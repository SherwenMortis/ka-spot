-- =============================================================================
-- KaSpot — Location retention (expiration) verification
--
-- RUN THIS ONLY AFTER
-- supabase/migrations/20261023_location_retention_expiration.sql has been
-- applied, and only in a development or staging project. It has NOT been run
-- against production as part of preparing this change — the linked Ka-Spot
-- project is the only environment that exists, so these checks are prepared for
-- review and were not executed here.
--
--   psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/tests/location_retention.sql
--
-- (`supabase db query` does not exist in CLI 2.120.0 — `supabase db` only
--  offers diff/dump/push/pull/reset/start — so psql is the supported way to run
--  a SQL file against a linked project. Use the staging connection string from
--  the dashboard: Database → Connection string.)
--
-- Everything happens inside one transaction that is rolled back at the end, so
-- no fixture row, grant change, expiry change or purge persists. Real user ids
-- are used because the sharing grants and is_accepted_connection() must be
-- genuine for the authorization half of the policy to be tested at all.
--
-- "Time passing" cannot be simulated by waiting: now() is the transaction
-- timestamp in Postgres, so the deadline is moved by updating expires_at
-- directly. The retention trigger rewrites expires_at on every update, so the
-- trigger is disabled around exactly those two steps and re-enabled immediately
-- afterwards. That is the only place any trigger is bypassed, and only to move a
-- deadline — never to make a client-supplied timestamp look legitimate.
--
-- Covers: the server stamps expires_at on a normal write; an unexpired location
-- stays visible to its owner and to an authorized recipient; an expired one is
-- invisible to both; a user with no enabled incoming grant learns nothing; the
-- purge RPC is not client-callable; a fresh write revives visibility with a new
-- deadline; a future-dated client clock cannot extend a location's lifetime; an
-- over-age fix is refused; revoking the last grant still removes access; one row
-- per user (no history) is preserved; the purge deletes exactly the expired rows
-- and leaves a row still inside retention alone.
-- =============================================================================

begin;

do $do$
declare
  orig_role      text;
  owner          uuid;
  recipient      uuid;
  outsider       uuid;
  retention      interval;
  expires        timestamptz;
  rec_at         timestamptz;
  recv_at        timestamptz;
  removed        integer;
  expired_count  integer;
  dupes          integer;
  visible        boolean;
  raised         boolean;
begin
  orig_role := current_user;
  retention := public.location_retention_interval();

  select c.user_a_id, c.user_b_id into owner, recipient
    from public.connections c limit 1;
  if owner is null then
    raise exception
      'NO CONNECTION ROW: retention behavior cannot be verified without a real accepted pair';
  end if;

  -- Somebody who may not read anyone else's location: no enabled grant points at
  -- them, and they are neither side of the fixture pair.
  select u.id into outsider from auth.users u
  where u.id <> owner and u.id <> recipient
    and not exists (select 1 from public.location_sharing s
                    where s.recipient_id = u.id and s.is_enabled)
  limit 1;
  if outsider is null then
    raise exception 'NO UNRELATED USER: the outsider case cannot be verified';
  end if;

  -- Fixture writes run as the owning role, but guard_sharing_upsert() now asks
  -- public.is_accepted_connection(), which requires a real identity: a caller
  -- with no JWT gets false and the grant is refused. Acting as the owner keeps
  -- the trigger's rule satisfied, exactly as the app does it.
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', owner::text)::text, true);

  -- ── 1. Fixture: an enabled grant plus a fresh location written through the
  -- normal insert path, so the retention trigger does all the stamping.
  insert into public.location_sharing (owner_id, recipient_id, is_enabled)
    values (owner, recipient, true)
    on conflict (owner_id, recipient_id) do update set is_enabled = true;

  insert into public.locations (user_id, latitude, longitude, recorded_at)
    values (owner, 10.3, 123.9, now())
    on conflict (user_id) do update
      set latitude = excluded.latitude,
          longitude = excluded.longitude,
          recorded_at = excluded.recorded_at;

  select l.expires_at, l.recorded_at, l.received_at
    into expires, rec_at, recv_at
    from public.locations l where l.user_id = owner;
  if expires is null then
    raise exception 'FAILED: the retention trigger did not stamp expires_at';
  end if;
  if recv_at is null then
    raise exception 'FAILED: the retention trigger did not stamp received_at';
  end if;
  if abs(extract(epoch from (expires - (now() + retention)))) > 60 then
    raise exception
      'FAILED: expires_at is not one retention window from the server clock: %', expires;
  end if;
  if rec_at > now() then
    raise exception 'FAILED: a write accepted a fix time in the future: %', rec_at;
  end if;

  -- ── 2. Owner and authorized recipient can both read an unexpired location.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', owner::text)::text, true);
  visible := exists (select 1 from public.locations where user_id = owner);
  if not visible then
    raise exception 'FAILED: the owner cannot read their own unexpired location';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', recipient::text)::text, true);
  visible := exists (select 1 from public.locations where user_id = owner);
  if not visible then
    raise exception 'FAILED: an authorized recipient cannot read an unexpired location';
  end if;

  -- ── 3. An unrelated authenticated user reads the fixture row not at all.
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', outsider::text)::text, true);
  visible := exists (select 1 from public.locations where user_id = owner);
  if visible then
    raise exception 'FAILED: an unrelated user can read someone else''s location';
  end if;
  perform set_config('role', orig_role, true);
  -- Restore the owner identity for the fixture writes that follow.
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', owner::text)::text, true);

  -- ── 4. The purge RPC is not reachable from a client role.
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', outsider::text)::text, true);
  raised := false;
  begin
    perform public.delete_expired_locations();
  exception when insufficient_privilege then
    raised := true;
  end;
  if not raised then
    raise exception 'FAILED: authenticated can execute delete_expired_locations()';
  end if;
  perform set_config('role', orig_role, true);
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', owner::text)::text, true);

  -- ── 5. Past the deadline the coordinate is invisible to owner AND recipient,
  -- purely through the policy — no cleaner has to have run.
  alter table public.locations disable trigger location_retention_enforcement;
  update public.locations
     set expires_at = now() - interval '1 minute'
   where user_id = owner;
  alter table public.locations enable trigger location_retention_enforcement;

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', owner::text)::text, true);
  visible := exists (select 1 from public.locations where user_id = owner);
  if visible then
    raise exception 'FAILED: the owner still sees an expired location';
  end if;

  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', recipient::text)::text, true);
  visible := exists (select 1 from public.locations where user_id = owner);
  if visible then
    raise exception 'FAILED: a recipient still sees an expired location';
  end if;
  perform set_config('role', orig_role, true);
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', owner::text)::text, true);

  -- ── 6. A new accepted write revives visibility with a freshly stamped
  -- deadline, and the server clock owns that deadline.
  insert into public.locations (user_id, latitude, longitude, recorded_at)
    values (owner, 10.4, 123.9, now())
    on conflict (user_id) do update
      set latitude = excluded.latitude, recorded_at = excluded.recorded_at;
  select l.expires_at into expires from public.locations l where l.user_id = owner;
  if expires <= now() then
    raise exception 'FAILED: a fresh write did not push expires_at into the future';
  end if;

  -- ── 7. Clock integrity: a future recorded_at is clamped to the server clock,
  -- so it cannot buy extra lifetime.
  insert into public.locations (user_id, latitude, longitude, recorded_at)
    values (owner, 10.5, 123.9, now() + interval '5 days')
    on conflict (user_id) do update
      set latitude = excluded.latitude, recorded_at = excluded.recorded_at;
  select l.recorded_at, l.expires_at into rec_at, expires
    from public.locations l where l.user_id = owner;
  if rec_at > now() then
    raise exception 'FAILED: a future client timestamp was accepted unclamped: %', rec_at;
  end if;
  if abs(extract(epoch from (expires - (now() + retention)))) > 60 then
    raise exception 'FAILED: expiry drifted from the server clock: %', expires;
  end if;

  -- ── 8. A fix older than the retention window is refused rather than shown as
  -- current — this is what stops an endless offline queue from lying.
  raised := false;
  begin
    insert into public.locations (user_id, latitude, longitude, recorded_at)
      values (owner, 10.6, 123.9, now() - interval '30 days')
      on conflict (user_id) do update
        set latitude = excluded.latitude, recorded_at = excluded.recorded_at;
  exception when others then
    raised := true;
  end;
  if not raised then
    raise exception 'FAILED: a 30-day-old fix was accepted as if it were current';
  end if;

  -- ── 9. Revoking access still removes the row outright, exactly as before this
  -- migration. Every grant of this owner goes off so the "last grant" condition
  -- is genuinely met (production data may hold other enabled grants).
  update public.location_sharing set is_enabled = false where owner_id = owner;
  if exists (select 1 from public.locations where user_id = owner) then
    raise exception 'FAILED: revoking the final grant left the location row in place';
  end if;

  -- ── 10. Latest-location-only is preserved: one row per user, never history.
  select count(*) into dupes from (
    select user_id from public.locations group by user_id having count(*) > 1
  ) d;
  if dupes <> 0 then
    raise exception 'FAILED: % user(s) have more than one stored location', dupes;
  end if;

  -- ── 11. The purge removes exactly the expired rows and keeps a live one.
  -- The owner's fixture row is written again (grant re-enabled first, so the
  -- write policies stay satisfied), and an unrelated live row is expired to give
  -- the purge something to remove.
  insert into public.location_sharing (owner_id, recipient_id, is_enabled)
    values (owner, recipient, true)
    on conflict (owner_id, recipient_id) do update set is_enabled = true;
  insert into public.locations (user_id, latitude, longitude, recorded_at)
    values (owner, 10.7, 123.9, now())
    on conflict (user_id) do update set latitude = excluded.latitude;
  insert into public.locations (user_id, latitude, longitude, recorded_at)
    values (outsider, 10.8, 123.9, now())
    on conflict (user_id) do update set latitude = excluded.latitude;

  alter table public.locations disable trigger location_retention_enforcement;
  update public.locations
     set expires_at = now() - interval '1 second'
   where user_id = outsider;
  alter table public.locations enable trigger location_retention_enforcement;

  select count(*) into expired_count from public.locations where expires_at <= now();
  if expired_count = 0 then
    raise exception 'SETUP: no expired row available to verify the purge';
  end if;

  removed := public.delete_expired_locations();
  if removed <> expired_count then
    raise exception 'FAILED: purge removed % rows, expected %', removed, expired_count;
  end if;
  if exists (select 1 from public.locations where expires_at <= now()) then
    raise exception 'FAILED: expired rows survived the purge';
  end if;
  if not exists (select 1 from public.locations where user_id = owner) then
    raise exception 'FAILED: the purge deleted a row that was still within retention';
  end if;

  raise notice 'location retention checks passed (retention = %)', retention;
end
$do$;

-- Nothing in this file is meant to persist.
rollback;
