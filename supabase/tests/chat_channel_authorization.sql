-- Live authorization check for the private Circle-chat channel.
--
-- Run against the linked project:
--   supabase db query -f supabase/tests/chat_channel_authorization.sql --linked
--
-- It drives realtime.authorize() — the exact function the Realtime server calls
-- when a client joins a private channel — with real user ids taken from
-- public.connections, and raises on the first unexpected result. The whole file
-- runs in one transaction that is rolled back at the end, and authorize() rolls
-- its own probe inserts back, so nothing is persisted here.
--
-- read_allowed / write_allowed return one boolean per requested extension, in
-- the order given. The policies deliberately ignore the extension label (it has
-- been renamed across Realtime versions), so every label must be allowed for a
-- participant and denied for everybody else.
begin;

create or replace function public.__authz_probe(chan text, uid uuid, role_name text)
returns boolean[] language plpgsql as $f$
declare
  r boolean[];
  w boolean[];
begin
  select read_allowed, write_allowed into r, w
  from realtime.authorize(
    role_name, chan,
    json_build_object('role', role_name, 'sub', uid::text)::text,
    case when role_name = 'anon' then null else uid::text end,
    '{}',
    array['broadcast', 'presence', 'postgres_changes'],
    array['broadcast', 'presence']);
  return coalesce(r, '{}'::boolean[]) || coalesce(w, '{}'::boolean[]);
end;
$f$;

-- ── S1: both members of a real accepted connection may subscribe and publish ─
do $do$
declare
  a uuid;
  b uuid;
  chan text;
  got boolean[];
  unrelated uuid;
begin
  select user_a_id, user_b_id into a, b from public.connections limit 1;
  if a is null then
    raise exception 'NO CONNECTION ROW: nothing to authorize against';
  end if;
  chan := 'chat-' || least(a, b)::text || '_' || greatest(a, b)::text;

  got := public.__authz_probe(chan, a, 'authenticated');
  if got != array[true, true, true, true, true] then
    raise exception 'FAILED S1: user_a cannot subscribe/publish own conversation: %', got;
  end if;

  got := public.__authz_probe(chan, b, 'authenticated');
  if got != array[true, true, true, true, true] then
    raise exception 'FAILED S1: user_b cannot subscribe/publish own conversation: %', got;
  end if;

  -- ── S2: the same pair with the ids the other way round is still their own
  -- conversation, so a build that has not picked up the canonical sorted name is
  -- not locked out of a channel it could only ever reach itself on.
  got := public.__authz_probe(
    'chat-' || greatest(a, b)::text || '_' || least(a, b)::text, a, 'authenticated');
  if got != array[true, true, true, true, true] then
    raise exception 'FAILED S2: unsorted own topic refused: %', got;
  end if;

  -- ── S3: an unrelated authenticated user may neither join nor publish.
  select u.id into unrelated from auth.users u
  where not exists (select 1 from public.connections c
                    where c.user_a_id = u.id or c.user_b_id = u.id)
  limit 1;
  if unrelated is null then
    raise exception 'NO UNRELATED USER: cannot test the outsider case';
  end if;

  got := public.__authz_probe(chan, unrelated, 'authenticated');
  if got != array[false, false, false, false, false] then
    raise exception 'FAILED S3: unrelated user reached the conversation: %', got;
  end if;

  -- ── S4: the outsider cannot even read the conversation channel's rows.
  -- A Broadcast row on the channel topic is written here as the table owner,
  -- inside the transaction that is rolled back at the end of this file.
  insert into realtime.messages (topic, extension, inserted_at, updated_at)
    values (chan, 'broadcast', now() at time zone 'utc', now() at time zone 'utc');

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', a::text)::text, true);
  if not exists (select 1 from realtime.messages where topic = chan) then
    raise exception 'FAILED S4: a participant cannot read the channel row';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', unrelated::text)::text, true);
  if exists (select 1 from realtime.messages where topic = chan) then
    raise exception 'FAILED S4: an unrelated user can read the channel row';
  end if;
  reset role;

  -- ── S5: the anonymous role is denied on a conversation channel.
  got := public.__authz_probe(chan, a, 'anon');
  if got != array[false, false, false, false, false] then
    raise exception 'FAILED S5: anon reached the conversation: %', got;
  end if;
end $do$;

-- ── S6: foreign, degenerate and non-conversation topics grant nothing ────────
do $do$
declare
  a uuid;
  b uuid;
  other uuid;
  got boolean[];
  t text;
begin
  select user_a_id, user_b_id into a, b from public.connections limit 1;
  select u.id into other from auth.users u
  where not exists (select 1 from public.connections c
                    where c.user_a_id = u.id or c.user_b_id = u.id)
  limit 1;

  for t in
    select x from (values
      -- a conversation channel whose pair holds no accepted connection
      ('chat-' || a::text || '_' || gen_random_uuid()::text),
      -- both slots the same user
      ('chat-' || a::text || '_' || a::text),
      -- somebody else's conversation, viewed by a real user
      ('chat-' || other::text || '_' || gen_random_uuid()::text),
      -- the map channel: not a conversation, must stay untouched
      ('kaspot-location-map-' || a::text),
      -- unparsable shapes, including the server-side topic form
      ('chat-not-a-uuid'),
      ('realtime:chat-' || a::text || '_x')
    ) v(x)
  loop
    got := public.__authz_probe(t, a, 'authenticated');
    if got != array[false, false, false, false, false] then
      raise exception 'FAILED S6: topic % allowed %', t, got;
    end if;
  end loop;
end $do$;

drop function if exists public.__authz_probe(text, uuid, text);

-- Nothing in this file is meant to persist.
rollback;
