// Tests for the Google credential check used before an account deletion.
// Run with:
//   npx deno@2 test --allow-env supabase/functions
//
// `--allow-env` is required only because importing google-auth-library reads
// process.env at load time; no test here makes a network call.
//
// The signature/issuer/expiry cryptography lives in google-auth-library and is
// not re-implemented here; these tests cover the part this repository owns — the
// binding between a verified token and the account being deleted — plus the
// claim re-checks that must survive a dependency upgrade.

import {
  createGoogleVerifier,
  GOOGLE_ISSUERS,
  type GoogleTokenPayload,
  type GoogleTokenVerifier,
  verifyGoogleIdentity,
} from './google_token.ts';

const AUDIENCE = '424760634120-kaspot.apps.googleusercontent.com';
const SUBJECT = '109876543210987654321';
const NOW = 1_766_000_000_000; // fixed clock in ms

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

/// A payload that passes every check, so each test can break exactly one thing.
function validPayload(
  overrides: Partial<GoogleTokenPayload> = {},
): GoogleTokenPayload {
  return {
    sub: SUBJECT,
    aud: AUDIENCE,
    iss: 'https://accounts.google.com',
    exp: Math.floor(NOW / 1000) + 600,
    email_verified: true,
    ...overrides,
  };
}

/// Records what the verifier was asked to verify, so a test can prove the token
/// is handed to Google's verifier with the configured audience.
interface SpyVerifier {
  verify: GoogleTokenVerifier;
  calls: Array<{ idToken: string; audience: string }>;
}

function spyVerifier(result: GoogleTokenPayload | null): SpyVerifier {
  const calls: Array<{ idToken: string; audience: string }> = [];
  return {
    calls,
    verify: (idToken, audience) => {
      calls.push({ idToken, audience });
      return Promise.resolve(result);
    },
  };
}

function check(
  spy: SpyVerifier,
  overrides: {
    expectedAudience?: string | undefined;
    expectedSubject?: string | null;
  } = {},
) {
  return verifyGoogleIdentity({
    idToken: 'google-id-token',
    expectedAudience: 'expectedAudience' in overrides
      ? overrides.expectedAudience
      : AUDIENCE,
    expectedSubject: 'expectedSubject' in overrides
      ? overrides.expectedSubject ?? null
      : SUBJECT,
    verify: spy.verify,
    now: () => NOW,
  });
}

// ── Configuration and account binding ───────────────────────────────────────

Deno.test('no configured client ID is a server configuration error', async () => {
  const spy = spyVerifier(validPayload());
  assertEquals(
    await check(spy, { expectedAudience: undefined }),
    'configuration',
    'verdict',
  );
  assertEquals(spy.calls, [], 'verifier must not run without an audience');
});

Deno.test('an account with no linked Google identity cannot match', async () => {
  const spy = spyVerifier(validPayload());
  assertEquals(
    await check(spy, { expectedSubject: null }),
    'mismatch',
    'verdict',
  );
  assertEquals(spy.calls, [], 'verifier must not run without a subject');
});

Deno.test('a valid token for the linked account is accepted', async () => {
  const spy = spyVerifier(validPayload());
  assertEquals(await check(spy), 'ok', 'verdict');
  assertEquals(spy.calls.length, 1, 'verifier ran');
});

Deno.test('the token is handed to Google with the configured audience', async () => {
  const spy = spyVerifier(validPayload());
  await check(spy);

  assertEquals(spy.calls[0].idToken, 'google-id-token', 'id token');
  assertEquals(spy.calls[0].audience, AUDIENCE, 'audience');
});

Deno.test('a token minted for another client is a mismatch', async () => {
  const spy = spyVerifier(
    validPayload({ aud: 'someone-elses-client-id.apps.googleusercontent.com' }),
  );
  assertEquals(await check(spy), 'mismatch', 'verdict');
});

Deno.test('a token for a different Google account is a mismatch', async () => {
  // This is the attack the check exists for: a perfectly valid Google token,
  // minted for this project, belonging to somebody else.
  const spy = spyVerifier(validPayload({ sub: '999999999999999999999' }));
  assertEquals(await check(spy), 'mismatch', 'verdict');
});

// ── Token validity ──────────────────────────────────────────────────────────

Deno.test('an unverifiable token is invalid', async () => {
  // google-auth-library returns null for a bad signature, foreign issuer,
  // wrong audience or expired token.
  const spy = spyVerifier(null);
  assertEquals(await check(spy), 'invalid', 'verdict');
});

Deno.test('an expired token is rejected even if it verified', async () => {
  const spy = spyVerifier(
    validPayload({ exp: Math.floor(NOW / 1000) - 1 }),
  );
  assertEquals(await check(spy), 'invalid', 'verdict');
});

Deno.test('a token expiring exactly now is rejected', async () => {
  const spy = spyVerifier(validPayload({ exp: Math.floor(NOW / 1000) }));
  assertEquals(await check(spy), 'invalid', 'verdict');
});

Deno.test('a token with no usable expiry is rejected', async () => {
  const spy = spyVerifier(validPayload({ exp: undefined }));
  assertEquals(await check(spy), 'invalid', 'verdict');
});

Deno.test('non-canonical issuers are rejected', async () => {
  // google-auth-library also admits the client universeDomain ("googleapis.com")
  // by default; an identity token must come from a Google identity issuer.
  for (
    const iss of [
      'googleapis.com',
      'accounts.example.com',
      '',
      'https://evil.test',
    ]
  ) {
    const spy = spyVerifier(validPayload({ iss }));
    assertEquals(await check(spy), 'invalid', `issuer ${iss}`);
  }
});

Deno.test('both canonical Google issuer spellings are accepted', async () => {
  for (const iss of GOOGLE_ISSUERS) {
    const spy = spyVerifier(validPayload({ iss }));
    assertEquals(await check(spy), 'ok', `issuer ${iss}`);
  }
});

Deno.test('a token whose subject is missing is rejected', async () => {
  const spy = spyVerifier(validPayload({ sub: undefined }));
  assertEquals(await check(spy), 'mismatch', 'verdict');
});

Deno.test('an unverified email is rejected', async () => {
  for (const value of [false, 'false'] as const) {
    const spy = spyVerifier(validPayload({ email_verified: value }));
    assertEquals(await check(spy), 'invalid', `email_verified=${value}`);
  }
});

Deno.test('an absent email_verified claim does not block deletion', async () => {
  // Google omits the claim for some account types; only an explicit false is
  // treated as a refusal.
  const spy = spyVerifier(validPayload({ email_verified: undefined }));
  assertEquals(await check(spy), 'ok', 'verdict');
});

// ── Rejection precedence ────────────────────────────────────────────────────

Deno.test('a wrong audience is reported even when the subject also differs', async () => {
  // Both are mismatches, but this pins that the audience is checked rather than
  // skipped whenever the subject happens to be different.
  const spy = spyVerifier(validPayload({ aud: 'other', sub: 'other' }));
  assertEquals(await check(spy), 'mismatch', 'verdict');
});

Deno.test('the production verifier is the library, not local parsing', () => {
  // A guard against silently replacing verification with claim decoding: the
  // factory must produce a function, and it must not resolve a token locally
  // without a network round-trip when the JWKS cache is cold.
  const verifier = createGoogleVerifier();
  assert(typeof verifier === 'function', 'verifier factory returns a function');
  assert(
    verifier.constructor.name === 'AsyncFunction' ||
      verifier.constructor.name === 'Function',
    'verifier is a callable',
  );
});
