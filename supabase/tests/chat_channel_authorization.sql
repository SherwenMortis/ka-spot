-- =============================================================================
-- KaSpot — authorization for the private Circle-chat Realtime channel
--
-- Run against an isolated staging project (never production):
--   psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/chat_channel_authorization.sql
--
-- WHAT THIS TESTS
--   The private-channel boundary is the pair of RLS policies on
--   realtime.messages (chat_channel_participant_receive / _publish), which call
--   public.is_chat_channel_participant(topic). Those policies are what the
--   Realtime server evaluates for a subscriber. This file drives them directly
--   as the subscribing role:
--     read  -> can the role see a realtime.messages row on that topic
--     write -> can the role insert one (a Broadcast publish)
--
--   An earlier version of this file called realtime.authorize(), a SQL function
--   that Realtime v2.140.10 does not provide (verified: `function
--   realtime.authorize(...) does not exist`). Driving the policies through RLS
--   needs no Realtime-version-specific SQL, and it exercises the same predicates
--   the server uses.
--
--   The whole file runs in one transaction and is rolled back, so no fixture
--   row, policy or topic persists.
--
-- S1  both members of an accepted connection may read and publish
-- S2  the same pair with the ids unsorted is still their own conversation
-- S3  an unrelated signed-in user may neither read nor publish
-- S4  an unrelated user sees none of the channel's rows
-- S5  anon is denied on a conversation channel
-- S6  foreign / degenerate / non-conversation topics grant nothing
-- =============================================================================

begin;

-- Read probe: can `uid` see rows on `chan`?
create or replace function public.__authz_can_read(chan text, uid uuid)
returns boolean language plpgsql as $f$
declare
  visible boolean;
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', uid::text)::text, true);
  select exists (select 1 from realtime.messages where topic = chan) into visible;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return visible;
end;
$f$;

-- Anon read probe: same question with no identity at all.
create or replace function public.__authz_anon_can_read(chan text)
returns boolean language plpgsql as $f$
declare
  visible boolean;
begin
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{}', true);
  select exists (select 1 from realtime.messages where topic = chan) into visible;
  reset role;
  return visible;
end;
$f$;

-- Publish probe: can `uid` insert a Broadcast row on `chan`?
-- A policy denial surfaces as insufficient_privilege, which is the answer.
create or replace function public.__authz_can_write(chan text, uid uuid)
returns boolean language plpgsql as $f$
declare
  allowed boolean := true;
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', uid::text)::text, true);
  begin
    insert into realtime.messages (topic, extension, private)
      values (chan, 'broadcast', true);
  exception when insufficient_privilege then
    allowed := false;
  end;
  reset role;
  perform set_config('request.jwt.claims', '{}', true);
  return allowed;
end;
$f$;

-- Anon publish probe.
create or replace function public.__authz_anon_can_write(chan text)
returns boolean language plpgsql as $f$
declare
  allowed boolean := true;
begin
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{}', true);
  begin
    insert into realtime.messages (topic, extension, private)
      values (chan, 'broadcast', true);
  exception when insufficient_privilege then
    allowed := false;
  end;
  reset role;
  return allowed;
end;
$f$;

-- ── S1/S2: the two participants of a real connection ───────────────────────
do $do$
declare
  a uuid;
  b uuid;
  chan text;
begin
  select user_a_id, user_b_id into a, b from public.connections limit 1;
  if a is null then
    raise exception 'NO CONNECTION ROW: seed at least one accepted connection';
  end if;

  chan := 'chat-' || least(a, b)::text || '_' || greatest(a, b)::text;

  -- A row on the topic, written as the owner, so a read probe is meaningful.
  insert into realtime.messages (topic, extension, private)
    values (chan, 'broadcast', true);

  if not public.__authz_can_read(chan, a) then
    raise exception 'FAILED S1: user_a cannot read their own conversation channel';
  end if;
  if not public.__authz_can_write(chan, a) then
    raise exception 'FAILED S1: user_a cannot publish on their own conversation channel';
  end if;
  if not public.__authz_can_read(chan, b) then
    raise exception 'FAILED S1: user_b cannot read the conversation channel';
  end if;
  if not public.__authz_can_write(chan, b) then
    raise exception 'FAILED S1: user_b cannot publish on the conversation channel';
  end if;

  -- ── S2: the unsorted topic form is the same conversation ────────────────
  chan := 'chat-' || greatest(a, b)::text || '_' || least(a, b)::text;
  insert into realtime.messages (topic, extension, private)
    values (chan, 'broadcast', true);
  if not public.__authz_can_read(chan, a) then
    raise exception 'FAILED S2: unsorted own topic refused for reads';
  end if;
  if not public.__authz_can_write(chan, a) then
    raise exception 'FAILED S2: unsorted own topic refused for writes';
  end if;
end $do$;

-- ── S3/S4: an unrelated signed-in user ────────────────────────────────────
do $do$
declare
  a uuid;
  b uuid;
  outsider uuid;
  chan text;
begin
  select user_a_id, user_b_id into a, b from public.connections limit 1;

  select u.id into outsider from auth.users u
  where not exists (
    select 1 from public.connections c
    where c.user_a_id = u.id or c.user_b_id = u.id)
  limit 1;
  if outsider is null then
    raise exception 'NO UNRELATED USER: seed a user with no connections';
  end if;

  chan := 'chat-' || least(a, b)::text || '_' || greatest(a, b)::text;
  insert into realtime.messages (topic, extension, private)
    values (chan, 'broadcast', true);

  if public.__authz_can_read(chan, outsider) then
    raise exception 'FAILED S3: an unrelated user can read the conversation channel';
  end if;
  if public.__authz_can_write(chan, outsider) then
    raise exception 'FAILED S3: an unrelated user can publish on the conversation channel';
  end if;

  -- S4: and the row itself is invisible to them.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', outsider::text)::text, true);
  if exists (select 1 from realtime.messages where topic = chan) then
    raise exception 'FAILED S4: an unrelated user can see the channel row';
  end if;
  reset role;
end $do$;

-- ── S5: anonymous ─────────────────────────────────────────────────────────
do $do$
declare
  a uuid;
  b uuid;
  chan text;
begin
  select user_a_id, user_b_id into a, b from public.connections limit 1;
  chan := 'chat-' || least(a, b)::text || '_' || greatest(a, b)::text;

  insert into realtime.messages (topic, extension, private)
    values (chan, 'broadcast', true);

  if public.__authz_anon_can_read(chan) then
    raise exception 'FAILED S5: anon can read a conversation channel';
  end if;
  if public.__authz_anon_can_write(chan) then
    raise exception 'FAILED S5: anon can publish on a conversation channel';
  end if;
end $do$;

-- ── S6: topics that must never authorize anyone ───────────────────────────
do $do$
declare
  a uuid;
  b uuid;
  other uuid;
  t text;
begin
  select user_a_id, user_b_id into a, b from public.connections limit 1;

  select u.id into other from auth.users u
  where not exists (
    select 1 from public.connections c
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
    insert into realtime.messages (topic, extension, private)
      values (t, 'broadcast', true);

    if public.__authz_can_read(t, a) then
      raise exception 'FAILED S6: topic % is readable', t;
    end if;
    if public.__authz_can_write(t, a) then
      raise exception 'FAILED S6: topic % is writable', t;
    end if;
  end loop;
end $do$;

drop function if exists public.__authz_can_read(text, uuid);
drop function if exists public.__authz_anon_can_read(text);
drop function if exists public.__authz_can_write(text, uuid);
drop function if exists public.__authz_anon_can_write(text);

do $do$
begin
  raise notice 'chat_channel_authorization: S1-S6 passed';
end $do$;

-- Nothing in this file is meant to persist.
rollback;
