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
