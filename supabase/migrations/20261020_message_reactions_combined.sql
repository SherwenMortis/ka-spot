-- =============================================================================
-- KaSpot — Message Reactions: complete, combined deployment script
-- Applied:   2026-10-20
--
-- Use this file when deploying to a Supabase project that does NOT yet have
-- the message_reactions table.  It supersedes running the two separate files
-- (20261020_message_reactions.sql + 20261020_message_reactions_security_fix.sql)
-- in sequence.
--
-- Safe to re-run: every statement is idempotent.
-- Prerequisite: public.circle_messages and public.is_accepted_connection must
-- already exist (they are created by the base schema.sql).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------
create table if not exists public.message_reactions (
  id          uuid        primary key default gen_random_uuid(),
  message_id  uuid        not null
                            references public.circle_messages(id)
                            on delete cascade,
  user_id     uuid        not null
                            references auth.users(id)
                            on delete cascade,
  emoji       text        not null
                            check (char_length(emoji) between 1 and 16),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint message_reactions_message_user_unique unique (message_id, user_id)
);

create index if not exists idx_message_reactions_message_id
  on public.message_reactions (message_id);

create index if not exists idx_message_reactions_user_id
  on public.message_reactions (user_id);

-- ---------------------------------------------------------------------------
-- 2. Row-Level Security
-- ---------------------------------------------------------------------------
alter table public.message_reactions enable row level security;

-- READ
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

-- INSERT
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

-- UPDATE (security-fixed version)
-- USING  — only the row owner may attempt an update.
-- WITH CHECK — ownership must not change AND the resulting message_id must
--              still belong to a conversation the caller is authorised to
--              access.  Without the message check a user could redirect their
--              own reaction to a message in a foreign conversation via a direct
--              UPDATE statement, bypassing the INSERT policy entirely.
drop policy if exists message_reactions_self_update on public.message_reactions;
create policy message_reactions_self_update
  on public.message_reactions for update to authenticated
  using (user_id = (select auth.uid()))
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.circle_messages m
      where m.id = message_reactions.message_id
        and (
          m.sender_id    = (select auth.uid())
          or m.recipient_id = (select auth.uid())
        )
        and public.is_accepted_connection(m.sender_id, m.recipient_id)
    )
  );

-- DELETE
drop policy if exists message_reactions_self_delete on public.message_reactions;
create policy message_reactions_self_delete
  on public.message_reactions for delete to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------------
-- 3. Grants
-- ---------------------------------------------------------------------------
revoke all on public.message_reactions from anon;
grant select, insert, update, delete on public.message_reactions to authenticated;

-- ---------------------------------------------------------------------------
-- 4. upsert_reaction RPC
-- SECURITY INVOKER: runs as the calling user so all RLS policies above apply.
-- user_id is always auth.uid() — never taken from caller input.
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
  do update set emoji      = excluded.emoji,
                updated_at = now();
end;
$$;

revoke all on function public.upsert_reaction(uuid, text) from public;
grant execute on function public.upsert_reaction(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Realtime publication (idempotent)
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname    = 'supabase_realtime'
      and schemaname = 'public'
      and tablename  = 'message_reactions'
  ) then
    alter publication supabase_realtime add table public.message_reactions;
  end if;
end;
$$;

commit;
