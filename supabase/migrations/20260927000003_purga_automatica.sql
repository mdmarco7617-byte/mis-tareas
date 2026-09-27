-- ═══════════════════════════════════════════════════════════════════════════
-- Verantia Voice · 003 · Purga RGPD automática (pg_cron de Supabase)
-- Todos los días a las 03:15 UTC: borra transcripciones caducadas y errores de más de 90 días.
-- Va en la propia base de datos para que la retención se cumpla aunque n8n esté caído.
-- ═══════════════════════════════════════════════════════════════════════════
create extension if not exists pg_cron;

do $$
begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'verantia-purga-rgpd';
  perform cron.schedule('verantia-purga-rgpd', '15 3 * * *', 'select public.fn_purge_expired()');
end $$;
