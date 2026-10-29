-- =============================================================================
-- Measured BEFORE the upgrade migrations: the state this repository is trying to
-- leave behind. Not an assertion — a recording. If this ever stops printing
-- true/true, the premise of migration 20261024 has changed and the file needs
-- re-reading before anyone "simplifies" it.
--
-- Expect, on a database built from the previous schema:
--   anon_can_execute          = true   (Supabase default privileges grant anon)
--   outsider_reads_foreign_pair = true (no identity predicate in the body)
-- =============================================================================
do $before$
declare
  outsider constant uuid := '55555555-5555-4555-8555-555555555555';
  a        constant uuid := '11111111-1111-4111-8111-111111111111';
  b        constant uuid := '22222222-2222-4222-8222-222222222222';
  anon_can boolean;
  oracle   boolean;
begin
  anon_can := has_function_privilege('anon',
    'public.is_accepted_connection(uuid,uuid)', 'EXECUTE');

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', outsider::text)::text, true);
  oracle := public.is_accepted_connection(a, b);
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '{}', true);

  raise notice 'BEFORE: anon_can_execute=%, outsider_reads_foreign_pair=%',
    anon_can, oracle;
end
$before$;
