-- ═══════════════════════════════════════════════════════════════════════════
-- Verantia Voice · 001 · Esquema multi-tenant
-- Supabase (Postgres 15+), región UE.
--
-- Seguridad:
--   · RLS activado en todas las tablas y SIN políticas → anon y authenticated
--     no pueden leer ni escribir nada. Solo service_role (n8n) accede.
--   · Cuando exista un panel para los negocios, se añaden políticas por tenant.
-- ═══════════════════════════════════════════════════════════════════════════

create schema if not exists extensions;
create extension if not exists btree_gist with schema extensions;  -- restricción anti-solape
create extension if not exists unaccent   with schema extensions;  -- búsqueda sin tildes
grant usage on schema extensions to service_role;                   -- n8n usa unaccent/btree_gist (en Supabase ya viene concedido)

-- ─── Tipos ─────────────────────────────────────────────────────────────────
create type public.tipo_negocio       as enum ('peluqueria','barberia','estetica','restaurante','academia','otro');
create type public.tipo_recurso       as enum ('profesional','cabina','mesa','sala','otro');
create type public.estado_cita        as enum ('confirmada','cancelada','completada','no_presentado');
create type public.canal_cita         as enum ('telefono','web','whatsapp','manual');
create type public.canal_confirmacion as enum ('whatsapp','sms','email','ninguno');

-- Teléfono en formato internacional E.164 (+34600111222)
create domain public.e164 as text check (value ~ '^\+[1-9][0-9]{7,14}$');

-- ─── Utilidad: updated_at automático ───────────────────────────────────────
create or replace function public._touch_updated_at() returns trigger
language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- NEGOCIOS
-- ═══════════════════════════════════════════════════════════════════════════
create table public.tenants (
  id                          uuid primary key default gen_random_uuid(),
  slug                        text not null unique check (slug ~ '^[a-z0-9-]{3,60}$'),
  nombre                      text not null check (length(nombre) between 2 and 120),
  tipo                        public.tipo_negocio not null,
  zona_horaria                text not null default 'Europe/Madrid',
  zona_festivos               text default 'valladolid',   -- null = no aplicar festivos automáticos
  nombre_asistente            text not null default 'Lucía',
  voz_id                      text,                         -- voz en Retell (null = la de la plantilla)
  descripcion                 text,
  direccion                   text,
  telefono_publico            text,                         -- el que el asistente puede dar a clientes
  telefono_transferencia      public.e164,                  -- a dónde pasar llamadas. NUNCA el número que se desvía al asistente (bucle)
  whatsapp_avisos             public.e164,                  -- WhatsApp del negocio para derivaciones
  email_avisos                text,
  politica_cancelacion        text,
  cancelacion_min_horas       int  not null default 0   check (cancelacion_min_horas between 0 and 168),
  antelacion_min_minutos      int  not null default 60  check (antelacion_min_minutos between 0 and 10080),
  reserva_max_dias            int  not null default 60  check (reserva_max_dias between 1 and 365),
  paso_minutos                int  not null default 15  check (paso_minutos in (5,10,15,20,30,60)),
  max_comensales              int  not null default 8   check (max_comensales between 1 and 100),
  canal_confirmacion          public.canal_confirmacion not null default 'whatsapp',
  sms_respaldo                boolean not null default true,
  guardar_transcripcion       boolean not null default false,
  retencion_transcripcion_dias int not null default 30  check (retencion_transcripcion_dias between 1 and 365),
  plan                        text,
  minutos_incluidos           int,
  activo                      boolean not null default true,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);
create trigger trg_tenants_updated before update on public.tenants
  for each row execute function public._touch_updated_at();

-- Número Verantia (al que desvía el negocio) → negocio
create table public.phone_numbers (
  numero      public.e164 primary key,
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  activo      boolean not null default true,
  created_at  timestamptz not null default now()
);
create index on public.phone_numbers (tenant_id);

-- ═══════════════════════════════════════════════════════════════════════════
-- CATÁLOGO: servicios, recursos (profesionales / cabinas / mesas) y horarios
-- ═══════════════════════════════════════════════════════════════════════════
create table public.services (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id) on delete cascade,
  codigo        text not null check (codigo ~ '^[a-z0-9_]{2,40}$'),   -- lo que usa el LLM: corte_mujer
  nombre        text not null check (length(nombre) between 2 and 120),
  sinonimos     text[] not null default '{}',                          -- {'balayage','reflejos'}
  categoria     text,
  descripcion   text,
  precio        numeric(8,2) check (precio >= 0),
  precio_desde  boolean not null default false,                       -- "desde 45 €"
  duracion_min  int not null check (duracion_min between 5 and 600),
  margen_min    int not null default 0 check (margen_min between 0 and 120),  -- limpieza/preparación tras el servicio
  activo        boolean not null default true,
  orden         int not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (tenant_id, codigo),
  unique (id, tenant_id)
);
create trigger trg_services_updated before update on public.services
  for each row execute function public._touch_updated_at();

-- Peluquería/estética: profesional o cabina (capacidad 1).
-- Restaurante: mesa con capacidad = comensales máximos (capacidad_min evita dar una mesa de 6 a 1 persona).
create table public.resources (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id) on delete cascade,
  nombre         text not null check (length(nombre) between 1 and 80),
  tipo           public.tipo_recurso not null default 'profesional',
  capacidad      int not null default 1 check (capacidad between 1 and 100),
  capacidad_min  int not null default 1 check (capacidad_min >= 1),
  activo         boolean not null default true,
  orden          int not null default 0,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  check (capacidad_min <= capacidad),
  unique (tenant_id, nombre),
  unique (id, tenant_id)
);
create trigger trg_resources_updated before update on public.resources
  for each row execute function public._touch_updated_at();

-- Qué recurso puede hacer qué servicio (las FK compuestas impiden mezclar negocios)
create table public.resource_services (
  tenant_id    uuid not null,
  resource_id  uuid not null,
  service_id   uuid not null,
  primary key (resource_id, service_id),
  foreign key (resource_id, tenant_id) references public.resources(id, tenant_id) on delete cascade,
  foreign key (service_id,  tenant_id) references public.services(id,  tenant_id) on delete cascade
);
create index on public.resource_services (service_id);

-- Horario. resource_id null = horario del negocio.
-- Si un recurso tiene filas propias, trabaja solo en esas franjas (y siempre dentro del horario del negocio).
create table public.business_hours (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  resource_id  uuid,
  dia_semana   smallint not null check (dia_semana between 1 and 7),   -- ISO: 1 = lunes … 7 = domingo
  hora_inicio  time not null,
  hora_fin     time not null,
  check (hora_fin > hora_inicio),
  foreign key (resource_id, tenant_id) references public.resources(id, tenant_id) on delete cascade
);
create index on public.business_hours (tenant_id, dia_semana) where resource_id is null;
create index on public.business_hours (resource_id, dia_semana) where resource_id is not null;

-- Cierres puntuales: vacaciones, formación, baja de un profesional… (resource_id null = todo el negocio)
create table public.closures (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  resource_id  uuid,
  periodo      tstzrange not null check (not isempty(periodo)),
  motivo       text,
  created_at   timestamptz not null default now(),
  foreign key (resource_id, tenant_id) references public.resources(id, tenant_id) on delete cascade
);
create index on public.closures using gist (tenant_id, periodo);

-- Festivos por zona (nacionales + Castilla y León + locales en una sola lista por zona)
create table public.holidays (
  fecha   date not null,
  zona    text not null,
  nombre  text not null,
  primary key (zona, fecha)
);

create table public.faqs (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  pregunta    text not null,
  respuesta   text not null,
  categoria   text,
  orden       int not null default 0,
  activo      boolean not null default true
);
create index on public.faqs (tenant_id);

-- ═══════════════════════════════════════════════════════════════════════════
-- CLIENTES Y CITAS
-- ═══════════════════════════════════════════════════════════════════════════
-- Minimización (RGPD): teléfono, nombre y email opcional. Nada más.
create table public.customers (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  telefono    public.e164 not null,
  nombre      text check (length(nombre) <= 80),
  email       text check (email ~* '^[^@\s]+@[^@\s]+\.[a-z]{2,}$'),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (tenant_id, telefono),
  unique (id, tenant_id)
);
create trigger trg_customers_updated before update on public.customers
  for each row execute function public._touch_updated_at();

create table public.appointments (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id) on delete cascade,
  referencia        text not null check (referencia ~ '^[0-9]{6}$'),   -- 6 dígitos: fácil de dictar
  customer_id       uuid,
  nombre_cliente    text not null check (length(nombre_cliente) between 1 and 80),
  service_id        uuid not null,
  resource_id       uuid not null,
  inicio            timestamptz not null,
  fin               timestamptz not null,
  fin_bloqueo       timestamptz not null,           -- fin + margen de limpieza/preparación
  comensales        int not null default 1 check (comensales between 1 and 100),
  estado            public.estado_cita not null default 'confirmada',
  canal             public.canal_cita not null default 'telefono',
  notas             text check (length(notas) <= 500),
  idempotency_key   text,
  call_id           text,
  reprogramaciones  int not null default 0,
  cancelada_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  check (fin > inicio),
  check (fin_bloqueo >= fin),
  unique (tenant_id, referencia),
  unique (tenant_id, idempotency_key),
  foreign key (customer_id, tenant_id) references public.customers(id, tenant_id) on delete set null (customer_id),
  foreign key (service_id,  tenant_id) references public.services(id,  tenant_id),
  foreign key (resource_id, tenant_id) references public.resources(id, tenant_id),
  -- ▼ LA GARANTÍA ANTI-DOBLE-RESERVA ▼
  -- La base de datos rechaza dos citas confirmadas del mismo recurso que se solapen,
  -- aunque lleguen exactamente a la vez y aunque falle cualquier comprobación previa.
  constraint citas_sin_solape exclude using gist (
    resource_id with =,
    tstzrange(inicio, fin_bloqueo, '[)') with &&
  ) where (estado = 'confirmada')
);
create trigger trg_appointments_updated before update on public.appointments
  for each row execute function public._touch_updated_at();
create index on public.appointments (tenant_id, inicio) where estado = 'confirmada';
create index on public.appointments (customer_id, inicio);

-- ═══════════════════════════════════════════════════════════════════════════
-- LLAMADAS Y ERRORES
-- ═══════════════════════════════════════════════════════════════════════════
create table public.calls (
  call_id                 text primary key,
  tenant_id               uuid references public.tenants(id) on delete cascade,
  from_number             text,
  to_number               text,
  iniciada_at             timestamptz,
  finalizada_at           timestamptz,
  duracion_seg            int,
  resultado               text,          -- resuelta / derivada / abandonada / error …
  escalada                boolean not null default false,
  motivo_escalada         text,
  resumen                 text,
  transcripcion           text,          -- solo si el negocio lo activa, con caducidad
  transcripcion_expira_at timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
create trigger trg_calls_updated before update on public.calls
  for each row execute function public._touch_updated_at();
create index on public.calls (tenant_id, iniciada_at);

-- Errores técnicos. SIN datos personales en `detalle`.
create table public.error_log (
  id          bigint generated always as identity primary key,
  tenant_id   uuid references public.tenants(id) on delete set null,
  origen      text not null,
  codigo      text,
  detalle     jsonb,
  created_at  timestamptz not null default now()
);
create index on public.error_log (created_at);

-- ═══════════════════════════════════════════════════════════════════════════
-- SEGURIDAD
-- ═══════════════════════════════════════════════════════════════════════════
do $$
declare t text;
begin
  foreach t in array array['tenants','phone_numbers','services','resources','resource_services',
                           'business_hours','closures','holidays','faqs','customers',
                           'appointments','calls','error_log']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end $$;
