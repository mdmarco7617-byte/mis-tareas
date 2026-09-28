-- Verantia Voice · 006 · Nombre por defecto del asistente: Álex (voz masculina elegida el 28/09/2026)
alter table public.tenants alter column nombre_asistente set default 'Álex';
update public.tenants set nombre_asistente = 'Álex' where slug in ('peluqueria-demo') and nombre_asistente = 'Lucía';
