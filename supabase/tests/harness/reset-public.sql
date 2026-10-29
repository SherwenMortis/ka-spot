-- Reset `public` to an empty schema while keeping the Supabase default
-- privileges for that schema. Dropping a schema also drops its pg_default_acl
-- rows, so they are re-created here exactly as the platform image has them
-- (verified earlier: postgres|public|f = {postgres=X,anon=X,authenticated=X,service_role=X}).
drop schema if exists public cascade;
create schema public;

grant usage on schema public to anon, authenticated, service_role;

alter default privileges for role postgres in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant all on sequences to anon, authenticated, service_role;
alter default privileges for role postgres in schema public
  grant execute on functions to anon, authenticated, service_role;

-- The fixture accounts live in auth.users, which survives a public reset. Without
-- this, the next fixtures file would hit `on conflict do nothing` and the
-- handle_new_user trigger would never run, leaving profiles empty.
delete from auth.users where id in (
  '11111111-1111-4111-8111-111111111111',
  '22222222-2222-4222-8222-222222222222',
  '33333333-3333-4333-8333-333333333333',
  '44444444-4444-4444-8444-444444444444',
  '55555555-5555-4555-8555-555555555555');
