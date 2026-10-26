-- =====================================================================
--  PADEL TRACKING  -  Esquema de base de datos + algoritmo Elo
--  Pegar completo en: Supabase > SQL Editor > New query > Run
-- =====================================================================

-- Esquema privado (no expuesto a la API) para funciones internas
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 1. TIPOS (ENUMS)
-- ---------------------------------------------------------------------
create type public.estado_torneo  as enum ('inscripciones_abiertas', 'en_progreso', 'finalizado');
create type public.formato_torneo as enum ('grupos', 'eliminacion_directa');
create type public.estado_partido as enum ('pendiente', 'en_progreso', 'finalizado');
create type public.fase_partido   as enum ('grupos', 'octavos', 'cuartos', 'semifinal', 'final');
create type public.tipo_evento    as enum ('winner', 'error_no_forzado', 'punto_general');
create type public.equipo         as enum ('A', 'B');

-- ---------------------------------------------------------------------
-- 2. TABLAS
-- ---------------------------------------------------------------------

-- 2.1 Jugadores: su id es el MISMO que el usuario de Supabase Auth
create table public.jugadores (
  id               uuid primary key references auth.users (id) on delete cascade,
  nombre           text not null check (char_length(nombre) between 1 and 80),
  email            text unique,
  elo_actual       integer not null default 1200 check (elo_actual >= 100),
  partidos_jugados integer not null default 0 check (partidos_jugados >= 0),
  partidos_ganados integer not null default 0 check (partidos_ganados >= 0),
  creado_at        timestamptz not null default now(),
  check (partidos_ganados <= partidos_jugados)
);
create index jugadores_ranking_idx on public.jugadores (elo_actual desc);

-- 2.2 Torneos
create table public.torneos (
  id               uuid primary key default gen_random_uuid(),
  nombre           text not null check (char_length(nombre) between 1 and 120),
  categoria        text not null,
  estado           public.estado_torneo  not null default 'inscripciones_abiertas',
  formato          public.formato_torneo not null,
  parejas_por_grupo smallint not null default 4 check (parejas_por_grupo in (3, 4)),
  organizador_id   uuid not null references public.jugadores (id) on delete cascade,
  creado_at        timestamptz not null default now()
);
create index torneos_organizador_idx on public.torneos (organizador_id);

-- 2.3 Parejas inscritas (jugador_2 puede ser NULL = "busco compañero")
create table public.parejas_inscritas (
  id                  uuid primary key default gen_random_uuid(),
  torneo_id           uuid not null references public.torneos (id) on delete cascade,
  jugador_1_id        uuid not null references public.jugadores (id) on delete cascade,
  jugador_2_id        uuid references public.jugadores (id) on delete cascade,
  elo_promedio_pareja integer not null default 1200,  -- lo calcula un trigger
  creado_at           timestamptz not null default now(),
  check (jugador_1_id <> jugador_2_id),
  unique (torneo_id, jugador_1_id),
  unique (torneo_id, jugador_2_id)
);
create index parejas_jugador1_idx on public.parejas_inscritas (jugador_1_id);
create index parejas_jugador2_idx on public.parejas_inscritas (jugador_2_id);

-- 2.4 Partidos del fixture (grupos y llaves)
create table public.partidos_fixture (
  id                   uuid primary key default gen_random_uuid(),
  torneo_id            uuid not null references public.torneos (id) on delete cascade,
  fase                 public.fase_partido not null,
  grupo                text,                 -- 'A', 'B'... solo en fase de grupos
  numero               smallint,             -- orden dentro de la fase
  pareja_a_id          uuid references public.parejas_inscritas (id) on delete cascade,
  pareja_b_id          uuid references public.parejas_inscritas (id) on delete cascade,
  estado               public.estado_partido not null default 'pendiente',
  resultado_sets       text,                 -- ej: '6-4, 7-5'
  pareja_ganadora_id   uuid references public.parejas_inscritas (id) on delete set null,
  estado_marcador      jsonb not null default '{}'::jsonb,  -- marcador en vivo (lo maneja la app)
  siguiente_partido_id uuid references public.partidos_fixture (id) on delete set null,
  siguiente_slot       public.equipo,        -- el ganador entra como 'A' o 'B' del siguiente
  anotador_id          uuid references public.jugadores (id) on delete set null,  -- tercero designado para anotar
  creado_at            timestamptz not null default now(),
  check (pareja_a_id <> pareja_b_id),
  check (pareja_ganadora_id is null or pareja_ganadora_id in (pareja_a_id, pareja_b_id)),
  check ((siguiente_partido_id is null) = (siguiente_slot is null))
);
create index fixture_torneo_idx    on public.partidos_fixture (torneo_id);
create index fixture_pareja_a_idx  on public.partidos_fixture (pareja_a_id);
create index fixture_pareja_b_idx  on public.partidos_fixture (pareja_b_id);
create index fixture_ganadora_idx  on public.partidos_fixture (pareja_ganadora_id);
create index fixture_siguiente_idx on public.partidos_fixture (siguiente_partido_id);
create index fixture_anotador_idx  on public.partidos_fixture (anotador_id);

-- 2.5 Eventos del anotador (cada toque de botón)
create table public.estadisticas_eventos (
  id               bigint generated always as identity primary key,
  partido_id       uuid not null references public.partidos_fixture (id) on delete cascade,
  tipo_evento      public.tipo_evento not null,
  jugador_id       uuid references public.jugadores (id) on delete cascade,
  equipo_que_suma  public.equipo not null,
  marcador_momento text,                     -- ej: '1-0, 30-15'
  creado_at        timestamptz not null default now(),
  -- 'punto_general' NO lleva jugador; winner y error_no_forzado SÍ
  check ((tipo_evento = 'punto_general') = (jugador_id is null))
);
create index eventos_partido_idx on public.estadisticas_eventos (partido_id);
create index eventos_jugador_idx on public.estadisticas_eventos (jugador_id);

-- 2.6 Historial de Elo (auditoría: antes / después de cada partido)
create table public.historial_elo (
  id          bigint generated always as identity primary key,
  partido_id  uuid not null references public.partidos_fixture (id) on delete cascade,
  jugador_id  uuid not null references public.jugadores (id) on delete cascade,
  elo_antes   integer not null,
  elo_despues integer not null,
  delta       integer not null,
  multiplicador_k numeric(4,2) not null,
  creado_at   timestamptz not null default now(),
  unique (partido_id, jugador_id)
);
create index historial_jugador_idx on public.historial_elo (jugador_id);

-- ---------------------------------------------------------------------
-- 3. FUNCIONES Y TRIGGERS
-- ---------------------------------------------------------------------

-- 3.1 Al registrarse un usuario en Auth, se crea su perfil de jugador
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.jugadores (id, nombre, email)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'nombre', ''), split_part(coalesce(new.email, 'jugador'), '@', 1)),
    new.email
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- 3.2 Parejas: valida que nadie esté en dos parejas del mismo torneo
--     y calcula el Elo promedio (el cliente NO puede falsearlo)
create or replace function private.preparar_pareja()
returns trigger
language plpgsql
set search_path = ''
as $$
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

  return new;
end;
$$;

create trigger parejas_preparar
  before insert or update of jugador_1_id, jugador_2_id on public.parejas_inscritas
  for each row execute function private.preparar_pareja();

-- 3.3 Eventos: el jugador debe pertenecer al partido y al equipo correcto
create or replace function private.validar_evento()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  a1 uuid; a2 uuid; b1 uuid; b2 uuid;
  v_equipo public.equipo;
begin
  if new.jugador_id is null then
    return new;  -- punto_general: nada que validar
  end if;

  select pa.jugador_1_id, pa.jugador_2_id, pb.jugador_1_id, pb.jugador_2_id
    into a1, a2, b1, b2
  from public.partidos_fixture f
  join public.parejas_inscritas pa on pa.id = f.pareja_a_id
  join public.parejas_inscritas pb on pb.id = f.pareja_b_id
  where f.id = new.partido_id;

  if new.jugador_id in (a1, a2) then v_equipo := 'A';
  elsif new.jugador_id in (b1, b2) then v_equipo := 'B';
  else raise exception 'El jugador no participa en este partido';
  end if;

  -- Winner: suma el equipo del propio jugador
  if new.tipo_evento = 'winner' and v_equipo <> new.equipo_que_suma then
    raise exception 'Un winner debe sumar para el equipo del jugador que lo hizo';
  end if;
  -- Error no forzado: el punto lo suma el equipo RIVAL del que falló
  if new.tipo_evento = 'error_no_forzado' and v_equipo = new.equipo_que_suma then
    raise exception 'Un error no forzado suma para el equipo rival del jugador que falló';
  end if;

  return new;
end;
$$;

create trigger eventos_validar
  before insert on public.estadisticas_eventos
  for each row execute function private.validar_evento();

-- 3.4 Partidos: validaciones antes de cerrar
create or replace function private.validar_cambio_partido()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.estado = 'finalizado' then
    raise exception 'Un partido finalizado no se puede modificar';
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

create trigger partidos_validar
  before update on public.partidos_fixture
  for each row execute function private.validar_cambio_partido();

-- ---------------------------------------------------------------------
-- 3.5 ALGORITMO ELO PARA PAREJAS  (se dispara al finalizar un partido)
-- ---------------------------------------------------------------------
create or replace function private.cerrar_partido()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  -- Parámetros del algoritmo (se pueden ajustar aquí)
  k_base        constant numeric := 32;    -- Factor K estándar
  bono_max      constant numeric := 0.20;  -- +20 % máximo sobre K por rendimiento
  min_acciones  constant integer := 6;     -- mínimo de winners+errores para aplicar bono

  a1 uuid; a2 uuid; b1 uuid; b2 uuid;
  v_elo_a numeric; v_elo_b numeric;
  v_esp_a numeric; v_esp_b numeric;       -- probabilidad esperada de victoria
  v_res_a numeric; v_res_b numeric;       -- resultado real: 1 gana, 0 pierde
  v_eq_ganador text;
  r record;
  v_w integer; v_e integer; v_total integer;
  v_share numeric; v_mult numeric;
  v_delta integer; v_nuevo integer;
begin
  -- Paso 0: identificar a los 4 jugadores
  select pa.jugador_1_id, pa.jugador_2_id, pb.jugador_1_id, pb.jugador_2_id
    into a1, a2, b1, b2
  from public.parejas_inscritas pa, public.parejas_inscritas pb
  where pa.id = new.pareja_a_id and pb.id = new.pareja_b_id;

  if a2 is null or b2 is null then
    raise exception 'Ambas parejas deben estar completas (2 jugadores) para calcular Elo';
  end if;

  -- Bloquear las 4 filas (orden fijo para evitar deadlocks)
  perform 1 from public.jugadores
   where id in (a1, a2, b1, b2) order by id for update;

  -- Paso 1: Elo promedio de cada equipo
  select avg(elo_actual) into v_elo_a from public.jugadores where id in (a1, a2);
  select avg(elo_actual) into v_elo_b from public.jugadores where id in (b1, b2);

  -- Paso 2: probabilidad esperada (fórmula estándar, base 400)
  v_esp_a := 1 / (1 + power(10, (v_elo_b - v_elo_a) / 400.0));
  v_esp_b := 1 - v_esp_a;

  -- Resultado real
  if new.pareja_ganadora_id = new.pareja_a_id then
    v_res_a := 1; v_res_b := 0; v_eq_ganador := 'A';
  else
    v_res_a := 0; v_res_b := 1; v_eq_ganador := 'B';
  end if;

  -- Pasos 3, 4 y 5: cambio individual con bono de rendimiento
  for r in
    select j.id, j.elo_actual, t.equipo
    from public.jugadores j
    join (values (a1, 'A'::text), (a2, 'A'::text), (b1, 'B'::text), (b2, 'B'::text))
         as t (id, equipo) on t.id = j.id
  loop
    -- Estadísticas del jugador en este partido
    select count(*) filter (where tipo_evento = 'winner'),
           count(*) filter (where tipo_evento = 'error_no_forzado')
      into v_w, v_e
    from public.estadisticas_eventos
    where partido_id = new.id and jugador_id = r.id;

    v_total := v_w + v_e;
    v_mult  := 1;

    if v_total >= min_acciones then
      v_share := v_w::numeric / v_total;   -- 0.5 = igual de winners que errores
      if r.equipo = v_eq_ganador then
        -- Ganador con muchos winners y pocos errores: gana más
        v_mult := 1 + bono_max * least(1, greatest(0, (v_share - 0.5) / 0.5));
      else
        -- Perdedor con muchos errores: pierde más
        v_mult := 1 + bono_max * least(1, greatest(0, (0.5 - v_share) / 0.5));
      end if;
    end if;

    -- Cambio = K individual x (resultado real - esperado del equipo)
    if r.equipo = 'A' then
      v_delta := round(k_base * v_mult * (v_res_a - v_esp_a));
    else
      v_delta := round(k_base * v_mult * (v_res_b - v_esp_b));
    end if;

    v_nuevo := greatest(100, r.elo_actual + v_delta);

    insert into public.historial_elo (partido_id, jugador_id, elo_antes, elo_despues, delta, multiplicador_k)
    values (new.id, r.id, r.elo_actual, v_nuevo, v_nuevo - r.elo_actual, round(v_mult, 2));

    update public.jugadores
       set elo_actual       = v_nuevo,
           partidos_jugados = partidos_jugados + 1,
           partidos_ganados = partidos_ganados + (case when r.equipo = v_eq_ganador then 1 else 0 end)
     where id = r.id;
  end loop;

  -- Avance automático de llaves: el ganador pasa al siguiente partido
  if new.siguiente_partido_id is not null then
    update public.partidos_fixture
       set pareja_a_id = case when new.siguiente_slot = 'A' then new.pareja_ganadora_id else pareja_a_id end,
           pareja_b_id = case when new.siguiente_slot = 'B' then new.pareja_ganadora_id else pareja_b_id end
     where id = new.siguiente_partido_id;
  end if;

  -- Si era la final, el torneo termina
  if new.fase = 'final' then
    update public.torneos set estado = 'finalizado' where id = new.torneo_id;
  end if;

  return new;
end;
$$;

create trigger partidos_cerrar
  after update of estado on public.partidos_fixture
  for each row
  when (old.estado is distinct from 'finalizado' and new.estado = 'finalizado')
  execute function private.cerrar_partido();

-- ---------------------------------------------------------------------
-- 4. SEGURIDAD (RLS) - quién puede ver / modificar qué
-- ---------------------------------------------------------------------
alter table public.jugadores            enable row level security;
alter table public.torneos              enable row level security;
alter table public.parejas_inscritas    enable row level security;
alter table public.partidos_fixture     enable row level security;
alter table public.estadisticas_eventos enable row level security;
alter table public.historial_elo        enable row level security;

-- Permisos base de tabla (RLS filtra después las filas)
revoke all on all tables in schema public from anon, authenticated;

grant select on public.jugadores, public.historial_elo to authenticated;
grant update (nombre) on public.jugadores to authenticated;           -- el Elo NO se puede editar a mano

grant select, insert, update, delete on public.torneos           to authenticated;
grant select, insert, update, delete on public.parejas_inscritas to authenticated;
grant select, insert, delete         on public.partidos_fixture  to authenticated;
grant update (estado, resultado_sets, pareja_ganadora_id, estado_marcador, anotador_id)
                                     on public.partidos_fixture  to authenticated;
grant select, insert, delete         on public.estadisticas_eventos to authenticated;

-- Jugadores
create policy "jugadores_ver" on public.jugadores
  for select to authenticated using (true);
create policy "jugadores_editar_propio" on public.jugadores
  for update to authenticated
  using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

-- Torneos
create policy "torneos_ver" on public.torneos
  for select to authenticated using (true);
create policy "torneos_crear" on public.torneos
  for insert to authenticated with check (organizador_id = (select auth.uid()));
create policy "torneos_editar" on public.torneos
  for update to authenticated
  using (organizador_id = (select auth.uid())) with check (organizador_id = (select auth.uid()));
create policy "torneos_borrar" on public.torneos
  for delete to authenticated using (organizador_id = (select auth.uid()));

-- Parejas inscritas
create policy "parejas_ver" on public.parejas_inscritas
  for select to authenticated using (true);
create policy "parejas_inscribir" on public.parejas_inscritas
  for insert to authenticated
  with check (
    jugador_1_id = (select auth.uid())
    and exists (select 1 from public.torneos t
                where t.id = parejas_inscritas.torneo_id and t.estado = 'inscripciones_abiertas')
  );
create policy "parejas_editar" on public.parejas_inscritas
  for update to authenticated
  using (
    jugador_1_id = (select auth.uid())
    or exists (select 1 from public.torneos t
               where t.id = parejas_inscritas.torneo_id and t.organizador_id = (select auth.uid()))
  )
  with check (
    jugador_1_id = (select auth.uid())
    or exists (select 1 from public.torneos t
               where t.id = parejas_inscritas.torneo_id and t.organizador_id = (select auth.uid()))
  );
create policy "parejas_borrar" on public.parejas_inscritas
  for delete to authenticated
  using (
    (select auth.uid()) in (jugador_1_id, jugador_2_id)
    or exists (select 1 from public.torneos t
               where t.id = parejas_inscritas.torneo_id and t.organizador_id = (select auth.uid()))
  );

-- Partidos del fixture
create policy "fixture_ver" on public.partidos_fixture
  for select to authenticated using (true);
create policy "fixture_crear" on public.partidos_fixture
  for insert to authenticated
  with check (exists (select 1 from public.torneos t
                      where t.id = partidos_fixture.torneo_id and t.organizador_id = (select auth.uid())));
create policy "fixture_borrar" on public.partidos_fixture
  for delete to authenticated
  using (exists (select 1 from public.torneos t
                 where t.id = partidos_fixture.torneo_id and t.organizador_id = (select auth.uid())));
-- Pueden anotar/cerrar: el organizador, los jugadores del partido o el anotador designado
create policy "fixture_actualizar" on public.partidos_fixture
  for update to authenticated
  using (
    partidos_fixture.anotador_id = (select auth.uid())
    or exists (select 1 from public.torneos t
            where t.id = partidos_fixture.torneo_id and t.organizador_id = (select auth.uid()))
    or exists (select 1 from public.parejas_inscritas p
               where p.id in (partidos_fixture.pareja_a_id, partidos_fixture.pareja_b_id)
                 and (select auth.uid()) in (p.jugador_1_id, p.jugador_2_id))
  )
  with check (
    partidos_fixture.anotador_id = (select auth.uid())
    or exists (select 1 from public.torneos t
            where t.id = partidos_fixture.torneo_id and t.organizador_id = (select auth.uid()))
    or exists (select 1 from public.parejas_inscritas p
               where p.id in (partidos_fixture.pareja_a_id, partidos_fixture.pareja_b_id)
                 and (select auth.uid()) in (p.jugador_1_id, p.jugador_2_id))
  );

-- Eventos del anotador (solo con el partido "en_progreso"; DELETE = deshacer punto)
create policy "eventos_ver" on public.estadisticas_eventos
  for select to authenticated using (true);
create policy "eventos_anotar" on public.estadisticas_eventos
  for insert to authenticated
  with check (
    exists (
      select 1 from public.partidos_fixture f
      join public.torneos t on t.id = f.torneo_id
      where f.id = estadisticas_eventos.partido_id
        and f.estado = 'en_progreso'
        and (t.organizador_id = (select auth.uid())
             or f.anotador_id = (select auth.uid())
             or exists (select 1 from public.parejas_inscritas p
                        where p.id in (f.pareja_a_id, f.pareja_b_id)
                          and (select auth.uid()) in (p.jugador_1_id, p.jugador_2_id)))
    )
  );
create policy "eventos_deshacer" on public.estadisticas_eventos
  for delete to authenticated
  using (
    exists (
      select 1 from public.partidos_fixture f
      join public.torneos t on t.id = f.torneo_id
      where f.id = estadisticas_eventos.partido_id
        and f.estado = 'en_progreso'
        and (t.organizador_id = (select auth.uid())
             or f.anotador_id = (select auth.uid())
             or exists (select 1 from public.parejas_inscritas p
                        where p.id in (f.pareja_a_id, f.pareja_b_id)
                          and (select auth.uid()) in (p.jugador_1_id, p.jugador_2_id)))
    )
  );

-- Historial de Elo: solo lectura (lo escribe el algoritmo)
create policy "historial_ver" on public.historial_elo
  for select to authenticated using (true);

-- ---------------------------------------------------------------------
-- 5. TIEMPO REAL (el marcador se ve en vivo en otros teléfonos)
-- ---------------------------------------------------------------------
alter publication supabase_realtime add table public.partidos_fixture;
alter publication supabase_realtime add table public.estadisticas_eventos;
