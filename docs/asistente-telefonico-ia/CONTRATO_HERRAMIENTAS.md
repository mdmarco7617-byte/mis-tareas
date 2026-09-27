# Contrato de herramientas — Verantia Voice v1

Este documento fija **qué recibe y qué devuelve** cada herramienta del asistente de voz. Todo lo demás (SQL, n8n, prompt de Retell) se construye contra este contrato. Si cambia algo aquí, cambia en los tres sitios.

---

## 1. Flujo de una llamada

```
Retell ──(1) call_inbound──► n8n  /voice/inbound ──► RPC fn_tenant_context(to, from)
       ◄── dynamic_variables ──┘
Retell ──(2) custom function─► n8n  /voice/tool    ──► RPC fn_tool_dispatch(to, from, call_id, tool, args)
       ◄── JSON {codigo, mensaje, ...} ──┘               └─► (n8n) WhatsApp/SMS/email si procede
Retell ──(3) call_analyzed ──► n8n  /voice/ended   ──► RPC fn_log_call(payload)  └─► avisos
```

Reglas que no se negocian:
1. **El negocio (tenant) se identifica SIEMPRE por `call.to_number`** (el número Verantia al que se desvía la llamada), que viene en el payload firmado de Retell. Nunca por un argumento que rellene el LLM.
2. **El teléfono del cliente de confianza es `call.from_number`**. El argumento `telefono` del LLM solo se usa si el número llega oculto o el cliente pide otro.
3. **La hora de fin la calcula el backend** a partir de la duración del servicio. El LLM solo manda fecha y hora de inicio. (En el chatbot actual el LLM calculaba `hora_fin`: fuente de errores, se elimina.)
4. Toda respuesta lleva `codigo` (para la lógica del prompt) y `mensaje` (pista en castellano de qué decir). **Nunca** devuelve un error técnico crudo: ante cualquier fallo, `ERROR_TECNICO`.
5. Firma: n8n verifica la cabecera `x-retell-signature` (HMAC con la API key de Retell) antes de hacer nada.

## 2. Payload que llega a n8n (custom function de Retell)

```json
{
  "name": "check_availability",
  "call": { "call_id": "call_abc", "from_number": "+34600111222", "to_number": "+34983000111", "direction": "inbound" },
  "args": { "servicio": "corte_mujer", "fecha": "2026-10-05", "hora": "10:00" }
}
```

n8n llama a una sola función SQL:

```sql
select fn_tool_dispatch(:to_number, :from_number, :call_id, :name, :args::jsonb);
```

y devuelve su resultado tal cual a Retell.

---

## 3. Herramientas

Formatos: `fecha` = `YYYY-MM-DD`, `hora` = `HH:MM` (24 h, hora local del negocio). `servicio` = el **código** que aparece en el catálogo del prompt (p. ej. `corte_mujer`) o su nombre/sinónimo; el backend acepta ambos.

### 3.1 `check_availability` — 1ª comprobación
| Arg | Tipo | Oblig. | Notas |
|---|---|---|---|
| servicio | string | sí | |
| fecha | string | sí | |
| hora | string | sí | hora de inicio |
| profesional | string | no | "con Laura" |
| comensales | integer | no | solo restaurantes (por defecto 1) |

Respuesta `DISPONIBLE`:
```json
{ "codigo": "DISPONIBLE", "mensaje": "...", "fecha": "2026-10-05", "dia_semana": "lunes",
  "hora_inicio": "10:00", "hora_fin": "10:45", "profesional": "Laura",
  "servicio": { "codigo": "corte_mujer", "nombre": "Corte de mujer", "duracion_min": 45, "precio": 22.00 } }
```
Si no está disponible, se añade `alternativas` (hasta 3 horas libres cercanas ese día) o `proximo_disponible` (primer hueco en días siguientes), para ofrecer opciones **sin otra llamada a herramienta** (menos silencio en la línea).

### 3.2 `get_available_slots`
| Arg | Tipo | Oblig. | Notas |
|---|---|---|---|
| servicio | string | sí | |
| fecha_inicio | string | sí | |
| fecha_fin | string | no | por defecto = fecha_inicio; máx. 14 días |
| franja | `manana` \| `tarde` | no | "¿tenéis algo por la tarde?" |
| profesional | string | no | |
| comensales | integer | no | |

Respuesta `HUECOS_DISPONIBLES`:
```json
{ "codigo": "HUECOS_DISPONIBLES", "mensaje": "...", "servicio": {...},
  "dias": [ { "fecha": "2026-10-05", "dia_semana": "lunes",
              "rangos": [ { "desde": "10:00", "hasta": "12:15" }, { "desde": "16:30", "hasta": "19:15" } ] } ] }
```
`desde`/`hasta` son **horas de inicio posibles** (a las 12:15 aún cabe el servicio completo). Si no hay nada: `SIN_HUECOS` + `proximo_disponible` si existe.

### 3.3 `create_appointment` — 2ª comprobación atómica
| Arg | Tipo | Oblig. | Notas |
|---|---|---|---|
| servicio, fecha, hora | | sí | |
| nombre | string | sí | nombre de quien viene (puede no ser quien llama) |
| telefono | string | no | solo si `from_number` es oculto o quiere otro |
| email | string | no | solo si el cliente lo quiere, deletreado |
| profesional, comensales | | no | |
| notas | string | no | máx. 500 caracteres; **nunca datos de salud** |

Dentro de una misma transacción: bloqueo por negocio → **se repite toda la comprobación de disponibilidad** → alta/actualización del cliente → inserción. Además la base de datos tiene una restricción de exclusión que hace imposible guardar dos citas solapadas del mismo profesional/mesa aunque todo lo demás fallara.

**Idempotencia**: la clave es `call_id + servicio + fecha + hora + teléfono`. Si Retell reintenta la herramienta, se devuelve la misma cita (`"repetida": true`), no una nueva.

Respuesta `CONFIRMADO`:
```json
{ "codigo": "CONFIRMADO", "mensaje": "...", "referencia": "482715", "cita_id": "uuid",
  "fecha": "2026-10-05", "dia_semana": "lunes", "hora_inicio": "10:00", "hora_fin": "10:45",
  "profesional": "Laura", "servicio": {...},
  "cliente": { "nombre": "Ana", "telefono": "+34600111222", "email": null },
  "confirmacion": { "canal": "whatsapp", "sms_respaldo": true } }
```
La `referencia` son 6 dígitos (más fáciles de dictar por teléfono que letras). n8n usa `cliente` y `confirmacion` para mandar el WhatsApp/SMS/email.

### 3.4 `find_appointments`
| Arg | Oblig. | Notas |
|---|---|---|
| nombre | no | junto con `fecha` si la búsqueda por teléfono no da resultado |
| fecha | no | |
| telefono | no | si el número es oculto |

Busca primero por el teléfono del llamante. Solo si no hay nada y el cliente da **nombre + fecha**, busca por esos datos. Respuesta `CITAS_ENCONTRADAS` con `citas: [{referencia, servicio, fecha, dia_semana, hora_inicio, profesional, nombre}]` o `SIN_CITAS`.

### 3.5 `cancel_appointment`
| Arg | Oblig. |
|---|---|
| referencia | sí (sale de `find_appointments` o la dice el cliente) |
| nombre | no (verificación si el teléfono no coincide) |

Verifica que la cita es del llamante (teléfono o nombre), que no ha pasado y que se respeta la antelación mínima de cancelación del negocio. Respuesta `CANCELADA` (con los datos, para el aviso) o `FUERA_DE_PLAZO` / `NO_VERIFICADA` / `NO_ENCONTRADA` / `CITA_PASADA`.

### 3.6 `reschedule_appointment`
| Arg | Oblig. |
|---|---|
| referencia, fecha, hora | sí |
| servicio, profesional, nombre | no |

Misma verificación que cancelar. Intenta primero con el mismo profesional y, si no se pidió uno concreto, con cualquiera. Cambio atómico: la cita no se pierde si el nuevo hueco no está libre. Respuesta `REPROGRAMADA` con `anterior` y `nueva`.

### 3.7 `escalate_to_human`
| Arg | Oblig. | Notas |
|---|---|---|
| motivo | sí | `cliente_lo_pide`, `queja`, `fuera_de_alcance`, `no_entiendo`, `grupo_grande`, `otro` |
| resumen | sí | 1–3 frases para el negocio |

Registra la derivación y responde `DERIVACION_REGISTRADA` con `transferencia_disponible` (true si el negocio está abierto ahora y tiene número de transferencia). Si es true, el agente usa la herramienta nativa `transfer_call` de Retell; si no, se despide diciendo que les llamarán. n8n manda el WhatsApp al negocio.

`transfer_call` y `end_call` son herramientas **nativas de Retell**, no pasan por n8n.

---

## 4. Códigos de respuesta

| Código | Significado | Qué hace el agente |
|---|---|---|
| `DISPONIBLE` | Hueco libre | Pide los datos que falten (nombre) y llama a `create_appointment` |
| `OCUPADO` | Hueco ocupado | Ofrece `alternativas` / `proximo_disponible` |
| `FUERA_DE_HORARIO` | Fuera del horario o el servicio no acaba antes del cierre | Informa del horario de ese día y ofrece alternativas |
| `DIA_CERRADO` | El negocio no abre ese día de la semana | Ofrece `proximo_disponible` |
| `DIA_BLOQUEADO` | Festivo, vacaciones o cierre puntual | Igual que el anterior; no ofrece horas de ese día |
| `FECHA_PASADA` | La fecha/hora ya ha pasado | Pide otra fecha |
| `DEMASIADO_PRONTO` | No respeta la antelación mínima | Explica y ofrece la primera hora válida |
| `DEMASIADO_LEJOS` | Supera el máximo de días de reserva | Pide una fecha más cercana |
| `FALTA_SERVICIO` | No se indicó servicio | Pregunta qué servicio quiere |
| `SERVICIO_NO_ENCONTRADO` | El servicio no existe en el catálogo | Lee opciones parecidas |
| `PROFESIONAL_NO_ENCONTRADO` | No hay nadie con ese nombre | Ofrece "con cualquiera" |
| `PROFESIONAL_NO_REALIZA_SERVICIO` | Esa persona no hace ese servicio | Ofrece otro profesional |
| `CAPACIDAD_EXCEDIDA` | No hay mesa para tantas personas | Deriva a humano |
| `GRUPO_GRANDE` | Supera el máximo de comensales por reserva telefónica | Deriva a humano |
| `ERROR_DATOS` | Fecha, hora u otro dato con formato incorrecto (`campo` indica cuál) | Vuelve a preguntar ese dato |
| `FALTA_TELEFONO` / `EMAIL_NO_VALIDO` / `NOMBRE_NO_VALIDO` | Datos de contacto incorrectos | Vuelve a pedirlos |
| `HUECOS_DISPONIBLES` / `SIN_HUECOS` | Resultado de `get_available_slots` | |
| `CONFIRMADO` | Cita creada | Confirma leyendo día, hora, servicio y referencia |
| `ERROR_OCUPADO` | Alguien reservó ese hueco justo antes (2ª comprobación) | Se disculpa y ofrece `alternativas` |
| `CITAS_ENCONTRADAS` / `SIN_CITAS` | Resultado de `find_appointments` | |
| `CANCELADA` / `REPROGRAMADA` | Operación hecha | Confirma |
| `NO_ENCONTRADA` | No existe una cita activa con esa referencia | Pide revisar la referencia o buscar por nombre y fecha |
| `NO_VERIFICADA` | La cita no es del llamante | No da detalles; ofrece pasar con el negocio |
| `FUERA_DE_PLAZO` | No se puede cancelar/mover con tan poca antelación | Explica la política y deriva |
| `CITA_PASADA` | La cita ya pasó | |
| `DERIVACION_REGISTRADA` | Derivación anotada | Transfiere o se despide |
| `ERROR_TECNICO` | Cualquier fallo interno (se avisa a Verantia) | Se disculpa, toma nota y deriva |

---

## 5. Webhook de inicio de llamada (`call_inbound`)

n8n llama a `fn_tenant_context(to_number, from_number)`, que devuelve el negocio, servicios, profesionales, horario, cierres y festivos próximos, FAQs y, si el llamante es conocido, su nombre y próximas citas. n8n lo convierte en texto (reutilizando tu `Build System Prompt`) y responde a Retell:

```json
{ "call_inbound": {
    "dynamic_variables": {
      "nombre_negocio": "Peluquería Demo", "nombre_asistente": "Lucía",
      "fecha_hoy": "lunes 28 de septiembre de 2026, 10:32",
      "calendario": "...", "horario": "...", "catalogo": "...", "faq": "...",
      "politicas": "...", "cliente_conocido": "Ana (cita el lunes 5 a las 10:00, ref. 482715)"
    },
    "metadata": { "tenant_id": "uuid" } } }
```

Si el número no está asignado o el negocio está inactivo: `{"ok": false, "codigo": "NUMERO_NO_ASIGNADO"}` → n8n responde variables mínimas ("servicio no disponible") y avisa a Verantia por WhatsApp.
