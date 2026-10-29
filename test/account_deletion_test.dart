import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspot/screens/delete_account_screen.dart';
import 'package:kaspot/screens/profile_screen.dart';
import 'package:kaspot/services/background_location_service.dart';
import 'package:kaspot/services/kaspot_service.dart';
import 'package:kaspot/utils/release_flags.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Account deletion: the promise the privacy policy makes ("Account & Privacy →
/// Delete Account … only then asks the server to delete the account") is only
/// worth anything if the screen cannot delete on open, cannot delete without the
/// typed confirmation, and cannot report success when the request failed.
const String _buttonLabel = 'Delete my account permanently';
const String _successText = 'Your KaSpot account and its data were deleted.';

void main() {
  setUp(() async {
    KaSpotService.enableLocalPreview();
    // The flow is opt-in at build time; these tests exercise the enabled state.
    ReleaseFlags.accountDeletionEnabled = true;
    // Both the preference store and the queued-fix handoff use this plugin; an
    // unmocked store blocks its platform channel inside a widget test.
    SharedPreferences.setMockInitialValues({});
    KaSpotService.debugDeleteAccountOverride = null;
    KaSpotService.unreadCounts.value = {};
    KaSpotService.activeChatUserId = null;
    KaSpotService.passwordRecoveryActive.value = false;
    await KaSpotService.signIn('member@kaspot.app', 'password123');
    await KaSpotService.setSharingForAll(true);
    await KaSpotService.setNotificationPreference(
      'connection_notifications_enabled',
      true,
    );
  });

  tearDown(() {
    KaSpotService.debugDeleteAccountOverride = null;
    ReleaseFlags.accountDeletionEnabled = false;
  });

  /// A tall viewport so the whole screen is built: the confirmation field and
  /// the button sit at the bottom of a lazily built list.
  Future<void> pumpScreen(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: DeleteAccountScreen()));
    await tester.pumpAndSettle();
  }

  // Keyed so the finds survive the lazily built list: the confirmation step
  // sits below the fold on a phone-sized viewport.
  final Finder passwordField = find.byKey(const Key('delete-account-password'));
  final Finder confirmField = find.byKey(const Key('delete-account-confirm'));
  final Finder submitButton = find.byKey(const Key('delete-account-submit'));

  /// Scrolls the page until [target] is built, then settles.
  Future<void> reveal(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  FilledButton deleteButton(WidgetTester tester) =>
      tester.widget<FilledButton>(submitButton);

  Future<void> armAndSubmit(
    WidgetTester tester, {
    String password = 'password123',
  }) async {
    await reveal(tester, passwordField);
    await tester.enterText(passwordField, password);
    await reveal(tester, confirmField);
    await tester.enterText(confirmField, 'DELETE');
    await tester.pump();
    await reveal(tester, submitButton);
    await tester.tap(submitButton);
  }

  group('Entry point', () {
    testWidgets('Account & Privacy offers deletion without performing one', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var calls = 0;
      KaSpotService.debugDeleteAccountOverride =
          ({password, googleIdToken}) async {
            calls++;
            return DeleteAccountOutcome.deleted;
          };

      await tester.pumpWidget(const MaterialApp(home: ProfileScreen()));
      await tester.pumpAndSettle();

      expect(find.text('Delete Account'), findsOneWidget);
      await tester.tap(find.text('Delete Account'));
      await tester.pumpAndSettle();

      expect(find.byType(DeleteAccountScreen), findsOneWidget);
      expect(calls, 0);
      expect(KaSpotService.isAuthenticated, isTrue);
    });

    testWidgets('opening the screen sends nothing and deletes nothing', (
      tester,
    ) async {
      var calls = 0;
      KaSpotService.debugDeleteAccountOverride =
          ({password, googleIdToken}) async {
            calls++;
            return DeleteAccountOutcome.deleted;
          };
      await pumpScreen(tester);

      // initState only reads local state; the destructive call needs a tap.
      expect(calls, 0);
      expect(KaSpotService.isAuthenticated, isTrue);
      await reveal(tester, submitButton);
      expect(find.text(_buttonLabel), findsOneWidget);
      expect(deleteButton(tester).onPressed, isNull);
      expect(find.text(_successText), findsNothing);
    });

    testWidgets('a build without a verified endpoint does not offer deletion', (
      tester,
    ) async {
      ReleaseFlags.accountDeletionEnabled = false;
      tester.view.physicalSize = const Size(420, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: ProfileScreen()));
      await tester.pumpAndSettle();

      // The function is not deployed, so the screen is not advertised: a
      // deletion screen that cannot delete is worse than no button.
      expect(find.text('Delete Account'), findsNothing);
      expect(find.text('Sign Out'), findsOneWidget);
    });

    testWidgets('the screen states what will be removed before confirming', (
      tester,
    ) async {
      await pumpScreen(tester);

      for (final entry in const [
        'Account and sign-in',
        'Profile photo',
        'Your location',
        'Your circle',
        'Messages',
        'Saved places',
        'Notifications',
      ]) {
        await reveal(tester, find.text(entry));
        expect(
          find.text(entry),
          findsOneWidget,
          reason: 'deletion consequences omit: $entry',
        );
      }
      await reveal(tester, find.text('Type DELETE to confirm.'));
      expect(find.text('Type DELETE to confirm.'), findsOneWidget);
    });
  });

  group('Confirmation gate', () {
    testWidgets('the button only arms once DELETE is typed', (tester) async {
      await pumpScreen(tester);
      expect(find.text('This cannot be undone'), findsOneWidget);
      await reveal(tester, submitButton);
      expect(deleteButton(tester).onPressed, isNull);

      await tester.enterText(confirmField, 'DELET');
      await tester.pump();
      expect(deleteButton(tester).onPressed, isNull);

      // Letter case and surrounding spaces are tolerated; the word is not.
      await tester.enterText(confirmField, ' delete ');
      await tester.pump();
      expect(deleteButton(tester).onPressed, isNotNull);

      await tester.enterText(confirmField, 'DELETE MY ACCOUNT');
      await tester.pump();
      expect(deleteButton(tester).onPressed, isNull);
    });

    testWidgets('an empty password stops the request before it is sent', (
      tester,
    ) async {
      var calls = 0;
      KaSpotService.debugDeleteAccountOverride =
          ({password, googleIdToken}) async {
            calls++;
            return DeleteAccountOutcome.deleted;
          };
      await pumpScreen(tester);

      await reveal(tester, confirmField);
      await tester.enterText(confirmField, 'DELETE');
      await tester.pump();
      await reveal(tester, submitButton);
      await tester.tap(submitButton);
      await tester.pumpAndSettle();

      expect(find.text('Enter your password to confirm.'), findsOneWidget);
      expect(calls, 0);
      expect(KaSpotService.isAuthenticated, isTrue);
    });
  });

  group('Deletion', () {
    testWidgets('success clears this device, tracking and the session', (
      tester,
    ) async {
      var calls = 0;
      KaSpotService.debugDeleteAccountOverride =
          ({password, googleIdToken}) async {
            calls++;
            return DeleteAccountOutcome.deleted;
          };
      KaSpotService.unreadCounts.value = {'other-user': 3};
      KaSpotService.activeChatUserId = 'other-user';
      BackgroundLocationService.isBackgroundSharingEnabled.value = true;
      BackgroundLocationService.state.value = TrackingState.suspendedNoSharing;

      await pumpScreen(tester);
      await armAndSubmit(tester);
      await tester.pumpAndSettle();

      expect(calls, 1);
      expect(find.text(_successText), findsOneWidget);
      expect(KaSpotService.isAuthenticated, isFalse);
      expect(KaSpotService.userId, isEmpty);

      // State that belongs to the account must not survive for the next one on
      // this phone.
      expect(KaSpotService.unreadCounts.value, isEmpty);
      expect(KaSpotService.activeChatUserId, isNull);
      expect(
        BackgroundLocationService.isBackgroundSharingEnabled.value,
        isFalse,
      );
      expect(BackgroundLocationService.state.value, TrackingState.off);
    });

    testWidgets('the typed password is the credential handed to the service', (
      tester,
    ) async {
      String? sentPassword;
      String? sentGoogle;
      KaSpotService.debugDeleteAccountOverride =
          ({password, googleIdToken}) async {
            sentPassword = password;
            sentGoogle = googleIdToken;
            return DeleteAccountOutcome.deleted;
          };

      await pumpScreen(tester);
      await armAndSubmit(tester, password: 'correct horse battery staple');
      await tester.pumpAndSettle();

      // The password leaves the screen only through the deletion call, and no
      // Google token is sent on the password path.
      expect(sentPassword, 'correct horse battery staple');
      expect(sentGoogle, isNull);
    });

    testWidgets(
      'an unverified cleanup is reported as deleted, not as clean success',
      (tester) async {
        KaSpotService.debugDeleteAccountOverride = ({
          password,
          googleIdToken,
        }) async => DeleteAccountOutcome.deletedWithUnverifiedCleanup;

        await pumpScreen(tester);
        await armAndSubmit(tester);
        await tester.pumpAndSettle();

        // The auth account is gone: reporting "nothing was removed" would be
        // false, and reporting a clean success would be unproven.
        expect(
          find.text(KaSpotService.deleteAccountCleanupUnverifiedMessage),
          findsOneWidget,
        );
        expect(find.text(_successText), findsNothing);
        expect(KaSpotService.isAuthenticated, isFalse);
      },
    );

    testWidgets('a failed request keeps the account and says nothing was '
        'removed', (tester) async {
      KaSpotService.debugDeleteAccountOverride =
          ({password, googleIdToken}) async {
            throw Exception('The server refused.');
          };
      KaSpotService.unreadCounts.value = {'other-user': 3};

      await pumpScreen(tester);
      await armAndSubmit(tester);
      await tester.pumpAndSettle();

      expect(find.text('The server refused.'), findsOneWidget);
      expect(find.text(_successText), findsNothing);
      expect(KaSpotService.isAuthenticated, isTrue);
      expect(KaSpotService.unreadCounts.value, {'other-user': 3});
    });

    testWidgets('an in-flight deletion cannot be submitted twice', (
      tester,
    ) async {
      final gate = Completer<void>();
      var calls = 0;
      KaSpotService.debugDeleteAccountOverride =
          ({password, googleIdToken}) async {
            calls++;
            await gate.future;
            return DeleteAccountOutcome.deleted;
          };

      await pumpScreen(tester);
      await armAndSubmit(tester);
      await tester.pump();

      expect(calls, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // The label is replaced by the spinner, so the button itself is the only
      // way to prove the tap target is dead while the call is open.
      expect(deleteButton(tester).onPressed, isNull);
      await tester.tap(submitButton, warnIfMissed: false);
      await tester.pump();
      expect(calls, 1);

      gate.complete();
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(KaSpotService.isAuthenticated, isFalse);
    });
  });

  /// The Flutter tests above cannot reach a Supabase stack, so the server-side
  /// contract is pinned here: identity from the caller's token, a credential
  /// verified for the request, an admin delete, and a re-read that does not
  /// trust the cascade.
  ///
  /// These assertions read the source, so they can only prove that a check is
  /// still present. The two decisions they guard — what counts as a credential
  /// and what counts as "already deleted" — are executed for real by
  /// `supabase/functions/delete-account/logic_test.ts` under `deno test`.
  /// Neither replaces a staging run against real accounts.
  group('delete-account function contract', () {
    late String source;

    setUpAll(() {
      // The handler lives in index.ts; the two security decisions were moved to
      // logic.ts so they can be tested without starting the HTTP server, and the
      // Google credential check lives in google_token.ts for the same reason. The
      // contract below spans all three files.
      source = [
        File('supabase/functions/delete-account/index.ts').readAsStringSync(),
        File('supabase/functions/delete-account/logic.ts').readAsStringSync(),
        File('supabase/functions/delete-account/google_token.ts')
            .readAsStringSync(),
      ].join('\n');
    });

    test(
      'identity comes from the token; the body can only carry a credential',
      () {
        // Split so `deno fmt` wrapping the call chain cannot break the check.
        expect(source, contains('callerClient.auth'));
        expect(source, contains('.getUser(accessToken)'));
        expect(source, contains('admin.auth.admin.deleteUser(user.id)'));

        // The body IS read now — but only for a credential, never for an id.
        final start = source.indexOf('async function readCredential(');
        expect(start, greaterThan(-1));
        final reader = source.substring(start, source.indexOf('\n}', start));
        expect(reader, contains('record.password'));
        expect(reader, contains('record.google_id_token'));
        expect(reader, isNot(contains('user_id')));
        expect(reader, isNot(contains('userId')));
      },
    );

    test('re-authentication never asks the auth server for an OTP', () {
      // gotrue 2.27.3 `reauthenticate()` only sends a re-authentication OTP
      // (`GET /reauthenticate`, returns void) and verifies nothing, so using it
      // would spam the user and prove nothing.
      final service = File('lib/services/kaspot_service.dart')
          .readAsStringSync();
      expect(service, isNot(contains('auth.reauthenticate(')));
      expect(service, contains('signInWithIdToken('));
      expect(service, contains('forceAccountChoice: true'));
    });

    test('there is no timestamp-only re-authentication path', () {
      expect(source, isNot(contains('REAUTH_WINDOW_MS')));
      expect(source, isNot(contains('hasRecentSignIn(')));
      expect(source, isNot(contains('reauth_required')));
    });

    test('the password is verified server-side with the sign-in service', () {
      expect(source, contains('authClient.auth.signInWithPassword('));
      expect(source, contains('data?.user?.id === expectedUserId'));
      expect(source, contains("json({ error: 'password_mismatch' }, 403)"));
      // The password must never be logged or echoed back.
      expect(source, isNot(contains('console.log(')));
      expect(source, isNot(contains('console.error(password')));
      expect(source, isNot(contains('JSON.stringify(credential')));
    });

    test('a Google token is verified by Google, then bound to this account', () {
      // Signature, issuer and expiry are checked by google-auth-library's
      // verifyIdToken, not by reading claims out of a decoded token.
      expect(source, contains('client.verifyIdToken({ idToken, audience })'));
      expect(
        source,
        isNot(contains('fetch(')),
        reason:
            'no ad-hoc HTTP verification call: the library owns the JWKS fetch',
      );
      expect(source, contains('GOOGLE_WEB_CLIENT_ID'));
      expect(source, contains('identity_data?.sub'));

      // The claims this repository re-asserts itself.
      expect(source, contains('payload.aud !== audience'));
      expect(source, contains('GOOGLE_ISSUERS.has(payload.iss)'));
      expect(source, contains('payload.sub !== subject'));
      expect(source, contains('expiresAt * 1000 <= now'));

      expect(source, contains("json({ error: 'google_mismatch' }, 403)"));
      expect(source, contains("json({ error: 'google_token_invalid' }, 403)"));
      // The token itself must never be logged or echoed.
      expect(source, isNot(contains('console.error(idToken')));
    });

    test(
      'the cascade is verified, retried, and never reported as clean when it '
      'cannot be checked',
      () {
        expect(source, contains('verifyCleanup(admin, user.id)'));
        expect(
          source,
          contains('forceCleanup(admin, user.id, report.remaining)'),
        );
        expect(source, contains("profiles: ['id']"));
        expect(source, contains("error: 'cleanup_incomplete'"));
        expect(source, contains("error: 'cleanup_unverified'"));
        expect(source, contains("json({ deleted: true }, 200)"));
        // A table that could not be read is not evidence of cleanliness.
        expect(source, isNot(contains('if (error) continue;')));
      },
    );

    test('a repeated request does not report a false failure', () {
      expect(source, contains('admin.auth.admin'));
      expect(source, contains('getUserById(user.id)'));
      expect(source, contains("json({ error: 'deletion_unconfirmed'"));
    });

    test('"already deleted" is read from the 404, not from a null user', () {
      // The Admin SDK answers a missing id with `user: null` AND an error, so
      // testing the user alone would classify every repeat as unconfirmed — the
      // client would then keep the session and tell the user to retry an account
      // that no longer exists.
      expect(source, contains('isUserNotFound(lookupError)'));
      expect(source, contains("record.status === 404"));
      expect(source, contains("'user_not_found'"));
      expect(source, contains('if (!gone && lookupError)'));
      expect(source, contains('if (!gone && lookup?.user)'));
      // A false positive here would report a failed delete as a finished one.
      expect(source, isNot(contains('lookupError.message')));
    });

    test('the service-role key stays in the server environment', () {
      // Read from the function's own environment, never returned or logged.
      expect(source, contains("Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')"));
      expect(
        source,
        isNot(contains('console.log(')),
        reason: 'stdout is not a safe place for request detail',
      );
    });
  });
}
