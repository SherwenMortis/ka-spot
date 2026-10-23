// Supabase Edge Function — notify-new-message
// Triggered by a Postgres webhook on INSERT into public.circle_messages.
// Looks up the recipient's FCM tokens, fetches the sender's display name,
// and calls the FCM v1 HTTP API to deliver: "Sherwin has a message for you".

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { GoogleAuth } from 'npm:google-auth-library@9';

// ── Types ──────────────────────────────────────────────────────────────────

interface WebhookPayload {
  type: 'INSERT';
  table: string;
  record: {
    id: string;
    sender_id: string;
    recipient_id: string;
    content: string;
    created_at: string;
  };
  schema: string;
}

// ── Handler ────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  try {
    // 1. Parse the webhook payload from Supabase.
    const payload: WebhookPayload = await req.json();

    // Only handle INSERT events on circle_messages.
    if (payload.type !== 'INSERT' || payload.table !== 'circle_messages') {
      return new Response('ignored', { status: 200 });
    }

    const { id: messageId, sender_id, recipient_id, content } = payload.record;
    if (!sender_id || !recipient_id) {
      return new Response('missing ids', { status: 400 });
    }

    // 2. Build a service-role Supabase client to read from the database.
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supabase = createClient(supabaseUrl, serviceKey);

    // 3. Fetch sender's display name.
    const { data: senderProfile } = await supabase
      .from('profiles')
      .select('display_name')
      .eq('id', sender_id)
      .single();

    const senderName: string =
      (senderProfile?.display_name as string | null)?.trim() || 'Someone';

    // 4. Fetch all FCM tokens for the recipient, together with each device's
    // notification-rendering capability.
    //
    // `supports_data_only` is an additive column. If this version of the
    // function is deployed BEFORE the migration is applied, selecting it returns
    // an error and `data` is null — which would silently stop notifications for
    // every user. Retry with the token-only select so an un-migrated database
    // behaves exactly like the previous function (everyone keeps receiving the
    // legacy payload) rather than breaking delivery. Deploying the migration
    // first is still the documented order; this only removes the failure mode.
    const tokensResult = await supabase
      .from('device_tokens')
      .select('token, supports_data_only')
      .eq('user_id', recipient_id);

    const capabilityColumnMissing = tokensResult.error != null;
    if (capabilityColumnMissing) {
      console.warn(
        'device_tokens.supports_data_only unavailable; falling back to legacy payloads for all devices',
      );
    }

    const tokenRows: Array<{ token: string; supports_data_only?: boolean | null }> =
      capabilityColumnMissing
        ? (
            await supabase
              .from('device_tokens')
              .select('token')
              .eq('user_id', recipient_id)
          ).data ?? []
        : tokensResult.data ?? [];

    if (!tokenRows || tokenRows.length === 0) {
      // Recipient has no registered device — nothing to do.
      return new Response('no tokens', { status: 200 });
    }

    // 5. Check recipient's notification preferences.
    const { data: prefs } = await supabase
      .from('notification_preferences')
      .select('connection_notifications_enabled')
      .eq('user_id', recipient_id)
      .single();

    if (prefs?.connection_notifications_enabled === false) {
      return new Response('notifications disabled', { status: 200 });
    }

    // 6. Obtain a short-lived OAuth2 access token for the FCM v1 API using
    //    the Firebase service account stored as a Supabase secret.
    const serviceAccountJson = Deno.env.get('FIREBASE_SERVICE_ACCOUNT_JSON');
    if (!serviceAccountJson) {
      console.error('FIREBASE_SERVICE_ACCOUNT_JSON secret is not set.');
      return new Response('server config error', { status: 500 });
    }

    const serviceAccount = JSON.parse(serviceAccountJson);
    const auth = new GoogleAuth({
      credentials: serviceAccount,
      scopes: ['https://www.googleapis.com/auth/firebase.messaging'],
    });
    const accessToken = await auth.getAccessToken();
    const projectId: string = serviceAccount.project_id;

    // 7. Send to each registered device token, choosing a payload the installed
    //    build can actually render. See the two branches below.
    const fcmUrl = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

    const notificationTitle = `${senderName} has a message for you`;
    const notificationBody =
      content.length > 80 ? `${content.substring(0, 77)}…` : content;

    const routingData: Record<string, string> = {
      type: 'circle_message',
      sender_id,
      // FCM v1 rejects a whole message whose data values are not strings, so
      // every field is coerced. An absent id becomes '' which the client reads
      // as "no specific message to scroll to".
      message_id: messageId == null ? '' : String(messageId),
      title: notificationTitle,
      body: notificationBody,
    };

    const buildMessage = (token: string, supportsDataOnly: boolean) => {
      // Capability-reported devices get a DATA-ONLY message: the app renders it
      // itself, which gives KaSpot control over the notification id/tag/channel
      // (so it can be dismissed when the message is read and plays sound on a
      // channel it owns) and over the tap routing payload. `priority: high` is
      // required so data-only messages wake the background/terminated handler
      // reliably on Android.
      //
      // Every other device (older installed binary, or a token registered before
      // the capability migration) keeps the legacy NOTIFICATION message. Older
      // builds cannot display a data-only message at all: their background
      // handler only logs, and their foreground handler renders only when
      // `message.notification` is present — data-only would silently drop the
      // notification for those users.
      if (supportsDataOnly) {
        return {
          token,
          android: { priority: 'high' },
          data: routingData,
        };
      }
      return {
        token,
        notification: {
          title: notificationTitle,
          body: notificationBody,
        },
        android: {
          priority: 'high',
          notification: {
            channel_id: 'kaspot_messages',
            sound: 'default',
            click_action: 'FLUTTER_NOTIFICATION_CLICK',
            tag: `sender_${sender_id}`,
          },
        },
        // Routing metadata also rides on the legacy payload so a newer build
        // that has not re-registered its token yet can still navigate on tap.
        data: routingData,
      };
    };

    const results = await Promise.allSettled(
      tokenRows.map(
        ({ token, supports_data_only }: { token: string; supports_data_only?: boolean | null }) =>
          fetch(fcmUrl, {
            method: 'POST',
            headers: {
              'Authorization': `Bearer ${accessToken}`,
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({
              message: buildMessage(
                token,
                !capabilityColumnMissing && supports_data_only === true,
              ),
            }),
          })
      )
    );

    // Log any failures (stale tokens etc.) but don't fail the function.
    for (const result of results) {
      if (result.status === 'rejected') {
        console.error('FCM send failed:', result.reason);
      }
    }

    return new Response('ok', { status: 200 });
  } catch (err) {
    console.error('notify-new-message error:', err);
    return new Response(String(err), { status: 500 });
  }
});
