import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspot/screens/profile_screen.dart';
import 'package:kaspot/services/kaspot_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The notification switches used to be called "Connection Requests" while the
/// stored field also silenced chat banners, and the push payload used to carry
/// the sender's name and the first 80 characters of the message. Both are now
/// something the privacy policy can describe truthfully, so both are pinned
/// here.
void main() {
  setUp(() async {
    KaSpotService.enableLocalPreview();
    SharedPreferences.setMockInitialValues({});
    await KaSpotService.signIn('member@kaspot.app', 'password123');
    await KaSpotService.setNotificationPreference(
      'connection_notifications_enabled',
      true,
    );
    await KaSpotService.setNotificationPreference(
      'arrival_alerts_enabled',
      false,
    );
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: NotificationsScreen()));
    await tester.pumpAndSettle();
  }

  SwitchListTile switchAt(WidgetTester tester, int index) =>
      tester.widget<SwitchListTile>(find.byType(SwitchListTile).at(index));

  group('Switch labels', () {
    testWidgets('each switch describes what it actually controls', (
      tester,
    ) async {
      await pumpSettings(tester);

      expect(find.text('Messages & invitations'), findsOneWidget);
      expect(find.text('Arrival & Departure Alerts'), findsOneWidget);
      // The old label promised less than the setting did.
      expect(find.text('Connection Requests'), findsNothing);

      expect(
        find.textContaining(
          'Messages still arrive in the chat when this is off.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Shown inside KaSpot while it is open'),
        findsOneWidget,
      );
    });

    testWidgets('the screen separates KaSpot switches from the OS permission', (
      tester,
    ) async {
      await pumpSettings(tester);

      expect(find.text('Two separate things'), findsOneWidget);
      expect(
        find.textContaining(
          'if the system permission is off, no alert can appear',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the Account & Privacy tile promises both kinds of alert', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: ProfileScreen()));
      await tester.pumpAndSettle();

      expect(
        find.text('Messages, invitations and arrival alerts'),
        findsOneWidget,
      );
    });
  });

  group('Preference behaviour', () {
    testWidgets('turning messages off is stored and survives a reopen', (
      tester,
    ) async {
      await pumpSettings(tester);
      expect(switchAt(tester, 0).value, isTrue);

      await tester.tap(find.text('Messages & invitations'));
      await tester.pumpAndSettle();

      expect(switchAt(tester, 0).value, isFalse);
      expect(
        (await KaSpotService.notificationPreferences())['connection_notifications_enabled'],
        isFalse,
      );

      // Rebuilding the screen reads the stored value, not a default.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(const MaterialApp(home: NotificationsScreen()));
      await tester.pumpAndSettle();
      expect(switchAt(tester, 0).value, isFalse);
    });

    testWidgets('arrival alerts are stored separately from messages', (
      tester,
    ) async {
      await pumpSettings(tester);
      expect(switchAt(tester, 1).value, isFalse);

      await tester.tap(find.text('Arrival & Departure Alerts'));
      await tester.pumpAndSettle();

      final prefs = await KaSpotService.notificationPreferences();
      expect(prefs['arrival_alerts_enabled'], isTrue);
      // Switching arrivals on must never re-enable message alerts.
      expect(prefs['connection_notifications_enabled'], isTrue);
      expect(switchAt(tester, 0).value, isTrue);
    });

    testWidgets('a rejected write rolls the switch back', (tester) async {
      await pumpSettings(tester);

      KaSpotService.debugPreferenceFailure = Exception('Server is down.');
      addTearDown(() => KaSpotService.debugPreferenceFailure = null);

      await tester.tap(find.text('Messages & invitations'));
      await tester.pumpAndSettle();

      expect(switchAt(tester, 0).value, isTrue);
      // The failure hook throws on reads too, so it is cleared before the store
      // is inspected: the value must be the one that was already there.
      KaSpotService.debugPreferenceFailure = null;
      expect(
        (await KaSpotService.notificationPreferences())['connection_notifications_enabled'],
        isTrue,
      );
    });
  });

  /// The function itself needs a deployed Supabase project, so what is checked
  /// here is that the pipeline still builds a payload with no conversation
  /// content in it. The payload shape, the recipient targeting and the caller
  /// authentication boundary are all executed for real under `deno test`
  /// (`supabase/functions/notify-new-message/*_test.ts`); these assertions only
  /// keep the wiring in place and are cheap to read.
  group('Push payload', () {
    late String source;

    setUpAll(() {
      // index.ts wires the clients, handler.ts is the pipeline, payload.ts
      // builds what leaves the server, webhook_secret.ts authenticates the
      // caller. All four are part of the same promise.
      source = [
        'index.ts',
        'handler.ts',
        'payload.ts',
        'webhook_secret.ts',
      ]
          .map(
            (name) => File(
              'supabase/functions/notify-new-message/$name',
            ).readAsStringSync(),
          )
          .join('\n');
    });

    test('the alert text is generic', () {
      expect(
        source,
        contains("const GENERIC_TITLE = 'New message in KaSpot';"),
      );
      expect(
        source,
        contains("const GENERIC_BODY = 'Open KaSpot to view your message';"),
      );
    });

    test('no sender name and no message preview are looked up or sent', () {
      expect(
        source,
        isNot(contains("from('profiles')")),
        reason: 'the sender display name must not be fetched for a push',
      );
      expect(
        source,
        isNot(contains('.substring(')),
        reason: 'the message text must never be truncated into a preview',
      );
      expect(
        source,
        isNot(contains('record.content')),
        reason: 'the message body in the webhook payload must never be read',
      );
    });

    test('tap routing and recipient targeting are unchanged', () {
      expect(source, contains("type: 'circle_message'"));
      expect(source, contains('sender_id,'));
      expect(source, contains('message_id:'));
      expect(
        source,
        contains('.eq(\'user_id\', userId)'),
        reason: 'device tokens are still looked up per recipient',
      );
      // The recipient comes from the stored row, never from the request body.
      expect(source, contains('store.deviceTokens(message.recipient_id)'));
    });

    test('the outgoing payload has routing keys only, never content', () {
      final start = source.indexOf('export function buildRoutingData(');
      expect(start, greaterThan(-1));
      final end = source.indexOf('\n}', start);
      final block = source.substring(start, end);

      // Shorthand properties (sender_id) have no colon, so both forms count.
      final keys = RegExp(
        r'^\s{4}([a-z_]+)[,:]',
        multiLine: true,
      ).allMatches(block).map((match) => match.group(1)).toList();
      expect(keys, ['type', 'sender_id', 'message_id', 'title', 'body']);
      expect(block, isNot(contains('content')));
      expect(block, isNot(contains('display_name')));
      expect(block, isNot(contains('avatar')));
    });

    test('the recipient preference still gates delivery', () {
      expect(
        source,
        contains('data?.connection_notifications_enabled !== false'),
      );
    });
  });

  /// The endpoint must not be callable by anyone who learns its URL. These are
  /// wiring checks; the behavioural proof (401 without a secret, no database
  /// read, no push) is in `supabase/functions/notify-new-message/handler_test.ts`.
  group('Webhook authentication', () {
    late String config;
    late String handler;
    late String secret;

    setUpAll(() {
      config = File('supabase/config.toml').readAsStringSync();
      handler = File(
        'supabase/functions/notify-new-message/handler.ts',
      ).readAsStringSync();
      secret = File(
        'supabase/functions/notify-new-message/webhook_secret.ts',
      ).readAsStringSync();
    });

    test('the gateway check is off only because the handler checks', () {
      final section = config.indexOf('[functions.notify-new-message]');
      expect(section, greaterThan(-1));
      expect(
        config.substring(section),
        contains('verify_jwt = false'),
        reason: 'pg_net cannot present a user JWT',
      );
      // The function must not be shipped with the gateway check off and nothing
      // in its place.
      expect(handler, contains('readPresentedSecret(req)'));
      expect(handler, contains('secretsMatch(presented, expected)'));
      expect(handler, contains("json({ error: 'unauthorized' }, 401)"));
    });

    test('the function fails closed when no secret is configured', () {
      expect(handler, contains('expected.length < MIN_SECRET_LENGTH'));
      expect(handler, contains("json({ error: 'server_configuration' }, 500)"));
    });

    test('the documented header is the one the webhook sets', () {
      expect(secret, contains("'x-kaspot-webhook-secret'"));
      expect(secret, contains('MIN_SECRET_LENGTH = 32'));
      // Both sides of the comparison are hashed first, so the check cannot
      // short-circuit on the first differing byte or reveal a length.
      expect(secret, contains("crypto.subtle.digest('SHA-256'"));
      expect(secret, contains('difference |= a[i] ^ b[i]'));
    });

    test('no secret is ever logged or returned', () {
      for (final file in [handler, secret]) {
        expect(file, isNot(contains('console.log(')));
        expect(file, isNot(contains('console.error(presented')));
        expect(file, isNot(contains('console.error(expected')));
      }
    });
  });
}
