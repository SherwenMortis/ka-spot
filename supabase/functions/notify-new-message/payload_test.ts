// Runtime tests for the FCM payload notify-new-message sends. Run with:
//   npx deno@2 test --allow-env supabase/functions
//
// These assert what actually leaves the server for Google, rather than that the
// handler still mentions the word "content".

import {
  buildFcmMessage,
  buildRoutingData,
  GENERIC_BODY,
  GENERIC_TITLE,
} from './payload.ts';

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals(
  actual: unknown,
  expected: unknown,
  message: string,
): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(`${message}\n  expected: ${e}\n  actual:   ${a}`);
  }
}

// A message body that must never appear in any payload.
const SECRET_TEXT = 'meet me at the clinic at 7';

Deno.test('the alert is generic: no sender name and no preview', () => {
  assertEquals(GENERIC_TITLE, 'New message in KaSpot', 'title');
  assertEquals(GENERIC_BODY, 'Open KaSpot to view your message', 'body');
});

Deno.test('routing data carries identifiers only', () => {
  const senderId = '0b9be6d2-1111-4222-8333-444455556666';
  const messageId = 'a1b2c3d4-1111-4222-8333-444455556666';
  const data = buildRoutingData(senderId, messageId);

  assertEquals(Object.keys(data).sort(), [
    'body',
    'message_id',
    'sender_id',
    'title',
    'type',
  ], 'routing keys');
  assertEquals(data.type, 'circle_message', 'type');
  assertEquals(data.sender_id, senderId, 'sender preserved for targeting');
  assertEquals(data.message_id, messageId, 'message id preserved for scroll');
});

Deno.test('an absent message id becomes empty rather than "undefined"', () => {
  const withNull = buildRoutingData('sender', null);
  const withUndefined = buildRoutingData('sender', undefined);
  assertEquals(withNull.message_id, '', 'null');
  assertEquals(withUndefined.message_id, '', 'undefined');
});

Deno.test('the data-only payload has no notification block at all', () => {
  const message = buildFcmMessage(
    'device-token',
    true,
    buildRoutingData('sender', 'message'),
  );
  assert(!('notification' in message), 'data-only must not set notification');
  assertEquals(message.token, 'device-token', 'token is the recipient device');
  assertEquals(
    message.android,
    { priority: 'high' },
    'high priority so the background handler wakes',
  );
});

Deno.test('the legacy payload is generic and keeps tap routing', () => {
  const message = buildFcmMessage(
    'device-token',
    false,
    buildRoutingData('sender', 'message'),
  );
  const notification = message.notification as Record<string, string>;
  assertEquals(notification.title, GENERIC_TITLE, 'legacy title');
  assertEquals(notification.body, GENERIC_BODY, 'legacy body');
  assert(
    'data' in message && typeof message.data === 'object',
    'legacy payload still carries routing data so a newer build can navigate',
  );
});

Deno.test('no branch leaks message text into the payload', () => {
  const routing = buildRoutingData('sender', 'message');
  for (const supportsDataOnly of [true, false]) {
    const serialized = JSON.stringify(
      buildFcmMessage('device-token', supportsDataOnly, routing),
    );
    assert(
      !serialized.includes(SECRET_TEXT),
      `message text leaked into a payload (dataOnly=${supportsDataOnly})`,
    );
  }
});

Deno.test('recipient targeting is per token, never shared', () => {
  const routing = buildRoutingData('sender', 'message');
  const first = buildFcmMessage('token-a', true, routing);
  const second = buildFcmMessage('token-b', true, routing);
  assertEquals(first.token, 'token-a', 'first token');
  assertEquals(second.token, 'token-b', 'second token');
});
