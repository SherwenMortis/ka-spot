// Supabase Edge Function — notify-new-message
//
// Triggered by a Database Webhook on INSERT into public.circle_messages. Looks
// up the recipient's FCM tokens and asks Firebase Cloud Messaging to wake the
// device. The payload is deliberately generic: no sender name, no message text,
// no preview. The message itself is only ever read through the app's
// authenticated chat flow, so the push provider never sees its content.
//
// SECURITY: this endpoint is invoked by pg_net, which is not a user and cannot
// present a session JWT. The project anon key is public (it ships in the app),
// so it authenticates nobody. The function is therefore deployed with
// `verify_jwt = false` (supabase/config.toml) and every request is authenticated
// inside handle() against KASPOT_WEBHOOK_SECRET before a body is read or a
// client exists — see webhook_secret.ts for the mechanism and rationale, and
// supabase/STAGING.md for the exact Dashboard header to configure.
//
// This file only wires the real clients; the request pipeline lives in
// handler.ts so the authentication and validation boundary can be executed by
// `deno test`.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { GoogleAuth } from 'npm:google-auth-library@9';
import { buildFcmMessage } from './payload.ts';
import {
  type DeviceToken,
  handle,
  type HandlerDeps,
  type WebhookStore,
} from './handler.ts';

// ── Types ──────────────────────────────────────────────────────────────────

interface DeviceTokenRow {
  token: string;
  supports_data_only?: boolean | null;
}

interface MessageRow {
  id: string;
  sender_id: string;
  recipient_id: string;
}

// ── Store ──────────────────────────────────────────────────────────────────

/// One service-role client per isolate. It is only constructed once a request
/// has been authenticated.
let cachedClient: ReturnType<typeof createClient> | null = null;

function supabase() {
  if (cachedClient) return cachedClient;
  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !serviceKey) {
    throw new Error('Supabase server configuration missing');
  }
  cachedClient = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  return cachedClient;
}

function createStore(): WebhookStore {
  return {
    async message(id) {
      const { data, error } = await supabase()
        .from('circle_messages')
        .select('id, sender_id, recipient_id')
        .eq('id', id)
        .maybeSingle<MessageRow>();
      if (error) throw new Error('message lookup failed');
      return data ?? null;
    },

    async areConnected(a, b) {
      // Either ordering is checked rather than assuming the stored pair is
      // sorted, so this stays correct even if that constraint is ever relaxed.
      const { data, error } = await supabase()
        .from('connections')
        .select('id')
        .or(
          `and(user_a_id.eq.${a},user_b_id.eq.${b}),` +
            `and(user_a_id.eq.${b},user_b_id.eq.${a})`,
        )
        .limit(1);
      if (error) throw new Error('connection lookup failed');
      return ((data ?? []) as Array<{ id: string }>).length > 0;
    },

    async notificationsEnabled(userId) {
      const { data, error } = await supabase()
        .from('notification_preferences')
        .select('connection_notifications_enabled')
        .eq('user_id', userId)
        .maybeSingle<{ connection_notifications_enabled: boolean | null }>();
      // A missing preferences row is the schema default (notifications on), and
      // a read failure must not silently mute every user in the product.
      if (error) throw new Error('preference lookup failed');
      return data?.connection_notifications_enabled !== false;
    },

    async deviceTokens(userId) {
      // `supports_data_only` is an additive column. If this version of the
      // function is deployed BEFORE the migration is applied, selecting it
      // returns an error — retry with the token-only select so an un-migrated
      // database behaves exactly like the previous function (everyone keeps
      // receiving the legacy payload) rather than breaking delivery.
      const result = await supabase()
        .from('device_tokens')
        .select('token, supports_data_only')
        .eq('user_id', userId);

      if (result.error) {
        console.warn(
          'device_tokens.supports_data_only unavailable; falling back to legacy payloads for all devices',
        );
        const fallback = await supabase()
          .from('device_tokens')
          .select('token')
          .eq('user_id', userId);
        if (fallback.error) throw new Error('device token lookup failed');
        return ((fallback.data ?? []) as DeviceTokenRow[]).map((row) => ({
          token: row.token,
          supportsDataOnly: false,
        }));
      }

      return ((result.data ?? []) as DeviceTokenRow[]).map((row) => ({
        token: row.token,
        supportsDataOnly: row.supports_data_only === true,
      }));
    },
  };
}

// ── Push ───────────────────────────────────────────────────────────────────

/// One Firebase client per isolate; GoogleAuth caches its OAuth2 token.
let cachedPush: HandlerDeps['push'] | null = null;

function createPush(): HandlerDeps['push'] {
  if (cachedPush) return cachedPush;

  const serviceAccountJson = Deno.env.get('FIREBASE_SERVICE_ACCOUNT_JSON');
  if (!serviceAccountJson) {
    throw new Error('FIREBASE_SERVICE_ACCOUNT_JSON is not set');
  }

  const serviceAccount = JSON.parse(serviceAccountJson);
  const auth = new GoogleAuth({
    credentials: serviceAccount,
    scopes: ['https://www.googleapis.com/auth/firebase.messaging'],
  });
  const fcmUrl =
    `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`;

  cachedPush = {
    async send(target: DeviceToken, routing: Record<string, string>) {
      const accessToken = await auth.getAccessToken();
      if (!accessToken) throw new Error('no FCM access token');

      const response = await fetch(fcmUrl, {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          message: buildFcmMessage(
            target.token,
            target.supportsDataOnly,
            routing,
          ),
        }),
      });

      // A non-2xx answer (typically a stale token) is a delivery failure for
      // this device and is counted by the handler; it never fails the webhook.
      if (!response.ok) {
        throw new Error(`FCM rejected the message with ${response.status}`);
      }
    },
  };
  return cachedPush;
}

// ── Handler ────────────────────────────────────────────────────────────────

Deno.serve((req: Request) =>
  handle(
    req,
    // Read per request so a rotated secret takes effect without a redeploy of
    // this file, and so a missing one fails closed instead of open.
    { secret: Deno.env.get('KASPOT_WEBHOOK_SECRET') },
    () => ({
      store: createStore(),
      // Deferred to the first send. Building the Firebase client here would make
      // every authenticated event fail with a server-configuration error, even
      // one with nobody to notify (unknown message, no devices, notifications
      // off). Staging showed exactly that: a missing FCM credential turned a
      // no-tokens event into a 500.
      push: { send: (target, routing) => createPush().send(target, routing) },
    }),
  )
);
