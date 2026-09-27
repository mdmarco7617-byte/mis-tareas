// Prepara la alerta técnica para Verantia. SIN datos personales: se eliminan teléfonos,
// emails y textos largos. Evita el "spam" de alertas: la misma alerta no se repite en
// 10 minutos (24 h para el aviso de exceso de minutos).
const cfg = $('Configuración').first().json;
const estado = $getWorkflowStaticData('global');
estado.ultimas = estado.ultimas || {};
const ahora = Date.now();

const limpiar = (v, max = 200) => String(v ?? '')
  .replace(/[\w.+-]+@[\w-]+\.[\w.]+/g, '[email]')
  .replace(/\+?\d[\d\s().-]{7,}\d/g, '[teléfono]')
  .replace(/[\r\n\t]+/g, ' ').replace(/ {2,}/g, ' ').trim().slice(0, max) || '-';

// Limpia claves antiguas para que el estado no crezca
for (const [k, ts] of Object.entries(estado.ultimas)) if (ahora - ts > 86400000) delete estado.ultimas[k];

const salida = [];
for (const item of $input.all()) {
  const j = item.json;
  let origen, codigo, detalle;
  if (j.execution && j.workflow) {            // Error Trigger: un flujo ha fallado
    origen = `n8n · ${j.workflow.name || j.workflow.id}`;
    codigo = `FALLO_EN_NODO ${j.execution.lastNodeExecuted || ''}`.trim();
    detalle = `${(j.execution.error && j.execution.error.message) || 'sin mensaje'} · ejecución ${j.execution.id || '-'}`;
  } else {                                     // Alerta explícita desde otro flujo
    origen = j.origen || 'desconocido';
    codigo = j.codigo || 'SIN_CODIGO';
    detalle = [j.tenant_id && `negocio ${j.tenant_id}`, j.call_id && `llamada ${j.call_id}`, j.detalle]
      .filter(Boolean).join(' · ');
  }
  origen = limpiar(origen, 80); codigo = limpiar(codigo, 80); detalle = limpiar(detalle);

  const clave = `${origen}|${codigo}|${j.tenant_id || ''}`;
  const ventana = codigo.includes('EXCESO_MINUTOS') ? 86400000 : 600000;
  if (estado.ultimas[clave] && ahora - estado.ultimas[clave] < ventana) continue;
  estado.ultimas[clave] = ahora;

  const porWhatsapp = ['sí', 'si', 'true', '1', 'yes'].includes(String(cfg.WHATSAPP_ACTIVO ?? '').trim().toLowerCase());
  salida.push({ json: {
    canal: porWhatsapp ? 'whatsapp' : 'email', destino: cfg.WHATSAPP_VERANTIA, plantilla: cfg.PLANTILLA_ALERTA,
    idioma: cfg.WHATSAPP_IDIOMA, parametros: [origen, codigo, detalle],
    email_respaldo: cfg.EMAIL_VERANTIA,
    texto: `Origen: ${origen}\nCódigo: ${codigo}\nDetalle: ${detalle}`,
  } });
}
return salida;
