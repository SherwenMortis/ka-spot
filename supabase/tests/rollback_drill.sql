-- =============================================================================
-- KaSpot — rollback drill for migration 20261024 (RPC caller scope)
--
-- This file does not test the product. It tests the RECOVERY PROCEDURE, and it
-- makes the claim in that procedure measurable instead of rhetorical:
--
--   "Reverting the function bodies keeps every privilege check green while it
--    hands any signed-in user a truthful oracle over every other user's
--    connection graph."
--
-- Stages, all inside one transaction that is rolled back:
--   R1  the installed state is intact (identity predicate present, ACLs as designed)
--   R2  install the pre-migration body -> an ACL check still passes (silent!)
--   R3  ... and a non-participant gets a TRUE answer about two other users
--   R4  ... and the structural detector from install_contract.sql C8 flags it
--   R5  apply the documented recovery -> detector clean, ACLs restored, and the
--       same non-participant now gets FALSE
--
-- Nothing here writes to the database after the final rollback. Run on staging:
--
--   psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/rollback_drill.sql
--
-- Fixture requirement: at least one row in public.connections (a real accepted
-- pair) and a third auth user that is not part of it.
-- =============================================================================

begin;

do $drill$
declare
  a            uuid;
  b            uuid;
  outsider     uuid;
  orig_role    text;
  flagged      integer;
  legacy_true  boolean;
  recovered_false boolean;
  anon_can     boolean;
  auth_can     boolean;
  svc_can      boolean;
begin
  orig_role := current_user;

  -- ── Fixture ─────────────────────────────────────────────────────────────
  select c.user_a_id, c.user_b_id into a, b from public.connections c limit 1;
  if a is null then
    raise exception 'NO CONNECTION ROW: seed at least one accepted connection';
  end if;

  select u.id into outsider
  from auth.users u
  where u.id not in (a, b)
    and not exists (
      select 1 from public.connections x
      where x.user_a_id = least(u.id, a) and x.user_b_id = greatest(u.id, a)
    )
    and not exists (
      select 1 from public.connections x
      where x.user_a_id = least(u.id, b) and x.user_b_id = greatest(u.id, b)
    )
  order by u.id
  limit 1;
  if outsider is null then
    raise exception 'NO UNRELATED USER: need a third user not connected to the fixture pair';
  end if;

  -- ── R1: the installed state is the design ───────────────────────────────
  select count(*) into flagged
  from pg_proc p
  where p.oid = to_regprocedure('public.is_accepted_connection(uuid,uuid)')::oid
    and pg_get_functiondef(p.oid) !~* 'auth\.uid\(\)';
  if flagged <> 0 then
    raise exception 'R1: the identity predicate is already missing — run the recovery (migration 20261024) before drilling';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', outsider::text)::text, true);
  if public.is_accepted_connection(a, b) then
    raise exception 'R1: a non-participant already learns a foreign connection — state is not the design';
  end if;
  perform set_config('role', orig_role, true);
  perform set_config('request.jwt.claims', '{}', true);

  -- ── R2: install the pre-migration body, as the old rollback would ───────
  -- Dynamic SQL: a CREATE FUNCTION inside a plpgsql block is a utility
  -- statement SPI can run, but EXECUTE keeps the nested body unambiguous.
  execute $ddl$
    create or replace function public.is_accepted_connection(a uuid, b uuid)
    returns boolean language sql stable security definer set search_path = '' as $legacy$
      select exists (
        select 1 from public.connections c
        where c.user_a_id = least(a, b) and c.user_b_id = greatest(a, b)
      );
    $legacy$
  $ddl$;

  -- The grants are untouched, which is the whole problem: every ACL assertion
  -- still passes, so a privileges-only check reports "fine".
  anon_can := has_function_privilege('anon',
    'public.is_accepted_connection(uuid,uuid)', 'EXECUTE');
  auth_can := has_function_privilege('authenticated',
    'public.is_accepted_connection(uuid,uuid)', 'EXECUTE');
  svc_can := has_function_privilege('service_role',
    'public.is_accepted_connection(uuid,uuid)', 'EXECUTE');
  if anon_can or svc_can or not auth_can then
    raise exception
      'R2: unexpected ACL state after the body swap (anon=%, authenticated=%, service_role=%) — the drill assumes the old rollback did not touch grants',
      anon_can, auth_can, svc_can;
  end if;

  -- ── R3: the regression is real, and it is an authenticated oracle ───────
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', outsider::text)::text, true);
  legacy_true := public.is_accepted_connection(a, b);
  perform set_config('role', orig_role, true);
  perform set_config('request.jwt.claims', '{}', true);

  if not legacy_true then
    raise exception 'R3: the legacy body did NOT answer a non-participant — the premise of the recovery section is wrong, re-examine it';
  end if;

  -- ── R4: the structural detector catches it ──────────────────────────────
  select count(*) into flagged
  from pg_proc p
  where p.oid = to_regprocedure('public.is_accepted_connection(uuid,uuid)')::oid
    and pg_get_functiondef(p.oid) !~* 'auth\.uid\(\)';
  if flagged <> 1 then
    raise exception 'R4: install_contract.sql C8 would NOT have caught this replacement';
  end if;

  -- ── R5: the documented recovery restores the design ─────────────────────
  -- Exactly the statements `create or replace` + explicit revokes in
  -- supabase/migrations/20261024_rpc_caller_scope.sql perform.
  execute $ddl$
    create or replace function public.is_accepted_connection(a uuid, b uuid)
    returns boolean language sql stable security definer set search_path = '' as $secure$
      select (select auth.uid()) is not null
         and ((select auth.uid()) = a or (select auth.uid()) = b)
         and kaspot_internal.is_connected(a, b);
    $secure$
  $ddl$;

  revoke all on function public.is_accepted_connection(uuid, uuid)
    from public, anon, authenticated, service_role;
  grant execute on function public.is_accepted_connection(uuid, uuid)
    to authenticated;

  select count(*) into flagged
  from pg_proc p
  where p.oid = to_regprocedure('public.is_accepted_connection(uuid,uuid)')::oid
    and pg_get_functiondef(p.oid) !~* 'auth\.uid\(\)';
  if flagged <> 0 then
    raise exception 'R5: recovery did not restore the identity predicate';
  end if;

  if has_function_privilege('anon', 'public.is_accepted_connection(uuid,uuid)', 'EXECUTE')
     or has_function_privilege('service_role', 'public.is_accepted_connection(uuid,uuid)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.is_accepted_connection(uuid,uuid)', 'EXECUTE') then
    raise exception 'R5: recovery did not restore the intended grants';
  end if;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', outsider::text)::text, true);
  recovered_false := public.is_accepted_connection(a, b);

  -- Still the outsider: a participant must get TRUE, so the false above is the
  -- identity rule and not a broken function.
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', a::text)::text, true);
  if not public.is_accepted_connection(a, b) then
    raise exception 'R5: recovery broke the participant case';
  end if;
  perform set_config('role', orig_role, true);
  perform set_config('request.jwt.claims', '{}', true);

  if recovered_false then
    raise exception 'R5: the outsider still reads a foreign connection after recovery';
  end if;

  raise notice 'rollback_drill: R1-R5 passed (legacy body = authenticated oracle, detector catches it, recovery restores the design)';
end
$drill$;

-- The drill replaced a function to make its point; nothing it did may persist.
rollback;
