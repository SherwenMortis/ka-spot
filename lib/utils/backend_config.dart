import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Resolves **which** Supabase project this build talks to, and whether that
/// answer can be trusted.
///
/// Three things went wrong before this file existed:
///
/// 1. `.env` was read *before* `--dart-define`, so a staging build produced with
///    `--dart-define=SUPABASE_URL=https://staging…` silently used the production
///    URL from the bundled `.env` asset. Every staging check would have run
///    against production while the build command looked correct.
/// 2. Nothing compared the URL with what the build claimed to target, so a
///    typo in either one was unobservable.
/// 3. `dotenv.maybeGet` throws when `.env` was never loaded, so the documented
///    "--dart-define only" build failed at startup instead of working.
///
/// The rules now:
///
/// * an explicit `--dart-define` always wins over the bundled `.env`;
/// * a build that declares `KASPOT_BACKEND` must agree with its URL, and the
///   process refuses to start otherwise (see `main()`);
/// * `KASPOT_BACKEND=staging` may never resolve to the production project;
/// * in-app account deletion additionally requires a *verified* target
///   ([isVerified]), which an undeclared build never has. That is what keeps a
///   deletion-capable release build from existing by accident.
///
/// The production ref is a constant rather than a build flag: it is the single
/// value a staging build must never resolve to, and a constant cannot be edited
/// by accident on a build machine.
const String kLinkedProductionProjectRef = 'etuosispxwfmvcupjhkv';

/// What the build says it targets.
enum KaspotBackend {
  /// `KASPOT_BACKEND=staging`.
  staging,

  /// `KASPOT_BACKEND=production`.
  production,

  /// Not declared. Acceptable for local development, never for a build that
  /// offers account deletion.
  unspecified,
}

/// The resolved target plus the evidence behind it.
class BackendTarget {
  const BackendTarget({
    required this.url,
    required this.anonKey,
    required this.declared,
  });

  /// The Supabase URL this build will actually use.
  final String url;

  /// The publishable (anon) key for that URL.
  final String anonKey;

  /// What the build claims to target.
  final KaspotBackend declared;

  /// `https://<ref>.supabase.co` → `<ref>`; null for a local stack, a custom
  /// domain, or an unparsable URL.
  String? get projectRef {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return null;
    for (final suffix in const ['.supabase.co', '.supabase.in']) {
      if (!host.endsWith(suffix)) continue;
      final ref = host.substring(0, host.length - suffix.length);
      return ref.isEmpty || ref.contains('.') ? null : ref;
    }
    return null;
  }

  bool get hasCredentials => url.isNotEmpty && anonKey.isNotEmpty;

  /// True only for the linked production project. A custom domain or a local
  /// stack is *not* production, which is what lets staging use a local stack.
  bool get pointsAtProduction => projectRef == kLinkedProductionProjectRef;

  /// The build declares a backend and the URL agrees with it.
  bool get isVerified {
    if (!hasCredentials) return false;
    return switch (declared) {
      KaspotBackend.unspecified => false,
      KaspotBackend.production => pointsAtProduction,
      // Deliberately "not production" rather than "is the staging ref": a
      // staging build may run against a local stack or a custom domain, and the
      // property that matters is that it cannot reach production.
      KaspotBackend.staging => !pointsAtProduction,
    };
  }

  /// A contradiction between the declaration and the URL. Null when the build
  /// may start. A missing URL is not a contradiction: the app also runs without
  /// a backend (local preview).
  String? get configurationError {
    if (!hasCredentials) return null;
    final ref = projectRef ?? url;
    return switch (declared) {
      KaspotBackend.unspecified => null,
      KaspotBackend.production when !pointsAtProduction =>
        'This build declares KASPOT_BACKEND=production but points at $ref. '
            'Rebuild with the production URL, or declare the backend it really '
            'uses.',
      KaspotBackend.staging when pointsAtProduction =>
        'This build declares KASPOT_BACKEND=staging but points at the '
            'production project ($kLinkedProductionProjectRef). Refusing to '
            'start: a staging check must never touch production data.',
      _ => null,
    };
  }

  /// Reads the real build environment: `--dart-define` first, then `.env`.
  ///
  /// Never throws. `.env` is optional (CI builds pass defines only), and
  /// `dotenv.maybeGet` throws when the file was never loaded.
  static BackendTarget current() {
    String? fromFile(String key) {
      if (!dotenv.isInitialized) return null;
      final value = dotenv.maybeGet(key)?.trim();
      return (value == null || value.isEmpty) ? null : value;
    }

    // The precedence rule lives in resolve(): a non-empty --dart-define wins,
    // which is the fix. The previous code preferred the bundled `.env`.
    return resolve(
      definedUrl: const String.fromEnvironment('SUPABASE_URL'),
      definedAnonKey: const String.fromEnvironment('SUPABASE_ANON_KEY'),
      declaredBackend: const String.fromEnvironment('KASPOT_BACKEND'),
      fileUrl: fromFile('SUPABASE_URL') ?? '',
      fileAnonKey: fromFile('SUPABASE_ANON_KEY') ?? '',
    );
  }

  /// Pure resolution, so the precedence and the guards can be tested without a
  /// build machine.
  static BackendTarget resolve({
    required String definedUrl,
    required String definedAnonKey,
    required String declaredBackend,
    required String fileUrl,
    required String fileAnonKey,
  }) {
    final url = definedUrl.trim().isNotEmpty
        ? definedUrl.trim()
        : fileUrl.trim();
    final key = definedAnonKey.trim().isNotEmpty
        ? definedAnonKey.trim()
        : fileAnonKey.trim();
    return BackendTarget(
      url: url,
      anonKey: key,
      declared: parseBackend(declaredBackend),
    );
  }

  /// `staging` / `production` (case-insensitive); anything else is
  /// [KaspotBackend.unspecified] rather than a guess.
  static KaspotBackend parseBackend(String value) {
    return switch (value.trim().toLowerCase()) {
      'staging' => KaspotBackend.staging,
      'production' => KaspotBackend.production,
      _ => KaspotBackend.unspecified,
    };
  }

  @override
  String toString() =>
      'BackendTarget(declared: ${declared.name}, ref: ${projectRef ?? url}, '
      'verified: $isVerified)';
}
