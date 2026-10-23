import 'dart:async';
import 'package:flutter/material.dart';
import '../screens/circle_chat_screen.dart';
import 'kaspot_service.dart';

/// Central coordinator that turns a notification tap into a navigation event to
/// the correct [CircleChatScreen] conversation.
///
/// It handles every application state:
///  * Cold start / terminated — the caller stashes the destination here and it
///    is preserved until authentication and the root navigator are ready.
///  * Background & foreground — resolved immediately once the navigator exists.
///
/// The destination is derived only from trusted routing data (the sender's
/// database id) delivered in the notification payload — never from the visible
/// title/body. Access is validated against the authenticated user's connections
/// before opening any conversation, so protected messages are never exposed.
class NotificationNavigation {
  NotificationNavigation._();

  /// The root navigator key, wired up by the app in `main.dart`.
  static GlobalKey<NavigatorState>? navigatorKey;

  static String? _pendingSenderId;
  static String? _pendingMessageId;
  static bool _authListenerAttached = false;

  // Guard against multiple callbacks firing for the same notification (e.g.
  // FCM + local, or a cold-start detail replayed) producing duplicate routes.
  static String? _lastHandledKey;
  static DateTime? _lastHandledAt;
  static const _dedupeWindow = Duration(seconds: 3);

  @visibleForTesting
  static void resetForTest() {
    if (_authListenerAttached) {
      KaSpotService.authStateNotifier.removeListener(_onAuthReady);
      _authListenerAttached = false;
    }
    _pendingSenderId = null;
    _pendingMessageId = null;
    _lastHandledKey = null;
    _lastHandledAt = null;
    navigatorKey = null;
  }

  /// Routes to the conversation with [senderId]. If the app is not yet
  /// authenticated or the navigator is not ready, the destination is preserved
  /// and applied once those become available.
  static void route(String senderId, {String? messageId}) {
    if (senderId.isEmpty) return;
    // A blank message id carries no target. Normalising it here keeps a legacy
    // or partially populated payload from scrolling to a nonexistent message.
    if (messageId != null && messageId.isEmpty) messageId = null;

    final key = '$senderId:$messageId';
    final now = DateTime.now();
    if (_lastHandledKey == key &&
        _lastHandledAt != null &&
        now.difference(_lastHandledAt!) < _dedupeWindow) {
      return; // duplicate callback for the same notification
    }
    _lastHandledKey = key;
    _lastHandledAt = now;

    if (!KaSpotService.authStateNotifier.value) {
      // Preserve intent until the user is signed in; do not expose messages.
      _pendingSenderId = senderId;
      _pendingMessageId = messageId;
      _attachAuthListener();
      return;
    }

    unawaited(_navigate(senderId, messageId));
  }

  static void _attachAuthListener() {
    if (_authListenerAttached) return;
    _authListenerAttached = true;
    KaSpotService.authStateNotifier.addListener(_onAuthReady);
  }

  static void _onAuthReady() {
    if (!KaSpotService.authStateNotifier.value) return;
    final senderId = _pendingSenderId;
    final messageId = _pendingMessageId;
    _pendingSenderId = null;
    _pendingMessageId = null;
    KaSpotService.authStateNotifier.removeListener(_onAuthReady);
    _authListenerAttached = false;
    if (senderId != null) {
      unawaited(_navigate(senderId, messageId));
    }
  }

  static Future<void> _navigate(String senderId, String? messageId) async {
    final navigator = navigatorKey?.currentState;
    if (navigator == null) return;

    // Already viewing this exact conversation — don't stack a duplicate route.
    if (KaSpotService.activeChatUserId == senderId) return;

    // Validate access and resolve the peer identity through the existing,
    // authorization-checked service. If the sender is not (or is no longer) a
    // connection, drop the navigation rather than open a protected chat.
    List<Map<String, dynamic>> conns = const [];
    try {
      conns = await KaSpotService.connections();
    } catch (_) {
      return;
    }

    final sender = conns.firstWhere(
      (c) => c['other_id'] == senderId,
      orElse: () => <String, dynamic>{},
    );
    if (sender.isEmpty) return;

    final displayName = sender['display_name'] as String? ?? 'Circle Member';
    final avatarUrl = sender['avatar_url'] as String?;

    navigator.push(
      MaterialPageRoute(
        builder: (_) => CircleChatScreen(
          otherId: senderId,
          displayName: displayName,
          avatarUrl: avatarUrl,
          initialMessageId: messageId,
        ),
      ),
    );
  }
}
