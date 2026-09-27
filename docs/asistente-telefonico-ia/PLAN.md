# Verantia Voice — Asistente telefónico con IA para negocios locales (Valladolid)

> Documento de proyecto v2 · 27/09/2026 (actualizado tras tus respuestas)
> Alcance: recepcionista telefónica con IA, multi-tenant, para restaurantes, centros de estética, peluquerías, academias, clínicas no sanitarias, etc.
> Backend: n8n + Supabase. Servicio de voz/telefonía: **Retell AI en configuración "lean"** (ver §2).
>
> **Cambios en v2** (respuesta a tus comentarios): coste de voz recalculado a la baja con una configuración "lean" de Retell (~0,08–0,10 €/min en vez de 0,13–0,16); Supabase pasa a ser fuente de verdad universal de agenda con sincronización *opcional* a distintos calendarios (no solo Google); WhatsApp confirmado para tus alertas; SMS incorporado como alternativa/complemento a WhatsApp para confirmaciones; coste real de WhatsApp Business detallado (no se dispara el presupuesto); primer piloto en estética/peluquería con diseño explícitamente reutilizable para restaurantes.

---

## 0. Resumen ejecutivo

| Pregunta | Respuesta corta |
|---|---|
| ¿Es viable? | **Sí, totalmente.** La tecnología de voz en tiempo real en español ya es madura (latencia < 1 s, voces de España naturales). Para conversaciones acotadas (precios, horarios, reservas) el porcentaje de llamadas resueltas sin humano suele estar en el 70–90 %. |
| Proveedor de voz recomendado | **Retell AI**, en **configuración lean** (LLM ligero + voz estándar + telefonía propia) para bajar el coste sin perder su punto fuerte: el manejo de turnos e interrupciones. Ver §2. |
| Dónde vive el conocimiento del negocio | **En Supabase**, inyectado al inicio de cada llamada (no en la base de conocimiento del proveedor). Te explico por qué en el §4. |
| Agenda | **Supabase como fuente de verdad única**, válida para cualquier negocio tenga o no Google Calendar. Sincronización de solo lectura a Google Calendar/Outlook/iCal es un extra opcional, no un requisito. Ver §5. |
| Doble comprobación de disponibilidad | Sí: 1ª en `check_availability`, 2ª **atómica** dentro de `create_appointment` + restricción de base de datos que hace **imposible** el doble booking. |
| Confirmación al cliente | **WhatsApp (recomendado) + SMS como alternativa/respaldo**, email opcional. Coste real detallado en §9 — no se dispara el presupuesto. |
| Alertas para ti (Verantia) | **WhatsApp.** |
| Primer piloto | **Estética/peluquería**, con el modelo de datos diseñado para reutilizarse en restaurantes con cambios menores (ver §5 y §8). |
| Tiempo hasta MVP en producción (1 persona) | **5–7 semanas** con dedicación completa; 9–12 a media jornada. Alta de cada cliente nuevo después: 2–4 h. |
| Coste variable | ~**0,09–0,12 €/min** todo incluido (config. lean). Una llamada media (2,5 min) ≈ 0,22–0,30 €. |
| Precio de mercado recomendado | Alta 390–790 € + cuota 149–399 €/mes según minutos. Margen bruto objetivo 65–80 %. |

---

## 1. Qué hace el asistente (alcance funcional MVP)

1. **Atiende** llamadas entrantes con voz natural (castellano de España), identificándose como asistente de IA.
2. **Responde FAQs**: precios, horarios, servicios/tratamientos, menús, ubicación, parking, formas de pago, política de cancelación.
3. **Consulta disponibilidad** (hora concreta o "¿qué tenéis el jueves?").
4. **Crea citas/reservas** con doble comprobación.
5. **Modifica y anula** citas (identificando al cliente por su número de teléfono + nombre).
6. **Envía confirmación** por WhatsApp (con SMS de respaldo automático si falla), y por email si el cliente lo prefiere (ver §6.4).
7. **Deriva a humano** si el cliente lo pide o si el asistente lo considera necesario: transferencia de la llamada en horario, o mensaje al WhatsApp del negocio con resumen + transcripción.
8. **Avisa a Verantia** por WhatsApp si algo técnico falla.
9. **Cumple RGPD/LOPDGDD y AI Act** (aviso de IA, información de protección de datos, minimización, retención limitada).

Fuera del MVP (fase 2): llamadas salientes (recordatorios), cobro de señales, integración con software de agenda de terceros (Booksy, Treatwell, CoverManager…), panel web propio para el negocio.

---

## 2. Evaluación de proveedores de voz — y cómo abaratar Retell sin bajar la calidad

Criterios: calidad de voz en español de España, latencia/naturalidad de turnos, fiabilidad llamando a herramientas (function calling), facilidad técnica, coste, soporte multi-tenant por API, números españoles, transferencia de llamada, cumplimiento RGPD.

Me preguntabas si hay opciones más baratas con la misma calidad, o si se puede abaratar Retell "desde dentro". **Respuesta corta: sí se puede, y es mejor abaratar Retell que saltar a un competidor.** El precio de 0,13–0,16 €/min que te di es el de una configuración "todo premium" (LLM potente + voz premium + telefonía del propio proveedor). Cada uno de esos tres componentes se puede sustituir por una opción más barata **sin tocar el motor de turnos/interrupciones**, que es lo que de verdad marca la diferencia en una llamada de voz y donde los competidores baratos flojean.

### Configuración "lean" de Retell (recomendada)
| Componente | Opción premium (lo que se suele configurar por defecto) | Opción lean (recomendada) | Ahorro |
|---|---|---|---|
| LLM | GPT-4o / modelo "frontier" (~0,08–0,16 €/min) | Modelo ligero (GPT-5 nano/mini o Claude Haiku 4.5, ~0,01–0,025 €/min). Para este caso de uso (FAQs + recogida de datos estructurados con herramientas) es más que suficiente: la conversación está muy guiada por el prompt y las herramientas, no requiere razonamiento complejo | ~0,06–0,10 €/min |
| Voz (TTS) | Voz premium (ElevenLabs alta gama) (~0,08 €/min) | Voz estándar/Cartesia (sigue sonando natural en español) (~0,04–0,05 €/min) | ~0,03–0,04 €/min |
| Telefonía | Telefonía incluida de Retell (~0,015 €/min + margen) | **Tu propio troncal Twilio/Telnyx** conectado a Retell ("BYO telephony"): pagas telefonía a precio mayorista y evitas el margen del proveedor | ~0,005–0,01 €/min |
| **Total estimado** | 0,13–0,16 €/min | **~0,08–0,10 €/min** | **~35–40 % más barato** |

Con esta configuración obtienes prácticamente la misma calidad conversacional (el "cerebro" de turnos y latencia de Retell no cambia) por un coste cercano al de Vapi barato, pero sin la carga de integrar tú mismo STT+LLM+TTS+telefonía por separado. **Este es el ajuste que recomiendo hacer, no cambiar de proveedor.**

### Comparativa de proveedores (con Retell ya en su versión lean)
| Proveedor | Voz ES-ES | Latencia / turnos | Herramientas + n8n | Facilidad | Coste real €/min* | Veredicto |
|---|---|---|---|---|---|---|
| **Retell AI (lean)** | Muy buena | Excelente, el mejor manejo de interrupciones | Custom functions → webhook n8n | Alta | **0,08–0,10** | ⭐ **Recomendado** |
| Retell AI (premium) | Muy buena | Excelente | Igual | Alta | 0,13–0,16 | Solo si en pruebas reales el lean se nota peor |
| ElevenLabs Agents | La mejor del mercado | Muy buena | Server tools → webhook | Alta | 0,08–0,12 (+ LLM, hoy parcialmente absorbido) | 2ª opción, si la voz es el argumento de venta nº1 |
| Vapi (lean: BYO Twilio + Deepgram + LLM ligero + TTS estándar) | Buena | Buena, pero **tú afinas** la sensibilidad de turno/interrupción | Muy flexible | Media-baja (más piezas que montar y mantener) | 0,06–0,09 | Solo si el coste manda por encima de todo y aceptas más horas de ajuste continuo |
| Bland AI | Enfocado a EE. UU., sin garantías claras en ES | Buena | Buena | Media | 0,09 sin plataforma (+ LLM/TTS/telefonía aparte) | No lo recomiendo para ES: poca evidencia de calidad en español de España |
| Synthflow / similares no-code | Correcta | Correcta | Limitada | Muy alta | 0,15–0,30 | Más caro y menos control; no aprovecha tu n8n |
| Hacerlo tú (Twilio/LiveKit/Pipecat + Realtime) | Buena | Depende de ti | Total | **Baja** | 0,06–0,10 | No para empezar: meses de trabajo y mantenimiento propio |

\* Coste orientativo a septiembre 2026, incluyendo voz + LLM + telefonía. **Verificar precios en el momento de contratar**, cambian cada pocos meses.

### Por qué Retell (lean) como 1ª opción
- Es el que mejor resuelve lo **difícil** de la voz (turnos, interrupciones, silencios, "ehh…") sin que tengas que afinarlo tú mismo — esto es justo lo que se pierde si vas a una opción "barata por diseño" tipo Vapi/Bland con piezas sueltas.
- Patrón perfecto para multi-tenant: **un único agente plantilla** con variables dinámicas (`{{nombre_negocio}}`, `{{servicios}}`…) que se rellenan en el webhook de llamada entrante según el número llamado. Mantienes 1 prompt, no 50.
- Transferencia de llamada (fría/cálida) nativa, análisis post-llamada (resumen, sentimiento, "¿se resolvió?") y webhooks firmados.
- Permite bajar LLM y voz a opciones ligeras/estándar y traer tu propia telefonía, sin perder el motor de conversación. Es decir: **se puede tener la calidad de Retell al precio de las alternativas baratas.**
- Si en las pruebas piloto (§8) un negocio nota la voz "más plana" en la versión lean, subes solo ese componente (voz o LLM) para ese tenant — es un ajuste de configuración, no una migración.

### Cuándo cambiaría a ElevenLabs
Si en las pruebas con clientes reales la voz se percibe claramente mejor en ElevenLabs, o si ElevenLabs consolida su precio con LLM incluido por debajo de 0,10 €/min. **La arquitectura propuesta es agnóstica**: el backend n8n+Supabase no cambia; solo cambia la capa de voz (1–2 días de migración).

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

### Agenda: Supabase como fuente de verdad única (no dependas de que el negocio use Google Calendar)

Tenías razón en dudarlo: no todos los negocios usan Google Calendar (muchas peluquerías/estéticas llevan la agenda en papel, en una libreta, en una app de gestión de citas tipo Booksy/Treatwell, o en el calendario del móvil sin más). La solución no es elegir "Supabase o Google Calendar", es que **Supabase sea siempre la fuente de verdad** (ahí vive la disponibilidad real que consulta el asistente) y que la forma en que el negocio *ve* su agenda sea un adaptador de visualización, opcional y por tenant:

| El negocio... | Cómo ve su agenda |
|---|---|
| No usa ningún calendario digital hoy | Vista simple propia (Verantia) por web/móvil, alimentada directamente por Supabase. Es la opción por defecto y la más sencilla de dar de alta. |
| Usa Google Calendar | Sincronización de solo lectura Supabase → Google Calendar (un evento por cita, actualizado en cada creación/cambio/cancelación). |
| Usa Outlook/Microsoft 365 | Mismo patrón vía Microsoft Graph API. |
| Usa otra cosa o nada compatible | Export a `.ics` (funciona con casi cualquier app de calendario) y/o resumen diario por email/WhatsApp de las citas del día. |

Esto es un **adaptador por negocio, no el núcleo del sistema**: añades o quitas la sincronización sin tocar la lógica de disponibilidad ni el asistente. Así el sistema "vale para distintos calendarios" tal y como pedías, sin depender de ninguno.

**Lo que sí sigue siendo un riesgo real**: si el negocio quiere que su agenda *siga estando* en Booksy/Treatwell/CoverManager y que sea esa herramienta (no Supabase) la que decide la disponibilidad, hace falta que esa plataforma tenga API — muchas no la tienen abierta para terceros. **Pregúntalo en la venta**: si el negocio acepta que la agenda "de verdad" pase a estar en Supabase (con la vista/sincronización que prefiera), no hay problema; si insiste en mantener la otra plataforma como única fuente, hay que valorarlo caso a caso o descartarlo para el MVP.

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

### 6.4 Confirmaciones: WhatsApp + SMS de respaldo, email opcional
Dictar un email por teléfono es la parte **más frágil** de toda la conversación (letras, puntos, "arroba", dominios raros). Con tu confirmación de usar WhatsApp + valorar SMS, la propuesta queda así:

1. **WhatsApp (canal principal)**: al número desde el que llama, sin pedir nada. Plantilla de utilidad aprobada por Meta ("Tu cita en [Negocio]: [servicio], [fecha] [hora]. Para cancelar o modificar, llama al [teléfono]."). Coste real ≈ **0,014–0,02 €/mensaje** en España (ver desglose de precios en §9.2) — mucho más barato de lo que sugerían mis cifras iniciales de 0,02–0,04 €.
2. **SMS (respaldo automático)**: si el número no tiene WhatsApp (falla el envío, "número no válido para WhatsApp") o si el negocio prefiere SMS como canal único (algunos clientes mayores usan más el SMS), se envía por Twilio. Coste ≈ **0,08 €/SMS a España** — más caro que WhatsApp pero sigue siendo marginal por reserva.
3. **Email**: si el cliente ya es conocido, se usa el guardado; si no, se pide solo si lo desea, **deletreado** y leído de vuelta para confirmar. Envío con Brevo/Resend/SMTP (gratis o casi en este volumen). Útil también para negocios cuyo público valora tener un justificante por email (academias, por ejemplo).

Configurable por negocio: canal principal (WhatsApp/SMS/email), y si se activa el de respaldo automático.

### 6.5 Derivación a humano
Disparadores: el cliente lo pide ("quiero hablar con una persona"), queja/enfado, tema fuera de alcance (salud, presupuestos especiales, grupos grandes), 2 intentos fallidos de entender, o error técnico.
- En horario y con número de transferencia → **transferencia cálida** (el agente resume al empleado antes de pasar).
- Fuera de horario / nadie contesta → "Tomo nota y te llamarán" + **WhatsApp al negocio**: nombre, teléfono, motivo, resumen y enlace/transcripción.

### 6.6 Errores y alertas (Verantia)
- **Error Trigger global** en n8n → **WhatsApp a Verantia** (confirmado): workflow, nodo, tenant, `call_id`, mensaje (sin datos personales).
- Alertas de negocio: webhook sin respuesta, tasa de llamadas no resueltas > X %, tenant sin número, consumo anómalo, saldo del proveedor bajo.
- **Health check** diario (cron): llamada a cada endpoint con un tenant de pruebas + comprobación de Supabase; opcionalmente, una llamada sintética semanal.
- Anti-spam de alertas: agrupar el mismo error en 10 min.
- Plantilla de "alerta técnica" de utilidad en WhatsApp Cloud API para tus propios avisos — mismo canal que usas para los negocios, así que no añade un proveedor nuevo. Coste marginal (unos pocos mensajes/día como mucho): irrelevante frente al ahorro de tener un panel/servidor de monitorización aparte.

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
| WhatsApp Cloud API (número de Verantia, cuenta) | ~0–5 |
| **Total** | **~40–70 €/mes** |

### 9.2 Costes variables por negocio (recalculado con Retell en configuración lean, §2)

**Voz — 0,08–0,10 €/min todo incluido** (LLM ligero + voz estándar + telefonía propia), en vez de los 0,11–0,16 €/min de la configuración premium inicial.

**WhatsApp — desglose real (para que veas que no se dispara el presupuesto):**
Meta cobra por plantilla enviada, según categoría y país. Para España, la plantilla de **"utilidad"** (la que usaríamos para confirmar una cita) cuesta del orden de **0,013–0,017 €/mensaje** en tarifa base de Meta; el proveedor que te da acceso a la API (Twilio, 360dialog, etc.) añade normalmente 0,003–0,01 €/mensaje de margen. **Total realista: ~0,015–0,025 €/mensaje de confirmación** — más barato de lo que estimé al principio (0,02–0,04 €), no más caro.
- ⚠️ Un cambio a vigilar: Meta ha anunciado que a partir de octubre de 2026 empieza a cobrar también los **mensajes de servicio en respuesta al cliente** dentro de la ventana de 24 h (antes eran gratis). No nos afecta al flujo principal (nosotros enviamos siempre plantillas de utilidad, que ya se pagaban), pero si en el futuro añades un chat de WhatsApp abierto con el negocio o el cliente, ese coste habrá que contemplarlo entonces. Lo reviso cuando lleguemos a esa fase.
- **SMS de respaldo** (Twilio): ~0,08 €/SMS a números españoles — se usa solo cuando falla WhatsApp o el negocio prefiere SMS, así que en la mayoría de negocios es un coste marginal (unos pocos €/mes).

**Resto:**
| Concepto | Coste |
|---|---|
| Número español (desvío) | 1–5 €/mes |
| Email (Brevo/Resend) | ~0 en este volumen |

### 9.2 bis — De dónde salen las cifras de llamadas/mes (nota de metodología)

Buena pregunta la de si esos números cuadran con la realidad de una peluquería. Respuesta honesta: **no hay estadística oficial española pública por sector** (lo he comprobado: ni INE ni el Ministerio de Industria publican volumen de llamadas de peluquerías/centros de estética). Mis cifras eran una estimación de planificación razonable, no un dato medido. Con más búsqueda encuentro **benchmarks del sector** (mayoritariamente EE. UU., que es donde más se ha estudiado esto porque lo usan empresas de "AI receptionist" para vender su producto — hay que tomarlos con margen, pero sirven de referencia):

- Un salón que atiende ~15 clientes/día recibe del orden de **10–15 llamadas/día** solo de reservas (sin contar consultas de precio/horario que no acaban en cita).
- Salones más grandes o con más rotación llegan a ~25 llamadas/día.
- El **62 % de las llamadas a peluquerías/centros de belleza en EE. UU. no se contestan** (fuente del argumento comercial de estas empresas, pero da una idea del volumen real que existe aunque hoy se pierda).
- Duración media de llamada de reserva por voz IA: **2–3 minutos** (coincide con mi estimación de 2,5 min).

Con esto, mi estimación original de **120 llamadas/mes (~4–5/día) para una "peluquería pequeña"** se queda en la parte **baja/conservadora** del rango real (un salón de barrio con 1–2 sillas, sin mucho movimiento) — no es descabellada, pero probablemente muchas peluquerías de Valladolid reciban más. Por eso, mejor que un único número, te doy una tabla de sensibilidad por volumen para que ubiques cada negocio concreto según su tamaño real (que se puede estimar en la venta preguntando cuántas llamadas reciben hoy, o simplemente mirando el registro de llamadas del móvil/fijo del negocio durante una semana antes de dar el precio).

### 9.2 ter — Tabla de sensibilidad por volumen (2,5 min/llamada de media, confirmación por WhatsApp)

| Volumen | Llamadas/día | Llamadas/mes (26 días) | Minutos/mes | Coste voz (lean) | + número + WhatsApp/SMS | **Coste total/mes** |
|---|---|---|---|---|---|---|
| Muy bajo (barrio, 1 silla) | 3–4 | ~90 | ~225 | 18–23 € | ~5 € | **~23–28 €** |
| **Bajo–medio** (mi estimación inicial "peluquería pequeña") | 4–5 | ~120 | ~300 | 24–30 € | ~6 € | **~30–36 €** |
| **Medio** (salón con 2–3 sillas, buen movimiento — más realista para la media del sector según los benchmarks de EE. UU.) | 10–12 | ~275 | ~690 | 55–69 € | ~10 € | **~65–79 €** |
| Alto (salón grande / varios profesionales, o centro de estética con muchos tratamientos) | 18–20 | ~500 | ~1.250 | 100–125 € | ~15 € | **~115–140 €** |
| Restaurante con reservas (referencia, otro patrón de llamada) | 15–20 | ~500 | ~1.250 | 100–125 € | ~20 € | **~120–145 €** |

**Lectura práctica para el precio de venta**: si la media real de una peluquería está más cerca de la fila "Medio" que de mi estimación inicial "Bajo–medio", el **plan Básico (300 min incluidos, 149 €/mes)** se queda corto para muchos negocios y pasarían a consumir del plan Profesional (700 min) casi desde el primer mes — lo cual **no es un problema** (es más ingreso por exceso o por upgrade), pero conviene decirlo claro en la venta para que el negocio no se sorprenda. Recomiendo, antes de cerrar el precio con cada cliente real, pedirle **una semana de registro de llamadas** de su teléfono actual (la mayoría de móviles y centralitas lo tienen) para dimensionar el plan con su dato real, no con la media del sector.

Con la configuración lean, en cualquier caso tu coste variable baja un 30–40 % respecto a la primera estimación (premium), lo que sube el margen bruto de forma directa (ver §10) — esa parte se mantiene independientemente del volumen real de cada negocio.

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

- Margen bruto estimado: **65–80 %** (mejora respecto al 60–75 % inicial gracias a la configuración lean de voz y al coste real de WhatsApp, más bajo de lo estimado).
- Permanencia 6–12 meses o descuento anual (2 meses gratis).
- Oferta de lanzamiento en Valladolid: piloto 30 días con 50 % de descuento en el alta.
- Venta cruzada: chatbot web (que ya tienes) + teléfono con el mismo backend.

---

## 11. Decisiones — estado tras tus respuestas

| # | Decisión | Estado |
|---|---|---|
| 1 | Proveedor de voz | ✅ **Retell AI, en configuración lean** (§2). Prueba de 1 h lean vs premium recomendada en fase 0 para validar que la voz estándar no se nota peor; si se nota, subimos solo ese componente. |
| 2 | Proveedor de números | 🟡 **Pendiente** — Twilio (más documentado, algo más caro) vs Telnyx (más barato) vs SIP español. Propuesta: empezar con **Twilio** para el piloto (menos fricción, mejor soporte de Retell) y evaluar Telnyx cuando haya varios negocios y el volumen justifique optimizar coste. |
| 3 | Agenda | ✅ **Supabase como fuente de verdad universal**, con adaptadores opcionales de visualización (Google Calendar, Outlook, .ics) según lo que use cada negocio (§5). No se depende de ningún calendario externo. |
| 4 | Confirmación | ✅ **WhatsApp (canal principal) + SMS de respaldo automático**, email opcional (§6.4). |
| 5 | Alertas para ti | ✅ **WhatsApp.** |
| 6 | Sector del primer piloto | ✅ **Estética/peluquería**, con el modelo de datos y los workflows diseñados para reutilizarse en restaurantes (ver más abajo). |

### Cómo queda garantizada la reutilización estética/peluquería → restaurante
El modelo de datos (§5) ya está pensado para esto desde el principio, no es un añadido:
- **Lo que no cambia entre sectores** (el ~80 % del sistema): autenticación/tenant por número llamado, las herramientas de disponibilidad/reserva/cancelación, el doble-check atómico, las notificaciones (WhatsApp/SMS/email), la derivación a humano, las alertas, el cumplimiento RGPD, todo el backend n8n y el esquema Supabase.
- **Lo que cambia por sector** (configuración, no código nuevo):
  - `resources`: en estética/peluquería es "profesional" (con sus servicios asignados); en restaurante es "mesa" (con capacidad de comensales).
  - Reglas de disponibilidad: en estética/peluquería se reserva un profesional para una franja continua; en restaurante se comprueba capacidad agregada en una franja (varias mesas, aforo).
  - El prompt de voz: vocabulario del sector (tratamientos/servicios vs. platos/menú/alérgenos) y alguna pregunta extra en restaurante (número de comensales, si hay alguna alergia — sin registrar el detalle, solo derivarlo a nota para el negocio).
- **Coste de adaptar a un restaurante una vez montado el sistema para estética**: ese cambio de configuración + ajustar el prompt, no reconstruir nada. Un par de días, no semanas.

### Pendiente para seguir
- Confirmar proveedor de números (#2) cuando quieras — no bloquea empezar con la base de datos.
- Elegir el negocio concreto del piloto en Valladolid (estética o peluquería) para tener datos reales con los que probar el prompt.

Siguiente entrega propuesta: script SQL de Supabase (esquema + RLS + funciones RPC) → workflows n8n (JSON) → prompt y configuración del agente (versión lean).
