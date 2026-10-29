// Caller authentication for the notify-new-message webhook.
//
// The only legitimate caller is the Database Webhook on public.circle_messages.
// That caller is not a user, so it has no session JWT, and the project's anon
// key ships inside the mobile app — presenting it proves nothing. The endpoint
// is therefore configured with `verify_jwt = false` (supabase/config.toml) and
// authenticates every request here instead, against a dedicated high-entropy
// secret that exists only as an Edge Function secret and in the webhook's own
// header configuration.
//
// Why a dedicated secret rather than Supabase's documented `apikey` +
// `auth: 'secret'` flow: this value can do exactly one thing — call this
// endpoint once you already have the URL. The project secret key can do
// everything, so putting it in a trigger definition (where the docs note it
// becomes visible in database dumps) would hand a database-wide credential to
// a component that only needs to send one notification. Least privilege wins.
// The `apikey` mechanism was verified against the current docs and would be the
// right choice for a caller that already needs the project key; this one does
// not.
//
// Fail-closed rules, all deliberate:
//   * No secret configured            -> 500 server_configuration, never "open".
//   * Secret shorter than 32 chars    -> same, because a short secret is a
//                                        misconfiguration, not a credential.
//   * Missing / wrong / empty header  -> 401 unauthorized.
//   * The secret is never logged, never echoed, and never returned.

/// Header the Database Webhook must send. A custom header is used instead of
/// `Authorization` so the credential cannot be confused with (or stripped as)
/// a bearer token by any layer between pg_net and this handler.
export const SECRET_HEADER = 'x-kaspot-webhook-secret';

/// Second accepted spelling: `Authorization: Bearer <secret>`. Supported only
/// because some webhook configurations can set that header and not a custom
/// one; it is compared exactly like the header above.
export const AUTHORIZATION_HEADER = 'authorization';

/// A 32-character floor is 128 bits of entropy if the secret is random. Generate
/// with `openssl rand -hex 32` (64 hex characters) and store it only as the
/// KASPOT_WEBHOOK_SECRET Edge Function secret.
export const MIN_SECRET_LENGTH = 32;

/// The secret the caller presented, or null when it presented none.
///
/// The custom header wins when both are present, so an operator who sets both
/// cannot accidentally authenticate with a stale Authorization value.
export function readPresentedSecret(req: Request): string | null {
  const direct = (req.headers.get(SECRET_HEADER) ?? '').trim();
  if (direct.length > 0) return direct;

  const authorization = (req.headers.get(AUTHORIZATION_HEADER) ?? '').trim();
  if (authorization.length === 0) return null;
  const match = /^Bearer\s+(\S+)$/i.exec(authorization);
  return match ? match[1] : null;
}

/// Constant-time comparison of two secrets.
///
/// Both values are hashed first so the comparison always runs over 32 bytes:
/// comparing raw strings would leak the length of the configured secret through
/// timing, and would short-circuit on the first differing character.
export async function secretsMatch(
  presented: string,
  expected: string,
): Promise<boolean> {
  const [a, b] = await Promise.all([digest(presented), digest(expected)]);
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i] ^ b[i];
  return difference === 0;
}

async function digest(value: string): Promise<Uint8Array> {
  const bytes = new TextEncoder().encode(value);
  return new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
}
