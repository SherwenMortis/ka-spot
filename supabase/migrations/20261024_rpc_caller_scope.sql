-- =============================================================================
-- KaSpot — least-privilege authorization for the connection/message helpers
--
-- STATUS: PREPARED, NOT APPLIED. Applying it is a separate, approved step. It
-- re-asserts its own post-conditions inside the transaction, so a run that does
-- not end in the intended ACL state rolls back instead of committing. There is
-- no safe rollback to the previous function bodies — read the RECOVERY section
-- at the bottom of this file before attempting one.
--
-- ── What the previous revision of this migration got wrong ──────────────────
--   It kept `auth.uid() IS NULL OR ...` as the caller guard and only relied on
--   `revoke all ... from public`. Both halves are unsafe on Supabase:
--
--   1. `revoke ... from public` does not remove a DIRECT grant. Supabase's
--      default privileges grant every new function in `public` to anon,
--      authenticated and service_role, so the ACL after
--      `revoke all ... from public; grant execute ... to authenticated;`
--      still reads: anon=X | authenticated=X | service_role=X.
--      Verified by execution, not by reading: see the probe in the report.
--
--   2. `auth.uid() IS NULL` then becomes an unauthenticated bypass. A caller
--      with only the project anon key (no session, no JWT) reaches the function
--      as role anon, auth.uid() returns null, and the guard admits it. Result:
--      an unauthenticated connection-graph and message-existence oracle.
--      Verified by execution: "ANON BYPASS: unauthenticated caller read the
--      connection graph".
--
-- ── Design after this migration ─────────────────────────────────────────────
--   Two layers, because the same fact has two different audiences.
--
--   INTERNAL (kaspot_internal schema — never in PostgREST's exposed schemas):
--     kaspot_internal.is_connected(a, b)                pure fact, no identity
--     kaspot_internal.reply_in_conversation(id, s, r)   pure fact, no identity
--       SECURITY DEFINER, search_path = '', EXECUTE to service_role only.
--       Client roles get neither USAGE on the schema nor EXECUTE on the
--       functions, so even if the schema were ever exposed by PostgREST a
--       signed-in caller could not invoke them.
--
--   PUBLIC (public schema — the Data API surface):
--     public.is_accepted_connection(a, b)
--     public.is_valid_reply(id, s, r)
--       SECURITY DEFINER, search_path = ''.
--       Identity is REQUIRED: auth.uid() must be non-null AND must be one of
--       the supplied identifiers. No JWT -> false, never a fact.
--       EXECUTE to authenticated only; revoked from public, anon AND
--       service_role (a server call would get `false`, which is a lie, so it
--       fails with 42501 and the caller must use the internal helper).
--
--   RLS policies keep calling the public wrapper. Every policy call site passes
--   auth.uid() as one of the arguments, and inside a SECURITY DEFINER function
--   the nested call is authorized against the owner, so the wrapper's identity
--   check is satisfied without granting `authenticated` anything on the
--   internal schema.
--
-- ── Every call site traced before writing this ──────────────────────────────
--   schema.sql:177  guard_sharing_upsert (SECURITY INVOKER)  owner_id = auth.uid()
--   schema.sql:201  profiles SELECT                          (id, auth.uid())
--   schema.sql:221  connection_requests INSERT               requester = auth.uid()
--   schema.sql:250  location_sharing INSERT                  owner_id = auth.uid()
--   schema.sql:254  location_sharing UPDATE                  owner_id = auth.uid()
--   schema.sql:277  locations SELECT                         recipient = auth.uid()
--   schema.sql:356  circle_messages SELECT                   participant = auth.uid()
--   schema.sql:392  circle_messages INSERT                   sender_id = auth.uid()
--   schema.sql:400  is_valid_reply inside that INSERT        sender_id = auth.uid()
--   schema.sql:598  message_reactions SELECT                 participant = auth.uid()
--   schema.sql:611  message_reactions INSERT                 participant = auth.uid()
--   schema.sql:634  message_reactions UPDATE                 participant = auth.uid()
--   20261023_private_chat_channel_authorization.sql:56
--                   is_chat_channel_participant (SECURITY DEFINER)
--                   uid = any(members) is asserted before the nested call
--   No TypeScript or Dart code calls either helper: notify-new-message reads
--   public.connections directly with the service role.
--
-- Verification required before applying (all three, on staging):
--   psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rpc_caller_scope.sql
--   psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/location_retention.sql
--   psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/chat_channel_authorization.sql
-- =============================================================================

begin;

-- ── 1. Internal schema ─────────────────────────────────────────────────────
-- A name of its own rather than `private`: some Supabase templates already use
-- `private` for other functions, and revoking USAGE there would break them.
create schema if not exists kaspot_internal;

revoke all on schema kaspot_internal from public;
revoke all on schema kaspot_internal from anon;
revoke all on schema kaspot_internal from authenticated;
grant usage on schema kaspot_internal to service_role;

comment on schema kaspot_internal is
  'KaSpot internal helpers. Not exposed through the Data API: no client role '
  'holds USAGE or EXECUTE, so these are reachable only from SECURITY DEFINER '
  'code owned by postgres and from the service role.';

-- ── 2. Internal fact helpers: no identity logic, no client access ──────────
create or replace function kaspot_internal.is_connected(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.connections c
    where c.user_a_id = least(a, b) and c.user_b_id = greatest(a, b)
  );
$$;

create or replace function kaspot_internal.reply_in_conversation(
  reply_id uuid,
  sender   uuid,
  recip    uuid
)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.circle_messages m
    where m.id = reply_id
      and (
        (m.sender_id = sender and m.recipient_id = recip)
        or (m.sender_id = recip  and m.recipient_id = sender)
      )
  );
$$;

comment on function kaspot_internal.is_connected(uuid, uuid) is
  'Pure fact: are these two users accepted connections? Carries no caller '
  'check, so it is granted only to service_role and to SECURITY DEFINER code.';

comment on function kaspot_internal.reply_in_conversation(uuid, uuid, uuid) is
  'Pure fact: does reply_id belong to the conversation between sender and '
  'recip? Granted only to service_role and to SECURITY DEFINER code.';

revoke all on function kaspot_internal.is_connected(uuid, uuid)
  from public, anon, authenticated;
revoke all on function kaspot_internal.reply_in_conversation(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function kaspot_internal.is_connected(uuid, uuid)
  to service_role;
grant execute on function kaspot_internal.reply_in_conversation(uuid, uuid, uuid)
  to service_role;

-- ── 3. Public wrappers: identity required, participant scope required ──────
create or replace function public.is_accepted_connection(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null
     and ((select auth.uid()) = a or (select auth.uid()) = b)
     and kaspot_internal.is_connected(a, b);
$$;

create or replace function public.is_valid_reply(
  reply_id uuid,
  sender   uuid,
  recip    uuid
)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null
     and ((select auth.uid()) = sender or (select auth.uid()) = recip)
     and kaspot_internal.reply_in_conversation(reply_id, sender, recip);
$$;

comment on function public.is_accepted_connection(uuid, uuid) is
  'Client-facing: true only when the signed-in caller is one of the pair and '
  'the pair is an accepted connection. Returns false without an identity. '
  'Trusted server code uses kaspot_internal.is_connected instead.';

comment on function public.is_valid_reply(uuid, uuid, uuid) is
  'Client-facing: true only when the signed-in caller participates in the '
  'conversation and reply_id belongs to it. Returns false without an identity.';

-- CREATE OR REPLACE keeps the old ACL, so the anon grant from default
-- privileges has to be revoked by name; revoking PUBLIC alone never removed it.
revoke all on function public.is_accepted_connection(uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.is_valid_reply(uuid, uuid, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.is_accepted_connection(uuid, uuid)
  to authenticated;
grant execute on function public.is_valid_reply(uuid, uuid, uuid)
  to authenticated;

-- ── 4. The same hole on the other client RPCs of this project ──────────────
-- None of these is reachable by a caller who has not signed in, and none of
-- them needs anon. Guarded with to_regprocedure so a partially built database
-- (schema.sql without the 20261023 migration, or the reverse) still applies.
do $do$
declare
  signature text;
begin
  foreach signature in array array[
    'public.lookup_user_by_code(text)',
    'public.upsert_reaction(uuid,text)',
    'public.chat_channel_users(text)',
    'public.is_chat_channel_participant(text)'
  ] loop
    if to_regprocedure(signature) is not null then
      execute format('revoke execute on function %s from public', signature);
      execute format('revoke execute on function %s from anon', signature);
    end if;
  end loop;
end $do$;

-- ── 4b. The same gap on two tables ────────────────────────────────────────
-- public.device_tokens and public.circle_messages were added to schema.sql
-- after the `revoke all ... from anon` list above them, so they carried the
-- anon grant from Supabase's default privileges. schema.sql now revokes it, but
-- a database upgraded by migrations alone never re-ran that file: the two
-- installation paths ended in different ACLs, which
-- supabase/tests/install_contract.sql C6 reports as
-- "anon holds a table privilege on public.device_tokens".
--
-- Both tables are RLS-protected with policies restricted to `authenticated`, so
-- anon reads no rows either way; this closes the privilege half of the same
-- least-privilege rule rather than a live exposure. Guarded with to_regclass so
-- the file still applies to a partially built database.
do $do$
declare
  table_name text;
begin
  foreach table_name in array array[
    'public.device_tokens',
    'public.circle_messages'
  ] loop
    if to_regclass(table_name) is not null then
      execute format('revoke all on %s from anon', table_name);
    end if;
  end loop;
end $do$;

-- ── 5. Refuse to commit if the resulting privileges are not the design ─────
-- A migration that silently leaves anon executable would reproduce exactly the
-- bug this file fixes, so the checks are inside the transaction.
do $do$
declare
  public_signature text;
  internal_signature text;
  table_name text;
begin
  foreach public_signature in array array[
    'public.is_accepted_connection(uuid,uuid)',
    'public.is_valid_reply(uuid,uuid,uuid)'
  ] loop
    if has_function_privilege('anon', public_signature, 'EXECUTE') then
      raise exception 'anon still holds EXECUTE on %', public_signature;
    end if;
    if not has_function_privilege('authenticated', public_signature, 'EXECUTE') then
      raise exception 'authenticated lost EXECUTE on %', public_signature;
    end if;
    if has_function_privilege('service_role', public_signature, 'EXECUTE') then
      raise exception 'service_role should use the internal helper, not %', public_signature;
    end if;
  end loop;

  if has_schema_privilege('authenticated', 'kaspot_internal', 'USAGE') then
    raise exception 'authenticated must not have USAGE on kaspot_internal';
  end if;

  foreach internal_signature in array array[
    'kaspot_internal.is_connected(uuid,uuid)',
    'kaspot_internal.reply_in_conversation(uuid,uuid,uuid)'
  ] loop
    if has_function_privilege('anon', internal_signature, 'EXECUTE')
       or has_function_privilege('authenticated', internal_signature, 'EXECUTE') then
      raise exception 'a client role holds EXECUTE on %', internal_signature;
    end if;
    if not has_function_privilege('service_role', internal_signature, 'EXECUTE') then
      raise exception 'service_role lost the internal helper %', internal_signature;
    end if;
  end loop;

  -- 4b: the two tables must not keep an anon grant after this migration, on
  -- either installation path.
  foreach table_name in array array[
    'public.device_tokens',
    'public.circle_messages'
  ] loop
    if to_regclass(table_name) is not null
       and has_table_privilege('anon', table_name, 'SELECT') then
      raise exception 'anon still holds a table privilege on %', table_name;
    end if;
  end loop;
end $do$;

commit;

-- =============================================================================
-- RECOVERY — THERE IS NO SAFE ROLLBACK TO THE PRE-MIGRATION BODIES
-- =============================================================================
-- This section used to be a rollback recipe. It is not one any more, because
-- the three steps it listed do not restore the previous state — they restore a
-- KNOWN SECURITY REGRESSION and leave the grants looking correct while doing it.
--
-- What actually happens if the old bodies are put back (measured, not assumed):
--
--   * The body of public.is_accepted_connection is `select exists (select 1 from
--     public.connections ...)` — it carries no caller predicate at all. It is
--     SECURITY DEFINER, so RLS on public.connections does not apply.
--   * The grants are unchanged: EXECUTE to authenticated only. Every ACL check
--     still passes. `supabase/tests/rpc_caller_scope.sql` G1/G2/G8 still pass.
--   * An authenticated user who is part of NO pair therefore gets a truthful
--     yes/no answer about any two other users: an authenticated
--     connection-graph oracle. G4 is the check that fails, and only because it
--     asks the question the ACL checks cannot.
--
-- So "revert the bodies, keep the grants" is the one combination that must never
-- be used: it restores the disclosure without any signal that it happened.
-- Reverting the bodies AND revoking EXECUTE is not a recovery either — every RLS
-- policy on profiles, location_sharing, locations, circle_messages and
-- message_reactions calls one of these wrappers, so the product stops serving
-- reads and writes entirely.
--
-- ── Recovery A (preferred): re-apply this file ─────────────────────────────
-- This file is idempotent: create schema if not exists, create or replace for
-- both layers, the grants re-stated by name, and a `do` block that refuses to
-- commit unless the resulting privileges are the design. If the wrappers were
-- replaced by hand, were half-applied, or were damaged by another change,
-- running it again restores the intended state and proves it in one transaction:
--
--   psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/migrations/20261024_rpc_caller_scope.sql
--   psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/rpc_caller_scope.sql
--   psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/install_contract.sql
--
-- ── Recovery B: a legitimate caller is failing with 42501 ──────────────────
-- Forward-fix the CALL SITE, never the primitive. The only sanctioned way to
-- read a connection fact without a caller identity is
-- kaspot_internal.is_connected / kaspot_internal.reply_in_conversation
-- (SECURITY DEFINER, EXECUTE to service_role, no client USAGE on the schema).
-- Server-side TypeScript already reads public.connections directly with the
-- service role and calls neither wrapper. A policy that fails is a policy that
-- is not passing auth.uid() as one of the arguments — fix the argument.
--
-- ── Recovery C: break-glass, only if the product is down ───────────────────
-- If, and only if, a wrapper is provably the outage and A/B cannot be done in
-- time, restore service by making the affected call site not depend on the
-- wrapper (for example, inline the same `exists (... from public.connections)`
-- predicate in that one policy, still scoped by auth.uid()). That keeps the
-- disclosure closed while the wrapper is repaired.
--
-- Reverting the function bodies is NOT part of that procedure. If an operator
-- still concludes they must, the temporary state has to be:
--
--   1. Time-boxed. Written down with an owner, a start time and a maximum
--      duration measured in hours, not days.
--   2. Restricted. Revoke EXECUTE on both wrappers from `authenticated` in the
--      same transaction (`revoke all on function ...`), so no session can probe
--      anything while the identity predicate is absent. Accept that reads and
--      writes guarded by those policies fail; that is an outage, which is
--      visible, instead of a disclosure, which is not.
--   3. Monitored. The detection query below must be run every few minutes and
--      must be empty; `rpc_caller_scope.sql` G4 must be re-run afterwards and
--      must pass. Log every authenticated request that reached the API during
--      the window — that set is the disclosure population.
--   4. Restored. Re-apply this file (Recovery A) and re-run all three suites
--      before the window closes. Ship the product again only after
--      `install_contract.sql` passes.
--
-- ── Detection: is the identity predicate present? ──────────────────────────
-- Run after ANY change to these functions. Empty result = the design is intact.
-- It is structural on purpose: it catches a hand-written replacement, which is
-- how this regression would arrive in practice.
--
--   select p.oid::regprocedure as function_missing_identity_check
--   from pg_proc p
--   join pg_namespace n on n.oid = p.pronamespace
--   where (n.nspname, p.proname) in (
--           ('public', 'is_accepted_connection'),
--           ('public', 'is_valid_reply'))
--     and pg_get_functiondef(p.oid) !~* 'auth\.uid\(\)';
--
-- supabase/tests/install_contract.sql asserts that result is empty, and
-- supabase/tests/rollback_drill.sql proves the detector catches the old bodies
-- and that the old bodies really do answer a non-participant truthfully.
-- =============================================================================
