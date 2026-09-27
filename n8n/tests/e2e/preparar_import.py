#!/usr/bin/env python3
"""SOLO pruebas: toma los flujos generados y les pone ids fijos, credenciales de prueba y los
enlaces entre subflujos (en tu n8n eso lo eliges tú al importar). Escribe también las credenciales."""
import json
import sys
from pathlib import Path

origen, destino = Path(sys.argv[1]), Path(sys.argv[2])
destino.mkdir(parents=True, exist_ok=True)

IDS = {'VOZ · 01 Inicio de llamada': 'vozInicio0000001', 'VOZ · 02 Herramientas': 'vozHerram0000002',
       'VOZ · 03 Fin de llamada': 'vozFinLlam000003', 'VOZ · 04 Notificaciones': 'vozNotif00000004',
       'VOZ · 05 Alertas Verantia': 'vozAlertas000005', 'VOZ · 06 Vigilancia diaria': 'vozVigila0000006'}
CREDS = {
    'Supabase · Verantia Voz': ('credSupabase0001', 'httpHeaderAuth', {'name': 'apikey', 'value': 'clave-prueba'}),
    'WhatsApp · Verantia': ('credWhatsapp0001', 'httpHeaderAuth', {'name': 'Authorization', 'value': 'Bearer token-whatsapp-prueba'}),
    'Twilio · Verantia': ('credTwilio000001', 'httpBasicAuth', {'user': 'ACprueba', 'password': 'token-twilio-prueba'}),
    'SMTP · Verantia': ('credSmtp00000001', 'smtp', {'user': '', 'password': '', 'host': '127.0.0.1', 'port': 2525,
                                                    'secure': False, 'disableStartTls': True}),
}

for p in sorted(origen.glob('*.json')):
    w = json.loads(p.read_text())
    w['id'] = IDS[w['name']]
    w['active'] = True
    w['settings']['errorWorkflow'] = IDS['VOZ · 05 Alertas Verantia']
    for n in w['nodes']:
        for tipo, ref in (n.get('credentials') or {}).items():
            ref['id'] = CREDS[ref['name']][0]
        if n['type'] == 'n8n-nodes-base.executeWorkflow':
            n['parameters']['workflowId']['value'] = IDS[n['parameters']['workflowId']['cachedResultName']]
    (destino / p.name).write_text(json.dumps(w, ensure_ascii=False, indent=2))

(destino.parent / 'credenciales.json').write_text(json.dumps(
    [{'id': i, 'name': n, 'type': t, 'data': d} for n, (i, t, d) in CREDS.items()], ensure_ascii=False, indent=2))
print(f'{len(IDS)} flujos y {len(CREDS)} credenciales de prueba preparados en {destino.parent}')
