#!/usr/bin/env python3
"""Crea (o actualiza) en Retell el agente plantilla de Verantia Voz: el "LLM" (prompt + funciones)
y el agente de voz. Un solo agente sirve para todos los negocios (las variables llegan del flujo 01).

Uso:
  export RETELL_API_KEY=...                       # tu API key de Retell (no la guardes en ningún archivo)
  export N8N_URL=https://n8n.tudominio.com        # URL pública de tu n8n en Hostinger, sin barra final
  export VOICE_ID=...                             # voz elegida en Retell (castellano de España)
  python3 retell/crear_agente.py --mostrar        # solo enseña lo que enviaría, no crea nada
  python3 retell/crear_agente.py                  # crea LLM + agente y muestra sus ids
  python3 retell/crear_agente.py --actualizar-llm <llm_id>   # tras cambiar el prompt o las funciones
  python3 retell/crear_agente.py --cargar-variables-prueba <llm_id>   # SOLO pruebas: datos de la peluquería demo
  python3 retell/crear_agente.py --quitar-variables-prueba <llm_id>   # OBLIGATORIO antes de llamadas reales

Opcionales: MODELO (por defecto gpt-4.1-mini), GUARDADO_DATOS (por defecto everything_except_pii).
"""
import json
import os
from datetime import datetime, timedelta
import sys
import urllib.request
from pathlib import Path

AQUI = Path(__file__).parent
API = 'https://api.retellai.com'


def entorno(nombre, defecto=None, obligatorio=True):
    v = os.environ.get(nombre, defecto)
    if obligatorio and not v:
        sys.exit(f'Falta la variable de entorno {nombre}')
    return v


DIAS = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo']
MESES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto',
         'septiembre', 'octubre', 'noviembre', 'diciembre']


def fecha_larga(d):
    return f'{DIAS[d.weekday()]} {d.day} de {MESES[d.month - 1]} de {d.year}'


def variables_prueba_de_hoy():
    """Variables de la peluquería demo con la fecha de HOY (la del ordenador).
    El archivo guarda los datos del negocio; la fecha y el calendario se recalculan cada vez,
    para que "mañana" sea siempre mañana. (En llamadas reales las calcula el flujo 01 en cada llamada.)"""
    v = json.loads((AQUI / 'variables_prueba_web.json').read_text(encoding='utf-8'))
    ahora = datetime.now()
    hoy = ahora.date()
    v['fecha_hoy'] = f'{fecha_larga(hoy)}, son las {ahora:%H:%M}'
    v['fecha_hoy_iso'] = hoy.isoformat()
    lineas = []
    for i in range(30):
        d = hoy + timedelta(days=i)
        prefijo = 'hoy, ' if i == 0 else 'mañana, ' if i == 1 else ''
        lineas.append(f'{prefijo}{fecha_larga(d)} = {d.isoformat()}')
    v['calendario'] = '\n'.join(lineas)
    return v


def cuerpo_llm(n8n_url):
    herramientas = json.loads((AQUI / 'herramientas.json').read_text(encoding='utf-8').replace('{{N8N_URL}}', n8n_url.rstrip('/')))
    return {
        'model': entorno('MODELO', 'gpt-4.1-mini'),
        'model_temperature': 0.2,                      # respuestas estables: es atención al cliente, no creatividad
        'start_speaker': 'agent',
        'begin_message': '{{saludo_inicial}}',        # aviso de IA + primera capa de privacidad
        'general_prompt': (AQUI / 'prompt_agente.md').read_text(encoding='utf-8'),
        'general_tools': herramientas,
    }


def cuerpo_agente(llm_id, n8n_url):
    return {
        'agent_name': 'Verantia Voz · plantilla',
        'response_engine': {'type': 'retell-llm', 'llm_id': llm_id},
        'voice_id': entorno('VOICE_ID'),
        'language': 'es-ES',
        'webhook_url': f'{n8n_url.rstrip("/")}/webhook/verantia-voz/eventos',
        'webhook_events': ['call_analyzed'],
        # RGPD: por defecto Retell lo guarda TODO (incluida la grabación). Aquí, sin datos personales.
        'data_storage_setting': entorno('GUARDADO_DATOS', 'everything_except_pii'),
        'interruption_sensitivity': 0.8,
        'responsiveness': 0.9,
        'enable_backchannel': True,
        'max_call_duration_ms': 600000,               # 10 min: evita llamadas colgadas y costes
        'end_call_after_silence_ms': 30000,
        'boosted_keywords': ['cita', 'reserva', 'anular', 'cambiar', 'mechas', 'balayage', 'tinte',
                             'corte', 'peinado', 'manicura', 'pedicura', 'depilación', 'comensales'],
    }


def llamar(metodo, ruta, cuerpo):
    req = urllib.request.Request(f'{API}{ruta}', method=metodo, data=json.dumps(cuerpo).encode(),
                                 headers={'Authorization': f'Bearer {entorno("RETELL_API_KEY")}',
                                          'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        sys.exit(f'Retell respondió {e.code}: {e.read().decode()[:500]}')


def main():
    args = sys.argv[1:]
    if any(a in args for a in ('--cargar-variables-prueba', '--quitar-variables-prueba')):
        n8n_url = 'https://sin-uso'
    else:
        n8n_url = entorno('N8N_URL')
    if not n8n_url.startswith('https://'):
        sys.exit('N8N_URL debe empezar por https:// (Retell no llama a direcciones sin cifrar)')

    if '--mostrar' in args:
        print(json.dumps({'llm': cuerpo_llm(n8n_url), 'agente': cuerpo_agente('<llm_id>', n8n_url)},
                         ensure_ascii=False, indent=2))
        return

    if '--cargar-variables-prueba' in args or '--quitar-variables-prueba' in args:
        cargar = '--cargar-variables-prueba' in args
        llm_id = args[args.index('--cargar-variables-prueba' if cargar else '--quitar-variables-prueba') + 1]
        # Retell usa estas variables solo si la llamada no trae las suyas (p. ej. en las pruebas del panel).
        # En llamadas reales las pone el flujo 01; aun así hay que QUITARLAS antes de atender clientes,
        # para que un fallo del flujo 01 nunca haga que el agente hable con datos de la peluquería demo.
        variables = variables_prueba_de_hoy() if cargar else {}
        llamar('PATCH', f'/update-retell-llm/{llm_id}', {'default_dynamic_variables': variables})
        print(f'Variables de prueba {"cargadas" if cargar else "quitadas"} en el LLM {llm_id}.')
        if cargar:
            print(f'Fecha usada: hoy es {variables["fecha_hoy_iso"]}. Si pruebas otro día, vuelve a ejecutar este comando.')
        return

    if '--actualizar-llm' in args:
        llm_id = args[args.index('--actualizar-llm') + 1]
        llamar('PATCH', f'/update-retell-llm/{llm_id}', cuerpo_llm(n8n_url))
        print(f'LLM {llm_id} actualizado (prompt y funciones).')
        return

    llm = llamar('POST', '/create-retell-llm', cuerpo_llm(n8n_url))
    agente = llamar('POST', '/create-agent', cuerpo_agente(llm['llm_id'], n8n_url))
    print(f"LLM creado:    {llm['llm_id']}")
    print(f"Agente creado: {agente['agent_id']}")
    print('Siguiente paso: asigna este agente a tu número en Retell y pon como "inbound webhook" '
          f'{n8n_url.rstrip("/")}/webhook/verantia-voz/inicio')


if __name__ == '__main__':
    main()
