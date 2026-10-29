// Request pipeline for notify-new-message, kept free of Deno.serve and of any
// network client so the security boundary itself can be executed by `deno test`.
//
// Order matters and is asserted by handler_test.ts:
//   1. method        -> 405
//   2. caller auth    -> 500 if this deployment has no usable secret, 401 if the
//                       caller did not present it. Nothing else has happened at
//                       this point: no body read, no database client, no push.
//   3. body size/JSON  -> 413 / 400
//   4. event shape     -> 200 ignored for anything that is not an INSERT on
//                       public.circle_messages, 400 for a malformed record
//   5. authoritative lookup -> the message row decides who is notified. The
//                       caller's `record.sender_id` / `record.recipient_id` are
//                       never used for routing, so a forged body cannot aim a
//                       push at an arbitrary user.
//   6. eligibility      -> still-connected pair, recipient preference, tokens
//   7. send             -> one generic message per registered device
//
// Response bodies never echo ids, tokens, message content or the secret.

import { buildRoutingData } from './payload.ts';
import {
  MIN_SECRET_LENGTH,
  readPresentedSecret,
  secretsMatch,
} from './webhook_secret.ts';

/// The columns this pipeline actually needs, read from the database rather than
/// from the webhook body.
export interface MessageRecord {
  id: string;
  sender_id: string;
  recipient_id: string;
}

export interface DeviceToken {
  token: string;
  supportsDataOnly: boolean;
}

export interface WebhookStore {
  message(id: string): Promise<MessageRecord | null>;
  areConnected(a: string, b: string): Promise<boolean>;
  notificationsEnabled(userId: string): Promise<boolean>;
  deviceTokens(userId: string): Promise<DeviceToken[]>;
}

export interface PushSender {
  send(target: DeviceToken, routing: Record<string, string>): Promise<void>;
}

/// Everything the pipeline needs once the caller is authenticated. Built lazily
/// so an unauthenticated request never reaches a database client or FCM.
export interface HandlerDeps {
  store: WebhookStore;
  push: PushSender;
}

/// Largest accepted body. A circle_messages row is far below this; the cap keeps
/// a hostile caller from streaming megabytes into the isolate.
export const MAX_BODY_BYTES = 64 * 1024;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

/// Reads the body, refusing more than [MAX_BODY_BYTES] however the caller
/// frames it. A declared `content-length` is checked first because it is free,
/// but a chunked request can omit or understate it, so the stream itself is
/// counted as well. Returns null when the cap was exceeded.
async function readLimitedBody(req: Request): Promise<string | null> {
  if (!req.body) return '';

  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value) continue;
      total += value.byteLength;
      if (total > MAX_BODY_BYTES) return null;
      chunks.push(value);
    }
  } finally {
    try {
      reader.releaseLock();
    } catch {
      // Nothing to release: the stream is already closed or errored.
    }
  }

  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(merged);
}

/// Handles one webhook request.
///
/// [createDeps] is a factory rather than a value so that authentication and
/// event validation happen before any client exists. If it throws (a missing
/// server secret), the caller gets a generic 500 and the failure is logged
/// without request detail.
export async function handle(
  req: Request,
  config: { secret: string | undefined },
  createDeps: () => HandlerDeps,
): Promise<Response> {
  try {
    // 1. Only a POST can carry a database event.
    if (req.method !== 'POST') {
      return json({ error: 'method_not_allowed' }, 405);
    }

    // 2. Authenticate the caller before touching anything else.
    const expected = config.secret;
    if (!expected || expected.length < MIN_SECRET_LENGTH) {
      // Distinct from 401 on purpose: this is a broken deployment, not a
      // forged request, and it must be obvious in the function logs.
      console.error(
        `notify-new-message: KASPOT_WEBHOOK_SECRET is unset or shorter than ${MIN_SECRET_LENGTH} characters; refusing every request`,
      );
      return json({ error: 'server_configuration' }, 500);
    }

    const presented = readPresentedSecret(req);
    if (!presented || !(await secretsMatch(presented, expected))) {
      // Nothing about the request is logged or echoed: it may be a forgery, and
      // the body has not been read.
      return json({ error: 'unauthorized' }, 401);
    }

    // 3. Size cap, then parse.
    const declaredLength = Number(req.headers.get('content-length') ?? '0');
    if (
      Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES
    ) {
      return json({ error: 'payload_too_large' }, 413);
    }

    const raw = await readLimitedBody(req);
    if (raw === null) return json({ error: 'payload_too_large' }, 413);

    let body: unknown;
    try {
      body = JSON.parse(raw);
    } catch {
      return json({ error: 'invalid_payload' }, 400);
    }

    const event = asRecord(body);
    if (!event) return json({ error: 'invalid_payload' }, 400);

    // 4. Only an INSERT on public.circle_messages is ours. Anything else is
    // acknowledged so the sender does not retry, and is never acted on.
    const schema = event.schema;
    if (
      event.type !== 'INSERT' ||
      event.table !== 'circle_messages' ||
      (typeof schema === 'string' && schema !== 'public')
    ) {
      return json({ result: 'ignored' }, 200);
    }

    const record = asRecord(event.record);
    const messageId = record?.id;
    if (typeof messageId !== 'string' || !UUID.test(messageId)) {
      return json({ error: 'invalid_payload' }, 400);
    }

    // 5. From here on a database client is needed, and only from here on.
    const { store, push } = createDeps();

    const message = await store.message(messageId);
    if (!message) {
      // Deleted between INSERT and delivery, or a body naming a message that
      // never existed. Either way there is nobody to notify and nothing to
      // report to an unauthenticated caller.
      return json({ result: 'unknown_message' }, 200);
    }
    if (message.sender_id === message.recipient_id) {
      // The table forbids this (is_accepted_connection requires distinct
      // participants); a row like this means the event is not trustworthy.
      return json({ error: 'invalid_payload' }, 400);
    }

    // 6. Eligibility, in the order that avoids the most work.
    if (!(await store.areConnected(message.sender_id, message.recipient_id))) {
      // A connection removed after the message was sent: the recipient can no
      // longer read it, so there is nothing to open.
      return json({ result: 'not_connected' }, 200);
    }

    if (!(await store.notificationsEnabled(message.recipient_id))) {
      return json({ result: 'notifications_disabled' }, 200);
    }

    const tokens = await store.deviceTokens(message.recipient_id);
    if (tokens.length === 0) {
      return json({ result: 'no_tokens' }, 200);
    }

    // 7. Send. Routing identifiers come from the row, never from the body.
    const routing = buildRoutingData(message.sender_id, message.id);
    const results = await Promise.allSettled(
      tokens.map((target) => push.send(target, routing)),
    );

    const failed = results.filter((result) => result.status === 'rejected')
      .length;
    if (failed > 0) {
      // Counts only: a device token or a conversation id does not belong in a
      // log line.
      console.error(
        `notify-new-message: ${failed} of ${tokens.length} push sends failed`,
      );
    }
    return json({ result: 'sent' }, 200);
  } catch {
    // Deliberately not interpolating the error: a parse or client error can
    // embed request data, and none of it is safe to return or log here.
    console.error('notify-new-message: unexpected failure');
    return json({ error: 'internal' }, 500);
  }
}
