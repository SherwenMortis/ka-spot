import 'package:flutter/material.dart';

/// Floating reaction badge displayed at the bottom edge of a message bubble.
///
/// Render as an overlay above the bubble using a [Stack] + [Positioned] so it
/// does not add height to the message item layout.  The badge is compact:
/// grouped emoji with optional count, aligned to the bubble's side.
///
/// Usage (inside a Stack that also contains the bubble):
/// ```dart
/// Stack(
///   clipBehavior: Clip.none,
///   children: [
///     bubble,
///     if (reactions.isNotEmpty)
///       Positioned(
///         bottom: -12,
///         left/right: 8,
///         child: MessageReactionBadge(...),
///       ),
///   ],
/// )
/// ```
class MessageReactionBadge extends StatelessWidget {
  const MessageReactionBadge({
    super.key,
    required this.reactions,
    required this.myUserId,
    required this.isMe,
    this.onTap,
  });

  final List<Map<String, dynamic>> reactions;
  final String myUserId;
  final bool isMe;
  final void Function(String emoji)? onTap;

  List<({String emoji, int count, bool isMine})> _grouped() {
    final map = <String, ({int count, bool isMine})>{};
    for (final r in reactions) {
      final emoji = r['emoji'] as String? ?? '';
      if (emoji.isEmpty) continue;
      final isMine = r['user_id'] == myUserId;
      final existing = map[emoji];
      if (existing == null) {
        map[emoji] = (count: 1, isMine: isMine);
      } else {
        map[emoji] = (count: existing.count + 1, isMine: existing.isMine || isMine);
      }
    }
    final entries = map.entries.toList()
      ..sort((a, b) {
        if (a.value.isMine && !b.value.isMine) return -1;
        if (!a.value.isMine && b.value.isMine) return 1;
        return b.value.count.compareTo(a.value.count);
      });
    return entries
        .map((e) => (emoji: e.key, count: e.value.count, isMine: e.value.isMine))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    final groups = _grouped();
    // Cap visible chips at 4; show "+N" if there are more.
    const maxVisible = 4;
    final visible = groups.take(maxVisible).toList();
    final overflow = groups.length - maxVisible;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ...visible.map((g) => Padding(
              padding: const EdgeInsets.only(right: 3),
              child: _BadgeChip(
                emoji: g.emoji,
                count: g.count,
                isMine: g.isMine,
                onTap: onTap == null ? null : () => onTap!(g.emoji),
              ),
            )),
        if (overflow > 0)
          _BadgeChip(
            label: '+$overflow',
            isMine: false,
            onTap: null,
          ),
      ],
    );
  }
}

class _BadgeChip extends StatelessWidget {
  const _BadgeChip({
    this.emoji,
    this.label,
    required this.isMine,
    this.count = 1,
    this.onTap,
  });

  final String? emoji;
  final String? label;
  final int count;
  final bool isMine;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bg = isMine ? const Color(0xFFDBEAFE) : Colors.white;
    final border = isMine ? const Color(0xFF93C5FD) : const Color(0xFFDDE3ED);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2.5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: border, width: 1.0),
          boxShadow: const [
            BoxShadow(
                color: Color(0x12000000), blurRadius: 4, offset: Offset(0, 1)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (emoji != null)
              Text(
                emoji!,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.2,
                  decoration: TextDecoration.none,
                ),
              ),
            if (label != null)
              Text(
                label!,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF64748B),
                  decoration: TextDecoration.none,
                ),
              ),
            if (count > 1) ...[
              const SizedBox(width: 2),
              Text(
                '$count',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color:
                      isMine ? const Color(0xFF1E60AA) : const Color(0xFF64748B),
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Keep the old MessageReactionBar name as an alias so existing widget tests
// that look it up by type still compile without changes.
@Deprecated('Use MessageReactionBadge for the floating badge layout.')
typedef MessageReactionBar = MessageReactionBadge;
