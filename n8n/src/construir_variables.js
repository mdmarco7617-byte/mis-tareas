// Convierte el contexto del negocio (Supabase) en las variables dinámicas del prompt de Retell.
// Retell exige que todos los valores sean texto. Si algo falla, el agente arranca en modo
// "sin_sistema": atiende, toma nota y promete que llamarán (nunca inventa disponibilidad).
const r = $input.first().json || {};
const txt = (v) => (v === null || v === undefined ? '' : String(v));

const DIAS = ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'];
const MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto',
  'septiembre', 'octubre', 'noviembre', 'diciembre'];
const fechaLarga = (iso) => {
  const [y, m, d] = iso.split('-').map(Number);
  const f = new Date(Date.UTC(y, m - 1, d));
  return `${DIAS[f.getUTCDay()]} ${d} de ${MESES[m - 1]} de ${y}`;
};
const euros = (n) => {
  const v = Number(n);
  return Number.isInteger(v) ? `${v} €` : `${v.toFixed(2).replace('.', ',')} €`;
};

// Variables que el prompt usa siempre (también en modo sin sistema)
const base = {
  modo_servicio: 'sin_sistema',
  nombre_negocio: 'el negocio', nombre_asistente: 'el asistente virtual', tipo_negocio: '',
  descripcion_negocio: '', direccion: '', telefono_negocio: '',
  fecha_hoy: '', fecha_hoy_iso: '', calendario: '', horario: '', festivos_y_cierres: '',
  catalogo: '', profesionales: '', faq: '', politica_cancelacion: '', antelacion_minima: '',
  es_restaurante: 'no', max_comensales: '', cliente_conocido: '',
  puede_transferir: 'no', telefono_transferencia: '',
  numero_negocio: '', numero_llamante: '', id_llamada: txt(r.call_id),
  saludo_inicial: 'Hola, soy un asistente virtual con inteligencia artificial. Ahora mismo no puedo consultar la agenda, pero tomo nota de tu consulta y el equipo te llamará. ¿Me dices tu nombre y el motivo de la llamada?',
};

if (r.ok !== true) {
  const firmaMala = r.codigo === 'FIRMA_NO_VALIDA';
  return [{ json: {
    firma_valida: !firmaMala,
    modo: 'sin_sistema',
    codigo: txt(r.codigo) || 'ERROR_TECNICO',
    call_id: txt(r.call_id),
    respuesta: { call_inbound: { dynamic_variables: base } },
  } }];
}

const t = r.tenant || {};
const hoyIso = txt(r.hoy);

// Calendario de 30 días: evita que la IA calcule mal "el jueves que viene"
const [y, m, d] = hoyIso.split('-').map(Number);
const cal = [];
for (let i = 0; i < 30; i++) {
  const f = new Date(Date.UTC(y, m - 1, d + i));
  const iso = f.toISOString().slice(0, 10);
  cal.push(`${i === 0 ? 'hoy, ' : i === 1 ? 'mañana, ' : ''}${fechaLarga(iso)} = ${iso}`);
}

// Horario semanal legible (los días sin franjas = cerrado)
const porDia = {};
for (const h of r.horario || []) porDia[h.dia] = (h.franjas || []).map((x) => x.replace('-', ' a ')).join(' y ');
const nombresIso = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];
const horario = nombresIso.map((n, i) => `${n}: ${porDia[i + 1] || 'cerrado'}`).join('; ');

const cierres = [
  ...(r.festivos_proximos || []).map((f) => `${fechaLarga(f.fecha)}: cerrado (${f.nombre})`),
  ...(r.cierres_proximos || []).map((c) => `del ${c.desde} al ${c.hasta}: cerrado${c.motivo ? ` (${c.motivo})` : ''}`),
].join('\n');

const profesionales = new Set();
const catalogo = (r.servicios || []).map((s) => {
  (s.profesionales || []).forEach((p) => profesionales.add(p));
  const precio = s.precio === null || s.precio === undefined ? 'precio a consultar'
    : `${s.precio_desde ? 'desde ' : ''}${euros(s.precio)}`;
  const con = (s.profesionales || []).length ? ` · lo hacen: ${s.profesionales.join(', ')}` : '';
  const desc = s.descripcion ? ` · ${s.descripcion}` : '';
  return `- ${s.codigo}: ${s.nombre} · ${precio} · ${s.duracion_min} min${con}${desc}`;
}).join('\n');

const faq = (r.faqs || []).map((f) => `P: ${f.pregunta}\nR: ${f.respuesta}`).join('\n');

let cliente = '';
if (r.cliente && r.cliente.nombre) {
  const citas = (r.cliente.citas || []).map((c) =>
    `${fechaLarga(c.fecha)} a las ${c.hora_inicio}, ${c.servicio} (referencia ${c.referencia})`);
  cliente = `${r.cliente.nombre}${citas.length ? `. Próximas citas: ${citas.join('; ')}` : '. Sin citas próximas'}`;
}

const antelacion = Number(t.antelacion_min_minutos || 0);
const asistente = txt(t.nombre_asistente) || 'el asistente virtual';
const negocio = txt(t.nombre);

// Primera capa informativa (RGPD art. 13) + aviso de IA (AI Act art. 50), en la primera frase
const saludo = `Hola, soy ${asistente}, asistente virtual con inteligencia artificial de ${negocio}. `
  + 'Usaré tus datos solo para atender tu consulta o gestionar tu cita; '
  + 'tienes toda la información sobre privacidad en nuestra web. ¿En qué puedo ayudarte?';

const vars = {
  ...base,
  modo_servicio: 'normal',
  nombre_negocio: negocio,
  nombre_asistente: asistente,
  tipo_negocio: txt(t.tipo),
  descripcion_negocio: txt(t.descripcion),
  direccion: txt(t.direccion),
  telefono_negocio: txt(t.telefono_publico),
  fecha_hoy: `${fechaLarga(hoyIso)}, son las ${txt(r.ahora_local).slice(11, 16)}`,
  fecha_hoy_iso: hoyIso,
  calendario: cal.join('\n'),
  horario,
  festivos_y_cierres: cierres || 'ninguno en las próximas semanas',
  catalogo,
  profesionales: [...profesionales].join(', '),
  faq,
  politica_cancelacion: txt(t.politica_cancelacion),
  antelacion_minima: antelacion >= 60 ? `${antelacion / 60} hora(s)` : `${antelacion} minutos`,
  es_restaurante: t.tipo === 'restaurante' ? 'sí' : 'no',
  max_comensales: txt(t.max_comensales),
  cliente_conocido: cliente,
  puede_transferir: t.puede_transferir ? 'sí' : 'no',
  telefono_transferencia: txt(r.telefono_transferencia),
  numero_negocio: txt(r.numero_negocio),
  numero_llamante: txt(r.numero_llamante),
  saludo_inicial: saludo,
};

return [{ json: {
  firma_valida: true,
  modo: 'normal',
  tenant_id: txt(t.id),
  respuesta: { call_inbound: { dynamic_variables: vars, metadata: { tenant_id: txt(t.id) } } },
} }];
