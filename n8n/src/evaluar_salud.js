// Revisión diaria: solo avisa si algo no va bien. Sin datos personales (solo contadores).
const s = $input.first().json || {};
const problemas = [];
if (s.ok !== true) problemas.push('Supabase no responde o devuelve un error');
if (Number(s.errores_24h) > 0) {
  const detalle = Object.entries(s.errores_por_codigo || {}).map(([c, n]) => `${c}: ${n}`).join(', ');
  problemas.push(`${s.errores_24h} errores en 24 h (${detalle})`);
}
if (s.ok === true && s.purga_programada !== true) problemas.push('La purga diaria RGPD (pg_cron) no está activa');

if (!problemas.length) return [];
return [{ json: {
  origen: 'VOZ · 06 Vigilancia diaria',
  codigo: 'REVISION_DIARIA',
  detalle: `${problemas.join(' | ')} · llamadas 24 h: ${s.llamadas_24h ?? '?'}, derivadas: ${s.derivadas_24h ?? '?'}`,
} }];
