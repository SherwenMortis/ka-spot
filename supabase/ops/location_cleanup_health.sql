-- =============================================================================
-- KaSpot — is the physical location purge actually running?
--
-- Read-only. Run after the job has had time to fire (15 minutes) and then on a
-- schedule, because "the job is scheduled" and "the job completes" are different
-- facts and only the second one reclaims storage.
--
--   psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
--     -f supabase/ops/location_cleanup_health.sql
--
-- H1  the job exists exactly once and is active
-- H2  its schedule, database and role are the ones that were approved
-- H3  the most recent runs, with status and returned row count
-- H4  failures in the last 24 hours (each one is an operator task, not noise)
-- H5  the backlog: expired-but-still-stored rows. This is the number that proves
--     physical deletion works. It must stay near zero — roughly one purge
--     interval of expired writes, not a number that only grows.
-- H6  the counter-check: rows still inside retention must NOT be deleted.
-- =============================================================================

-- ── H1 / H2 ─────────────────────────────────────────────────────────────────
select jobid,
       jobname,
       schedule,
       command,
       database,
       username,
       active
from cron.job
where jobname = 'kaspot-location-retention-staging';

-- ── H3 ─────────────────────────────────────────────────────────────────────
-- status is 'succeeded' / 'failed'; return_message carries the function's return
-- value on success and the error text on failure. Nothing in this project prunes
-- cron.job_run_details (pg_cron does not clean it automatically), so it grows by
-- one row per run — see the scheduling section of supabase/STAGING.md for the
-- retention decision.
select jobid, runid, status, return_message,
       start_time, end_time,
       (end_time - start_time) as duration
from cron.job_run_details
where jobid in (select jobid from cron.job
                where jobname = 'kaspot-location-retention-staging')
order by start_time desc
limit 10;

-- ── H4 ─────────────────────────────────────────────────────────────────────
-- Any row here means expired coordinates are accumulating and nothing is
-- reclaiming them. Alert on this query returning a count above zero.
select count(*) as failed_runs_last_24h,
       min(start_time) as first_failure,
       max(start_time) as last_failure
from cron.job_run_details d
where d.jobid in (select jobid from cron.job
                  where jobname = 'kaspot-location-retention-staging')
  and d.status = 'failed'
  and d.start_time > now() - interval '24 hours';

-- ── H5 / H6 ────────────────────────────────────────────────────────────────
-- H5 is `expired_still_stored`; H6 is `live_rows`, which must never drop because
-- of the purge. Runs as the invoking role: use the owner role (postgres) or the
-- numbers are filtered by RLS and look smaller than they are.
select count(*) filter (where expires_at <= now())     as expired_still_stored,
       count(*) filter (where expires_at >  now())     as live_rows,
       min(expires_at)                                 as oldest_deadline,
       max(received_at)                                as newest_write
from public.locations;
