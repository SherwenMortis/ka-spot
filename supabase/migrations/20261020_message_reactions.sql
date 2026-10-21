-- =============================================================================
-- Migration: message_reactions
-- Applied:   2026-10-20
-- Purpose:   Adds per-message emoji reactions for the KaSpot Circle Chat.
--
-- Deployment instructions
-- -----------------------
-- Run this script once in the Supabase SQL Editor (or via `supabase db push`).
-- It is idempotent: every statement uses IF NOT EXISTS / OR REPLACE / IF EXISTS
-- guards so it can safely be re-run without resetting data.
--
-- After running this script, enable realtime for message_reactions in the
-- Supabase Dashboard → Database → Replication → supabase_realtime publication
-- (or use the ALTER PUBLICATION statement at the bottom of this file).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Table: public.message_reactions
-- ---------------------------------------------------------------------------
create table if not exists public.message_reactions (
  id          uuid        primary key default gen_random_uuid(),
  message_id  uuid        not null
                            references public.circle_messages(id)
                            on delete cascade,   -- reactions cannot outlive their message
  user_id     uuid        not null
                            references auth.users(id)
                            on delete cascade,
  emoji       text        not null
                            check (char_length(emoji) between 1 and 16),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),

  -- Each user may have at most one active reaction per message.
  constraint message_reactions_message_user_unique unique (message_id, user_id)
);

-- Index for loading all reactions belonging to a set of message IDs quickly.
create index if not exists idx_message_reactions_message_id
  on public.message_reactions (message_id);

-- Index for loading / cleaning up a user's own reactions.
create index if not exists idx_message_reactions_user_id
  on public.message_reactions (user_id);

-- ---------------------------------------------------------------------------
-- Row-Level Security
-- ---------------------------------------------------------------------------
alter table public.message_reactions enable row level security;

-- READ: a user may read reactions only for messages in conversations they are
-- already authorised to access (i.e. conversations where they are a participant
-- and an accepted connection exists).  We re-use the same predicate as the
-- circle_messages SELECT policy without introducing recursion.
drop policy if exists message_reactions_participant_read on public.message_reactions;
create policy message_reactions_participant_read
  on public.message_reactions for select to authenticated
  using (
    exists (
      select 1
      from public.circle_messages m
      where m.id = message_reactions.message_id
        and (m.sender_id = (select auth.uid()) or m.recipient_id = (select auth.uid()))
        and public.is_accepted_connection(m.sender_id, m.recipient_id)
    )
  );

-- CREATE: a user may insert a reaction row only as themselves, and only for
-- a message in a conversation they participate in.
drop policy if exists message_reactions_self_create on public.message_reactions;
create policy message_reactions_self_create
  on public.message_reactions for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1
      from public.circle_messages m
      where m.id = message_reactions.message_id
        and (m.sender_id = (select auth.uid()) or m.recipient_id = (select auth.uid()))
        and public.is_accepted_connection(m.sender_id, m.recipient_id)
    )
  );

-- UPDATE: a user may update only their own reaction row (e.g. to change the emoji).
-- The WITH CHECK clause also verifies the resulting message_id still belongs
-- to a conversation the caller is authorized to access.  This prevents a user
-- from redirecting their own reaction to a message in a foreign conversation
-- via a direct UPDATE statement (which bypasses the INSERT policy entirely).
drop policy if exists message_reactions_self_update on public.message_reactions;
create policy message_reactions_self_update
  on public.message_reactions for update to authenticated
  using  (user_id = (select auth.uid()))
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

-- DELETE: a user may delete only their own reaction.
drop policy if exists message_reactions_self_delete on public.message_reactions;
create policy message_reactions_self_delete
  on public.message_reactions for delete to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- Data-API grants
-- ---------------------------------------------------------------------------
revoke all on public.message_reactions from anon;
grant select, insert, update, delete on public.message_reactions to authenticated;

-- ---------------------------------------------------------------------------
-- Helper: upsert_reaction
-- Called by the Flutter client as a single RPC to add-or-replace a reaction.
-- Using a database function avoids the round-trip of a DELETE + INSERT and
-- prevents a race window where a competing UNIQUE violation can occur.
-- security definer is NOT used here; the function runs as the caller so all
-- RLS policies on message_reactions still apply.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_reaction(
  p_message_id uuid,
  p_emoji      text
)
returns void language plpgsql security invoker set search_path = '' as $$
begin
  insert into public.message_reactions (message_id, user_id, emoji, updated_at)
  values (p_message_id, auth.uid(), p_emoji, now())
  on conflict (message_id, user_id)
  do update set emoji = excluded.emoji,
                updated_at = now();
end;
$$;

revoke all on function public.upsert_reaction(uuid, text) from public;
grant execute on function public.upsert_reaction(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Realtime publication
-- Run once; safe to re-run (DO $$ blocks are idempotent here).
-- ---------------------------------------------------------------------------
do $$
begin
  -- Add message_reactions to the realtime publication if it is not already a member.
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'message_reactions'
  ) then
    alter publication supabase_realtime add table public.message_reactions;
  end if;
end;
$$;

commit;
