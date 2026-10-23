-- =============================================================================
-- Migration: message_reactions_security_fix
-- Applied:   2026-10-20 (immediately after 20261020_message_reactions.sql)
-- Purpose:   Fixes a defect in the UPDATE RLS policy for message_reactions.
--
-- Defect
-- ------
-- The original UPDATE policy checked only `user_id = auth.uid()` in both the
-- USING and WITH CHECK clauses.  This allowed an authenticated user who owns a
-- reaction to UPDATE the `message_id` column of that row to any UUID, including
-- the ID of a message in a conversation they are not authorized to access.
--
-- Attack example (without this fix):
--   UPDATE public.message_reactions
--   SET message_id = '<id from a foreign conversation>'
--   WHERE id = '<attacker owns this reaction>';
-- The INSERT policy cannot block this because UPDATE bypasses INSERT entirely.
--
-- Fix
-- ---
-- The WITH CHECK clause is extended to require that the resulting row's
-- message_id still belongs to a conversation the current user is authorized
-- to access under the same predicate used by the INSERT policy and the SELECT
-- policy.  The USING clause is unchanged (it correctly gates which rows the
-- user may even attempt to update).
--
-- This migration is idempotent: DROP POLICY IF EXISTS + CREATE POLICY is safe
-- to re-run.  No existing data is modified.
-- =============================================================================

begin;

drop policy if exists message_reactions_self_update on public.message_reactions;

create policy message_reactions_self_update
  on public.message_reactions for update to authenticated
  -- Existing-row gate: only the reaction's owner may attempt an update.
  using (user_id = (select auth.uid()))
  -- Resulting-row gate: the updated row must still belong to an authorized
  -- conversation, AND ownership must not change.
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

commit;
