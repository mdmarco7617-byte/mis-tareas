// Simuladores para la prueba de extremo a extremo de los flujos de n8n (SOLO pruebas locales):
//   :54321  API RPC estilo Supabase (/rest/v1/rpc/<fn>) → ejecuta las funciones REALES del Postgres local
//   :54322  WhatsApp Cloud API + Twilio → registran los mensajes (un número "sin WhatsApp" devuelve error)
//   :2525   SMTP → registra los correos
//   GET/DELETE :54322/registro → consultar / vaciar lo enviado
import http from 'node:http';
import net from 'node:net';
import pg from 'pg';

const APIKEY = process.env.APIKEY || 'clave-prueba';
const SIN_WHATSAPP = '34600999999';           // simula un número que WhatsApp rechaza
const db = new pg.Pool({ host: process.env.PGHOST, port: process.env.PGPORT, user: 'postgres', database: process.env.DB });
const registro = [];

const leer = (req) => new Promise((ok) => { let b = ''; req.on('data', (c) => { b += c; }); req.on('end', () => ok(b)); });
const enviar = (res, codigo, cuerpo) => { res.writeHead(codigo, { 'content-type': 'application/json' }); res.end(JSON.stringify(cuerpo)); };

// ─── API estilo Supabase ───────────────────────────────────────────────────
http.createServer(async (req, res) => {
  const m = req.url.match(/^\/rest\/v1\/rpc\/([a-z_]+)$/);
  if (req.method !== 'POST' || !m) return enviar(res, 404, { message: 'no encontrado' });
  if (req.headers.apikey !== APIKEY) return enviar(res, 401, { message: 'Invalid API key' });
  try {
    const args = JSON.parse((await leer(req)) || '{}');
    if (args.p_call_id === 'forzar-caida') return enviar(res, 503, { message: 'simulación: Supabase caído' });
    const claves = Object.keys(args).filter((k) => /^p_[a-z_]+$/.test(k));
    const sql = `select public.${m[1]}(${claves.map((k, i) => `${k} => $${i + 1}`).join(', ')}) as r`;
    const { rows } = await db.query(sql, claves.map((k) => args[k]));
    enviar(res, 200, rows[0].r);
  } catch (e) {
    enviar(res, 400, { message: e.message });
  }
}).listen(54321);

// ─── WhatsApp + Twilio ─────────────────────────────────────────────────────
http.createServer(async (req, res) => {
  if (req.url === '/registro') {
    if (req.method === 'DELETE') registro.length = 0;
    return enviar(res, 200, registro);
  }
  const cuerpo = await leer(req);
  if (/^\/v[\d.]+\/[^/]+\/messages$/.test(req.url)) {
    const j = JSON.parse(cuerpo);
    if (!/^Bearer token-whatsapp-prueba$/.test(req.headers.authorization || '')) return enviar(res, 401, { error: { message: 'token' } });
    if (j.to === SIN_WHATSAPP) return enviar(res, 400, { error: { message: 'Recipient phone number not in allowed list', code: 131030 } });
    registro.push({ canal: 'whatsapp', to: j.to, plantilla: j.template.name, idioma: j.template.language.code,
                    parametros: j.template.components[0].parameters.map((p) => p.text) });
    return enviar(res, 200, { messages: [{ id: `wamid.${registro.length}` }] });
  }
  if (/^\/2010-04-01\/Accounts\/[^/]+\/Messages\.json$/.test(req.url)) {
    const f = Object.fromEntries(new URLSearchParams(cuerpo));
    const auth = Buffer.from((req.headers.authorization || '').replace('Basic ', ''), 'base64').toString();
    if (auth !== 'ACprueba:token-twilio-prueba') return enviar(res, 401, { message: 'auth' });
    registro.push({ canal: 'sms', to: f.To, from: f.From, texto: f.Body });
    return enviar(res, 201, { sid: `SM${registro.length}` });
  }
  enviar(res, 404, {});
}).listen(54322);

// ─── SMTP mínimo ───────────────────────────────────────────────────────────
net.createServer((s) => {
  let datos = false; let buf = ''; const correo = { canal: 'email', to: [] };
  s.write('220 prueba ESMTP\r\n');
  s.on('data', (d) => {
    buf += d.toString();
    let i;
    while ((i = buf.indexOf('\r\n')) >= 0) {
      if (datos) {
        const fin = buf.indexOf('\r\n.\r\n');
        if (fin < 0) return;
        correo.contenido = buf.slice(0, fin); buf = buf.slice(fin + 5); datos = false;
        correo.asunto = (correo.contenido.match(/^Subject: (.*)$/m) || [])[1];
        registro.push({ ...correo }); s.write('250 OK\r\n'); continue;
      }
      const linea = buf.slice(0, i); buf = buf.slice(i + 2);
      const cmd = linea.slice(0, 4).toUpperCase();
      if (cmd === 'EHLO') s.write('250-prueba\r\n250 SIZE 10000000\r\n');
      else if (cmd === 'HELO' || cmd === 'MAIL' || cmd === 'RSET' || cmd === 'NOOP') s.write('250 OK\r\n');
      else if (cmd === 'RCPT') { correo.to.push(linea.replace(/.*<(.*)>.*/, '$1')); s.write('250 OK\r\n'); }
      else if (cmd === 'DATA') { datos = true; s.write('354 adelante\r\n'); }
      else if (cmd === 'QUIT') { s.write('221 adiós\r\n'); s.end(); }
      else s.write('250 OK\r\n');
    }
  });
}).listen(2525);

console.log('simuladores listos: supabase :54321 · whatsapp/twilio :54322 · smtp :2525');
