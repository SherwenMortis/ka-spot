// Verification of the Google credential presented for account deletion.
//
// What is checked, and by whom
//   * Signature, issuer and expiry are established by google-auth-library's
//     `verifyIdToken`, which is Google's own supported server-side verifier: it
//     fetches the rotating JWKS from Google, checks the RSA signature, checks
//     `iss` against the canonical Google issuers, checks `aud` against the
//     audience we pass, and rejects an expired or not-yet-valid token. This
//     replaces an earlier `oauth2.googleapis.com/tokeninfo` call, which also
//     authenticates the token (Google validates it) but adds a network
//     round-trip, a rate limit, and a second endpoint that has to be trusted.
//   * The binding to this KaSpot account is established here, and only here:
//     `sub` must equal the `sub` recorded on the caller's linked Google
//     identity. A token for a different Google account — including one the
//     attacker controls — is a mismatch, not a login.
//
// Re-asserted locally even though the library checks them, because each is a
// security property this file should not silently lose on a dependency upgrade:
//   * `aud` must be exactly GOOGLE_WEB_CLIENT_ID (the token was minted for
//     another app otherwise).
//   * `iss` must be one of the two canonical Google issuers. This matters:
//     google-auth-library's default issuer list also admits the client's
//     `universeDomain` ("googleapis.com"), which is not an identity issuer.
//   * `exp` must still be in the future.
//   * `email_verified === false` is rejected; an account holder who has not
//     verified the address that identifies the link cannot delete through it.
//
// Not implemented, deliberately: a `nonce` claim. Google's native ID token flow
// has no request-bound nonce that this server could verify, and inventing one
// without a challenge round-trip would only look like replay protection. What
// this proves is control of the linked Google account on this device at this
// moment; the residual replay window is the token's lifetime.

import { OAuth2Client } from 'npm:google-auth-library@9';

export type GoogleVerdict = 'ok' | 'mismatch' | 'invalid' | 'configuration';

/// The claims this check needs. Everything else in the token is ignored.
export interface GoogleTokenPayload {
  sub?: string;
  aud?: string;
  iss?: string;
  exp?: number;
  email_verified?: boolean | string;
}

/// Injected so the claim-binding rules can be tested without Google: production
/// passes [createGoogleVerifier], tests pass a stub that returns a payload.
export type GoogleTokenVerifier = (
  idToken: string,
  audience: string,
) => Promise<GoogleTokenPayload | null>;

/// Google may serialise the issuer with or without the scheme.
export const GOOGLE_ISSUERS: ReadonlySet<string> = new Set([
  'accounts.google.com',
  'https://accounts.google.com',
]);

/// Google's supported server-side verifier, bound to [audience].
export function createGoogleVerifier(): GoogleTokenVerifier {
  return async (idToken, audience) => {
    const client = new OAuth2Client(audience);
    try {
      const ticket = await client.verifyIdToken({ idToken, audience });
      const payload = ticket.getPayload();
      if (!payload) return null;
      return {
        sub: payload.sub,
        aud: typeof payload.aud === 'string' ? payload.aud : undefined,
        iss: payload.iss,
        exp: payload.exp,
        email_verified: payload.email_verified,
      };
    } catch {
      // A bad signature, a foreign issuer, a token minted for another client,
      // an expired token and a malformed token all land here. None of them is
      // distinguishable to the caller, and none is logged: the token itself is
      // the sensitive part.
      return null;
    }
  };
}

/// Decides whether a verified token proves ownership of [expectedSubject].
export async function verifyGoogleIdentity(input: {
  idToken: string;
  expectedAudience: string | undefined;
  expectedSubject: string | null;
  verify: GoogleTokenVerifier;
  now?: () => number;
}): Promise<GoogleVerdict> {
  const audience = input.expectedAudience;
  if (!audience) return 'configuration';

  const subject = input.expectedSubject;
  // The account has no linked Google identity: there is nothing a token could
  // match, so this is a mismatch rather than a verification failure.
  if (!subject) return 'mismatch';

  const payload = await input.verify(input.idToken, audience);
  if (!payload) return 'invalid';

  if (payload.aud !== audience) return 'mismatch';
  if (typeof payload.iss !== 'string' || !GOOGLE_ISSUERS.has(payload.iss)) {
    return 'invalid';
  }
  if (typeof payload.sub !== 'string' || payload.sub !== subject) {
    return 'mismatch';
  }
  if (payload.email_verified === false || payload.email_verified === 'false') {
    return 'invalid';
  }

  const expiresAt = Number(payload.exp);
  const now = (input.now ?? Date.now)();
  if (!Number.isFinite(expiresAt) || expiresAt * 1000 <= now) return 'invalid';

  return 'ok';
}
