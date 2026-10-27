-- =====================================================================
--  PADEL TRACKING - Parche v2  (correr DESPUÉS de 01_esquema_padel.sql)
--  1) Fecha de inicio del torneo
--  2) Formato de partido configurable (por torneo y por partido)
--  3) El compañero debe ACEPTAR la invitación de pareja
-- =====================================================================

-- 1 y 2 -----------------------------------------------------------------
alter table public.torneos
  add column fecha_inicio date,
  add column config jsonb not null
    default '{"sets":3,"juegos":6,"tb":7,"stb":0,"oro":true}'::jsonb
    check (jsonb_typeof(config) = 'object');

-- config NULL en un partido = usa el formato del torneo
alter table public.partidos_fixture
  add column config jsonb check (config is null or jsonb_typeof(config) = 'object');

grant update (config) on public.partidos_fixture to authenticated;

-- Solo el organizador cambia el formato de un partido, y solo antes de empezar
create or replace function private.validar_cambio_partido()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.estado = 'finalizado' then
    raise exception 'Un partido finalizado no se puede modificar';
  end if;

  if new.config is distinct from old.config then
    if old.estado <> 'pendiente' then
      raise exception 'El formato no se puede cambiar con el partido ya iniciado';
    end if;
    if not exists (select 1 from public.torneos t
                   where t.id = new.torneo_id and t.organizador_id = (select auth.uid())) then
      raise exception 'Solo el organizador puede cambiar el formato del partido';
    end if;
  end if;

  if new.estado = 'finalizado' then
    if new.pareja_a_id is null or new.pareja_b_id is null then
      raise exception 'No se puede cerrar un partido sin las dos parejas definidas';
    end if;
    if new.pareja_ganadora_id is null
       or new.pareja_ganadora_id not in (new.pareja_a_id, new.pareja_b_id) then
      raise exception 'Debe indicarse una pareja ganadora válida';
    end if;
    if new.resultado_sets is null or new.resultado_sets = '' then
      raise exception 'Debe indicarse el resultado en sets';
    end if;
  end if;

  return new;
end;
$$;

-- 3 ---------------------------------------------------------------------
alter table public.parejas_inscritas
  add column confirmada boolean not null default true;  -- las existentes quedan confirmadas

create or replace function private.preparar_pareja()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_org boolean;
begin
  if exists (
    select 1 from public.parejas_inscritas p
    where p.torneo_id = new.torneo_id
      and p.id <> new.id
      and (p.jugador_1_id in (new.jugador_1_id, new.jugador_2_id)
        or p.jugador_2_id in (new.jugador_1_id, new.jugador_2_id))
  ) then
    raise exception 'Un jugador ya está inscrito en otra pareja de este torneo';
  end if;

  select round(avg(j.elo_actual))::integer
    into new.elo_promedio_pareja
  from public.jugadores j
  where j.id in (new.jugador_1_id, new.jugador_2_id);

  if tg_op = 'INSERT' then
    -- con compañero: queda pendiente hasta que él acepte
    new.confirmada := (new.jugador_2_id is null);
  elsif v_uid is not null then
    if new.jugador_2_id is distinct from old.jugador_2_id then
      select exists (select 1 from public.torneos t
                     where t.id = new.torneo_id and t.organizador_id = v_uid) into v_org;
      if not (v_uid = old.jugador_1_id or v_org
              or (v_uid = old.jugador_2_id and new.jugador_2_id is null)) then
        raise exception 'No podés cambiar el compañero de esta pareja';
      end if;
      new.confirmada := (new.jugador_2_id is null);
    elsif new.confirmada and not old.confirmada
          and v_uid is distinct from new.jugador_2_id then
      raise exception 'Solo el compañero invitado puede aceptar la inscripción';
    end if;
  end if;

  return new;
end;
$$;

drop trigger parejas_preparar on public.parejas_inscritas;
create trigger parejas_preparar
  before insert or update on public.parejas_inscritas
  for each row execute function private.preparar_pareja();

-- Permisos: solo se pueden tocar compañero y confirmación; el invitado también
revoke update on public.parejas_inscritas from authenticated;
grant update (jugador_2_id, confirmada) on public.parejas_inscritas to authenticated;

drop policy "parejas_editar" on public.parejas_inscritas;
create policy "parejas_editar" on public.parejas_inscritas
  for update to authenticated
  using (
    (select auth.uid()) in (jugador_1_id, jugador_2_id)
    or exists (select 1 from public.torneos t
               where t.id = parejas_inscritas.torneo_id and t.organizador_id = (select auth.uid()))
  )
  -- el trigger preparar_pareja valida quién puede cada cambio (p. ej. el invitado puede rechazar dejando el campo vacío)
  with check (true);
