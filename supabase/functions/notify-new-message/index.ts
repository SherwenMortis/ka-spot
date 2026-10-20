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

    const { sender_id, recipient_id, content } = payload.record;
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

    // 4. Fetch all FCM tokens for the recipient.
    const { data: tokenRows } = await supabase
      .from('device_tokens')
      .select('token')
      .eq('user_id', recipient_id);

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

    // 7. Send to each registered device token.
    const fcmUrl = `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`;

    const notificationTitle = `${senderName} has a message for you`;
    const notificationBody =
      content.length > 80 ? `${content.substring(0, 77)}…` : content;

    const results = await Promise.allSettled(
      tokenRows.map(({ token }: { token: string }) =>
        fetch(fcmUrl, {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${accessToken}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            message: {
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
              data: {
                sender_id,
                type: 'circle_message',
              },
            },
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
