-- KaSpot v1. Latest location only; no historical location trail, and the one
-- stored coordinate expires on its own after the retention window below.
-- Apply using the Supabase SQL editor or Supabase CLI migrations.
-- Safe to re-run: every statement is idempotent, so applying this script to
-- an existing database upgrades it in place without resetting any data.
begin;

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'KaSpot Member' check (char_length(display_name) between 1 and 80),
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Set when the account owner completes KaSpot registration (Google register
  -- flow or first verified password sign-in). Google sign-in without this flag
  -- is rejected so that signing in never doubles as silent registration.
  registered_at timestamptz
);

create table if not exists public.connection_requests (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'accepted', 'rejected', 'cancelled')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (requester_id <> recipient_id)
);
create unique index if not exists one_pending_request_per_pair
  on public.connection_requests (least(requester_id, recipient_id), greatest(requester_id, recipient_id))
  where status = 'pending';

create table if not exists public.connections (
  id uuid primary key default gen_random_uuid(),
  user_a_id uuid not null references auth.users(id) on delete cascade,
  user_b_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  check (user_a_id < user_b_id),
  unique (user_a_id, user_b_id)
);

create table if not exists public.circle_relationships (
  user_id uuid not null references auth.users(id) on delete cascade,
  target_user_id uuid not null references auth.users(id) on delete cascade,
  relationship text not null default 'Friend' check (relationship in ('Partner', 'Family', 'Friend')),
  updated_at timestamptz not null default now(),
  primary key (user_id, target_user_id)
);

create table if not exists public.location_sharing (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  is_enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  unique (owner_id, recipient_id),
  check (owner_id <> recipient_id)
);

-- Retention window for a stored coordinate, measured from the moment the server
-- accepts a write. Kept in one function so the policy, the trigger and the app
-- (lib/utils/location_tracking_config.dart) can be checked against a single
-- number.
create or replace function public.location_retention_interval()
returns interval language sql stable security invoker set search_path = '' as $$
  select interval '24 hours';
$$;

-- One row per user: the latest coordinate only, never a trail. received_at and
-- expires_at are stamped by a server-side trigger, so they are not client input.
create table if not exists public.locations (
  user_id uuid primary key references auth.users(id) on delete cascade,
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  recorded_at timestamptz not null default now(),
  received_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + public.location_retention_interval())
);

create table if not exists public.saved_places (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  created_at timestamptz not null default now()
);

create table if not exists public.notification_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  connection_notifications_enabled boolean not null default true,
  arrival_alerts_enabled boolean not null default false,
  background_sharing_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table public.notification_preferences
  add column if not exists background_sharing_enabled boolean not null default false;

create or replace function public.is_accepted_connection(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.connections c
    where (c.user_a_id = least(a, b) and c.user_b_id = greatest(a, b))
  );
$$;
revoke all on function public.is_accepted_connection(uuid, uuid) from public;
grant execute on function public.is_accepted_connection(uuid, uuid) to authenticated;

create or replace function public.guard_request_update()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if new.id <> old.id or new.requester_id <> old.requester_id
     or new.recipient_id <> old.recipient_id or new.created_at <> old.created_at then
    raise exception 'Request identity is immutable';
  end if;
  if old.status <> 'pending' or new.status not in ('accepted', 'rejected', 'cancelled') then
    raise exception 'Invalid request status transition';
  end if;
  if new.status in ('accepted', 'rejected') and auth.uid() <> old.recipient_id then
    raise exception 'Only the recipient can accept or reject';
  end if;
  if new.status = 'cancelled' and auth.uid() <> old.requester_id then
    raise exception 'Only the requester can cancel';
  end if;
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists connection_request_update_guard on public.connection_requests;
create trigger connection_request_update_guard before update on public.connection_requests
for each row execute function public.guard_request_update();

create or replace function public.create_connection_after_accept()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'accepted' and old.status = 'pending' then
    insert into public.connections (user_a_id, user_b_id)
    values (least(new.requester_id, new.recipient_id), greatest(new.requester_id, new.recipient_id))
    on conflict (user_a_id, user_b_id) do nothing;
  end if;
  return new;
end;
$$;
drop trigger if exists accepted_request_creates_connection on public.connection_requests;
create trigger accepted_request_creates_connection after update of status on public.connection_requests
for each row execute function public.create_connection_after_accept();

create or replace function public.cleanup_sharing_after_connection_removal()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.location_sharing
  where (owner_id = old.user_a_id and recipient_id = old.user_b_id)
     or (owner_id = old.user_b_id and recipient_id = old.user_a_id);
  return old;
end;
$$;
drop trigger if exists connection_removal_revokes_sharing on public.connections;
create trigger connection_removal_revokes_sharing after delete on public.connections
for each row execute function public.cleanup_sharing_after_connection_removal();

create or replace function public.guard_sharing_upsert()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if new.owner_id <> auth.uid() then raise exception 'Only the location owner may control sharing'; end if;
  if not public.is_accepted_connection(new.owner_id, new.recipient_id) then
    raise exception 'Sharing is available only to accepted connections';
  end if;
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists location_sharing_guard on public.location_sharing;
create trigger location_sharing_guard before insert or update on public.location_sharing
for each row execute function public.guard_sharing_upsert();

alter table public.profiles enable row level security;
alter table public.connection_requests enable row level security;
alter table public.connections enable row level security;
alter table public.location_sharing enable row level security;
alter table public.locations enable row level security;
alter table public.saved_places enable row level security;
alter table public.notification_preferences enable row level security;

-- A connected person or connection request participant can see published profile fields.
drop policy if exists profile_self_or_connection_read on public.profiles;
create policy profile_self_or_connection_read on public.profiles for select to authenticated
using (
  id = (select auth.uid())
  or public.is_accepted_connection(id, (select auth.uid()))
  or exists (
    select 1 from public.connection_requests r
    where (r.requester_id = profiles.id and r.recipient_id = (select auth.uid()))
       or (r.recipient_id = profiles.id and r.requester_id = (select auth.uid()))
  )
);
drop policy if exists profile_self_insert on public.profiles;
create policy profile_self_insert on public.profiles for insert to authenticated
with check (id = (select auth.uid()));
drop policy if exists profile_self_update on public.profiles;
create policy profile_self_update on public.profiles for update to authenticated
using (id = (select auth.uid())) with check (id = (select auth.uid()));

drop policy if exists requests_participant_read on public.connection_requests;
create policy requests_participant_read on public.connection_requests for select to authenticated
using (requester_id = (select auth.uid()) or recipient_id = (select auth.uid()));
drop policy if exists requests_requester_create on public.connection_requests;
create policy requests_requester_create on public.connection_requests for insert to authenticated
with check (requester_id = (select auth.uid()) and requester_id <> recipient_id
  and not public.is_accepted_connection(requester_id, recipient_id));
drop policy if exists requests_participant_transition on public.connection_requests;
create policy requests_participant_transition on public.connection_requests for update to authenticated
using ((requester_id = (select auth.uid()) or recipient_id = (select auth.uid())) and status = 'pending')
with check (
  (requester_id = (select auth.uid()) or recipient_id = (select auth.uid()))
  and (
    -- The recipient decides the outcome: accept or decline.
    (status in ('accepted', 'rejected') and recipient_id = (select auth.uid()))
    -- The requester may only withdraw their own pending invitation; consent
    -- can never be granted by the side that asked for the connection.
    or (status = 'cancelled' and requester_id = (select auth.uid()))
  )
);

drop policy if exists connections_participant_read on public.connections;
create policy connections_participant_read on public.connections for select to authenticated
using (user_a_id = (select auth.uid()) or user_b_id = (select auth.uid()));
drop policy if exists connections_participant_remove on public.connections;
create policy connections_participant_remove on public.connections for delete to authenticated
using (user_a_id = (select auth.uid()) or user_b_id = (select auth.uid()));
-- Connection rows are created only by the trusted acceptance trigger. Removing
-- a connection deletes both directional grants before the transaction commits.

drop policy if exists sharing_owner_or_recipient_read on public.location_sharing;
create policy sharing_owner_or_recipient_read on public.location_sharing for select to authenticated
using (owner_id = (select auth.uid()) or recipient_id = (select auth.uid()));
drop policy if exists sharing_owner_create on public.location_sharing;
create policy sharing_owner_create on public.location_sharing for insert to authenticated
with check (owner_id = (select auth.uid()) and public.is_accepted_connection(owner_id, recipient_id));
drop policy if exists sharing_owner_update on public.location_sharing;
create policy sharing_owner_update on public.location_sharing for update to authenticated
using (owner_id = (select auth.uid()))
with check (owner_id = (select auth.uid()) and public.is_accepted_connection(owner_id, recipient_id));
drop policy if exists sharing_owner_delete on public.location_sharing;
create policy sharing_owner_delete on public.location_sharing for delete to authenticated
using (owner_id = (select auth.uid()));

-- A user writes only their own latest location. A recipient reads only while
-- the owner has an enabled per-recipient sharing grant and the connection exists.
drop policy if exists locations_owner_upsert on public.locations;
create policy locations_owner_upsert on public.locations for insert to authenticated
with check (user_id = (select auth.uid()) and exists (
  select 1 from public.location_sharing s where s.owner_id = (select auth.uid()) and s.is_enabled
));
drop policy if exists locations_owner_refresh on public.locations;
create policy locations_owner_refresh on public.locations for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()) and exists (
  select 1 from public.location_sharing s where s.owner_id = (select auth.uid()) and s.is_enabled
));
drop policy if exists locations_authorized_read on public.locations;
create policy locations_authorized_read on public.locations for select to authenticated
using (expires_at > now() and (user_id = (select auth.uid()) or exists (
  select 1 from public.location_sharing s
  where s.owner_id = locations.user_id and s.recipient_id = (select auth.uid())
    and s.is_enabled and public.is_accepted_connection(s.owner_id, s.recipient_id)
)));
drop policy if exists locations_owner_delete on public.locations;
create policy locations_owner_delete on public.locations for delete to authenticated
using (user_id = (select auth.uid()));

drop policy if exists saved_places_owner_all on public.saved_places;
create policy saved_places_owner_all on public.saved_places for all to authenticated
using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists notification_preferences_owner_all on public.notification_preferences;
create policy notification_preferences_owner_all on public.notification_preferences for all to authenticated
using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
alter table public.circle_relationships enable row level security;
drop policy if exists circle_relationships_owner on public.circle_relationships;
create policy circle_relationships_owner on public.circle_relationships for all to authenticated
using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Make the Data API role grants explicit; RLS remains the row/relationship boundary.
revoke all on public.profiles, public.connection_requests, public.connections,
  public.circle_relationships, public.location_sharing, public.locations,
  public.saved_places, public.notification_preferences from anon;
grant select, insert, update on public.profiles to authenticated;
grant select, insert, update on public.connection_requests to authenticated;
grant select, delete on public.connections to authenticated;
grant select, insert, update, delete on public.circle_relationships to authenticated;
grant select, insert, update, delete on public.location_sharing to authenticated;
grant select, insert, update, delete on public.locations to authenticated;
grant select, insert, update, delete on public.saved_places to authenticated;
grant select, insert, update, delete on public.notification_preferences to authenticated;

-- ── FCM Device Tokens ──────────────────────────────────────────────────────
-- Stores one row per (user, device token) pair. The Edge Function reads this
-- table to look up where to deliver push notifications.
create table if not exists public.device_tokens (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  token       text not null,
  platform    text not null default 'android' check (platform in ('android', 'ios')),
  -- True only for app builds that render data-only FCM messages themselves via
  -- flutter_local_notifications. notify-new-message sends data-only payloads
  -- exclusively to such tokens and falls back to a legacy OS-rendered
  -- notification payload for every other token, so older installed binaries
  -- keep receiving notifications they can display during the rollout.
  supports_data_only boolean not null default false,
  updated_at  timestamptz not null default now(),
  constraint device_tokens_user_token_unique unique (user_id, token)
);

alter table public.device_tokens enable row level security;

-- Each user can only read and manage their own tokens.
drop policy if exists device_tokens_owner on public.device_tokens;
create policy device_tokens_owner on public.device_tokens
  for all to authenticated
  using  (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

grant select, insert, update, delete on public.device_tokens to authenticated;

-- In-Circle Chat Messaging between accepted circle members
create table if not exists public.circle_messages (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  content text not null check (char_length(trim(content)) between 1 and 500),
  created_at timestamptz not null default now(),
  -- Nullable: set by the recipient when they open the conversation.
  -- Used to drive unread-message badges without a separate counter table.
  read_at timestamptz default null,
  -- Nullable: references a prior message in the same conversation being replied to.
  reply_to_message_id uuid references public.circle_messages(id) on delete set null
);

alter table public.circle_messages enable row level security;

drop policy if exists circle_messages_participant_read on public.circle_messages;
create policy circle_messages_participant_read on public.circle_messages for select to authenticated
using (
  (sender_id = (select auth.uid()) or recipient_id = (select auth.uid()))
  and public.is_accepted_connection(sender_id, recipient_id)
);

-- Helper used by the INSERT policy to validate reply_to_message_id without
-- triggering infinite recursion (an inline subquery on circle_messages inside
-- an RLS policy on circle_messages causes a recursive policy evaluation loop).
-- security definer bypasses RLS for this read, breaking the cycle safely.
create or replace function public.is_valid_reply(
  reply_id uuid,
  sender   uuid,
  recip    uuid
)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.circle_messages m
    where m.id = reply_id
      and (
        (m.sender_id = sender and m.recipient_id = recip)
        or (m.sender_id = recip  and m.recipient_id = sender)
      )
  );
$$;
revoke all on function public.is_valid_reply(uuid, uuid, uuid) from public;
grant execute on function public.is_valid_reply(uuid, uuid, uuid) to authenticated;

drop policy if exists circle_messages_sender_create on public.circle_messages;
create policy circle_messages_sender_create on public.circle_messages for insert to authenticated
with check (
  sender_id = (select auth.uid())
  and public.is_accepted_connection(sender_id, recipient_id)
  and sender_id <> recipient_id
  and (
    reply_to_message_id is null
    or public.is_valid_reply(reply_to_message_id, sender_id, recipient_id)
  )
);

grant select, insert on public.circle_messages to authenticated;

-- Allow columns to be added to an existing table (safe to re-run: no-op if already present).
alter table public.circle_messages add column if not exists read_at timestamptz default null;
alter table public.circle_messages add column if not exists reply_to_message_id uuid references public.circle_messages(id) on delete set null;
create index if not exists idx_circle_messages_reply_to on public.circle_messages (reply_to_message_id);

-- Unread-badge support: the recipient may mark received messages as read.
drop policy if exists circle_messages_recipient_mark_read on public.circle_messages;
create policy circle_messages_recipient_mark_read on public.circle_messages
  for update to authenticated
  using  (recipient_id = (select auth.uid()))
  with check (recipient_id = (select auth.uid()));

grant select, insert, update on public.circle_messages to authenticated;

-- Lookup user ID by short uppercase circle code (e.g. KS-E7BE-D662 or E7BED662)
-- Both sides are normalised to uppercase hex so the comparison is case-insensitive.
create or replace function public.lookup_user_by_code(code text)
returns uuid language sql stable security definer set search_path = '' as $$
  select id from public.profiles
  where replace(replace(upper(trim(code)), 'KS-', ''), '-', '')
        = upper(substring(replace(id::text, '-', '') from 1 for 8))
  limit 1;
$$;
revoke all on function public.lookup_user_by_code(text) from public;
grant execute on function public.lookup_user_by_code(text) to authenticated;

-- Add public.locations, public.location_sharing, and public.circle_messages to the supabase_realtime
-- publication in the dashboard only after reviewing RLS and Realtime settings.
-- A database trigger below removes public.locations when the owner's final
-- enabled sharing grant is disabled or deleted.

commit;


-- Keep this cleanup trigger at the database boundary: direct client-side revocation
-- must stop exposing stale coordinates even if the owner app closes immediately.
begin;
create or replace function public.remove_unshared_latest_location()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  affected_owner uuid;
begin
  if tg_op = 'DELETE' then
    affected_owner := old.owner_id;
  else
    affected_owner := new.owner_id;
  end if;
  if not exists (
    select 1 from public.location_sharing s
    where s.owner_id = affected_owner and s.is_enabled
  ) then
    delete from public.locations where user_id = affected_owner;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
drop trigger if exists sharing_revocation_clears_location on public.location_sharing;
create trigger sharing_revocation_clears_location after update of is_enabled or delete on public.location_sharing
for each row execute function public.remove_unshared_latest_location();
commit;

-- Server-side retention: expiry is always stamped from the server clock, a
-- client timestamp can never be in the future, and a fix older than the
-- retention window is refused instead of being shown as current. Existing
-- installs get the columns and the backfill from
-- supabase/migrations/20261023_location_retention_expiration.sql.
begin;
create or replace function public.enforce_location_retention()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare
  retention interval := public.location_retention_interval();
begin
  new.received_at := now();
  if new.recorded_at is null or new.recorded_at > now() then
    new.recorded_at := now();
  end if;
  if now() - new.recorded_at > retention then
    raise exception 'KaSpot refused a location fix older than the % retention window', retention
      using errcode = '22000';
  end if;
  new.expires_at := now() + retention;
  return new;
end;
$$;

drop trigger if exists location_retention_enforcement on public.locations;
create trigger location_retention_enforcement before insert or update on public.locations
for each row execute function public.enforce_location_retention();

-- Physical purge of expired rows. Read invisibility is enforced by the SELECT
-- policy above, so this only reclaims storage and is meant for a scheduler.
-- pg_cron is available on the project but not installed, and scheduling it is a
-- separate approved deployment step (see the migration file).
create or replace function public.delete_expired_locations()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  removed integer;
begin
  delete from public.locations where expires_at <= now();
  get diagnostics removed = row_count;
  return removed;
end;
$$;
revoke all on function public.delete_expired_locations() from public, anon, authenticated;
grant execute on function public.delete_expired_locations() to postgres, service_role;
commit;

-- Automatically provision profile and default notification preferences on signup
begin;
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  candidate_name text;
begin
  candidate_name := coalesce(
    nullif(trim(new.raw_user_meta_data->>'display_name'), ''),
    nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
    nullif(trim(new.raw_user_meta_data->>'name'), ''),
    nullif(split_part(new.email, '@', 1), ''),
    'KaSpot Member'
  );

  insert into public.profiles (id, display_name)
  values (new.id, candidate_name)
  on conflict (id) do update
    set display_name = excluded.display_name
    where public.profiles.display_name is null or trim(public.profiles.display_name) = '';

  insert into public.notification_preferences (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();
commit;

-- Migration for existing databases that predate the registration flag
-- (idempotent — safe to run once in the Supabase SQL editor):
--   alter table public.profiles add column if not exists registered_at timestamptz;
--   update public.profiles set registered_at = coalesce(created_at, now())
--   where registered_at is null;

-- Migration for existing databases that predate the role-restricted request
-- transitions (idempotent — safe to run once in the Supabase SQL editor).
-- Without it, the original policy let a requester move their own pending
-- request straight to 'accepted', bypassing the recipient's consent:
--   drop policy if exists requests_participant_transition on public.connection_requests;
--   create policy requests_participant_transition on public.connection_requests for update to authenticated
--   using ((requester_id = (select auth.uid()) or recipient_id = (select auth.uid())) and status = 'pending')
--   with check (
--     (requester_id = (select auth.uid()) or recipient_id = (select auth.uid()))
--     and (
--       (status in ('accepted', 'rejected') and recipient_id = (select auth.uid()))
--       or (status = 'cancelled' and requester_id = (select auth.uid()))
--     )
--   );

-- ── Message Reactions ───────────────────────────────────────────────────────
-- Each user may have at most one active emoji reaction per circle_message.
-- Reactions are deleted automatically when their parent message is deleted
-- (on delete cascade on the message_id foreign key).
-- See also: supabase/migrations/20261020_message_reactions.sql

create table if not exists public.message_reactions (
  id          uuid        primary key default gen_random_uuid(),
  message_id  uuid        not null
                            references public.circle_messages(id) on delete cascade,
  user_id     uuid        not null references auth.users(id) on delete cascade,
  emoji       text        not null check (char_length(emoji) between 1 and 16),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint message_reactions_message_user_unique unique (message_id, user_id)
);

create index if not exists idx_message_reactions_message_id
  on public.message_reactions (message_id);
create index if not exists idx_message_reactions_user_id
  on public.message_reactions (user_id);

alter table public.message_reactions enable row level security;

drop policy if exists message_reactions_participant_read on public.message_reactions;
create policy message_reactions_participant_read
  on public.message_reactions for select to authenticated
  using (
    exists (
      select 1 from public.circle_messages m
      where m.id = message_reactions.message_id
        and (m.sender_id = (select auth.uid()) or m.recipient_id = (select auth.uid()))
        and public.is_accepted_connection(m.sender_id, m.recipient_id)
    )
  );

drop policy if exists message_reactions_self_create on public.message_reactions;
create policy message_reactions_self_create
  on public.message_reactions for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.circle_messages m
      where m.id = message_reactions.message_id
        and (m.sender_id = (select auth.uid()) or m.recipient_id = (select auth.uid()))
        and public.is_accepted_connection(m.sender_id, m.recipient_id)
    )
  );

drop policy if exists message_reactions_self_update on public.message_reactions;
create policy message_reactions_self_update
  on public.message_reactions for update to authenticated
  -- Existing-row gate: only the reaction's owner may attempt an update.
  using (user_id = (select auth.uid()))
  -- Resulting-row gate: ownership must not change AND the message must still
  -- belong to a conversation the caller is authorized to access.
  -- Without the message check a user could redirect their own reaction to a
  -- message in a foreign conversation via a direct UPDATE statement.
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1
      from public.circle_messages m
      where m.id = message_reactions.message_id
        and (
          m.sender_id    = (select auth.uid())
          or m.recipient_id = (select auth.uid())
        )
        and public.is_accepted_connection(m.sender_id, m.recipient_id)
    )
  );

drop policy if exists message_reactions_self_delete on public.message_reactions;
create policy message_reactions_self_delete
  on public.message_reactions for delete to authenticated
  using (user_id = (select auth.uid()));

revoke all on public.message_reactions from anon;
grant select, insert, update, delete on public.message_reactions to authenticated;

create or replace function public.upsert_reaction(p_message_id uuid, p_emoji text)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  insert into public.message_reactions (message_id, user_id, emoji, updated_at)
  values (p_message_id, auth.uid(), p_emoji, now())
  on conflict (message_id, user_id)
  do update set emoji = excluded.emoji, updated_at = now();
end;
$$;
revoke all on function public.upsert_reaction(uuid, text) from public;
grant execute on function public.upsert_reaction(uuid, text) to authenticated;
