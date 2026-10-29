// The exact payload notify-new-message hands to Firebase Cloud Messaging.
//
// Isolated from the handler so `deno test` can assert what actually leaves this
// server for Google's push infrastructure: a fixed generic alert plus routing
// ids, never message text, never a sender name. The handler itself only wires
// env vars and HTTP, which a unit test cannot exercise.

// Every notification says the same thing; the conversation is opened by the tap
// routing below, not by anything written here.
export const GENERIC_TITLE = 'New message in KaSpot';
export const GENERIC_BODY = 'Open KaSpot to view your message';

/// Keys the client reads to open the right conversation. Anything added here
/// reaches the push provider, so it must stay an opaque identifier.
export function buildRoutingData(
  senderId: string,
  messageId: string | null | undefined,
): Record<string, string> {
  return {
    type: 'circle_message',
    sender_id: senderId,
    // FCM v1 rejects a whole message whose data values are not strings, so
    // every field is coerced. An absent id becomes '' which the client reads
    // as "no specific message to scroll to".
    message_id: messageId == null ? '' : String(messageId),
    title: GENERIC_TITLE,
    body: GENERIC_BODY,
  };
}

/// One FCM message for one device token, shaped for what that install can
/// render. Neither branch ever carries message content.
export function buildFcmMessage(
  token: string,
  supportsDataOnly: boolean,
  routingData: Record<string, string>,
): Record<string, unknown> {
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
      title: routingData.title,
      body: routingData.body,
    },
    android: {
      priority: 'high',
      notification: {
        channel_id: 'kaspot_messages',
        sound: 'default',
        click_action: 'FLUTTER_NOTIFICATION_CLICK',
        tag: `sender_${routingData.sender_id}`,
      },
    },
    // Routing metadata also rides on the legacy payload so a newer build
    // that has not re-registered its token yet can still navigate on tap.
    data: routingData,
  };
}
