-- A location row that predates the retention columns, written before the
-- retention migration runs. recorded_at is 30 days old, so the migration's
-- backfill must clamp it and mark it immediately expired instead of granting it
-- a fresh 24 hour window.
insert into public.locations (user_id, latitude, longitude, recorded_at)
values ('11111111-1111-4111-8111-111111111111', 51.5, -0.12, now() - interval '30 days')
on conflict (user_id) do nothing;
