-- Split'em database setup.
-- Paste this whole file into the Supabase SQL editor and click Run. It is safe to run again.

-- ---------- tables ----------
create table if not exists public.questions (
  qkey     text primary key,
  kind     text not null check (kind in ('split','price','group')),
  grp      text,
  prior    int  not null,
  prior_by jsonb not null default '{}'
);

create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text check (name is null or char_length(name) between 1 and 18),
  age        text check (age is null or char_length(age) <= 12),
  gender     text check (gender is null or char_length(gender) <= 12),
  region     text check (region is null or char_length(region) <= 16),
  updated_at timestamptz not null default now()
);

create table if not exists public.answers (
  user_id    uuid not null references auth.users(id) on delete cascade,
  qkey       text not null references public.questions(qkey),
  answer     int  not null,
  created_at timestamptz not null default now(),
  primary key (user_id, qkey)
);
create index if not exists answers_qkey on public.answers (qkey);

create table if not exists public.plays (
  user_id    uuid not null references auth.users(id) on delete cascade,
  mode       text not null check (mode in ('daily','archive','battle')),
  ref        text not null,
  card       int  not null check (card between 0 and 5),
  qkey       text not null references public.questions(qkey),
  guess      int  not null,
  score      int  not null check (score between 0 and 100),
  created_at timestamptz not null default now(),
  primary key (user_id, mode, ref, card)
);
create index if not exists plays_mode_ref on public.plays (mode, ref);

create table if not exists public.battles (
  code       text primary key check (code ~ '^[A-Z]{4}$'),
  qkeys      text[] not null check (array_length(qkeys, 1) = 6),
  host       uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.battle_players (
  code      text not null references public.battles(code) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (code, user_id)
);

create table if not exists public.inbox (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind       text not null check (kind in ('question','feedback')),
  body       text check (body is null or char_length(body) <= 800),
  detail     text check (detail is null or char_length(detail) <= 40),
  name       text check (name is null or char_length(name) <= 18),
  created_at timestamptz not null default now()
);

-- ---------- security: players only ever touch their own rows; everything else goes through the functions below ----------
alter table public.questions      enable row level security;
alter table public.profiles       enable row level security;
alter table public.answers        enable row level security;
alter table public.plays          enable row level security;
alter table public.battles        enable row level security;
alter table public.battle_players enable row level security;
alter table public.inbox          enable row level security;

drop policy if exists "own profile read"   on public.profiles;
drop policy if exists "own profile insert" on public.profiles;
drop policy if exists "own profile update" on public.profiles;
drop policy if exists "send to inbox"      on public.inbox;
create policy "own profile read"   on public.profiles for select to authenticated using (id = auth.uid());
create policy "own profile insert" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "own profile update" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy "send to inbox"      on public.inbox    for insert to authenticated with check (user_id = auth.uid());

-- ---------- helpers ----------
create or replace function public._groups(p_age text, p_gender text, p_region text)
returns text[] language sql immutable set search_path = '' as $$
  select array_remove(array[
    case when p_age in ('Under 18','18–24') then 'u25' when p_age in ('25–34','35–44') then 'a2544' when p_age in ('45–54','55+') then 'o45' end,
    case p_gender when 'Woman' then 'w' when 'Man' then 'm' end,
    case p_region when 'Europe' then 'eu' when 'North America' then 'na' when 'Asia' then 'as' end
  ], null)
$$;

-- Daily schedule: day No. 1 is 12 Nov 2026; 16 daily sets, then it starts again. Must match setOf() in index.html.
create or replace function public._set_of(p_no int)
returns int language sql immutable set search_path = '' as $$
  select case when ((p_no - 1) % 16 + 1) <= 6 then (((p_no - 1) % 16 + 1) + 2) % 6 else (p_no - 1) % 16 end
$$;

-- Result of one question: real answers once there are 30 (15 per group), otherwise the estimate stored with the question.
create or replace function public._stats(p_qkey text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  q questions; n int; v int; g text; gn int; gv int;
  by_v jsonb := '{}'; by_n jsonb := '{}'; bins jsonb; truth int; is_real boolean;
begin
  select * into q from questions where qkey = p_qkey;
  if not found then raise exception 'unknown question'; end if;
  select count(*) into n from answers where qkey = p_qkey;
  if n >= 30 then
    if q.kind = 'price' then
      select percentile_disc(0.5) within group (order by answer) into v from answers where qkey = p_qkey;
      select jsonb_agg(c order by i) into bins from (
        select i, (select count(*) from answers where qkey = p_qkey and answer = i) as c from generate_series(-34, 34) i) s;
    else
      select round(100.0 * count(*) filter (where answer = 0) / count(*))::int into v from answers where qkey = p_qkey;
    end if;
  else
    v := q.prior;
  end if;
  foreach g in array array['u25','a2544','o45','w','m','eu','na','as'] loop
    select count(*),
           case when q.kind = 'price' then (percentile_disc(0.5) within group (order by a.answer))::int
                else round(100.0 * count(*) filter (where a.answer = 0) / nullif(count(*), 0))::int end
      into gn, gv
      from answers a join profiles p on p.id = a.user_id
     where a.qkey = p_qkey and g = any(_groups(p.age, p.gender, p.region));
    by_n := by_n || jsonb_build_object(g, gn);
    by_v := by_v || jsonb_build_object(g, case when gn >= 15 then to_jsonb(gv) else q.prior_by -> g end);
  end loop;
  if q.kind = 'group' then
    truth := (by_v ->> q.grp)::int; is_real := (by_n ->> q.grp)::int >= 15;
  else
    truth := v; is_real := n >= 30;
  end if;
  return jsonb_build_object('n', n, 'real', is_real, 'value', truth, 'overall', v, 'by', by_v, 'by_n', by_n, 'bins', bins);
end $$;

-- ---------- what the site calls ----------
-- Saves the player's answer and guess, scores the guess on the server and returns the result.
create or replace function public.play_card(p_mode text, p_ref text, p_card int, p_qkey text, p_answer int, p_guess int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); q questions; st jsonb; t int; s int; prev plays; today int;
begin
  if uid is null then raise exception 'not signed in'; end if;
  select * into q from questions where qkey = p_qkey;
  if not found then raise exception 'unknown question'; end if;
  if q.kind = 'price' then
    if p_answer not between -34 and 34 or p_guess not between -34 and 34 then raise exception 'out of range'; end if;
  elsif p_answer not in (0, 1) or p_guess not between 0 and 100 then
    raise exception 'out of range';
  end if;
  if p_card not between 0 and 5 then raise exception 'bad card'; end if;
  today := (current_date - date '2026-11-12') + 1;
  if p_mode in ('daily', 'archive') then
    if p_ref !~ '^[0-9]{1,5}$' then raise exception 'bad day'; end if;
    if p_mode = 'daily' and p_ref::int not between today - 1 and today + 1 then raise exception 'not today'; end if;
    if p_mode = 'archive' and p_ref::int not between 1 and today then raise exception 'bad day'; end if;
    if p_qkey <> 's' || _set_of(p_ref::int) || 'q' || p_card then raise exception 'wrong question'; end if;
  elsif p_mode = 'battle' then
    if not exists (select 1 from battle_players where code = p_ref and user_id = uid) then raise exception 'not in this battle'; end if;
    if (select qkeys[p_card + 1] from battles where code = p_ref) is distinct from p_qkey then raise exception 'wrong question'; end if;
  else
    raise exception 'bad mode';
  end if;
  insert into answers (user_id, qkey, answer) values (uid, p_qkey, p_answer) on conflict do nothing;
  st := _stats(p_qkey);
  t := (st ->> 'value')::int;
  select * into prev from plays where user_id = uid and mode = p_mode and ref = p_ref and card = p_card;
  if prev.user_id is not null then
    s := prev.score; p_guess := prev.guess;
  else
    s := case when q.kind = 'price' then greatest(0, 100 - 12 * abs(p_guess - t))
              else greatest(0, round(100 - 3 * abs(p_guess - t)))::int end;
    insert into plays (user_id, mode, ref, card, qkey, guess, score) values (uid, p_mode, p_ref, p_card, p_qkey, p_guess, s);
  end if;
  return st || jsonb_build_object('score', s, 'guess', p_guess);
end $$;

-- Today's leaderboard: players who finished all six cards of a day.
create or replace function public.leaderboard(p_day int)
returns jsonb language sql stable security definer set search_path = public as $$
  with t as (
    select user_id, sum(score)::int as total from plays
     where mode = 'daily' and ref = p_day::text group by user_id having count(*) = 6),
  r as (
    select t.user_id, t.total, coalesce(p.name, 'Player') as name, rank() over (order by t.total desc) as rk
      from t left join profiles p on p.id = t.user_id)
  select jsonb_build_object(
    'players', (select count(*) from r),
    'mean',    (select round(avg(total)) from r),
    'sd',      (select round(stddev_pop(total)) from r),
    'top',     coalesce((select jsonb_agg(jsonb_build_object('name', name, 'total', total, 'rank', rk, 'me', user_id = auth.uid()) order by rk, name)
                           from (select * from r order by rk, name limit 10) x), '[]'::jsonb),
    'me',      (select jsonb_build_object('total', total, 'rank', rk, 'below', (select count(*) from r r2 where r2.total < r.total))
                  from r where user_id = auth.uid()))
$$;

-- All-time leaderboard: average daily score.
create or replace function public.leaderboard_all()
returns jsonb language sql stable security definer set search_path = public as $$
  with d as (
    select user_id, ref, sum(score) as total from plays where mode = 'daily' group by user_id, ref having count(*) = 6),
  u as (
    select user_id, round(avg(total))::int as avg, count(*)::int as games from d group by user_id),
  r as (
    select u.*, coalesce(p.name, 'Player') as name, rank() over (order by u.avg desc) as rk
      from u left join profiles p on p.id = u.user_id)
  select jsonb_build_object(
    'players', (select count(*) from r),
    'top',     coalesce((select jsonb_agg(jsonb_build_object('name', name, 'total', avg, 'games', games, 'rank', rk, 'me', user_id = auth.uid()) order by rk, name)
                           from (select * from r order by rk, name limit 10) x), '[]'::jsonb),
    'me',      (select jsonb_build_object('total', avg, 'games', games, 'rank', rk) from r where user_id = auth.uid()))
$$;

create or replace function public.create_battle(p_code text, p_qkeys text[])
returns void language plpgsql security definer set search_path = public as $$
declare k text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_code !~ '^[A-Z]{4}$' or array_length(p_qkeys, 1) <> 6 then raise exception 'bad battle'; end if;
  foreach k in array p_qkeys loop
    if k !~ '^s(16|17|18|19)q[0-5]$' then raise exception 'bad question'; end if;
  end loop;
  insert into battles (code, qkeys, host) values (p_code, p_qkeys, auth.uid());
  insert into battle_players (code, user_id) values (p_code, auth.uid());
end $$;

create or replace function public.join_battle(p_code text)
returns text[] language plpgsql security definer set search_path = public as $$
declare k text[];
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select qkeys into k from battles where code = upper(p_code);
  if not found then return null; end if;
  insert into battle_players (code, user_id) values (upper(p_code), auth.uid()) on conflict do nothing;
  return k;
end $$;

create or replace function public.battle_standings(p_code text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when exists (select 1 from battle_players where code = p_code and user_id = auth.uid()) then
    coalesce((select jsonb_agg(jsonb_build_object(
        'name', coalesce(p.name, 'Player'),
        'me',   bp.user_id = auth.uid(),
        'scores', coalesce((select jsonb_agg(pl.score order by pl.card) from plays pl
                             where pl.mode = 'battle' and pl.ref = p_code and pl.user_id = bp.user_id), '[]'::jsonb))
        order by bp.joined_at)
      from battle_players bp left join profiles p on p.id = bp.user_id where bp.code = p_code), '[]'::jsonb)
  end
$$;

-- Erases the player and everything they stored (answers, scores, battles, messages).
create or replace function public.delete_me()
returns void language sql security definer set search_path = public as $$
  delete from auth.users where id = auth.uid();
$$;

revoke all on function public._stats(text) from public, anon, authenticated;
revoke all on function public.play_card(text, text, int, text, int, int) from public, anon;
revoke all on function public.leaderboard(int) from public, anon;
revoke all on function public.leaderboard_all() from public, anon;
revoke all on function public.create_battle(text, text[]) from public, anon;
revoke all on function public.join_battle(text) from public, anon;
revoke all on function public.battle_standings(text) from public, anon;
revoke all on function public.delete_me() from public, anon;
grant execute on function public.play_card(text, text, int, text, int, int), public.leaderboard(int), public.leaderboard_all(),
  public.create_battle(text, text[]), public.join_battle(text), public.battle_standings(text), public.delete_me() to authenticated;

-- ---------- the 120 questions (estimates used until real answers arrive) ----------
insert into public.questions (qkey, kind, grp, prior, prior_by) values
('s0q0','split',null,34,'{"w":38,"m":30,"u25":36,"a2544":34,"o45":32,"eu":31,"na":40,"as":39}'),
('s0q1','price',null,18,'{"w":16,"m":20,"u25":17,"a2544":18,"o45":19,"eu":20,"na":18,"as":18}'),
('s0q2','group','w',71,'{"w":74,"m":68,"u25":66,"a2544":74,"o45":76,"eu":73,"na":78,"as":75}'),
('s0q3','split',null,12,'{"w":17,"m":7,"u25":13,"a2544":8,"o45":11,"eu":6,"na":8,"as":21}'),
('s0q4','price',null,-21,'{"w":-23,"m":-19,"u25":-24,"a2544":-20,"o45":-18,"eu":-22,"na":-23,"as":-20}'),
('s0q5','group','o45',44,'{"w":49,"m":39,"u25":38,"a2544":40,"o45":52,"eu":49,"na":37,"as":39}'),
('s1q0','split',null,38,'{"w":30,"m":46,"u25":31,"a2544":40,"o45":45,"eu":43,"na":47,"as":39}'),
('s1q1','price',null,17,'{"w":16,"m":18,"u25":17,"a2544":18,"o45":17,"eu":16,"na":16,"as":16}'),
('s1q2','group','u25',49,'{"w":51,"m":47,"u25":58,"a2544":49,"o45":42,"eu":47,"na":49,"as":44}'),
('s1q3','split',null,63,'{"w":63,"m":63,"u25":73,"a2544":65,"o45":53,"eu":64,"na":63,"as":64}'),
('s1q4','price',null,-25,'{"w":-27,"m":-23,"u25":-27,"a2544":-26,"o45":-23,"eu":-25,"na":-24,"as":-24}'),
('s1q5','group','m',46,'{"w":41,"m":51,"u25":47,"a2544":47,"o45":45,"eu":44,"na":46,"as":49}'),
('s2q0','split',null,58,'{"w":63,"m":53,"u25":65,"a2544":55,"o45":51,"eu":57,"na":59,"as":66}'),
('s2q1','price',null,14,'{"w":16,"m":12,"u25":13,"a2544":14,"o45":15,"eu":12,"na":12,"as":14}'),
('s2q2','group','u25',54,'{"w":51,"m":57,"u25":69,"a2544":58,"o45":42,"eu":51,"na":52,"as":62}'),
('s2q3','split',null,39,'{"w":39,"m":39,"u25":49,"a2544":36,"o45":29,"eu":38,"na":33,"as":30}'),
('s2q4','price',null,-19,'{"w":-19,"m":-19,"u25":-19,"a2544":-20,"o45":-19,"eu":-20,"na":-20,"as":-21}'),
('s2q5','group','w',57,'{"w":52,"m":62,"u25":60,"a2544":55,"o45":54,"eu":63,"na":49,"as":61}'),
('s3q0','split',null,44,'{"w":52,"m":36,"u25":48,"a2544":46,"o45":40,"eu":45,"na":42,"as":34}'),
('s3q1','price',null,19,'{"w":20,"m":18,"u25":17,"a2544":20,"o45":21,"eu":20,"na":20,"as":18}'),
('s3q2','group','o45',66,'{"w":67,"m":65,"u25":80,"a2544":64,"o45":48,"eu":65,"na":74,"as":69}'),
('s3q3','split',null,22,'{"w":21,"m":23,"u25":26,"a2544":23,"o45":18,"eu":18,"na":17,"as":26}'),
('s3q4','price',null,-22,'{"w":-22,"m":-22,"u25":-25,"a2544":-21,"o45":-19,"eu":-21,"na":-22,"as":-21}'),
('s3q5','group','u25',62,'{"w":67,"m":57,"u25":55,"a2544":66,"o45":68,"eu":66,"na":56,"as":63}'),
('s4q0','split',null,47,'{"w":42,"m":52,"u25":45,"a2544":49,"o45":49,"eu":41,"na":55,"as":52}'),
('s4q1','price',null,12,'{"w":12,"m":12,"u25":15,"a2544":12,"o45":9,"eu":11,"na":12,"as":10}'),
('s4q2','group','u25',18,'{"w":11,"m":25,"u25":29,"a2544":22,"o45":9,"eu":18,"na":22,"as":10}'),
('s4q3','split',null,61,'{"w":62,"m":60,"u25":57,"a2544":60,"o45":65,"eu":62,"na":54,"as":68}'),
('s4q4','price',null,-25,'{"w":-26,"m":-24,"u25":-26,"a2544":-24,"o45":-24,"eu":-25,"na":-25,"as":-24}'),
('s4q5','group','m',53,'{"w":45,"m":61,"u25":46,"a2544":55,"o45":60,"eu":50,"na":49,"as":55}'),
('s5q0','split',null,41,'{"w":42,"m":40,"u25":51,"a2544":41,"o45":31,"eu":46,"na":43,"as":43}'),
('s5q1','price',null,19,'{"w":19,"m":19,"u25":20,"a2544":18,"o45":18,"eu":17,"na":17,"as":18}'),
('s5q2','group','u25',61,'{"w":67,"m":55,"u25":78,"a2544":60,"o45":47,"eu":55,"na":61,"as":52}'),
('s5q3','split',null,36,'{"w":33,"m":39,"u25":30,"a2544":37,"o45":42,"eu":31,"na":43,"as":32}'),
('s5q4','price',null,-20,'{"w":-22,"m":-18,"u25":-18,"a2544":-20,"o45":-22,"eu":-19,"na":-21,"as":-18}'),
('s5q5','group','w',68,'{"w":63,"m":73,"u25":59,"a2544":72,"o45":77,"eu":62,"na":69,"as":76}'),
('s6q0','split',null,27,'{"w":25,"m":29,"u25":29,"a2544":26,"o45":25,"eu":21,"na":28,"as":26}'),
('s6q1','price',null,23,'{"w":24,"m":22,"u25":24,"a2544":24,"o45":22,"eu":23,"na":25,"as":23}'),
('s6q2','group','o45',64,'{"w":66,"m":62,"u25":57,"a2544":62,"o45":73,"eu":67,"na":57,"as":63}'),
('s6q3','split',null,52,'{"w":53,"m":51,"u25":48,"a2544":51,"o45":56,"eu":53,"na":58,"as":45}'),
('s6q4','price',null,-8,'{"w":-10,"m":-6,"u25":-6,"a2544":-8,"o45":-10,"eu":-8,"na":-6,"as":-5}'),
('s6q5','group','a2544',67,'{"w":68,"m":66,"u25":76,"a2544":74,"o45":58,"eu":62,"na":60,"as":59}'),
('s7q0','split',null,43,'{"w":50,"m":36,"u25":55,"a2544":40,"o45":31,"eu":48,"na":50,"as":39}'),
('s7q1','price',null,15,'{"w":14,"m":16,"u25":13,"a2544":14,"o45":17,"eu":14,"na":15,"as":15}'),
('s7q2','group','m',35,'{"w":39,"m":31,"u25":45,"a2544":36,"o45":25,"eu":35,"na":44,"as":43}'),
('s7q3','split',null,9,'{"w":13,"m":5,"u25":4,"a2544":8,"o45":14,"eu":9,"na":10,"as":5}'),
('s7q4','price',null,-21,'{"w":-22,"m":-20,"u25":-24,"a2544":-20,"o45":-18,"eu":-22,"na":-20,"as":-23}'),
('s7q5','group','u25',58,'{"w":54,"m":62,"u25":81,"a2544":59,"o45":40,"eu":63,"na":52,"as":52}'),
('s8q0','split',null,67,'{"w":71,"m":63,"u25":66,"a2544":64,"o45":68,"eu":64,"na":70,"as":66}'),
('s8q1','price',null,11,'{"w":12,"m":10,"u25":12,"a2544":12,"o45":10,"eu":9,"na":9,"as":11}'),
('s8q2','group','w',45,'{"w":49,"m":41,"u25":43,"a2544":49,"o45":47,"eu":47,"na":44,"as":37}'),
('s8q3','split',null,57,'{"w":54,"m":60,"u25":60,"a2544":55,"o45":54,"eu":57,"na":57,"as":50}'),
('s8q4','price',null,-16,'{"w":-14,"m":-18,"u25":-17,"a2544":-15,"o45":-15,"eu":-16,"na":-15,"as":-18}'),
('s8q5','group','m',31,'{"w":24,"m":38,"u25":38,"a2544":28,"o45":24,"eu":31,"na":22,"as":32}'),
('s9q0','split',null,72,'{"w":78,"m":66,"u25":60,"a2544":75,"o45":84,"eu":75,"na":65,"as":72}'),
('s9q1','price',null,13,'{"w":13,"m":13,"u25":10,"a2544":13,"o45":16,"eu":12,"na":14,"as":15}'),
('s9q2','group','o45',29,'{"w":29,"m":29,"u25":22,"a2544":29,"o45":38,"eu":30,"na":31,"as":24}'),
('s9q3','split',null,46,'{"w":54,"m":38,"u25":55,"a2544":43,"o45":37,"eu":46,"na":42,"as":46}'),
('s9q4','price',null,-14,'{"w":-12,"m":-16,"u25":-13,"a2544":-15,"o45":-15,"eu":-13,"na":-13,"as":-13}'),
('s9q5','group','a2544',69,'{"w":67,"m":71,"u25":58,"a2544":76,"o45":80,"eu":70,"na":62,"as":61}'),
('s10q0','split',null,41,'{"w":48,"m":34,"u25":38,"a2544":43,"o45":44,"eu":46,"na":43,"as":35}'),
('s10q1','price',null,13,'{"w":11,"m":15,"u25":12,"a2544":14,"o45":14,"eu":14,"na":15,"as":14}'),
('s10q2','group','eu',63,'{"w":62,"m":64,"u25":66,"a2544":66,"o45":60,"eu":55,"na":63,"as":56}'),
('s10q3','split',null,59,'{"w":56,"m":62,"u25":55,"a2544":62,"o45":63,"eu":59,"na":54,"as":68}'),
('s10q4','price',null,-18,'{"w":-16,"m":-20,"u25":-21,"a2544":-17,"o45":-15,"eu":-18,"na":-19,"as":-20}'),
('s10q5','group','o45',52,'{"w":44,"m":60,"u25":37,"a2544":53,"o45":71,"eu":51,"na":56,"as":54}'),
('s11q0','split',null,55,'{"w":62,"m":48,"u25":60,"a2544":58,"o45":50,"eu":56,"na":47,"as":53}'),
('s11q1','price',null,17,'{"w":16,"m":18,"u25":17,"a2544":16,"o45":17,"eu":18,"na":18,"as":19}'),
('s11q2','group','u25',21,'{"w":16,"m":26,"u25":33,"a2544":19,"o45":11,"eu":18,"na":24,"as":18}'),
('s11q3','split',null,49,'{"w":56,"m":42,"u25":42,"a2544":50,"o45":56,"eu":48,"na":54,"as":43}'),
('s11q4','price',null,-24,'{"w":-26,"m":-22,"u25":-27,"a2544":-25,"o45":-21,"eu":-25,"na":-24,"as":-24}'),
('s11q5','group','o45',62,'{"w":66,"m":58,"u25":74,"a2544":60,"o45":47,"eu":58,"na":57,"as":59}'),
('s12q0','split',null,32,'{"w":31,"m":33,"u25":25,"a2544":34,"o45":39,"eu":30,"na":26,"as":34}'),
('s12q1','price',null,22,'{"w":24,"m":20,"u25":20,"a2544":23,"o45":24,"eu":21,"na":23,"as":21}'),
('s12q2','group','w',58,'{"w":61,"m":55,"u25":68,"a2544":59,"o45":48,"eu":56,"na":52,"as":59}'),
('s12q3','split',null,66,'{"w":71,"m":61,"u25":67,"a2544":68,"o45":65,"eu":61,"na":61,"as":70}'),
('s12q4','price',null,-22,'{"w":-21,"m":-23,"u25":-25,"a2544":-21,"o45":-19,"eu":-24,"na":-21,"as":-21}'),
('s12q5','group','u25',64,'{"w":64,"m":64,"u25":73,"a2544":64,"o45":57,"eu":64,"na":62,"as":61}'),
('s13q0','split',null,44,'{"w":37,"m":51,"u25":48,"a2544":45,"o45":40,"eu":49,"na":35,"as":37}'),
('s13q1','price',null,13,'{"w":12,"m":14,"u25":14,"a2544":12,"o45":12,"eu":13,"na":11,"as":14}'),
('s13q2','group','a2544',41,'{"w":46,"m":36,"u25":53,"a2544":36,"o45":29,"eu":48,"na":47,"as":44}'),
('s13q3','split',null,61,'{"w":63,"m":59,"u25":71,"a2544":59,"o45":51,"eu":58,"na":67,"as":68}'),
('s13q4','price',null,-23,'{"w":-24,"m":-22,"u25":-24,"a2544":-23,"o45":-22,"eu":-24,"na":-23,"as":-26}'),
('s13q5','group','m',56,'{"w":60,"m":52,"u25":49,"a2544":59,"o45":63,"eu":60,"na":64,"as":62}'),
('s14q0','split',null,68,'{"w":68,"m":68,"u25":71,"a2544":70,"o45":65,"eu":63,"na":69,"as":60}'),
('s14q1','price',null,20,'{"w":19,"m":21,"u25":21,"a2544":19,"o45":19,"eu":21,"na":19,"as":21}'),
('s14q2','group','w',59,'{"w":55,"m":63,"u25":71,"a2544":59,"o45":47,"eu":60,"na":57,"as":65}'),
('s14q3','split',null,51,'{"w":52,"m":50,"u25":51,"a2544":52,"o45":51,"eu":46,"na":42,"as":56}'),
('s14q4','price',null,-19,'{"w":-20,"m":-18,"u25":-18,"a2544":-19,"o45":-20,"eu":-20,"na":-17,"as":-20}'),
('s14q5','group','u25',38,'{"w":36,"m":40,"u25":49,"a2544":38,"o45":29,"eu":38,"na":36,"as":30}'),
('s15q0','split',null,63,'{"w":59,"m":67,"u25":58,"a2544":63,"o45":68,"eu":59,"na":62,"as":71}'),
('s15q1','price',null,17,'{"w":16,"m":18,"u25":19,"a2544":18,"o45":15,"eu":18,"na":17,"as":18}'),
('s15q2','group','u25',34,'{"w":31,"m":37,"u25":42,"a2544":33,"o45":28,"eu":30,"na":29,"as":25}'),
('s15q3','split',null,71,'{"w":74,"m":68,"u25":67,"a2544":70,"o45":75,"eu":73,"na":78,"as":78}'),
('s15q4','price',null,-13,'{"w":-11,"m":-15,"u25":-12,"a2544":-13,"o45":-14,"eu":-13,"na":-11,"as":-14}'),
('s15q5','group','m',36,'{"w":28,"m":44,"u25":33,"a2544":34,"o45":39,"eu":30,"na":42,"as":46}'),
('s16q0','split',null,78,'{"w":75,"m":81,"u25":68,"a2544":80,"o45":88,"eu":81,"na":74,"as":82}'),
('s16q1','price',null,15,'{"w":16,"m":14,"u25":16,"a2544":15,"o45":14,"eu":16,"na":14,"as":14}'),
('s16q2','group','w',39,'{"w":44,"m":34,"u25":45,"a2544":42,"o45":33,"eu":45,"na":35,"as":34}'),
('s16q3','split',null,37,'{"w":43,"m":31,"u25":28,"a2544":40,"o45":46,"eu":41,"na":44,"as":44}'),
('s16q4','price',null,-16,'{"w":-14,"m":-18,"u25":-19,"a2544":-16,"o45":-13,"eu":-16,"na":-16,"as":-15}'),
('s16q5','group','u25',42,'{"w":50,"m":34,"u25":61,"a2544":42,"o45":27,"eu":48,"na":43,"as":39}'),
('s17q0','split',null,38,'{"w":36,"m":40,"u25":30,"a2544":35,"o45":46,"eu":32,"na":34,"as":46}'),
('s17q1','price',null,9,'{"w":11,"m":7,"u25":10,"a2544":10,"o45":8,"eu":9,"na":8,"as":7}'),
('s17q2','group','o45',71,'{"w":69,"m":73,"u25":89,"a2544":69,"o45":48,"eu":72,"na":80,"as":68}'),
('s17q3','split',null,43,'{"w":36,"m":50,"u25":47,"a2544":41,"o45":39,"eu":37,"na":51,"as":50}'),
('s17q4','price',null,-12,'{"w":-14,"m":-10,"u25":-10,"a2544":-11,"o45":-14,"eu":-12,"na":-12,"as":-13}'),
('s17q5','group','u25',46,'{"w":45,"m":47,"u25":31,"a2544":48,"o45":58,"eu":52,"na":41,"as":43}'),
('s18q0','split',null,74,'{"w":78,"m":70,"u25":82,"a2544":71,"o45":66,"eu":74,"na":78,"as":78}'),
('s18q1','price',null,7,'{"w":5,"m":9,"u25":4,"a2544":8,"o45":10,"eu":8,"na":6,"as":6}'),
('s18q2','group','na',46,'{"w":53,"m":39,"u25":48,"a2544":46,"o45":44,"eu":41,"na":54,"as":50}'),
('s18q3','split',null,60,'{"w":62,"m":58,"u25":63,"a2544":63,"o45":57,"eu":63,"na":57,"as":55}'),
('s18q4','price',null,-12,'{"w":-14,"m":-10,"u25":-9,"a2544":-12,"o45":-15,"eu":-13,"na":-12,"as":-11}'),
('s18q5','group','m',66,'{"w":69,"m":63,"u25":75,"a2544":64,"o45":57,"eu":72,"na":64,"as":69}'),
('s19q0','split',null,64,'{"w":61,"m":67,"u25":58,"a2544":65,"o45":70,"eu":71,"na":55,"as":64}'),
('s19q1','price',null,10,'{"w":9,"m":11,"u25":13,"a2544":11,"o45":7,"eu":11,"na":9,"as":12}'),
('s19q2','group','o45',69,'{"w":69,"m":69,"u25":63,"a2544":67,"o45":77,"eu":76,"na":65,"as":68}'),
('s19q3','split',null,53,'{"w":53,"m":53,"u25":59,"a2544":55,"o45":47,"eu":57,"na":52,"as":45}'),
('s19q4','price',null,-17,'{"w":-18,"m":-16,"u25":-16,"a2544":-18,"o45":-18,"eu":-15,"na":-16,"as":-14}'),
('s19q5','group','eu',44,'{"w":41,"m":47,"u25":47,"a2544":46,"o45":41,"eu":49,"na":48,"as":46}')
on conflict (qkey) do update set kind = excluded.kind, grp = excluded.grp, prior = excluded.prior, prior_by = excluded.prior_by;
