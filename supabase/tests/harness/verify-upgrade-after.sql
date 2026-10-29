-- =============================================================================
-- Measured AFTER the upgrade migrations: the same probe must now print
-- false/false, and the retention backfill must have clamped the legacy row
-- instead of handing it a fresh 24 hour window.
-- =============================================================================
do $after$
declare
  outsider     constant uuid := '55555555-5555-4555-8555-555555555555';
  a            constant uuid := '11111111-1111-4111-8111-111111111111';
  b            constant uuid := '22222222-2222-4222-8222-222222222222';
  anon_can     boolean;
  oracle       boolean;
  expires      timestamptz;
  received     timestamptz;
  recorded     timestamptz;
begin
  anon_can := has_function_privilege('anon',
    'public.is_accepted_connection(uuid,uuid)', 'EXECUTE');

  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    json_build_object('role', 'authenticated', 'sub', outsider::text)::text, true);
  oracle := public.is_accepted_connection(a, b);
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '{}', true);

  raise notice 'AFTER: anon_can_execute=%, outsider_reads_foreign_pair=%',
    anon_can, oracle;

  select l.expires_at, l.received_at, l.recorded_at
    into expires, received, recorded
    from public.locations l where l.user_id = a;

  if expires is null then
    raise exception 'BACKFILL: the legacy location row lost its expires_at';
  end if;
  if expires > now() then
    raise exception
      'BACKFILL: a row last written at % was given a fresh window until % — '
      'the clamp did not happen', recorded, expires;
  end if;
  if abs(extract(epoch from (received - recorded))) > 0.001 then
    raise exception
      'BACKFILL: received_at % does not match the clamped recorded_at %',
      received, recorded;
  end if;

  raise notice 'BACKFILL: legacy row is immediately expired (recorded_at=%, expires_at=%)',
    recorded, expires;
end
$after$;
