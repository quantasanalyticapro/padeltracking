-- Evita crear una solicitud pendiente o un push cuando el organizador se asigna
-- a sí mismo como anotador. Preparado como parche local; no aplicado en Supabase.

create or replace function private.validar_designacion_anotador()
returns trigger language plpgsql set search_path = '' as $$
declare v_organizador uuid;
begin
  if new.anotador_id is distinct from old.anotador_id
     or (new.anotador_id is not null and old.anotador_estado = 'rechazado')
     or (new.anotador_id is not null and old.anotador_estado <> 'aceptado'
         and exists (select 1 from public.torneos t
                     where t.id = new.torneo_id
                       and t.organizador_id = new.anotador_id)) then
    if new.anotador_id is null then
      new.anotador_estado := 'sin_asignar';
    else
      select t.organizador_id into v_organizador
      from public.torneos t
      where t.id = new.torneo_id;

      if v_organizador is distinct from (select auth.uid()) then
        raise exception 'Solo el organizador puede designar un anotador.';
      end if;

      new.anotador_estado := case
        when new.anotador_id = v_organizador then 'aceptado'
        else 'pendiente'
      end;
    end if;
  end if;
  return new;
end;
$$;

create or replace function private.push_designacion_anotador()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_nombre text; v_org uuid;
begin
  if new.anotador_id is not null and (
    new.anotador_id is distinct from old.anotador_id
    or (old.anotador_estado = 'rechazado' and new.anotador_estado = 'pendiente')
  ) then
    select t.nombre, t.organizador_id into v_nombre, v_org
    from public.torneos t where t.id = new.torneo_id;

    if new.anotador_id is distinct from v_org then
      perform private.encolar_aviso_push(new.anotador_id, 'Nueva designación de anotador',
        'Te designaron para anotar un partido de ' || coalesce(v_nombre, 'un torneo') || '. Aceptá o rechazá desde la campanita.', 'anotador-' || new.id::text);
    end if;
  elsif old.anotador_estado = 'pendiente' and new.anotador_estado in ('aceptado', 'rechazado') then
    select t.organizador_id into v_org from public.torneos t where t.id = new.torneo_id;

    if new.anotador_id is distinct from v_org then
      perform private.encolar_aviso_push(v_org,
        case when new.anotador_estado = 'aceptado' then 'Anotador confirmado' else 'Designación rechazada' end,
        'El jugador respondió a la designación de anotador.', 'anotador-respuesta-' || new.id::text);
    end if;
  end if;
  return new;
end;
$$;
