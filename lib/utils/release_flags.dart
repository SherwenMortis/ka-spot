import 'backend_config.dart';

/// Build-time switches that must match what has actually been deployed.
///
/// These are not A/B feature toggles: each one records whether the backend the
/// build talks to has the capability the UI offers. Shipping a screen that calls
/// an endpoint which does not exist is a broken promise, so the default is
/// always the safe, offline state.
class ReleaseFlags {
  ReleaseFlags._();

  /// Whether this build may offer in-app account deletion.
  ///
  /// Requires the `delete-account` Edge Function to be deployed **and verified**
  /// on the project this build points at. A build produced without
  /// `--dart-define=KASPOT_ACCOUNT_DELETION=true` hides the flow, and the
  /// Privacy Policy then states that deletion is unavailable in this build
  /// instead of directing users to a screen that cannot delete anything.
  ///
  /// Two conditions must hold, and the second one is not decorative:
  ///
  ///  1. the build passed `KASPOT_ACCOUNT_DELETION=true`, and
  ///  2. the build declares a backend (`KASPOT_BACKEND`) that matches the URL it
  ///     actually uses (see [BackendTarget.isVerified]).
  ///
  /// Without (2), a build whose `.env` silently wins over `--dart-define` would
  /// offer a deletion button that deletes the *other* environment's accounts.
  /// The staging APK is therefore built with `KASPOT_BACKEND=staging`, and an
  /// undeclared build (every existing release) keeps this false.
  ///
  /// Mutable only so widget tests can exercise both states; no application code
  /// writes it.
  static bool accountDeletionEnabled =
      const bool.fromEnvironment('KASPOT_ACCOUNT_DELETION') &&
      BackendTarget.current().isVerified;
}
