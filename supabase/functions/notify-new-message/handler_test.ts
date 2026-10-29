// Runtime tests for the notify-new-message request pipeline. Run with:
//   npx deno@2 test --allow-env supabase/functions
//
// These call handle() — the same function Deno.serve exposes — so they exercise
// the real order of checks: method, caller authentication, body parsing, event
// validation, authoritative lookup, eligibility, send. The store and the push
// sender are spies, which lets a test assert not only the response but that no
// database read and no push happened at all.

import {
  type DeviceToken,
  handle,
  type HandlerDeps,
  MAX_BODY_BYTES,
  type MessageRecord,
  type WebhookStore,
} from './handler.ts';
import { SECRET_HEADER } from './webhook_secret.ts';

const SECRET = 'a'.repeat(64); // stands in for `openssl rand -hex 32`
const MESSAGE_ID = '4f0d6f1e-8a1b-4c2d-9e3f-5a6b7c8d9e0f';
const SENDER_ID = '0b9be6d2-1111-4222-8333-444455556666';
const RECIPIENT_ID = 'a1b2c3d4-1111-4222-8333-444455556666';
const ATTACKER_ID = 'deadbeef-1111-4222-8333-444455556666';

const MESSAGE: MessageRecord = {
  id: MESSAGE_ID,
  sender_id: SENDER_ID,
  recipient_id: RECIPIENT_ID,
};

// ── Harness ────────────────────────────────────────────────────────────────

interface Harness {
  store: SpyStore;
  push: SpyPush;
  /// How many times the dependency factory ran. Any value above 0 before the
  /// caller is authenticated would mean the boundary leaked.
  depsCalls: () => number;
  call: (
    body: unknown,
    options?: {
      method?: string;
      secret?: string | null;
      authorization?: string;
      rawBody?: string;
      streamBody?: ReadableStream<Uint8Array>;
      extraHeaders?: Record<string, string>;
    },
  ) => Promise<Response>;
}

class SpyStore implements WebhookStore {
  messageCalls: string[] = [];
  connectionCalls: Array<[string, string]> = [];
  preferenceCalls: string[] = [];
  tokenCalls: string[] = [];

  constructor(
    private readonly options: {
      message?: MessageRecord | null;
      connected?: boolean;
      notificationsEnabled?: boolean;
      tokens?: DeviceToken[];
      throwOn?: 'message' | 'connection' | 'preference' | 'tokens';
    } = {},
  ) {}

  message(id: string): Promise<MessageRecord | null> {
    this.messageCalls.push(id);
    if (this.options.throwOn === 'message') {
      return Promise.reject(new Error('db down'));
    }
    return Promise.resolve(
      this.options.message === undefined
        ? { ...MESSAGE }
        : this.options.message,
    );
  }

  areConnected(a: string, b: string): Promise<boolean> {
    this.connectionCalls.push([a, b]);
    if (this.options.throwOn === 'connection') {
      return Promise.reject(new Error('db down'));
    }
    return Promise.resolve(this.options.connected ?? true);
  }

  notificationsEnabled(userId: string): Promise<boolean> {
    this.preferenceCalls.push(userId);
    if (this.options.throwOn === 'preference') {
      return Promise.reject(new Error('db down'));
    }
    return Promise.resolve(this.options.notificationsEnabled ?? true);
  }

  deviceTokens(userId: string): Promise<DeviceToken[]> {
    this.tokenCalls.push(userId);
    if (this.options.throwOn === 'tokens') {
      return Promise.reject(new Error('db down'));
    }
    return Promise.resolve(
      this.options.tokens ??
        [{ token: 'device-token', supportsDataOnly: true }],
    );
  }
}

class SpyPush {
  calls: Array<{ target: DeviceToken; routing: Record<string, string> }> = [];

  send(target: DeviceToken, routing: Record<string, string>): Promise<void> {
    this.calls.push({ target, routing });
    return Promise.resolve();
  }
}

function harness(
  storeOptions: ConstructorParameters<typeof SpyStore>[0] = {},
  config: { secret: string | undefined } = { secret: SECRET },
): Harness {
  const store = new SpyStore(storeOptions);
  const push = new SpyPush();
  let depsCalls = 0;

  return {
    store,
    push,
    depsCalls: () => depsCalls,
    call: (body, options = {}) => {
      const headers: Record<string, string> = {
        'content-type': 'application/json',
        ...options.extraHeaders,
      };
      if (options.secret !== null) {
        headers[SECRET_HEADER] = options.secret ?? SECRET;
      }
      if (options.authorization) {
        headers['authorization'] = options.authorization;
      }
      const method = options.method ?? 'POST';
      const request = new Request('http://localhost/notify-new-message', {
        method,
        headers,
        // GET/HEAD requests cannot carry a body at all; the method check must
        // be reachable without one.
        body: method === 'GET' || method === 'HEAD'
          ? undefined
          : options.streamBody ?? options.rawBody ?? JSON.stringify(body),
      });
      return handle(request, config, () => {
        depsCalls++;
        return { store, push } as HandlerDeps;
      });
    },
  };
}

function insertEvent(record: Record<string, unknown>) {
  return {
    type: 'INSERT',
    table: 'circle_messages',
    schema: 'public',
    record: {
      id: MESSAGE_ID,
      sender_id: SENDER_ID,
      recipient_id: RECIPIENT_ID,
      content: 'meet me at the clinic at 7',
      created_at: '2026-10-23T10:00:00Z',
      ...record,
    },
    old_record: null,
  };
}

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

/// No response may echo the secret, the message text, or an identifier.
/// Consumes the body; the returned text is what the caller should parse.
async function assertNothingLeaked(response: Response): Promise<string> {
  const text = await response.text();
  assert(!text.includes(SECRET), 'response leaked the webhook secret');
  assert(
    !text.includes('meet me at the clinic'),
    'response leaked message content',
  );
  assert(!text.includes(MESSAGE_ID), 'response leaked a message id');
  assert(!text.includes(SENDER_ID), 'response leaked a sender id');
  assert(!text.includes(RECIPIENT_ID), 'response leaked a recipient id');
  return text;
}

// ── Authentication boundary ────────────────────────────────────────────────

Deno.test('rejects a request with no credential before doing any work', async () => {
  const h = harness();
  const response = await h.call(insertEvent({}), { secret: null });

  assertEquals(response.status, 401, 'status');
  await assertNothingLeaked(response);
  assertEquals(h.depsCalls(), 0, 'dependency factory must not run');
  assertEquals(h.store.messageCalls, [], 'no message lookup');
  assertEquals(h.push.calls, [], 'no push');
});

Deno.test('rejects an empty credential', async () => {
  const h = harness();
  const response = await h.call(insertEvent({}), { secret: '' });

  assertEquals(response.status, 401, 'status');
  assertEquals(h.depsCalls(), 0, 'dependency factory must not run');
});

Deno.test('rejects a wrong secret of the same length', async () => {
  const h = harness();
  const response = await h.call(insertEvent({}), { secret: 'b'.repeat(64) });

  assertEquals(response.status, 401, 'status');
  assertEquals(h.depsCalls(), 0, 'dependency factory must not run');
  assertEquals(h.push.calls, [], 'no push');
});

Deno.test('rejects a wrong secret with a valid prefix', async () => {
  // A prefix must not be enough: the comparison covers every byte.
  const h = harness();
  const response = await h.call(insertEvent({}), {
    secret: `${SECRET.slice(0, 63)}b`,
  });

  assertEquals(response.status, 401, 'status');
  assertEquals(h.depsCalls(), 0, 'dependency factory must not run');
});

Deno.test('rejects a request that only carries the Authorization header form', async () => {
  const h = harness();
  const response = await h.call(insertEvent({}), {
    secret: null,
    authorization: `Basic ${SECRET}`,
  });

  assertEquals(response.status, 401, 'status');
  assertEquals(h.depsCalls(), 0, 'dependency factory must not run');
});

Deno.test('accepts the documented Authorization: Bearer form', async () => {
  const h = harness();
  const response = await h.call(insertEvent({}), {
    secret: null,
    authorization: `Bearer ${SECRET}`,
  });

  assertEquals(response.status, 200, 'status');
  assertEquals(h.push.calls.length, 1, 'one push');
});

Deno.test('fails closed when this deployment has no usable secret', async () => {
  for (const secret of [undefined, '', 'too-short']) {
    const h = harness({}, { secret });
    const response = await h.call(insertEvent({}), { secret: null });

    assertEquals(response.status, 500, `status for secret=${secret}`);
    assertEquals(
      (await response.json()).error,
      'server_configuration',
      'error code',
    );
    assertEquals(h.depsCalls(), 0, 'dependency factory must not run');
    assertEquals(h.push.calls, [], 'no push');
  }
});

Deno.test('rejects a non-POST method before anything else', async () => {
  for (const method of ['GET', 'PUT', 'DELETE', 'OPTIONS']) {
    const h = harness();
    const response = await h.call(insertEvent({}), { method });
    assertEquals(response.status, 405, `status for ${method}`);
    assertEquals(
      h.depsCalls(),
      0,
      `dependency factory must not run for ${method}`,
    );
  }
});

// ── Payload validation ─────────────────────────────────────────────────────

Deno.test('rejects invalid JSON without leaking the body', async () => {
  const h = harness();
  const response = await h.call(null, {
    rawBody:
      '{"type":"INSERT","record":{"content":"meet me at the clinic at 7"',
  });

  assertEquals(response.status, 400, 'status');
  await assertNothingLeaked(response);
  assertEquals(h.depsCalls(), 0, 'dependency factory must not run');
});

Deno.test('rejects a JSON body that is not an object', async () => {
  for (const raw of ['null', '"INSERT"', '[]', '42']) {
    const h = harness();
    const response = await h.call(null, { rawBody: raw });
    assertEquals(response.status, 400, `status for ${raw}`);
    assertEquals(
      h.depsCalls(),
      0,
      `dependency factory must not run for ${raw}`,
    );
  }
});

Deno.test('ignores unrelated tables, events and schemas', async () => {
  const unrelated = [
    { ...insertEvent({}), table: 'profiles' },
    { ...insertEvent({}), table: 'device_tokens' },
    { ...insertEvent({}), type: 'UPDATE' },
    { ...insertEvent({}), type: 'DELETE' },
    { ...insertEvent({}), schema: 'auth' },
  ];

  for (const event of unrelated) {
    const h = harness();
    const response = await h.call(event);

    assertEquals(response.status, 200, 'status');
    assertEquals((await response.json()).result, 'ignored', 'result');
    assertEquals(h.depsCalls(), 0, 'dependency factory must not run');
    assertEquals(h.push.calls, [], 'no push');
  }
});

Deno.test('rejects a record without a usable message id', async () => {
  const bad = [
    { id: '' },
    { id: 'not-a-uuid' },
    { id: 42 },
    { id: null },
  ];

  for (const record of bad) {
    const h = harness();
    const response = await h.call(insertEvent(record));

    assertEquals(response.status, 400, `status for ${JSON.stringify(record)}`);
    assertEquals(h.depsCalls(), 0, 'dependency factory must not run');
    assertEquals(h.push.calls, [], 'no push');
  }
});

Deno.test('rejects an oversized body without reading it', async () => {
  const h = harness();
  const response = await h.call(insertEvent({}), {
    extraHeaders: { 'content-length': String(MAX_BODY_BYTES + 1) },
  });

  assertEquals(response.status, 413, 'status');
  assertEquals(h.push.calls, [], 'no push');
});

Deno.test('stops a chunked body that exceeds the cap', async () => {
  // No content-length to trust: the stream itself has to be counted, or a
  // caller could stream far more than the documented maximum into the isolate.
  const chunk = new Uint8Array(16 * 1024);
  let sent = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(controller) {
      if (sent > MAX_BODY_BYTES) {
        controller.close();
        return;
      }
      sent += chunk.byteLength;
      controller.enqueue(chunk);
    },
  });

  const h = harness();
  const response = await h.call(insertEvent({}), { streamBody: stream });

  assertEquals(response.status, 413, 'status');
  assertEquals(h.depsCalls(), 0, 'dependency factory must not run');
  assertEquals(h.push.calls, [], 'no push');
});

// ── Authoritative lookup and recipient targeting ───────────────────────────

Deno.test('does not push for a message that does not exist', async () => {
  const h = harness({ message: null });
  const response = await h.call(insertEvent({}));

  assertEquals(response.status, 200, 'status');
  assertEquals((await response.json()).result, 'unknown_message', 'result');
  assertEquals(h.store.messageCalls, [MESSAGE_ID], 'looked up the body id');
  assertEquals(h.store.tokenCalls, [], 'no token lookup');
  assertEquals(h.push.calls, [], 'no push');
});

Deno.test('a forged recipient in the body cannot redirect the push', async () => {
  // The body claims the message is for an attacker-chosen user. Routing must
  // come from the stored row, so the real recipient is the only device queried.
  const h = harness();
  const response = await h.call(
    insertEvent({ recipient_id: ATTACKER_ID, sender_id: ATTACKER_ID }),
  );

  assertEquals(response.status, 200, 'status');
  assertEquals((await response.json()).result, 'sent', 'result');
  assertEquals(
    h.store.tokenCalls,
    [RECIPIENT_ID],
    'tokens must be looked up for the stored recipient only',
  );
  assertEquals(h.push.calls.length, 1, 'one push');
  assertEquals(
    h.push.calls[0].routing.sender_id,
    SENDER_ID,
    'routing sender comes from the stored row',
  );
  assert(
    !JSON.stringify(h.push.calls).includes(ATTACKER_ID),
    'the forged id must not appear anywhere in the outgoing push',
  );
});

Deno.test('does not push after the connection is gone', async () => {
  const h = harness({ connected: false });
  const response = await h.call(insertEvent({}));

  assertEquals(response.status, 200, 'status');
  assertEquals((await response.json()).result, 'not_connected', 'result');
  assertEquals(h.store.preferenceCalls, [], 'preferences not consulted');
  assertEquals(h.push.calls, [], 'no push');
});

Deno.test('does not push when the recipient disabled notifications', async () => {
  const h = harness({ notificationsEnabled: false });
  const response = await h.call(insertEvent({}));

  assertEquals(response.status, 200, 'status');
  assertEquals(
    (await response.json()).result,
    'notifications_disabled',
    'result',
  );
  assertEquals(h.store.tokenCalls, [], 'no token lookup');
  assertEquals(h.push.calls, [], 'no push');
});

Deno.test('reports no tokens without failing the webhook', async () => {
  const h = harness({ tokens: [] });
  const response = await h.call(insertEvent({}));

  assertEquals(response.status, 200, 'status');
  assertEquals((await response.json()).result, 'no_tokens', 'result');
  assertEquals(h.push.calls, [], 'no push');
});

// ── Delivery ───────────────────────────────────────────────────────────────

Deno.test('a valid event sends one generic push per device token', async () => {
  const h = harness({
    tokens: [
      { token: 'token-a', supportsDataOnly: true },
      { token: 'token-b', supportsDataOnly: false },
    ],
  });
  const response = await h.call(insertEvent({}));

  assertEquals(response.status, 200, 'status');
  assertEquals((await response.json()).result, 'sent', 'result');
  assertEquals(h.push.calls.length, 2, 'one push per token');
  assertEquals(
    h.push.calls.map((call) => call.target.token),
    ['token-a', 'token-b'],
    'each token targeted once',
  );
});

Deno.test('the routing identifiers stay correct and content-free', async () => {
  const h = harness();
  await h.call(insertEvent({}));

  const routing = h.push.calls[0].routing;
  assertEquals(Object.keys(routing).sort(), [
    'body',
    'message_id',
    'sender_id',
    'title',
    'type',
  ], 'routing keys');
  assertEquals(routing.type, 'circle_message', 'type');
  assertEquals(routing.sender_id, SENDER_ID, 'sender id');
  assertEquals(routing.message_id, MESSAGE_ID, 'message id');
  assertEquals(routing.title, 'New message in KaSpot', 'generic title');
  assertEquals(
    routing.body,
    'Open KaSpot to view your message',
    'generic body',
  );

  const serialized = JSON.stringify(h.push.calls);
  for (const forbidden of ['meet me at the clinic', 'display_name', 'avatar']) {
    assert(
      !serialized.includes(forbidden),
      `push payload must not contain ${forbidden}`,
    );
  }
});

Deno.test('a failing device does not fail the webhook', async () => {
  const h = harness();
  // Replace the spy with one that rejects for the first token only.
  const original = h.push.send.bind(h.push);
  let call = 0;
  h.push.send = async (target, routing) => {
    call++;
    if (call === 1) throw new Error('fcm down');
    await original(target, routing);
  };

  const response = await h.call(insertEvent({}));

  assertEquals(response.status, 200, 'status');
  assertEquals((await response.json()).result, 'sent', 'result');
});

// ── Failure disclosure ─────────────────────────────────────────────────────

Deno.test('an internal failure returns a generic body and leaks nothing', async () => {
  for (
    const throwOn of ['message', 'connection', 'preference', 'tokens'] as const
  ) {
    const h = harness({ throwOn });
    const response = await h.call(insertEvent({}));

    assertEquals(response.status, 500, `status for ${throwOn}`);
    const text = await assertNothingLeaked(response);
    assertEquals(JSON.parse(text).error, 'internal', 'error code');
    assertEquals(h.push.calls, [], 'no push');
  }
});
