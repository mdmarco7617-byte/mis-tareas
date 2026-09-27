#!/usr/bin/env python3
"""Genera los flujos de n8n (JSON importables) a partir del código de n8n/src.

    python3 n8n/construir_flujos.py      → escribe n8n/flujos/*.json

El JavaScript de los nodos Code vive en n8n/src y se prueba aparte (n8n/tests/probar_codigo.mjs),
así lo que se importa en n8n es exactamente lo que se ha probado.
"""
import json
import os
import uuid
from pathlib import Path

AQUI = Path(__file__).parent
CFG = json.loads((AQUI / 'config_ejemplo.json').read_text())
# Solo para pruebas locales: VOZ_PRUEBAS='{"SUPABASE_URL": "http://localhost:54321", ...}'
CFG.update(json.loads(os.environ.get('VOZ_PRUEBAS', '{}')))
SUPABASE = CFG['SUPABASE_URL']

CRED_SUPABASE = {'httpHeaderAuth': {'id': 'REEMPLAZAR', 'name': 'Supabase · Verantia Voz'}}
CRED_WHATSAPP = {'httpHeaderAuth': {'id': 'REEMPLAZAR', 'name': 'WhatsApp · Verantia'}}
CRED_TWILIO = {'httpBasicAuth': {'id': 'REEMPLAZAR', 'name': 'Twilio · Verantia'}}
CRED_SMTP = {'smtp': {'id': 'REEMPLAZAR', 'name': 'SMTP · Verantia'}}

# RGPD: n8n no guarda las ejecuciones correctas (llevarían nombres y teléfonos).
# Las fallidas sí, para poder depurar; se borran solas con la poda de ejecuciones (ver README).
AJUSTES = {
    'executionOrder': 'v1',
    'saveDataSuccessExecution': 'none',
    'saveDataErrorExecution': 'all',
    'saveManualExecutions': False,
    'saveExecutionProgress': False,
    'timezone': 'Europe/Madrid',
    'callerPolicy': 'workflowsFromSameOwner',
}


class Flujo:
    def __init__(self, nombre):
        self.nombre, self.nodos, self.conex = nombre, [], {}

    def nodo(self, nombre, tipo, version, params, pos, **extra):
        n = {'parameters': params, 'type': tipo, 'typeVersion': version, 'position': list(pos),
             'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'{self.nombre}/{nombre}')), 'name': nombre}
        n.update(extra)
        self.nodos.append(n)
        return nombre

    def unir(self, origen, destino, salida=0):
        salidas = self.conex.setdefault(origen, {'main': []})['main']
        while len(salidas) <= salida:
            salidas.append([])
        salidas[salida].append({'node': destino, 'type': 'main', 'index': 0})

    def json(self):
        return {'name': self.nombre, 'nodes': self.nodos, 'connections': self.conex,
                'pinData': {}, 'active': False, 'settings': AJUSTES, 'meta': {'templateCredsSetupCompleted': False}}


# ─── Plantillas de nodos ───────────────────────────────────────────────────
def webhook(f, nombre, ruta, pos, responder_al_recibir=False):
    opciones = {'rawBody': True}   # cuerpo exacto: imprescindible para verificar la firma de Retell
    return f.nodo(nombre, 'n8n-nodes-base.webhook', 2,
                  {'httpMethod': 'POST', 'path': ruta,
                   'responseMode': 'onReceived' if responder_al_recibir else 'responseNode', 'options': opciones},
                  pos, webhookId=str(uuid.uuid5(uuid.NAMESPACE_URL, ruta)))


def codigo(f, nombre, fichero, pos):
    return f.nodo(nombre, 'n8n-nodes-base.code', 2, {'jsCode': (AQUI / 'src' / fichero).read_text()}, pos)


def rpc(f, nombre, funcion, cuerpo, pos, timeout=5000, reintentos=False):
    extra = {'onError': 'continueErrorOutput', 'credentials': CRED_SUPABASE}
    if reintentos:
        extra.update(retryOnFail=True, maxTries=3, waitBetweenTries=2000)
    return f.nodo(nombre, 'n8n-nodes-base.httpRequest', 4.2, {
        'method': 'POST', 'url': f'{SUPABASE}/rest/v1/rpc/{funcion}',
        'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
        'sendBody': True, 'specifyBody': 'json', 'jsonBody': cuerpo,
        'options': {'timeout': timeout}}, pos, **extra)


def si(f, nombre, expresion, pos):
    return f.nodo(nombre, 'n8n-nodes-base.if', 2.3, {
        'conditions': {
            'options': {'caseSensitive': True, 'leftValue': '', 'typeValidation': 'loose', 'version': 3},
            'conditions': [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'{f.nombre}/{nombre}/c')),
                            'leftValue': expresion, 'rightValue': '',
                            'operator': {'type': 'boolean', 'operation': 'true', 'singleValue': True}}],
            'combinator': 'and'},
        'looseTypeValidation': True, 'options': {}}, pos)


def responder(f, nombre, pos, cuerpo=None, codigo_http=200):
    params = {'respondWith': 'json' if cuerpo else 'noData', 'options': {'responseCode': codigo_http}}
    if cuerpo:
        params['responseBody'] = cuerpo
    return f.nodo(nombre, 'n8n-nodes-base.respondToWebhook', 1.1, params, pos)


def campos(f, nombre, valores, pos, conservar=False):
    asignaciones = [{'id': str(uuid.uuid5(uuid.NAMESPACE_URL, f'{f.nombre}/{nombre}/{k}')), 'name': k,
                     'value': v, 'type': 'boolean' if isinstance(v, bool) else 'string'}
                    for k, v in valores.items()]
    params = {'assignments': {'assignments': asignaciones}, 'options': {}}
    if conservar:
        params['includeOtherFields'] = True
    return f.nodo(nombre, 'n8n-nodes-base.set', 3.4, params, pos)


def subflujo(f, nombre, destino, pos):
    return f.nodo(nombre, 'n8n-nodes-base.executeWorkflow', 1.1, {
        'source': 'database',
        'workflowId': {'__rl': True, 'mode': 'list', 'value': '', 'cachedResultName': destino},
        'options': {'waitForSubWorkflow': False}}, pos)


def alerta(f, nombre, origen, codigo_expr, pos, detalle='={{ "" }}'):
    return campos(f, nombre, {
        'origen': origen, 'codigo': codigo_expr,
        'tenant_id': '={{ $json.tenant_id ?? "" }}', 'call_id': '={{ $json.call_id ?? "" }}',
        'detalle': detalle}, pos)


def configuracion(f, pos):
    return campos(f, 'Configuración', {k: v for k, v in CFG.items()}, pos, conservar=True)


ALERTAS = 'VOZ · 05 Alertas Verantia'
NOTIFICACIONES = 'VOZ · 04 Notificaciones'
ERROR_HTTP = '={{ ($json.error && ($json.error.message || $json.error.description)) || "sin detalle" }}'
flujos = []

# ═══ 01 · Inicio de llamada ════════════════════════════════════════════════
f = Flujo('VOZ · 01 Inicio de llamada')
webhook(f, 'Retell · inicio de llamada', 'verantia-voz/inicio', (0, 300))
codigo(f, 'Leer petición', 'leer_peticion.js', (220, 300))
rpc(f, 'Supabase · contexto del negocio', 'fn_voz_inbound',
    '={{ JSON.stringify({ p_raw: $json.p_raw, p_signature: $json.p_signature }) }}', (440, 300), timeout=4000)
campos(f, 'Supabase no responde', {'ok': False, 'codigo': 'SUPABASE_NO_RESPONDE'}, (660, 480))
codigo(f, 'Construir variables del agente', 'construir_variables.js', (880, 300))
si(f, '¿Firma válida?', '={{ $json.firma_valida }}', (1100, 300))
responder(f, 'Responder a Retell', (1320, 200), '={{ JSON.stringify($json.respuesta) }}')
responder(f, 'Rechazar (401)', (1320, 420), codigo_http=401)
si(f, '¿Arranca sin sistema?', '={{ $json.modo === "sin_sistema" }}', (1540, 200))
alerta(f, 'Datos de la alerta', f.nombre, '={{ $json.codigo }}', (1760, 200))
subflujo(f, 'Avisar a Verantia', ALERTAS, (1980, 200))
f.unir('Retell · inicio de llamada', 'Leer petición')
f.unir('Leer petición', 'Supabase · contexto del negocio')
f.unir('Supabase · contexto del negocio', 'Construir variables del agente', 0)
f.unir('Supabase · contexto del negocio', 'Supabase no responde', 1)
f.unir('Supabase no responde', 'Construir variables del agente')
f.unir('Construir variables del agente', '¿Firma válida?')
f.unir('¿Firma válida?', 'Responder a Retell', 0)
f.unir('¿Firma válida?', 'Rechazar (401)', 1)
f.unir('Responder a Retell', '¿Arranca sin sistema?')
f.unir('¿Arranca sin sistema?', 'Datos de la alerta', 0)
f.unir('Datos de la alerta', 'Avisar a Verantia')
flujos.append(f)

# ═══ 02 · Herramientas ═════════════════════════════════════════════════════
f = Flujo('VOZ · 02 Herramientas')
webhook(f, 'Retell · herramienta', 'verantia-voz/herramientas', (0, 300))
codigo(f, 'Leer petición', 'leer_peticion.js', (220, 300))
rpc(f, 'Supabase · ejecutar herramienta', 'fn_voz_tool',
    '={{ JSON.stringify({ p_raw: $json.p_raw, p_signature: $json.p_signature, p_tool: $json.p_tool, '
    'p_to: $json.p_to, p_from: $json.p_from, p_call_id: $json.p_call_id }) }}', (440, 300), timeout=4000)
si(f, '¿Firma válida?', '={{ $json.firma_valida }}', (660, 200))
responder(f, 'Responder al agente', (880, 100), '={{ JSON.stringify($json.agente) }}')
responder(f, 'Rechazar (401)', (880, 320), codigo_http=401)
responder(f, 'Responder error técnico', (660, 520),
          '={{ JSON.stringify({ codigo: "ERROR_TECNICO", mensaje: "Ha habido un problema técnico. '
          'Discúlpate, toma nota del motivo de la llamada y di que el equipo le llamará." }) }}')
si(f, '¿Hay que notificar?', '={{ !!$json.notificacion }}', (1100, 0))
subflujo(f, 'Enviar notificaciones', NOTIFICACIONES, (1320, 0))
si(f, '¿Error técnico?', '={{ $json.alerta === true }}', (1100, 200))
alerta(f, 'Datos de la alerta', f.nombre, '={{ "HERRAMIENTA_" + ($json.herramienta || "?") + "_ERROR_TECNICO" }}', (1320, 200))
alerta(f, 'Datos de la alerta (Supabase)', f.nombre, 'SUPABASE_NO_RESPONDE', (880, 520),
       detalle=ERROR_HTTP)
subflujo(f, 'Avisar a Verantia', ALERTAS, (1540, 300))
f.unir('Retell · herramienta', 'Leer petición')
f.unir('Leer petición', 'Supabase · ejecutar herramienta')
f.unir('Supabase · ejecutar herramienta', '¿Firma válida?', 0)
f.unir('Supabase · ejecutar herramienta', 'Responder error técnico', 1)
f.unir('¿Firma válida?', 'Responder al agente', 0)
f.unir('¿Firma válida?', 'Rechazar (401)', 1)
f.unir('Responder al agente', '¿Hay que notificar?')
f.unir('Responder al agente', '¿Error técnico?')
f.unir('¿Hay que notificar?', 'Enviar notificaciones', 0)
f.unir('¿Error técnico?', 'Datos de la alerta', 0)
f.unir('Datos de la alerta', 'Avisar a Verantia')
f.unir('Responder error técnico', 'Datos de la alerta (Supabase)')
f.unir('Datos de la alerta (Supabase)', 'Avisar a Verantia')
flujos.append(f)

# ═══ 03 · Fin de llamada ═══════════════════════════════════════════════════
f = Flujo('VOZ · 03 Fin de llamada')
webhook(f, 'Retell · eventos de llamada', 'verantia-voz/eventos', (0, 300), responder_al_recibir=True)
codigo(f, 'Leer petición', 'leer_peticion.js', (220, 300))
si(f, '¿Es call_analyzed?', '={{ $json.evento === "call_analyzed" }}', (440, 300))
rpc(f, 'Supabase · registrar llamada', 'fn_voz_event',
    '={{ JSON.stringify({ p_raw: $json.p_raw, p_signature: $json.p_signature }) }}', (660, 300),
    timeout=8000, reintentos=True)
si(f, '¿Avisar al negocio?', '={{ $json.avisar_negocio === true }}', (880, 200))
subflujo(f, 'Enviar notificaciones', NOTIFICACIONES, (1100, 200))
si(f, '¿Algo que revisar?', '={{ $json.ok !== true || $json.exceso_minutos === true }}', (880, 400))
alerta(f, 'Datos de la alerta', f.nombre,
       '={{ $json.ok !== true ? ($json.codigo || "ERROR") : "EXCESO_MINUTOS" }}', (1100, 400),
       detalle='={{ $json.ok === true ? ("minutos del mes: " + $json.minutos_mes + " de " + $json.minutos_incluidos) : "" }}')
alerta(f, 'Datos de la alerta (Supabase)', f.nombre, 'SUPABASE_NO_RESPONDE', (880, 600), detalle=ERROR_HTTP)
subflujo(f, 'Avisar a Verantia', ALERTAS, (1320, 500))
f.unir('Retell · eventos de llamada', 'Leer petición')
f.unir('Leer petición', '¿Es call_analyzed?')
f.unir('¿Es call_analyzed?', 'Supabase · registrar llamada', 0)
f.unir('Supabase · registrar llamada', '¿Avisar al negocio?', 0)
f.unir('Supabase · registrar llamada', '¿Algo que revisar?', 0)
f.unir('Supabase · registrar llamada', 'Datos de la alerta (Supabase)', 1)
f.unir('¿Avisar al negocio?', 'Enviar notificaciones', 0)
f.unir('¿Algo que revisar?', 'Datos de la alerta', 0)
f.unir('Datos de la alerta', 'Avisar a Verantia')
f.unir('Datos de la alerta (Supabase)', 'Avisar a Verantia')
flujos.append(f)

# ═══ 04 · Notificaciones ═══════════════════════════════════════════════════
f = Flujo(NOTIFICACIONES)
f.nodo('Desde otro flujo', 'n8n-nodes-base.executeWorkflowTrigger', 1, {}, (0, 300))
configuracion(f, (220, 300))
codigo(f, 'Preparar mensajes', 'preparar_mensajes.js', (440, 300))
f.nodo('Por canal', 'n8n-nodes-base.switch', 3.2, {
    'mode': 'expression', 'numberOutputs': 3,
    'output': '={{ ({ whatsapp: 0, sms: 1, email: 2 })[$json.canal] ?? 0 }}'}, (660, 300))
cfg = "$('Configuración').first().json"
f.nodo('Enviar WhatsApp', 'n8n-nodes-base.httpRequest', 4.2, {
    'method': 'POST',
    'url': f'={{{{ {cfg}.WHATSAPP_API_URL + "/" + {cfg}.WHATSAPP_API_VERSION + "/" + {cfg}.WHATSAPP_PHONE_NUMBER_ID + "/messages" }}}}',
    'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
    'sendBody': True, 'specifyBody': 'json',
    'jsonBody': "={{ JSON.stringify({ messaging_product: 'whatsapp', to: $json.destino.replace('+', ''), type: 'template', "
                "template: { name: $json.plantilla, language: { code: $json.idioma }, components: [{ type: 'body', "
                "parameters: $json.parametros.map(t => ({ type: 'text', text: t })) }] } }) }}",
    'options': {'timeout': 10000}}, (880, 100), onError='continueErrorOutput', credentials=CRED_WHATSAPP)
f.nodo('Enviar SMS', 'n8n-nodes-base.httpRequest', 4.2, {
    'method': 'POST',
    'url': f'={{{{ {cfg}.TWILIO_API_URL + "/2010-04-01/Accounts/" + {cfg}.TWILIO_ACCOUNT_SID + "/Messages.json" }}}}',
    'authentication': 'genericCredentialType', 'genericAuthType': 'httpBasicAuth',
    'sendBody': True, 'contentType': 'form-urlencoded',
    'bodyParameters': {'parameters': [
        {'name': 'To', 'value': '={{ $json.destino }}'},
        {'name': 'From', 'value': f'={{{{ {cfg}.SMS_REMITENTE }}}}'},
        {'name': 'Body', 'value': '={{ $json.texto }}'}]},
    'options': {'timeout': 10000}}, (1320, 300), onError='continueErrorOutput', credentials=CRED_TWILIO)
f.nodo('Enviar email', 'n8n-nodes-base.emailSend', 2.1, {
    'fromEmail': f'={{{{ {cfg}.EMAIL_REMITENTE }}}}', 'toEmail': '={{ $json.destino }}',
    'subject': '={{ $json.asunto }}', 'emailFormat': 'html', 'html': '={{ $json.html }}',
    'options': {'appendAttribution': False, 'replyTo': '={{ $json.responder_a }}'}},
    (880, 500), onError='continueErrorOutput', credentials=CRED_SMTP)
si(f, '¿Tiene SMS de respaldo?', "={{ !!$('Por canal').item.json.sms_respaldo }}", (1100, 180))
campos(f, 'SMS de respaldo', {'destino': "={{ $('Por canal').item.json.destino }}",
                              'texto': "={{ $('Por canal').item.json.sms_respaldo }}"}, (1100, 20))
campos(f, 'Datos de la alerta', {
    'origen': f.nombre, 'codigo': "={{ 'ENVIO_FALLIDO_' + ($('Por canal').item.json.canal || '?').toUpperCase() }}",
    'tenant_id': "={{ $('Por canal').item.json.tenant_id ?? '' }}",
    'call_id': "={{ $('Por canal').item.json.call_id ?? '' }}",
    'detalle': ERROR_HTTP}, (1540, 450))
subflujo(f, 'Avisar a Verantia', ALERTAS, (1760, 450))
f.unir('Desde otro flujo', 'Configuración')
f.unir('Configuración', 'Preparar mensajes')
f.unir('Preparar mensajes', 'Por canal')
f.unir('Por canal', 'Enviar WhatsApp', 0)
f.unir('Por canal', 'Enviar SMS', 1)
f.unir('Por canal', 'Enviar email', 2)
f.unir('Enviar WhatsApp', '¿Tiene SMS de respaldo?', 1)
f.unir('¿Tiene SMS de respaldo?', 'SMS de respaldo', 0)
f.unir('¿Tiene SMS de respaldo?', 'Datos de la alerta', 1)
f.unir('SMS de respaldo', 'Enviar SMS')
f.unir('Enviar SMS', 'Datos de la alerta', 1)
f.unir('Enviar email', 'Datos de la alerta', 1)
f.unir('Datos de la alerta', 'Avisar a Verantia')
flujos.append(f)

# ═══ 05 · Alertas Verantia ═════════════════════════════════════════════════
f = Flujo(ALERTAS)
f.nodo('Fallo en un flujo VOZ', 'n8n-nodes-base.errorTrigger', 1, {}, (0, 200))
f.nodo('Desde otro flujo', 'n8n-nodes-base.executeWorkflowTrigger', 1, {}, (0, 400))
configuracion(f, (220, 300))
codigo(f, 'Preparar alerta (sin datos personales)', 'preparar_alerta.js', (440, 300))
f.nodo('Enviar WhatsApp a Verantia', 'n8n-nodes-base.httpRequest', 4.2, {
    'method': 'POST',
    'url': f'={{{{ {cfg}.WHATSAPP_API_URL + "/" + {cfg}.WHATSAPP_API_VERSION + "/" + {cfg}.WHATSAPP_PHONE_NUMBER_ID + "/messages" }}}}',
    'authentication': 'genericCredentialType', 'genericAuthType': 'httpHeaderAuth',
    'sendBody': True, 'specifyBody': 'json',
    'jsonBody': "={{ JSON.stringify({ messaging_product: 'whatsapp', to: $json.destino.replace('+', ''), type: 'template', "
                "template: { name: $json.plantilla, language: { code: $json.idioma }, components: [{ type: 'body', "
                "parameters: $json.parametros.map(t => ({ type: 'text', text: t })) }] } }) }}",
    'options': {'timeout': 10000}}, (770, 220), onError='continueErrorOutput', credentials=CRED_WHATSAPP)
f.nodo('Email de respaldo a Verantia', 'n8n-nodes-base.emailSend', 2.1, {
    'fromEmail': f'={{{{ {cfg}.EMAIL_REMITENTE }}}}',
    'toEmail': "={{ $('Preparar alerta (sin datos personales)').item.json.email_respaldo }}",
    'subject': 'Alerta técnica · Verantia Voz', 'emailFormat': 'text',
    'text': "={{ $('Preparar alerta (sin datos personales)').item.json.texto }}",
    'options': {'appendAttribution': False}}, (990, 380), credentials=CRED_SMTP)
f.unir('Fallo en un flujo VOZ', 'Configuración')
f.unir('Desde otro flujo', 'Configuración')
f.unir('Configuración', 'Preparar alerta (sin datos personales)')
si(f, '¿Por WhatsApp?', '={{ $json.canal === "whatsapp" }}', (550, 300))
f.unir('Preparar alerta (sin datos personales)', '¿Por WhatsApp?')
f.unir('¿Por WhatsApp?', 'Enviar WhatsApp a Verantia', 0)
f.unir('¿Por WhatsApp?', 'Email de respaldo a Verantia', 1)
f.unir('Enviar WhatsApp a Verantia', 'Email de respaldo a Verantia', 1)
flujos.append(f)

# ═══ 06 · Vigilancia diaria ════════════════════════════════════════════════
f = Flujo('VOZ · 06 Vigilancia diaria')
f.nodo('Cada día a las 8:05', 'n8n-nodes-base.scheduleTrigger', 1.2,
       {'rule': {'interval': [{'field': 'days', 'daysInterval': 1, 'triggerAtHour': 8, 'triggerAtMinute': 5}]}}, (0, 300))
f.nodo('Probar ahora', 'n8n-nodes-base.executeWorkflowTrigger', 1, {}, (0, 480))
rpc(f, 'Supabase · estado del sistema', 'fn_voz_health', '={{ "{}" }}', (220, 300), timeout=10000, reintentos=True)
codigo(f, 'Evaluar', 'evaluar_salud.js', (440, 200))
alerta(f, 'Datos de la alerta (Supabase)', f.nombre, 'SUPABASE_NO_RESPONDE', (440, 420), detalle=ERROR_HTTP)
subflujo(f, 'Avisar a Verantia', ALERTAS, (660, 300))
f.unir('Cada día a las 8:05', 'Supabase · estado del sistema')
f.unir('Probar ahora', 'Supabase · estado del sistema')
f.unir('Supabase · estado del sistema', 'Evaluar', 0)
f.unir('Supabase · estado del sistema', 'Datos de la alerta (Supabase)', 1)
f.unir('Evaluar', 'Avisar a Verantia')
f.unir('Datos de la alerta (Supabase)', 'Avisar a Verantia')
flujos.append(f)

# ─── Escribir ──────────────────────────────────────────────────────────────
salida = Path(os.environ.get('VOZ_SALIDA', AQUI / 'flujos'))
salida.mkdir(exist_ok=True)
for fl in flujos:
    nombre_fichero = fl.nombre.replace('VOZ · ', 'VOZ_').replace(' · ', '_').replace(' ', '_') + '.json'
    (salida / nombre_fichero).write_text(json.dumps(fl.json(), ensure_ascii=False, indent=2) + '\n')
    print(f'{nombre_fichero}: {len(fl.nodos)} nodos')
