import 'package:flutter_test/flutter_test.dart';
import 'package:kaspot/utils/backend_config.dart';
import 'package:kaspot/utils/release_flags.dart';

/// The staging build has to be *provably* aimed at staging. These tests cover
/// the resolution rules that make that true, because the previous behaviour
/// (`.env` before `--dart-define`) made a correct-looking build command silently
/// target production.
void main() {
  const productionUrl = 'https://etuosispxwfmvcupjhkv.supabase.co';
  const stagingUrl = 'https://abcdefghijklmnop.supabase.co';

  BackendTarget build({
    String definedUrl = '',
    String definedAnonKey = '',
    String declared = '',
    String fileUrl = productionUrl,
    String fileAnonKey = 'anon-from-file',
  }) {
    return BackendTarget.resolve(
      definedUrl: definedUrl,
      definedAnonKey: definedAnonKey,
      declaredBackend: declared,
      fileUrl: fileUrl,
      fileAnonKey: fileAnonKey,
    );
  }

  group('precedence', () {
    test('a --dart-define URL wins over the bundled .env', () {
      final target = build(
        definedUrl: stagingUrl,
        definedAnonKey: 'anon-from-define',
        declared: 'staging',
      );

      expect(target.url, stagingUrl);
      expect(target.anonKey, 'anon-from-define');
      expect(target.projectRef, 'abcdefghijklmnop');
      // The whole point: the production value that used to win is ignored.
      expect(target.pointsAtProduction, isFalse);
    });

    test('the .env value is still used when no define is present', () {
      final target = build(declared: 'production');

      expect(target.url, productionUrl);
      expect(target.anonKey, 'anon-from-file');
      expect(target.pointsAtProduction, isTrue);
    });

    test(
      'an empty --dart-define falls through instead of blanking the URL',
      () {
        final target = build(definedUrl: '   ', definedAnonKey: '');

        expect(target.url, productionUrl);
        expect(target.anonKey, 'anon-from-file');
      },
    );
  });

  group('declared backend versus actual target', () {
    test('staging + a staging project is verified and has no error', () {
      final target = build(
        definedUrl: stagingUrl,
        definedAnonKey: 'k',
        declared: 'staging',
      );

      expect(target.configurationError, isNull);
      expect(target.isVerified, isTrue);
    });

    test('staging + the production project refuses to run', () {
      final target = build(
        definedUrl: productionUrl,
        definedAnonKey: 'k',
        declared: 'staging',
      );

      expect(target.isVerified, isFalse);
      expect(target.configurationError, isNotNull);
      expect(
        target.configurationError,
        contains('must never touch production'),
      );
    });

    test('production + the production project is verified', () {
      final target = build(
        definedUrl: productionUrl,
        definedAnonKey: 'k',
        declared: 'production',
      );

      expect(target.configurationError, isNull);
      expect(target.isVerified, isTrue);
    });

    test('production + a staging project refuses to run', () {
      final target = build(
        definedUrl: stagingUrl,
        definedAnonKey: 'k',
        declared: 'production',
      );

      expect(target.isVerified, isFalse);
      expect(
        target.configurationError,
        contains('declares KASPOT_BACKEND=production'),
      );
    });

    test('a staging build may use a local stack', () {
      final target = build(
        definedUrl: 'http://127.0.0.1:54321',
        definedAnonKey: 'k',
        declared: 'staging',
      );

      expect(target.projectRef, isNull);
      expect(target.pointsAtProduction, isFalse);
      expect(target.isVerified, isTrue);
    });

    test('an undeclared build starts but is never verified', () {
      final target = build(definedUrl: productionUrl, definedAnonKey: 'k');

      // No error: local runs without a declaration must keep working.
      expect(target.configurationError, isNull);
      // But nothing that needs a trustworthy target may switch on.
      expect(target.isVerified, isFalse);
    });

    test('a build with no credentials is not an error, just unverified', () {
      final target = build(definedUrl: '', fileUrl: '', declared: 'staging');

      expect(target.hasCredentials, isFalse);
      expect(target.configurationError, isNull);
      expect(target.isVerified, isFalse);
    });
  });

  group('parsing', () {
    test('project ref comes out of a supabase.co host', () {
      expect(
        build(definedUrl: productionUrl, definedAnonKey: 'k').projectRef,
        'etuosispxwfmvcupjhkv',
      );
    });

    test('a custom domain has no project ref but is not production', () {
      final target = build(
        definedUrl: 'https://api.example.com',
        definedAnonKey: 'k',
      );

      expect(target.projectRef, isNull);
      expect(target.pointsAtProduction, isFalse);
    });

    test('backend declarations are case-insensitive and never guessed', () {
      expect(BackendTarget.parseBackend('Staging'), KaspotBackend.staging);
      expect(
        BackendTarget.parseBackend(' PRODUCTION '),
        KaspotBackend.production,
      );
      expect(BackendTarget.parseBackend('prod'), KaspotBackend.unspecified);
      expect(BackendTarget.parseBackend(''), KaspotBackend.unspecified);
    });
  });

  group('account deletion gate', () {
    test('is off in a test build, which declares nothing', () {
      // Widget tests do not pass --dart-define, so the backend is undeclared and
      // the flag stays false even though the tests that need it assign it
      // directly.
      expect(BackendTarget.current().isVerified, isFalse);
      expect(ReleaseFlags.accountDeletionEnabled, isFalse);
    });
  });
}
