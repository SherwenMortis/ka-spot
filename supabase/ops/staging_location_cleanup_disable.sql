-- =============================================================================
-- KaSpot — remove the physical location purge job (STAGING ONLY)
--
-- Safe to run whether or not the job exists. Does not touch the retention
-- function, the columns, or the policies: an unscheduled purge only means
-- expired rows stay on disk (they are already invisible to every reader, see the
-- SELECT policy in 20261023_location_retention_expiration.sql).
--
--   psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/ops/staging_location_cleanup_disable.sql
-- =============================================================================

\set ON_ERROR_STOP on

do $disable$
declare
  removed boolean := false;
begin
  if to_regclass('cron.job') is null then
    raise notice 'cron.job is not present in this database: nothing to unschedule.';
    return;
  end if;

  if exists (select 1 from cron.job where jobname = 'kaspot-location-retention-staging') then
    removed := cron.unschedule('kaspot-location-retention-staging');
    raise notice 'unscheduled kaspot-location-retention-staging: %', removed;
  else
    raise notice 'kaspot-location-retention-staging is not scheduled: nothing to do.';
  end if;
end
$disable$;

-- Must return zero rows. One row here means the job is still scheduled.
select jobid, jobname, schedule, database, username, active
from cron.job
where jobname = 'kaspot-location-retention-staging';
