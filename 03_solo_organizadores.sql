-- =====================================================================
--  PADEL TRACKING - Parche v3: solo los ORGANIZADORES pueden crear torneos
--  (correr DESPUÉS de 01 y 02)
-- =====================================================================

-- Marca de organizador. Los usuarios NO pueden editarla (solo pueden editar su nombre).
alter table public.jugadores
  add column es_organizador boolean not null default false;

drop policy "torneos_crear" on public.torneos;
create policy "torneos_crear" on public.torneos
  for insert to authenticated
  with check (
    organizador_id = (select auth.uid())
    and exists (select 1 from public.jugadores j
                where j.id = (select auth.uid()) and j.es_organizador)
  );

-- ---------------------------------------------------------------------
-- DESPUÉS de correr lo de arriba, habilitate vos como organizador
-- (cambiá el email por el tuyo y corré SOLO esta línea):
--
--   update public.jugadores set es_organizador = true where email = 'TU_EMAIL@ejemplo.com';
--
-- Para quitar el permiso: poné false en lugar de true.
-- ---------------------------------------------------------------------
