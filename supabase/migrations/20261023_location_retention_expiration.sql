-- =============================================================================
-- KaSpot — Server-enforced location retention (expiration)
--
-- STATUS: PREPARED, NOT APPLIED.  This migration has deliberately not been run
-- against the linked (production) project.  Apply it only after the retention
-- window below has been approved as a product policy.
--
-- Problem it closes
--   public.locations keeps exactly one row per user (latest location only, no
--   history — that design is preserved here).  Before this migration a row
--   stayed readable by its grantees for as long as it existed, so an owner who
--   stopped reporting without ever pausing or revoking sharing — uninstalled,
--   dead account, force-stopped app — left their exact coordinates exposed
--   indefinitely.
--
-- Chosen semantics (proposed default, needs approval)
--   A location is retained for 24 hours after the server accepted a write for
--   it.  Expiration is stamped by the SERVER clock (now()), never by a
--   client-supplied timestamp, so a skewed or deliberately fake device clock
--   can neither extend a location's lifetime nor make an old fix look fresh:
--     * expires_at  := now() + retention          (set on every insert/update)
--     * recorded_at := least(recorded_at, now())  (future stamps are clamped)
--     * a write whose fix is already older than the retention window is refused
--   Once expires_at has passed the row is invisible to its owner AND to every
--   recipient, because the SELECT policy filters on it.  Physical deletion is
--   handled separately (see "Cleanup" below) — invisibility does not depend on
--   the cleaner ever running.
--
-- What this migration deliberately does NOT do
--   * No location-history table, no extra rows: one row per user still holds only
--     the latest coordinate.
--   * No scheduled job.  pg_cron is AVAILABLE in this project but NOT INSTALLED
--     (pg_available_extensions: pg_cron 1.6.4, installed_version NULL), so
--     enabling it is a separate, explicitly approved deployment step.  The
--     exact commands are documented at the bottom of this file.
--   * No change to who may write or read a location: the authorization checks
--     (own row, enabled sharing grant, accepted connection) are copied verbatim
--     into the replacement SELECT policy and only narrowed by the expiry filter.
--
-- Prerequisites: base schema.sql (public.locations, public.location_sharing,
-- public.is_accepted_connection) already applied.  Safe to re-run.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. The retention window lives in exactly one place.
-- ---------------------------------------------------------------------------
create or replace function public.location_retention_interval()
returns interval
language sql
stable
security invoker
set search_path = ''
as $$
  select interval '24 hours';
$$;

comment on function public.location_retention_interval() is
  'Server-authoritative retention window for a latest-location row. The Flutter '
  'app mirrors this value in lib/utils/location_tracking_config.dart '
  '(LocationTrackingConfig.retention); change both together.';

-- ---------------------------------------------------------------------------
-- 2. Retention columns.
--    received_at records when the server accepted the write (audit + proof that
--    expiry is not derived from client time).  expires_at is the deadline the
--    read policy enforces.
-- ---------------------------------------------------------------------------
alter table public.locations
  add column if not exists received_at timestamptz,
  add column if not exists expires_at timestamptz;

comment on column public.locations.received_at is
  'Server clock time of the last accepted write. Never supplied by the client.';
comment on column public.locations.expires_at is
  'Server clock deadline after which the coordinate is no longer visible to '
  'anyone, including its owner and its grantees.';

-- Backfill from the recorded time, clamped to the server clock: a row that has
-- not been updated for longer than the retention window becomes expired
-- immediately rather than gaining a free extra 24 hours of exposure, and a row
-- whose stored fix time is in the future cannot buy itself more lifetime.
update public.locations
   set received_at = least(coalesce(recorded_at, now()), now()),
       expires_at = least(coalesce(recorded_at, now()), now())
                  + public.location_retention_interval()
 where expires_at is null or received_at is null;

alter table public.locations
  alter column received_at set default now(),
  alter column received_at set not null,
  alter column expires_at set default (now() + public.location_retention_interval()),
  alter column expires_at set not null;

create index if not exists locations_expires_at_idx
  on public.locations (expires_at);

-- ---------------------------------------------------------------------------
-- 3. Stamp expiry and clamp client time on every write.
--    A BEFORE trigger (not a generated column) because generated columns cannot
--    call now(), and a default alone would not apply to UPDATE ... the app
--    upserts with ON CONFLICT DO UPDATE.
-- ---------------------------------------------------------------------------
create or replace function public.enforce_location_retention()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  retention interval := public.location_retention_interval();
begin
  -- Server clock, always. Ignores anything the client tried to send.
  new.received_at := now();

  -- A device clock running ahead must not keep a coordinate looking fresh past
  -- its retention window, so a future fix time is pulled back to now.
  if new.recorded_at is null or new.recorded_at > now() then
    new.recorded_at := now();
  end if;

  -- Refusing an already-expired fix stops an old client from reviving a location
  -- the app's own queue would have discarded.
  if now() - new.recorded_at > retention then
    raise exception
      'KaSpot refused a location fix older than the % retention window',
      retention
      using errcode = '22000';
  end if;

  -- Expiry is measured from the moment the server accepted the write.
  new.expires_at := now() + retention;

  return new;
end;
$$;

drop trigger if exists location_retention_enforcement on public.locations;
create trigger location_retention_enforcement
  before insert or update on public.locations
  for each row execute function public.enforce_location_retention();

-- ---------------------------------------------------------------------------
-- 4. Expired coordinates are invisible to everybody, owner included.
--    Authorization is unchanged: same owner check, same enabled grant, same
--    accepted-connection requirement — only narrowed by the expiry filter.
--    DELETE and the owner's write policies are left untouched on purpose, so a
--    user can always remove their own row (revocation cleanup keeps working).
-- ---------------------------------------------------------------------------
drop policy if exists locations_authorized_read on public.locations;
create policy locations_authorized_read on public.locations for select to authenticated
using (
  expires_at > now()
  and (user_id = (select auth.uid()) or exists (
    select 1 from public.location_sharing s
    where s.owner_id = locations.user_id and s.recipient_id = (select auth.uid())
      and s.is_enabled and public.is_accepted_connection(s.owner_id, s.recipient_id)
  ))
);

-- ---------------------------------------------------------------------------
-- 5. Cleanup strategy: a privileged purge function, ready to be scheduled.
--    Not callable by authenticated/anon — only by the roles that may run the
--    scheduler — so it cannot be used to probe other users' rows.
-- ---------------------------------------------------------------------------
create or replace function public.delete_expired_locations()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  removed integer;
begin
  delete from public.locations where expires_at <= now();
  get diagnostics removed = row_count;
  return removed;
end;
$$;

comment on function public.delete_expired_locations() is
  'Physically removes latest-location rows past their retention deadline. '
  'Read invisibility does not depend on it; it only reclaims storage. Meant to '
  'be run from a scheduler, never from a client.';

revoke all on function public.delete_expired_locations() from public;
revoke all on function public.delete_expired_locations() from anon;
revoke all on function public.delete_expired_locations() from authenticated;
grant execute on function public.delete_expired_locations() to postgres, service_role;

commit;

-- =============================================================================
-- Cleanup scheduling — REQUIRES SEPARATE APPROVAL, INTENTIONALLY NOT RUN HERE
-- =============================================================================
-- pg_cron is available on this project but not installed.  Expiring rows are
-- already invisible through the SELECT policy above, so nothing is exposed while
-- this remains unapplied; only storage is held.
--
-- To enable automatic physical deletion (dashboard: Database → Extensions →
-- pg_cron, or SQL editor):
--
--   create extension if not exists pg_cron with schema extensions;
--   select cron.schedule(
--     'kaspot-location-retention',
--     '15 2 * * *',                                  -- daily, 02:15 UTC
--     $$select public.delete_expired_locations()$$
--   );
--
-- Verify with:
--   select jobid, jobname, schedule, active from cron.job where jobname =
--     'kaspot-location-retention';
--
-- Remove again with:
--   select cron.unschedule('kaspot-location-retention');
--
-- Note that cron jobs run as the scheduling role in the database they are
-- scheduled in; public.delete_expired_locations() is granted to postgres and
-- service_role only.

-- =============================================================================
-- STAGING VERIFICATION — PREPARED, NOT RUN
-- =============================================================================
-- Every step below states the result that makes it a pass. Run it against a
-- STAGING project only; none of this has been executed against the linked
-- project, and no result is claimed here.
--
-- Setup (staging): users A and B, both email-confirmed; an accepted row in
-- public.connections between them; a public.location_sharing row A -> B with
-- is_enabled = true. A third confirmed user C is needed for V3.
--
-- Note on a fresh project: supabase/schema.sql already declares these columns,
-- the policy, the trigger and the purge function, so on a project built from it
-- this migration re-asserts the same definitions and its backfill finds nothing
-- to do. It only adds and backfills on an install created before the retention
-- work. Verify which case the staging project is before interpreting V1.
--
-- V1  A fresh write gets a 24 hour deadline and stays readable.
--     insert into public.locations (user_id, latitude, longitude)
--       values (A, 51.5, -0.12)
--       on conflict (user_id) do update set latitude = excluded.latitude;
--     select expires_at - now() from public.locations where user_id = A;
--     PASS: about 24:00:00. As B, the row is selectable.
--
-- V2  A device clock set in the future cannot buy extra lifetime.
--     update public.locations set recorded_at = now() + interval '10 days'
--       where user_id = A;
--     PASS: recorded_at is pulled back to now() and expires_at stays
--     now() + 24h, not the client value.
--
-- V3  A fix older than the window is refused outright.
--     insert into public.locations (user_id, latitude, longitude, recorded_at)
--       values (C, 51.5, -0.12, now() - interval '25 hours');
--     PASS: error 22000 "KaSpot refused a location fix older than the ...";
--     no row exists for C.
--
-- V4  An expired row is invisible to the owner AND to the grantee.
--     The trigger rewrites expires_at on every UPDATE, so the expiry has to be
--     simulated with the trigger temporarily disabled:
--       alter table public.locations disable trigger location_retention_enforcement;
--       update public.locations set expires_at = now() - interval '1 minute'
--         where user_id = A;
--       alter table public.locations enable trigger location_retention_enforcement;
--     PASS: 0 rows as A, 0 rows as B (grant still enabled).
--     Restore afterwards with the same pattern and expires_at = now() + 1 hour.
--
-- V5  Live rows keep exactly the authorization they had before.
--     set location_sharing.is_enabled = false for A -> B; PASS: 0 rows as B,
--     while expires_at is still in the future. Re-enable -> visible again.
--     Delete the sharing row -> 0 rows.
--     Delete the accepted connection -> 0 rows as B, AND the sharing row is
--     gone as well, because connection_removal_revokes_sharing deletes it.
--     Verify both: select from public.locations and from public.location_sharing.
--
-- V6  The purge removes rows and only rows that are past their deadline.
--     (Simulate expiry exactly as in V4.) Then, as postgres:
--       select public.delete_expired_locations();
--     PASS: first call returns >= 1, an immediate second call returns 0, and
--     select count(*) from public.locations where user_id = A; returns 0.
--     A row with expires_at in the future must survive the call.
--
-- V7  A client cannot run the purge.
--       begin;
--       set local role authenticated;
--       select public.delete_expired_locations();
--       rollback;
--     PASS: 42501 permission denied for function delete_expired_locations.
--
-- V8  Expiry never blocks the owner's own cleanup.
--     As A (trigger enabled, expires_at in the past):
--       delete from public.locations where user_id = A;
--     PASS: 1 row deleted. The revocation path in KaSpotService must keep
--     working for a row nobody can read any more.
--
-- V9  App and database agree on the window.
--     LocationTrackingConfig.retention must equal
--     public.location_retention_interval(), and LocationTrackingConfig
--     .maxQueuedFixAge is that same value. If they drift, the app queues a fix
--     the server will refuse.
--
-- Rollback of this migration (staging only; restore the pre-migration SELECT
-- policy from schema history first):
--   drop trigger if exists location_retention_enforcement on public.locations;
--   drop function if exists public.enforce_location_retention();
--   drop function if exists public.delete_expired_locations();
--   drop index if exists public.locations_expires_at_idx;
--   alter table public.locations
--     drop column if exists received_at,
--     drop column if exists expires_at;
--   drop function if exists public.location_retention_interval();
--
-- Until all of the above passes on staging, this file stays unapplied and
-- lib/utils/privacy_policy_content.dart states no retention window at all.
-- =============================================================================
