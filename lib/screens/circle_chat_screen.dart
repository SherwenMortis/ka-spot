import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/in_app_notification_service.dart';
import '../services/kaspot_service.dart';
import '../services/push_notification_service.dart';
import '../widgets/kaspot_avatar.dart';

class CircleChatScreen extends StatefulWidget {
  const CircleChatScreen({
    super.key,
    required this.otherId,
    required this.displayName,
    this.avatarUrl,
    this.theyShareWithMe = false,
  });

  final String otherId;
  final String displayName;
  final String? avatarUrl;
  final bool theyShareWithMe;

  @override
  State<CircleChatScreen> createState() => _CircleChatScreenState();
}

class _CircleChatScreenState extends State<CircleChatScreen> {
  final _textController = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();

  /// Messages stored with newest at index 0 (matches reversed ListView).
  List<Map<String, dynamic>> _messages = [];
  bool _loading = true;
  bool _sending = false;
  RealtimeChannel? _channel;

  /// Active message being replied to (if any).
  Map<String, dynamic>? _replyingToMessage;

  /// Controls display of the floating "↓ New messages" button when scrolled up.
  bool _showScrollToBottom = false;
  int _newIncomingCount = 0;

  static const List<String> _quickAlerts = [
    "🚶 I'm away right now",
    "🚗 Heading out now",
    "📍 Arrived safely!",
    "⏱️ Back in 15 mins",
    "🔔 Please check on me",
  ];

  @override
  void initState() {
    super.initState();
    KaSpotService.activeChatUserId = widget.otherId;
    _scrollController.addListener(_onScroll);
    _loadMessages();
    _subscribeRealtime();

    // Mark messages as read and clear related notifications on open.
    // Deferred past the current frame so that the synchronous ValueNotifier
    // mutation inside markMessagesRead does not fire during widget build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(KaSpotService.markMessagesRead(widget.otherId));
      PushNotificationService.clearNotificationsForSender(widget.otherId);
      InAppNotificationService.dismissForSender(widget.otherId);
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.offset <= 40 && _showScrollToBottom) {
      setState(() {
        _showScrollToBottom = false;
        _newIncomingCount = 0;
      });
    }
  }

  /// Subscribe to Supabase Realtime for instant incoming messages and read receipts.
  void _subscribeRealtime() {
    if (!KaSpotService.isConfigured) return;
    final myId = KaSpotService.userId;

    _channel = KaSpotService.client!
        .channel('chat-${myId}_${widget.otherId}')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'circle_messages',
        callback: (payload) {
          final newRecord = payload.newRecord;
          final senderId = newRecord['sender_id'] as String?;
          final recipientId = newRecord['recipient_id'] as String?;

          final isRelevant = (senderId == myId && recipientId == widget.otherId) ||
              (senderId == widget.otherId && recipientId == myId);
          if (!isRelevant) return;

          // If the message is incoming from the other person while the chat is open:
          if (senderId == widget.otherId) {
            unawaited(KaSpotService.markMessagesRead(widget.otherId));
            unawaited(PushNotificationService.clearNotificationsForSender(widget.otherId));
            InAppNotificationService.dismissForSender(widget.otherId);
          }

          // If scrolled up into older messages, signal unread incoming messages without forcing drag:
          if (_scrollController.hasClients && _scrollController.offset > 80) {
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
      ..subscribe();
  }

  @override
  void dispose() {
    if (KaSpotService.activeChatUserId == widget.otherId) {
      KaSpotService.activeChatUserId = null;
    }
    if (_channel != null && KaSpotService.isConfigured) {
      unawaited(KaSpotService.client!.removeChannel(_channel!));
    }
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadMessages({bool silent = false}) async {
    // Capture the conversation this load was started for.  If the widget is
    // recycled for a different otherId before the await returns, the stale
    // result must be discarded rather than overwriting the current conversation.
    final expectedOtherId = widget.otherId;
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final msgs = await KaSpotService.getCircleMessages(expectedOtherId);
      if (mounted && widget.otherId == expectedOtherId) {
        setState(() {
          // Invert chronological list so index 0 is newest (matches ListView reverse: true).
          // On a silent refresh (called after send or on incoming Realtime events) all
          // pending optimistic entries are already confirmed server-side, so drop them
          // entirely and replace with the authoritative result.  On a non-silent initial
          // load there are no pending entries yet, so the behaviour is the same.
          final authoritative = msgs.reversed.toList();
          _messages = authoritative;
          _loading = false;
        });

        // Ensure newly arrived messages are marked as read while chat is open
        KaSpotService.markMessagesRead(widget.otherId);
        PushNotificationService.clearNotificationsForSender(widget.otherId);
        InAppNotificationService.dismissForSender(widget.otherId);
      }
    } catch (_) {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  Future<void> _sendMessage([String? presetText]) async {
    final text = (presetText ?? _textController.text).trim();
    if (text.isEmpty || _sending) return;

    final myId = KaSpotService.userId;
    final replyTo = _replyingToMessage;
    final replyToId = replyTo?['id'] as String?;

    if (presetText == null) {
      _textController.clear();
    }

    setState(() {
      _sending = true;
      _replyingToMessage = null;
      // Optimistic pending message added at index 0 (bottom of reversed list)
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

    // Auto-scroll to latest message if currently scrolled up
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
    setState(() {
      _replyingToMessage = message;
    });
    _focusNode.requestFocus();
  }

  void _cancelReply() {
    setState(() {
      _replyingToMessage = null;
    });
  }

  void _scrollToMessageId(String messageId) {
    final index = _messages.indexWhere((m) => m['id'] == messageId);
    if (index != -1 && _scrollController.hasClients) {
      // In a reversed list, higher index means older message scrolled further up.
      final targetOffset = (index * 72.0).clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

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
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.theyShareWithMe ? const Color(0xFF10B981) : const Color(0xFF94A3B8),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        widget.theyShareWithMe ? 'Sharing active · In circle' : 'Circle member',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: widget.theyShareWithMe ? const Color(0xFF059669) : const Color(0xFF64748B),
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
                : _messages.isEmpty
                    ? _buildEmptyState()
                    : Stack(
                        children: [
                          ListView.builder(
                            controller: _scrollController,
                            reverse: true,
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                            itemCount: _messages.length,
                            itemBuilder: (context, index) {
                              final msg = _messages[index];
                              final isMe = msg['sender_id'] == myId;
                              final content = msg['content'] as String? ?? '';
                              final timeStr = _formatTime(msg['created_at']);
                              final replyToId = msg['reply_to_message_id'] as String?;

                              return SwipeToReplyWidget(
                                onReply: () => _initiateReply(msg),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 4),
                                  child: Row(
                                    mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
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
                                        child: Container(
                                          constraints: BoxConstraints(
                                            maxWidth: MediaQuery.of(context).size.width * 0.75,
                                          ),
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
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
                                              BoxShadow(color: Color(0x08000000), blurRadius: 4, offset: Offset(0, 2)),
                                            ],
                                          ),
                                          child: Column(
                                            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                            children: [
                                              // Quoted Message Banner (if this message is a reply)
                                              if (replyToId != null) ...[
                                                _buildQuotedReplyPreview(replyToId, isMe),
                                                const SizedBox(height: 6),
                                              ],

                                              // Message Content Text
                                              Text(
                                                content,
                                                style: TextStyle(
                                                  fontSize: 14.5,
                                                  height: 1.35,
                                                  color: isMe ? Colors.white : const Color(0xFF0F172A),
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),

                                              // Metadata & Read Receipt Status
                                              const SizedBox(height: 3),
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  if (timeStr.isNotEmpty)
                                                    Text(
                                                      timeStr,
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        color: isMe ? const Color(0xFFBAE6FD) : const Color(0xFF94A3B8),
                                                        fontWeight: FontWeight.w600,
                                                      ),
                                                    ),
                                                  // Read receipt indicators for outgoing messages
                                                  if (isMe) ...[
                                                    const SizedBox(width: 5),
                                                    _buildReadReceiptStatus(msg),
                                                  ],
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),

                          // Floating Jump to Latest / New Messages pill button
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
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1E60AA),
                                      borderRadius: BorderRadius.circular(20),
                                      boxShadow: const [
                                        BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 3)),
                                      ],
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.arrow_downward_rounded, size: 16, color: Colors.white),
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
                        ],
                      ),
          ),

          // 2. Reply Composer Preview Banner
          if (_replyingToMessage != null) _buildReplyComposerBar(myId),

          // 3. Quick Status Alerts (e.g. "I'm away right now")
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
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF1E60AA)),
                      ),
                      backgroundColor: const Color(0xFFEFF6FF),
                      side: const BorderSide(color: Color(0xFFBFDBFE), width: 1),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
              color: Colors.white,
              child: Row(
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
                        maxLength: 500,
                        textCapitalization: TextCapitalization.sentences,
                        buildCounter: (context, {required currentLength, required isFocused, maxLength}) {
                          if (maxLength == null || currentLength < maxLength - 80) return null;
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
                          hintStyle: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        onSubmitted: (_) => _sendMessage(),
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
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
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

  /// Builds Messenger-style read receipt status indicator for an outgoing message bubble.
  Widget _buildReadReceiptStatus(Map<String, dynamic> msg) {
    if (msg['_pending'] == true) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFFBAE6FD)),
          ),
          SizedBox(width: 3),
          Text(
            'Sending',
            style: TextStyle(fontSize: 10, color: Color(0xFFBAE6FD), fontWeight: FontWeight.w600),
          ),
        ],
      );
    }

    final readAt = msg['read_at'];
    if (readAt != null) {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.done_all_rounded, size: 13, color: Color(0xFF38BDF8)),
          SizedBox(width: 2),
          Text(
            'Seen',
            style: TextStyle(
              fontSize: 10,
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
        Icon(Icons.check_rounded, size: 13, color: Color(0xFFBAE6FD)),
        SizedBox(width: 2),
        Text(
          'Sent',
          style: TextStyle(
            fontSize: 10,
            color: Color(0xFFBAE6FD),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  /// Builds a quoted message preview inside a message bubble.
  Widget _buildQuotedReplyPreview(String replyToId, bool isMe) {
    final original = _messages.firstWhere(
      (m) => m['id'] == replyToId,
      orElse: () => <String, dynamic>{},
    );

    final myId = KaSpotService.userId;
    final originalSenderId = original['sender_id'] as String?;
    final senderName = originalSenderId == null
        ? 'Message'
        : (originalSenderId == myId ? 'You' : widget.displayName);
    final snippet = original['content'] as String? ?? 'Original message unavailable';

    return GestureDetector(
      onTap: () => _scrollToMessageId(replyToId),
      child: Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: BoxDecoration(
          color: isMe ? Colors.white.withValues(alpha: 0.18) : const Color(0xFFF1F5F9),
          borderRadius: BorderRadius.circular(8),
          border: Border(
            left: BorderSide(
              color: isMe ? const Color(0xFF93C5FD) : const Color(0xFF1E60AA),
              width: 3.5,
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
                  size: 12,
                  color: isMe ? const Color(0xFFBAE6FD) : const Color(0xFF1E60AA),
                ),
                const SizedBox(width: 4),
                Text(
                  senderName,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: isMe ? Colors.white : const Color(0xFF1E60AA),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              snippet,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: isMe ? const Color(0xFFF1F5F9) : const Color(0xFF475569),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Builds the reply preview composer bar displayed above the input field.
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
            icon: const Icon(Icons.close_rounded, size: 18, color: Color(0xFF64748B)),
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
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: const BoxDecoration(
                color: Color(0xFFEFF6FF),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.chat_bubble_outline_rounded, color: Color(0xFF1E60AA), size: 36),
            ),
            const SizedBox(height: 16),
            Text(
              'Chat with ${widget.displayName}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
            ),
            const SizedBox(height: 8),
            const Text(
              'Send quick messages or swipe right on any message to reply directly.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13.5, color: Color(0xFF64748B), height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

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
    _animation = Tween<double>(begin: 0.0, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
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
    if (_triggered) {
      widget.onReply();
    }
    _triggered = false;
    _animation = Tween<double>(begin: _dragOffset, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _controller.forward(from: 0.0);
  }

  void _onHorizontalDragCancel() {
    _triggered = false;
    _animation = Tween<double>(begin: _dragOffset, end: 0.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
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
          // Reply icon indicator revealed behind bubble while swiping
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
                      color: progress >= 1.0 ? const Color(0xFF1E60AA) : const Color(0xFFEFF6FF),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.reply_rounded,
                      size: 18,
                      color: progress >= 1.0 ? Colors.white : const Color(0xFF1E60AA),
                    ),
                  ),
                ),
              ),
            ),
          // Horizontally translated message bubble
          Transform.translate(
            offset: Offset(_dragOffset, 0),
            child: widget.child,
          ),
        ],
      ),
    );
  }
}
