# Verantia Voice — Asistente telefónico con IA para negocios locales (Valladolid)

> Documento de proyecto v1 · 27/09/2026
> Alcance: recepcionista telefónica con IA, multi-tenant, para restaurantes, centros de estética, peluquerías, academias, clínicas no sanitarias, etc.
> Backend: n8n + Supabase. Servicio de voz/telefonía: a decidir (este documento lo evalúa y recomienda).

---

## 0. Resumen ejecutivo

| Pregunta | Respuesta corta |
|---|---|
| ¿Es viable? | **Sí, totalmente.** La tecnología de voz en tiempo real en español ya es madura (latencia < 1 s, voces de España naturales). Para conversaciones acotadas (precios, horarios, reservas) el porcentaje de llamadas resueltas sin humano suele estar en el 70–90 %. |
| Proveedor de voz recomendado | **Retell AI** (1ª opción) · **ElevenLabs Agents** (2ª, mejor voz, algo menos maduro en telefonía/herramientas) · Vapi solo si necesitas control extremo. |
| Dónde vive el conocimiento del negocio | **En Supabase**, inyectado al inicio de cada llamada (no en la base de conocimiento del proveedor). Te explico por qué en el §4. |
| Doble comprobación de disponibilidad | Sí: 1ª en `check_availability`, 2ª **atómica** dentro de `create_appointment` + restricción de base de datos que hace **imposible** el doble booking. |
| Tiempo hasta MVP en producción (1 persona) | **5–7 semanas** con dedicación completa; 9–12 a media jornada. Alta de cada cliente nuevo después: 2–4 h. |
| Coste variable | ~0,11–0,16 €/min todo incluido. Una llamada media (2,5 min) ≈ 0,30–0,40 €. |
| Precio de mercado recomendado | Alta 390–790 € + cuota 149–399 €/mes según minutos. Margen bruto objetivo 60–75 %. |

---

## 1. Qué hace el asistente (alcance funcional MVP)

1. **Atiende** llamadas entrantes con voz natural (castellano de España), identificándose como asistente de IA.
2. **Responde FAQs**: precios, horarios, servicios/tratamientos, menús, ubicación, parking, formas de pago, política de cancelación.
3. **Consulta disponibilidad** (hora concreta o "¿qué tenéis el jueves?").
4. **Crea citas/reservas** con doble comprobación.
5. **Modifica y anula** citas (identificando al cliente por su número de teléfono + nombre).
6. **Envía confirmación** por email (y opcionalmente WhatsApp/SMS — ver §6.4, lo recomiendo).
7. **Deriva a humano** si el cliente lo pide o si el asistente lo considera necesario: transferencia de la llamada en horario, o mensaje al WhatsApp del negocio con resumen + transcripción.
8. **Avisa a Verantia** por WhatsApp si algo técnico falla.
9. **Cumple RGPD/LOPDGDD y AI Act** (aviso de IA, información de protección de datos, minimización, retención limitada).

Fuera del MVP (fase 2): llamadas salientes (recordatorios), cobro de señales, integración con software de agenda de terceros (Booksy, Treatwell, CoverManager…), panel web propio para el negocio.

---

## 2. Evaluación de proveedores de voz

Criterios: calidad de voz en español de España, latencia/naturalidad de turnos, fiabilidad llamando a herramientas (function calling), facilidad técnica, coste, soporte multi-tenant por API, números españoles, transferencia de llamada, cumplimiento RGPD.

| Proveedor | Voz ES-ES | Latencia / turnos | Herramientas + n8n | Facilidad | Coste real €/min* | Multi-tenant | Veredicto |
|---|---|---|---|---|---|---|---|
| **Retell AI** | Muy buena (voces ElevenLabs/Cartesia/OpenAI integradas) | Excelente, el mejor manejo de interrupciones | Custom functions → webhook n8n; webhook de llamada entrante para variables dinámicas; post-call analysis | Alta | 0,11–0,15 | API sólida, un agente plantilla + variables por negocio | ⭐ **Recomendado** |
| **ElevenLabs Agents** | La mejor del mercado | Muy buena | Server tools → webhook; "conversation initiation webhook" | Alta | 0,08–0,12 + LLM (hoy en parte absorbido) + telefonía | Buena | 2ª opción. Elegir si la voz es el argumento de venta nº1 |
| **Vapi** | Buena (eliges proveedor) | Buena, pero requiere afinar | Muy flexible | Media (muchas piezas: STT+LLM+TTS+telefonía a configurar) | 0,12–0,24 (+ concurrencia extra) | Buena | Solo si necesitas control total; más horas de ajuste |
| Synthflow / similares no-code | Correcta | Correcta | Limitada | Muy alta | 0,15–0,30 | Pensado para agencias (white label) | Más caro y menos control; no aprovecha tu n8n |
| Bland AI | Enfocado a EE. UU. | Buena | Buena | Media | 0,09–0,15 | Sí | No lo recomiendo para ES |
| Hacerlo tú (Twilio/LiveKit/Pipecat + OpenAI Realtime) | Buena | Depende de ti | Total | **Baja** | 0,06–0,12 | Tú lo construyes | No para empezar: meses de trabajo y mantenimiento |

\* Coste orientativo a septiembre 2026, incluyendo voz + LLM + telefonía. **Verificar precios en el momento de contratar**, cambian cada pocos meses.

### Por qué Retell como 1ª opción
- Es el que mejor resuelve lo **difícil** de la voz (turnos, interrupciones, silencios, "ehh…") sin que tengas que afinarlo.
- Patrón perfecto para multi-tenant: **un único agente plantilla** con variables dinámicas (`{{nombre_negocio}}`, `{{servicios}}`…) que se rellenan en el webhook de llamada entrante según el número llamado. Mantienes 1 prompt, no 50.
- Transferencia de llamada (fría/cálida) nativa, análisis post-llamada (resumen, sentimiento, "¿se resolvió?") y webhooks firmados.
- Puedes usar las voces de ElevenLabs dentro de Retell, así que no renuncias a la mejor voz.

### Cuándo cambiaría a ElevenLabs
Si en las pruebas con clientes reales la voz de Retell se percibe "robótica" frente a ElevenLabs, o si ElevenLabs consolida su precio con LLM incluido por debajo de 0,10 €/min. **La arquitectura propuesta es agnóstica**: el backend n8n+Supabase no cambia; solo cambia la capa de voz (1–2 días de migración).

### Telefonía (números)
- **Estrategia recomendada: el negocio conserva su número** y activa un **desvío** (si no contesta en X tonos / si comunica / fuera de horario / siempre) hacia un número de Verantia asignado a ese negocio.
- Números: españoles (geográfico 983 de Valladolid o móvil virtual) vía **Twilio o Telnyx** importados en Retell (requieren expediente regulatorio con dirección en España, 1–5 días), o un operador SIP español (p. ej. Zadarma) por SIP trunk. Coste: 1–5 €/mes por número.
- ⚠️ Trampa habitual: si el negocio desvía **siempre** su número al asistente, la transferencia a humano **no puede volver a ese mismo número** (bucle). Hay que transferir a un **móvil del encargado** o usar desvío "si no contesta".

---

## 3. Arquitectura

```
Cliente llama al 983 xxx xxx (número del negocio)
        │  desvío
        ▼
Número Verantia (Twilio/Telnyx) ──► Retell AI (STT + LLM + TTS, voz natural)
                                     │
   1) Webhook "inbound call" ────────┼──► n8n: identifica tenant por número llamado
                                     │        → Supabase: config, servicios, FAQ, horario
                                     │        ← variables dinámicas del prompt
   2) Custom functions (durante la llamada, < 1,5 s)
        check_availability ──────────┼──► n8n ─► Supabase RPC (SQL)
        get_available_slots ─────────┤
        create_appointment ──────────┤    (2ª comprobación atómica)
        find_appointments ───────────┤
        cancel_appointment ──────────┤
        reschedule_appointment ──────┤
        escalate_to_human ───────────┤──► WhatsApp negocio
        transfer_call (nativa) ──────┘
   3) Webhook "call ended / analyzed" ──► n8n: log RGPD-minimizado, email/WhatsApp confirmación,
                                            alertas, métricas de uso para facturación
n8n Error Trigger global ──► WhatsApp de Verantia
```

### Principios clave
1. **El LLM de la conversación vive en Retell**, no en n8n. En tu chatbot web el "AI Agent" de n8n pensaba y respondía; en voz eso añadiría 1–3 s de latencia por turno y la llamada sonaría mal. Aquí n8n es **backend de herramientas**, rápido y determinista.
2. **La lógica de disponibilidad va en SQL (funciones RPC de Supabase)**, no en nodos Code de n8n: es más rápido (< 100 ms), transaccional y reutilizable por el chatbot web.
3. **El `tenant_id` nunca lo decide el LLM.** Se obtiene del número llamado (metadatos de la llamada) y n8n lo resuelve en cada herramienta a partir del `call_id`. Así un cliente no puede "convencer" al asistente de consultar la agenda de otro negocio.
4. **Una única plantilla de agente** + variables por negocio. Personalizaciones puntuales (voz, nombre del asistente, tono) como campos de configuración.

### Qué reaprovechas de tu workflow del chatbot
| Pieza del chatbot | ¿Se reutiliza? |
|---|---|
| `Build System Prompt` (calendario 30 días, horario, tratamientos, FAQ, reglas de recogida de datos, códigos DISPONIBLE/OCUPADO…) | **Sí**, casi entero, adaptado a voz (frases cortas, sin emojis, números en palabras, confirmar leyendo en voz alta). Pasa a ser el webhook de llamada entrante. |
| Subworkflows `CHECK AVAILABILITY`, `GET AVAILABLE SLOTS`, `CREATE APPOINTMENT` | **La lógica sí**, pero migrada a funciones SQL en Supabase y expuestas por webhooks n8n. Los mismos códigos de respuesta (el prompt ya los entiende). |
| Validación de `business_id`, comparación segura de API key, sanitización | Sí (adaptado: firma HMAC de Retell en vez de API key). |
| Logs en Airtable | **No** → Supabase (UE) con minimización. |
| Memoria `Simple Memory` | No aplica en voz (el proveedor mantiene el contexto de la llamada). |

**Recomendación extra**: migrar también el chatbot web a este mismo backend Supabase. Tendrás **un único backend para dos canales** (web y teléfono) y un negocio puede contratar ambos.

### Cosas a corregir en el workflow actual del chatbot (te lo digo porque lo pediste)
1. **`Simple Memory` (buffer en memoria)**: se pierde al reiniciar n8n y no funciona en modo cola/multi-worker. → Usa *Postgres Chat Memory* sobre Supabase.
2. **Logs con datos personales en Airtable** (servidores en EE. UU.) sin política de retención → problema RGPD. → Supabase región UE + borrado automático.
3. **La sanitización elimina comillas, paréntesis y `;`**: no protege frente a *prompt injection* (eso lo hace el prompt de seguridad + que el tenant no lo controle el LLM) y estropea textos legítimos. Mejor: limitar longitud, quitar caracteres de control y validar estrictamente los **parámetros de las herramientas** (fechas, horas, email), que es donde está el riesgo real.
4. **API key en el widget web**: en el navegador no es secreta; la protección real es `dominio_permitido`, pero si ese campo está vacío se acepta cualquier origen. → Hacerlo obligatorio y añadir *rate limiting* por IP/sesión.
5. **Respuesta de éxito con `Access-Control-Allow-Origin: *`** mientras la de 401 usa el dominio permitido: incoherente. → Usar siempre el dominio del negocio.
6. **Sin alertas**: los errores se registran pero nadie se entera. → Error Trigger + WhatsApp (igual que en voz).
7. **Crear cita sin idempotencia**: si el agente reintenta la herramienta puedes duplicar la cita. → `idempotency_key` + restricción única.

---

## 4. ¿Conocimiento del negocio en el proveedor de voz o en tu backend?

| Opción | Pros | Contras |
|---|---|---|
| A. Knowledge Base del proveedor (RAG de Retell/ElevenLabs) | Rápido de montar; bueno para documentos largos (cartas extensas, PDFs) | Recupera *fragmentos* (puede fallar con precios exactos); datos duplicados fuera de tu control; cambiar un precio = subir documentos otra vez; *vendor lock-in*; un proveedor más tratando datos |
| **B. Supabase → inyectado en el prompt al inicio de la llamada** ⭐ | Una sola fuente de verdad para web y teléfono; el negocio (o tú) edita un precio y se aplica en la siguiente llamada; información completa y exacta en contexto (sin fallos de recuperación); migrar de proveedor es trivial | Hay que construir el webhook de inicio (ya lo tienes casi hecho: es tu `Build System Prompt`) |
| C. Híbrido | B para lo estructurado + A para documentos largos opcionales | Algo más de complejidad |

**Recomendación: B, y C solo si un cliente tiene muchísimo contenido.** Un negocio pequeño cabe entero en 2.000–5.000 tokens (servicios, precios, horarios, 20–40 FAQs); meterlo todo en el prompt es más preciso que RAG y no añade latencia. Además, con *prompt caching* del LLM el coste extra es mínimo.

---

## 5. Modelo de datos (Supabase, región UE)

Tablas principales (todas con `tenant_id` y **RLS activado**; n8n accede con `service_role` guardada como credencial, nunca expuesta):

- `tenants` — negocio: nombre, tipo (`estetica`, `peluqueria`, `restaurante`, `academia`), zona horaria, nombre del asistente, voz, tono, teléfono de transferencia, WhatsApp del negocio, email, política de cancelación, textos RGPD, `activo`, plan contratado.
- `phone_numbers` — número Verantia (E.164) → `tenant_id` (clave para identificar el negocio en cada llamada).
- `services` — nombre, sinónimos (para que "mechas" encuentre "balayage"), precio, duración, bonos, activo.
- `resources` — profesional, cabina, sala o mesa; con `capacidad` (restaurantes: comensales; academias: plazas).
- `resource_services` — qué recurso puede hacer qué servicio.
- `business_hours` — franjas por día de la semana (y por recurso si aplica).
- `closures` — cierres, vacaciones, festivos (precargar nacionales, Castilla y León y locales de Valladolid: 13 de mayo San Pedro Regalado, 8 de septiembre Virgen de San Lorenzo).
- `faqs` — pregunta/respuesta, categoría, orden.
- `customers` — teléfono (E.164), nombre, email opcional; mínimo imprescindible.
- `appointments` — `tenant_id`, `resource_id`, `service_id`, `customer_id`, `tstzrange(inicio, fin)`, estado (`confirmada`, `cancelada`, `modificada`), `canal` (`telefono`/`web`), `idempotency_key`.
  - **Restricción de exclusión** (`btree_gist`): `EXCLUDE USING gist (resource_id WITH =, periodo WITH &&) WHERE (estado = 'confirmada')` → la base de datos **rechaza** dos citas solapadas en el mismo recurso aunque lleguen a la vez.
  - Para restaurantes/academias (capacidad): función con bloqueo `SELECT … FOR UPDATE` que suma comensales en la franja antes de insertar.
- `calls` — `call_id`, tenant, inicio/fin, duración (facturación), resultado, `escalada`, resumen corto; **transcripción con caducidad** (ver §7).
- `events_log` / `errors` — trazas técnicas sin datos personales.

Funciones RPC (SQL/plpgsql): `check_availability`, `get_available_slots`, `create_appointment` (comprueba + inserta en una transacción), `find_customer_appointments`, `cancel_appointment`, `reschedule_appointment` (comprueba nuevo hueco + actualiza de forma atómica), `purge_expired_data`.

**Agenda visible para el negocio**: fase 1, sincronización unidireccional a Google Calendar (el negocio la ve en el móvil) + acceso a una vista simple. Fase 2, panel web propio. Si el negocio ya usa Booksy/Treatwell/CoverManager, hay que valorar caso a caso (muchas no tienen API abierta): **pregúntalo en la venta**, es el mayor riesgo comercial del proyecto.

---

## 6. Flujos (workflows n8n)

### 6.1 `VOICE · Inbound Call` (webhook de llamada entrante)
1. Verificar firma HMAC de Retell.
2. Normalizar número llamado → buscar `phone_numbers` → `tenant`. Si no existe o `activo=false` → variables de "servicio no disponible" + alerta a Verantia.
3. Leer config, servicios, horario, cierres próximos, FAQs.
4. Construir variables: fecha actual y próximos 30 días (reutilizas tu código), catálogo, horario, políticas, FAQ, texto RGPD de primera capa, nombre del asistente.
5. Buscar si el llamante (`from_number`) es cliente conocido → pasar su nombre y citas futuras (personaliza y agiliza modificar/anular). Si el número es oculto, se le pedirá.
6. Responder en < 1 s. Fallback si Supabase falla: variables mínimas + el agente ofrece tomar el recado.

### 6.2 `VOICE · Tools` (un webhook por herramienta o uno con `switch` por nombre)
Cada herramienta: verificar firma → resolver tenant desde `call_id` (no desde los argumentos) → **validar y sanitizar argumentos** → RPC Supabase → responder un **código + frase** que el agente entiende (`DISPONIBLE`, `OCUPADO`, `DIA_BLOQUEADO`, `FUERA_DE_HORARIO`, `CONFIRMADO`, `ERROR_OCUPADO`, `NO_ENCONTRADA`…). Timeout máximo 5 s; si se excede, se devuelve `ERROR_TECNICO` y el agente ofrece tomar el recado (nunca silencio).

Herramientas:
| Herramienta | Qué hace |
|---|---|
| `check_availability` | **1ª comprobación**: servicio + fecha + hora → estado |
| `get_available_slots` | Rangos libres de un día o rango de días para un servicio |
| `create_appointment` | **2ª comprobación atómica** + inserción + dispara confirmación. Si alguien se adelantó → `ERROR_OCUPADO` + alternativas |
| `find_appointments` | Citas futuras del llamante (por teléfono; si no coincide, por nombre + fecha) |
| `cancel_appointment` | Anula (respetando política de antelación del negocio) |
| `reschedule_appointment` | Comprueba nuevo hueco y mueve en una transacción |
| `escalate_to_human` | Motivo + resumen → WhatsApp al negocio; si está en horario y hay número de transferencia, el agente usa `transfer_call` |

### 6.3 `VOICE · Call Ended` (post-llamada)
Guardar duración, resultado y resumen; enviar confirmación/actualización; si `escalada` o el análisis dice "no resuelto" → WhatsApp al negocio con resumen (y transcripción si el negocio lo tiene activado); contabilizar minutos para facturación y alertar si un cliente supera su plan.

### 6.4 Confirmaciones: email sí, pero ojo
Dictar un email por teléfono es la parte **más frágil** de toda la conversación (letras, puntos, "arroba", dominios raros). Propuesta:
- **Recomendado**: confirmación por **WhatsApp** (plantilla de utilidad de WhatsApp Cloud API, ~0,02–0,04 € por mensaje) o SMS al número desde el que llama; no hay que pedir nada.
- **Email**: si el cliente ya es conocido, usar el guardado; si no, pedirlo solo si lo desea, **deletreado** y leído de vuelta para confirmar. Envío con Brevo/Resend/SMTP (gratis o casi en este volumen).
- Configurable por negocio.

### 6.5 Derivación a humano
Disparadores: el cliente lo pide ("quiero hablar con una persona"), queja/enfado, tema fuera de alcance (salud, presupuestos especiales, grupos grandes), 2 intentos fallidos de entender, o error técnico.
- En horario y con número de transferencia → **transferencia cálida** (el agente resume al empleado antes de pasar).
- Fuera de horario / nadie contesta → "Tomo nota y te llamarán" + **WhatsApp al negocio**: nombre, teléfono, motivo, resumen y enlace/transcripción.

### 6.6 Errores y alertas (Verantia)
- **Error Trigger global** en n8n → WhatsApp a Verantia: workflow, nodo, tenant, `call_id`, mensaje (sin datos personales).
- Alertas de negocio: webhook sin respuesta, tasa de llamadas no resueltas > X %, tenant sin número, consumo anómalo, saldo del proveedor bajo.
- **Health check** diario (cron): llamada a cada endpoint con un tenant de pruebas + comprobación de Supabase; opcionalmente, una llamada sintética semanal.
- Anti-spam de alertas: agrupar el mismo error en 10 min.
- Para tus propias alertas, WhatsApp Cloud API con una plantilla de "alerta técnica". Si quieres algo más simple y gratis, Telegram es alternativa válida (tú decides; para los negocios, WhatsApp).

### 6.7 Sanitización y seguridad
- Firma HMAC en todos los webhooks; rechazar lo no firmado.
- Validación estricta: fecha `YYYY-MM-DD` dentro de 0–90 días, hora `HH:MM` en franja válida, servicio existente del tenant (por id o nombre normalizado), email por regex + dominio con MX opcional, teléfono a E.164, textos libres ≤ 300 caracteres y sin caracteres de control.
- Consultas siempre parametrizadas (RPC/REST de Supabase), nunca concatenando texto.
- Prompt de seguridad (el tuyo ya es bueno) + el agente nunca lee datos de otras citas ni de otros clientes; `find_appointments` solo devuelve citas del número llamante o tras verificar nombre + fecha.
- Rate limiting por número llamante (evitar abuso/coste): p. ej. máx. 5 llamadas/hora y duración máxima de llamada de 10 min.
- Secretos en credenciales de n8n; n8n autoalojado en servidor UE (Hetzner/OVH/Contabo) con HTTPS, actualizaciones y copias de seguridad.

---

## 7. Protección de datos (RGPD, LOPDGDD) y AI Act

**Roles**: el negocio es **responsable del tratamiento**; Verantia es **encargada** (contrato art. 28 RGPD con cada cliente); Retell/ElevenLabs, proveedor del LLM, Supabase, Twilio/Telnyx, proveedor de email/WhatsApp y hosting son **subencargados** (firmar sus DPA y listarlos en el contrato).

**Obligaciones y cómo se cumplen**:
1. **Transparencia IA (AI Act art. 50, aplicable desde el 2/8/2026)**: el asistente dice al empezar que es un asistente virtual con IA.
2. **Información de primera capa al inicio** (≈10 s): *"Hola, soy Lucía, la asistente virtual con inteligencia artificial de [Negocio]. Tratamos tus datos para gestionar tu cita; tienes más información en nuestra web. ¿En qué te ayudo?"* Segunda capa: política de privacidad del negocio (plantilla que les das) + enlace en el email/WhatsApp de confirmación.
3. **Base jurídica**: gestión de la cita = medidas precontractuales/contrato (art. 6.1.b). Nada de marketing sin consentimiento separado (no se pide por teléfono en el MVP).
4. **Grabación**: **no guardar audio** por defecto (desactivar almacenamiento de grabaciones en el proveedor). Transcripción solo si el negocio la quiere para derivaciones, con **retención 30 días** y borrado automático (`purge_expired_data`). Logs técnicos sin datos personales.
5. **Minimización**: nombre, teléfono, (email opcional), servicio, fecha. **Prohibido pedir datos de salud** (alergias, medicación, embarazo…) — especialmente en estética: el agente deriva a humano si el cliente los menciona. Si un cliente es **clínica sanitaria/medicina estética**, requiere análisis específico (categoría especial art. 9) → fuera del MVP o con EIPD.
6. **Transferencias internacionales**: Retell/Vapi/OpenAI son de EE. UU. → verificar adhesión al EU-US Data Privacy Framework + cláusulas contractuales tipo; activar opciones de *no retención/no entrenamiento* y, si existen, residencia de datos en UE (ElevenLabs la ofrece en planes altos). Supabase y n8n en UE.
7. **Derechos ARSOPL**: procedimiento para que el negocio te pida exportar/borrar datos de un teléfono (función SQL `forget_customer`).
8. **Documentación**: registro de actividades de tratamiento (plantilla por negocio), análisis de riesgos, contrato de encargado, cláusula informativa, política de retención. EIPD probablemente no obligatoria para este uso básico sin audio ni datos sensibles, pero documenta el análisis que lo justifica.
9. **Seguridad (art. 32)**: RLS, cifrado en tránsito, acceso mínimo, copias, registro de accesos.

> Recomendación: que un asesor de protección de datos revise las plantillas una vez (coste único ~300–600 €); luego las reutilizas con todos los clientes. Esto además es **argumento de venta** ("cumple RGPD y la ley europea de IA").

---

## 8. Plan paso a paso y tiempos (1 persona, dedicación completa)

| Fase | Semana | Entregables |
|---|---|---|
| **0. Decisiones y cuentas** | 1 | Cuenta Retell (y prueba de 1 h con ElevenLabs para comparar voz), Supabase (región UE), n8n autoalojado UE, WhatsApp Cloud API (verificación Meta puede tardar días: **empezar ya**), número de pruebas español (trámite regulatorio 1–5 días: **empezar ya**). Elegir voz. |
| **1. Base de datos** | 1–2 | Esquema, RLS, restricción de exclusión, funciones RPC, festivos, datos de un negocio demo (reutiliza los de tu centro de estética). Tests SQL de disponibilidad y concurrencia. |
| **2. Backend n8n** | 2–3 | Workflows Inbound Call, Tools, Call Ended, Error Handler. Validación, firmas, idempotencia. Pruebas con Postman/cURL. Tiempo de respuesta objetivo < 800 ms. |
| **3. Agente de voz** | 3–4 | Prompt de voz (adaptado del tuyo), definición de herramientas, transferencia, variables dinámicas, parámetros de voz (velocidad, interrupciones, silencio, tiempo máximo). 50+ llamadas de prueba con guion: acentos, ruido, nombres, fechas relativas ("el jueves que viene"), cambios de opinión, cancelaciones. |
| **4. Notificaciones y derivación** | 4–5 | Email + WhatsApp de confirmación, WhatsApp al negocio, alertas a Verantia, health check. |
| **5. Legal y onboarding** | 5 | Contrato de encargo, cláusulas, política de retención, guion RGPD. Formulario de alta de negocio (Tally/Typeform → n8n → Supabase) para dar de alta un cliente en 2–4 h. |
| **6. Piloto** | 6–7 | 1–2 negocios reales de Valladolid (gratis o a precio reducido 30 días, a cambio de testimonio). Revisar transcripciones diariamente la 1ª semana, ajustar prompt, medir % resuelto. |
| **7. Comercialización** | 8+ | Demo pública (número al que cualquier prospecto puede llamar), vídeo, casos de uso por sector, landing en verantia. |

A media jornada: 10–12 semanas hasta el piloto.

**Riesgos y mitigaciones**
| Riesgo | Mitigación |
|---|---|
| El negocio ya usa otra agenda (Booksy, Treatwell, CoverManager…) | Preguntar en la venta; ofrecer migrar a la agenda Verantia + Google Calendar; integraciones solo si hay API |
| Nombres/emails mal entendidos | Deletrear y repetir; confirmar por WhatsApp/SMS en vez de email; vocabulario personalizado (nombres de tratamientos) en el STT |
| Ruido (restaurantes, secadores) | Ajustes de supresión de ruido y sensibilidad de interrupción del proveedor |
| Rechazo de clientes mayores a hablar con IA | Presentación amable, derivación fácil a humano, uso preferente fuera de horario / cuando el personal está ocupado |
| Subidas de precio del proveedor | Arquitectura agnóstica; precio al cliente con margen suficiente y minutos incluidos |
| Alucinaciones de precios | Toda la info en el prompt desde Supabase; regla "si no está en la información, no lo sé, te pongo con el equipo" |

---

## 9. Costes

### 9.1 Costes fijos de la plataforma (compartidos entre todos los clientes)
| Concepto | €/mes |
|---|---|
| Servidor n8n autoalojado (UE) | 10–25 |
| Supabase Pro (backups, sin pausa) | ~25 |
| Dominio, email transaccional, monitorización | 0–15 |
| WhatsApp Cloud API (alertas) | ~0–5 |
| **Total** | **~40–70 €/mes** |

### 9.2 Costes variables por negocio
| Concepto | Coste |
|---|---|
| Voz todo incluido (Retell + LLM + telefonía) | 0,11–0,16 €/min |
| Número español | 1–5 €/mes |
| Mensajes WhatsApp de confirmación | 0,02–0,04 €/mensaje |
| Email | ~0 |

**Ejemplos (llamada media 2,5 min):**
| Negocio | Llamadas/mes | Minutos | Coste voz | + número + WhatsApp | **Coste total** |
|---|---|---|---|---|---|
| Peluquería pequeña | 120 | 300 | 33–48 € | ~6 € | **~40–55 €** |
| Centro de estética | 250 | 625 | 70–100 € | ~10 € | **~80–110 €** |
| Restaurante con reservas | 500 | 1.250 | 140–200 € | ~20 € | **~160–220 €** |

### 9.3 Inversión inicial
- Tu tiempo: 5–7 semanas.
- Pruebas (minutos, números, créditos): 50–150 €.
- Revisión legal de plantillas: 300–600 € (recomendado).

---

## 10. Precio de mercado y propuesta de tarifas

Referencias de mercado en España (2026): las "recepcionistas IA" para pymes se venden normalmente entre **99 y 400 €/mes** con alta de **0 a 1.500 €**; las soluciones grandes (centralitas con IA) por encima. Una recepcionista humana a media jornada cuesta > 1.000 €/mes; ese es tu ancla de valor, junto con **"cuántas reservas pierdes por no coger el teléfono"** (un restaurante o una peluquería pierden fácilmente 20–40 llamadas/semana en horas punta).

Propuesta:
| Plan | Incluye | Cuota | Alta |
|---|---|---|---|
| **Básico** | FAQs + reservas + email, 300 min | 149 €/mes | 390 € |
| **Profesional** ⭐ | + modificar/anular, WhatsApp de confirmación, derivación a humano, 700 min | 249 €/mes | 590 € |
| **Premium** | + chatbot web incluido, sincronización de calendario, informes mensuales, 1.500 min | 399 €/mes | 790 € |
| Exceso | | 0,25–0,30 €/min | |

- Margen bruto estimado: 60–75 %.
- Permanencia 6–12 meses o descuento anual (2 meses gratis).
- Oferta de lanzamiento en Valladolid: piloto 30 días con 50 % de descuento en el alta.
- Venta cruzada: chatbot web (que ya tienes) + teléfono con el mismo backend.

---

## 11. Decisiones que necesito que confirmes antes de pasar al JSON / código

1. **Proveedor de voz**: Retell (recomendado) vs ElevenLabs. Propuesta: 1 h de prueba de voz con ambos y decidir.
2. **Proveedor de números**: Twilio (más documentado) vs Telnyx (más barato) vs SIP español.
3. **Agenda**: Supabase como fuente de verdad + Google Calendar de solo lectura para el negocio (recomendado) vs Google Calendar como fuente de verdad (como tu chatbot actual, si es lo que usa).
4. **Confirmación**: WhatsApp (recomendado) + email opcional, o solo email.
5. **Alertas para ti**: WhatsApp Cloud API vs Telegram.
6. **Sector del primer piloto**: estética/peluquería (recursos por profesional) o restaurante (capacidad por franja). El modelo soporta ambos, pero conviene empezar por uno.

Siguiente entrega propuesta: script SQL de Supabase (esquema + RLS + funciones RPC) → workflows n8n (JSON) → prompt y configuración del agente.
