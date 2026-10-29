import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kaspot/screens/privacy_policy_screen.dart';
import 'package:kaspot/screens/profile_screen.dart';
import 'package:kaspot/services/kaspot_service.dart';
import 'package:kaspot/utils/location_tracking_config.dart';
import 'package:kaspot/utils/privacy_policy_content.dart';
import 'package:kaspot/utils/release_flags.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The screen's single scroll view.
Finder get _page => find.byType(SingleChildScrollView);

void main() {
  setUp(() async {
    KaSpotService.enableLocalPreview();
    // The published text for a build that offers deletion. The disabled-build
    // wording is asserted separately below.
    ReleaseFlags.accountDeletionEnabled = true;
    // Signing out and the settings screens touch the preference store; an
    // unmocked store blocks its platform channel inside a widget test.
    SharedPreferences.setMockInitialValues({});
    await KaSpotService.signIn('member@kaspot.app', 'password123');
    await KaSpotService.setSharingForAll(true);
  });

  tearDown(() {
    ReleaseFlags.accountDeletionEnabled = false;
  });

  /// The policy screen with an optional text-scale override, so the layout can
  /// be exercised the way an accessibility setting would.
  Widget app({double textScale = 1.0}) {
    return MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: const PrivacyPolicyScreen(),
        ),
      ),
    );
  }

  void useView(WidgetTester tester, double width, double height) {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  ScrollableState scrollState(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).first);

  group('Entry point', () {
    testWidgets('Account & Privacy opens the policy and back returns to it', (
      tester,
    ) async {
      useView(tester, 400, 1200);
      await tester.pumpWidget(const MaterialApp(home: ProfileScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Privacy Policy'));
      await tester.pumpAndSettle();

      expect(find.byType(PrivacyPolicyScreen), findsOneWidget);
      // One title only: the app bar's. No second oversized page heading.
      expect(find.widgetWithText(AppBar, 'Privacy Policy'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(find.text('Your KaSpot Circle Code'), findsOneWidget);
    });
  });

  group('Document structure', () {
    testWidgets('title, effective date and every section render', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Effective $privacyPolicyEffective'),
        findsOneWidget,
      );
      // Each title appears twice: once in the table of contents, once as the
      // section heading. A missing heading would leave a dead table of contents.
      for (final section in privacyPolicySections) {
        expect(
          find.text(section.title),
          findsNWidgets(2),
          reason: 'missing heading or contents entry: ${section.title}',
        );
      }
    });

    testWidgets('every original topic is still covered, in accurate wording', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      const mustKeep = [
        // Overview
        'We built this app around a simple principle',
        'does not sell your data, does not run advertising or profiling',
        'service providers process data so the app can run',
        // Information we collect
        'Account information',
        'Profile picture',
        'Device token',
        'no history, no routes, no movement trails',
        // How we use information
        'We do not use your data for advertising, profiling',
        // Location design
        'One point, never a trail',
        'keeps no record of where you have been',
        // Notifications
        "device's notification system",
        // Storage, retention, security
        'Data is encrypted in transit using TLS',
        'Retention',
        // Who can access your data
        'Service providers',
        'KaSpot operators',
        // Rights and choices
        'verifies your password or Google account again',
        // Children, changes, contact
        'under the age of 13',
        'Continuing to use KaSpot after a policy update',
        'does not currently publish a privacy contact address',
        // Footer
        'Privacy-first location sharing',
        'This policy applies to the KaSpot mobile application.',
      ];

      for (final snippet in mustKeep) {
        expect(
          find.textContaining(snippet),
          findsWidgets,
          reason: 'policy content missing: $snippet',
        );
      }
    });

    testWidgets('claims the implementation contradicted are not published', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // Each of these appeared in the previous policy and failed the audit:
      // a processor claim, a nonexistent support channel, an at-rest guarantee
      // the codebase cannot attest to, a deletion promise no flow honoured, and
      // a notice mechanism that was never built.
      const retired = [
        'any third party',
        'the app\'s feedback channel',
        'KaSpot Support',
        'We aim to respond within 5 business days',
        'industry-standard encryption in transit',
        'permanently removed',
        'we will notify you through the app',
        'Only you and the person you are chatting with can read',
        'immediately when you disable sharing',
      ];

      for (final snippet in retired) {
        expect(
          find.textContaining(snippet),
          findsNothing,
          reason: 'retracted claim is still published: $snippet',
        );
      }
    });

    testWidgets('a build without a verified endpoint says deletion is off', (
      tester,
    ) async {
      ReleaseFlags.accountDeletionEnabled = false;

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // The build cannot delete an account, so the policy must not send the
      // reader to a screen that cannot do it.
      expect(
        find.textContaining(
          'in-app account deletion is not enabled in this build',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('verifies your password or Google account again'),
        findsNothing,
      );
      // The contact card is the other place the policy names the deletion
      // screen; it must be flag-dependent too, not just the choices section.
      expect(
        find.textContaining('it is available in the app under Account & Privacy'),
        findsNothing,
      );
    });

    testWidgets('background cadence uses the values the app applies', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // The policy must read the same constants the tracking service uses, so a
      // tuning change cannot leave the document describing a different cadence.
      final seconds = LocationTrackingConfig.streamInterval.inSeconds;
      final heartbeat = LocationTrackingConfig.heartbeatInterval.inSeconds;
      expect(find.textContaining('about every $seconds seconds'), findsWidgets);
      expect(find.textContaining('every $heartbeat seconds'), findsWidgets);
      expect(
        find.textContaining(LocationTrackingConfig.notificationTitle),
        findsWidgets,
      );
    });
  });

  group('Scrolling and navigation', () {
    testWidgets('long content scrolls down to the footer', (tester) async {
      useView(tester, 320, 480);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final footer = find.text(privacyPolicyFooterScope);
      // The page is taller than the phone: the footer starts below the fold.
      expect(tester.getRect(footer).top, greaterThan(480));

      await tester.scrollUntilVisible(
        footer,
        400,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.getRect(footer).bottom, lessThanOrEqualTo(481));
      expect(tester.takeException(), isNull);
    });

    testWidgets('table of contents scrolls to the tapped section', (
      tester,
    ) async {
      useView(tester, 360, 640);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final target = privacyPolicySections[5];
      final contentsEntry = find.text(target.title).first;
      await tester.tap(contentsEntry);
      await tester.pumpAndSettle();

      // The heading lands at the top of the viewport rather than anywhere on
      // the page, and the page really moved.
      final heading = find.text(target.title).last;
      expect(tester.getTopLeft(heading).dy, inInclusiveRange(40, 160));
      expect(scrollState(tester).position.pixels, greaterThan(0));
      expect(tester.takeException(), isNull);
    });
  });

  group('Privacy controls', () {
    testWidgets('policy links to the real settings screens without changing '
        'sharing state', (tester) async {
      useView(tester, 400, 900);
      final sharingBefore = await KaSpotService.anySharingEnabled();

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // Informational only: the page owns no toggles.
      expect(find.byType(Switch), findsNothing);
      expect(find.byType(SwitchListTile), findsNothing);

      await tester.scrollUntilVisible(
        find.text('Privacy & sharing rules'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Privacy & sharing rules'));
      await tester.pumpAndSettle();
      expect(find.byType(PrivacyScreen), findsOneWidget);
      expect(find.text('Pause Sharing for Everyone'), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Notification preferences'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Notification preferences'));
      await tester.pumpAndSettle();
      expect(find.byType(NotificationsScreen), findsOneWidget);

      await tester.pageBack();
      await tester.pumpAndSettle();

      // Reading the policy never touched the user's sharing consent.
      expect(await KaSpotService.anySharingEnabled(), sharingBefore);
    });
  });

  group('Responsive layout', () {
    testWidgets('narrow phone renders every section without overflow', (
      tester,
    ) async {
      useView(tester, 340, 480);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getSize(_page).width, 340);

      // Walk the whole document; a RenderFlex overflow anywhere surfaces as an
      // exception on the next pump.
      for (var i = 0; i < 14; i++) {
        await tester.drag(_page, const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'overflow at drag $i');
      }
    });

    testWidgets('200% text scale stays inside the screen', (tester) async {
      useView(tester, 320, 640);
      await tester.pumpWidget(app(textScale: 2.0));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      for (final section in privacyPolicySections) {
        // Last occurrence is the section heading, not the contents entry.
        final heading = find.text(section.title).last;
        expect(
          tester.getRect(heading).right,
          lessThanOrEqualTo(320.0),
          reason: 'heading runs past the screen edge: ${section.title}',
        );
      }

      for (var i = 0; i < 22; i++) {
        await tester.drag(_page, const Offset(0, -400));
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'overflow at 200% text scale, drag $i',
        );
      }
    });
  });

  group('Content model', () {
    test('section anchors are unique and every section has content', () {
      final ids = privacyPolicySections.map((section) => section.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final section in privacyPolicySections) {
        expect(section.blocks, isNotEmpty, reason: section.id);
      }
    });

    test('the controls shortcut appears once, in the choices section', () {
      final withControls = privacyPolicySections
          .where((section) => section.blocks.any((b) => b is PolicyControls))
          .map((section) => section.id)
          .toList();
      expect(withControls, ['choices']);
    });
  });
}
