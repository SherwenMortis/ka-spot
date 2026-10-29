-- =============================================================================
-- KaSpot — schedule the physical location purge (STAGING ONLY)
--
-- This file is not a migration. Migrations describe the schema; this describes
-- an operational setting of one environment, and it refuses to run anywhere that
-- has not been marked as staging on purpose.
--
-- What it does: creates one pg_cron job that calls
-- public.delete_expired_locations() every 15 minutes.
--
-- Why 15 minutes, when the retention window is 24 hours: the window decides when
-- a coordinate becomes invisible (the SELECT policy, immediately, no job
-- needed). This job only decides how long an already-invisible row keeps
-- occupying storage. 15 minutes bounds that residue to a quarter hour at a cost
-- of one indexed DELETE over a table that holds at most one row per user; a
-- daily job would leave up to 24 hours of dead rows for no measurable gain.
-- The interval is timezone-independent on purpose: cron.timezone is a
-- postgresql.conf setting (GMT on a Supabase project) and cannot be set per job,
-- so a schedule that does not name an hour cannot be misread.
--
-- Before running, in the STAGING project only:
--   alter database postgres set kaspot.environment = 'staging';
-- and reconnect, so this session sees it. That marker is what the guard below
-- reads; a production database does not have it and this script aborts.
--
-- Prerequisites this script verifies instead of assuming:
--   pg_cron installed in this database (Database → Extensions → pg_cron),
--   public.delete_expired_locations() present,
--   the scheduling role able to execute it,
--   no other active job already running the same purge.
--
-- Run:  psql "$KASPOT_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 \
--         -f supabase/ops/staging_location_cleanup.sql
-- Undo: supabase/ops/staging_location_cleanup_disable.sql
-- Watch: supabase/ops/location_cleanup_health.sql
-- =============================================================================

\set ON_ERROR_STOP on

-- One transaction: if any guard below raises, the schedule statement never
-- commits. Running this file with the SQL editor (which runs statements one by
-- one and would otherwise continue past a failed guard) is therefore still safe.
begin;

do $guard$
declare
  env      text := current_setting('kaspot.environment', true);
  db       text := current_database();
  other    text;
begin
  -- ── 1. This must be the staging database ─────────────────────────────────
  if env is distinct from 'staging' then
    raise exception
      'refusing to schedule: this database is not marked staging (kaspot.environment = %)',
      coalesce(env, '<unset>')
      using hint = 'On the staging project only: alter database postgres set kaspot.environment = ''staging''; then reconnect and re-run. Never set this marker on production.';
  end if;

  -- ── 2. pg_cron must already exist ────────────────────────────────────────
  -- Checked, not created: enabling an extension is its own approved change.
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise exception 'refusing to schedule: pg_cron is not installed in database %', db
      using hint = 'Dashboard → Database → Extensions → pg_cron (staging only), or: create extension if not exists pg_cron with schema extensions;  Then re-run this file.';
  end if;

  if to_regclass('cron.job') is null then
    raise exception 'refusing to schedule: the pg_cron metadata tables are not visible to this role'
      using hint = 'Schedule as the project owner role (postgres). A pooled connection that is not the database owner cannot manage cron jobs.';
  end if;

  -- ── 3. The purge function and its privilege ──────────────────────────────
  if to_regprocedure('public.delete_expired_locations()') is null then
    raise exception 'refusing to schedule: public.delete_expired_locations() does not exist'
      using hint = 'Apply supabase/migrations/20261023_location_retention_expiration.sql first.';
  end if;

  if not has_function_privilege(current_user,
       'public.delete_expired_locations()', 'EXECUTE') then
    raise exception
      'refusing to schedule: the scheduling role % cannot EXECUTE public.delete_expired_locations()',
      current_user
      using hint = 'The function is granted to postgres and service_role only, by design. Schedule as postgres, or grant it deliberately — do not grant it to a client role.';
  end if;

  -- ── 4. Do not schedule the same purge twice ─────────────────────────────
  -- Two jobs deleting the same rows is not dangerous (the delete is idempotent),
  -- but it hides which schedule is authoritative, so it is refused.
  select string_agg(j.jobname, ', ' order by j.jobname) into other
  from cron.job j
  where j.jobname <> 'kaspot-location-retention-staging'
    and j.command ilike '%delete_expired_locations%';

  if other is not null then
    raise exception 'refusing to schedule: another cron job already runs the purge: %', other
      using hint = format('Unschedule it first: select cron.unschedule(%L);', split_part(other, ', ', 1));
  end if;

  -- ── 5. The database this job is bound to ─────────────────────────────────
  -- schedule_in_database records the target database in cron.job, so the job
  -- cannot be carried into another database of the same cluster, and the same
  -- file on another project binds to that project's database.
  if db is distinct from 'postgres' then
    raise exception 'unexpected database name %, expected postgres', db
      using hint = 'The Supabase project database is named postgres. A different name means this is not the project you think it is.';
  end if;
end
$guard$;

-- Idempotent: replace a job of the same name rather than stacking a second one.
select cron.unschedule('kaspot-location-retention-staging')
where exists (
  select 1 from cron.job where jobname = 'kaspot-location-retention-staging'
);

select cron.schedule_in_database(
  'kaspot-location-retention-staging',        -- job name, unique per database
  '*/15 * * * *',                             -- every 15 minutes, cron.timezone (GMT)
  'select public.delete_expired_locations();',-- one statement, no client input
  current_database(),                         -- bound to THIS database
  -- NULL, not 'postgres': pg_cron refuses an explicit user name from a
  -- non-superuser with "must be superuser to create a job for another role",
  -- even when the name is the current one. NULL records the role that created
  -- the job, which is the role this script already verified can execute the
  -- purge (cron.job.username then reads back as that role).
  NULL
);

-- Verification. All four columns must look right before this counts as done,
-- and the job must run as the role that just created it.
select jobid,
       jobname,
       schedule,
       command,
       database,
       username,
       active,
       (username = current_user) as runs_as_me
from cron.job
where jobname = 'kaspot-location-retention-staging';

commit;
