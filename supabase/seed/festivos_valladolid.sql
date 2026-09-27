-- Festivos zona 'valladolid' (nacionales + Castilla y León + locales de Valladolid capital).
--
-- ⚠️ VERIFICAR cada año con el BOCyL (calendario laboral autonómico, se publica en otoño)
--    y con el Ayuntamiento de Valladolid (2 fiestas locales). Cuando un festivo cae en
--    domingo, la Junta puede trasladarlo al lunes: esos traslados NO están incluidos aquí.
-- Un negocio que abre en festivo: tenants.zona_festivos = null y sus cierres en `closures`.

insert into public.holidays (zona, fecha, nombre) values
  ('valladolid', '2026-10-12', 'Fiesta Nacional de España'),
  ('valladolid', '2026-11-01', 'Todos los Santos (domingo: revisar traslado)'),
  ('valladolid', '2026-12-06', 'Día de la Constitución (domingo: revisar traslado)'),
  ('valladolid', '2026-12-08', 'Inmaculada Concepción'),
  ('valladolid', '2026-12-25', 'Navidad'),
  ('valladolid', '2027-01-01', 'Año Nuevo'),
  ('valladolid', '2027-01-06', 'Epifanía del Señor'),
  ('valladolid', '2027-03-25', 'Jueves Santo'),
  ('valladolid', '2027-03-26', 'Viernes Santo'),
  ('valladolid', '2027-04-23', 'Fiesta de Castilla y León'),
  ('valladolid', '2027-05-01', 'Fiesta del Trabajo'),
  ('valladolid', '2027-05-13', 'San Pedro Regalado (local, verificar)'),
  ('valladolid', '2027-08-15', 'Asunción de la Virgen (domingo: revisar traslado)'),
  ('valladolid', '2027-09-08', 'Virgen de San Lorenzo (local, verificar)'),
  ('valladolid', '2027-10-12', 'Fiesta Nacional de España'),
  ('valladolid', '2027-11-01', 'Todos los Santos'),
  ('valladolid', '2027-12-06', 'Día de la Constitución'),
  ('valladolid', '2027-12-08', 'Inmaculada Concepción'),
  ('valladolid', '2027-12-25', 'Navidad')
on conflict (zona, fecha) do update set nombre = excluded.nombre;
