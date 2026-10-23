-- =============================================================================
-- Migration: device_token_notification_capability
-- Date:      2026-10-23
-- Purpose:   Lets each registered device advertise whether its installed
--            KaSpot build can render app-managed (data-only) chat
--            notifications, so the notify-new-message Edge Function can pick a
--            compatible FCM payload per device instead of switching every
--            installed binary over at once.
--
-- Why this is needed
-- ------------------
-- Chat notifications were moved from OS-rendered FCM "notification" messages to
-- data-only messages rendered by the app itself. That is what makes reliable
-- sound, tap-to-conversation navigation, and read-based dismissal possible --
-- but OLDER installed binaries cannot display a data-only message at all:
--   * their _firebaseBackgroundHandler only logs (it never shows a notification),
--   * their foreground handler only shows a notification when
--     message.notification != null.
-- Sending data-only to those devices would silently drop the notification.
-- The Edge Function therefore keeps sending the legacy "notification" payload to
-- tokens that have not reported the capability, and sends data-only only to
-- tokens that have.
--
-- Deployment instructions
-- -----------------------
-- Apply this BEFORE deploying the updated Edge Function and BEFORE releasing the
-- updated app. It is additive and safe for older clients: the column defaults
-- to false, so every existing row keeps receiving the legacy payload it already
-- understands. Re-run any time -- every statement is guarded.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Column: public.device_tokens.supports_data_only
-- ---------------------------------------------------------------------------
alter table public.device_tokens
  add column if not exists supports_data_only boolean not null default false;

comment on column public.device_tokens.supports_data_only is
  'true when the app build that registered this token renders data-only FCM '
  'messages itself via flutter_local_notifications. The notify-new-message '
  'function sends data-only payloads only to such tokens and falls back to a '
  'legacy OS-rendered notification payload for every other token.';

commit;
