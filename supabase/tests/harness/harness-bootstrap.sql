-- =============================================================================
-- LOCAL HARNESS BOOTSTRAP — not part of the product schema, never run on a
-- hosted project. Run as supabase_admin (the image's superuser): the auth and
-- realtime schemas are owned by supabase roles that postgres cannot alter.
-- It provisions the two things a full Supabase stack creates by starting the
-- GoTrue / Realtime services, which are not running here:
--
--   1. auth.uid() at the current definition (the image ships the legacy
--      single-claim version; the suites set request.jwt.claims as JSON).
--   2. realtime.messages, the table the private-channel policies live on.
--
-- Plus one ownership accommodation: `auth.users` is owned by
-- supabase_auth_admin, and the SQL editor path (postgres) creates the
-- on_auth_user_created trigger on it. supautils grants that in production; here
-- the ownership is transferred instead.
--
-- Everything else is the real thing: the supabase/postgres image's roles,
-- default privileges (anon=X on new public functions), extensions and the
-- GoTrue auth schema.
-- =============================================================================

-- ── 1. auth.uid() ────────────────────────────────────────────────────────────
-- Current Supabase definition: the JSON claims first, then the legacy single
-- claim. The image's version only reads the latter, which the suites never set.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

-- ── 2. trigger target ownership ──────────────────────────────────────────────
alter table auth.users owner to postgres;

-- ── 3. realtime.messages ─────────────────────────────────────────────────────
-- Shape taken from the Realtime service's own migration: the columns the app's
-- policies and the SQL suites actually use, with RLS enabled and the table
-- privileges granted to the client roles so that RLS — not a missing GRANT — is
-- the boundary under test.
create table if not exists realtime.messages (
  id          bigint generated always as identity primary key,
  topic       text        not null,
  extension   text        not null,
  payload     jsonb,
  event       text,
  private     boolean     not null default false,
  inserted_at timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- In production the table is owned by supabase_realtime_admin and postgres
-- creates the policies through supautils. supautils is not present here, and
-- CREATE POLICY requires ownership, so ownership moves to postgres. The policy
-- definitions and the RLS evaluation are the same; what this cannot prove is the
-- supautils privilege path itself.
alter table realtime.messages owner to postgres;

alter table realtime.messages enable row level security;

-- The Realtime service grants schema usage to the client roles; without it the
-- policy is never reached and the probe fails with "permission denied for
-- schema realtime" instead of a policy decision.
grant usage on schema realtime to anon, authenticated, service_role;

grant select, insert, update, delete on realtime.messages
  to anon, authenticated, service_role;
