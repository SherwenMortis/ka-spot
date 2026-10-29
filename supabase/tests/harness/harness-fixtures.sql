-- =============================================================================
-- LOCAL HARNESS FIXTURES — five disposable users, two accepted connections, one
-- message. Matches the shape the SQL suites require (see supabase/STAGING.md §2.4):
--
--   u1 <-> u2   accepted connection, the "first" pair every suite picks
--   u3 <-> u4   a second, disjoint pair
--   u5          no connections at all (the outsider)
--
-- Rows are inserted as the database owner, so RLS is bypassed for the fixture
-- itself; the suites then switch to anon/authenticated to test the boundary.
-- Inserting into auth.users exercises public.handle_new_user(), which is how a
-- real signup provisions the profile row.
-- =============================================================================

insert into auth.users (id, email, raw_user_meta_data)
values
  ('11111111-1111-4111-8111-111111111111', 'u1@harness.invalid', '{"display_name":"User One"}'),
  ('22222222-2222-4222-8222-222222222222', 'u2@harness.invalid', '{"display_name":"User Two"}'),
  ('33333333-3333-4333-8333-333333333333', 'u3@harness.invalid', '{"display_name":"User Three"}'),
  ('44444444-4444-4444-8444-444444444444', 'u4@harness.invalid', '{"display_name":"User Four"}'),
  ('55555555-5555-4555-8555-555555555555', 'u5@harness.invalid', '{"display_name":"User Five"}')
on conflict (id) do nothing;

insert into public.connections (user_a_id, user_b_id)
values
  ('11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222'),
  ('33333333-3333-4333-8333-333333333333', '44444444-4444-4444-8444-444444444444')
on conflict do nothing;

insert into public.circle_messages (sender_id, recipient_id, content)
select '11111111-1111-4111-8111-111111111111',
       '22222222-2222-4222-8222-222222222222',
       'harness fixture message'
where not exists (
  select 1 from public.circle_messages
  where sender_id = '11111111-1111-4111-8111-111111111111'
    and recipient_id = '22222222-2222-4222-8222-222222222222'
);
