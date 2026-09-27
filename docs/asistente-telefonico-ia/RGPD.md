# Verantia Voz — Cumplimiento RGPD / LOPDGDD / AI Act

Lista de control viva: se revisa en cada entrega. Estados:
- ✅ **Hecho y probado** en el sistema
- 🟡 **Pendiente de ti** (configuración, contratos o decisiones fuera del código)
- ⚖️ **Validar con un profesional** de protección de datos (recomendado una vez, antes del primer cliente)

> Honestidad por delante: el código puede cumplir "por diseño" (minimización, seguridad, plazos, derechos), pero el cumplimiento completo exige además contratos firmados, configuración de proveedores y documentación. Mientras quede algún 🟡 o ⚖️ abierto, **no se debe atender a clientes reales**. El piloto con los negocios demo no trata datos reales.

## 1. Roles
| | Estado |
|---|---|
| El **negocio** es el *responsable del tratamiento*; **Verantia** es *encargada* (art. 28) | 🟡 Contrato de encargo firmado con cada negocio (plantilla pendiente, ver §9) |
| Subencargados: Supabase (BD), Retell (voz + IA), proveedor del LLM vía Retell, Twilio (teléfono/SMS), Meta (WhatsApp), proveedor SMTP, hosting de n8n | 🟡 Aceptar/firmar el DPA de cada uno y listarlos en el contrato con el negocio |

## 2. Transparencia (arts. 12–14) y AI Act (art. 50)
| | Estado |
|---|---|
| Aviso de que habla con una **IA** en la primera frase de la llamada | ✅ `saludo_inicial` (probado) |
| **Primera capa** informativa al inicio de la llamada (finalidad + dónde ampliar) | ✅ en el saludo (probado) |
| **Segunda capa**: política de privacidad del negocio enlazada en cada confirmación (WhatsApp/SMS/email) | ✅ técnicamente (`url_privacidad`); 🟡 cada negocio debe tener su política publicada y la URL cargada en `tenants.url_privacidad` **antes de activarlo** |
| La política debe mencionar: asistente con IA, uso del número llamante para identificar citas, destinatarios (subencargados), transferencias internacionales, plazos, derechos | ⚖️ plantilla de política para los negocios (pendiente, §9) |

## 3. Base jurídica
| | Estado |
|---|---|
| Gestión de citas: medidas precontractuales / contrato (art. 6.1.b) | ✅ diseño |
| Nada de marketing: solo plantillas de **utilidad**; sin consentimiento no se envía publicidad | ✅ diseño (plantillas de utilidad) |
| Menores: la reserva la hace normalmente un adulto; si llama un menor, la base sigue siendo la gestión de la cita (no consentimiento). Sin perfilado | ⚖️ confirmar criterio |

## 4. Minimización (art. 5.1.c)
| | Estado |
|---|---|
| Solo se guarda: teléfono, nombre, email opcional, servicio, fecha, notas cortas | ✅ esquema |
| **Prohibido pedir datos de salud** (alergias, medicación, embarazo…) | 🟡 regla en el prompt (siguiente entrega) + revisión de transcripciones en el piloto |
| Retell envía a n8n **solo los argumentos** de cada herramienta, no la transcripción | ✅ admitido y probado; 🟡 activar "Payload: args only" en las 7 funciones |
| A la IA no le vuelven teléfonos, emails ni ids internos | ✅ probado |
| **No se guarda audio**; transcripción solo si el negocio lo activa (por defecto no) | ✅ en nuestro sistema (probado); 🟡 desactivar grabación y almacenamiento de PII en Retell |
| n8n **no guarda** las ejecuciones correctas | ✅ ajuste en los 6 flujos (probado: 0 ejecuciones con datos) |
| Alertas a Verantia **sin datos personales** (se borran teléfonos y emails) | ✅ probado |
| Aviso al negocio: solo lo necesario para atender (nombre, servicio, hora, teléfono para devolver la llamada) | ✅ diseño |

## 5. Plazos de conservación (art. 5.1.e) — purga automática diaria (pg_cron)
| Dato | Plazo por defecto (configurable por negocio) | Estado |
|---|---|---|
| Transcripción (si el negocio la activa) | 30 días | ✅ probado |
| Resumen y nº del llamante de cada llamada | 90 días (se conserva la duración para facturar) | ✅ probado |
| Citas pasadas | 24 meses → anonimizadas | ✅ probado |
| Clientes sin citas ni actividad | 24 meses → borrados | ✅ probado |
| Registro técnico de errores | 90 días | ✅ |
| Ejecuciones fallidas de n8n | 7 días | 🟡 variables `EXECUTIONS_DATA_*` (ver `n8n/README.md`) |
| Datos en Retell, Twilio y Meta | según cada proveedor | 🟡 configurar el mínimo posible en cada uno |
| Plazos definitivos por negocio | | ⚖️ acordarlos en el contrato de encargo |

## 6. Derechos (arts. 15–22)
| | Estado |
|---|---|
| Acceso / portabilidad: exportar todo lo de un teléfono (JSON) | ✅ `fn_export_customer` (probado) |
| Supresión: anonimizar citas y borrar cliente y rastros en llamadas | ✅ `fn_forget_customer` (probado) |
| Rectificación | ✅ por SQL / futuro panel |
| Procedimiento: el negocio pide a Verantia → respuesta en ≤ 1 mes | 🟡 procedimiento escrito (plantilla pendiente, §9) |
| Derecho a hablar con una persona | ✅ derivación/transferencia en cualquier momento |

## 7. Seguridad (art. 32)
| | Estado |
|---|---|
| Firma HMAC de Retell verificada (con anti-replay de 5 min); clave cifrada en Supabase Vault | ✅ probado en local y en el Supabase real |
| RLS sin políticas: la clave pública no puede leer ni ejecutar nada | ✅ probado |
| Aislamiento entre negocios (el negocio lo decide el número llamado) | ✅ probado |
| Consultas parametrizadas, validación y limpieza de todas las entradas | ✅ probado |
| Cifrado en tránsito (HTTPS) en todos los tramos | ✅ Supabase/Retell/Meta/Twilio; 🟡 n8n en producción con HTTPS |
| **n8n de producción** en servidor de la UE, disco cifrado, actualizado, con copias | 🟡 hoy es local (solo apto para pruebas con datos demo) |
| **Copias de seguridad** de la BD | 🟡 el plan gratuito de Supabase no ofrece copias restaurables: plan Pro antes del primer cliente |
| Túnel para pruebas (Cloudflare, ngrok…) | 🟡 solo con datos demo; nunca con clientes reales |

## 8. Transferencias internacionales (cap. V)
| Proveedor | Situación | Estado |
|---|---|---|
| Supabase | Datos en Frankfurt (UE) | ✅ |
| Retell AI | Empresa de EE. UU. | 🟡⚖️ verificar certificación en el EU-US Data Privacy Framework o cláusulas contractuales tipo en su DPA; preguntar si ofrece residencia de datos en la UE |
| LLM usado por Retell (OpenAI / Anthropic…) | EE. UU. | 🟡 idem; elegir el modelo con garantías y sin entrenamiento con los datos |
| Twilio | EE. UU. (DPF / BCR) | 🟡 aceptar su DPA |
| Meta (WhatsApp) | Meta Platforms Ireland | 🟡 aceptar las condiciones de WhatsApp Business |
| Proveedor SMTP | Recomendado en la UE (p. ej. Brevo) | 🟡 |

## 9. Documentación pendiente (la preparo en su momento)
- ⚖️ Contrato de encargo del tratamiento (Verantia ↔ negocio) con anexo de subencargados y plazos.
- ⚖️ Plantilla de política de privacidad (segunda capa) para cada negocio.
- 🟡 Registro de actividades de tratamiento (del negocio, y de Verantia como encargada).
- 🟡 Procedimiento de ejercicio de derechos y de **brechas de seguridad** (notificar a la AEPD en 72 h; las alertas técnicas ya avisan de fallos).
- ⚖️ Análisis de riesgos y valoración de si hace falta EIPD (con estas medidas —sin audio, sin datos de salud, sin perfilado— probablemente no, pero debe quedar documentado).

## Registro de revisiones
| Fecha | Entrega | Resultado |
|---|---|---|
| 27/09/2026 | BD (migraciones 001–005) + flujos n8n 01–06 | Todo lo técnico ✅ y probado. Abiertos: configuración de Retell, contratos, política por negocio, n8n de producción, plan Pro |
