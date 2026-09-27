-- ═══════════════════════════════════════════════════════════════════════════
-- Verantia Voice · 004 · Ajustes tras los avisos (advisors) de Supabase
--   · search_path fijo en las funciones auxiliares (aviso de seguridad 0011)
--   · índices que cubren las claves foráneas compuestas (aviso de rendimiento 0001)
-- Aviso que se deja a propósito: "RLS enabled, no policy" en todas las tablas.
-- Es intencionado: sin políticas, anon/authenticated no ven nada; solo service_role (n8n).
-- ═══════════════════════════════════════════════════════════════════════════

alter function public._dia_es(date)                    set search_path = public;
alter function public._clean(text, int)                set search_path = public;
alter function public.fn_normalize_phone(text)         set search_path = public;
alter function public._parse_date(text)                set search_path = public;
alter function public._parse_time(text)                set search_path = public;
alter function public._parse_int(text, int, int)       set search_path = public;
alter function public._hhmm(timestamptz, text)         set search_path = public;
alter function public._mensaje(text)                   set search_path = public;
alter function public._resp(text, jsonb)               set search_path = public;
alter function public._servicio_json(public.services)  set search_path = public;

-- Índices sobre las FK compuestas (sustituyen a los parciales equivalentes)
drop index if exists public.appointments_customer_id_inicio_idx;
create index if not exists appointments_customer_tenant_idx    on public.appointments (customer_id, tenant_id);
create index if not exists appointments_service_tenant_idx     on public.appointments (service_id, tenant_id);
create index if not exists appointments_resource_tenant_idx    on public.appointments (resource_id, tenant_id);

drop index if exists public.business_hours_resource_id_dia_semana_idx;
create index if not exists business_hours_resource_tenant_idx  on public.business_hours (resource_id, tenant_id);

create index if not exists closures_resource_tenant_idx        on public.closures (resource_id, tenant_id);
create index if not exists error_log_tenant_idx                on public.error_log (tenant_id);

drop index if exists public.resource_services_service_id_idx;
create index if not exists resource_services_resource_tenant_idx on public.resource_services (resource_id, tenant_id);
create index if not exists resource_services_service_tenant_idx  on public.resource_services (service_id, tenant_id);
