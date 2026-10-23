import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/in_app_notification_service.dart';
import '../services/kaspot_service.dart';
import '../services/push_notification_service.dart';
import '../services/typing_indicator.dart';
import '../utils/chat_channel.dart';
import '../widgets/kaspot_avatar.dart';
import '../widgets/message_reaction_bar.dart';
import '../widgets/reaction_picker_overlay.dart';
import '../widgets/typing_dots.dart';

class CircleChatScreen extends StatefulWidget {
  const CircleChatScreen({
    super.key,
    required this.otherId,
    required this.displayName,
    this.avatarUrl,
    this.theyShareWithMe = false,
    this.initialMessageId,
  });

  final String otherId;
  final String displayName;
  final String? avatarUrl;
  final bool theyShareWithMe;

  /// When set (e.g. from a notification tap), the chat scrolls to and briefly
  /// highlights this message once it is loaded. Null keeps the default behavior.
  final String? initialMessageId;

  @override
  State<CircleChatScreen> createState() => _CircleChatScreenState();
}

class _CircleChatScreenState extends State<CircleChatScreen>
    with WidgetsBindingObserver {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();

  /// Ephemeral typing state for THIS conversation only. Broadcast over the
  /// existing Realtime channel, never written to the database.
  TypingIndicatorController? _typing;

  /// Named so the composer listener can be removed in dispose().
  VoidCallback? _typingComposerListener;

  /// Messages stored with newest at index 0 (matches reversed ListView).
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  bool _sending = false;
  RealtimeChannel? _channel;

  /// Ensures the notification `initialMessageId` is scrolled to at most once.
  bool _didNavigateToInitialMessage = false;

  /// Active message being replied to (if any).
  Map<String, dynamic>? _replyingToMessage;

  /// Controls display of the floating "↓ New messages" button when scrolled up.
  bool _showScrollToBottom = false;
  int _newIncomingCount = 0;

  /// Whether the reader is looking at the newest message. The floating typing
  /// indicator and the clearance it needs only apply at the bottom, so showing
  /// or hiding it can never shift a reading position.
  bool _isPinnedToBottom = true;

  // ── Reactions ─────────────────────────────────────────────────────────────

  /// Reactions keyed by messageId. Each value is a list of reaction rows.
  Map<String, List<Map<String, dynamic>>> _reactions = {};

  /// Tracks in-flight reaction operations to prevent duplicate submissions.
  final Set<String> _pendingReactionMessageIds = {};

  // ──────────────────────────────────────────────────────────────────────────

  static const List<String> _quickAlerts = [
    "🚶 I'm away right now",
    "🚗 Heading out now",
    "📍 Arrived safely!",
    "⏱️ Back in 15 mins",
    "🔔 Please check on me",
  ];

  /// Extra bottom inset for the message list while the peer's dots are floating
  /// over the feed: the pill (≈26 px) plus its 8 px offset, less the 12 px the
  /// list already rests at. Keeps the newest bubble fully clear of the dots.
  static const double _kTypingClearance = 26.0;

  /// How far from the newest message still counts as "at the bottom".
  static const double _kPinnedToBottomTolerance = 12.0;

  /// Below this body height (the window minus the keyboard and the app bar) the
  /// app bar, quick-alert row and composer cannot all fit and still leave the
  /// feed readable, so the optional shortcut row steps aside and the composer's
  /// padding tightens. Nothing is scaled down.
  static const double _kShortViewportHeight = 220.0;

  /// How many wrapped lines the composer shows before it starts scrolling
  /// internally. Messenger-style: one line at rest, growing with the draft.
  static const int _kComposerMaxLines = 5;

  /// Ceiling on the share of the chat body the composer may occupy. A fixed
  /// five-line cap would leave no readable feed on a landscape phone with the
  /// keyboard open, so the line count is derived from the space available.
  static const double _kComposerHeightShare = 0.4;

  @override
  void initState() {
    super.initState();
    KaSpotService.activeChatUserId = widget.otherId;
    _scrollController.addListener(_onScroll);
    _loadMessages();
    _subscribeRealtime();
    _setupTyping();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(KaSpotService.markMessagesRead(widget.otherId));
      PushNotificationService.clearNotificationsForSender(widget.otherId);
      InAppNotificationService.dismissForSender(widget.otherId);
    });
  }

  /// Creates the conversation-scoped typing controller and attaches the
  /// composer listener. Called once from initState, so navigating into the same
  /// chat repeatedly can never stack subscriptions or timers (A8).
  void _setupTyping() {
    _typing = TypingIndicatorController(
      selfId: KaSpotService.userId,
      peerId: widget.otherId,
      broadcast: _broadcastTyping,
    );
    _typingComposerListener = () {
      _typing?.onComposerChanged(_textController.text);
    };
    _textController.addListener(_typingComposerListener!);
  }

  /// Sends a typing event on the conversation's existing channel.
  void _broadcastTyping(Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null) return; // Not configured: typing stays invisible.
    unawaited(
      channel
          .sendBroadcastMessage(
            event: TypingIndicatorController.broadcastEvent,
            payload: payload,
          )
          .catchError((Object error) {
            // A failed cosmetic broadcast must never surface in the chat.
            debugPrint('[Typing] broadcast error: $error');
            return ChannelResponse.ok;
          }),
    );
  }

  @override
  void didUpdateWidget(CircleChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.otherId == widget.otherId) return;
    // This State was re-targeted at a different conversation. Nothing may
    // survive the switch: not the previous peer's typing state or timers, not
    // their channel, messages, reactions or draft (A5, A8).
    _releaseTypingAndChannel();
    _textController.clear();
    setState(() {
      _messages = [];
      _reactions = {};
      _replyingToMessage = null;
      _loading = true;
      _sending = false;
      _isPinnedToBottom = true;
      _showScrollToBottom = false;
      _newIncomingCount = 0;
      _didNavigateToInitialMessage = false;
    });
    KaSpotService.activeChatUserId = widget.otherId;
    _loadMessages();
    _subscribeRealtime();
    _setupTyping();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Backgrounded / detached: we can no longer prove the user is still typing,
    // so stop rather than leave the peer's dots hanging (A5).
    if (state != AppLifecycleState.resumed) {
      _typing?.onLeaveConversation();
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pinned = _scrollController.offset <= _kPinnedToBottomTolerance;
    // Only rebuilt when the reader actually crosses the bottom edge, so the
    // floating indicator costs no rebuilds during ordinary scrolling.
    if (pinned != _isPinnedToBottom) {
      setState(() => _isPinnedToBottom = pinned);
    }
    if (_scrollController.offset <= 40 && _showScrollToBottom) {
      setState(() {
        _showScrollToBottom = false;
        _newIncomingCount = 0;
      });
    }
  }

  /// Subscribe to Supabase Realtime for instant incoming messages, read
  /// receipts, and reaction changes.
  void _subscribeRealtime() {
    if (!KaSpotService.isConfigured) return;
    final myId = KaSpotService.userId;

    // Both participants must join the SAME channel or neither receives the
    // other's broadcast, so the name comes from the sorted id pair. The channel
    // is private, which makes Supabase authorize join + broadcast against the
    // realtime.messages policies: only the two members of this conversation,
    // while their connection is accepted, can subscribe or publish here.
    _channel =
        KaSpotService.client!.channel(
            chatChannelNameFor(myId, widget.otherId),
            opts: chatChannelConfig,
          )
          ..onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'circle_messages',
            callback: (payload) {
              final newRecord = payload.newRecord;
              final senderId = newRecord['sender_id'] as String?;
              final recipientId = newRecord['recipient_id'] as String?;

              final isRelevant =
                  (senderId == myId && recipientId == widget.otherId) ||
                  (senderId == widget.otherId && recipientId == myId);
              if (!isRelevant) return;

              if (senderId == widget.otherId) {
                unawaited(KaSpotService.markMessagesRead(widget.otherId));
                unawaited(
                  PushNotificationService.clearNotificationsForSender(
                    widget.otherId,
                  ),
                );
                InAppNotificationService.dismissForSender(widget.otherId);
              }

              if (_scrollController.hasClients &&
                  _scrollController.offset > 80) {
                if (mounted) {
                  setState(() {
                    _showScrollToBottom = true;
                    _newIncomingCount++;
                  });
                }
              }

              _loadMessages(silent: true);
            },
          )
          ..onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'circle_messages',
            callback: (payload) {
              final updated = payload.newRecord;
              final updatedId = updated['id'] as String?;
              final newReadAt = updated['read_at'];

              if (updatedId != null && mounted) {
                setState(() {
                  for (final m in _messages) {
                    if (m['id'] == updatedId) {
                      m['read_at'] = newReadAt;
                    }
                  }
                });
              }
            },
          )
          // ── Reaction realtime handlers ────────────────────────────────────────
          ..onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'message_reactions',
            callback: (payload) => _handleReactionChange(payload.newRecord),
          )
          ..onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'message_reactions',
            callback: (payload) => _handleReactionChange(payload.newRecord),
          )
          ..onPostgresChanges(
            event: PostgresChangeEvent.delete,
            schema: 'public',
            table: 'message_reactions',
            callback: (payload) => _handleReactionDelete(payload.oldRecord),
          )
          // ── Typing: ephemeral broadcast on the SAME channel (no second
          // subscription, no database write, no notification). The controller drops
          // anything that is not this conversation's peer, including our own echo.
          ..onBroadcast(
            event: TypingIndicatorController.broadcastEvent,
            callback: (payload) => _typing?.handlePeerBroadcast(payload),
          )
          ..subscribe();
  }

  /// Applies a newly inserted or updated reaction to local state.
  void _handleReactionChange(Map<String, dynamic> record) {
    if (!mounted) return;
    final messageId = record['message_id'] as String?;
    if (messageId == null) return;

    // Verify the message belongs to this conversation.
    final inConversation = _messages.any((m) => m['id'] == messageId);
    if (!inConversation) return;

    setState(() {
      final list = _reactions.putIfAbsent(messageId, () => []);
      final idx = list.indexWhere((r) => r['id'] == record['id']);
      if (idx >= 0) {
        list[idx] = Map<String, dynamic>.from(record);
      } else {
        // Also de-duplicate by (message_id, user_id) to handle races.
        final uid = record['user_id'] as String?;
        list.removeWhere((r) => r['user_id'] == uid);
        list.add(Map<String, dynamic>.from(record));
      }
    });
  }

  /// Removes a deleted reaction from local state.
  void _handleReactionDelete(Map<String, dynamic> record) {
    if (!mounted) return;
    final messageId = record['message_id'] as String?;
    final reactionId = record['id'] as String?;
    if (messageId == null || reactionId == null) return;

    if (!_messages.any((m) => m['id'] == messageId)) return;

    setState(() {
      _reactions[messageId]?.removeWhere((r) => r['id'] == reactionId);
    });
  }

  /// Releases everything that belongs to one peer: the typing controller (whose
  /// final `stop` must go out while the channel is still attached) and the
  /// conversation's Realtime channel.
  void _releaseTypingAndChannel() {
    final composerListener = _typingComposerListener;
    if (composerListener != null) {
      _textController.removeListener(composerListener);
      _typingComposerListener = null;
    }
    // Cancels every timer and broadcasts `stop` while the channel is still
    // attached, so the peer's dots vanish the moment this screen goes away.
    _typing?.dispose();
    _typing = null;
    if (KaSpotService.activeChatUserId == widget.otherId) {
      KaSpotService.activeChatUserId = null;
    }
    final channel = _channel;
    _channel = null;
    if (channel != null && KaSpotService.isConfigured) {
      unawaited(KaSpotService.client!.removeChannel(channel));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _releaseTypingAndChannel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadMessages({bool silent = false}) async {
    final expectedOtherId = widget.otherId;
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final msgs = await KaSpotService.getCircleMessages(expectedOtherId);
      if (!mounted || widget.otherId != expectedOtherId) return;

      final authoritative = msgs.reversed.toList();

      // Load reactions for these messages.
      final ids = authoritative
          .map((m) => m['id'] as String)
          .where((id) => !id.startsWith('temp-'))
          .toList();
      final reactions = await KaSpotService.getReactionsForMessages(ids);

      if (!mounted || widget.otherId != expectedOtherId) return;
      setState(() {
        _messages = authoritative;
        _loading = false;
        // Merge: keep optimistic entries for messages not in the server result.
        for (final entry in reactions.entries) {
          _reactions[entry.key] = entry.value;
        }
      });

      KaSpotService.markMessagesRead(widget.otherId);
      PushNotificationService.clearNotificationsForSender(widget.otherId);
      InAppNotificationService.dismissForSender(widget.otherId);

      _maybeScrollToInitialMessage();
    } catch (_) {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  Future<void> _sendMessage([String? presetText]) async {
    // Kept untrimmed so a failed send can hand the draft back exactly as it was
    // typed, line breaks included.
    final raw = presetText ?? _textController.text;
    final text = raw.trim();
    if (text.isEmpty || _sending) return;

    final myId = KaSpotService.userId;
    final replyTo = _replyingToMessage;
    final replyToId = replyTo?['id'] as String?;

    // The peer's indicator must disappear as soon as the message leaves, not
    // after the round-trip completes.
    _typing?.onMessageSent();

    if (presetText == null) _textController.clear();

    setState(() {
      _sending = true;
      _replyingToMessage = null;
      _messages.insert(0, {
        'id': 'temp-${DateTime.now().millisecondsSinceEpoch}',
        'sender_id': myId,
        'recipient_id': widget.otherId,
        'content': text,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'read_at': null,
        'reply_to_message_id': replyToId,
        '_pending': true,
      });
    });

    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.animateTo(
        0.0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }

    try {
      await KaSpotService.sendCircleMessage(
        widget.otherId,
        text,
        replyToMessageId: replyToId,
      );
      await _loadMessages(silent: true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.removeWhere((m) => m['_pending'] == true);
          // The message never left, so the draft belongs to the user again.
          // It is only put back when they have not started a new one while the
          // attempt was in flight, and never on top of text they just typed.
          if (presetText == null && _textController.text.isEmpty) {
            _textController.value = TextEditingValue(
              text: raw,
              selection: TextSelection.collapsed(offset: raw.length),
            );
            _replyingToMessage ??= replyTo;
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _initiateReply(Map<String, dynamic> message) {
    setState(() => _replyingToMessage = message);
    _focusNode.requestFocus();
  }

  void _cancelReply() {
    setState(() => _replyingToMessage = null);
  }

  void _scrollToMessageId(String messageId) {
    final index = _messages.indexWhere((m) => m['id'] == messageId);
    if (index != -1 && _scrollController.hasClients) {
      final targetOffset = (index * 72.0).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  /// If the screen was opened from a notification carrying a specific message
  /// id, scroll to that message once (after the first load). Falls back to the
  /// normal bottom-anchored behavior if the message is missing/deleted.
  void _maybeScrollToInitialMessage() {
    final targetId = widget.initialMessageId;
    if (targetId == null ||
        _didNavigateToInitialMessage ||
        !_scrollController.hasClients) {
      return;
    }
    final exists = _messages.any((m) => m['id'] == targetId);
    if (!exists) return;
    _didNavigateToInitialMessage = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToMessageId(targetId);
    });
  }

  // ── Reaction handlers ─────────────────────────────────────────────────────

  /// Long-press on a message bubble → opens the reaction picker.
  Future<void> _onMessageLongPress(
    Map<String, dynamic> msg,
    Rect bubbleRect,
  ) async {
    final messageId = msg['id'] as String?;
    if (messageId == null || messageId.startsWith('temp-')) return;
    if (_pendingReactionMessageIds.contains(messageId)) return;

    final myId = KaSpotService.userId;
    final myExisting = (_reactions[messageId] ?? []).firstWhere(
      (r) => r['user_id'] == myId,
      orElse: () => <String, dynamic>{},
    );
    final currentEmoji = myExisting.isEmpty
        ? null
        : myExisting['emoji'] as String?;

    final result = await ReactionPickerOverlay.show(
      context: context,
      userId: myId,
      bubbleRect: bubbleRect,
      isMe: msg['sender_id'] == myId,
      currentEmoji: currentEmoji,
    );

    // null  → dismissed without selection
    // ''    → user tapped their current emoji (remove)
    // emoji → add/replace
    if (result == null || !mounted) return;

    if (result.isEmpty) {
      await _removeReaction(messageId);
    } else {
      await _applyReaction(messageId, result, myId);
    }
  }

  /// Tapping an existing reaction chip: toggle (remove if own, otherwise react).
  Future<void> _onReactionChipTap(String messageId, String emoji) async {
    if (_pendingReactionMessageIds.contains(messageId)) return;
    final myId = KaSpotService.userId;
    final myReaction = (_reactions[messageId] ?? []).firstWhere(
      (r) => r['user_id'] == myId,
      orElse: () => <String, dynamic>{},
    );

    if (myReaction.isNotEmpty && myReaction['emoji'] == emoji) {
      // Tap own current reaction → remove.
      await _removeReaction(messageId);
    } else {
      // Tap another emoji chip or a chip the user hasn't reacted with.
      await _applyReaction(messageId, emoji, myId);
    }
  }

  Future<void> _applyReaction(
    String messageId,
    String emoji,
    String myId,
  ) async {
    _pendingReactionMessageIds.add(messageId);

    // Optimistic update.
    final prevReactions = Map<String, List<Map<String, dynamic>>>.from(
      _reactions.map((k, v) => MapEntry(k, List<Map<String, dynamic>>.from(v))),
    );

    setState(() {
      final list = _reactions.putIfAbsent(messageId, () => []);
      list.removeWhere((r) => r['user_id'] == myId);
      list.add({
        'id':
            'opt-${DateTime.now().millisecondsSinceEpoch}-${messageId.hashCode}',
        'message_id': messageId,
        'user_id': myId,
        'emoji': emoji,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    });

    try {
      await KaSpotService.upsertReaction(messageId, emoji);
      // Reconcile with confirmed server state.
      final confirmed = await KaSpotService.getReactionsForMessages([
        messageId,
      ]);
      if (mounted) {
        setState(() {
          if (confirmed.containsKey(messageId)) {
            _reactions[messageId] = confirmed[messageId]!;
          }
        });
      }
    } catch (e) {
      // Roll back.
      if (mounted) {
        setState(() => _reactions = prevReactions);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not save reaction. Please try again.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      _pendingReactionMessageIds.remove(messageId);
    }
  }

  Future<void> _removeReaction(String messageId) async {
    _pendingReactionMessageIds.add(messageId);
    final myId = KaSpotService.userId;

    // Optimistic removal.
    final prevReactions = Map<String, List<Map<String, dynamic>>>.from(
      _reactions.map((k, v) => MapEntry(k, List<Map<String, dynamic>>.from(v))),
    );

    setState(() {
      _reactions[messageId]?.removeWhere((r) => r['user_id'] == myId);
    });

    try {
      await KaSpotService.removeReaction(messageId);
      // Reconcile.
      final confirmed = await KaSpotService.getReactionsForMessages([
        messageId,
      ]);
      if (mounted) {
        setState(() {
          _reactions[messageId] = confirmed[messageId] ?? [];
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _reactions = prevReactions);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not remove reaction. Please try again.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      _pendingReactionMessageIds.remove(messageId);
    }
  }

  // ─────────────────────────────────────────────────────────────────────────

  String _formatTime(dynamic rawDate) {
    if (rawDate == null) return '';
    try {
      final dt = DateTime.parse(rawDate.toString()).toLocal();
      final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
      final minute = dt.minute.toString().padLeft(2, '0');
      final period = dt.hour >= 12 ? 'PM' : 'AM';
      return '$hour:$minute $period';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final myId = KaSpotService.userId;
    // What the chat body actually has to work with, after the keyboard and the
    // system bars. Short viewports (a landscape phone with the keyboard open)
    // cannot fit the whole fixed chrome, so it is trimmed responsively below.
    final media = MediaQuery.of(context);
    final usableHeight =
        media.size.height - media.viewInsets.bottom - media.padding.vertical;
    // The app bar is already spent before the chat column lays out, so what the
    // feed, the shortcut row and the composer really share is the body below
    // it. Measuring against the body (not the window) is what keeps a 320×480
    // phone with the keyboard open from running out of column.
    final bodyHeight = usableHeight > kToolbarHeight
        ? usableHeight - kToolbarHeight
        : 0.0;
    final shortViewport = bodyHeight < _kShortViewportHeight;

    // Messenger-style composer: one line at rest, growing as the draft wraps,
    // but never past [_kComposerMaxLines] and never more than
    // [_kComposerHeightShare] of the body. The line height follows the platform
    // text scale, so large accessibility fonts get fewer lines instead of a
    // clipped field.
    final bodyTextStyle = Theme.of(context).textTheme.bodyLarge;
    final composerLineHeight =
        MediaQuery.textScalerOf(context).scale(bodyTextStyle?.fontSize ?? 16) *
        1.25;
    int composerMaxLines =
        (bodyHeight * _kComposerHeightShare / composerLineHeight).floor();
    if (composerMaxLines < 1) composerMaxLines = 1;
    if (composerMaxLines > _kComposerMaxLines) {
      composerMaxLines = _kComposerMaxLines;
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            KaSpotAvatar(
              name: widget.displayName,
              avatarUrl: widget.avatarUrl,
              size: 38,
              isCircle: true,
              showBorder: true,
              borderColor: const Color(0xFF2563EB),
              borderWidth: 1.5,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.theyShareWithMe
                              ? const Color(0xFF10B981)
                              : const Color(0xFF94A3B8),
                        ),
                      ),
                      const SizedBox(width: 5),
                      // Flexible: a narrow phone or a large text scale must
                      // shorten the subtitle, never overflow the title row.
                      Flexible(
                        child: Text(
                          widget.theyShareWithMe
                              ? 'Sharing active · In circle'
                              : 'Circle member',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: widget.theyShareWithMe
                                ? const Color(0xFF059669)
                                : const Color(0xFF64748B),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh chat',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _loadMessages(),
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. Message Bubble Feed
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      // The empty conversation shares this Stack, so the
                      // peer's dots stay visible before the first message.
                      if (_messages.isEmpty)
                        Positioned.fill(child: _buildEmptyState()),

                      // The typing clearance belongs to the list itself: the
                      // dots float over the feed instead of taking a row in
                      // the chat Column, so an active indicator never shrinks
                      // the conversation. Only this builder listens to the
                      // typing flag, so bubbles are not rebuilt per event.
                      if (_messages.isNotEmpty)
                        ValueListenableBuilder<bool>(
                          valueListenable: _typing!.peerTyping,
                          builder: (context, peerTyping, _) => ListView.builder(
                            controller: _scrollController,
                            reverse: true,
                            padding: EdgeInsets.fromLTRB(
                              16,
                              16,
                              16,
                              12.0 +
                                  (peerTyping && _isPinnedToBottom
                                      ? _kTypingClearance
                                      : 0),
                            ),
                            itemCount: _messages.length,
                            itemBuilder: (context, index) {
                              final msg = _messages[index];
                              final isMe = msg['sender_id'] == myId;
                              return SwipeToReplyWidget(
                                onReply: () => _initiateReply(msg),
                                child: _buildMessageItem(msg, isMe, myId),
                              );
                            },
                          ),
                        ),

                      // Floating Jump to Latest pill
                      if (_showScrollToBottom)
                        Positioned(
                          bottom: 12,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: GestureDetector(
                              onTap: () {
                                _scrollController.animateTo(
                                  0.0,
                                  duration: const Duration(milliseconds: 250),
                                  curve: Curves.easeOut,
                                );
                                setState(() {
                                  _showScrollToBottom = false;
                                  _newIncomingCount = 0;
                                });
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E60AA),
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Color(0x33000000),
                                      blurRadius: 8,
                                      offset: Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.arrow_downward_rounded,
                                      size: 16,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      _newIncomingCount > 0
                                          ? '$_newIncomingCount new message${_newIncomingCount > 1 ? 's' : ''}'
                                          : 'Latest messages',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),

                      // Typing indicator: three animated dots only, no text,
                      // floating over the bottom of the feed right above the
                      // composer. It takes no row in the chat Column, so it
                      // never costs the conversation vertical space, and
                      // IgnorePointer keeps every bubble, reaction chip and
                      // pill underneath it fully tappable.
                      if (_typing != null && _isPinnedToBottom)
                        Positioned(
                          left: 0,
                          bottom: 0,
                          child: IgnorePointer(
                            child: TypingIndicatorBar(
                              peerTyping: _typing!.peerTyping,
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),

          // 2. Reply Composer Preview Banner
          if (_replyingToMessage != null) _buildReplyComposerBar(myId),

          // 3. Quick Status Alerts — optional shortcuts. On a genuinely short
          // viewport the fixed chrome cannot all fit and still leave the feed
          // readable, so this row steps aside before the feed or the composer
          // does: nothing is scaled down and both stay fully usable.
          if (!shortViewport)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(top: BorderSide(color: Color(0xFFF1F5F9))),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: _quickAlerts.map((preset) {
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(
                          preset,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1E60AA),
                          ),
                        ),
                        backgroundColor: const Color(0xFFEFF6FF),
                        side: const BorderSide(
                          color: Color(0xFFBFDBFE),
                          width: 1,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        onPressed: _sending ? null : () => _sendMessage(preset),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),

          // 4. Input Text Composer
          SafeArea(
            top: false,
            child: Container(
              padding: shortViewport
                  ? const EdgeInsets.fromLTRB(12, 4, 12, 4)
                  : const EdgeInsets.fromLTRB(16, 6, 16, 12),
              color: Colors.white,
              child: Row(
                // The send control rides the bottom of the box, so it stays put
                // while the field grows upward instead of drifting mid-column.
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: TextField(
                        controller: _textController,
                        focusNode: _focusNode,
                        // Grows with the draft: wraps long text onto readable
                        // lines instead of running off horizontally, and scrolls
                        // inside the field once the line cap is reached.
                        minLines: 1,
                        maxLines: composerMaxLines,
                        keyboardType: TextInputType.multiline,
                        // Return inserts a line break; the send button remains
                        // the only way to send, so a stray newline can never
                        // submit an unfinished message.
                        textInputAction: TextInputAction.newline,
                        maxLength: 500,
                        textCapitalization: TextCapitalization.sentences,
                        buildCounter:
                            (
                              context, {
                              required currentLength,
                              required isFocused,
                              maxLength,
                            }) {
                              if (maxLength == null ||
                                  currentLength < maxLength - 80) {
                                return null;
                              }
                              return Text(
                                '$currentLength/$maxLength',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: currentLength >= maxLength
                                      ? const Color(0xFFDC2626)
                                      : const Color(0xFF94A3B8),
                                ),
                              );
                            },
                        decoration: InputDecoration(
                          hintText: _replyingToMessage != null
                              ? 'Reply to ${_replyingToMessage!['sender_id'] == myId ? 'yourself' : widget.displayName}...'
                              : 'Message ${widget.displayName}...',
                          hintStyle: const TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 14,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 11,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Material(
                    color: const Color(0xFF1E60AA),
                    shape: const CircleBorder(),
                    child: InkWell(
                      onTap: _sending ? null : () => _sendMessage(),
                      customBorder: const CircleBorder(),
                      child: Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        child: _sending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(
                                Icons.send_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Message item builder ──────────────────────────────────────────────────

  /// Horizontal padding inside a bubble. Shared by the bubble decoration and
  /// the reply-preview maths so the two can never drift apart.
  static const double _kBubblePaddingH = 12;

  /// Longest a bubble may get.
  ///
  /// Computed from the row's own **content** width — which already excludes the
  /// chat's horizontal padding, and for incoming messages the avatar as well —
  /// instead of the previous raw fraction of the *screen* width. It is a
  /// maximum only; the bubble itself stays content-sized.
  double _maxBubbleWidth(double contentWidth) {
    final safe = contentWidth.isFinite
        ? contentWidth
        : MediaQuery.sizeOf(context).width - 32;
    return (safe * 0.8).clamp(180.0, 560.0);
  }

  Widget _buildMessageItem(Map<String, dynamic> msg, bool isMe, String myId) {
    final messageId = msg['id'] as String? ?? '';
    final content = msg['content'] as String? ?? '';
    final timeStr = _formatTime(msg['created_at']);
    final replyToId = msg['reply_to_message_id'] as String?;
    final reactions = _reactions[messageId] ?? [];
    final hasReactions = reactions.isNotEmpty;

    // The badge has to float over the bubble's bottom edge *and* stay tappable.
    // A Positioned child is only hit-testable while it lies inside its Stack's
    // own box (RenderBox.hitTest descends into children solely when
    // size.contains(position)), and now that bubbles shrink-wrap their content a
    // multi-emoji badge can easily be wider than a two-word bubble. So the badge
    // is a *flow* child of a Column inside the Stack: the Stack then sizes to the
    // wider of bubble/badge (nothing can land outside the box, nothing is
    // clipped), and a small upward lift reproduces the exact previous floating
    // position instead of relying on Clip.none plus a reserved padding strip.
    const badgeLift = 8.0;

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: LayoutBuilder(
        builder: (context, rowConstraints) {
          final maxBubble = _maxBubbleWidth(rowConstraints.maxWidth);
          return Row(
            mainAxisAlignment: isMe
                ? MainAxisAlignment.end
                : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!isMe) ...[
                KaSpotAvatar(
                  name: widget.displayName,
                  avatarUrl: widget.avatarUrl,
                  size: 26,
                  isCircle: true,
                ),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: isMe
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start,
                      children: [
                        // ── Bubble ───────────────────────────────────────────
                        _MessageBubble(
                          key: ValueKey('bubble-$messageId'),
                          messageId: messageId,
                          isMe: isMe,
                          content: content,
                          timeStr: timeStr,
                          replyToId: replyToId,
                          isPending: msg['_pending'] == true,
                          readAt: msg['read_at'],
                          onLongPress: (rect) => _onMessageLongPress(msg, rect),
                          buildQuotedPreview: replyToId != null
                              ? () => _buildQuotedReplyPreview(
                                  replyToId,
                                  isMe,
                                  maxBubble,
                                )
                              : null,
                          buildReadReceipt: () => _buildReadReceiptStatus(msg),
                          maxWidth: maxBubble,
                          horizontalPadding: _kBubblePaddingH,
                        ),

                        // ── Floating reaction badge ──────────────────────────
                        if (hasReactions)
                          Transform.translate(
                            offset: const Offset(0, -badgeLift),
                            child: Padding(
                              padding: EdgeInsets.only(
                                left: isMe ? 0 : 8,
                                right: isMe ? 8 : 0,
                              ),
                              child: MessageReactionBadge(
                                reactions: reactions,
                                myUserId: myId,
                                isMe: isMe,
                                onTap: (emoji) =>
                                    _onReactionChipTap(messageId, emoji),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // ── Existing helper widgets ───────────────────────────────────────────────

  Widget _buildReadReceiptStatus(Map<String, dynamic> msg) {
    if (msg['_pending'] == true) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 9,
            height: 9,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: Color(0xFFBAE6FD),
            ),
          ),
          SizedBox(width: 3),
          Text(
            'Sending',
            style: TextStyle(
              fontSize: 9.5,
              color: Color(0xFFBAE6FD),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
    }

    final readAt = msg['read_at'];
    if (readAt != null) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.done_all_rounded, size: 12, color: Color(0xFF38BDF8)),
          SizedBox(width: 2),
          Text(
            'Seen',
            style: TextStyle(
              fontSize: 9.5,
              color: Color(0xFF38BDF8),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      );
    }

    return const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_rounded, size: 12, color: Color(0xFFBAE6FD)),
        SizedBox(width: 2),
        Text(
          'Sent',
          style: TextStyle(
            fontSize: 9.5,
            color: Color(0xFFBAE6FD),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildQuotedReplyPreview(
    String replyToId,
    bool isMe,
    double maxBubbleWidth,
  ) {
    final original = _messages.firstWhere(
      (m) => m['id'] == replyToId,
      orElse: () => <String, dynamic>{},
    );

    final myId = KaSpotService.userId;
    final originalSenderId = original['sender_id'] as String?;
    final senderName = originalSenderId == null
        ? 'Message'
        : (originalSenderId == myId ? 'You' : widget.displayName);
    final snippet =
        original['content'] as String? ?? 'Original message unavailable';

    // A quoted excerpt must never be what dictates the bubble's width. A
    // wrapping Text claims every pixel it is offered, so leaving this preview
    // unconstrained pinned a one-word reply to the full maximum width. Bounding
    // it well below the bubble's own maximum keeps short replies compact while
    // long quotes still truncate gracefully over two lines.
    final previewMax = ((maxBubbleWidth - _kBubblePaddingH * 2) * 0.62).clamp(
      110.0,
      220.0,
    );

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: previewMax),
      child: GestureDetector(
        onTap: () => _scrollToMessageId(replyToId),
        child: Container(
          padding: const EdgeInsets.fromLTRB(7, 4, 8, 4),
          decoration: BoxDecoration(
            color: isMe
                ? Colors.white.withValues(alpha: 0.18)
                : const Color(0xFFF1F5F9),
            borderRadius: BorderRadius.circular(6),
            border: Border(
              left: BorderSide(
                color: isMe ? const Color(0xFF93C5FD) : const Color(0xFF1E60AA),
                width: 3,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.reply_rounded,
                    size: 11,
                    color: isMe
                        ? const Color(0xFFBAE6FD)
                        : const Color(0xFF1E60AA),
                  ),
                  const SizedBox(width: 4),
                  // Long sender names must not push the preview (or the whole
                  // bubble) past its width.
                  Flexible(
                    child: Text(
                      senderName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: isMe ? Colors.white : const Color(0xFF1E60AA),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 1),
              Text(
                snippet,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.25,
                  color: isMe
                      ? const Color(0xFFF1F5F9)
                      : const Color(0xFF475569),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReplyComposerBar(String myId) {
    final senderId = _replyingToMessage!['sender_id'] as String?;
    final senderName = senderId == myId ? 'yourself' : widget.displayName;
    final snippet = _replyingToMessage!['content'] as String? ?? '';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFFF1F5F9),
        border: Border(
          top: BorderSide(color: Color(0xFFE2E8F0)),
          bottom: BorderSide(color: Color(0xFFE2E8F0)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 3.5,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFF1E60AA),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.reply_rounded, size: 20, color: Color(0xFF1E60AA)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying to $senderName',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1E60AA),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  snippet,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.close_rounded,
              size: 18,
              color: Color(0xFF64748B),
            ),
            onPressed: _cancelReply,
            tooltip: 'Cancel reply',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    // Centered when there is room, scrollable when there is not. A rigid Center
    // would pass this block's intrinsic height straight to the chat Column,
    // which overflows the screen on short viewports (landscape phones, large
    // text scale) even before the keyboard appears.
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentMinHeight =
            constraints.maxHeight.isFinite && constraints.maxHeight > 64
            ? constraints.maxHeight - 64
            : 0.0;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: contentMinHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: const BoxDecoration(
                    color: Color(0xFFEFF6FF),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.chat_bubble_outline_rounded,
                    color: Color(0xFF1E60AA),
                    size: 36,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Chat with ${widget.displayName}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Send quick messages or swipe right on any message to reply directly.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: Color(0xFF64748B),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// =============================================================================
// _MessageBubble — extracted widget so long-press can capture its RenderBox
// =============================================================================

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.messageId,
    required this.isMe,
    required this.content,
    required this.timeStr,
    this.replyToId,
    required this.isPending,
    required this.readAt,
    required this.onLongPress,
    this.buildQuotedPreview,
    required this.buildReadReceipt,
    required this.maxWidth,
    required this.horizontalPadding,
  });

  final String messageId;
  final bool isMe;
  final String content;
  final String timeStr;
  final String? replyToId;
  final bool isPending;
  final dynamic readAt;
  final void Function(Rect bubbleRect) onLongPress;
  final Widget Function()? buildQuotedPreview;
  final Widget Function() buildReadReceipt;

  /// Hard ceiling for this bubble, supplied by the message row so it can be
  /// derived from the real content width. Never a fixed bubble width.
  final double maxWidth;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    return Builder(
      builder: (ctx) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: () {
            final renderBox = ctx.findRenderObject() as RenderBox?;
            if (renderBox == null) return;
            final offset = renderBox.localToGlobal(Offset.zero);
            final rect = offset & renderBox.size;
            onLongPress(rect);
          },
          child: Container(
            // A maximum only. The Container shrink-wraps to its content, so a
            // short message stays short instead of filling the row.
            constraints: BoxConstraints(maxWidth: maxWidth),
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: 9,
            ),
            decoration: BoxDecoration(
              color: isMe ? const Color(0xFF1E60AA) : Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(18),
                topRight: const Radius.circular(18),
                bottomLeft: Radius.circular(isMe ? 18 : 4),
                bottomRight: Radius.circular(isMe ? 4 : 18),
              ),
              border: isMe ? null : Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x08000000),
                  blurRadius: 4,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: isMe
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (buildQuotedPreview != null) ...[
                  buildQuotedPreview!(),
                  const SizedBox(height: 5),
                ],
                Text(
                  content,
                  style: TextStyle(
                    fontSize: 14.5,
                    height: 1.35,
                    color: isMe ? Colors.white : const Color(0xFF0F172A),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                // Compact metadata: the timestamp and delivery status stay
                // visible (nothing is dropped to save space) but are sized so a
                // five-character message is not stretched to fit them.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (timeStr.isNotEmpty)
                      Text(
                        timeStr,
                        style: TextStyle(
                          fontSize: 9.5,
                          color: isMe
                              ? const Color(0xFFBAE6FD)
                              : const Color(0xFF94A3B8),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    if (isMe) ...[const SizedBox(width: 4), buildReadReceipt()],
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// =============================================================================
// SwipeToReplyWidget — unchanged from original implementation
// =============================================================================

/// A lightweight, gesture-arena safe swipe-to-reply widget.
/// Only moves horizontally on positive (rightward) swipes and does not claim
/// vertical scrolls, preserving ordinary vertical list physics.
class SwipeToReplyWidget extends StatefulWidget {
  const SwipeToReplyWidget({
    super.key,
    required this.child,
    required this.onReply,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onReply;
  final bool enabled;

  @override
  State<SwipeToReplyWidget> createState() => _SwipeToReplyWidgetState();
}

class _SwipeToReplyWidgetState extends State<SwipeToReplyWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _animation;
  double _dragOffset = 0.0;
  static const double _threshold = 44.0;
  static const double _maxDrag = 68.0;
  bool _triggered = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _animation = Tween<double>(
      begin: 0.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.addListener(() {
      setState(() {
        _dragOffset = _animation.value;
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (!widget.enabled) return;
    final delta = details.primaryDelta ?? 0.0;
    final newOffset = (_dragOffset + delta).clamp(0.0, _maxDrag);
    if (newOffset != _dragOffset) {
      setState(() {
        _dragOffset = newOffset;
      });
      if (!_triggered && _dragOffset >= _threshold) {
        _triggered = true;
        Feedback.forTap(context);
      } else if (_triggered && _dragOffset < _threshold) {
        _triggered = false;
      }
    }
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (!widget.enabled) return;
    if (_triggered) widget.onReply();
    _triggered = false;
    _animation = Tween<double>(
      begin: _dragOffset,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.forward(from: 0.0);
  }

  void _onHorizontalDragCancel() {
    _triggered = false;
    _animation = Tween<double>(
      begin: _dragOffset,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.forward(from: 0.0);
  }

  @override
  Widget build(BuildContext context) {
    final progress = (_dragOffset / _threshold).clamp(0.0, 1.0);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragUpdate: _onHorizontalDragUpdate,
      onHorizontalDragEnd: _onHorizontalDragEnd,
      onHorizontalDragCancel: _onHorizontalDragCancel,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.centerLeft,
        children: [
          if (_dragOffset > 2)
            Positioned(
              left: 4,
              child: Opacity(
                opacity: progress,
                child: Transform.scale(
                  scale: 0.6 + (progress * 0.4),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: progress >= 1.0
                          ? const Color(0xFF1E60AA)
                          : const Color(0xFFEFF6FF),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.reply_rounded,
                      size: 18,
                      color: progress >= 1.0
                          ? Colors.white
                          : const Color(0xFF1E60AA),
                    ),
                  ),
                ),
              ),
            ),
          Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
