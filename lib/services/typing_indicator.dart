import 'dart:async';

import 'package:flutter/foundation.dart';

/// Ephemeral, conversation-scoped typing state for the Circle chat.
///
/// Design notes
/// ------------
/// * Typing is transported over Supabase Realtime **Broadcast**, never written
///   to the database. No message rows, no `circle_messages` schema change and
///   therefore no push notification is ever produced for typing.
/// * The controller is transport-agnostic: the screen hands it a [broadcast]
///   callback (bound to the conversation's existing Realtime channel) and feeds
///   inbound payloads into [handlePeerBroadcast]. That keeps the timing rules
///   fully testable without a live Supabase project.
/// * Sender side emits at most one `start`, then at most one refresh per
///   [heartbeatInterval] and one `stop` — never one event per keystroke.
/// * Receiver side always arms [staleTimeout], so a lost `stop` (network drop,
///   killed app, realtime disconnect) can never leave the indicator stuck.
class TypingIndicatorController {
  TypingIndicatorController({
    required this.selfId,
    required this.peerId,
    required this.broadcast,
    this.startDelay = const Duration(milliseconds: 400),
    this.idleStopDelay = const Duration(milliseconds: 2000),
    this.heartbeatInterval = const Duration(seconds: 3),
    this.staleTimeout = const Duration(seconds: 5),
  });

  /// Broadcast event name shared by both peers.
  static const String broadcastEvent = 'typing';

  static const String _stateStart = 'start';
  static const String _stateStop = 'stop';

  /// Builds the payload that is broadcast for [senderId]. Only the sender's own
  /// authenticated id is ever put on the wire — no message content.
  static Map<String, dynamic> buildPayload(String senderId, String state) =>
      {'sender_id': senderId, 'state': state};

  /// This device's authenticated user id. Owned by the caller (never read from
  /// an inbound payload), so a peer cannot spoof someone else's typing.
  final String selfId;

  /// The other participant of this conversation.
  final String peerId;

  /// Bound to the conversation's existing Realtime channel.
  final void Function(Map<String, dynamic> payload) broadcast;

  /// How long the user must keep typing before we announce anything (A5).
  final Duration startDelay;

  /// How long the composer may sit idle before typing is considered stopped.
  final Duration idleStopDelay;

  /// Refresh cadence that keeps a still-active `start` alive on the peer while
  /// the user types for a long time, without emitting per keystroke.
  final Duration heartbeatInterval;

  /// Receiver-side expiry: the indicator disappears if nothing refreshes it.
  final Duration staleTimeout;

  /// True while the *peer* is typing. Drives the three-dot indicator only —
  /// listening to this never rebuilds the message list.
  final ValueNotifier<bool> peerTyping = ValueNotifier<bool>(false);

  bool _disposed = false;

  // ── Sender side ────────────────────────────────────────────────────────────

  Timer? _startTimer;
  Timer? _idleStopTimer;
  Timer? _heartbeat;
  bool _announced = false;

  /// Called from the composer's text listener on every change.
  ///
  /// A stray space is not "typing"; only non-whitespace text announces.
  void onComposerChanged(String text) {
    if (_disposed) return;
    if (text.trim().isEmpty) {
      // Composer emptied → stop immediately (A5).
      stopAnnouncing();
      return;
    }

    // Every keystroke only pushes back the idle stop. It never sends anything.
    _idleStopTimer?.cancel();
    _idleStopTimer = Timer(idleStopDelay, stopAnnouncing);

    if (_announced) return; // already live; heartbeat keeps it alive
    if (_startTimer != null) return; // debounce already scheduled

    _startTimer = Timer(startDelay, _announceStart);
  }

  void _announceStart() {
    if (_disposed) return;
    _startTimer = null;
    if (_announced) return;
    _announced = true;
    _send(_stateStart);
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      if (_disposed || !_announced) return;
      // Refresh, so a peer that is still typing does not expire its own
      // indicator while the receiver's stale timeout elapses.
      _send(_stateStart);
    });
  }

  /// Broadcasts `stop` if we are currently announcing and clears every timer.
  void stopAnnouncing() {
    if (_disposed) return;
    _startTimer?.cancel();
    _startTimer = null;
    _idleStopTimer?.cancel();
    _idleStopTimer = null;
    _heartbeat?.cancel();
    _heartbeat = null;
    if (!_announced) return;
    _announced = false;
    _send(_stateStop);
  }

  /// A message was sent: typing ends at once, and the peer's indicator must
  /// disappear immediately (the message itself replaces it).
  void onMessageSent() => stopAnnouncing();

  /// The app left the foreground / the conversation is being torn down, where a
  /// continued typing claim can no longer be trusted.
  void onLeaveConversation() => stopAnnouncing();

  // ── Receiver side ──────────────────────────────────────────────────────────

  Timer? _staleTimer;

  /// Applies an inbound typing broadcast for this conversation.
  ///
  /// Anything that is not our peer's event is ignored: our own echo (a user
  /// must never see their own indicator), another conversation, and
  /// client-supplied ids that do not match this conversation's peer.
  void handlePeerBroadcast(Map<String, dynamic> payload) {
    if (_disposed) return;
    final senderId = payload['sender_id'] as String?;
    if (senderId == null || senderId != peerId) return;
    if (senderId == selfId) return;

    final state = payload['state'] as String?;
    if (state == _stateStart) {
      peerTyping.value = true;
      _staleTimer?.cancel();
      _staleTimer = Timer(staleTimeout, _expirePeerTyping);
    } else if (state == _stateStop) {
      _staleTimer?.cancel();
      _staleTimer = null;
      peerTyping.value = false;
    }
  }

  void _expirePeerTyping() {
    _staleTimer = null;
    // A missing stop event must never keep the dots on screen forever (A6).
    peerTyping.value = false;
  }

  // ── Plumbing ───────────────────────────────────────────────────────────────

  void _send(String state) {
    try {
      broadcast(buildPayload(selfId, state));
    } catch (e) {
      // Typing is cosmetic: a not-yet-joined channel must never surface an
      // error or break sending messages.
      debugPrint('[Typing] broadcast failed: $e');
    }
  }

  void dispose() {
    if (_disposed) return;
    stopAnnouncing();
    _disposed = true;
    _staleTimer?.cancel();
    _staleTimer = null;
    peerTyping.value = false;
    peerTyping.dispose();
  }

  /// Exposed for regression tests only.
  @visibleForTesting
  bool get isAnnouncingForTests => _announced;
}
