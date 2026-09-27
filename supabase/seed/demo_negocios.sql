-- Dos negocios de demostración: una peluquería (piloto) y un restaurante (para validar
-- que el mismo modelo sirve con mesas). Números +34983000001/2 son ficticios.

-- ─── Peluquería ────────────────────────────────────────────────────────────
insert into public.tenants (id, slug, nombre, tipo, nombre_asistente, descripcion, direccion, telefono_publico,
                            telefono_transferencia, whatsapp_avisos, politica_cancelacion, cancelacion_min_horas,
                            antelacion_min_minutos, paso_minutos)
values ('11111111-1111-1111-1111-111111111111', 'peluqueria-demo', 'Peluquería Demo', 'peluqueria', 'Lucía',
        'Peluquería de barrio en el centro de Valladolid. Trabajamos con productos sin amoniaco.',
        'Calle Santiago 1, Valladolid', '983 000 001', '+34600000001', '+34600000001',
        'Puedes cancelar o cambiar tu cita sin coste hasta 12 horas antes.', 12, 60, 15);

insert into public.phone_numbers (numero, tenant_id) values ('+34983000001', '11111111-1111-1111-1111-111111111111');

insert into public.services (tenant_id, codigo, nombre, sinonimos, categoria, precio, precio_desde, duracion_min, margen_min, orden) values
  ('11111111-1111-1111-1111-111111111111', 'corte_mujer',  'Corte de mujer',   '{corte señora,cortar el pelo}', 'Corte', 22, false, 45, 0, 1),
  ('11111111-1111-1111-1111-111111111111', 'corte_hombre', 'Corte de hombre',  '{corte caballero}',             'Corte', 14, false, 30, 0, 2),
  ('11111111-1111-1111-1111-111111111111', 'tinte',        'Tinte raíz',       '{color,tinte de raiz}',         'Color', 38, false, 90, 15, 3),
  ('11111111-1111-1111-1111-111111111111', 'mechas',       'Mechas',           '{balayage,reflejos,babylights}','Color', 65, true, 120, 15, 4),
  ('11111111-1111-1111-1111-111111111111', 'peinado',      'Lavar y peinar',   '{peinar,lavado y peinado,brushing}', 'Peinado', 16, false, 30, 0, 5);

insert into public.resources (tenant_id, nombre, tipo, orden) values
  ('11111111-1111-1111-1111-111111111111', 'Laura', 'profesional', 1),
  ('11111111-1111-1111-1111-111111111111', 'Marta', 'profesional', 2);

-- Laura hace todo; Marta solo cortes y peinados
insert into public.resource_services (tenant_id, resource_id, service_id)
select s.tenant_id, r.id, s.id from public.services s join public.resources r on r.tenant_id = s.tenant_id
where s.tenant_id = '11111111-1111-1111-1111-111111111111'
  and (r.nombre = 'Laura' or s.codigo in ('corte_mujer','corte_hombre','peinado'));

-- L-V 10:00-14:00 y 16:00-20:00 · S 10:00-14:00 · D cerrado
insert into public.business_hours (tenant_id, dia_semana, hora_inicio, hora_fin)
select '11111111-1111-1111-1111-111111111111'::uuid, d, h.i, h.f
from generate_series(1, 5) d, (values (time '10:00', time '14:00'), (time '16:00', time '20:00')) h(i, f)
union all select '11111111-1111-1111-1111-111111111111'::uuid, 6, '10:00', '14:00';

-- Marta no trabaja los sábados
insert into public.business_hours (tenant_id, resource_id, dia_semana, hora_inicio, hora_fin)
select '11111111-1111-1111-1111-111111111111'::uuid, r.id, d, h.i, h.f
from public.resources r, generate_series(1, 5) d, (values (time '10:00', time '14:00'), (time '16:00', time '20:00')) h(i, f)
where r.tenant_id = '11111111-1111-1111-1111-111111111111' and r.nombre = 'Marta';

insert into public.faqs (tenant_id, pregunta, respuesta, orden) values
  ('11111111-1111-1111-1111-111111111111', '¿Se puede pagar con tarjeta?', 'Sí, tarjeta, Bizum y efectivo.', 1),
  ('11111111-1111-1111-1111-111111111111', '¿Hay aparcamiento?', 'Hay un parking público a 100 metros, en la Plaza Mayor.', 2);

-- ─── Restaurante ───────────────────────────────────────────────────────────
insert into public.tenants (id, slug, nombre, tipo, nombre_asistente, telefono_publico, whatsapp_avisos,
                            politica_cancelacion, cancelacion_min_horas, antelacion_min_minutos, paso_minutos, max_comensales)
values ('22222222-2222-2222-2222-222222222222', 'restaurante-demo', 'Restaurante Demo', 'restaurante', 'Carmen',
        '983 000 002', '+34600000002', 'Avísanos si no puedes venir.', 2, 120, 30, 8);

insert into public.phone_numbers (numero, tenant_id) values ('+34983000002', '22222222-2222-2222-2222-222222222222');

-- Un único "servicio" (la mesa). Comida o cena lo decide la hora; los turnos salen del horario.
insert into public.services (tenant_id, codigo, nombre, sinonimos, duracion_min, orden) values
  ('22222222-2222-2222-2222-222222222222', 'mesa', 'Reserva de mesa', '{reserva,comer,comida,cenar,cena,almuerzo}', 90, 1);

-- Mesas: la capacidad es el máximo de comensales; capacidad_min evita sentar a 1 persona en una de 6
insert into public.resources (tenant_id, nombre, tipo, capacidad, capacidad_min, orden) values
  ('22222222-2222-2222-2222-222222222222', 'Mesa 1', 'mesa', 2, 1, 1),
  ('22222222-2222-2222-2222-222222222222', 'Mesa 2', 'mesa', 2, 1, 2),
  ('22222222-2222-2222-2222-222222222222', 'Mesa 3', 'mesa', 4, 2, 3),
  ('22222222-2222-2222-2222-222222222222', 'Mesa 4', 'mesa', 4, 2, 4),
  ('22222222-2222-2222-2222-222222222222', 'Mesa 5', 'mesa', 6, 3, 5);

insert into public.resource_services (tenant_id, resource_id, service_id)
select s.tenant_id, r.id, s.id from public.services s join public.resources r on r.tenant_id = s.tenant_id
where s.tenant_id = '22222222-2222-2222-2222-222222222222';

-- Ma-D: comidas 13:30-16:00 (la reserva debe terminar a las 16:00), cenas 20:30-23:30
insert into public.business_hours (tenant_id, dia_semana, hora_inicio, hora_fin)
select '22222222-2222-2222-2222-222222222222'::uuid, d, h.i, h.f
from generate_series(2, 7) d, (values (time '13:30', time '16:00'), (time '20:30', time '23:30')) h(i, f);
