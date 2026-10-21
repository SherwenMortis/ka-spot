import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Default and supported emoji sets
// ─────────────────────────────────────────────────────────────────────────────

/// Factory-default quick reactions shown before any customisation.
const List<String> kDefaultQuickReactions = ['❤️', '😂', '👍', '😮', '😢', '🙏'];

/// Supplemental emojis shown in the expanded grid.
const List<String> kExpandedEmojis = [
  '🎉', '🔥', '👀', '💯', '🤔', '😍',
  '😎', '🥰', '🤣', '😅', '👏', '🫶',
  '💪', '🙌', '✨', '💀', '😭', '🤦',
  '🫡', '😤', '❄️', '🌟', '💔', '🥲',
];

/// All supported emojis (defaults + extended).  Picker uses this.
List<String> get kAllSupportedEmojis => [
      ...kDefaultQuickReactions,
      ...kExpandedEmojis,
    ];

/// SharedPreferences key template — keyed by user ID so preferences don't
/// leak across account switches.
String _prefsKey(String userId) => 'kaspot_quick_reactions_v1_$userId';

// ─────────────────────────────────────────────────────────────────────────────
// Quick-reaction preference service
// ─────────────────────────────────────────────────────────────────────────────

/// Loads the current user's saved quick reactions from SharedPreferences.
/// Falls back to [kDefaultQuickReactions] when nothing has been saved yet or
/// the stored data is malformed.
Future<List<String>> loadQuickReactions(String userId) async {
  if (userId.isEmpty) return List.from(kDefaultQuickReactions);
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_prefsKey(userId));
    if (raw == null || raw.length != 6) return List.from(kDefaultQuickReactions);
    // Validate all stored values are supported.
    final supported = kAllSupportedEmojis.toSet();
    if (!raw.every(supported.contains)) return List.from(kDefaultQuickReactions);
    return List.from(raw);
  } catch (_) {
    return List.from(kDefaultQuickReactions);
  }
}

/// Persists the user's custom quick reactions.  No-op when [userId] is empty.
Future<void> saveQuickReactions(String userId, List<String> emojis) async {
  if (userId.isEmpty || emojis.length != 6) return;
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey(userId), emojis);
  } catch (_) {}
}

// ─────────────────────────────────────────────────────────────────────────────
// Public entry-point
// ─────────────────────────────────────────────────────────────────────────────

/// Opens the reaction picker as a full-screen overlay route anchored near the
/// selected message bubble.
///
/// **Normal mode** (default):
/// Returns the selected emoji string, `''` to signal removal of the current
/// reaction, or `null` when the user dismisses without selecting.
///
/// **Customisation mode** is entered from inside the picker and never returns
/// a reaction string — it only updates the user's stored quick reactions.
///
/// Parameters:
/// - [userId]       Current authenticated user ID; used for preference key.
/// - [bubbleRect]   Screen-space Rect of the message bubble (from RenderBox).
/// - [isMe]         Whether the bubble is an outgoing message.
/// - [currentEmoji] The emoji the current user has already applied, if any.
class ReactionPickerOverlay {
  ReactionPickerOverlay._();

  static Future<String?> show({
    required BuildContext context,
    required String userId,
    required Rect bubbleRect,
    required bool isMe,
    String? currentEmoji,
  }) {
    return Navigator.of(context).push<String>(
      _ReactionPickerRoute(
        userId: userId,
        bubbleRect: bubbleRect,
        isMe: isMe,
        currentEmoji: currentEmoji,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Route
// ─────────────────────────────────────────────────────────────────────────────

class _ReactionPickerRoute extends PageRoute<String> {
  _ReactionPickerRoute({
    required this.userId,
    required this.bubbleRect,
    required this.isMe,
    this.currentEmoji,
  }) : super(fullscreenDialog: false);

  final String userId;
  final Rect bubbleRect;
  final bool isMe;
  final String? currentEmoji;

  @override
  Color? get barrierColor => Colors.black12;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss reactions';

  @override
  bool get opaque => false;

  @override
  bool get maintainState => false;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    // Wrap in Material(transparency) so Text widgets resolve DefaultTextStyle
    // from Material and never inherit the route-level underline decoration.
    return Material(
      type: MaterialType.transparency,
      child: _ReactionPickerSheet(
        animation: animation,
        userId: userId,
        bubbleRect: bubbleRect,
        isMe: isMe,
        currentEmoji: currentEmoji,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Picker sheet — state machine
// ─────────────────────────────────────────────────────────────────────────────

enum _PickerMode { quick, expanded, customise }

class _ReactionPickerSheet extends StatefulWidget {
  const _ReactionPickerSheet({
    required this.animation,
    required this.userId,
    required this.bubbleRect,
    required this.isMe,
    this.currentEmoji,
  });

  final Animation<double> animation;
  final String userId;
  final Rect bubbleRect;
  final bool isMe;
  final String? currentEmoji;

  @override
  State<_ReactionPickerSheet> createState() => _ReactionPickerSheetState();
}

class _ReactionPickerSheetState extends State<_ReactionPickerSheet> {
  _PickerMode _mode = _PickerMode.quick;

  // Quick reactions loaded from prefs (may differ from kDefaultQuickReactions).
  // Start with factory defaults so the picker is immediately renderable.
  // Overwrite with the user's saved preferences once they load.
  List<String> _quickReactions = List.from(kDefaultQuickReactions);
  List<String> _editingReactions = List.from(kDefaultQuickReactions);
  int _editingSlot = -1;

  // ── Sizing constants ──────────────────────────────────────────────────────
  static const double _quickPanelH = 60.0;
  static const double _expandedPanelH = 232.0;
  static const double _customisePanelH = 296.0;
  static const double _panelW = 320.0;
  static const double _screenMargin = 10.0;

  @override
  void initState() {
    super.initState();
    _loadPrefs(); // async; updates state if saved prefs differ from defaults
  }

  Future<void> _loadPrefs() async {
    final loaded = await loadQuickReactions(widget.userId);
    if (mounted && loaded != _quickReactions) {
      setState(() {
        _quickReactions = loaded;
        _editingReactions = List.from(loaded);
      });
    }
  }

  // ── Panel geometry ────────────────────────────────────────────────────────

  double get _panelH {
    switch (_mode) {
      case _PickerMode.quick:
        return _quickPanelH;
      case _PickerMode.expanded:
        return _expandedPanelH;
      case _PickerMode.customise:
        return _customisePanelH;
    }
  }

  Offset _panelPosition(Size screen) {
    // Prefer above the bubble; shift below if not enough room.
    double top = widget.bubbleRect.top - _panelH - 10;
    if (top < _screenMargin) {
      top = widget.bubbleRect.bottom + 10;
    }
    // Clamp so it never goes off the bottom.
    if (top + _panelH > screen.height - _screenMargin) {
      top = screen.height - _screenMargin - _panelH;
    }

    double left = widget.isMe
        ? widget.bubbleRect.right - _panelW
        : widget.bubbleRect.left;
    left = left.clamp(_screenMargin, screen.width - _panelW - _screenMargin);

    return Offset(left, top);
  }

  // ── Reaction selection ────────────────────────────────────────────────────

  void _select(String emoji) {
    HapticFeedback.lightImpact();
    final result = emoji == widget.currentEmoji ? '' : emoji;
    Navigator.of(context).pop(result);
  }

  // ── Customisation actions ─────────────────────────────────────────────────

  void _enterCustomise() {
    HapticFeedback.selectionClick();
    setState(() {
      _editingReactions = List.from(_quickReactions);
      _editingSlot = -1;
      _mode = _PickerMode.customise;
    });
  }

  void _selectEditSlot(int index) {
    setState(() => _editingSlot = index);
  }

  void _replaceSlot(String emoji) {
    if (_editingSlot < 0 || _editingSlot >= 6) return;
    setState(() {
      _editingReactions[_editingSlot] = emoji;
      _editingSlot = -1;
    });
  }

  Future<void> _saveCustomisation() async {
    await saveQuickReactions(widget.userId, _editingReactions);
    if (mounted) {
      setState(() {
        _quickReactions = List.from(_editingReactions);
        _editingSlot = -1;
        _mode = _PickerMode.quick;
      });
    }
  }

  void _cancelCustomisation() {
    setState(() {
      _editingReactions = List.from(_quickReactions);
      _editingSlot = -1;
      _mode = _PickerMode.quick;
    });
  }

  Future<void> _restoreDefaults() async {
    setState(() {
      _editingReactions = List.from(kDefaultQuickReactions);
      _editingSlot = -1;
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.of(context).size;
    final pos = _panelPosition(screen);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).pop(null),
      child: Stack(
        children: [
          Positioned(
            left: pos.dx,
            top: pos.dy,
            width: _panelW,
            child: GestureDetector(
              onTap: () {}, // absorb taps; don't propagate to barrier
              child: FadeTransition(
                opacity: CurvedAnimation(
                  parent: widget.animation,
                  curve: Curves.easeOut,
                ),
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.88, end: 1.0).animate(
                    CurvedAnimation(
                        parent: widget.animation,
                        curve: Curves.easeOutBack),
                  ),
                  alignment: widget.isMe
                      ? Alignment.bottomRight
                      : Alignment.bottomLeft,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeInOut,
                    height: _panelH,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                          color: const Color(0xFFE2E8F0), width: 0.8),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x1A000000),
                          blurRadius: 20,
                          offset: Offset(0, 6),
                        ),
                      ],
                    ),
                    // ClipRRect ensures child content never bleeds outside
                    // the rounded corners during animated height changes.
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: _buildBody(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (_mode) {
      case _PickerMode.quick:
        return _buildQuickRow();
      case _PickerMode.expanded:
        return _buildExpandedGrid();
      case _PickerMode.customise:
        return _buildCustomisePanel();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Mode: quick
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildQuickRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          ..._quickReactions.map((emoji) {
            final isActive = emoji == widget.currentEmoji;
            return _EmojiButton(
              emoji: emoji,
              isActive: isActive,
              onTap: () => _select(emoji),
              size: 38,
              fontSize: 22,
            );
          }),
          // "…" more button
          _MoreButton(
            onTap: () {
              HapticFeedback.selectionClick();
              setState(() => _mode = _PickerMode.expanded);
            },
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Mode: expanded
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildExpandedGrid() {
    final all = kAllSupportedEmojis;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row — wrap-safe so it never overflows on narrow canvases
          Row(
            mainAxisSize: MainAxisSize.max,
            children: [
              _SmallIconButton(
                icon: Icons.arrow_back_rounded,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _mode = _PickerMode.quick);
                },
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Reactions',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF0F172A),
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
              // Edit quick reactions action
              GestureDetector(
                onTap: _enterCustomise,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(10),
                    border:
                        Border.all(color: const Color(0xFFBFDBFE), width: 1),
                  ),
                  child: const Text(
                    'Edit',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1E60AA),
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Grid — fill remaining height
          Expanded(
            child: GridView.builder(
              padding: EdgeInsets.zero,
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 8,
                mainAxisSpacing: 2,
                crossAxisSpacing: 2,
              ),
              itemCount: all.length,
              itemBuilder: (context, i) {
                final emoji = all[i];
                return _EmojiButton(
                  emoji: emoji,
                  isActive: emoji == widget.currentEmoji,
                  onTap: () => _select(emoji),
                  size: 34,
                  fontSize: 20,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Mode: customise
  // ─────────────────────────────────────────────────────────────────────────

  Widget _buildCustomisePanel() {
    final all = kAllSupportedEmojis;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header — use a Wrap so it never overflows on narrow canvases.
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              const Text(
                'Edit quick reactions',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                  decoration: TextDecoration.none,
                ),
              ),
              GestureDetector(
                onTap: _restoreDefaults,
                child: const Text(
                  'Reset',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF64748B),
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            'Tap a slot to replace it, then pick an emoji below.',
            style: TextStyle(
              fontSize: 11,
              color: Color(0xFF94A3B8),
              decoration: TextDecoration.none,
            ),
          ),
          const SizedBox(height: 10),

          // Six editable slots
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: List.generate(6, (i) {
              final emoji = _editingReactions[i];
              final isSelected = _editingSlot == i;
              return GestureDetector(
                onTap: () => _selectEditSlot(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFFDBEAFE)
                        : const Color(0xFFF8FAFC),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xFF1E60AA)
                          : const Color(0xFFE2E8F0),
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    emoji,
                    style: const TextStyle(
                      fontSize: 22,
                      height: 1.2,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 8),

          // Emoji grid — tapping replaces selected slot
          Expanded(
            child: _editingSlot < 0
                ? Center(
                    child: Text(
                      'Tap a slot above to choose which one to change.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade400,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  )
                : GridView.builder(
                    padding: EdgeInsets.zero,
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 8,
                      mainAxisSpacing: 2,
                      crossAxisSpacing: 2,
                    ),
                    itemCount: all.length,
                    itemBuilder: (context, i) {
                      final emoji = all[i];
                      return _EmojiButton(
                        emoji: emoji,
                        isActive: _editingReactions.contains(emoji),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          _replaceSlot(emoji);
                        },
                        size: 34,
                        fontSize: 20,
                      );
                    },
                  ),
          ),
          const SizedBox(height: 6),

          // Save / Cancel row
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _cancelCustomisation,
                  child: Container(
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF64748B),
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onTap: _saveCustomisation,
                  child: Container(
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E60AA),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      'Save',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Reusable sub-widgets
// ─────────────────────────────────────────────────────────────────────────────

/// A tappable emoji button with scale animation and optional active highlight.
class _EmojiButton extends StatefulWidget {
  const _EmojiButton({
    required this.emoji,
    required this.isActive,
    required this.onTap,
    this.size = 42,
    this.fontSize = 24,
  });

  final String emoji;
  final bool isActive;
  final VoidCallback onTap;
  final double size;
  final double fontSize;

  @override
  State<_EmojiButton> createState() => _EmojiButtonState();
}

class _EmojiButtonState extends State<_EmojiButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 110));
    _scale = Tween<double>(begin: 1.0, end: 0.78)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeIn));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) async {
        await _ctrl.reverse();
        widget.onTap();
      },
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.isActive
                ? const Color(0xFFDBEAFE)
                : Colors.transparent,
            shape: BoxShape.circle,
            border: widget.isActive
                ? Border.all(color: const Color(0xFF93C5FD), width: 1.5)
                : null,
          ),
          alignment: Alignment.center,
          child: Text(
            widget.emoji,
            style: TextStyle(
              fontSize: widget.fontSize,
              height: 1.2,
              // Explicitly clear any inherited decoration — this is the
              // confirmed fix for the yellow underline artifact.
              decoration: TextDecoration.none,
            ),
          ),
        ),
      ),
    );
  }
}

/// The circular "…" button that opens the expanded picker.
class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F9),
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFFE2E8F0), width: 1),
        ),
        alignment: Alignment.center,
        child: const Text(
          '…',
          style: TextStyle(
            fontSize: 20,
            height: 1.0,
            color: Color(0xFF64748B),
            fontWeight: FontWeight.w700,
            // Explicitly suppress any inherited underline decoration.
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}

/// Small icon button used in the expanded/customise header rows.
class _SmallIconButton extends StatelessWidget {
  const _SmallIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F9),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: 16, color: const Color(0xFF64748B)),
      ),
    );
  }
}
