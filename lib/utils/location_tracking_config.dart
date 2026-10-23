/// Single source of truth for every location-tracking number KaSpot applies,
/// plus the consent wording that must stay accurate to those numbers.
///
/// The background stream, the heartbeat, the offline queue, the map's freshness
/// labels and every consent surface all read from here. Changing a value here is
/// the only way to change the behaviour — and the disclosures update with it, so
/// the consent dialog can never drift away from what the code actually does.
///
/// The retention window is mirrored by the database
/// (`public.location_retention_interval()` in
/// `supabase/migrations/20261023_location_retention_expiration.sql`); the two
/// must be changed together.
class LocationTrackingConfig {
  LocationTrackingConfig._();

  // ── Numbers the platform stream is actually configured with ───────────────

  /// `AndroidSettings.distanceFilter` / `AppleSettings.distanceFilter`: the
  /// minimum movement the provider is asked to report.
  static const int distanceFilterMeters = 5;

  /// `AndroidSettings.intervalDuration`: the requested minimum delay between
  /// position updates.
  static const Duration streamInterval = Duration(seconds: 3);

  /// Period of the stationary heartbeat that keeps a still phone's marker fresh.
  static const Duration heartbeatInterval = Duration(seconds: 30);

  /// A heartbeat tick is skipped when a movement fix landed within this window.
  static const Duration heartbeatSkipWindow = Duration(seconds: 20);

  /// Time limit for the one-shot fix taken when the user enables sharing.
  static const Duration singleFixTimeLimit = Duration(seconds: 15);

  /// Time limit for the silent auto-locate performed when the map opens.
  static const Duration autoFixTimeLimit = Duration(seconds: 8);

  /// Time limit for the fix collected by each heartbeat tick.
  static const Duration heartbeatFixTimeLimit = Duration(seconds: 30);

  /// How many times a failed position stream is re-opened before the service
  /// reports a hard failure. Keeps recovery bounded and never stacks
  /// subscriptions.
  static const int maxStreamRetries = 3;

  // ── Numbers that govern freshness and lifetime ────────────────────────────

  /// A shared marker older than this is presented as inactive rather than live.
  static const Duration markerStaleAfter = Duration(minutes: 20);

  /// How long the server keeps a latest location after accepting a write.
  static const Duration retention = Duration(hours: 24);

  /// An offline-queued fix older than the retention window is discarded instead
  /// of being uploaded as if it were current.
  static const Duration maxQueuedFixAge = retention;

  // ── Foreground-service notification ───────────────────────────────────────

  static const String notificationTitle = 'KaSpot · Live Sharing Active';
  static const String notificationBody =
      'Sharing your latest position with your authorized circle';

  // ── Consent wording derived from the numbers above ────────────────────────

  /// The plain-language summary shown next to the sharing controls. Derived from
  /// the same numbers the service applies, so no surface can repeat a cadence
  /// that the code has moved away from.
  static String get cadenceSummary =>
      'Battery-Smart: transmits when you have moved about '
      '$distanceFilterMeters m, asks for no more than one update every '
      '${streamInterval.inSeconds} seconds, and sends a stationary heartbeat '
      'about every ${heartbeatInterval.inSeconds} seconds.';

  /// The consent-first explanation under the sharing switches: what happens with
  /// the switch off, what the cadence really is when it is on, and what becomes
  /// of a fix that cannot be sent.
  static String get privacyCardSummary =>
      'Consent-First Tracking: while Background Location is OFF, KaSpot never '
      'polls or transmits GPS with the app closed. When it is ON, KaSpot asks '
      'for a position about every ${streamInterval.inSeconds} seconds once you '
      'have moved $distanceFilterMeters m, plus a stationary heartbeat about '
      'every ${heartbeatInterval.inSeconds} seconds. A fix that cannot be sent '
      'while offline is kept as the single latest point and synced when the '
      'connection returns; a queued point older than '
      '${maxQueuedFixAge.inHours} hours is dropped rather than uploaded as if it '
      'were current. Android '
      'may end the service at any time, and KaSpot restarts it only when you '
      'open the app.';

  static String get cadenceDisclaimer =>
      'Those values are requests, not guarantees: Android, GPS conditions, '
      'battery saver and your device manufacturer decide how often a position '
      'actually arrives. Movement may be reported later, or not at all.';

  static String get lifecycleDisclosure =>
      'Android can end the sharing service at any time — when you swipe '
      'KaSpot away, force-stop it, reboot the phone, or when the system '
      'restricts background work. KaSpot cannot bring tracking back by itself; '
      'opening the app again resumes it.';

  static String get permissionDisclosure =>
      'Needs "Allow all the time" location access, device location switched '
      'on, and a network connection. If any of those is missing, your circle '
      'simply stops receiving updates.';

  static String get accuracyDisclaimer =>
      'KaSpot asks for high-accuracy fixes but cannot guarantee GPS precision; '
      'expect errors of several metres, especially indoors.';

  static String get notificationDisclosure =>
      'Transparency: while background sharing runs, Android keeps a "'
      '$notificationTitle" notification visible on your phone.';

  /// The full set of disclosures every consent surface must present, in order.
  static List<String> get disclosures => [
        cadenceSummary,
        cadenceDisclaimer,
        lifecycleDisclosure,
        permissionDisclosure,
        accuracyDisclaimer,
        notificationDisclosure,
      ];
}
