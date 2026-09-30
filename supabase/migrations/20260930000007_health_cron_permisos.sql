-- Verantia Voice · 007 · fn_voz_health: leer cron.job con permisos propios
-- La clave secret (rol service_role) no tiene acceso al esquema cron. La función pasa a SECURITY DEFINER
-- (se ejecuta con el dueño de la función, que sí lo tiene), con search_path fijo, y solo consulta
-- si la purga RGPD está programada. Sigue ejecutable únicamente por service_role.
create or replace function public.fn_voz_health()
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_cron boolean := false;
begin
  begin
    if to_regclass('cron.job') is not null then
      execute $q$select exists (select 1 from cron.job where jobname = 'verantia-purga-rgpd' and active)$q$ into v_cron;
    end if;
  exception when others then
    v_cron := false;   -- si no se puede comprobar, se avisa como "no activa" (fallo seguro)
  end;
  return jsonb_build_object(
    'ok', true,
    'negocios_activos', (select count(*) from public.tenants where activo),
    'llamadas_24h', (select count(*) from public.calls where created_at > now() - interval '24 hours'),
    'derivadas_24h', (select count(*) from public.calls where escalada and created_at > now() - interval '24 hours'),
    'errores_24h', (select count(*) from public.error_log where created_at > now() - interval '24 hours'),
    'errores_por_codigo', coalesce((select jsonb_object_agg(codigo, n) from (
        select coalesce(codigo, '?') codigo, count(*) n from public.error_log
        where created_at > now() - interval '24 hours' group by 1) x), '{}'::jsonb),
    'purga_programada', v_cron);
end $$;

revoke all on function public.fn_voz_health() from public, anon, authenticated;
grant execute on function public.fn_voz_health() to service_role;
