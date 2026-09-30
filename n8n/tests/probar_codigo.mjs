// Ejecuta el JavaScript de los nodos Code igual que n8n (mismas variables: $input, $, this.helpers,
// $getWorkflowStaticData) con respuestas REALES de Supabase (fixtures) y comprueba el resultado.
// Uso: node n8n/tests/probar_codigo.mjs
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const aqui = dirname(fileURLToPath(import.meta.url));
const src = (f) => readFileSync(join(aqui, '..', 'src', f), 'utf8');
const fx = (f) => JSON.parse(readFileSync(join(aqui, 'fixtures', f), 'utf8'));
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

const CONFIG_BASE = JSON.parse(readFileSync(join(aqui, '..', 'config_ejemplo.json'), 'utf8'));
// Por defecto las pruebas encienden los tres canales; cada prueba puede apagarlos
const TODO_ENCENDIDO = { WHATSAPP_ACTIVO: 'sí', SMS_ACTIVO: 'sí', EMAIL_ACTIVO: 'sí' };
let CONFIG = { ...CONFIG_BASE, ...TODO_ENCENDIDO };
const estadoGlobal = {};

async function ejecutar(fichero, items, { binarios = {}, config } = {}) {
  CONFIG = { ...CONFIG_BASE, ...TODO_ENCENDIDO, ...(config || {}) };
  const $input = { first: () => items[0], all: () => items };
  const $ = (nodo) => {
    if (nodo !== 'Configuración') throw new Error(`nodo desconocido ${nodo}`);
    return { first: () => ({ json: CONFIG }) };
  };
  const ctx = { helpers: { getBinaryDataBuffer: async (i, prop) => binarios[prop] } };
  const fn = new AsyncFunction('$input', '$', '$getWorkflowStaticData', src(fichero));
  return fn.call(ctx, $input, $, () => estadoGlobal);
}

let ok = 0;
const prueba = async (nombre, f) => {
  try { await f(); ok++; console.log(`ok  ${nombre}`); } catch (e) { console.log(`FALLA  ${nombre}\n  ${e.message}`); process.exitCode = 1; }
};
const sinPII = (texto) => {
  assert.ok(!/\+?\d[\d\s().-]{7,}\d/.test(texto), `hay un teléfono en: ${texto}`);
  assert.ok(!/@/.test(texto), `hay un email en: ${texto}`);
};

// ─── leer_peticion ─────────────────────────────────────────────────────────
await prueba('leer_peticion: cuerpo exacto (bytes) y cabeceras', async () => {
  const cuerpo = '{"a": 1,  "b":"ñ"}';
  const [r] = await ejecutar('leer_peticion.js', [{ json: { headers: { 'x-retell-signature': 'v=1,d=2', 'x-herramienta': 'check_availability', 'x-numero-negocio': '+34983000001' }, body: { a: 1 } }, binary: { data: {} } }],
    { binarios: { data: Buffer.from(cuerpo, 'utf8') } });
  assert.equal(r.json.p_raw, cuerpo);                       // no re-serializado: los espacios se conservan
  assert.equal(r.json.p_signature, 'v=1,d=2');
  assert.equal(r.json.p_tool, 'check_availability');
  assert.equal(r.json.p_to, '+34983000001');
  assert.equal(r.json.p_from, null);
});
await prueba('leer_peticion: sin cuerpo crudo → lo marca (la firma fallará en Supabase)', async () => {
  const [r] = await ejecutar('leer_peticion.js', [{ json: { headers: {}, body: { event: 'call_started' } } }]);
  assert.equal(r.json.cuerpo_leido, false);
  assert.equal(r.json.evento, 'call_started');
});

// ─── construir_variables ───────────────────────────────────────────────────
await prueba('variables: contexto real → todas las variables son texto', async () => {
  const [r] = await ejecutar('construir_variables.js', [{ json: fx('contexto_ok.json') }]);
  const v = r.json.respuesta.call_inbound.dynamic_variables;
  for (const [k, val] of Object.entries(v)) assert.equal(typeof val, 'string', `${k} no es texto`);
  assert.equal(r.json.firma_valida, true);
  assert.equal(v.modo_servicio, 'normal');
  assert.equal(v.nombre_negocio, 'Peluquería Demo');
});
await prueba('variables: saludo con aviso de IA y de privacidad en la primera frase', async () => {
  const [r] = await ejecutar('construir_variables.js', [{ json: fx('contexto_ok.json') }]);
  const s = r.json.respuesta.call_inbound.dynamic_variables.saludo_inicial;
  assert.match(s, /^Hola, soy Álex, asistente virtual con inteligencia artificial de Peluquería Demo\./);
  assert.match(s, /gestionar tu cita; puedes pedirnos más información\./);   // sin web cargada: no promete una web
  assert.ok(s.split(' ').length <= 30, 'el saludo es demasiado largo para una llamada');
});
await prueba('variables: con política de privacidad cargada, el saludo remite a la web', async () => {
  const ctx = structuredClone(fx('contexto_ok.json')); ctx.url_privacidad = 'https://ejemplo.es/privacidad';
  const [r] = await ejecutar('construir_variables.js', [{ json: ctx }]);
  assert.match(r.json.respuesta.call_inbound.dynamic_variables.saludo_inicial, /más información en nuestra web\./);
});
await prueba('variables: calendario de 30 días, horario y catálogo con códigos', async () => {
  const [r] = await ejecutar('construir_variables.js', [{ json: fx('contexto_ok.json') }]);
  const v = r.json.respuesta.call_inbound.dynamic_variables;
  assert.equal(v.calendario.split('\n').length, 30);
  assert.match(v.calendario.split('\n')[0], /^hoy, \p{L}+ \d+ de \p{L}+ de \d{4} = \d{4}-\d{2}-\d{2}$/u);
  assert.match(v.horario, /lunes: 10:00 a 14:00 y 16:00 a 20:00/);
  assert.match(v.horario, /domingo: cerrado/);
  assert.match(v.catalogo, /- mechas: Mechas · desde 65 € · 120 min/);
  assert.match(v.catalogo, /- corte_mujer: Corte de mujer · 22 € · 45 min · lo hacen: Laura, Marta/);
});
await prueba('variables: reconoce al cliente que llama y sus citas', async () => {
  const [r] = await ejecutar('construir_variables.js', [{ json: fx('contexto_ok.json') }]);
  assert.match(r.json.respuesta.call_inbound.dynamic_variables.cliente_conocido, /^Ana Fixture\. Próximas citas: .* \(referencia \d{6}\)/);
});
await prueba('variables: número no asignado → modo sin_sistema con todas las variables', async () => {
  const [ok1] = await ejecutar('construir_variables.js', [{ json: fx('contexto_ok.json') }]);
  const [r] = await ejecutar('construir_variables.js', [{ json: fx('contexto_desconocido.json') }]);
  const v = r.json.respuesta.call_inbound.dynamic_variables;
  assert.equal(v.modo_servicio, 'sin_sistema');
  assert.equal(r.json.firma_valida, true);
  assert.deepEqual(Object.keys(v).sort(), Object.keys(ok1.json.respuesta.call_inbound.dynamic_variables).sort());
});
await prueba('variables: firma no válida → se marca para responder 401', async () => {
  const [r] = await ejecutar('construir_variables.js', [{ json: fx('contexto_firma_mala.json') }]);
  assert.equal(r.json.firma_valida, false);
});

// ─── preparar_mensajes ─────────────────────────────────────────────────────
await prueba('mensajes: cita confirmada → WhatsApp cliente (+SMS respaldo) + email + aviso negocio', async () => {
  const out = await ejecutar('preparar_mensajes.js', [{ json: fx('tool_confirmado.json') }]);
  const canales = out.map((o) => `${o.json.canal}:${o.json.plantilla || ''}`);
  assert.deepEqual(canales, ['whatsapp:verantia_cita_confirmada', 'email:', 'whatsapp:verantia_aviso_negocio']);
  const [cli, mail, neg] = out.map((o) => o.json);
  assert.equal(cli.destino, '+34600888001');
  assert.equal(cli.parametros.length, 7);
  assert.equal(cli.parametros[0], 'Ana Fixture');
  assert.match(cli.parametros[3], /^\p{L}+ \d+ de \p{L}+ a las 10:00$/u);
  assert.match(cli.sms_respaldo, /Ref\. \d{6}/);
  assert.equal(mail.destino, 'ana@example.com');
  assert.match(mail.html, /Responsable del tratamiento: Peluquería Demo/);
  assert.equal(neg.destino, '+34600000001');
  assert.equal(neg.parametros[1], 'Nueva cita');
});
await prueba('mensajes: parámetros de WhatsApp sin saltos de línea ni vacíos', async () => {
  const out = await ejecutar('preparar_mensajes.js', [{ json: fx('tool_confirmado.json') }]);
  for (const o of out.filter((x) => x.json.canal === 'whatsapp')) {
    for (const p of o.json.parametros) { assert.ok(p.length > 0); assert.ok(!/[\n\r\t]/.test(p)); }
  }
});
await prueba('mensajes: email escapa HTML (nombre malicioso no inyecta código)', async () => {
  const n = structuredClone(fx('tool_confirmado.json'));
  n.notificacion.cliente.nombre = '<script>alert(1)</script>';
  const out = await ejecutar('preparar_mensajes.js', [{ json: n }]);
  const mail = out.find((o) => o.json.canal === 'email').json;
  assert.ok(!mail.html.includes('<script>'));
});
await prueba('mensajes: cita reprogramada → plantilla de modificación y aviso con antes/ahora', async () => {
  const out = await ejecutar('preparar_mensajes.js', [{ json: fx('tool_reprogramada.json') }]);
  assert.equal(out[0].json.plantilla, 'verantia_cita_modificada');
  const neg = out.find((o) => o.json.plantilla === 'verantia_aviso_negocio').json;
  assert.match(neg.parametros[2], /antes .* 10:00, ahora .* 11:00/);
});
await prueba('mensajes: cita anulada → plantilla de anulación (5 parámetros)', async () => {
  const out = await ejecutar('preparar_mensajes.js', [{ json: fx('tool_cancelada.json') }]);
  assert.equal(out[0].json.plantilla, 'verantia_cita_anulada');
  assert.equal(out[0].json.parametros.length, 5);
});
await prueba('mensajes: derivación → solo aviso al negocio, con teléfono para devolver la llamada', async () => {
  const out = await ejecutar('preparar_mensajes.js', [{ json: fx('tool_derivacion.json') }]);
  assert.equal(out.length, 1);
  assert.equal(out[0].json.destino, '+34600000001');
  assert.deepEqual(out[0].json.parametros.slice(0, 2), ['Peluquería Demo', 'Llamada para el equipo']);
  assert.match(out[0].json.parametros[3], /\+34600888002/);
});
await prueba('mensajes: llamada no resuelta (fin de llamada) → aviso al negocio', async () => {
  const out = await ejecutar('preparar_mensajes.js', [{ json: fx('evento_no_resuelta.json') }]);
  assert.equal(out.length, 1);
  assert.deepEqual(out[0].json.parametros.slice(0, 2), ['Peluquería Demo', 'Llamada no resuelta']);
  assert.match(out[0].json.parametros[2], /mechas/);
});
await prueba('mensajes: canal "sms" del negocio → SMS directo, sin WhatsApp al cliente', async () => {
  const n = structuredClone(fx('tool_confirmado.json'));
  n.notificacion.confirmacion.canal = 'sms';
  const out = await ejecutar('preparar_mensajes.js', [{ json: n }]);
  assert.equal(out[0].json.canal, 'sms');
  assert.ok(out[0].json.texto.length <= 320);
});
await prueba('mensajes: canal "ninguno" → nada al cliente, solo al negocio', async () => {
  const n = structuredClone(fx('tool_confirmado.json'));
  n.notificacion.confirmacion.canal = 'ninguno';
  const out = await ejecutar('preparar_mensajes.js', [{ json: n }]);
  assert.deepEqual(out.map((o) => o.json.destino), ['+34600000001']);
});

await prueba('interruptores: configuración de ejemplo = todo apagado → no se envía nada', async () => {
  const out = await ejecutar('preparar_mensajes.js', [{ json: fx('tool_confirmado.json') }],
    { config: { WHATSAPP_ACTIVO: CONFIG_BASE.WHATSAPP_ACTIVO, SMS_ACTIVO: CONFIG_BASE.SMS_ACTIVO, EMAIL_ACTIVO: CONFIG_BASE.EMAIL_ACTIVO } });
  assert.equal(out.length, 0);
});
await prueba('interruptores: solo email (Resend) → email al cliente y aviso al negocio por email', async () => {
  const n = structuredClone(fx('tool_confirmado.json'));
  n.notificacion.negocio.email_avisos = 'negocio@example.com';
  const out = await ejecutar('preparar_mensajes.js', [{ json: n }], { config: { WHATSAPP_ACTIVO: 'no', SMS_ACTIVO: 'no' } });
  assert.deepEqual(out.map((o) => `${o.json.canal}:${o.json.destino}`), ['email:ana@example.com', 'email:negocio@example.com']);
  assert.match(out[1].json.asunto, /^Nueva cita · Peluquería Demo$/);
});
await prueba('interruptores: WhatsApp apagado y SMS encendido → SMS al cliente', async () => {
  const out = await ejecutar('preparar_mensajes.js', [{ json: fx('tool_confirmado.json') }], { config: { WHATSAPP_ACTIVO: 'no', EMAIL_ACTIVO: 'no' } });
  assert.deepEqual(out.map((o) => o.json.canal), ['sms']);
});
await prueba('interruptores: SMS apagado → WhatsApp sin SMS de respaldo', async () => {
  const out = await ejecutar('preparar_mensajes.js', [{ json: fx('tool_confirmado.json') }], { config: { SMS_ACTIVO: 'no' } });
  assert.equal(out[0].json.canal, 'whatsapp');
  assert.equal(out[0].json.sms_respaldo, null);
});

// ─── preparar_alerta ───────────────────────────────────────────────────────
await prueba('alerta: sin datos personales aunque el error los contenga', async () => {
  const out = await ejecutar('preparar_alerta.js', [{ json: {
    execution: { id: '77', lastNodeExecuted: 'Supabase', error: { message: 'Fallo con +34 600 111 222 y ana@example.com' } },
    workflow: { id: 'w1', name: 'VOZ · 02 Herramientas' } } }]);
  assert.equal(out.length, 1);
  sinPII(out[0].json.parametros.join(' '));
  assert.match(out[0].json.parametros[2], /\[teléfono\].*\[email\]/);
});
await prueba('alerta: con WhatsApp apagado va por email (Resend)', async () => {
  const out = await ejecutar('preparar_alerta.js', [{ json: { origen: 'prueba', codigo: 'CANAL_EMAIL' } }], { config: { WHATSAPP_ACTIVO: 'no' } });
  assert.equal(out[0].json.canal, 'email');
  assert.equal(out[0].json.email_respaldo, CONFIG_BASE.EMAIL_VERANTIA);
});
await prueba('alerta: la misma alerta no se repite en 10 minutos', async () => {
  const a = { origen: 'VOZ · 01', codigo: 'NUMERO_NO_ASIGNADO', tenant_id: 't1' };
  const p1 = await ejecutar('preparar_alerta.js', [{ json: a }]);
  const p2 = await ejecutar('preparar_alerta.js', [{ json: a }]);
  const p3 = await ejecutar('preparar_alerta.js', [{ json: { ...a, codigo: 'OTRO' } }]);
  assert.equal(p1.length, 1); assert.equal(p2.length, 0); assert.equal(p3.length, 1);
});

// ─── evaluar_salud ─────────────────────────────────────────────────────────
await prueba('salud: todo bien → no avisa', async () => {
  const s = { ...fx('salud.json'), errores_24h: 0, errores_por_codigo: {}, purga_programada: true };
  assert.equal((await ejecutar('evaluar_salud.js', [{ json: s }])).length, 0);
});
await prueba('salud: errores o purga RGPD inactiva → avisa sin datos personales', async () => {
  const s = { ...fx('salud.json'), errores_24h: 3, errores_por_codigo: { FIRMA_NO_VALIDA: 3 }, purga_programada: false };
  const out = await ejecutar('evaluar_salud.js', [{ json: s }]);
  assert.equal(out.length, 1);
  assert.match(out[0].json.detalle, /3 errores.*FIRMA_NO_VALIDA: 3.*purga diaria RGPD/);
  sinPII(out[0].json.detalle);
});

// ─── Coherencia con Retell ─────────────────────────────────────────────────
await prueba('retell: toda {{variable}} del prompt y de las funciones existe (modo normal y sin sistema)', async () => {
  const retell = join(aqui, '..', '..', 'retell');
  const textos = readFileSync(join(retell, 'prompt_agente.md'), 'utf8') + readFileSync(join(retell, 'herramientas.json'), 'utf8') + '{{saludo_inicial}}';
  const usadas = [...new Set([...textos.matchAll(/\{\{\s*([a-zA-Z_]+)\s*\}\}/g)].map((m) => m[1]))].filter((v) => v !== 'N8N_URL');
  for (const fx_ of ['contexto_ok.json', 'contexto_desconocido.json']) {
    const [r] = await ejecutar('construir_variables.js', [{ json: fx(fx_) }]);
    const v = r.json.respuesta.call_inbound.dynamic_variables;
    const faltan = usadas.filter((k) => !(k in v));
    assert.deepEqual(faltan, [], `${fx_}: faltan ${faltan.join(', ')}`);
  }
});
await prueba('retell: las 7 funciones propias apuntan al webhook de herramientas con sus 4 cabeceras', async () => {
  const h = JSON.parse(readFileSync(join(aqui, '..', '..', 'retell', 'herramientas.json'), 'utf8'));
  const propias = h.filter((t) => t.type === 'custom');
  assert.equal(propias.length, 7);
  for (const t of propias) {
    assert.equal(t.headers['x-herramienta'], t.name);
    assert.deepEqual(Object.keys(t.headers).sort(), ['x-herramienta', 'x-id-llamada', 'x-numero-llamante', 'x-numero-negocio']);
    assert.match(t.url, /\/webhook\/verantia-voz\/herramientas$/);
  }
});

console.log(process.exitCode ? '══ HAY FALLOS' : `══ ${ok} PRUEBAS DEL CÓDIGO DE n8n OK`);
