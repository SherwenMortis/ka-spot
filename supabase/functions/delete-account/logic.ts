// Pure request-parsing and error-classification logic for delete-account.
//
// Kept out of index.ts so it can be exercised by `deno test` without starting
// the HTTP server: these two functions ARE the deletion security decisions
// (what counts as a credential, and what counts as "already deleted"), and a
// source-reading test cannot prove either one behaves correctly.

/// Verified credential attached to the request. Exactly one field is set.
export interface Credential {
  password?: string;
  googleIdToken?: string;
}

/// Largest body accepted. A password or an ID token is far below this; the cap
/// keeps a hostile caller from streaming megabytes into the isolate.
export const MAX_BODY_BYTES = 8 * 1024;

/// Reads exactly one credential from the body. Returns null when the body is
/// missing, malformed, oversized, or carries zero or two credentials.
/// The body is never echoed: it can contain a password.
export async function readCredential(req: Request): Promise<Credential | null> {
  const declaredLength = Number(req.headers.get('content-length') ?? '0');
  if (Number.isFinite(declaredLength) && declaredLength > MAX_BODY_BYTES) {
    return null;
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return null;
  }
  if (!body || typeof body !== 'object') return null;

  const record = body as Record<string, unknown>;
  const password = typeof record.password === 'string' ? record.password : null;
  const googleIdToken = typeof record.google_id_token === 'string'
    ? record.google_id_token
    : null;

  if ((password === null) === (googleIdToken === null)) return null;
  if (password !== null && (password.length === 0 || password.length > 1024)) {
    return null;
  }
  if (googleIdToken !== null && googleIdToken.length > 4096) return null;

  return {
    password: password ?? undefined,
    googleIdToken: googleIdToken ?? undefined,
  };
}

/// True only when the Admin API states that the id does not exist.
///
/// Deliberately narrow: a false positive here would report a FAILED delete as a
/// finished one, so an unrecognised error is never treated as "gone". GoTrue
/// answers 404 with `error_code: "user_not_found"` and the SDK surfaces it as an
/// auth error whose `status` is 404.
export function isUserNotFound(error: unknown): boolean {
  if (!error || typeof error !== 'object') return false;
  const record = error as Record<string, unknown>;
  if (record.status === 404) return true;
  const code = String(record.code ?? record.error_code ?? '');
  return code === '404' || code === 'user_not_found';
}
