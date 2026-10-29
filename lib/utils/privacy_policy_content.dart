/// The KaSpot Privacy Policy as structured content.
///
/// Layout lives in `lib/screens/privacy_policy_screen.dart`; this file is the
/// text itself. It replaced the previous `assets/privacy_policy.html` + regex
/// tag-stripper pipeline, where the renderer guessed headings and bullets from
/// line prefixes.
///
/// Content rules for future edits:
/// * Every statement must be traceable to the implementation in this repository
///   or to a provider's documented behaviour. Do not add an address, contact
///   email, retention period, deletion feature, certification, or third-party
///   arrangement that the app does not have.
/// * Keep `id` stable: the table of contents scrolls to sections by `id`.
/// * Numbers that the app itself applies are read from
///   `lib/utils/location_tracking_config.dart` instead of being retyped here, so
///   the policy cannot drift away from the code.
///
/// Rewritten 2026-10-23 after auditing every claim against the source. The
/// statements that were removed because the code contradicted them:
/// * "we do not share ... with any third party. Ever" — Supabase, Google
///   (Sign-In and Cloud Messaging), OpenStreetMap and Esri all process data.
/// * "Only you and the person you are chatting with can read your messages" —
///   true in the app, but operators hold administrative access.
/// * "Removed from our servers immediately when you disable sharing" — the row
///   goes when the last enabled grant is revoked, not on any single revocation.
/// * "No data is collected when sharing is off" — the map still reads the
///   device's own position locally (`map_screen.dart`, `_autoLocate`).
/// * "Profile picture ... only shown to people in your circle" — the `profiles`
///   select policy also admits connection-request counterparties.
/// * "you may delete your account ... by contacting us at the address below",
///   "the app's feedback channel", "respond within 5 business days" — none of
///   those channels exist, and deletion is now an in-app flow.
/// * "we will notify you through the app before the changes take effect" — no
///   notice mechanism exists.
/// * "encrypted in transit (TLS) and at rest" as a verified claim — at-rest
///   encryption is the hosting provider's default, not something this codebase
///   can attest to.
///
/// Deliberately absent: any location retention window. `schema.sql` and the
/// unapplied `20261023_location_retention_expiration.sql` describe a 24-hour
/// expiration, but until that migration is applied and verified the policy must
/// not present it as live.
library;

import 'location_tracking_config.dart';
import 'release_flags.dart';

/// The effective date stated by the policy document itself.
const String privacyPolicyEffective = '23 October 2026';

/// Footer lines, carried over unchanged from the document footer.
const String privacyPolicyFooterCopyright =
    '© 2026 KaSpot · Privacy-first location sharing';
const String privacyPolicyFooterScope =
    'This policy applies to the KaSpot mobile application.';

/// One list item: a short bold lead-in followed by the rest of the sentence.
/// Rendered as an em dash between the bold lead-in and the sentence.
class PolicyBullet {
  const PolicyBullet({required this.title, required this.text});

  final String title;
  final String text;
}

sealed class PolicyBlock {
  const PolicyBlock();
}

/// A normal body paragraph.
class PolicyParagraph extends PolicyBlock {
  const PolicyParagraph(this.text);

  final String text;
}

/// A sub-heading inside a section, e.g. "Retention" under storage.
class PolicySubheading extends PolicyBlock {
  const PolicySubheading(this.text);

  final String text;
}

class PolicyBulletList extends PolicyBlock {
  const PolicyBulletList(this.bullets);

  final List<PolicyBullet> bullets;
}

/// A highlighted assurance. Reserved for statements the policy sets apart.
class PolicyCallout extends PolicyBlock {
  const PolicyCallout(this.text);

  final String text;
}

/// The closing contact details block.
class PolicyContactCard extends PolicyBlock {
  const PolicyContactCard({required this.title, required this.text});

  final String title;
  final String text;
}

/// Placeholder for the "your choices" controls. Renders navigation to the real
/// settings screens; the policy screen itself never changes any state.
class PolicyControls extends PolicyBlock {
  const PolicyControls();
}

class PolicySection {
  const PolicySection({
    required this.id,
    required this.title,
    required this.blocks,
  });

  /// Stable anchor used by the table of contents.
  final String id;
  final String title;
  final List<PolicyBlock> blocks;
}

/// The policy, in reading order: the same nine sections, with statements
/// corrected rather than regrouped.
///
/// Built lazily and rebuilt only when [ReleaseFlags.accountDeletionEnabled]
/// changes, so the deletion wording always matches what this build can do. The
/// tracking numbers are read from [LocationTrackingConfig] at build time.
List<PolicySection> get privacyPolicySections {
  if (_cachedPolicySections == null ||
      _cachedPolicyFlag != ReleaseFlags.accountDeletionEnabled) {
    _cachedPolicySections = _buildPolicySections();
    _cachedPolicyFlag = ReleaseFlags.accountDeletionEnabled;
  }
  return _cachedPolicySections!;
}

List<PolicySection>? _cachedPolicySections;
bool? _cachedPolicyFlag;

List<PolicySection> _buildPolicySections() => [
  PolicySection(
    id: 'overview',
    title: 'Privacy Overview',
    blocks: [
      PolicyParagraph(
        'Welcome to KaSpot. We built this app around a simple principle: your '
        'location belongs to you. This Privacy Policy explains what information '
        'KaSpot collects, how it is used, and the choices you have. We have '
        'written it in plain language because you deserve to understand it, not '
        'just check a box.',
      ),
      PolicyCallout(
        'KaSpot does not sell your data, does not run advertising or profiling, '
        'and does not share your information for marketing. A small number of '
        'service providers process data so the app can run — they are named in '
        'Sharing and Disclosure.',
      ),
      PolicyParagraph(
        'Where something described here is not active yet, this policy says so '
        'instead of describing it as if it were.',
      ),
    ],
  ),
  PolicySection(
    id: 'collection',
    title: 'Information We Collect',
    blocks: [
      PolicyParagraph(
        'KaSpot collects only what the app needs to work. Almost all of it is '
        'information you provide or create — your location is the only category '
        'your device supplies on its own, and it is uploaded only while you are '
        'sharing.',
      ),
      PolicyBulletList([
        PolicyBullet(
          title: 'Account information',
          text:
              'your email address, your display name, and the sign-in method you '
              'used (a password, or your Google account).',
        ),
        PolicyBullet(
          title: 'Profile picture',
          text:
              'an optional photo you pick from your device. Your circle members '
              'see it, and so do people with an open connection invitation with '
              'you — that is how an invitation shows who sent it.',
        ),
        PolicyBullet(
          title: 'Location data',
          text:
              'the single latest GPS coordinate, uploaded only while location '
              'sharing is on. KaSpot keeps one point and overwrites it: no '
              'history, no routes, no movement trails. The map also reads your '
              'device\'s own position to show where you are, even with sharing '
              'off; that reading stays on the device.',
        ),
        PolicyBullet(
          title: 'Circle messages',
          text:
              'the text you send in the in-app chat, when it was sent, whether '
              'it has been read, any reactions, and which message it replies to.',
        ),
        PolicyBullet(
          title: 'Circle connections and invitations',
          text:
              'your accepted connections, the invitations you sent or received '
              '(including declined and withdrawn ones), and the relationship '
              'label you choose for each person.',
        ),
        PolicyBullet(
          title: 'Saved places',
          text: 'the names and coordinates of places you save on the map.',
        ),
        PolicyBullet(
          title: 'Location-sharing preferences',
          text:
              'which circle members may see your latest position, and whether '
              'background sharing is switched on.',
        ),
        PolicyBullet(
          title: 'Notification preferences',
          text: 'the switches described under Circles, Messages and Notifications.',
        ),
        PolicyBullet(
          title: 'Device token',
          text:
              'an identifier your device\'s operating system generates so push '
              'notifications can reach it. It is not an advertising identifier '
              'and is not used to follow you between apps.',
        ),
      ]),
      PolicyParagraph(
        'KaSpot does not collect your contacts, your photo library beyond the one '
        'picture you choose, advertising identifiers, analytics, or crash '
        'reporting data.',
      ),
    ],
  ),
  PolicySection(
    id: 'usage',
    title: 'How We Use Information',
    blocks: [
      PolicyBulletList([
        PolicyBullet(
          title: 'Location',
          text:
              'shown only to the circle members you have individually authorised. '
              'KaSpot stores one point for you; it is deleted once no enabled '
              'sharing permission is left.',
        ),
        PolicyBullet(
          title: 'Messages',
          text:
              'delivered to the person you are messaging and stored so the '
              'conversation stays available to both of you.',
        ),
        PolicyBullet(
          title: 'Push notifications',
          text:
              'sent through Google Firebase Cloud Messaging when a new message is '
              'waiting for you, if you have notifications enabled. The '
              'notification states that a message is waiting, never what it says.',
        ),
        PolicyBullet(
          title: 'Profile information',
          text:
              'shown to your circle members so they can recognise you on the map '
              'and in the circle list.',
        ),
        PolicyBullet(
          title: 'Running and protecting the service',
          text:
              'keeping the app working, fixing faults, and preventing abuse. In '
              'this context the operator may read stored data — see Sharing and '
              'Disclosure.',
        ),
      ]),
      PolicyParagraph(
        'We do not use your data for advertising, profiling, or any purpose '
        'beyond making the app work for you.',
      ),
      PolicyParagraph(
        'KaSpot makes no automated decisions about you. Arrival alerts compare '
        'shared positions with your own saved places on your device; nothing is '
        'scored or decided about you.',
      ),
    ],
  ),
  PolicySection(
    id: 'location',
    title: 'Location Sharing and Tracking',
    blocks: [
      PolicySubheading('One point, never a trail'),
      PolicyCallout(
        'KaSpot stores only your latest GPS coordinate — one row, overwritten '
        'with every update. When you revoke the last person who could see it, or '
        'pause sharing for everyone, that row is deleted. KaSpot keeps no record '
        'of where you have been.',
      ),
      PolicyParagraph('What each state means, precisely:'),
      PolicyBulletList([
        PolicyBullet(
          title: 'Sharing off',
          text:
              'no position is uploaded to KaSpot\'s servers and nothing is shared '
              'with anyone. The map still asks your device where you are so it '
              'can show your own position; that reading never leaves the device.',
        ),
        PolicyBullet(
          title: 'Sharing on for some people',
          text:
              'the latest point is uploaded and visible to exactly those people, '
              'and only while your connection with each of them is still '
              'accepted.',
        ),
        PolicyBullet(
          title: 'Revoking one person',
          text:
              'that person can no longer see your position. Your point is deleted '
              'when nobody else is still authorised.',
        ),
        PolicyBullet(
          title: 'Pausing for everyone, or removing a connection',
          text:
              'every permission is switched off and the stored point is deleted. '
              'Removing a connection deletes the sharing permission that went '
              'with it.',
        ),
        PolicyBullet(
          title: 'Old or undelivered updates',
          text:
              'An old position is never presented as current. If a position '
              'cannot be uploaded it is kept on your device only, and dropped '
              'once it is more than '
              '${LocationTrackingConfig.maxQueuedFixAge.inHours} hours old; a '
              'shared position that stops being updated is shown as inactive '
              'rather than live.',
        ),
      ]),
      PolicySubheading('Background sharing (optional)'),
      PolicyParagraph(
        'Background sharing is off unless you turn it on in Account & Privacy → '
        'Privacy & Sharing Rules. Turning it on first shows a consent screen and '
        'requires location permission set to "Allow all the time", location '
        'services switched on, and a network connection.',
      ),
      PolicyParagraph(
        'While it is on, KaSpot asks the device for a position about every '
        '${LocationTrackingConfig.streamInterval.inSeconds} seconds once you have '
        'moved about ${LocationTrackingConfig.distanceFilterMeters} metres, plus '
        'a stationary heartbeat about every '
        '${LocationTrackingConfig.heartbeatInterval.inSeconds} seconds so a phone '
        'that is not moving still shows a current position.',
      ),
      PolicyParagraph(LocationTrackingConfig.cadenceDisclaimer),
      PolicyParagraph(
        'While background sharing runs, Android keeps a '
        '"${LocationTrackingConfig.notificationTitle}" notification visible on '
        'your phone. Switching background sharing off — from that notification or '
        'from the app — stops the updates.',
      ),
      PolicyParagraph(
        'Android can end background work at any time: swiping KaSpot away, '
        'force-stopping it, rebooting the phone, revoking the location permission, '
        'or a manufacturer battery restriction. KaSpot cannot restart tracking by '
        'itself; opening the app again resumes it when your permissions still '
        'allow it. When it stops, your circle simply stops receiving updates — '
        'KaSpot does not show them an old position as if it were live.',
      ),
      PolicySubheading('A position that could not be sent'),
      PolicyParagraph(
        'If a position cannot be uploaded — you are offline, or the server cannot '
        'be reached — KaSpot keeps only that single latest point on your device '
        'and sends it when the connection returns. A queued point older than '
        '${LocationTrackingConfig.maxQueuedFixAge.inHours} hours is discarded '
        'rather than uploaded as if it were current, and signing out or deleting '
        'the account removes it.',
      ),
    ],
  ),
  PolicySection(
    id: 'messages',
    title: 'Circles, Messages, and Notifications',
    blocks: [
      PolicyParagraph(
        'Messages travel through KaSpot\'s backend to the person you are chatting '
        'with and are stored so both of you keep the conversation. Within the app, '
        'only the two participants can read it: every read requires an accepted '
        'connection between them.',
      ),
      PolicyParagraph(
        'Operators of the service hold administrative access to the database, '
        'which is needed to keep the app secure and working. That access is '
        'purpose-limited to security, debugging and support; it is not used to '
        'read conversations out of interest. This is the difference between what '
        'other users can see in the app and the technical access required to '
        'operate the service.',
      ),
      PolicyParagraph(
        'Alerts use your device\'s notification system. Two settings inside KaSpot '
        'control them:',
      ),
      PolicyBulletList([
        PolicyBullet(
          title: 'Messages & invitations',
          text:
              'in-app banners for new messages and circle invitations, plus push '
              'alerts for new messages. Turning it off stops them; messages still '
              'arrive in the chat, and unread badges keep counting. Invitations '
              'have no push alert: they appear inside the app only.',
        ),
        PolicyBullet(
          title: 'Arrival & Departure Alerts',
          text:
              'worked out on your device by comparing shared positions with the '
              'places you saved. They appear only while KaSpot is open, and the '
              'comparison is never uploaded; the switch itself is stored with your '
              'other notification preferences.',
        ),
      ]),
      PolicyParagraph(
        'Android\'s notification permission is a separate setting outside the app. '
        'If it is switched off, no alert can appear even when KaSpot is allowed to '
        'send them.',
      ),
      PolicyParagraph(
        'Push notifications are delivered by Google Firebase Cloud Messaging. '
        'KaSpot sends it your device token and a generic alert — "New message in '
        'KaSpot" — plus the identifiers the app needs to open the right '
        'conversation. No message text and no sender name is included. '
        'Notification delivery uses a device token that is not used to track you '
        'and is not shared with any advertising service.',
      ),
    ],
  ),
  PolicySection(
    id: 'storage',
    title: 'Data Storage, Retention, and Security',
    blocks: [
      PolicySubheading('Where data is stored'),
      PolicyParagraph(
        'KaSpot runs on Supabase: the database, sign-in, realtime updates and the '
        'server functions that deliver notifications all belong to that platform. '
        'Your data is stored in the Supabase project that operates KaSpot.',
      ),
      PolicySubheading('Access control'),
      PolicyParagraph(
        'Every table is protected by row-level security, so a request can only '
        'read rows the signed-in person is authorised to read. A stored position '
        'is readable only while an enabled, per-person sharing permission exists '
        'and the connection is still accepted; a message is readable only by its '
        'two participants while they are connected.',
      ),
      PolicySubheading('Security'),
      PolicyParagraph(
        'Data is encrypted in transit using TLS. Encryption at rest and provider '
        'backups are the hosting provider\'s default arrangements; KaSpot does not '
        'claim a specific at-rest configuration beyond that, and cannot guarantee '
        'that a deleted row has already disappeared from every provider backup.',
      ),
      PolicyParagraph(
        'We take reasonable technical and organizational measures to protect your '
        'data against unauthorized access, loss, or disclosure.',
      ),
      PolicySubheading('Retention'),
      PolicyBulletList([
        PolicyBullet(
          title: 'Location data',
          text:
              'one latest point per account, deleted when you revoke the last '
              'sharing permission or pause sharing for everyone. A stored point '
              'that is never replaced stays until it is deleted that way or the '
              'account is deleted.',
        ),
        PolicyBullet(
          title: 'Messages',
          text:
              'retained while both accounts exist so the conversation stays '
              'available. They are removed when either participant deletes their '
              'account.',
        ),
        PolicyBullet(
          title: 'Account data',
          text: 'retained until you delete your account in the app.',
        ),
        PolicyBullet(
          title: 'Profile pictures',
          text: 'retained until you remove or replace them, or delete your account.',
        ),
        PolicyBullet(
          title: 'Saved places, preferences and device tokens',
          text:
              'retained until you change them, sign out of that device, or delete '
              'your account.',
        ),
        PolicyBullet(
          title: 'Anything queued on your device',
          text:
              'at most the single latest position, dropped after '
              '${LocationTrackingConfig.maxQueuedFixAge.inHours} hours, on '
              'sign-out, or on account deletion.',
        ),
      ]),
      PolicyParagraph(
        'KaSpot keeps no movement history, no usage analytics and no marketing '
        'profile about you.',
      ),
    ],
  ),
  PolicySection(
    id: 'sharing',
    title: 'Sharing and Disclosure',
    blocks: [
      PolicySubheading('Who can see your data'),
      PolicyBulletList([
        PolicyBullet(
          title: 'You',
          text:
              'full control over your profile, connections, and sharing settings '
              'at all times.',
        ),
        PolicyBullet(
          title: 'Your circle members',
          text:
              'can see your name and profile picture, and your location only if '
              'you have granted them sharing permission.',
        ),
        PolicyBullet(
          title: 'People with an open invitation',
          text:
              'can see your name and profile picture so an invitation shows who '
              'sent it. They cannot see your location.',
        ),
        PolicyBullet(
          title: 'KaSpot operators',
          text:
              'as the operator of this service, we have administrative access to '
              'the database for the purposes of security monitoring, debugging, '
              'and ensuring the app functions correctly. This access is not used '
              'to read your messages for personal purposes.',
        ),
      ]),
      PolicySubheading('Service providers'),
      PolicyParagraph(
        'KaSpot does not sell personal data and has no advertising partners. To '
        'run the app, these providers process data on KaSpot\'s behalf:',
      ),
      PolicyBulletList([
        PolicyBullet(
          title: 'Supabase',
          text:
              'hosting for the database, sign-in, realtime updates and server '
              'functions. Receives everything stored in the app, through KaSpot\'s '
              'servers rather than directly from your device.',
        ),
        PolicyBullet(
          title: 'Google Firebase Cloud Messaging',
          text:
              'push delivery. Receives your device token and a generic alert, with '
              'no message text and no sender name.',
        ),
        PolicyBullet(
          title: 'Google Sign-In',
          text:
              'only if you choose to continue with Google. Your device exchanges '
              'your Google identity with KaSpot through Google.',
        ),
        PolicyBullet(
          title: 'OpenStreetMap tile servers',
          text:
              'the standard map layer. Your device requests map images for the '
              'area you are viewing, so these servers see your IP address and '
              'which area was requested.',
        ),
        PolicyBullet(
          title: 'Esri ArcGIS',
          text:
              'the satellite layer, with the same request pattern as the map '
              'tiles.',
        ),
        PolicyBullet(
          title: 'Google Maps',
          text:
              'only when you tap to open a location in Google Maps. That app then '
              'handles the coordinate under Google\'s own terms.',
        ),
      ]),
      PolicyParagraph(
        'Beyond the providers above, KaSpot does not transfer your personal data '
        'to third parties. If the operator were legally compelled to disclose '
        'something, only what is required would be provided.',
      ),
    ],
  ),
  PolicySection(
    id: 'choices',
    title: 'Your Privacy Choices',
    blocks: [
      PolicyBulletList([
        PolicyBullet(
          title: 'Access',
          text:
              'you can view your profile, connections, and messages directly '
              'in the app at any time.',
        ),
        PolicyBullet(
          title: 'Correction',
          text:
              'update your display name and profile picture at any time in '
              'Account & Privacy.',
        ),
        // The flow is only advertised when this build targets a project where
        // the deletion function is deployed; otherwise the policy says so.
        if (ReleaseFlags.accountDeletionEnabled)
          PolicyBullet(
            title: 'Deleting your account',
            text:
                'Account & Privacy → Delete Account lists exactly what will be '
                'removed, asks you to type DELETE, verifies your password or Google '
                'account again, and only then asks the server to delete the account. '
                'If the request cannot be completed, KaSpot tells you and nothing is '
                'removed. If the account is removed but the server cannot confirm '
                'that every stored record was cleared, KaSpot says that instead of '
                'reporting a clean deletion.',
          )
        else
          PolicyBullet(
            title: 'Deleting your account',
            text:
                'in-app account deletion is not enabled in this build. The flow is '
                'being verified end to end before it is offered, and no other '
                'deletion route is published yet. Do not rely on this build to '
                'delete an account.',
          ),
        PolicyBullet(
          title: 'Location sharing control',
          text:
              'each person\'s access is a separate switch in Privacy & Sharing '
              'Rules, and "Pause Sharing for Everyone" revokes them all and '
              'deletes your stored position.',
        ),
        PolicyBullet(
          title: 'Notifications',
          text:
              'the switches under Notifications control in-app banners and push '
              'alerts; Android\'s own permission can silence the app completely.',
        ),
        PolicyBullet(
          title: 'Background sharing',
          text:
              'off by default. Turning it on requires the consent screen and full '
              'location permission; turning it off stops tracking immediately.',
        ),
      ]),
      PolicyControls(),
    ],
  ),
  PolicySection(
    id: 'changes',
    title: 'Children, Changes, and Contact',
    blocks: [
      PolicySubheading("Children's privacy"),
      PolicyParagraph(
        'KaSpot is not intended for use by children under the age of 13. The app '
        'does not ask for a date of birth and does not verify age. If the '
        'operator learns that a child under 13 has created an account, that '
        'account will be deleted.',
      ),
      PolicySubheading('Changes to this policy'),
      PolicyParagraph(
        'When this policy changes, the effective date at the top is updated and '
        'the current version is published in the app under Account & Privacy → '
        'Privacy Policy. KaSpot does not currently send a separate in-app notice '
        'when the policy changes, so the effective date is the reliable signal.',
      ),
      PolicyParagraph(
        ReleaseFlags.accountDeletionEnabled
            ? 'Continuing to use KaSpot after a policy update means you accept '
                  'the revised terms. You can delete your account in the app at any '
                  'time.'
            : 'Continuing to use KaSpot after a policy update means you accept '
                  'the revised terms. Account deletion from inside the app is not '
                  'enabled in this build.',
      ),
      PolicySubheading('Contact us'),
      PolicyParagraph(
        'KaSpot does not currently publish a privacy contact address and does not '
        'run a support channel, so there is no way to send a privacy question or '
        'a data request from inside the app. This is a known gap in the service, '
        'not something this policy can promise away.',
      ),
      PolicyContactCard(
        title: 'Privacy contact',
        text: ReleaseFlags.accountDeletionEnabled
            // A build that offers the flow may say so; a build that does not
            // must not point the reader at a screen that cannot delete.
            ? 'No contact address is published yet. Account deletion does not '
                  'depend on one — it is available in the app under Account & '
                  'Privacy → Delete Account. This section will be replaced with '
                  'a real, monitored channel as soon as the operator publishes '
                  'one.'
            : 'No contact address is published yet, and this build offers no '
                  'deletion route either, so there is no published way to send a '
                  'privacy question or a data request. This section will be '
                  'replaced with a real, monitored channel as soon as the '
                  'operator publishes one.',
      ),
    ],
  ),
];
