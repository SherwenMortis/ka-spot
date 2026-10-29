-- =============================================================================
-- KaSpot — installation contract: structure, privileges, and the identity guard
--
-- One file, two installation paths. Run it AFTER the path you chose:
--
--   CLEAN INSTALL (new database)
--     psql "$URL" -v ON_ERROR_STOP=1 -f supabase/schema.sql
--     for each file in supabase/migrations/ in filename order:
--       psql "$URL" -v ON_ERROR_STOP=1 -f <file>
--     psql "$URL" -v ON_ERROR_STOP=1 -f supabase/tests/install_contract.sql
--
--   UPGRADE PATH (database created before the retention work / before 20261023)
--     psql "$STAGING_URL" -v ON_ERROR_STOP=1 -f <each migration in order>
--     psql "$STAGING_URL" -v ON_ERROR_STOP=1 -f supabase/tests/install_contract.sql
--
-- Both must produce the same passing result. That is the point of this file: the
-- two paths may be different procedures, never different end states. It also
-- pins the parts of `supabase/schema.sql` that a migration first introduced —
-- without them a clean install has no private-channel authorization at all.
--
-- Read-only: no fixtures, no grants, no DDL. Safe on a staging project, safe to
-- run repeatedly. Every check runs, then all failures are raised together, so a
-- single run reports everything instead of stopping at the first problem.
--
-- C1  the 11 app tables exist and have RLS enabled
-- C2  columns introduced by a migration are present with their final nullability
-- C3  every function exists, exactly once (no duplicate overloads)
-- C4  every trigger exists, exactly once (no duplicate retention/cleanup triggers)
-- C5  every policy exists, exactly once — including both private-channel policies
-- C6  anon and PUBLIC hold nothing; authenticated holds only its six RPCs
-- C7  kaspot_internal is unreachable from a client role
-- C8  the public wrappers still carry an identity predicate (rollback detector)
-- C9  the purge function stays unavailable to client roles
-- =============================================================================

do $contract$
declare
  failures text[] := array[]::text[];

  v_tbl      text;
  v_col      text;
  v_nullable text;
  v_sch      text;
  v_pol      text;
  v_trg      text;
  v_sig      text;
  v_n        integer;
  v_oid      oid;

  app_tables constant text[] := array[
    'public.profiles', 'public.connection_requests', 'public.connections',
    'public.circle_relationships', 'public.location_sharing', 'public.locations',
    'public.saved_places', 'public.notification_preferences',
    'public.device_tokens', 'public.circle_messages', 'public.message_reactions'
  ];

  -- Client-facing RPCs: EXECUTE for `authenticated` only. PUBLIC and anon must
  -- hold nothing, because Supabase's default privileges grant new functions in
  -- `public` to both directly — `revoke ... from public` never removed those.
  client_rpcs constant text[] := array[
    'public.is_accepted_connection(uuid,uuid)',
    'public.is_valid_reply(uuid,uuid,uuid)',
    'public.lookup_user_by_code(text)',
    'public.upsert_reaction(uuid,text)',
    'public.chat_channel_users(text)',
    'public.is_chat_channel_participant(text)'
  ];

  internal_rpcs constant text[] := array[
    'kaspot_internal.is_connected(uuid,uuid)',
    'kaspot_internal.reply_in_conversation(uuid,uuid,uuid)'
  ];
begin
  -- ── C1: tables and RLS ───────────────────────────────────────────────────
  foreach v_tbl in array app_tables loop
    if to_regclass(v_tbl) is null then
      failures := failures || format('C1 missing table %s', v_tbl);
    elsif not (select c.relrowsecurity from pg_class c where c.oid = to_regclass(v_tbl)) then
      failures := failures || format('C1 RLS is not enabled on %s', v_tbl);
    end if;
  end loop;

  -- ── C2: columns a migration introduced ───────────────────────────────────
  -- Exactly what an upgrade that skipped a migration would be missing.
  for v_tbl, v_col, v_nullable in
    select * from (values
      ('locations',      'received_at',          'NO'),
      ('locations',      'expires_at',           'NO'),
      ('device_tokens',  'supports_data_only',   'NO'),
      ('profiles',       'registered_at',        'YES'),
      ('circle_messages','read_at',              'YES'),
      ('circle_messages','reply_to_message_id',  'YES'),
      ('message_reactions','emoji',              'NO')
    ) AS v(t, c, n)
  loop
    if not exists (
      select 1 from information_schema.columns
      where table_schema = 'public' and table_name = v_tbl and column_name = v_col
    ) then
      failures := failures || format('C2 missing column public.%s.%s', v_tbl, v_col);
    elsif (
      select is_nullable from information_schema.columns
      where table_schema = 'public' and table_name = v_tbl and column_name = v_col
    ) <> v_nullable then
      failures := failures || format(
        'C2 public.%s.%s should be %s', v_tbl, v_col,
        case when v_nullable = 'NO' then 'NOT NULL' else 'nullable' end);
    end if;
  end loop;

  if to_regclass('public.locations_expires_at_idx') is null then
    -- format(), not a bare literal: `text[] || 'x'` resolves to array || array
    -- and raises "Array value must start with {" instead of recording the failure.
    failures := failures || format('%s', 'C2 missing index public.locations_expires_at_idx');
  end if;

  -- ── C3: functions exist exactly once ─────────────────────────────────────
  -- `create or replace` with a different argument list does not replace, it
  -- overloads. A duplicated helper is invisible to a call site and to a reader.
  foreach v_sig in array array[
    'public.location_retention_interval()',
    'public.is_accepted_connection(uuid,uuid)',
    'public.is_valid_reply(uuid,uuid,uuid)',
    'public.lookup_user_by_code(text)',
    'public.upsert_reaction(uuid,text)',
    'public.chat_channel_users(text)',
    'public.is_chat_channel_participant(text)',
    'public.delete_expired_locations()',
    'public.enforce_location_retention()',
    'public.guard_request_update()',
    'public.create_connection_after_accept()',
    'public.cleanup_sharing_after_connection_removal()',
    'public.guard_sharing_upsert()',
    'public.remove_unshared_latest_location()',
    'public.handle_new_user()',
    'kaspot_internal.is_connected(uuid,uuid)',
    'kaspot_internal.reply_in_conversation(uuid,uuid,uuid)'
  ] loop
    if to_regprocedure(v_sig) is null then
      failures := failures || format('C3 missing function %s', v_sig);
      continue;
    end if;

    select count(*) into v_n
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = split_part(v_sig, '.', 1)
      and p.proname = split_part(split_part(v_sig, '.', 2), '(', 1);

    if v_n <> 1 then
      failures := failures || format(
        'C3 %s exists %s times (expected 1: a duplicate overload changes which '
        'version a policy actually calls)', v_sig, v_n);
    end if;
  end loop;

  -- ── C4: triggers exist exactly once ──────────────────────────────────────
  -- The retention and sharing-cleanup triggers are created with DROP IF EXISTS
  -- in two different files. Re-created under another name they would fire twice,
  -- and `drop trigger if exists <name>` would not notice.
  for v_tbl, v_trg in
    select * from (values
      ('public.locations',          'location_retention_enforcement'),
      ('public.connection_requests','connection_request_update_guard'),
      ('public.connection_requests','accepted_request_creates_connection'),
      ('public.connections',        'connection_removal_revokes_sharing'),
      ('public.location_sharing',   'location_sharing_guard'),
      ('public.location_sharing',   'sharing_revocation_clears_location'),
      ('auth.users',                'on_auth_user_created')
    ) AS v(t, g)
  loop
    if to_regclass(v_tbl) is null then
      continue; -- reported by C1, or not a table this project owns
    end if;
    select count(*) into v_n
    from pg_trigger t
    where t.tgrelid = to_regclass(v_tbl)::oid
      and not t.tgisinternal
      and t.tgname = v_trg;
    if v_n <> 1 then
      failures := failures || format(
        'C4 trigger %s on %s exists %s times (expected 1)',
        v_trg, v_tbl, v_n);
    end if;
  end loop;

  v_oid := to_regprocedure('public.enforce_location_retention()')::oid;
  if v_oid is not null then
    select count(*) into v_n
    from pg_trigger t
    where t.tgrelid = 'public.locations'::regclass
      and not t.tgisinternal
      and t.tgfoid = v_oid;
    if v_n <> 1 then
      failures := failures || format(
        'C4 public.locations has %s triggers running enforce_location_retention '
        '(expected 1)', v_n);
    end if;
  end if;

  -- ── C5: policies exist exactly once, including the private channel ───────
  for v_sch, v_tbl, v_pol in
    select * from (values
      ('public',   'profiles',              'profile_self_or_connection_read'),
      ('public',   'profiles',              'profile_self_insert'),
      ('public',   'profiles',              'profile_self_update'),
      ('public',   'connection_requests',   'requests_participant_read'),
      ('public',   'connection_requests',   'requests_requester_create'),
      ('public',   'connection_requests',   'requests_participant_transition'),
      ('public',   'connections',           'connections_participant_read'),
      ('public',   'connections',           'connections_participant_remove'),
      ('public',   'location_sharing',      'sharing_owner_or_recipient_read'),
      ('public',   'location_sharing',      'sharing_owner_create'),
      ('public',   'location_sharing',      'sharing_owner_update'),
      ('public',   'location_sharing',      'sharing_owner_delete'),
      ('public',   'locations',             'locations_owner_upsert'),
      ('public',   'locations',             'locations_owner_refresh'),
      ('public',   'locations',             'locations_authorized_read'),
      ('public',   'locations',             'locations_owner_delete'),
      ('public',   'saved_places',          'saved_places_owner_all'),
      ('public',   'notification_preferences','notification_preferences_owner_all'),
      ('public',   'circle_relationships',  'circle_relationships_owner'),
      ('public',   'device_tokens',         'device_tokens_owner'),
      ('public',   'circle_messages',       'circle_messages_participant_read'),
      ('public',   'circle_messages',       'circle_messages_sender_create'),
      ('public',   'circle_messages',       'circle_messages_recipient_mark_read'),
      ('public',   'message_reactions',     'message_reactions_participant_read'),
      ('public',   'message_reactions',     'message_reactions_self_create'),
      ('public',   'message_reactions',     'message_reactions_self_update'),
      ('public',   'message_reactions',     'message_reactions_self_delete'),
      ('realtime', 'messages',              'chat_channel_participant_receive'),
      ('realtime', 'messages',              'chat_channel_participant_publish')
    ) AS v(s, t, p)
  loop
    select count(*) into v_n
    from pg_policies
    where schemaname = v_sch and tablename = v_tbl and policyname = v_pol;
    if v_n <> 1 then
      failures := failures || format(
        'C5 policy %s on %s.%s exists %s times (expected 1)',
        v_pol, v_sch, v_tbl, v_n);
    end if;
  end loop;

  -- RLS with no policy is a silently dead table. This is the check that would
  -- have caught a clean install built from schema.sql alone: the private
  -- channel's two policies simply were not there.
  foreach v_tbl in array app_tables loop
    if to_regclass(v_tbl) is null then
      continue;
    end if;
    select count(*) into v_n
    from pg_policies
    where schemaname = 'public' and tablename = split_part(v_tbl, '.', 2);
    if v_n = 0 then
      failures := failures || format('C5 %s has RLS enabled but no policy', v_tbl);
    end if;
  end loop;

  -- ── C6: client RPC privileges ────────────────────────────────────────────
  foreach v_sig in array client_rpcs loop
    v_oid := to_regprocedure(v_sig)::oid;
    if v_oid is null then
      continue; -- C3 already reported it
    end if;

    if has_function_privilege('anon', v_oid, 'EXECUTE') then
      failures := failures || format('C6 anon can EXECUTE %s', v_sig);
    end if;
    if not has_function_privilege('authenticated', v_oid, 'EXECUTE') then
      failures := failures || format('C6 authenticated cannot EXECUTE %s', v_sig);
    end if;

    -- PUBLIC is not a role, so it is read from the ACL itself.
    -- acldefault('f', owner) is the state in which PUBLIC holds EXECUTE.
    select count(*) into v_n
    from pg_proc p
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
    where p.oid = v_oid
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE';
    if v_n > 0 then
      failures := failures || format('C6 PUBLIC can EXECUTE %s', v_sig);
    end if;
  end loop;

  -- The wrappers must not be callable by the service role either: with no
  -- caller identity they answer `false`, which is a lie, so trusted server code
  -- has to use the internal helpers.
  foreach v_sig in array array[
    'public.is_accepted_connection(uuid,uuid)',
    'public.is_valid_reply(uuid,uuid,uuid)'
  ] loop
    v_oid := to_regprocedure(v_sig)::oid;
    if v_oid is not null and has_function_privilege('service_role', v_oid, 'EXECUTE') then
      failures := failures || format('C6 service_role can EXECUTE %s', v_sig);
    end if;
  end loop;

  -- ── C7: kaspot_internal is unreachable from a client role ────────────────
  foreach v_sch in array array['anon', 'authenticated'] loop
    if has_schema_privilege(v_sch, 'kaspot_internal', 'USAGE') then
      failures := failures || format('C7 %s has USAGE on kaspot_internal', v_sch);
    end if;
  end loop;

  foreach v_sig in array internal_rpcs loop
    v_oid := to_regprocedure(v_sig)::oid;
    if v_oid is null then
      continue;
    end if;
    if has_function_privilege('anon', v_oid, 'EXECUTE')
       or has_function_privilege('authenticated', v_oid, 'EXECUTE') then
      failures := failures || format('C7 a client role can EXECUTE %s', v_sig);
    end if;
    if not has_function_privilege('service_role', v_oid, 'EXECUTE') then
      failures := failures || format('C7 service_role cannot EXECUTE %s', v_sig);
    end if;
  end loop;

  -- ── C8: the identity guard is present (rollback detector) ────────────────
  -- Structural on purpose: this is what catches a hand-written or reverted body.
  -- A wrapper without `auth.uid()` truthfully answers any signed-in caller.
  foreach v_sig in array array[
    'public.is_accepted_connection(uuid,uuid)',
    'public.is_valid_reply(uuid,uuid,uuid)'
  ] loop
    v_oid := to_regprocedure(v_sig)::oid;
    if v_oid is null then
      continue;
    end if;

    select count(*) into v_n
    from pg_proc p
    where p.oid = v_oid
      and pg_get_functiondef(p.oid) !~* 'auth\.uid\(\)';
    if v_n > 0 then
      failures := failures || format(
        'C8 %s has no auth.uid() identity predicate, so any signed-in caller '
        'gets a truthful answer about a pair it is not part of (see the '
        'RECOVERY section of migration 20261024)', v_sig);
    end if;

    select count(*) into v_n
    from pg_proc p
    where p.oid = v_oid
      and (not p.prosecdef
           or array_to_string(coalesce(p.proconfig, '{}'), ',') not like '%search_path=%');
    if v_n > 0 then
      failures := failures || format(
        'C8 %s is not SECURITY DEFINER with a pinned search_path', v_sig);
    end if;
  end loop;

  -- ── C9: the purge stays off the client surface ───────────────────────────
  v_oid := to_regprocedure('public.delete_expired_locations()')::oid;
  if v_oid is null then
    failures := failures || format('%s', 'C9 missing function public.delete_expired_locations()');
  else
    if has_function_privilege('anon', v_oid, 'EXECUTE') then
      failures := failures || format('%s', 'C9 anon can EXECUTE delete_expired_locations()');
    end if;
    if has_function_privilege('authenticated', v_oid, 'EXECUTE') then
      failures := failures || format('%s', 'C9 authenticated can EXECUTE delete_expired_locations()');
    end if;
    -- The scheduler runs as the database owner, so it must keep this.
    if not has_function_privilege('postgres', v_oid, 'EXECUTE') then
      failures := failures || format('%s', 'C9 postgres cannot EXECUTE delete_expired_locations()');
    end if;
  end if;

  -- ── anon must hold no table privilege either ─────────────────────────────
  foreach v_tbl in array app_tables loop
    if to_regclass(v_tbl) is null then
      continue;
    end if;
    if has_table_privilege('anon', v_tbl, 'SELECT')
       or has_table_privilege('anon', v_tbl, 'INSERT')
       or has_table_privilege('anon', v_tbl, 'UPDATE')
       or has_table_privilege('anon', v_tbl, 'DELETE') then
      failures := failures || format('C6 anon holds a table privilege on %s', v_tbl);
    end if;
  end loop;

  -- ── verdict ──────────────────────────────────────────────────────────────
  if array_length(failures, 1) > 0 then
    raise exception E'installation contract FAILED (% issue(s)):\n  %',
      array_length(failures, 1), array_to_string(failures, E'\n  ')
      using hint = 'A database built from schema.sql and one upgraded by the migrations must reach the same state. Check which path produced this database against supabase/STAGING.md section 3.';
  end if;

  raise notice 'install_contract: all checks passed (11 tables, 17 functions, 7 triggers, 29 policies, ACLs, identity guard)';
end
$contract$;
