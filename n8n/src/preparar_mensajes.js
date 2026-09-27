// Prepara los mensajes de una notificación (uno por canal y destinatario).
// Entrada: la "notificacion" que devuelve Supabase (fn_voz_tool / fn_voz_event).
// RGPD: solo los datos imprescindibles; mensajes de servicio (nunca publicidad);
// el enlace a la política de privacidad del negocio va en los mensajes al cliente.
const cfg = $('Configuración').first().json;
const salida = [];
// Interruptores (nodo Configuración): un canal sin configurar no se usa y no genera alertas
const activo = (v) => ['sí', 'si', 'true', '1', 'yes'].includes(String(v ?? '').trim().toLowerCase());
const WA = activo(cfg.WHATSAPP_ACTIVO), SMS = activo(cfg.SMS_ACTIVO), EMAIL = activo(cfg.EMAIL_ACTIVO);

const DIAS = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'];
const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto',
  'septiembre', 'octubre', 'noviembre', 'diciembre'];
const fecha = (iso) => {
  if (!iso) return '';
  const [y, m, d] = String(iso).split('-').map(Number);
  return `${DIAS[new Date(Date.UTC(y, m - 1, d)).getUTCDay()]} ${d} de ${MESES[m - 1]}`;
};
// WhatsApp no admite saltos de línea, tabuladores ni parámetros vacíos en las plantillas
const p = (v, max = 300) => {
  const s = String(v ?? '').replace(/[\r\n\t]+/g, ' ').replace(/ {2,}/g, ' ').trim().slice(0, max);
  return s || '-';
};
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const wa = (destino, plantilla, parametros, extra = {}) => salida.push({ json: {
  canal: 'whatsapp', destino, plantilla, idioma: cfg.WHATSAPP_IDIOMA,
  parametros: parametros.map((x) => p(x)), ...extra,
} });
const sms = (destino, texto, extra = {}) => salida.push({ json: {
  canal: 'sms', destino, texto: String(texto).slice(0, 320), ...extra,
} });
const email = (destino, asunto, html, responderA) => salida.push({ json: {
  canal: 'email', destino, asunto, html, responder_a: responderA || cfg.EMAIL_REMITENTE,
} });

for (const item of $input.all()) {
  const n = item.json.notificacion || item.json;
  // Los datos del negocio llegan con distinta forma según el origen (cita / derivación / fin de llamada)
  const neg = (n.negocio && typeof n.negocio === 'object') ? n.negocio : {
    nombre: (n.aviso && n.aviso.negocio) || (typeof n.negocio === 'string' ? n.negocio : ''),
    whatsapp_avisos: (n.aviso && n.aviso.whatsapp_negocio) || n.whatsapp_negocio || null,
  };
  const tipo = n.tipo || (n.avisar_negocio ? 'llamada_no_resuelta' : null);
  const cli = n.cliente || {};
  const conf = n.confirmacion || {};
  const serv = (n.servicio && n.servicio.nombre) || '';
  const nombreNeg = neg.nombre || n.negocio_nombre || '';
  const privacidad = n.url_privacidad || '';
  const telNeg = neg.telefono || '';
  const quien = n.profesional ? ` con ${n.profesional}` : '';
  const personas = Number(n.comensales) > 1 ? ` · ${n.comensales} personas` : '';
  const ctx = { tipo, tenant_id: n.tenant_id || '', call_id: n.call_id || '' };

  // ─── Al cliente ──────────────────────────────────────────────────────────
  const plantillaCliente = { cita_confirmada: cfg.PLANTILLA_CITA_CONFIRMADA,
    cita_reprogramada: cfg.PLANTILLA_CITA_MODIFICADA, cita_cancelada: cfg.PLANTILLA_CITA_ANULADA }[tipo];
  if (plantillaCliente && cli.telefono && conf.canal !== 'ninguno') {
    const cuando = `${fecha(n.fecha)} a las ${n.hora_inicio}`;
    let parametros, textoSms, asunto;
    if (tipo === 'cita_cancelada') {
      parametros = [cli.nombre, nombreNeg, serv, cuando, telNeg];
      textoSms = `${nombreNeg}: tu cita de ${serv} del ${cuando} queda anulada. Para pedir otra, llama al ${telNeg}.`;
      asunto = `Cita anulada · ${nombreNeg}`;
    } else {
      parametros = [cli.nombre, nombreNeg, `${serv}${quien}${personas}`, cuando, n.referencia, telNeg, privacidad];
      const verbo = tipo === 'cita_reprogramada' ? 'se ha cambiado al' : 'está confirmada:';
      textoSms = `${nombreNeg}: tu cita de ${serv} ${verbo} ${cuando}. Ref. ${n.referencia}. `
        + `Cambios: ${telNeg}.${privacidad ? ` Privacidad: ${privacidad}` : ''}`;
      asunto = `${tipo === 'cita_reprogramada' ? 'Cita modificada' : 'Cita confirmada'} · ${nombreNeg}`;
    }

    // Canal elegido por el negocio; si está apagado se usa el otro canal de móvil si está encendido
    if (conf.canal === 'whatsapp' && WA) {
      wa(cli.telefono, plantillaCliente, parametros, { ...ctx, sms_respaldo: conf.sms_respaldo && SMS ? textoSms : null });
    } else if ((conf.canal === 'sms' || conf.canal === 'whatsapp') && SMS) {
      sms(cli.telefono, textoSms, ctx);
    } else if (conf.canal === 'sms' && WA) {
      wa(cli.telefono, plantillaCliente, parametros, ctx);
    }

    if (cli.email && EMAIL) {
      const filas = [['Servicio', `${serv}${quien}${personas}`], ['Cuándo', cuando],
        ...(tipo !== 'cita_cancelada' ? [['Referencia', n.referencia]] : []),
        ['Dirección', neg.direccion || ''], ['Teléfono', telNeg]]
        .filter(([, v]) => v).map(([k, v]) => `<tr><td style="padding:4px 12px 4px 0;color:#666">${esc(k)}</td><td><b>${esc(v)}</b></td></tr>`).join('');
      const html = `<p>Hola ${esc(cli.nombre)},</p><p>${esc(textoSms.replace(/^[^:]+: /, ''))}</p><table>${filas}</table>`
        + '<p style="color:#666;font-size:12px">Este es un mensaje automático sobre tu cita, enviado porque la solicitaste por teléfono. '
        + `Responsable del tratamiento: ${esc(nombreNeg)}. Puedes ejercer tus derechos de acceso, rectificación, supresión y demás contactando con el negocio`
        + `${privacidad ? `; más información en <a href="${esc(privacidad)}">${esc(privacidad)}</a>` : ''}.</p>`;
      email(cli.email, asunto, html, neg.email_avisos);
    }
  }

  // ─── Al negocio (su WhatsApp de avisos) ─────────────────────────────────
  const emailNeg = neg.email_avisos || (n.aviso && n.aviso.email_negocio) || null;
  if ((neg.whatsapp_avisos && WA) || (emailNeg && EMAIL)) {
    const telCli = cli.telefono || n.llamante || 'número oculto';
    const avisos = {
      cita_confirmada: ['Nueva cita', `${cli.nombre} · ${serv}${quien}${personas} · ${fecha(n.fecha)} ${n.hora_inicio} · ref. ${n.referencia}`, `Teléfono del cliente: ${telCli}`],
      cita_reprogramada: ['Cita cambiada', `${cli.nombre} · ${serv}${quien} · antes ${fecha(n.anterior && n.anterior.fecha)} ${(n.anterior && n.anterior.hora_inicio) || ''}, ahora ${fecha(n.fecha)} ${n.hora_inicio} · ref. ${n.referencia}`, `Teléfono del cliente: ${telCli}`],
      cita_cancelada: ['Cita anulada', `${cli.nombre} · ${serv} · ${fecha(n.fecha)} ${n.hora_inicio} · ref. ${n.referencia}`, 'El hueco vuelve a estar libre en la agenda'],
      derivacion: ['Llamada para el equipo', `Motivo: ${String(n.motivo || '').replace(/_/g, ' ')}. ${n.resumen || ''}`, `Devolver la llamada al ${telCli}`],
      llamada_no_resuelta: ['Llamada no resuelta', n.resumen || 'Sin resumen disponible', `Devolver la llamada al ${telCli}`],
    }[tipo];
    if (avisos && neg.whatsapp_avisos && WA) {
      wa(neg.whatsapp_avisos, cfg.PLANTILLA_AVISO_NEGOCIO, [nombreNeg, ...avisos], ctx);
    } else if (avisos && emailNeg && EMAIL) {
      const html = `<p><b>${esc(avisos[0])}</b></p><p>${esc(avisos[1])}</p><p>${esc(avisos[2])}</p>`
        + '<p style="color:#666;font-size:12px">Aviso automático de tu asistente telefónico (Verantia).</p>';
      email(emailNeg, `${avisos[0]} · ${nombreNeg}`, html, cfg.EMAIL_REMITENTE);
    }
  }
}

return salida;
