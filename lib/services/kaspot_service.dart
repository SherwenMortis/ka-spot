import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/email_validator.dart';
import '../utils/location_tracking_config.dart';

class AuthResult {
  final bool isSessionActive;
  final bool requiresEmailConfirmation;
  final String? email;
  final String? message;

  const AuthResult({
    required this.isSessionActive,
    this.requiresEmailConfirmation = false,
    this.email,
    this.message,
  });
}

class KaSpotService {
  KaSpotService._();
  static SupabaseClient? _client;

  /// Deep-link scheme registered in AndroidManifest.xml. Email confirmation and
  /// password-recovery links return to the app through this URI so the
  /// Supabase SDK can complete the flow automatically.
  static const String authRedirectUrl = 'io.supabase.kaspot://login-callback';

  /// Shown whenever a real authenticateable backend is unavailable and the
  /// development-only local preview is not explicitly enabled.
  static const String backendUnavailableMessage =
      'Secure sign-in is unavailable: KaSpot is not connected to its authentication service. Restore the app configuration and try again.';

  /// Shown when someone tries to sign in with a Google account that has never
  /// completed a KaSpot registration. Signing in must never silently register
  /// a brand-new account — the user must register through Create Account first.
  static const String googleNotRegisteredMessage =
      'This Google account is not registered with KaSpot yet. Tap "Create Account" and continue with Google there to register first.';

  /// True while a Google credential exchange is being gated for registration
  /// completeness. The auth listener must not activate the app during this
  /// window, since the fresh session may be dropped right after the check.
  static bool _googleRegistrationGateActive = false;

  /// Development-only local preview session. It fabricates a local user with no
  /// server verification and must never be enabled in a release build.
  static bool _localPreviewEnabled =
      const bool.fromEnvironment('KASPOT_LOCAL_PREVIEW') ||
      (dotenv.isInitialized &&
          dotenv.maybeGet('KASPOT_LOCAL_PREVIEW')?.trim().toLowerCase() ==
              'true');

  /// Enables/disables the clearly-labelled local preview session (tests/dev).
  static void enableLocalPreview({bool enabled = true}) {
    _localPreviewEnabled = enabled;
  }

  static void configure(SupabaseClient client) {
    _client = client;
    authStateNotifier.value = _hasVerifiedSession(client.auth.currentSession);
    client.auth.onAuthStateChange.listen((data) async {
      if (data.event == AuthChangeEvent.passwordRecovery) {
        // A recovery link opens a short-lived session whose only purpose is to
        // set a new password. It must never be treated as a normal sign-in.
        passwordRecoveryActive.value = true;
        return;
      }
      if (data.event == AuthChangeEvent.signedOut) {
        passwordRecoveryActive.value = false;
      }
      final user = data.session?.user ?? client.auth.currentUser;
      // A session alone is never sufficient: the required verification must
      // have been completed, and an active recovery flow blocks activation.
      final hasVerifiedSession =
          data.session != null &&
          _isVerifiedUser(user) &&
          !passwordRecoveryActive.value;
      if (hasVerifiedSession && !_googleRegistrationGateActive) {
        authStateNotifier.value = true;
        try {
          await ensureProfile();
        } catch (_) {}
      } else {
        // Either there is no verified session, or a Google sign-in is still
        // being checked for registration completeness — the app must stay
        // locked until that check completes.
        authStateNotifier.value = false;
        if (data.session == null) {
          profileNotifier.value = null;
        }
      }
    });
  }

  /// True only when the user has completed the required verification: a
  /// confirmed email, or a provider-verified identity (e.g. Google). A raw,
  /// unconfirmed session is never sufficient.
  static bool _isVerifiedUser(User? user) {
    if (user == null) return false;
    if (user.emailConfirmedAt != null) return true;
    final identities = user.identities;
    if (identities != null &&
        identities.any((identity) => identity.provider != 'email')) {
      return true;
    }
    return false;
  }

  static bool _hasVerifiedSession(Session? session) {
    return session != null && _isVerifiedUser(session.user);
  }

  static SupabaseClient? get client => _client;
  static bool get isConfigured => _client != null;

  // Real authentication state listenable for clean reactive transitions
  static final ValueNotifier<bool> authStateNotifier = ValueNotifier<bool>(
    false,
  );
  static final ValueNotifier<Map<String, dynamic>?> profileNotifier =
      ValueNotifier<Map<String, dynamic>?>(null);

  /// True while a password-recovery deep link has opened a reset session.
  static final ValueNotifier<bool> passwordRecoveryActive = ValueNotifier<bool>(
    false,
  );

  // Local session state (used when no Supabase backend is configured)
  static Map<String, dynamic>? _localUser;
  static final List<Map<String, dynamic>> _localSavedPlaces = [];
  static final List<Map<String, dynamic>> _localConnections = [];
  static final List<Map<String, dynamic>> _localRequests = [];
  static final Map<String, bool> _localSharingGrants = {};
  static final Map<String, dynamic> _localPrefs = {
    'connection_notifications_enabled': true,
    'arrival_alerts_enabled': false,
    'background_sharing_enabled': false,
  };
  static final Map<String, String> _localRelationships = {};

  // In-memory cache of the user's latest GPS coordinate for instant map warm-start
  static double? lastUserLatitude;
  static double? lastUserLongitude;

  static bool get isAuthenticated {
    if (_client != null) return _isVerifiedUser(_client!.auth.currentUser);
    return _localPreviewEnabled && _localUser != null;
  }

  static String get userId {
    if (_client != null) return _client!.auth.currentUser?.id ?? '';
    return _localUser?['id'] as String? ?? '';
  }

  /// Formats any user ID into a clean, short, uppercase KaSpot Circle Code:
  /// e.g. "KS-E7BE-D662"
  static String formatAccountCode(String id) {
    if (id.isEmpty) return '';
    final clean = id.replaceAll('-', '').replaceAll(' ', '').toUpperCase();
    if (clean.length < 8) return 'KS-$clean';
    return 'KS-${clean.substring(0, 4)}-${clean.substring(4, 8)}';
  }

  /// Returns the current user's short, capitalized Account Code (e.g. "KS-E7BE-D662")
  static String get accountCode => formatAccountCode(userId);

  /// Monotonic suffix so two local-preview sign-ins that land in the same
  /// millisecond still get distinct ids (widget tests sign in back-to-back).
  static int _localSessionSeq = 0;

  static String _newLocalUserId() =>
      'u-${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}${(_localSessionSeq++).toRadixString(16)}';

  /// Resolves an entered Account Code (e.g. "KS-E7BE-D662" or "E7BED662") or raw UUID into the target User UUID
  static Future<String> resolveUserId(String input) async {
    final clean = input.trim().toUpperCase();
    if (clean.isEmpty) {
      throw Exception('Please enter an Account Code or ID.');
    }

    final uuidRegex = RegExp(
      r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$',
      caseSensitive: false,
    );
    if (uuidRegex.hasMatch(clean)) {
      return clean.toLowerCase();
    }

    final rawHex = clean
        .replaceAll('KS-', '')
        .replaceAll('-', '')
        .replaceAll(' ', '')
        .toLowerCase();

    // Prevent matching self
    final myHex = userId.replaceAll('-', '').toLowerCase();
    if (rawHex.length >= 6 && myHex.startsWith(rawHex)) {
      throw Exception('You cannot connect to yourself.');
    }

    if (_client != null) {
      try {
        final res = await _client!.rpc(
          'lookup_user_by_code',
          params: {'code': clean},
        );
        if (res != null && res.toString().isNotEmpty) {
          return res.toString();
        }
      } catch (e) {
        debugPrint('[KaSpot] lookup_user_by_code RPC failed: $e');
      }

      // Fallback: the RPC is the preferred path; this scan is a safety net
      // and only works if the profiles RLS policy permits reading other rows.
      try {
        final rows = await _client!.from('profiles').select('id');
        for (final row in rows) {
          final targetId = row['id'] as String;
          final cleanTargetId = targetId.replaceAll('-', '').toLowerCase();
          if (cleanTargetId.startsWith(rawHex)) {
            return targetId;
          }
        }
      } catch (e) {
        debugPrint('[KaSpot] profiles fallback scan failed: $e');
      }
    } else {
      if (_localUser != null) {
        final localId = _localUser!['id'] as String? ?? '';
        final localHex = localId.replaceAll('-', '').toLowerCase();
        if (localHex.startsWith(rawHex)) return localId;
      }
      for (final conn in _localConnections) {
        final otherId = conn['other_id'] as String? ?? '';
        final otherHex = otherId.replaceAll('-', '').toLowerCase();
        if (otherHex.startsWith(rawHex)) return otherId;
      }
      return 'user-$rawHex';
    }

    throw Exception(
      'No KaSpot member found with code "$clean". Check the code and try again.',
    );
  }

  static Future<void> signIn(String email, String password) async {
    final cleanEmail = email.trim().toLowerCase();
    if (_client != null) {
      final response = await _client!.auth.signInWithPassword(
        email: cleanEmail,
        password: password,
      );
      if (!_isVerifiedUser(response.user)) {
        // Defense-in-depth: never keep a session whose required verification
        // has not been completed, regardless of project configuration.
        try {
          await _client!.auth.signOut();
        } catch (_) {}
        throw const AuthException('Email not confirmed');
      }
      await ensureProfile();
      // A completed password sign-in proves this account passed through the
      // register flow; backfill the registration flag for future Google use.
      await _markRegistrationCompleted(response.user?.id ?? '');
    } else {
      if (!_localPreviewEnabled) {
        throw AuthException(backendUnavailableMessage);
      }
      // Local development session validation (preview only)
      if (cleanEmail.isEmpty || !cleanEmail.contains('@')) {
        throw Exception('Please enter a valid email address.');
      }
      if (password.length < 6) {
        throw Exception('Password must be at least 6 characters.');
      }
      final name = cleanEmail.split('@').first;
      final displayName = name.isNotEmpty
          ? '${name[0].toUpperCase()}${name.substring(1)}'
          : 'Member';
      _localUser = {
        'id': _newLocalUserId(),
        'email': cleanEmail,
        'display_name': displayName,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };
      profileNotifier.value = _localUser;
      authStateNotifier.value = true;
    }
  }

  /// Runs the native Google picker and returns the raw credential. It does NOT
  /// exchange it with Supabase and does NOT touch the current session, so a
  /// different Google account cannot replace the signed-in one.
  ///
  /// [forceAccountChoice] clears Google's cached account first, so the picker is
  /// shown again and the token comes from a fresh interaction rather than from a
  /// silently reused account.
  static Future<({String idToken, String? accessToken, String? displayName})?>
  _requestGoogleCredential({bool forceAccountChoice = false}) async {
    final webClientId =
        dotenv.maybeGet('GOOGLE_WEB_CLIENT_ID') ??
        const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');

    final googleSignIn = GoogleSignIn(
      serverClientId: webClientId.isNotEmpty ? webClientId : null,
    );

    if (forceAccountChoice) {
      try {
        await googleSignIn.signOut();
      } catch (_) {
        // Only a local cache clear: if it fails the picker still opens.
      }
    }

    final googleUser = await googleSignIn.signIn();
    if (googleUser == null) {
      // User dismissed or cancelled the native account selector
      return null;
    }

    final googleAuth = await googleUser.authentication;
    final idToken = googleAuth.idToken;
    if (idToken == null) {
      throw Exception(
        'Google Sign-In failed: No ID token returned from Google.',
      );
    }

    return (
      idToken: idToken,
      accessToken: googleAuth.accessToken,
      displayName: googleUser.displayName,
    );
  }

  /// Exchanges a Google ID token for a Supabase session. Shared by the sign-in
  /// and registration entry points. Returns the authenticated user plus the
  /// Google display name, or null when the user dismissed the native picker.
  static Future<(User, String?)?> _exchangeGoogleCredentials() async {
    final credential = await _requestGoogleCredential();
    if (credential == null) return null;

    final response = await _client!.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: credential.idToken,
      accessToken: credential.accessToken,
    );
    final user = response.user ?? _client!.auth.currentUser;
    if (user == null) {
      throw Exception(
        'Google Sign-In failed: the session did not include a user.',
      );
    }
    return (user, credential.displayName);
  }

  /// Sign-in entry point (Sign In screen). Only accounts that have completed a
  /// KaSpot registration may enter: Supabase creates a brand-new account on the
  /// first Google credential exchange, so a never-registered account is signed
  /// back out immediately with guidance to register — signing in must never
  /// double as silent registration.
  static Future<void> signInWithGoogle() async {
    if (_client != null) {
      _googleRegistrationGateActive = true;
      try {
        final exchange = await _exchangeGoogleCredentials();
        if (exchange == null) return; // picker dismissed
        final user = exchange.$1;
        final displayName = exchange.$2;

        final registered = await _hasCompletedRegistration(user.id);
        if (!registered) {
          try {
            await _client!.auth.signOut();
          } catch (_) {}
          throw AuthException(googleNotRegisteredMessage);
        }

        await ensureProfile(name: displayName);
        authStateNotifier.value = true;
      } finally {
        _googleRegistrationGateActive = false;
      }
    } else {
      _activateLocalGooglePreview();
    }
  }

  /// Registration entry point (Create Account screen). The Google account is
  /// registered here: the server-side flag is written first so that later
  /// sign-ins of the same account pass the registration gate.
  static Future<void> registerWithGoogle() async {
    if (_client != null) {
      _googleRegistrationGateActive = true;
      try {
        final exchange = await _exchangeGoogleCredentials();
        if (exchange == null) return; // picker dismissed
        final user = exchange.$1;
        final displayName = exchange.$2;

        await _markRegistrationCompleted(user.id);
        await ensureProfile(name: displayName);
        authStateNotifier.value = true;
      } finally {
        _googleRegistrationGateActive = false;
      }
    } else {
      _activateLocalGooglePreview();
    }
  }

  static void _activateLocalGooglePreview() {
    if (!_localPreviewEnabled) {
      throw AuthException(backendUnavailableMessage);
    }
    _localUser = {
      'id': _newLocalUserId(),
      'email': 'googleuser@gmail.com',
      'display_name': 'Google Member',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };
    profileNotifier.value = _localUser;
    authStateNotifier.value = true;
  }

  /// Reads the server-side registration flag. If the flag cannot be read at
  /// all (e.g. the migration has not been applied yet), the sign-in is allowed
  /// so that a configuration gap never locks legitimate users out.
  static Future<bool> _hasCompletedRegistration(String userId) async {
    if (userId.isEmpty) return false;
    try {
      final rows = await _client!
          .from('profiles')
          .select('registered_at')
          .eq('id', userId)
          .limit(1);
      if (rows.isEmpty) return false;
      return rows.first['registered_at'] != null;
    } catch (_) {
      return true;
    }
  }

  /// Marks the account as registered (idempotent, best-effort bookkeeping).
  static Future<void> _markRegistrationCompleted(String userId) async {
    if (userId.isEmpty) return;
    try {
      final rows = await _client!
          .from('profiles')
          .select('registered_at')
          .eq('id', userId)
          .limit(1);
      if (rows.isNotEmpty && rows.first['registered_at'] != null) return;
      final nowIso = DateTime.now().toUtc().toIso8601String();
      await _client!
          .from('profiles')
          .update({'registered_at': nowIso, 'updated_at': nowIso})
          .eq('id', userId);
    } catch (_) {
      // Best-effort: registration itself must not fail on this bookkeeping.
    }
  }

  static Future<AuthResult> register(
    String name,
    String email,
    String password,
  ) async {
    final cleanEmail = email.trim().toLowerCase();
    final cleanName = name.trim();

    final validationError = EmailValidator.validate(
      cleanEmail,
      requireGoogleAccount: true,
    );
    if (validationError != null) {
      throw AuthException(validationError);
    }

    if (_client != null) {
      final result = await _client!.auth.signUp(
        email: cleanEmail,
        password: password,
        emailRedirectTo: authRedirectUrl,
        data: {
          'display_name': cleanName,
          'full_name': cleanName,
          'name': cleanName,
        },
      );
      if (result.session != null) {
        if (!_isVerifiedUser(result.user)) {
          // A session without completed verification must not activate the
          // app; drop it and surface the confirmation-pending state instead.
          try {
            await _client!.auth.signOut();
          } catch (_) {}
          return AuthResult(
            isSessionActive: false,
            requiresEmailConfirmation: true,
            email: cleanEmail,
          );
        }
        await ensureProfile(name: cleanName);
        await _markRegistrationCompleted(result.user?.id ?? '');
        return AuthResult(isSessionActive: true, email: cleanEmail);
      } else {
        final identities = result.user?.identities;
        if (identities != null && identities.isEmpty) {
          throw const AuthException(
            'An account with this email already exists. Please sign in instead.',
          );
        }
        return AuthResult(
          isSessionActive: false,
          requiresEmailConfirmation: true,
          email: cleanEmail,
        );
      }
    } else {
      if (!_localPreviewEnabled) {
        throw AuthException(backendUnavailableMessage);
      }
      // Local development registration (preview only)
      if (cleanName.isEmpty) throw Exception('Please enter your name.');
      if (cleanEmail.isEmpty || !cleanEmail.contains('@')) {
        throw Exception('Please enter a valid email address.');
      }
      if (password.length < 8) {
        throw Exception('Password must be at least 8 characters.');
      }
      _localUser = {
        'id': _newLocalUserId(),
        'email': cleanEmail,
        'display_name': cleanName,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };
      profileNotifier.value = _localUser;
      authStateNotifier.value = true;
      return AuthResult(isSessionActive: true, email: cleanEmail);
    }
  }

  static Future<void> resendVerificationEmail(String email) async {
    final cleanEmail = email.trim().toLowerCase();
    if (_client != null) {
      await _client!.auth.resend(
        type: OtpType.signup,
        email: cleanEmail,
        emailRedirectTo: authRedirectUrl,
      );
    } else if (!_localPreviewEnabled) {
      throw AuthException(backendUnavailableMessage);
    }
  }

  static Future<void> recoverPassword(String email) async {
    if (_client != null) {
      await _client!.auth.resetPasswordForEmail(
        email.trim(),
        redirectTo: authRedirectUrl,
      );
    } else if (!_localPreviewEnabled) {
      throw AuthException(backendUnavailableMessage);
    }
  }

  /// Completes the password-recovery flow: replaces the password on the
  /// short-lived recovery session, then closes that session so the user signs
  /// in again with the new password.
  static Future<void> updateRecoveredPassword(String newPassword) async {
    if (_client == null) {
      throw AuthException(backendUnavailableMessage);
    }
    final user = _client!.auth.currentUser;
    if (user == null) {
      throw AuthException(
        'Your recovery link has expired. Please request a new password reset email.',
      );
    }
    await _client!.auth.updateUser(UserAttributes(password: newPassword));
    await signOut();
  }

  /// Abandon the password-recovery flow without changing the password.
  static Future<void> cancelPasswordRecovery() async {
    await signOut();
  }

  /// Stores the FCM device token in the `device_tokens` table so the
  /// Supabase Edge Function can look it up when delivering push notifications.
  static Future<void> registerFcmToken(String token) async {
    if (_client == null || userId.isEmpty) return;
    final row = <String, dynamic>{
      'user_id': userId,
      'token': token,
      'platform': 'android',
      'updated_at': DateTime.now().toUtc().toIso8601String(),
      // Advertises that this build renders data-only FCM messages itself, so
      // notify-new-message may deliver the reliable data-only payload here.
      'supports_data_only': true,
    };
    try {
      await _client!
          .from('device_tokens')
          .upsert(row, onConflict: 'user_id,token');
    } catch (e) {
      debugPrint('[KaSpot] registerFcmToken failed: $e');
      // The capability column is added by a migration. If it has not been
      // applied yet, registering the token without it is strictly better than
      // losing the token (the device would get no notifications at all).
      // The device then keeps receiving the legacy payload it can display.
      try {
        await _client!
            .from('device_tokens')
            .upsert(
              Map<String, dynamic>.from(row)..remove('supports_data_only'),
              onConflict: 'user_id,token',
            );
      } catch (fallbackError) {
        debugPrint('[KaSpot] registerFcmToken fallback failed: $fallbackError');
      }
    }
  }

  static Future<void> signOut() async {
    if (_client != null) {
      try {
        await GoogleSignIn().signOut();
      } catch (_) {}
      try {
        await _client!.auth.signOut();
      } catch (_) {
        // The local session is what keeps this device signed in, so a failed or
        // unreachable sign-out call must never leave a session behind: fall
        // through and clear it locally.
      }
    }
    await _clearLocalSession();
  }

  /// Removes every trace of the current account from this device without
  /// touching the network. Used by [signOut] and after a confirmed deletion,
  /// where the session's user no longer exists.
  static Future<void> _clearLocalSession() async {
    _localUser = null;
    lastUserLatitude = null;
    lastUserLongitude = null;
    sharingActive.value = false;
    // A signed-out device keeps no coordinates of its own: the single queued fix
    // is removed instead of lingering for the next account on this phone.
    await clearPendingLocation();
    // Badge and conversation state belong to the account that just left; the
    // next account on this phone must never inherit them.
    unreadCounts.value = {};
    activeChatUserId = null;
    passwordRecoveryActive.value = false;
    authStateNotifier.value = false;
    profileNotifier.value = null;
  }

  /// Shown whenever a deletion request cannot reach a deployed, configured
  /// endpoint. It states plainly that nothing was removed, so a failed call can
  /// never read as a successful deletion.
  static const String deleteAccountUnavailableMessage =
      'Account deletion could not be completed, and nothing was removed from your account. The deletion service is not available right now. Please try again later.';

  /// Used when the server could not confirm whether the account still exists.
  /// Deliberately claims neither success nor failure, and the device stays
  /// signed in so the user can retry.
  static const String deleteAccountNotConfirmedMessage =
      'KaSpot could not confirm whether your account was deleted, so this device was left signed in. Try again; if it keeps failing, do not assume the account is gone.';

  /// Used when the auth account was deleted but the server could not confirm
  /// that every associated record was removed. The account is gone, so this is
  /// not reported as "nothing happened".
  static const String deleteAccountCleanupUnverifiedMessage =
      'Your account was deleted, but KaSpot could not confirm that every stored record was removed. The cleanup has been recorded on the server for follow-up.';

  /// Test-only seam: replaces the network deletion so the whole UI flow
  /// (confirmation, credential handling, cleanup, navigation) can be exercised
  /// without a deployed function. Same role as [debugUploadOverride].
  @visibleForTesting
  static Future<DeleteAccountOutcome> Function({
    String? password,
    String? googleIdToken,
  })?
  debugDeleteAccountOverride;

  /// Whether this account can prove ownership with a password. Google-only
  /// accounts have no password to re-enter, so they confirm through the Google
  /// credential exchange instead.
  static bool get hasPasswordIdentity {
    if (_client == null) return true; // local preview keeps the password form
    final user = _client!.auth.currentUser;
    if (user == null) return false;
    final identities = user.identities;
    if (identities == null || identities.isEmpty) {
      return (user.email ?? '').isNotEmpty;
    }
    return identities.any((identity) => identity.provider == 'email');
  }

  /// Obtains a fresh Google ID token for the signed-in account **without**
  /// touching the Supabase session. `delete-account` verifies the token with
  /// Google, checks its audience and matches its subject to this account's
  /// Google identity before deleting anything.
  ///
  /// What the token proves: control of the linked Google account on this device
  /// at this moment, through a fresh account-picker interaction. It does not
  /// prove a password was re-entered — Google's flow does not expose that, and
  /// claiming otherwise would overstate it.
  static Future<String?> acquireGoogleDeletionProof() async {
    if (_client == null) return null;
    final credential = await _requestGoogleCredential(forceAccountChoice: true);
    return credential?.idToken;
  }

  /// Permanently deletes the signed-in account through the `delete-account` Edge
  /// Function, then clears every trace of it on this device.
  ///
  /// Exactly one credential is sent with the request, and the function verifies
  /// it server-side: [password] is checked with the sign-in service, or
  /// [googleIdToken] is verified with Google and matched to this account's
  /// Google identity. Neither is stored, and the request never carries a user id.
  ///
  /// Nothing local is cleared until the server confirms, so a failure leaves the
  /// user signed in and told so. Returns
  /// [DeleteAccountOutcome.deletedWithUnverifiedCleanup] when the auth account is
  /// gone but the function could not confirm that every associated record was
  /// removed. That is not a failure to report as "nothing happened".
  static Future<DeleteAccountOutcome> deleteAccount({
    String? password,
    String? googleIdToken,
  }) async {
    assert(
      (password != null) != (googleIdToken != null),
      'exactly one credential is required',
    );
    final override = debugDeleteAccountOverride;
    if (override != null) {
      final outcome = await override(
        password: password,
        googleIdToken: googleIdToken,
      );
      await _dropSessionLocally();
      return outcome;
    }
    if (_client == null) {
      if (!_localPreviewEnabled) throw AuthException(backendUnavailableMessage);
      await _dropSessionLocally();
      return DeleteAccountOutcome.deleted;
    }
    final body = password != null
        ? <String, dynamic>{'password': password}
        : <String, dynamic>{'google_id_token': googleIdToken};
    try {
      await _client!.functions.invoke('delete-account', body: body);
    } on FunctionException catch (error) {
      if (error.status == 401) {
        throw AuthException(
          'Your session has expired. Sign in again, then retry the deletion.',
        );
      }
      if (error.status == 400) {
        throw AuthException(
          'Confirm your password or Google account before deleting.',
        );
      }
      if (error.status == 403) {
        final code = _functionErrorCode(error);
        if (code == 'password_mismatch') {
          throw AuthException('That password did not match this account.');
        }
        if (code == 'google_mismatch') {
          throw AuthException(
            'That Google account does not match the account you are signed in with.',
          );
        }
        if (code == 'google_token_invalid') {
          throw AuthException(
            'Google confirmation could not be verified. Try again.',
          );
        }
        throw AuthException(
          'Please confirm your credentials again before deleting your account.',
        );
      }
      if (error.status == 404) {
        throw AuthException(deleteAccountUnavailableMessage);
      }
      final code = _functionErrorCode(error);
      if (code == 'cleanup_incomplete' || code == 'cleanup_unverified') {
        // The auth account is already gone; only the confirmation of the
        // associated records failed. Saying "nothing was removed" would be
        // false, and leaving the device signed in would be worse.
        await _dropSessionLocally();
        return DeleteAccountOutcome.deletedWithUnverifiedCleanup;
      }
      if (code == 'deletion_failed') {
        throw AuthException(
          'KaSpot could not delete your account, and nothing was removed. Please try again.',
        );
      }
      // Anything else (including an unconfirmed lookup) must not be reported as
      // either success or "nothing happened".
      throw AuthException(deleteAccountNotConfirmedMessage);
    } catch (_) {
      throw AuthException(
        'KaSpot could not reach the server, so nothing was deleted. Check your connection and try again.',
      );
    }
    await _dropSessionLocally();
    return DeleteAccountOutcome.deleted;
  }

  /// Reads the machine-readable error code from a function response body.
  static String? _functionErrorCode(FunctionException error) {
    final details = error.details;
    if (details is Map && details['error'] is String) {
      return details['error'] as String;
    }
    return null;
  }

  /// Ends this device's session without asking the auth server to end it. Used
  /// after a confirmed deletion, where the user no longer exists — a server-side
  /// sign-out would be answered with "user not found" and prove nothing.
  static Future<void> _dropSessionLocally() async {
    if (_client != null) {
      try {
        await _client!.auth.signOut(scope: SignOutScope.local);
      } catch (_) {
        // The in-memory and notifier state below is cleared unconditionally, so
        // a failed sign-out cannot leave this device signed in.
      }
      try {
        await GoogleSignIn().signOut();
      } catch (_) {}
    }
    await _clearLocalSession();
  }

  static Future<void> ensureProfile({String? name}) async {
    if (_client == null) return;
    final user = _client!.auth.currentUser;
    if (user == null) return;
    final metaName =
        (user.userMetadata?['display_name'] as String?) ??
        (user.userMetadata?['full_name'] as String?) ??
        (user.userMetadata?['name'] as String?);
    final emailPrefix = user.email?.split('@').first;
    final candidate = name?.trim() ?? metaName?.trim() ?? emailPrefix?.trim();
    final displayName = (candidate != null && candidate.isNotEmpty)
        ? candidate
        : 'KaSpot Member';
    await _client!.from('profiles').upsert({
      'id': user.id,
      'display_name': displayName,
    }, onConflict: 'id');
    profileNotifier.value = await myProfile();
  }

  static Future<Map<String, dynamic>?> myProfile() async {
    if (_client != null) {
      final rows = await _client!
          .from('profiles')
          .select()
          .eq('id', userId)
          .limit(1);
      return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
    }
    return _localUser;
  }

  static Future<void> updateMyName(String name) async {
    final cleanName = name.trim();
    if (_client != null) {
      await _client!.from('profiles').upsert({
        'id': userId,
        'display_name': cleanName,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'id');
    } else if (_localUser != null) {
      _localUser!['display_name'] = cleanName;
    }
    profileNotifier.value = await myProfile();
  }

  static Future<void> updateMyAvatar(String? avatarUrl) async {
    if (_client != null) {
      await ensureProfile();
      await _client!
          .from('profiles')
          .update({
            'avatar_url': avatarUrl,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', userId);
    } else if (_localUser != null) {
      _localUser!['avatar_url'] = avatarUrl;
    }
    profileNotifier.value = await myProfile();
  }

  static Future<List<Map<String, dynamic>>> requests() async {
    if (_client != null) {
      final rows = await _client!
          .from('connection_requests')
          .select()
          .or('requester_id.eq.$userId,recipient_id.eq.$userId')
          .order('created_at', ascending: false);
      return _attachCounterpartProfiles(
        rows.map((row) => Map<String, dynamic>.from(row)).toList(),
      );
    }
    return _attachCounterpartProfiles(
      _localRequests.map((row) => Map<String, dynamic>.from(row)).toList(),
    );
  }

  /// Adds the counterpart's identity (id, display name, avatar, Circle Code)
  /// to each connection request so the Circle tab can show who is on the other
  /// side instead of a raw identifier. Request participants may already read
  /// each other's profiles under the existing RLS policies.
  static Future<List<Map<String, dynamic>>> _attachCounterpartProfiles(
    List<Map<String, dynamic>> rows,
  ) async {
    final myId = userId;
    final counterpartIds = <String>{
      for (final row in rows)
        (row['requester_id'] == myId
                ? row['recipient_id']
                : row['requester_id'])
            as String,
    };
    final profilesById = <String, Map<String, dynamic>>{};
    if (_client != null && counterpartIds.isNotEmpty) {
      try {
        final profiles = await _client!
            .from('profiles')
            .select('id,display_name,avatar_url')
            .inFilter('id', counterpartIds.toList());
        for (final profile in profiles) {
          profilesById[profile['id'] as String] = Map<String, dynamic>.from(
            profile,
          );
        }
      } catch (_) {}
    }
    return rows.map((row) {
      final counterpartId =
          (row['requester_id'] == myId
                  ? row['recipient_id']
                  : row['requester_id'])
              as String;
      final profile = profilesById[counterpartId];
      return {
        ...row,
        'counterpart_id': counterpartId,
        'counterpart_name':
            profile?['display_name'] as String? ?? 'KaSpot member',
        'counterpart_avatar': profile?['avatar_url'] as String?,
        'counterpart_code': formatAccountCode(counterpartId),
      };
    }).toList();
  }

  static Future<Map<String, String>> circleRelationships() async {
    if (_client != null) {
      try {
        final rows = await _client!
            .from('circle_relationships')
            .select('target_user_id, relationship')
            .eq('user_id', userId);
        return {
          for (final r in rows)
            r['target_user_id'] as String: r['relationship'] as String,
        };
      } catch (_) {
        return Map<String, String>.from(_localRelationships);
      }
    }
    return Map<String, String>.from(_localRelationships);
  }

  static Future<void> setCircleRelationship(
    String targetUserId,
    String relationship,
  ) async {
    final valid = {'Partner', 'Family', 'Friend'}.contains(relationship)
        ? relationship
        : 'Friend';
    if (_client != null) {
      try {
        await _client!.from('circle_relationships').upsert({
          'user_id': userId,
          'target_user_id': targetUserId,
          'relationship': valid,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'user_id,target_user_id');
      } catch (_) {}
    }
    _localRelationships[targetUserId] = valid;
  }

  static Future<void> sendRequest(
    String recipientInput, {
    String relationship = 'Friend',
  }) async {
    final cleanInput = recipientInput.trim();
    if (cleanInput.isEmpty) {
      throw Exception('Please enter an account code or ID.');
    }

    final targetId = await resolveUserId(cleanInput);
    if (targetId == userId) throw Exception('You cannot connect to yourself.');

    // Friendly pre-checks: a human explanation beats a raw database error when
    // the invitation cannot be created.
    final existingConnections = await connections();
    if (existingConnections.any((c) => c['other_id'] == targetId)) {
      throw Exception('You are already connected with this person.');
    }
    final pending = await _pendingRequestBetween(targetId);
    if (pending != null) {
      if (pending['requester_id'] == userId) {
        throw Exception(
          'You already sent this person an invitation. Check Sent Invitations.',
        );
      }
      throw Exception(
        'This person has already invited you. Check Incoming Requests and accept it there.',
      );
    }

    if (_client != null) {
      try {
        await _client!.from('connection_requests').insert({
          'requester_id': userId,
          'recipient_id': targetId,
        });
      } on PostgrestException catch (e) {
        // A race can slip past the pre-checks; map the database outcome to the
        // same human wording instead of surfacing PostgREST internals.
        if (e.code == '23505') {
          final raced = await _pendingRequestBetween(targetId);
          if (raced != null && raced['requester_id'] == userId) {
            throw Exception(
              'You already sent this person an invitation. Check Sent Invitations.',
            );
          }
          throw Exception(
            'This person has already invited you. Check Incoming Requests and accept it there.',
          );
        }
        if (e.code == '42501') {
          throw Exception('You are already connected with this person.');
        }
        throw Exception('Could not send the invitation. Please try again.');
      }
    } else {
      _localRequests.insert(0, {
        'id': 'req-${DateTime.now().millisecondsSinceEpoch}',
        'requester_id': userId,
        'recipient_id': targetId,
        'status': 'pending',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    }
    await setCircleRelationship(targetId, relationship);
  }

  /// Cancels a pending invitation I sent. The database policy lets the
  /// requester move a pending request to 'cancelled' (never to 'accepted'),
  /// so consent always stays with the recipient.
  static Future<void> cancelRequest(String requestId) async {
    if (_client != null) {
      await _client!
          .from('connection_requests')
          .update({'status': 'cancelled'})
          .eq('id', requestId);
      return;
    }
    final index = _localRequests.indexWhere((r) => r['id'] == requestId);
    if (index != -1) {
      _localRequests[index]['status'] = 'cancelled';
    }
  }

  /// Returns the pending request between me and [targetId] in either
  /// direction, or null when none exists.
  static Future<Map<String, dynamic>?> _pendingRequestBetween(
    String targetId,
  ) async {
    if (_client != null) {
      try {
        final rows = await _client!
            .from('connection_requests')
            .select()
            .or(
              'and(requester_id.eq.$userId,recipient_id.eq.$targetId),'
              'and(requester_id.eq.$targetId,recipient_id.eq.$userId)',
            )
            .eq('status', 'pending');
        if (rows.isNotEmpty) return Map<String, dynamic>.from(rows.first);
      } catch (_) {}
      return null;
    }
    for (final request in _localRequests) {
      final samePair =
          (request['requester_id'] == userId &&
              request['recipient_id'] == targetId) ||
          (request['requester_id'] == targetId &&
              request['recipient_id'] == userId);
      if (samePair && request['status'] == 'pending') return request;
    }
    return null;
  }

  static Future<void> respondToRequest(String requestId, String status) async {
    if (_client != null) {
      await _client!
          .from('connection_requests')
          .update({'status': status})
          .eq('id', requestId);
    } else {
      final index = _localRequests.indexWhere((r) => r['id'] == requestId);
      if (index != -1) {
        _localRequests[index]['status'] = status;
        if (status == 'accepted') {
          final otherId = _localRequests[index]['requester_id'] == userId
              ? _localRequests[index]['recipient_id']
              : _localRequests[index]['requester_id'];
          _localConnections.add({
            'id': 'conn-${DateTime.now().millisecondsSinceEpoch}',
            'other_id': otherId,
            'display_name': 'Connected Member',
          });
        }
      }
    }
  }

  static Future<List<Map<String, dynamic>>> connections() async {
    final rels = await circleRelationships();
    if (_client != null) {
      final rows = await _client!
          .from('connections')
          .select()
          .or('user_a_id.eq.$userId,user_b_id.eq.$userId');
      if (rows.isEmpty) return [];
      final ids = rows
          .map(
            (row) => row['user_a_id'] == userId
                ? row['user_b_id'] as String
                : row['user_a_id'] as String,
          )
          .toSet()
          .toList();
      final profiles = await _client!
          .from('profiles')
          .select('id,display_name,avatar_url')
          .inFilter('id', ids);
      final byId = {
        for (final profile in profiles) profile['id'] as String: profile,
      };
      return rows.map((row) {
        final otherId = row['user_a_id'] == userId
            ? row['user_b_id'] as String
            : row['user_a_id'] as String;
        return {
          ...Map<String, dynamic>.from(row),
          'other_id': otherId,
          'display_name': byId[otherId]?['display_name'] ?? 'KaSpot member',
          'avatar_url': byId[otherId]?['avatar_url'] as String?,
          'relationship': rels[otherId] ?? 'Friend',
        };
      }).toList();
    }
    return _localConnections
        .map(
          (c) => {
            ...c,
            'relationship':
                rels[c['other_id']] ??
                (c['relationship'] as String? ?? 'Friend'),
          },
        )
        .toList();
  }

  static Future<void> removeConnection(String connectionId) async {
    if (_client != null) {
      await _client!.from('connections').delete().eq('id', connectionId);
    } else {
      _localConnections.removeWhere((c) => c['id'] == connectionId);
    }
  }

  static Future<List<Map<String, dynamic>>> sharingGrants() async {
    if (_client != null) {
      final rows = await _client!
          .from('location_sharing')
          .select()
          .eq('owner_id', userId);
      return rows.map((row) => Map<String, dynamic>.from(row)).toList();
    }
    return _localSharingGrants.entries
        .map((e) => {'recipient_id': e.key, 'is_enabled': e.value})
        .toList();
  }

  static Future<Map<String, bool>> incomingSharingStatus() async {
    if (_client != null) {
      final rows = await _client!
          .from('location_sharing')
          .select('owner_id,is_enabled')
          .eq('recipient_id', userId);
      return {
        for (final row in rows)
          row['owner_id'] as String: row['is_enabled'] as bool,
      };
    }
    return {};
  }

  static Future<void> setSharing(String recipientId, bool enabled) async {
    if (_client != null) {
      await _client!.from('location_sharing').upsert({
        'owner_id': userId,
        'recipient_id': recipientId,
        'is_enabled': enabled,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'owner_id,recipient_id');
      if (enabled) {
        sharingActive.value = true;
      } else {
        // Publishes whether any enabled grant is left, which is what lets the
        // tracking service stop acquiring GPS it has nowhere to send.
        await _removeLocationIfNoActiveGrants();
      }
    } else {
      _localSharingGrants[recipientId] = enabled;
      sharingActive.value = _localSharingGrants.values.any((on) => on);
    }
  }

  static Future<void> setSharingForAll(bool enabled) async {
    if (_client != null) {
      final conns = await connections();
      for (final c in conns) {
        final otherId = c['other_id'] as String;
        await _client!.from('location_sharing').upsert({
          'owner_id': userId,
          'recipient_id': otherId,
          'is_enabled': enabled,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'owner_id,recipient_id');
      }
      if (enabled) {
        sharingActive.value = true;
      } else {
        await _removeLocationIfNoActiveGrants();
      }
    } else {
      if (_localSharingGrants.isEmpty && _localConnections.isNotEmpty) {
        for (final c in _localConnections) {
          _localSharingGrants[c['other_id'] as String] = enabled;
        }
      } else if (_localSharingGrants.isEmpty) {
        _localSharingGrants['default'] = enabled;
      } else {
        for (final key in _localSharingGrants.keys) {
          _localSharingGrants[key] = enabled;
        }
      }
      sharingActive.value = enabled;
    }
  }

  /// Whether at least one enabled sharing grant exists for this account.
  /// Reactive on purpose: the tracking service watches it so GPS acquisition —
  /// and the foreground-service notification that goes with it — does not outlive
  /// the authorization it exists to serve.
  static final ValueNotifier<bool> sharingActive = ValueNotifier<bool>(false);

  static Future<bool> anySharingEnabled() async {
    final bool enabled;
    if (_client != null) {
      final rows = await _client!
          .from('location_sharing')
          .select('id')
          .eq('owner_id', userId)
          .eq('is_enabled', true)
          .limit(1);
      enabled = rows.isNotEmpty;
    } else {
      enabled = _localSharingGrants.values.any((on) => on);
    }
    sharingActive.value = enabled;
    return enabled;
  }

  /// Key under which the single latest un-uploaded location fix is stored when
  /// the phone has no connectivity. Zero-trail: only ever one point is kept.
  static const String _pendingFixKey = 'kaspot_pending_fix';

  /// Test-only upload hook: when set, the real network upload is replaced by
  /// this function so offline behavior can be unit-tested deterministically.
  @visibleForTesting
  static Future<void> Function(
    double latitude,
    double longitude,
    DateTime recordedAt,
  )?
  debugUploadOverride;

  /// Returns true when the fix was accepted for upload, false when the
  /// authorization gate refused it because no enabled sharing grant is left.
  static Future<bool> upsertOwnLocation(Position position) {
    // Carry the fix's own timestamp: a location captured while offline keeps the
    // time it was measured, so reconnecting can never dress an old fix up as a
    // current one.
    return upsertOwnLocationAt(
      position.latitude,
      position.longitude,
      recordedAt: position.timestamp,
    );
  }

  /// Uploads the user's latest coordinate. When the phone is offline the fix
  /// is queued (overwriting any older pending point) and re-sent automatically
  /// by [flushPendingLocation] as soon as connectivity returns.
  static Future<bool> upsertOwnLocationAt(
    double latitude,
    double longitude, {
    DateTime? recordedAt,
  }) async {
    lastUserLatitude = latitude;
    lastUserLongitude = longitude;
    final fixTime = _sanitizeFixTime(recordedAt ?? DateTime.now().toUtc());
    try {
      if (!await anySharingEnabled()) {
        // Sharing is off: zero-trail means nothing may remain queued either.
        await clearPendingLocation();
        return false;
      }
      await _uploadLocation(latitude, longitude, fixTime);
      await clearPendingLocation();
      return true;
    } catch (_) {
      // No usable connection (or backend unreachable): keep the latest fix so
      // it can be sent the moment connectivity returns.
      await _savePendingLocation(latitude, longitude, fixTime);
      rethrow;
    }
  }

  /// A device clock running ahead would otherwise stamp a coordinate that keeps
  /// looking fresh past its retention window, so a future fix time is pulled
  /// back to the present. The database clamps this again server-side.
  static DateTime _sanitizeFixTime(DateTime recordedAt) {
    final utc = recordedAt.toUtc();
    final now = DateTime.now().toUtc();
    if (utc.isAfter(now.add(const Duration(minutes: 5)))) return now;
    return utc;
  }

  /// Sends a queued fix (if any) left over from an offline period. Safe to
  /// call any time; silently keeps the fix queued when the upload still fails.
  static Future<void> flushPendingLocation() async {
    final SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }
    final raw = prefs.getString(_pendingFixKey);
    if (raw == null) return;

    Map<String, dynamic> data;
    try {
      data = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      await prefs.remove(_pendingFixKey);
      return;
    }

    // Never upload a fix that belongs to a different account (e.g. after an
    // account switch on the same device). An empty id means nobody is signed
    // in yet; keep the fix until the rightful owner is back.
    if (userId.isEmpty || data['uid'] != userId) return;

    final latitude = (data['lat'] as num?)?.toDouble();
    final longitude = (data['lon'] as num?)?.toDouble();
    if (latitude == null || longitude == null) {
      await prefs.remove(_pendingFixKey);
      return;
    }

    final recordedAt = DateTime.tryParse(data['at'] as String? ?? '')?.toUtc();
    if (recordedAt == null) {
      // Without a trustworthy capture time the point cannot be labelled fresh,
      // so it is dropped rather than uploaded as if it had just been measured.
      await prefs.remove(_pendingFixKey);
      return;
    }
    if (DateTime.now().toUtc().difference(recordedAt) >
        LocationTrackingConfig.maxQueuedFixAge) {
      // Older than the retention window: uploading it would show a position the
      // backend would immediately refuse to serve anyway. Zero-trail: drop it.
      await prefs.remove(_pendingFixKey);
      debugPrint(
        'KaSpot dropped a queued fix older than the retention window.',
      );
      return;
    }

    try {
      if (!await anySharingEnabled()) {
        // Now that we are back online we can see sharing was revoked while
        // offline — the queued point must not be uploaded (zero-trail).
        await clearPendingLocation();
        return;
      }
      await _uploadLocation(latitude, longitude, recordedAt);
      await clearPendingLocation();
      debugPrint('KaSpot pending location synced after reconnect.');
    } catch (e) {
      debugPrint('KaSpot pending location still offline: $e');
    }
  }

  static Future<void> _uploadLocation(
    double latitude,
    double longitude,
    DateTime recordedAt,
  ) async {
    final override = debugUploadOverride;
    if (override != null) {
      await override(latitude, longitude, recordedAt);
      return;
    }
    if (_client != null) {
      await _client!.from('locations').upsert({
        'user_id': userId,
        'latitude': latitude,
        'longitude': longitude,
        'recorded_at': recordedAt.toIso8601String(),
      }, onConflict: 'user_id');
    }
  }

  static Future<void> _savePendingLocation(
    double latitude,
    double longitude,
    DateTime recordedAt,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _pendingFixKey,
        jsonEncode({
          'lat': latitude,
          'lon': longitude,
          // The time the fix was *measured*, not the time it is retried.
          'at': recordedAt.toUtc().toIso8601String(),
          'uid': userId,
        }),
      );
    } catch (_) {}
  }

  static Future<void> clearPendingLocation() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingFixKey);
    } catch (_) {}
  }

  static Future<void> _removeLocationIfNoActiveGrants() async {
    if (_client != null && !await anySharingEnabled()) {
      await _client!.from('locations').delete().eq('user_id', userId);
    }
  }

  /// True when the server-stamped retention deadline has passed. Rows written
  /// before the retention migration ships carry no `expires_at`, so they are
  /// left alone rather than being silently dropped.
  static bool _locationExpired(Map<String, dynamic> row) {
    final raw = row['expires_at'] as String?;
    if (raw == null) return false;
    final expiresAt = DateTime.tryParse(raw)?.toUtc();
    if (expiresAt == null) return false;
    return !expiresAt.isAfter(DateTime.now().toUtc());
  }

  static Future<List<Map<String, dynamic>>> sharedLocations() async {
    final rels = await circleRelationships();
    if (_client != null) {
      final grants = await _client!
          .from('location_sharing')
          .select('owner_id')
          .eq('recipient_id', userId)
          .eq('is_enabled', true);
      if (grants.isEmpty) return [];
      final ids = grants
          .map((row) => row['owner_id'] as String)
          .toSet()
          .toList();
      final locations = await _client!
          .from('locations')
          .select()
          .inFilter('user_id', ids);
      // Defense in depth: the authorized-read policy already drops expired rows,
      // but a cached response must never put a past-retention coordinate on the
      // map either.
      final live = locations.where((row) => !_locationExpired(row)).toList();
      final profiles = await _client!
          .from('profiles')
          .select('id,display_name,avatar_url')
          .inFilter('id', ids);
      final profileMap = {
        for (final profile in profiles) profile['id'] as String: profile,
      };
      return live.map((row) {
        final otherId = row['user_id'] as String;
        final profile = profileMap[otherId];
        return {
          ...Map<String, dynamic>.from(row),
          'display_name': profile?['display_name'] ?? 'KaSpot member',
          'avatar_url': profile?['avatar_url'] as String?,
          'relationship': rels[otherId] ?? 'Friend',
        };
      }).toList();
    }
    return [];
  }

  static Future<List<Map<String, dynamic>>> savedPlaces() async {
    if (_client != null) {
      final rows = await _client!
          .from('saved_places')
          .select()
          .eq('user_id', userId)
          .order('created_at');
      return rows.map((row) => Map<String, dynamic>.from(row)).toList();
    }
    return List<Map<String, dynamic>>.from(_localSavedPlaces);
  }

  static Future<void> addSavedPlace(String name, Position position) async {
    final cleanName = name.trim();
    if (_client != null) {
      await _client!.from('saved_places').insert({
        'user_id': userId,
        'name': cleanName,
        'latitude': position.latitude,
        'longitude': position.longitude,
      });
    } else {
      _localSavedPlaces.insert(0, {
        'id': 'place-${DateTime.now().millisecondsSinceEpoch}',
        'name': cleanName,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });
    }
  }

  static Future<void> deleteSavedPlace(String id) async {
    if (_client != null) {
      await _client!.from('saved_places').delete().eq('id', id);
    } else {
      _localSavedPlaces.removeWhere((p) => p['id'] == id);
    }
  }

  /// Test-only: makes preference reads and writes fail the way an unreachable
  /// backend does, so offline start-up and offline sign-out can be exercised
  /// deterministically (same role as [debugUploadOverride] plays for uploads).
  @visibleForTesting
  static Object? debugPreferenceFailure;

  static Future<Map<String, dynamic>> notificationPreferences() async {
    final failure = debugPreferenceFailure;
    if (failure != null) throw failure;
    if (_client != null) {
      final rows = await _client!
          .from('notification_preferences')
          .select()
          .eq('user_id', userId)
          .limit(1);
      if (rows.isEmpty) {
        return {
          'connection_notifications_enabled': true,
          'arrival_alerts_enabled': false,
          'background_sharing_enabled': false,
        };
      }
      return Map<String, dynamic>.from(rows.first);
    }
    return Map<String, dynamic>.from(_localPrefs);
  }

  static Future<void> setNotificationPreference(
    String field,
    bool value,
  ) async {
    final failure = debugPreferenceFailure;
    if (failure != null) throw failure;
    if (!{
      'connection_notifications_enabled',
      'arrival_alerts_enabled',
      'background_sharing_enabled',
    }.contains(field)) {
      return;
    }
    if (_client != null) {
      await _client!.from('notification_preferences').upsert({
        'user_id': userId,
        field: value,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'user_id');
    } else {
      _localPrefs[field] = value;
    }
  }

  // In-Circle Chat Messaging
  static final List<Map<String, dynamic>> _localMessages = [];

  /// Exposed for regression tests only. Do not use in production code.
  @visibleForTesting
  static List<Map<String, dynamic>> get debugLocalMessages => _localMessages;

  /// Exposed for regression tests only. Do not use in production code.
  @visibleForTesting
  static List<Map<String, dynamic>> get debugLocalRequests => _localRequests;

  /// Exposed for regression tests only. Do not use in production code.
  @visibleForTesting
  static List<Map<String, dynamic>> get debugLocalConnections =>
      _localConnections;

  /// User ID of the active chat conversation currently open in the foreground.
  /// When set, in-app banners and redundant unread increments are suppressed for this sender.
  static String? activeChatUserId;

  /// Global unread-message counts keyed by sender id.
  /// Updated by HomeShell's Realtime subscription and cleared when the
  /// recipient opens a conversation. Widgets listen via [unreadCounts].
  static final ValueNotifier<Map<String, int>> unreadCounts =
      ValueNotifier<Map<String, int>>({});

  /// Increments the in-memory unread counter for [senderId] by 1.
  static void incrementUnread(String senderId) {
    final current = Map<String, int>.from(unreadCounts.value);
    current[senderId] = (current[senderId] ?? 0) + 1;
    unreadCounts.value = current;
  }

  /// Clears the unread counter for [senderId] and marks their messages as read
  /// in the database (and in-memory test store) so the count stays at zero.
  static Future<void> markMessagesRead(String senderId) async {
    final current = Map<String, int>.from(unreadCounts.value);
    current.remove(senderId);
    unreadCounts.value = current;

    final nowIso = DateTime.now().toUtc().toIso8601String();
    for (final m in _localMessages) {
      if (m['sender_id'] == senderId &&
          m['recipient_id'] == userId &&
          m['read_at'] == null) {
        m['read_at'] = nowIso;
      }
    }

    if (_client != null) {
      try {
        await _client!
            .from('circle_messages')
            .update({'read_at': nowIso})
            .eq('sender_id', senderId)
            .eq('recipient_id', userId)
            .isFilter('read_at', null);
      } catch (e) {
        debugPrint('[KaSpot] markMessagesRead failed: $e');
      }
    }
  }

  /// Returns the total unread count across all senders.
  static int get totalUnreadCount =>
      unreadCounts.value.values.fold(0, (sum, n) => sum + n);

  /// Loads unread message counts from the database on startup so badges
  /// appear immediately even before a new Realtime event arrives.
  /// Counts all rows where recipient = me and read_at IS NULL, grouped by sender.
  static Future<void> loadUnreadCounts() async {
    if (_client == null || userId.isEmpty) return;
    try {
      final rows = await _client!
          .from('circle_messages')
          .select('sender_id')
          .eq('recipient_id', userId)
          .isFilter('read_at', null);
      final counts = <String, int>{};
      for (final row in rows) {
        final sender = row['sender_id'] as String?;
        if (sender != null && sender != userId) {
          counts[sender] = (counts[sender] ?? 0) + 1;
        }
      }
      unreadCounts.value = counts;
    } catch (e) {
      debugPrint('[KaSpot] loadUnreadCounts failed: $e');
    }
  }

  static Future<List<Map<String, dynamic>>> getCircleMessages(
    String otherUserId,
  ) async {
    if (_client != null) {
      final rows = await _client!
          .from('circle_messages')
          .select()
          .or(
            'and(sender_id.eq.$userId,recipient_id.eq.$otherUserId),and(sender_id.eq.$otherUserId,recipient_id.eq.$userId)',
          )
          .order('created_at', ascending: true);
      return rows.map((r) => Map<String, dynamic>.from(r)).toList();
    }
    return _localMessages
        .where(
          (m) =>
              (m['sender_id'] == userId && m['recipient_id'] == otherUserId) ||
              (m['sender_id'] == otherUserId && m['recipient_id'] == userId),
        )
        .map((m) => Map<String, dynamic>.from(m))
        .toList();
  }

  // ── Message Reactions ───────────────────────────────────────────────────

  /// In-memory reaction store for the local-preview path.
  /// Structure: { messageId: [ { id, message_id, user_id, emoji, created_at, updated_at } ] }
  static final Map<String, List<Map<String, dynamic>>> _localReactions = {};

  /// Exposed for regression tests only.
  @visibleForTesting
  static Map<String, List<Map<String, dynamic>>> get debugLocalReactions =>
      _localReactions;

  /// Loads reactions for a list of message IDs in a single query.
  /// Returns a map of messageId → list of reaction rows.
  static Future<Map<String, List<Map<String, dynamic>>>>
  getReactionsForMessages(List<String> messageIds) async {
    if (messageIds.isEmpty) return {};

    // Strip temporary optimistic IDs that have no server record yet.
    final stableIds = messageIds
        .where((id) => !id.startsWith('temp-'))
        .toList();
    if (stableIds.isEmpty) return {};

    if (_client != null) {
      try {
        final rows = await _client!
            .from('message_reactions')
            .select('id, message_id, user_id, emoji, created_at, updated_at')
            .inFilter('message_id', stableIds);
        final result = <String, List<Map<String, dynamic>>>{};
        for (final row in rows) {
          final mid = row['message_id'] as String;
          result.putIfAbsent(mid, () => []);
          result[mid]!.add(Map<String, dynamic>.from(row));
        }
        return result;
      } catch (e) {
        debugPrint('[KaSpot] getReactionsForMessages failed: $e');
        return {};
      }
    }

    // Local-preview path.
    final result = <String, List<Map<String, dynamic>>>{};
    for (final id in stableIds) {
      result[id] = (_localReactions[id] ?? [])
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    }
    return result;
  }

  /// Adds or replaces the current user's reaction on [messageId].
  /// Returns the confirmed reaction row.
  static Future<void> upsertReaction(String messageId, String emoji) async {
    final myId = userId;
    if (myId.isEmpty) throw Exception('Not authenticated.');
    if (messageId.startsWith('temp-')) {
      throw Exception('Cannot react to a message that has not been saved yet.');
    }

    if (_client != null) {
      await _client!.rpc(
        'upsert_reaction',
        params: {'p_message_id': messageId, 'p_emoji': emoji},
      );
      return;
    }

    // Local-preview path.
    _localReactions.putIfAbsent(messageId, () => []);
    final list = _localReactions[messageId]!;
    final existing = list.indexWhere((r) => r['user_id'] == myId);
    final now = DateTime.now().toUtc().toIso8601String();
    if (existing >= 0) {
      list[existing]['emoji'] = emoji;
      list[existing]['updated_at'] = now;
    } else {
      final rxnSeq = _localSessionSeq++;
      list.add({
        'id': 'rxn-${DateTime.now().millisecondsSinceEpoch}-$rxnSeq',
        'message_id': messageId,
        'user_id': myId,
        'emoji': emoji,
        'created_at': now,
        'updated_at': now,
      });
    }
  }

  /// Removes the current user's reaction from [messageId].
  static Future<void> removeReaction(String messageId) async {
    final myId = userId;
    if (myId.isEmpty) throw Exception('Not authenticated.');

    if (_client != null) {
      try {
        await _client!
            .from('message_reactions')
            .delete()
            .eq('message_id', messageId)
            .eq('user_id', myId);
      } catch (e) {
        debugPrint('[KaSpot] removeReaction failed: $e');
        rethrow;
      }
      return;
    }

    // Local-preview path.
    _localReactions[messageId]?.removeWhere((r) => r['user_id'] == myId);
  }

  // ── End Message Reactions ────────────────────────────────────────────────

  static Future<void> sendCircleMessage(
    String recipientId,
    String content, {
    String? replyToMessageId,
  }) async {
    final cleanContent = content.trim();
    if (cleanContent.isEmpty) throw Exception('Message cannot be empty.');
    if (recipientId == userId) throw Exception('You cannot message yourself.');
    if (cleanContent.length > 500) {
      throw Exception('Message is too long (max 500 characters).');
    }

    if (_client != null) {
      // Failures (e.g. the connection was just removed) must surface to the
      // user: silently storing the message locally would fake a delivery the
      // other member never receives.
      final insertData = <String, dynamic>{
        'sender_id': userId,
        'recipient_id': recipientId,
        'content': cleanContent,
      };
      if (replyToMessageId != null && replyToMessageId.isNotEmpty) {
        insertData['reply_to_message_id'] = replyToMessageId;
      }
      await _client!.from('circle_messages').insert(insertData);
      return;
    }
    // Use a monotonically incrementing suffix so that messages seeded in
    // rapid succession (e.g. inside Flutter widget tests with fake time) always
    // receive distinct IDs even when millisecondsSinceEpoch doesn't advance.
    final msgSeq = _localSessionSeq++;
    _localMessages.add({
      'id': 'msg-${DateTime.now().millisecondsSinceEpoch}-$msgSeq',
      'sender_id': userId,
      'recipient_id': recipientId,
      'content': cleanContent,
      if (replyToMessageId != null && replyToMessageId.isNotEmpty)
        'reply_to_message_id': replyToMessageId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'read_at': null,
    });
  }
}

/// Result of [KaSpotService.deleteAccount].
///
/// A separate value rather than a bare success, because "the account is gone but
/// the server could not prove the associated records were removed" must never be
/// shown as either a clean success or as "nothing happened".
enum DeleteAccountOutcome {
  /// The auth account and every checked associated record were removed.
  deleted,

  /// The auth account is gone; at least one associated table could not be
  /// verified (or still held a row after the explicit retry). The device is
  /// signed out and the condition is reported to the user for follow-up.
  deletedWithUnverifiedCleanup,
}
