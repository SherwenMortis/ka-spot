-- =============================================================================
-- KaSpot — authorization and privileges of the connection/message helpers
--
-- Verifies supabase/migrations/20261024_rpc_caller_scope.sql. Run against an
-- isolated staging project only, AFTER the migration is applied:
--
--   psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/rpc_caller_scope.sql
--
-- Everything runs in one transaction that is rolled back, including the fixture
-- connection, message and sharing grant it creates.
--
-- Covers
--   G1  an unauthenticated caller (role anon) cannot execute either helper
--   G2  a request with no user identity cannot bypass the caller restriction
--   G3  a connected participant gets the expected answer
--   G4  a non-participant cannot probe arbitrary connection relationships
--   G5  a non-participant cannot probe message/conversation membership
--   G6  trusted service-side code still works through the internal helper
--   G7  RLS policies behave exactly as before for valid and invalid users
--   G8  effective privileges match the least-privilege design (incl. PUBLIC)
-- =============================================================================

begin;

do $do$
declare
  a uuid;          -- sender of the existing connection
  b uuid;          -- recipient of the existing connection
  c uuid;          -- outsider
  d uuid;          -- second pair, so a connected pair exists that excludes `a`
  msg uuid;        -- a real message between a and b
  foreign_msg uuid;-- a real message between c and d
  blocked boolean;
  n integer;
begin
  -- ── Fixture ─────────────────────────────────────────────────────────────
  select user_a_id, user_b_id into a, b from public.connections limit 1;
  if a is null then
    raise exception 'NO CONNECTION ROW: seed at least two connected users';
  end if;

  select id into msg from public.circle_messages
  where sender_id in (a, b) and recipient_id in (a, b)
  limit 1;
  if msg is null then
    insert into public.circle_messages (sender_id, recipient_id, content)
      values (a, b, 'authorization fixture') returning id into msg;
  end if;

  select u.id into c from auth.users u where u.id not in (a, b) order by u.id limit 1;
  select u.id into d from auth.users u
  where u.id not in (a, b, c)
    and not exists (
      select 1 from public.connections x
      where x.user_a_id = least(u.id, c) and x.user_b_id = greatest(u.id, c)
    )
  order by u.id limit 1;
  if c is null or d is null then
    raise exception 'FIXTURE: need 4 users, with the 3rd not connected to the 4th';
  end if;

  insert into public.connections (user_a_id, user_b_id)
    values (least(c, d), greatest(c, d));
  insert into public.circle_messages (sender_id, recipient_id, content)
    values (c, d, 'foreign conversation fixture') returning id into foreign_msg;

  -- ── G8 (part 1): PUBLIC holds no EXECUTE ────────────────────────────────
  -- acldefault('f', owner) is what PostgreSQL uses when proacl is null, which
  -- is exactly the state in which PUBLIC *does* have EXECUTE.
  for n in
    select count(*) from (
      select p.oid
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
      cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
      where (ns.nspname, p.proname) in (
              ('public', 'is_accepted_connection'),
              ('public', 'is_valid_reply'),
              ('kaspot_internal', 'is_connected'),
              ('kaspot_internal', 'reply_in_conversation'))
        and acl.grantee = 0            -- 0 = PUBLIC
        and acl.privilege_type = 'EXECUTE'
    ) public_grants
  loop
    if n > 0 then
      raise exception 'FAILED G8: PUBLIC holds EXECUTE on % function(s)', n;
    end if;
  end loop;

  -- ── G8 (part 2): the roles that do and do not hold EXECUTE ──────────────
  if has_function_privilege('anon',
       'public.is_accepted_connection(uuid,uuid)', 'EXECUTE')
     or has_function_privilege('anon',
       'public.is_valid_reply(uuid,uuid,uuid)', 'EXECUTE') then
    raise exception 'FAILED G8: anon still holds EXECUTE on a public helper';
  end if;

  if not has_function_privilege('authenticated',
       'public.is_accepted_connection(uuid,uuid)', 'EXECUTE')
     or not has_function_privilege('authenticated',
       'public.is_valid_reply(uuid,uuid,uuid)', 'EXECUTE') then
    raise exception 'FAILED G8: authenticated lost EXECUTE on a public helper';
  end if;

  if has_function_privilege('service_role',
       'public.is_accepted_connection(uuid,uuid)', 'EXECUTE')
     or has_function_privilege('service_role',
       'public.is_valid_reply(uuid,uuid,uuid)', 'EXECUTE') then
    raise exception 'FAILED G8: service_role can call the client wrapper (it would get false)';
  end if;

  if has_schema_privilege('authenticated', 'kaspot_internal', 'USAGE')
     or has_schema_privilege('anon', 'kaspot_internal', 'USAGE') then
    raise exception 'FAILED G8: a client role has USAGE on kaspot_internal';
  end if;

  if has_function_privilege('authenticated',
       'kaspot_internal.is_connected(uuid,uuid)', 'EXECUTE')
     or has_function_privilege('anon',
       'kaspot_internal.reply_in_conversation(uuid,uuid,uuid)', 'EXECUTE') then
    raise exception 'FAILED G8: a client role can execute an internal helper';
  end if;

  if not has_function_privilege('service_role',
       'kaspot_internal.is_connected(uuid,uuid)', 'EXECUTE')
     or not has_function_privilege('service_role',
       'kaspot_internal.reply_in_conversation(uuid,uuid,uuid)', 'EXECUTE') then
    raise exception 'FAILED G8: service_role cannot use the internal helpers';
  end if;

  -- ── G1: an unauthenticated caller (role anon, no JWT) is refused ───────
  -- This is the regression that matters: before the fix, the anon grant from
  -- default privileges plus `auth.uid() IS NULL` returned the true answer.
  perform set_config('role', 'anon', true);
  perform set_config('request.jwt.claims', '{}', true);

  blocked := false;
  begin
    perform public.is_accepted_connection(a, b);
  exception when others then
    blocked := true;
  end;
  if not blocked then
    raise exception 'FAILED G1: anon executed is_accepted_connection';
  end if;

  blocked := false;
  begin
    perform public.is_valid_reply(msg, a, b);
  exception when others then
    blocked := true;
  end;
  if not blocked then
    raise exception 'FAILED G1: anon executed is_valid_reply';
  end if;

  blocked := false;
  begin
    perform kaspot_internal.is_connected(a, b);
  exception when others then
    blocked := true;
  end;
  if not blocked then
    raise exception 'FAILED G1: anon reached the internal helper';
  end if;

  -- ── G2: authenticated role, but no identity in the token ───────────────
  -- A JWT with no `sub` is what a forged or stripped token looks like. The
  -- wrapper must answer false, not the truth, and must not raise.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims', '{}', true);

  if public.is_accepted_connection(a, b) then
    raise exception 'FAILED G2: no-identity request read a real connection';
  end if;
  if public.is_accepted_connection(c, d) then
    raise exception 'FAILED G2: no-identity request read a foreign connection';
  end if;
  if public.is_valid_reply(msg, a, b) then
    raise exception 'FAILED G2: no-identity request probed a message';
  end if;

  -- ── G3: a connected participant is answered truthfully ─────────────────
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', a::text)::text, true);

  if not public.is_accepted_connection(a, b) then
    raise exception 'FAILED G3: a participant cannot confirm their own connection';
  end if;
  if not public.is_accepted_connection(b, a) then
    raise exception 'FAILED G3: argument order broke a participant pair';
  end if;
  if not public.is_valid_reply(msg, a, b) then
    raise exception 'FAILED G3: a participant cannot validate their own message';
  end if;

  -- ── G4: a non-participant cannot probe other connections ───────────────
  -- `a` is connected to `b` but not to `c`/`d`; `c`-`d` is a real connection
  -- that must not be readable by `a`.
  if public.is_accepted_connection(c, d) then
    raise exception 'FAILED G4: a caller learned that two other users are connected';
  end if;
  if public.is_accepted_connection(a, c) then
    raise exception 'FAILED G4: a caller learned about a pair it is not part of';
  end if;

  -- ── G5: a non-participant cannot probe message membership ──────────────
  if public.is_valid_reply(foreign_msg, c, d) then
    raise exception 'FAILED G5: a caller tested whether a foreign message exists';
  end if;

  -- ── G6: trusted service-side code uses the internal helper ─────────────
  perform set_config('role', 'service_role', true);
  perform set_config('request.jwt.claims', '{}', true);

  if not kaspot_internal.is_connected(a, b) then
    raise exception 'FAILED G6: service_role lost the connection fact';
  end if;
  if not kaspot_internal.is_connected(c, d) then
    raise exception 'FAILED G6: service_role cannot read the fixture connection';
  end if;
  if not kaspot_internal.reply_in_conversation(foreign_msg, c, d) then
    raise exception 'FAILED G6: service_role lost the message fact';
  end if;

  -- ── G7: RLS is unchanged for valid and invalid users ───────────────────
  perform set_config('role', 'authenticated', true);

  -- Participant: the message policy calls is_accepted_connection(sender,
  -- recipient) and must still see its own conversation.
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', a::text)::text, true);
  if not exists (select 1 from public.circle_messages where id = msg) then
    raise exception 'FAILED G7: the sender can no longer read their own message';
  end if;
  if not exists (select 1 from public.profiles where id = b) then
    raise exception 'FAILED G7: a connection can no longer read the peer profile';
  end if;

  -- Participant may still grant location sharing to a connection (this goes
  -- through guard_sharing_upsert, a SECURITY INVOKER trigger).
  insert into public.location_sharing (owner_id, recipient_id, is_enabled)
    values (a, b, true);

  -- Outsider: same reads must stay denied, and an unrelated sharing grant must
  -- be refused by RLS or by the trigger.
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', c::text)::text, true);
  if exists (select 1 from public.circle_messages where id = msg) then
    raise exception 'FAILED G7: an outsider can read a message they are not part of';
  end if;
  if exists (select 1 from public.profiles where id = b) then
    raise exception 'FAILED G7: an outsider can read an unrelated profile';
  end if;

  blocked := false;
  begin
    insert into public.location_sharing (owner_id, recipient_id, is_enabled)
      values (c, b, true);
  exception when others then
    blocked := true;
  end;
  if not blocked then
    raise exception 'FAILED G7: an outsider created a sharing grant to a stranger';
  end if;

  perform set_config('role', 'postgres', true);
  raise notice 'rpc_caller_scope: G1-G8 passed';
end $do$;

rollback;
