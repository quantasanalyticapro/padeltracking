-- Propuestas de pareja creadas por el organizador para dos jugadores inscriptos solos.
-- Ejecutar una sola vez, después de 02_cambios_v2.sql.

create table if not exists public.propuestas_pareja (
  id uuid primary key default gen_random_uuid(),
  torneo_id uuid not null references public.torneos(id) on delete cascade,
  pareja_origen_id uuid not null references public.parejas_inscritas(id) on delete cascade,
  jugador_origen_id uuid not null references public.jugadores(id) on delete cascade,
  jugador_invitado_id uuid not null references public.jugadores(id) on delete cascade,
  organizador_id uuid not null references public.jugadores(id) on delete cascade,
  estado text not null default 'pendiente'
    check (estado in ('pendiente','aceptada','rechazada','cancelada')),
  creado_at timestamptz not null default now(),
  respondido_at timestamptz,
  check (jugador_origen_id <> jugador_invitado_id)
);

create index if not exists propuestas_pareja_torneo_estado_idx
  on public.propuestas_pareja (torneo_id, estado, creado_at);
create index if not exists propuestas_pareja_invitado_idx
  on public.propuestas_pareja (jugador_invitado_id, estado);

alter table public.propuestas_pareja enable row level security;
revoke all on public.propuestas_pareja from public, anon, authenticated;
grant select on public.propuestas_pareja to authenticated;
drop policy if exists propuestas_pareja_ver on public.propuestas_pareja;
create policy propuestas_pareja_ver on public.propuestas_pareja
  for select to authenticated
  using (
    (select auth.uid()) in (jugador_origen_id, jugador_invitado_id, organizador_id)
  );

-- Mantiene la protección existente y reconoce la aceptación de una propuesta
-- hecha por el organizador. La invitación solo confirma si acepta el destinatario.
create or replace function private.preparar_pareja()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_org boolean;
  v_propuesta boolean := false;
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
    new.confirmada := (new.jugador_2_id is null);
  elsif v_uid is not null then
    if new.jugador_2_id is distinct from old.jugador_2_id then
      select exists (
        select 1 from public.torneos t
        where t.id = new.torneo_id and t.organizador_id = v_uid
      ) into v_org;
      select exists (
        select 1 from public.propuestas_pareja q
        where q.torneo_id = new.torneo_id
          and q.pareja_origen_id = new.id
          and q.jugador_origen_id = new.jugador_1_id
          and q.jugador_invitado_id = new.jugador_2_id
          and q.estado = 'pendiente'
      ) into v_propuesta;

      if not (v_uid = old.jugador_1_id or v_org
              or (v_uid = old.jugador_2_id and new.jugador_2_id is null)
              or (v_propuesta and v_uid = new.jugador_2_id)) then
        raise exception 'No podés cambiar el compañero de esta pareja';
      end if;
      new.confirmada := v_propuesta and v_uid = new.jugador_2_id;
      if new.jugador_2_id is null then new.confirmada := true; end if;
    elsif new.confirmada and not old.confirmada
          and v_uid is distinct from new.jugador_2_id then
      raise exception 'Solo el compañero invitado puede aceptar la inscripción';
    end if;
  end if;

  return new;
end;
$$;

-- Crea una propuesta sin alterar ni borrar las dos inscripciones individuales.
create or replace function public.proponer_pareja_organizador(
  p_pareja_origen_id uuid,
  p_pareja_invitada_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_a public.parejas_inscritas%rowtype;
  v_b public.parejas_inscritas%rowtype;
  v_org uuid;
  v_propuesta_id uuid;
begin
  if v_uid is null then raise exception 'Tenés que iniciar sesión.'; end if;
  if p_pareja_origen_id = p_pareja_invitada_id then
    raise exception 'Elegí dos inscriptos distintos.';
  end if;

  select * into v_a from public.parejas_inscritas where id = p_pareja_origen_id;
  select * into v_b from public.parejas_inscritas where id = p_pareja_invitada_id;
  if v_a.id is null or v_b.id is null then
    raise exception 'No se encontraron ambas inscripciones.';
  end if;
  if v_a.torneo_id <> v_b.torneo_id then
    raise exception 'Las dos personas deben estar inscriptas en el mismo torneo.';
  end if;
  if v_a.jugador_1_id = v_b.jugador_1_id then
    raise exception 'Elegí a dos personas distintas.';
  end if;
  select t.organizador_id into v_org from public.torneos t
    where t.id = v_a.torneo_id and t.estado = 'inscripciones_abiertas'
    for update;
  if v_org is null or v_org <> v_uid then
    raise exception 'Solo el organizador puede proponer parejas durante la inscripción.';
  end if;
  if exists (select 1 from public.partidos_fixture f where f.torneo_id = v_a.torneo_id) then
    raise exception 'El fixture ya fue generado; no se pueden proponer parejas.';
  end if;

  -- Serializa propuestas que involucren a cualquiera de estos dos jugadores.
  perform 1 from public.jugadores j
    where j.id in (v_a.jugador_1_id, v_b.jugador_1_id)
    order by j.id for update;
  perform 1 from public.parejas_inscritas p
    where p.id in (p_pareja_origen_id, p_pareja_invitada_id)
    order by p.id for update;
  select * into v_a from public.parejas_inscritas where id = p_pareja_origen_id;
  select * into v_b from public.parejas_inscritas where id = p_pareja_invitada_id;

  if v_a.torneo_id <> v_b.torneo_id
     or v_a.jugador_2_id is not null or v_b.jugador_2_id is not null
     or not v_a.confirmada or not v_b.confirmada then
    raise exception 'Solo se pueden proponer inscriptos que sigan sin compañero.';
  end if;
  if exists (
    select 1 from public.propuestas_pareja q
    where q.torneo_id = v_a.torneo_id and q.estado = 'pendiente'
      and (q.jugador_origen_id in (v_a.jugador_1_id, v_b.jugador_1_id)
        or q.jugador_invitado_id in (v_a.jugador_1_id, v_b.jugador_1_id))
  ) then
    raise exception 'Una de esas personas ya tiene una propuesta pendiente.';
  end if;

  insert into public.propuestas_pareja
    (torneo_id, pareja_origen_id, jugador_origen_id, jugador_invitado_id, organizador_id)
  values
    (v_a.torneo_id, v_a.id, v_a.jugador_1_id, v_b.jugador_1_id, v_uid)
  returning id into v_propuesta_id;
  return v_propuesta_id;
end;
$$;

-- El invitado puede aceptar o rechazar. Al aceptar, se combinan las dos filas
-- dentro de la misma transacción; al rechazar, ambas inscripciones quedan intactas.
create or replace function public.responder_propuesta_pareja(
  p_propuesta_id uuid,
  p_aceptar boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_q public.propuestas_pareja%rowtype;
  v_a public.parejas_inscritas%rowtype;
  v_b public.parejas_inscritas%rowtype;
  v_torneo_estado public.estado_torneo;
begin
  if v_uid is null then raise exception 'Tenés que iniciar sesión.'; end if;
  select * into v_q from public.propuestas_pareja where id = p_propuesta_id for update;
  if v_q.id is null or v_q.jugador_invitado_id <> v_uid then
    raise exception 'Esta propuesta no está dirigida a tu cuenta.';
  end if;
  if v_q.estado <> 'pendiente' then raise exception 'La propuesta ya fue respondida.'; end if;

  if not p_aceptar then
    update public.propuestas_pareja set estado = 'rechazada', respondido_at = now()
      where id = v_q.id;
    return;
  end if;

  select t.estado into v_torneo_estado from public.torneos t where t.id = v_q.torneo_id;
  if v_torneo_estado is distinct from 'inscripciones_abiertas'::public.estado_torneo then
    raise exception 'Las inscripciones ya cerraron.';
  end if;
  select * into v_a from public.parejas_inscritas where id = v_q.pareja_origen_id;
  select * into v_b from public.parejas_inscritas
    where torneo_id = v_q.torneo_id and jugador_1_id = v_q.jugador_invitado_id;
  if v_a.id is null or v_b.id is null then
    raise exception 'Una de las inscripciones ya no está disponible.';
  end if;

  perform 1 from public.jugadores j
    where j.id in (v_a.jugador_1_id, v_b.jugador_1_id)
    order by j.id for update;
  perform 1 from public.parejas_inscritas p
    where p.id in (v_a.id, v_b.id)
    order by p.id for update;
  select * into v_a from public.parejas_inscritas where id = v_q.pareja_origen_id;
  select * into v_b from public.parejas_inscritas
    where torneo_id = v_q.torneo_id and jugador_1_id = v_q.jugador_invitado_id;
  if v_a.id is null or v_b.id is null or v_a.id = v_b.id
     or v_a.jugador_1_id <> v_q.jugador_origen_id
     or v_a.jugador_2_id is not null or v_b.jugador_2_id is not null
     or not v_a.confirmada or not v_b.confirmada then
    raise exception 'Las inscripciones cambiaron; pedile al organizador que revise las parejas.';
  end if;

  delete from public.parejas_inscritas where id = v_b.id;
  update public.parejas_inscritas
    set jugador_2_id = v_q.jugador_invitado_id, confirmada = true
    where id = v_a.id;
  update public.propuestas_pareja set estado = 'aceptada', respondido_at = now()
    where id = v_q.id;
end;
$$;

create or replace function public.cancelar_propuesta_pareja(p_propuesta_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_q public.propuestas_pareja%rowtype;
begin
  if v_uid is null then raise exception 'Tenés que iniciar sesión.'; end if;
  select * into v_q from public.propuestas_pareja where id = p_propuesta_id for update;
  if v_q.id is null or v_q.organizador_id <> v_uid then
    raise exception 'Solo quien organiza este torneo puede cancelar la propuesta.';
  end if;
  if v_q.estado <> 'pendiente' then raise exception 'La propuesta ya fue respondida.'; end if;
  update public.propuestas_pareja set estado = 'cancelada', respondido_at = now()
    where id = v_q.id;
end;
$$;

-- Las propuestas solo se leen por organizador y jugadores involucrados.
-- Toda modificación pasa por funciones que validan el actor y el estado.
revoke all on function public.proponer_pareja_organizador(uuid, uuid) from public, anon;
revoke all on function public.responder_propuesta_pareja(uuid, boolean) from public, anon;
revoke all on function public.cancelar_propuesta_pareja(uuid) from public, anon;
grant execute on function public.proponer_pareja_organizador(uuid, uuid) to authenticated;
grant execute on function public.responder_propuesta_pareja(uuid, boolean) to authenticated;
grant execute on function public.cancelar_propuesta_pareja(uuid) to authenticated;
