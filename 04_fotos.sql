-- =====================================================================
--  PADEL TRACKING - Parche v4: fotos de jugadores (correr después de 01, 02 y 03)
-- =====================================================================

-- Dirección de la foto (solo se acepta una imagen de NUESTRO almacenamiento)
alter table public.jugadores
  add column foto_url text
  check (foto_url is null or
         foto_url like 'https://ypptwklnylrnnoqxcupe.supabase.co/storage/v1/object/public/avatares/%');

grant update (foto_url) on public.jugadores to authenticated;

-- Carpeta de fotos: lectura pública por enlace, máx. 500 KB, solo imágenes
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatares', 'avatares', true, 524288, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

-- Cada jugador solo puede escribir dentro de SU carpeta (nombre = su id)
create policy "avatares_subir_propio" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatares' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "avatares_ver_propio" on storage.objects
  for select to authenticated
  using (bucket_id = 'avatares' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "avatares_actualizar_propio" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatares' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'avatares' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "avatares_borrar_propio" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatares' and (storage.foldername(name))[1] = (select auth.uid())::text);
