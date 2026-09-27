# Verantia Voice — Base de datos (Supabase)

Contrato de herramientas: [`../docs/asistente-telefonico-ia/CONTRATO_HERRAMIENTAS.md`](../docs/asistente-telefonico-ia/CONTRATO_HERRAMIENTAS.md)

## Proyecto en producción

| | |
|---|---|
| Proyecto Supabase | **`verantia-voz`** (ref `cvbmsdliucawhzmzyylp`) — separado del proyecto del chatbot web |
| Región | eu-central-1 (Frankfurt, UE) |
| URL de la API | `https://cvbmsdliucawhzmzyylp.supabase.co` |
| Migraciones aplicadas | 001 esquema · 002 funciones · 003 purga RGPD diaria (pg_cron, 03:15 UTC) · 004 ajustes de los advisors |
| Datos cargados | Festivos de Valladolid oct-2026 → 2027 y los 2 negocios demo (números ficticios +34983000001/2) |

Quitar los negocios demo cuando entre el primer cliente real:
```sql
delete from public.tenants where slug in ('peluqueria-demo', 'restaurante-demo');  -- borra en cascada todo lo suyo
```

⚠️ En plan gratuito, Supabase **pausa el proyecto tras 7 días sin actividad**. Con un asistente atendiendo llamadas reales eso tiraría el servicio: antes del primer cliente de pago, pasar la organización a plan Pro.

## Estructura

| Archivo | Qué es |
|---|---|
| `migrations/20260927000001_esquema.sql` | Tablas, restricción anti-solape, RLS y permisos |
| `migrations/20260927000002_funciones_reserva.sql` | Lógica de disponibilidad, reservas, derivación, RGPD y puntos de entrada para n8n |
| `migrations/20260927000003_purga_automatica.sql` | Tarea diaria pg_cron que aplica la retención RGPD aunque n8n esté caído |
| `migrations/20260927000004_ajustes_advisors.sql` | search_path fijo e índices sobre claves foráneas (avisos de Supabase) |
| `seed/festivos_valladolid.sql` | Festivos oct-2026 → 2027 (verificar con BOCyL cada año) |
| `seed/demo_negocios.sql` | Peluquería y restaurante de ejemplo (**no cargar en producción**) |
| `tests/` | 77 tests funcionales + prueba de concurrencia real |

## Instalar en Supabase

1. Crear el proyecto en **región UE** (Frankfurt o Irlanda).
2. **SQL Editor** → pegar y ejecutar, en este orden:
   1. Las 4 migraciones de `migrations/`, en orden
   2. `seed/festivos_valladolid.sql`
   3. (opcional, para pruebas) `seed/demo_negocios.sql`

   Con la CLI de Supabase: copiar la carpeta `migrations` a `supabase/migrations` del proyecto y hacer `supabase db push`.
3. En n8n, crear la credencial con la **service_role key** (Project Settings → API). **Nunca** la anon key: con la anon key todas las funciones y tablas están bloqueadas a propósito.

## Cómo lo llama n8n

Una sola llamada por herramienta (HTTP Request a la API REST de Supabase):

```
POST https://<proyecto>.supabase.co/rest/v1/rpc/fn_tool_dispatch
apikey: <service_role>
Authorization: Bearer <service_role>
Content-Type: application/json

{ "p_to_number": "+34983000001", "p_from_number": "+34600111222", "p_call_id": "call_abc",
  "p_tool": "check_availability", "p_args": { "servicio": "corte_mujer", "fecha": "2026-10-05", "hora": "10:00" } }
```

Otras funciones: `fn_tenant_context` (inicio de llamada), `fn_log_call` (fin), `fn_purge_expired` (cron diario), `fn_forget_customer` (derecho de supresión), `fn_add_closure_days` (vacaciones).

## Garantías probadas

- **Doble comprobación**: `check_availability` (1ª) y otra vez dentro de `create_appointment`, bajo bloqueo por negocio (2ª).
- **Anti doble reserva a nivel de base de datos**: restricción `citas_sin_solape`. 50 conexiones simultáneas reservando el mismo hueco → 1 cita; 50 inserciones directas solapadas, sin pasar por las funciones → 1 guardada.
- **Idempotencia**: si Retell reintenta `create_appointment` en la misma llamada, devuelve la misma cita.
- **Multi-tenant**: el negocio sale del número llamado, nunca de lo que diga el LLM. Las claves foráneas compuestas impiden mezclar datos de negocios.
- **Permisos**: anon y authenticated no pueden leer tablas ni ejecutar funciones (probado).
- **Latencia** (Postgres local): 11–17 ms por comprobación, ~50 ms para buscar huecos en 14 días.

## Ejecutar los tests en local

Requiere un Postgres 15+ desechable (con `btree_gist` y `unaccent`):

```bash
PGHOST=/ruta/socket PGPORT=5432 ./supabase/tests/run_local.sh      # N=50 para más presión en concurrencia
```

`tests/00_bootstrap_local.sql` crea los roles que Supabase ya trae (anon, authenticated, service_role). **No ejecutarlo en Supabase.**

## Modelo por sector

| | Peluquería / estética | Restaurante |
|---|---|---|
| `resources` | Profesionales o cabinas (capacidad 1) | Mesas (`capacidad` = máx. comensales, `capacidad_min` evita dar una mesa grande a 1 persona) |
| `services` | Catálogo con precio y duración | Uno solo: `mesa` (comida o cena lo marca la hora) |
| Asignación | Profesional libre con menos citas ese día | Mesa libre más pequeña que sirva |
| Horario propio del recurso | Sí (p. ej. Marta no trabaja sábados) | No hace falta |

Pendiente para más adelante (no en el MVP): aforo por turno sin mesas, clases grupales con plazas (academias), y unir mesas para grupos grandes (hoy esto se deriva a una persona).

## Avisos de Supabase que quedan (revisados)

- **RLS enabled, no policy** (INFO): intencionado. Sin políticas, anon y authenticated no ven nada; solo service_role (n8n).
- **Unused index** (INFO): normal en una base de datos recién creada; se usarán con tráfico real.
