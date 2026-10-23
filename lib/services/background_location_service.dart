import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/location_tracking_config.dart';
import 'kaspot_service.dart';

/// What the location service is *actually* doing right now.
///
/// The distinction matters: a stored preference ("the user turned background
/// sharing on") is not the same thing as a running service. Every UI surface
/// must report this value — never [BackgroundLocationService
/// .isBackgroundSharingEnabled] — when it claims a position is live.
enum TrackingState {
  /// Tracking was never enabled, or the user switched it off.
  off,

  /// An enable was requested and is being worked on.
  starting,

  /// The position stream is open and has produced a fix.
  streaming,

  /// The stream is open but no fix has been acquired yet (cold GPS start,
  /// indoors, permission still settling).
  waitingForFix,

  /// The stream was closed because no enabled sharing grant is left. The user's
  /// background preference is untouched; tracking resumes when sharing is
  /// switched back on.
  suspendedNoSharing,

  /// Device location services are turned off.
  blockedLocationServices,

  /// Location permission is missing, or is only while-in-use, which cannot keep
  /// sharing running in the background.
  blockedPermission,

  /// Fixes arrive but cannot be uploaded, or the stream errored and a bounded
  /// retry is scheduled.
  degraded,

  /// Recovery gave up after [LocationTrackingConfig.maxStreamRetries] attempts.
  failed,
}

/// Outcome of the permission/service gate in front of a tracking start.
enum PermissionGate {
  /// "Allow all the time" is granted and device location is switched on.
  granted,

  /// Device location services are switched off.
  locationServicesOff,

  /// Denied for this session; the system dialog can still be shown again.
  denied,

  /// Denied permanently — only App Settings can fix it.
  deniedForever,

  /// Only while-in-use access exists: background sharing cannot be honoured.
  whileInUseOnly,

  /// The platform could not answer (no activity, missing manifest entry, …).
  platformError,
}

/// Service managing user-controlled background location sharing.
///
/// What it really does — and the only thing the consent UI may promise:
/// - Consent-first opt-in, OFF by default. The wording shown at consent time is
///   generated from [LocationTrackingConfig], the same values applied here.
/// - One Android foreground-service notification, owned by geolocator and torn
///   down together with the single position subscription this service keeps.
/// - A [LocationTrackingConfig.distanceFilterMeters] metre distance filter, a
///   [LocationTrackingConfig.streamInterval] requested interval and a
///   [LocationTrackingConfig.heartbeatInterval] stationary heartbeat — all
///   requests to the platform, not guarantees.
/// - Tracking lives exactly as long as the Flutter engine does. Android ends it
///   on swipe-away, force-stop, reboot or an OS background restriction, and no
///   code in this app can resurrect it; reopening KaSpot does.
/// - Fixes captured while offline are queued (latest only) by [KaSpotService].
class BackgroundLocationService {
  BackgroundLocationService._();

  /// The user's *desired* state. Says nothing about anything running.
  static final ValueNotifier<bool> isBackgroundSharingEnabled = ValueNotifier<bool>(false);

  /// Whether a position subscription is currently open.
  static final ValueNotifier<bool> isStreamingActive = ValueNotifier<bool>(false);

  /// The real service state — what the UI must report.
  static final ValueNotifier<TrackingState> state =
      ValueNotifier<TrackingState>(TrackingState.off);

  /// Emits every fresh GPS position from the background stream so the map
  /// screen can update the own-user marker without requiring a manual recenter.
  static final ValueNotifier<Position?> livePosition = ValueNotifier<Position?>(null);

  /// Last successful *acquisition* from the device and last successful
  /// *delivery* to the backend. Kept apart on purpose: a phone can know exactly
  /// where it is and still be unable to report it.
  static final ValueNotifier<DateTime?> lastFixAt = ValueNotifier<DateTime?>(null);
  static final ValueNotifier<DateTime?> lastUploadAt = ValueNotifier<DateTime?>(null);

  /// Human-readable reason behind [state] whenever it is not a healthy state.
  static String? lastError;

  static StreamSubscription<Position>? _positionSubscription;
  static Timer? _heartbeatTimer;
  static Timer? _retryTimer;
  static int _retryCount = 0;
  static bool _startInFlight = false;
  static bool _lastFixSeen = false;
  static bool _backgroundAskAttempted = false;

  /// Set after a denied permission was escalated to App Settings, so returning
  /// to KaSpot completes the enable the user already consented to — and nothing
  /// else ever auto-starts tracking.
  static bool _awaitingPermissionResolution = false;

  /// Account the running stream belongs to, so consent can still be withdrawn
  /// on sign-out after the session (and with it [KaSpotService.userId]) is gone.
  static String? _trackedUid;

  static String? _pendingPreferenceResetUid;
  static bool _listenersInstalled = false;
  static WidgetsBindingObserver? _lifecycleObserver;

  static const String _consentKeyPrefix = 'kaspot_bg_consent';

  // ── Wiring & start-up ─────────────────────────────────────────────────────

  /// Restores the persisted preference and starts tracking only when this
  /// device's own consent record still agrees. Never throws: a failure is
  /// surfaced through [state] and [lastError] instead of being swallowed.
  static Future<void> initialize() {
    _installListeners();
    return _restoreDesiredState();
  }

  /// Test seam: removes the listeners and the lifecycle observer, releases every
  /// timer and subscription and returns the observable state to its resting
  /// values, so a suite can install the service more than once per isolate.
  @visibleForTesting
  static void resetForTest() {
    KaSpotService.authStateNotifier.removeListener(_onAuthStateChanged);
    KaSpotService.sharingActive.removeListener(_onSharingActiveChanged);
    final observer = _lifecycleObserver;
    if (observer != null) WidgetsBinding.instance.removeObserver(observer);
    _lifecycleObserver = null;
    _listenersInstalled = false;
    _awaitingPermissionResolution = false;
    _backgroundAskAttempted = false;
    _startInFlight = false;
    _pendingPreferenceResetUid = null;
    _trackedUid = null;
    _retryCount = 0;
    _lastFixSeen = false;
    lastError = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    final subscription = _positionSubscription;
    _positionSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    isBackgroundSharingEnabled.value = false;
    isStreamingActive.value = false;
    state.value = TrackingState.off;
    livePosition.value = null;
    lastFixAt.value = null;
    lastUploadAt.value = null;
  }

  static void _installListeners() {
    if (_listenersInstalled) return;
    _listenersInstalled = true;
    KaSpotService.authStateNotifier.addListener(_onAuthStateChanged);
    KaSpotService.sharingActive.addListener(_onSharingActiveChanged);
    final observer = _TrackingLifecycleObserver();
    _lifecycleObserver = observer;
    WidgetsBinding.instance.addObserver(observer);
  }

  static void _onAuthStateChanged() {
    if (KaSpotService.isAuthenticated) {
      unawaited(_restoreDesiredState());
    } else {
      unawaited(onSignedOut());
    }
  }

  /// A session that ends — explicit sign-out, an expired token or an unverified
  /// account — stops location acquisition on this device immediately and
  /// withdraws the local consent record. None of that depends on the network.
  static Future<void> onSignedOut() async {
    final uid = _trackedUid ?? KaSpotService.userId;
    // Idempotent: main.dart and this service's own auth listener both react to
    // the session ending, and a second pass has nothing left to withdraw.
    if (uid.isEmpty && !isStreamingActive.value && state.value == TrackingState.off) {
      return;
    }
    _awaitingPermissionResolution = false;
    _backgroundAskAttempted = false;
    _trackedUid = null;
    _retryCount = 0;
    _lastFixSeen = false;
    await _teardown();
    _setState(TrackingState.off);
    isBackgroundSharingEnabled.value = false;
    livePosition.value = null;
    lastFixAt.value = null;
    lastUploadAt.value = null;
    lastError = null;

    if (uid.isNotEmpty) await _writeLocalConsent(uid, false);

    // Keep the backend preference in step with the local withdrawal, but never
    // let a failed write leave tracking running or block the sign-out.
    if (uid.isEmpty) return;
    try {
      await KaSpotService.setNotificationPreference('background_sharing_enabled', false);
      _pendingPreferenceResetUid = null;
    } catch (e) {
      _pendingPreferenceResetUid = uid;
      debugPrint('Background sharing preference reset deferred (offline): $e');
    }
  }

  static Future<void> _restoreDesiredState() async {
    _installListeners();
    if (!KaSpotService.isAuthenticated) return;
    final uid = KaSpotService.userId;
    if (uid.isEmpty) return;

    final bool serverEnabled;
    try {
      final prefs = await KaSpotService.notificationPreferences();
      serverEnabled = prefs['background_sharing_enabled'] as bool? ?? false;
    } catch (e) {
      // Offline or backend error: report it instead of guessing.
      _setState(TrackingState.failed);
      lastError = 'Could not read your sharing preference';
      debugPrint('Background sharing initialization failed: $e');
      return;
    }

    if (_pendingPreferenceResetUid == uid) {
      // Finish the preference withdrawal this device had to defer while offline.
      _pendingPreferenceResetUid = null;
      try {
        await KaSpotService.setNotificationPreference('background_sharing_enabled', false);
        if (serverEnabled) {
          // The stale account-level flag is gone: preference and behaviour now
          // agree, and nothing resumes without a fresh consent gesture.
          isBackgroundSharingEnabled.value = false;
          _setState(TrackingState.off);
          return;
        }
      } catch (e) {
        _pendingPreferenceResetUid = uid;
        debugPrint('Deferred background sharing preference reset still failing: $e');
      }
    }

    final bool? localConsent = await _readLocalConsent(uid);
    // Auto-resume only when the account's stored preference AND this device's
    // own consent record agree. A backend flag alone can never start a tracker:
    // that is what stops an account switch, a re-install or a device that never
    // asked for consent from silently resuming background collection.
    final bool desired = serverEnabled && localConsent == true;
    isBackgroundSharingEnabled.value = desired;

    if (serverEnabled && !desired) {
      debugPrint(
        'Background sharing is enabled on the account but was never consented to '
        'on this device; leaving tracking stopped.',
      );
    }

    if (!desired) {
      if (isStreamingActive.value) await _teardown();
      _setState(TrackingState.off);
      return;
    }

    _trackedUid = uid;
    final bool? grants = await _refreshSharingStatus();
    if (grants == false) {
      _setState(TrackingState.suspendedNoSharing);
      return;
    }
    try {
      await _startTracking(persist: false);
    } catch (e) {
      debugPrint('Background sharing could not resume on this launch: $e');
    }
  }

  /// Re-reads whether at least one enabled sharing grant exists and publishes it
  /// on [KaSpotService.sharingActive]. Returns null when it could not be
  /// determined (offline) — an unknown grant state must not be read as "no
  /// grants".
  static Future<bool?> _refreshSharingStatus() async {
    try {
      final enabled = await KaSpotService.anySharingEnabled();
      KaSpotService.sharingActive.value = enabled;
      return enabled;
    } catch (e) {
      debugPrint('Sharing grants could not be verified: $e');
      return null;
    }
  }

  // ── Public controls ───────────────────────────────────────────────────────

  /// Toggle background sharing mode with consent and preference persistence.
  static Future<void> toggleBackgroundSharing(bool enabled) async {
    if (enabled) {
      await startBackgroundTracking();
    } else {
      await stopBackgroundTracking();
    }
  }

  /// Start the background stream and its persistent foreground notification.
  ///
  /// Throws a user-facing [Exception] explaining what to change when a
  /// requirement is unmet, so no surface can end up showing an "active" state
  /// for a service that never started.
  static Future<void> startBackgroundTracking({bool persist = true}) async {
    _installListeners();
    isBackgroundSharingEnabled.value = true;
    try {
      await _startTracking(persist: persist);
    } catch (_) {
      isBackgroundSharingEnabled.value = false;
      rethrow;
    }
  }

  static Future<void> _startTracking({required bool persist}) async {
    if (_startInFlight || _positionSubscription != null) return;
    _startInFlight = true;
    _setState(TrackingState.starting);
    var started = false;
    try {
      final uid = KaSpotService.userId;
      if (uid.isEmpty || !KaSpotService.isAuthenticated) {
        _setState(TrackingState.off);
        throw Exception('Sign in to share your location.');
      }
      _trackedUid = uid;

      final gate = await ensureBackgroundPermission(requestIfMissing: true);
      if (gate != PermissionGate.granted) {
        _applyGateFailure(gate, escalate: persist);
        throw Exception(lastError ?? 'Background location sharing cannot start yet.');
      }

      _backgroundAskAttempted = false;
      _awaitingPermissionResolution = false;
      _retryCount = 0;
      lastError = null;
      await _openStream();
      started = true;

      if (persist) {
        await _writeLocalConsent(uid, true);
        try {
          await KaSpotService.setNotificationPreference('background_sharing_enabled', true);
          _pendingPreferenceResetUid = null;
        } catch (e) {
          // Tracking is running and consented on this device; a failed
          // preference write only means it will not auto-resume next launch.
          debugPrint('Background sharing preference could not be stored: $e');
        }
      }
    } catch (_) {
      // Never leave a "starting"/"live" impression behind a failure.
      if (!started) {
        if (state.value != TrackingState.blockedPermission &&
            state.value != TrackingState.blockedLocationServices &&
            state.value != TrackingState.off) {
          _setState(TrackingState.failed);
        }
      }
      rethrow;
    } finally {
      _startInFlight = false;
    }
  }

  /// Stop the stream, dismiss the ongoing notification and clear the timers.
  static Future<void> stopBackgroundTracking({bool persist = true}) async {
    _awaitingPermissionResolution = false;
    _backgroundAskAttempted = false;
    _retryCount = 0;
    final uid = _trackedUid ?? KaSpotService.userId;
    _trackedUid = null;
    await _teardown();
    _setState(TrackingState.off);
    isBackgroundSharingEnabled.value = false;
    lastError = null;

    if (persist) {
      if (uid.isNotEmpty) await _writeLocalConsent(uid, false);
      try {
        await KaSpotService.setNotificationPreference('background_sharing_enabled', false);
        _pendingPreferenceResetUid = null;
      } catch (e) {
        _pendingPreferenceResetUid = uid;
        debugPrint('Background sharing stop recorded locally; preference retry pending: $e');
      }
    }
  }

  // ── Sharing-grant reconciliation ─────────────────────────────────────────

  /// Keeps GPS acquisition honest about what it is for: with no enabled sharing
  /// grant left there is nothing to upload, so acquisition stops and the
  /// foreground notification goes away. The user's background preference
  /// survives, and switching sharing back on resumes the stream.
  static void _onSharingActiveChanged() {
    if (!KaSpotService.sharingActive.value) {
      _suspendSoon();
    } else if (state.value == TrackingState.suspendedNoSharing &&
        isBackgroundSharingEnabled.value) {
      unawaited(_resumeAfterGrantsRestored());
    }
  }

  static void _suspendSoon() {
    if (_isStoppedState(state.value)) return;
    // Deferred: this can be reached from inside a stream event or an upload,
    // and cancelling a subscription during its own delivery is unsafe.
    scheduleMicrotask(_suspendForNoGrants);
  }

  static bool _isStoppedState(TrackingState value) =>
      value == TrackingState.off || value == TrackingState.suspendedNoSharing;

  static Future<void> _suspendForNoGrants() async {
    // A session end or an explicit switch-off already put the service in its own
    // terminal state; suspending on top of that would misreport it.
    if (!KaSpotService.isAuthenticated || !isBackgroundSharingEnabled.value) return;
    if (_isStoppedState(state.value)) return;
    await _teardown();
    _setState(TrackingState.suspendedNoSharing);
    lastError = null;
    debugPrint('Background tracking suspended: no active sharing grant to receive it.');
  }

  static Future<void> _resumeAfterGrantsRestored() async {
    if (!isBackgroundSharingEnabled.value) return;
    if (_positionSubscription != null || !KaSpotService.isAuthenticated) return;
    _retryCount = 0;
    try {
      await _startTracking(persist: false);
    } catch (e) {
      debugPrint('Background tracking could not resume after sharing was re-enabled: $e');
    }
  }

  // ── Permissions ───────────────────────────────────────────────────────────

  /// The supported permission flow for this app's target SDK.
  ///
  /// geolocator's `requestPermission()` also asks for
  /// `ACCESS_BACKGROUND_LOCATION` while a while-in-use grant exists, which is
  /// what lets Android 10+ offer its "Allow all the time" route. Granting it
  /// still does not promise survival after a force-stop — see
  /// [LocationTrackingConfig.lifecycleDisclosure].
  static Future<PermissionGate> ensureBackgroundPermission({
    bool requestIfMissing = true,
  }) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return PermissionGate.locationServicesOff;
      }

      var permission = await Geolocator.checkPermission();

      if (requestIfMissing &&
          (permission == LocationPermission.denied ||
              permission == LocationPermission.unableToDetermine)) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.always) return PermissionGate.granted;

      if (permission == LocationPermission.whileInUse) {
        // Background access is asked for exactly once per enable gesture, so a
        // user who already refused is never nagged again by KaSpot.
        if (requestIfMissing && !_backgroundAskAttempted) {
          _backgroundAskAttempted = true;
          final upgraded = await Geolocator.requestPermission();
          if (upgraded == LocationPermission.always) return PermissionGate.granted;
          if (upgraded == LocationPermission.deniedForever) {
            return PermissionGate.deniedForever;
          }
        }
        return PermissionGate.whileInUseOnly;
      }

      if (permission == LocationPermission.deniedForever) {
        return PermissionGate.deniedForever;
      }
      if (permission == LocationPermission.denied) return PermissionGate.denied;
      return PermissionGate.platformError;
    } catch (e) {
      debugPrint('Background permission check failed: $e');
      return PermissionGate.platformError;
    }
  }

  static void _applyGateFailure(PermissionGate gate, {required bool escalate}) {
    switch (gate) {
      case PermissionGate.locationServicesOff:
        _setState(TrackingState.blockedLocationServices);
        lastError = 'Turn on device location (GPS) to start sharing.';
        if (escalate) unawaited(Geolocator.openLocationSettings());
      case PermissionGate.whileInUseOnly:
        _setState(TrackingState.blockedPermission);
        lastError = 'Background sharing needs "Allow all the time" location '
            'access. Choose it in the permissions screen, then return to KaSpot.';
        if (escalate) {
          _awaitingPermissionResolution = true;
          unawaited(Geolocator.openAppSettings());
        }
      case PermissionGate.deniedForever:
        _setState(TrackingState.blockedPermission);
        lastError = 'Location permission is permanently denied. Open KaSpot\'s '
            'App Settings and choose "Allow all the time" to start sharing.';
        if (escalate) {
          _awaitingPermissionResolution = true;
          unawaited(Geolocator.openAppSettings());
        }
      case PermissionGate.denied:
        _setState(TrackingState.blockedPermission);
        lastError = 'Location permission was denied, so sharing cannot start.';
      case PermissionGate.platformError:
        _setState(TrackingState.failed);
        lastError = 'This device could not confirm location permission.';
      case PermissionGate.granted:
        break;
    }
  }

  /// Re-checks permissions and services when KaSpot returns to the foreground,
  /// and completes an enable the user already consented to when the permission
  /// has since been granted in App Settings.
  static Future<void> onAppResumed() async {
    if (!KaSpotService.isAuthenticated) return;
    final gate = await ensureBackgroundPermission(requestIfMissing: false);

    if (gate == PermissionGate.granted) {
      if (_awaitingPermissionResolution) {
        _awaitingPermissionResolution = false;
        _backgroundAskAttempted = false;
        isBackgroundSharingEnabled.value = true;
        try {
          await _startTracking(persist: true);
        } catch (e) {
          debugPrint('Tracking did not resume after permission was granted: $e');
        }
        return;
      }
      if (isBackgroundSharingEnabled.value &&
          !isStreamingActive.value &&
          KaSpotService.sharingActive.value) {
        await _resumeAfterGrantsRestored();
        return;
      }
      lastError = null;
      return;
    }

    // Requirements are not met: reflect that instead of reporting a healthy run.
    if (isStreamingActive.value) await _teardown();
    _applyGateFailure(gate, escalate: false);
  }

  // ── Stream plumbing ───────────────────────────────────────────────────────

  static Future<void> _openStream() async {
    await _teardownStream();
    _positionSubscription = Geolocator
        .getPositionStream(locationSettings: _buildSettings())
        .listen(
          _onPosition,
          onError: (Object error) => _onStreamError('Position stream error: $error'),
        );
    isStreamingActive.value = true;
    // Re-opening after a bounded recovery must replace the heartbeat, never add
    // a second one on top of it.
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      LocationTrackingConfig.heartbeatInterval,
      (_) => unawaited(_sendHeartbeat()),
    );
    _setState(_lastFixSeen ? TrackingState.streaming : TrackingState.waitingForFix);
  }

  /// Near-real-time settings, every number taken from [LocationTrackingConfig]
  /// so the consent wording and the platform request can never disagree.
  static LocationSettings _buildSettings() {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: LocationTrackingConfig.distanceFilterMeters,
        intervalDuration: LocationTrackingConfig.streamInterval,
        foregroundNotificationConfig: const ForegroundNotificationConfig(
          notificationTitle: LocationTrackingConfig.notificationTitle,
          notificationText: LocationTrackingConfig.notificationBody,
          enableWakeLock: true,
        ),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: LocationTrackingConfig.distanceFilterMeters,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: LocationTrackingConfig.distanceFilterMeters,
    );
  }

  static void _onPosition(Position position) {
    if (_positionSubscription == null) return;
    _lastFixSeen = true;
    _retryCount = 0;
    lastFixAt.value = DateTime.now();
    livePosition.value = position;
    unawaited(_report(position));
  }

  static Future<void> _report(Position position) async {
    // A thrown upload means "no connection" and the fix is queued by
    // KaSpotService; a returned false means the authorization gate refused it.
    // Those are different problems and must never be reported as one.
    var refused = false;
    try {
      final delivered = await KaSpotService.upsertOwnLocation(position);
      if (delivered) {
        lastUploadAt.value = DateTime.now();
        lastError = null;
        if (_positionSubscription != null) _setState(TrackingState.streaming);
      } else {
        refused = true;
      }
    } catch (e) {
      // Acquisition works, delivery does not — report exactly that.
      lastError = 'Location captured but not uploaded yet.';
      debugPrint('Background location transmission deferred: $e');
      if (state.value == TrackingState.streaming ||
          state.value == TrackingState.waitingForFix) {
        _setState(TrackingState.degraded);
      }
    }
    if (refused) {
      // The write was refused because no enabled sharing grant can receive it.
      lastError = 'No active sharing grant is able to receive your position.';
      _suspendSoon();
    }
  }

  static void _onStreamError(String message) {
    debugPrint('Background location $message');
    // Tear the whole cycle down, heartbeat included, so a failing provider can
    // never accumulate timers between retry attempts.
    unawaited(_teardown());
    _scheduleRetry();
  }

  /// Bounded recovery: at most [LocationTrackingConfig.maxStreamRetries]
  /// re-openings, each tearing the previous subscription down first, so a
  /// failing provider can neither stack duplicate streams nor retry forever.
  static void _scheduleRetry() {
    if (_retryCount >= LocationTrackingConfig.maxStreamRetries) {
      _setState(TrackingState.failed);
      lastError = 'Location tracking stopped unexpectedly. Reopen KaSpot to resume.';
      return;
    }
    _retryCount++;
    _setState(TrackingState.degraded);
    lastError = 'Location tracking hiccup; attempting a bounded recovery.';
    final delay = const Duration(seconds: 2) * (1 << (_retryCount - 1));
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () async {
      if (!isBackgroundSharingEnabled.value || !KaSpotService.isAuthenticated) return;
      if (_positionSubscription != null) return;
      if (KaSpotService.sharingActive.value) {
        try {
          await _openStream();
          lastError = null;
        } catch (e) {
          _onStreamError('Could not re-open the position stream: $e');
        }
      } else {
        await _suspendForNoGrants();
      }
    });
  }

  /// One lightweight stationary fix, sent by the heartbeat timer.
  static Future<void> _sendHeartbeat() async {
    if (_positionSubscription == null) return;
    final last = lastFixAt.value;
    if (last != null &&
        DateTime.now().difference(last) < LocationTrackingConfig.heartbeatSkipWindow) {
      return; // A movement update was already reported recently.
    }
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: LocationTrackingConfig.heartbeatFixTimeLimit,
        ),
      );
      _lastFixSeen = true;
      lastFixAt.value = DateTime.now();
      livePosition.value = position;
      await _report(position);
      debugPrint('KaSpot heartbeat sent.');
    } catch (e) {
      lastError = 'The stationary heartbeat could not get a fix.';
      debugPrint('KaSpot heartbeat skipped: $e');
    }
  }

  static Future<void> _teardownStream() async {
    final subscription = _positionSubscription;
    _positionSubscription = null;
    isStreamingActive.value = false;
    if (subscription != null) await subscription.cancel();
  }

  static Future<void> _teardown() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    await _teardownStream();
    _lastFixSeen = false;
  }

  /// [state] is the only thing [_setState] claims: whether a subscription is
  /// open is reported by [isStreamingActive], which the stream plumbing owns, so
  /// a paused-retry window can never be described as "streaming".
  static void _setState(TrackingState next) {
    state.value = next;
  }

  // ── Per-device consent record ─────────────────────────────────────────────

  static String _consentKey(String uid) => '${_consentKeyPrefix}_$uid';

  static Future<bool?> _readLocalConsent(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_consentKey(uid));
    } catch (e) {
      debugPrint('Background consent could not be read: $e');
      return null;
    }
  }

  static Future<void> _writeLocalConsent(String uid, bool granted) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (granted) {
        await prefs.setBool(_consentKey(uid), true);
      } else {
        await prefs.remove(_consentKey(uid));
      }
    } catch (e) {
      debugPrint('Background consent could not be stored: $e');
    }
  }

  /// Status line for the existing settings surfaces. Reports what is actually
  /// running, never what the stored preference says.
  static String describeState() => switch (state.value) {
        TrackingState.streaming => 'Active · Sharing your latest position',
        TrackingState.waitingForFix => 'Starting · Waiting for a GPS fix',
        TrackingState.degraded => 'Degraded · ${lastError ?? 'Recovering'}',
        TrackingState.failed => 'Stopped · ${lastError ?? 'Location tracking failed'}',
        TrackingState.blockedLocationServices => 'Stopped · Device location is off',
        TrackingState.blockedPermission =>
          'Stopped · ${lastError ?? 'Location permission needed'}',
        TrackingState.suspendedNoSharing => 'Suspended · Sharing is paused',
        TrackingState.starting => 'Starting…',
        TrackingState.off => 'Off · Only updates while the app is on screen',
      };
}

class _TrackingLifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    if (lifecycleState == AppLifecycleState.resumed) {
      unawaited(BackgroundLocationService.onAppResumed());
    }
  }
}
