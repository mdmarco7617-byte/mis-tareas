# Verantia Voz — Flujos de n8n

Probados de extremo a extremo con **n8n 2.22.5** (tu versión): n8n real + llamadas firmadas como las de Retell + base de datos real + simuladores de WhatsApp, Twilio y SMTP (`tests/e2e/ejecutar_e2e.sh`, 28/28).

Todos los flujos empiezan por **`VOZ ·`** y no tocan nada del chatbot web.

| Flujo | Qué hace | Se activa con |
|---|---|---|
| `VOZ · 01 Inicio de llamada` | Identifica el negocio por el número llamado y prepara las variables del agente (saludo con aviso de IA y privacidad, horario, catálogo, calendario, cliente conocido…) | Webhook `POST /webhook/verantia-voz/inicio` (Retell: *inbound call webhook*) |
| `VOZ · 02 Herramientas` | Ejecuta las 7 herramientas (disponibilidad, huecos, crear, buscar, anular, cambiar, derivar). Responde al agente en < 1 s y **después** lanza las notificaciones | Webhook `POST /webhook/verantia-voz/herramientas` (Retell: *custom functions*) |
| `VOZ · 03 Fin de llamada` | Registra duración y resultado; si la llamada no se resolvió, avisa al negocio; vigila el exceso de minutos del plan | Webhook `POST /webhook/verantia-voz/eventos` (Retell: *agent webhook*, evento `call_analyzed`) |
| `VOZ · 04 Notificaciones` | WhatsApp al cliente (SMS si WhatsApp falla), email si lo dio, WhatsApp al negocio | Subflujo |
| `VOZ · 05 Alertas Verantia` | WhatsApp a ti (email si falla) **sin datos personales**, sin repetir la misma alerta en 10 min | Subflujo + *error workflow* de los demás |
| `VOZ · 06 Vigilancia diaria` | A las 8:05 revisa errores, llamadas y que la purga RGPD siga activa. Solo avisa si hay algo | Programado (y "Probar ahora") |

## Seguridad (resumen)
- **La firma de Retell se verifica en Supabase** con la API key guardada cifrada en Supabase Vault. En n8n no hay ninguna clave de Retell. Firma falsa, cuerpo alterado o firma de hace más de 5 minutos → rechazado (401).
- El negocio se decide por el número llamado, nunca por lo que diga la IA.
- **A la IA solo le vuelve lo necesario para hablar**: sin teléfonos, emails ni ids internos (probado).
- Si Supabase no responde, el agente recibe `ERROR_TECNICO` (nunca silencio) y tú recibes una alerta.

---

## Instalación paso a paso

### 1. Supabase (una vez)
En el SQL Editor del proyecto **verantia-voz**:
```sql
select vault.create_secret('<TU API KEY DE RETELL>', 'retell_api_key');
```
(Usa la API key de Retell marcada con el distintivo *webhook*.) No la pegues en n8n ni la compartas por chat.

### 2. Credenciales en n8n
Crea estas (los nombres exactos ayudan a que n8n las asocie solas al importar). Ahora mismo bastan **Supabase** y **SMTP (Resend)**; WhatsApp y Twilio, cuando actives las confirmaciones:

| Nombre | Tipo en n8n | Datos |
|---|---|---|
| `Supabase · Verantia Voz` | Header Auth | Name: `apikey` · Value: la **secret key** del proyecto (Project Settings → API Keys, empieza por `sb_secret_`). ⚠️ Nunca la *publishable/anon* key |
| `WhatsApp · Verantia` | Header Auth | Name: `Authorization` · Value: `Bearer <token permanente de la app de Meta>` |
| `Twilio · Verantia` | Basic Auth | User: Account SID · Password: Auth Token |
| `SMTP · Verantia` | SMTP | **Resend**: host `smtp.resend.com`, puerto 465, SSL activado, usuario `resend`, contraseña = tu API key de Resend |

### 3. Importar
1. En n8n: *Create workflow → ⋯ → Import from file*, uno a uno, **en este orden**: 05, 04, 06, 01, 02, 03 (así los subflujos existen cuando importas los que los llaman).
2. En cada nodo con credencial, **elige tú la credencial correspondiente, aunque ya aparezca una puesta**. Al importar, n8n puede enlazar solo cualquier credencial existente del mismo tipo (por ejemplo, otra *Header Auth* del chatbot) y enviarle a Supabase una clave que no es. Nodos a revisar: `Supabase · …` en los flujos 01, 02, 03 y 06 (credencial `Supabase · Verantia Voz`); `Enviar WhatsApp`, `Enviar SMS` y `Enviar email` en el 04; `Enviar WhatsApp a Verantia` y `Email de respaldo a Verantia` en el 05.
3. En los nodos **"Avisar a Verantia"** y **"Enviar notificaciones"**, elige el flujo `VOZ · 05 Alertas Verantia` / `VOZ · 04 Notificaciones` en la lista.
4. En `VOZ · 04` y `VOZ · 05`, abre el nodo **Configuración**:
   - **Interruptores** `WHATSAPP_ACTIVO`, `SMS_ACTIVO`, `EMAIL_ACTIVO` (`sí`/`no`). Vienen en `no`: un canal sin configurar no se usa ni genera alertas. Las confirmaciones se activan al final del proyecto.
   - Con WhatsApp apagado, **tus alertas técnicas llegan por email** a `EMAIL_VERANTIA` (Resend). Con solo el email encendido, los avisos al negocio también van por email (a `tenants.email_avisos`).
   - Rellena `EMAIL_REMITENTE` (un dominio verificado en Resend) y `EMAIL_VERANTIA`; el resto (`WHATSAPP_*`, `TWILIO_*`) cuando llegue su momento.
5. En *Settings* de los flujos 01, 02, 03, 04 y 06 → **Error workflow: `VOZ · 05 Alertas Verantia`**.
6. Comprueba en *Settings* de cada flujo que sigue: *Save successful production executions: **Do not save*** (viene así; es un requisito RGPD, ver abajo).
7. **Publica** (activa) los 6 flujos.

### 4. Variables de entorno de n8n (RGPD)
n8n guarda las ejecuciones **fallidas** para poder depurarlas, y pueden contener nombres o teléfonos. Que se borren solas a los 7 días:
```
EXECUTIONS_DATA_PRUNE=true
EXECUTIONS_DATA_MAX_AGE=168
EXECUTIONS_DATA_PRUNE_MAX_COUNT=5000
GENERIC_TIMEZONE=Europe/Madrid
```

### 5. n8n tiene que ser accesible desde Internet (HTTPS)
Retell llama a tus webhooks desde su nube. Un n8n en tu ordenador **no sirve para producción**: tiene que estar encendido siempre y tener una URL pública con HTTPS.
- **Para pruebas** (solo con los negocios demo, sin datos reales): un túnel (p. ej. Cloudflare Tunnel) hacia tu n8n local.
- **Para clientes reales**: n8n en un servidor en la UE (p. ej. Hetzner Alemania, ~5–10 €/mes) con HTTPS, disco cifrado y copias de seguridad. Ver `docs/asistente-telefonico-ia/RGPD.md`.

---

## Configuración en Retell

### Número de teléfono
- *Inbound call webhook URL*: `https://<tu-n8n>/webhook/verantia-voz/inicio`

### Agente (plantilla única para todos los negocios)
- *Begin message*: `{{saludo_inicial}}` (lleva el aviso de IA y la primera capa de privacidad).
- *Webhook URL* del agente: `https://<tu-n8n>/webhook/verantia-voz/eventos`, solo con el evento **`call_analyzed`**.
- *Post-call analysis*: activado (genera `call_summary` y `call_successful`).
- **Privacidad** (obligatorio, RGPD): desactivar el almacenamiento de grabaciones y usar la opción de almacenamiento de datos más restrictiva que ofrezca Retell ("no guardar PII / solo atributos básicos"). Revisar el plazo de retención de Retell y que el DPA esté aceptado.
- *Transfer call*: destino `{{telefono_transferencia}}`.
- El **prompt** (instrucciones del agente) va en la siguiente entrega; usa las variables de la tabla de abajo.

### Las 7 funciones (custom functions)
Para todas:
- URL: `https://<tu-n8n>/webhook/verantia-voz/herramientas` · método POST
- **Payload: args only** activado (así la transcripción no sale de Retell: minimización)
- Timeout: 8000 ms · Reintentos: 1 (la idempotencia evita citas duplicadas)
- Cabeceras:

| Cabecera | Valor |
|---|---|
| `x-herramienta` | el nombre de la función (`check_availability`, `create_appointment`…) |
| `x-numero-negocio` | `{{numero_negocio}}` |
| `x-numero-llamante` | `{{numero_llamante}}` |
| `x-id-llamada` | `{{id_llamada}}` |

Parámetros de cada función: ver `docs/asistente-telefonico-ia/CONTRATO_HERRAMIENTAS.md` §3.

### Variables dinámicas disponibles para el prompt
`saludo_inicial`, `modo_servicio` (`normal` / `sin_sistema`), `nombre_negocio`, `nombre_asistente`, `tipo_negocio`, `descripcion_negocio`, `direccion`, `telefono_negocio`, `fecha_hoy`, `fecha_hoy_iso`, `calendario` (30 días con su fecha AAAA-MM-DD), `horario`, `festivos_y_cierres`, `catalogo` (con los códigos de servicio), `profesionales`, `faq`, `politica_cancelacion`, `antelacion_minima`, `es_restaurante`, `max_comensales`, `cliente_conocido`, `puede_transferir`, `telefono_transferencia`, `numero_negocio`, `numero_llamante`, `id_llamada`.

---

## Plantillas de WhatsApp (dar de alta en Meta Business, categoría **Utilidad**, idioma español)
Meta exige que una plantilla no empiece ni termine con una variable, y las revisa antes de aprobarlas (suele tardar minutos u horas). Los nombres deben coincidir con los del nodo Configuración.

**`verantia_cita_confirmada`** (7 variables)
> Hola {{1}}, tu cita en {{2}} está confirmada: {{3}}, el {{4}}. Tu referencia es {{5}}. Si necesitas cambiarla o anularla, llama al {{6}}. Información sobre protección de datos: {{7}}. Gracias.

**`verantia_cita_modificada`** (7 variables)
> Hola {{1}}, tu cita en {{2}} ha cambiado: {{3}}, ahora el {{4}}. Tu referencia es {{5}}. Para cualquier otro cambio, llama al {{6}}. Información sobre protección de datos: {{7}}. Gracias.

**`verantia_cita_anulada`** (5 variables)
> Hola {{1}}, tu cita en {{2}} ({{3}}, {{4}}) ha quedado anulada. Si quieres pedir otra, llama al {{5}}. Gracias.

**`verantia_aviso_negocio`** (4 variables)
> Aviso para {{1}}. {{2}}: {{3}}. {{4}}. Mensaje automático de tu asistente telefónico.

**`verantia_alerta_tecnica`** (3 variables)
> Alerta técnica de Verantia Voz. Origen: {{1}}. Código: {{2}}. Detalle: {{3}}. Revisa el sistema.

---

## Limitaciones conocidas (para una siguiente iteración)
- **SMS de respaldo**: se envía cuando WhatsApp rechaza el envío en el momento. Si el número no tiene WhatsApp, Meta a veces lo acepta y avisa del fallo **más tarde** por su webhook de estados; para cubrir ese caso hará falta un flujo que reciba esos estados. Mientras tanto, el negocio recibe siempre su aviso de cada cita.
- El resumen de "llamada no resuelta" lo genera Retell; conviene revisar en las primeras semanas que es útil para el negocio.

## Desarrollo
- Código de los nodos Code: `src/*.js` → `python3 construir_flujos.py` genera `flujos/*.json`. **No edites los JSON a mano**: edita `src/` y regenera.
- Pruebas: `node tests/probar_codigo.mjs` (código) · `tests/e2e/ejecutar_e2e.sh` (n8n real de extremo a extremo; necesita el Postgres local de `supabase/tests`).
