-- SOLO para pruebas en un Postgres local: crea los roles que Supabase ya trae de serie.
-- NO ejecutar en Supabase.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon')          then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role')  then create role service_role nologin bypassrls; end if;
end $$;
grant usage on schema public to anon, authenticated, service_role;

-- Sustituto local de Supabase Vault (en Supabase ya existe vault.decrypted_secrets)
create schema if not exists vault;
create table if not exists vault.secretos_locales (name text primary key, decrypted_secret text);
create or replace view vault.decrypted_secrets as select name, decrypted_secret from vault.secretos_locales;

-- Réplica local de pg_cron: el esquema existe pero service_role NO tiene acceso (como en Supabase)
create schema if not exists cron;
create table if not exists cron.job (jobname text, active boolean);
insert into cron.job select 'verantia-purga-rgpd', true where not exists (select 1 from cron.job);
revoke all on schema cron from public, anon, authenticated, service_role;
revoke all on cron.job from public, anon, authenticated, service_role;
