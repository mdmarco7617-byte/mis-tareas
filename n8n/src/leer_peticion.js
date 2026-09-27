// Lee el cuerpo EXACTO que envió Retell (hace falta byte a byte para verificar su firma)
// y las cabeceras. La firma se verifica en Supabase; aquí no se interpreta nada.
const item = $input.first();
const h = item.json.headers || {};

let raw = null;
if (item.binary) {
  const prop = Object.keys(item.binary)[0];
  if (prop) raw = (await this.helpers.getBinaryDataBuffer(0, prop)).toString('utf8');
}

const cab = (n) => (typeof h[n] === 'string' && h[n].length <= 100 ? h[n] : null);

return [{ json: {
  p_raw: raw ?? '',
  p_signature: String(h['x-retell-signature'] || '').slice(0, 200),
  // Solo en el formato "solo argumentos" de Retell (cabeceras configuradas en cada función)
  p_tool: cab('x-herramienta'),
  p_to: cab('x-numero-negocio'),
  p_from: cab('x-numero-llamante'),
  p_call_id: cab('x-id-llamada'),
  cuerpo_leido: raw !== null,
  evento: (item.json.body && typeof item.json.body.event === 'string') ? item.json.body.event : null,
} }];
