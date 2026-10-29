// Runtime tests for the two deletion security decisions. Run with:
//   npx deno@2 test --allow-env supabase/functions
//
// No external dependencies: the assertions are plain throws, so the suite runs
// offline and cannot break on a registry outage.

import { isUserNotFound, MAX_BODY_BYTES, readCredential } from './logic.ts';

function assert(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function assertEquals<T>(actual: T, expected: T, message: string): void {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(`${message}\n  expected: ${e}\n  actual:   ${a}`);
  }
}

function post(body: unknown, headers: Record<string, string> = {}): Request {
  return new Request('http://localhost/delete-account', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

// ── What counts as a credential ─────────────────────────────────────────────

Deno.test('readCredential: a password alone is accepted', async () => {
  const credential = await readCredential(post({ password: 'correct horse' }));
  assertEquals(
    credential,
    { password: 'correct horse' },
    'password credential',
  );
});

Deno.test('readCredential: a Google ID token alone is accepted', async () => {
  const credential = await readCredential(
    post({ google_id_token: 'ya29.token' }),
  );
  assertEquals(
    credential,
    { googleIdToken: 'ya29.token' },
    'google credential',
  );
});

Deno.test('readCredential: no credential is refused', async () => {
  assertEquals(await readCredential(post({})), null, 'empty object');
});

Deno.test('readCredential: two credentials at once are refused', async () => {
  // Accepting both would let a caller pick whichever check is weaker.
  const credential = await readCredential(
    post({ password: 'a', google_id_token: 'b' }),
  );
  assertEquals(credential, null, 'two credentials');
});

Deno.test('readCredential: a client-supplied identity is not a credential', async () => {
  // The whole point of the endpoint: these must never satisfy it, alone or
  // alongside a real credential that they could otherwise stand in for.
  const spoofed = [
    { user_id: '00000000-0000-0000-0000-000000000000' },
    { user_id: 'x', reauthenticated: true },
    { reauthenticated: true, last_sign_in_at: new Date().toISOString() },
    { sub: 'x', aud: 'y' },
    { access_token: 'x' },
    { provider_token: 'x' },
  ];
  for (const body of spoofed) {
    assertEquals(await readCredential(post(body)), null, JSON.stringify(body));
  }
});

Deno.test('readCredential: empty and oversized values are refused', async () => {
  assertEquals(await readCredential(post({ password: '' })), null, 'empty');
  assertEquals(
    await readCredential(post({ password: 'a'.repeat(1025) })),
    null,
    'password too long',
  );
  assertEquals(
    await readCredential(post({ google_id_token: 'a'.repeat(4097) })),
    null,
    'token too long',
  );
});

Deno.test('readCredential: a non-string credential is refused', async () => {
  // A number/boolean/object must not be coerced into a credential.
  for (const value of [123, true, { toString: 1 }, ['a'], null]) {
    assertEquals(
      await readCredential(post({ password: value })),
      null,
      `password=${JSON.stringify(value)}`,
    );
  }
});

Deno.test('readCredential: a malformed or non-object body is refused', async () => {
  assertEquals(await readCredential(post('not json')), null, 'invalid json');
  assertEquals(await readCredential(post('"a string"')), null, 'json string');
  assertEquals(await readCredential(post('null')), null, 'json null');
  assertEquals(await readCredential(post('[]')), null, 'json array');
});

Deno.test('readCredential: a declared oversized body is refused unread', async () => {
  const credential = await readCredential(
    post({ password: 'a' }, { 'content-length': String(MAX_BODY_BYTES + 1) }),
  );
  assertEquals(credential, null, 'oversized declaration');
});

// ── What counts as "the account is already gone" ────────────────────────────

Deno.test('isUserNotFound: a 404 is the only "already gone" signal', () => {
  assert(isUserNotFound({ status: 404 }), 'status 404');
  assert(isUserNotFound({ code: '404' }), 'code 404');
  assert(
    isUserNotFound({ code: 'user_not_found' }),
    'error_code user_not_found',
  );
  assert(
    isUserNotFound({
      status: 404,
      code: 'user_not_found',
      message: 'User not found',
    }),
    'full GoTrue error',
  );
});

Deno.test('isUserNotFound: every other failure is NOT "already gone"', () => {
  // Reporting an unrecognised failure as gone would turn a failed deletion into
  // a success response, which is the one outcome this endpoint must never fake.
  const notGone: unknown[] = [
    undefined,
    null,
    {},
    { status: 500, message: 'Database error deleting user' },
    { status: 400, code: 'bad_json' },
    { code: 'unexpected_failure' },
    { message: 'User not found' }, // message alone is not a status
    'user_not_found',
    404,
  ];
  for (const error of notGone) {
    assertEquals(
      isUserNotFound(error),
      false,
      JSON.stringify(error) ?? 'undefined',
    );
  }
});
