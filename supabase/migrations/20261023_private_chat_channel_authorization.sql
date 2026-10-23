-- KaSpot: authorization for the private Circle-chat conversation channel.
--
-- Scope: ONLY channels whose topic is a conversation channel, i.e. exactly
-- `chat-<uuid>_<uuid>`. Every other Realtime channel in this project
-- (`kaspot-location-map-<uid>`, `kaspot-inapp-<uid>`) is Postgres-Changes only,
-- stays public and is untouched by these policies, so the project-wide
-- "Allow public access" Realtime setting must remain enabled.
--
-- RLS is ALREADY enabled on realtime.messages (owned by supabase_realtime_admin)
-- so this migration deliberately contains no
-- `alter table realtime.messages enable row level security`: that statement
-- fails with 42501 "must be owner of table messages", aborts the transaction and
-- silently skips every policy after it. supautils lets the postgres role create
-- policies on this table without owning it.
--
-- Authorization is derived entirely from the topic the Realtime server itself
-- reports plus the accepted-connection rule the rest of the app already uses.
-- Nothing here trusts a client-supplied peer id, and knowing the channel name is
-- not sufficient: the two ids must hold a row in public.connections, which only
-- the trusted request-acceptance trigger can create.
--
-- The two ids are matched in EITHER order so that a client build that has not
-- yet picked up the canonical sorted name is not locked out of its own
-- conversation while it is still unable to reach the peer's broadcasts anyway.

-- The two participant ids encoded in a conversation channel topic, or an empty
-- array for anything that is not a conversation channel.
create or replace function public.chat_channel_users(channel_topic text)
returns uuid[] language sql immutable security definer set search_path = '' as $$
  select case
    when t ~ '^chat-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then array[substring(t from 6 for 36)::uuid, substring(t from 43)::uuid]
    else array[]::uuid[]
  end
  from (
    select lower(regexp_replace(coalesce(channel_topic, ''), '^realtime:', '')) as t
  ) parsed;
$$;

revoke all on function public.chat_channel_users(text) from public;
grant execute on function public.chat_channel_users(text) to authenticated;

-- True only when the caller is one of the two ids of a conversation channel
-- whose members still hold an accepted connection.
--
-- The policy intentionally does not filter realtime.messages.extension: the
-- label the Realtime server probes with (broadcast / presence /
-- postgres_changes) has changed across server versions, and the conversation
-- membership test above is the actual security boundary. Postgres-Changes
-- payloads remain governed by the RLS on their own tables.
create or replace function public.is_chat_channel_participant(channel_topic text)
returns boolean language sql stable security definer set search_path = '' as $$
  select members[1] is not null
    and members[1] <> members[2]
    and uid = any (members)
    and public.is_accepted_connection(members[1], members[2])
  from (
    select public.chat_channel_users(channel_topic) as members,
           (select auth.uid()) as uid
  ) subject;
$$;

revoke all on function public.is_chat_channel_participant(text) from public;
grant execute on function public.is_chat_channel_participant(text) to authenticated;

-- Subscribe / receive: joining the channel and receiving its Broadcast events.
drop policy if exists chat_channel_participant_receive on realtime.messages;
create policy chat_channel_participant_receive on realtime.messages
  for select to authenticated
  using ( public.is_chat_channel_participant(topic) );

-- Publish: sending a Broadcast event (typing start / stop) on the channel.
drop policy if exists chat_channel_participant_publish on realtime.messages;
create policy chat_channel_participant_publish on realtime.messages
  for insert to authenticated
  with check ( public.is_chat_channel_participant(topic) );
