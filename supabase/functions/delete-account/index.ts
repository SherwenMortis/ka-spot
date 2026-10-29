// Supabase Edge Function — delete-account
//
// Permanently deletes the CALLER'S account. Identity comes only from the
// verified access token — the request never carries a user id, so a caller
// cannot name someone else's account.
//
// What establishes eligibility
//   1. `auth.getUser(accessToken)` asks the auth server who the token belongs to
//      (not the token's own claims). An unauthenticated or expired token is 401.
//   2. A credential is verified for THIS request. The body carries exactly one:
//        { "password": "…" }        → checked with the sign-in service
//        { "google_id_token": "…" } → verified with Google and matched to the
//                                     caller's linked Google identity (sub)
//      A client-supplied user id, boolean, timestamp or "I reauthenticated"
//      claim is never accepted. There is no timestamp-only path: a recent
//      `last_sign_in_at` proves only that a session was minted recently, not
//      that the account holder asked for this deletion.
//
// Password proof
//   `signInWithPassword` is called HERE, on an anonymous client with no session
//   persistence, and the returned user id must equal the caller's. The password
//   is therefore verified by the auth server, not by the app. It is held only in
//   this request's memory: never logged, never echoed, never stored. The extra
//   session the check creates is not persisted anywhere; the account is deleted
//   immediately afterwards.
//   Trust surface: the password now transits this function (same Supabase
//   project and TLS boundary as the auth service it is checked against). That is
//   the deliberate cost of server-verifiable proof; the app no longer signs in
//   locally to "prove" anything.
//
// Google proof
//   The app obtains a fresh ID token from the native picker (it does not exchange
//   it with Supabase, so the current session is untouched) and sends it here.
//   The token is verified with google-auth-library's `verifyIdToken` — Google's
//   supported server-side verifier, which checks the RSA signature against
//   Google's JWKS, the issuer, the audience and the expiry — and the verified
//   `sub` must then equal the `sub` of the caller's linked Google identity.
//   This proves control of that Google account on this device at this moment.
//   It does NOT mean a password was re-entered — Google does not expose one —
//   and the app and policy say so rather than overstating it. Details, including
//   the claims re-asserted locally, are in google_token.ts.
//
// Deliberately not used: gotrue's `reauthenticate()`. In gotrue 2.27.3 it only
// asks the auth server to send a re-authentication OTP (`GET /reauthenticate`,
// returns void) and verifies nothing.
//
// Deletion and verification
//   Deletion uses the Admin API with the service-role key, which exists only in
//   this server environment. Every app table references auth.users with
//   `on delete cascade`; `verifyCleanup()` re-reads them and `forceCleanup()`
//   deletes any survivor explicitly before verifying again, so a missing cascade
//   or a partially applied schema is corrected rather than reported as success.
//   Storage: KaSpot keeps avatars in the profile row, not in a Storage bucket,
//   so there is no external object to remove. Re-check if that ever changes.
//
// Repeated calls: a second concurrent delete returns an error from the Admin
// API, so the handler re-reads the user; if the user is already gone the request
// continues as a cleanup check instead of reporting a false failure. "Already
// gone" has to be read from the re-read's 404: the Admin SDK answers a missing
// id with a null user AND an error, never with a null user and no error, so
// testing the user alone would classify every repeat as unconfirmed.
//
// STATUS: prepared. Deploying this function is a separate, approved step; the
// app reports a failed deletion (and keeps the session) while it is undeployed.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  createGoogleVerifier,
  type GoogleVerdict,
  verifyGoogleIdentity,
} from './google_token.ts';
import { isUserNotFound, readCredential } from './logic.ts';

/// True only when the sign-in service accepts [password] for [email] and the
/// account it returns is [expectedUserId]. Never logs or returns the password.
async function passwordBelongsTo(
  supabaseUrl: string,
  anonKey: string,
  email: string,
  password: string,
  expectedUserId: string,
): Promise<boolean> {
  const authClient = createClient(supabaseUrl, anonKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
    },
  });
  try {
    const { data, error } = await authClient.auth.signInWithPassword({
      email,
      password,
    });
    return !error && Boolean(data?.session) &&
      data?.user?.id === expectedUserId;
  } catch {
    return false;
  }
}

/// The caller's linked Google subject, if any.
function googleSubject(
  // deno-lint-ignore no-explicit-any
  user: any,
): string | null {
  const identities = user?.identities;
  if (!Array.isArray(identities)) return null;
  for (const identity of identities) {
    if (identity?.provider !== 'google') continue;
    const sub = identity?.identity_data?.sub;
    if (typeof sub === 'string' && sub.length > 0) return sub;
  }
  return null;
}

/// Google's supported server-side verifier (signature, issuer, audience, expiry),
/// bound to the web client ID this project issues tokens for. Created once per
/// isolate: the JWKS fetch is cached inside the library.
const verifyWithGoogle = createGoogleVerifier();

/// Establishes that [idToken] was minted by Google for this project AND belongs
/// to the Google identity linked to [user]. See google_token.ts for what each
/// verdict means.
function verifyGoogleIdToken(
  // deno-lint-ignore no-explicit-any
  user: any,
  idToken: string,
): Promise<GoogleVerdict> {
  return verifyGoogleIdentity({
    idToken,
    expectedAudience: Deno.env.get('GOOGLE_WEB_CLIENT_ID'),
    expectedSubject: googleSubject(user),
    verify: verifyWithGoogle,
  });
}

/// Tables that must hold no row referencing the deleted user afterwards, with
/// the columns that can reference them. Every one of these foreign keys is
/// `on delete cascade`, so a survivor means the cascade did not do what the
/// schema promises.
const CLEANUP_CHECKS: Record<string, string[]> = {
  profiles: ['id'],
  locations: ['user_id'],
  location_sharing: ['owner_id', 'recipient_id'],
  notification_preferences: ['user_id'],
  device_tokens: ['user_id'],
  circle_messages: ['sender_id', 'recipient_id'],
  connections: ['user_a_id', 'user_b_id'],
  connection_requests: ['requester_id', 'recipient_id'],
  circle_relationships: ['user_id', 'target_user_id'],
  saved_places: ['user_id'],
  message_reactions: ['user_id'],
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/// What the post-delete verification found.
interface CleanupReport {
  /// Tables that still hold a row referencing the deleted user.
  remaining: string[];
  /// Tables whose state could not be read. Not proof of an orphan — and not
  /// proof of cleanliness either, so it is reported rather than ignored.
  unverified: string[];
}

/// Re-reads the tables that should have been emptied by the cascade.
async function verifyCleanup(
  // deno-lint-ignore no-explicit-any
  admin: any,
  userId: string,
): Promise<CleanupReport> {
  const remaining: string[] = [];
  const unverified: string[] = [];
  for (const [table, columns] of Object.entries(CLEANUP_CHECKS)) {
    try {
      const { count, error } = await admin
        .from(table)
        .select('*', { count: 'exact', head: true })
        .or(columns.map((column) => `${column}.eq.${userId}`).join(','));
      if (error) {
        unverified.push(table);
        continue;
      }
      if ((count ?? 0) > 0) remaining.push(table);
    } catch {
      unverified.push(table);
    }
  }
  return { remaining, unverified };
}

/// Second pass for tables that still held a row: deletes them explicitly.
/// Idempotent, and deliberately not silent — the verification that follows is
/// what decides the response.
async function forceCleanup(
  // deno-lint-ignore no-explicit-any
  admin: any,
  userId: string,
  tables: string[],
): Promise<void> {
  for (const table of tables) {
    const columns = CLEANUP_CHECKS[table];
    if (!columns) continue;
    try {
      await admin
        .from(table)
        .delete()
        .or(columns.map((column) => `${column}.eq.${userId}`).join(','));
    } catch {
      // Whatever survived is reported by the verification below.
    }
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405);
  }

  const authHeader = req.headers.get('Authorization') ?? '';
  const accessToken = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!accessToken) {
    return json({ error: 'unauthenticated' }, 401);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !anonKey || !serviceKey) {
    // Never echo which secret is missing.
    console.error('delete-account: server configuration is incomplete.');
    return json({ error: 'server_configuration' }, 500);
  }

  try {
    // ── 1. Who is calling? Answered by the auth server, keyed by the token. ──
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: `Bearer ${accessToken}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: userData, error: userError } = await callerClient.auth
      .getUser(accessToken);

    if (userError || !userData?.user) {
      return json({ error: 'unauthenticated' }, 401);
    }

    const user = userData.user;

    // ── 2. Verify a credential for THIS request. ────────────────────────────
    const credential = await readCredential(req);
    if (!credential) {
      return json({ error: 'credential_required' }, 400);
    }

    if (credential.password !== undefined) {
      if (!user.email) {
        return json({ error: 'credential_type_unsupported' }, 400);
      }
      const matches = await passwordBelongsTo(
        supabaseUrl,
        anonKey,
        user.email,
        credential.password,
        user.id,
      );
      if (!matches) {
        return json({ error: 'password_mismatch' }, 403);
      }
    } else {
      const verdict = await verifyGoogleIdToken(
        user,
        credential.googleIdToken!,
      );
      if (verdict === 'configuration') {
        console.error('delete-account: GOOGLE_WEB_CLIENT_ID is not set.');
        return json({ error: 'server_configuration' }, 500);
      }
      if (verdict === 'invalid') {
        return json({ error: 'google_token_invalid' }, 403);
      }
      if (verdict === 'mismatch') {
        return json({ error: 'google_mismatch' }, 403);
      }
    }

    // ── 3. Delete exactly that account, with administrative privileges. ─────
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
    if (deleteError) {
      // A concurrent or repeated request can lose the race and get "user not
      // found". Re-read before concluding anything: reporting a failure for an
      // account that is already gone tells the user the opposite of the truth.
      const { data: lookup, error: lookupError } = await admin.auth.admin
        .getUserById(user.id);
      const gone = isUserNotFound(lookupError);
      if (!gone && lookupError) {
        console.error(
          'delete-account: delete failed and the user could not be re-read:',
          deleteError.message,
        );
        return json({ error: 'deletion_unconfirmed' }, 500);
      }
      if (!gone && lookup?.user) {
        console.error(
          'delete-account: admin delete failed:',
          deleteError.message,
        );
        return json({ error: 'deletion_failed' }, 500);
      }
      // The user is gone: this call lost the race to another deletion, so it
      // continues as a cleanup check rather than reporting a false failure.
    }

    // ── 4. Prove the cascade ran instead of trusting it. ────────────────────
    let report = await verifyCleanup(admin, user.id);
    if (report.remaining.length > 0) {
      // A survivor means a cascade did not do what the schema promises. Finish
      // the job explicitly, then check again — the auth user being gone is not
      // evidence that the account's data is gone.
      await forceCleanup(admin, user.id, report.remaining);
      report = await verifyCleanup(admin, user.id);
    }

    if (report.remaining.length > 0) {
      // Reported honestly rather than as success: an operator must finish it.
      // The id goes to the log (never to the response body) because the auth
      // user is gone — without it, the surviving rows cannot be located later.
      console.error(
        `delete-account: rows survived the cascade for user ${user.id}:`,
        report.remaining.join(', '),
      );
      return json(
        { error: 'cleanup_incomplete', tables: report.remaining },
        500,
      );
    }

    if (report.unverified.length > 0) {
      // Nothing readable is left, but cleanliness was not proven. The auth
      // account is already gone, so this must not be reported as a clean
      // success either.
      console.error(
        `delete-account: cleanup could not be verified for user ${user.id}:`,
        report.unverified.join(', '),
      );
      return json(
        { error: 'cleanup_unverified', tables: report.unverified },
        500,
      );
    }

    return json({ deleted: true }, 200);
  } catch (err) {
    // An unexpected throw can happen before OR after the admin delete, so it is
    // not proof that nothing was removed. The client reports this as
    // "unconfirmed" and keeps the user signed in.
    console.error('delete-account: unexpected failure:', String(err));
    return json({ error: 'deletion_unconfirmed' }, 500);
  }
});
