import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/background_location_service.dart';
import '../services/kaspot_service.dart';

/// Permanent account deletion. Nothing here runs on open: the request is only
/// sent after the user has typed DELETE, read what will be removed, and proved
/// they are the account owner (password re-entry, or a fresh Google exchange).
class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  static const _danger = Color(0xFFDC2626);
  static const _heading = Color(0xFF0F172A);
  static const _body = Color(0xFF334155);
  static const _muted = Color(0xFF64748B);
  static const _border = Color(0xFFE2E8F0);

  final TextEditingController _confirmController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  late final bool _usesPassword = KaSpotService.hasPasswordIdentity;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _confirmController.addListener(_onConfirmChanged);
  }

  @override
  void dispose() {
    _confirmController.removeListener(_onConfirmChanged);
    _confirmController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onConfirmChanged() => setState(() {});

  /// The typed word must match exactly, in any letter case: this is a
  /// deliberate gesture, not a tap that can happen by accident.
  bool get _wordConfirmed =>
      _confirmController.text.trim().toUpperCase() == 'DELETE';

  bool get _canSubmit => !_busy && _wordConfirmed;

  static String _messageFor(Object error) {
    if (error is AuthException) return error.message;
    final text = error.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }

  Future<void> _delete() async {
    if (!_canSubmit) return;
    // Captured before the session ends: the account change pops this route back
    // to the welcome screen, so the feedback must outlive it.
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      if (_usesPassword && _passwordController.text.isEmpty) {
        throw Exception('Enter your password to confirm.');
      }
      // Google-only accounts send a freshly issued ID token instead of a
      // password. The server verifies it against this account's Google identity;
      // acquiring it does not change the current session.
      String? googleIdToken;
      if (!_usesPassword) {
        googleIdToken = await KaSpotService.acquireGoogleDeletionProof();
        if (googleIdToken == null) {
          throw Exception(
            'Google confirmation was cancelled. Your account was not deleted.',
          );
        }
      }

      final outcome = await KaSpotService.deleteAccount(
        password: _usesPassword ? _passwordController.text : null,
        googleIdToken: googleIdToken,
      );
      // The account is gone either way, so tracking is stopped locally:
      // withdrawing the preference from the server is no longer possible or
      // meaningful. A failure here must not turn a confirmed deletion into an
      // error message, so it is contained rather than propagated.
      try {
        await BackgroundLocationService.onSignedOut();
      } catch (_) {}

      final cleanupVerified = outcome == DeleteAccountOutcome.deleted;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            cleanupVerified
                ? 'Your KaSpot account and its data were deleted.'
                : KaSpotService.deleteAccountCleanupUnverifiedMessage,
          ),
          behavior: SnackBarBehavior.floating,
          // An unverified cleanup is not a success toast: it stays long enough
          // to be read, because the user needs to know the difference.
          duration: Duration(seconds: cleanupVerified ? 4 : 10),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _messageFor(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Delete Account')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          _warningCard(),
          const SizedBox(height: 16),
          _section('What will be deleted'),
          _removalList(),
          const SizedBox(height: 16),
          _section('What changes for other people'),
          _card(
            child: const Text(
              'Your messages are removed from your circle members’ chats as well: '
              'KaSpot stores one copy per conversation, so neither side keeps it. '
              'People you shared your location with lose access immediately, and '
              'your profile photo disappears from their circle.',
              style: TextStyle(height: 1.45, fontSize: 13.5, color: _body),
            ),
          ),
          const SizedBox(height: 16),
          _section('Confirm it is you'),
          _reauthentication(),
          const SizedBox(height: 16),
          _section('Last step'),
          _confirmation(),
          if (_error != null) ...[
            const SizedBox(height: 16),
            _errorCard(_error!),
          ],
          const SizedBox(height: 20),
          _deleteButton(),
          const SizedBox(height: 12),
          const Text(
            'This deletes your KaSpot account. It does not delete your Google '
            'account. Android may keep a system backup of app data that KaSpot '
            'cannot reach.',
            style: TextStyle(fontSize: 12, height: 1.45, color: _muted),
          ),
        ],
      ),
    );
  }

  Widget _warningCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: _danger, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'This cannot be undone',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: _danger,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Deleting your account permanently removes your profile, your '
                  'saved location data and your messages. KaSpot cannot restore '
                  'them afterwards.',
                  style: TextStyle(height: 1.45, fontSize: 13.5, color: _body),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
    child: Text(
      text.toUpperCase(),
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        color: _muted,
        letterSpacing: 0.8,
      ),
    ),
  );

  Widget _card({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _border),
      ),
      child: child,
    );
  }

  Widget _removalList() {
    const entries = <(IconData, String, String)>[
      (
        Icons.person_outline_rounded,
        'Account and sign-in',
        'Your email address, display name and sign-in method.',
      ),
      (
        Icons.photo_outlined,
        'Profile photo',
        'The picture stored on your profile.',
      ),
      (
        Icons.location_on_outlined,
        'Your location',
        'The single latest coordinate KaSpot held for you, plus every sharing '
            'permission you granted.',
      ),
      (
        Icons.groups_outlined,
        'Your circle',
        'Connections, pending invitations and the relationship labels you set.',
      ),
      (
        Icons.chat_bubble_outline_rounded,
        'Messages',
        'Every message you sent or received, its read state and reactions.',
      ),
      (
        Icons.bookmark_border_rounded,
        'Saved places',
        'The places you saved on the map.',
      ),
      (
        Icons.notifications_none_rounded,
        'Notifications',
        'Your device push token and notification preferences.',
      ),
    ];

    return _card(
      child: Column(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) const Divider(height: 20, color: _border),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(entries[i].$1, size: 20, color: _muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entries[i].$2,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: _heading,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        entries[i].$3,
                        style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: _muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _reauthentication() {
    if (!_usesPassword) {
      return _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This account signs in with Google. Confirm with the same Google '
              'account to continue.',
              style: TextStyle(height: 1.45, fontSize: 13.5, color: _body),
            ),
            const SizedBox(height: 10),
            const Text(
              'The Google prompt opens after you tap the delete button below.',
              style: TextStyle(fontSize: 12, color: _muted),
            ),
          ],
        ),
      );
    }

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Re-enter your password. The deletion service asks the sign-in '
            'service to verify it before anything is deleted, and the password '
            'itself is never stored.',
            style: TextStyle(height: 1.45, fontSize: 13.5, color: _body),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('delete-account-password'),
            controller: _passwordController,
            obscureText: true,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Password',
              hintText: 'Your current password',
              prefixIcon: Icon(Icons.lock_outline_rounded),
            ),
          ),
        ],
      ),
    );
  }

  Widget _confirmation() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Type DELETE to confirm.',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: _body,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('delete-account-confirm'),
            controller: _confirmController,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              hintText: 'DELETE',
              prefixIcon: const Icon(Icons.keyboard_outlined),
              suffixIcon: _wordConfirmed
                  ? const Icon(
                      Icons.check_circle_rounded,
                      color: Color(0xFF10B981),
                    )
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorCard(String message) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: _danger, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                color: Color(0xFFB91C1C),
                fontSize: 13,
                height: 1.4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _deleteButton() {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        key: const Key('delete-account-submit'),
        style: FilledButton.styleFrom(
          backgroundColor: _danger,
          disabledBackgroundColor: const Color(0xFFFCA5A5),
          padding: const EdgeInsets.symmetric(vertical: 16),
        ),
        onPressed: _canSubmit ? _delete : null,
        child: _busy
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : const Text('Delete my account permanently'),
      ),
    );
  }
}
