import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The animated three-dot typing indicator and the slot it lives in.
///
/// Deliberately contains **no text**: no "is typing", no sender name, no card.
/// The three dots are the entire message.
///
/// The animation belongs to this one small widget only — its `AnimationController`
/// never touches the message list — and [TypingIndicatorBar] listens to a
/// [ValueListenable], so a typing event rebuilds the indicator and nothing else.
class TypingDots extends StatefulWidget {
  const TypingDots({
    super.key,
    this.dotSize = 6.5,
    this.gap = 5.0,
    this.color = const Color(0xFF94A3B8),
    this.cycle = const Duration(milliseconds: 1100),
  });

  final double dotSize;
  final double gap;
  final Color color;
  final Duration cycle;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.cycle);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Honour the OS "reduce animation" setting instead of forcing motion (A3).
    if (_reducedMotion) {
      if (_controller.isAnimating) _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _reducedMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// 0 → 1 → 0 across the phase, used for the lift / opacity / scale curve.
  static double _pulse(double phase) {
    final p = phase % 1.0; // Dart's % keeps the result non-negative.
    final half = p < 0.5 ? p * 2 : (1 - p) * 2;
    return Curves.easeInOut.transform(half);
  }

  Widget _dot(double wave) => SizedBox(
        width: widget.dotSize,
        height: widget.dotSize,
        child: Transform.translate(
          offset: Offset(0, -2.5 * wave),
          child: Transform.scale(
            scale: 0.8 + 0.2 * wave,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color.withValues(alpha: 0.45 + 0.55 * wave),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );

  List<Widget> _dots(double t) {
    final children = <Widget>[];
    for (var i = 0; i < 3; i++) {
      // Stagger left → right so the motion reads as a travelling wave.
      children.add(_dot(_pulse(t - i * 0.18)));
      if (i < 2) children.add(SizedBox(width: widget.gap));
    }
    return children;
  }

  @override
  Widget build(BuildContext context) {
    if (_reducedMotion) {
      // Static, evenly legible dots — the indicator still reads as "typing".
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (var i = 0; i < 3; i++) ...[_dot(0.6), if (i < 2) SizedBox(width: widget.gap)]],
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: _dots(_controller.value),
      ),
    );
  }
}

/// Compact pill that hosts [TypingDots], sized only by its own content.
///
/// The chat screen floats this over the bottom of the message feed, immediately
/// above the composer, instead of giving it a row in the chat Column: it is
/// content-sized (never full width), collapses to zero when the peer is not
/// typing, and animates its own appearance so the conversation is never
/// permanently shifted or shrunk.
class TypingIndicatorBar extends StatelessWidget {
  const TypingIndicatorBar({
    super.key,
    required this.peerTyping,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 2),
  });

  /// Whether the person on the other side of *this* conversation is typing.
  final ValueListenable<bool> peerTyping;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: peerTyping,
      builder: (context, isTyping, _) {
        return AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          alignment: Alignment.bottomLeft,
          child: isTyping
              ? Padding(
                  padding: padding,
                  child: Semantics(
                    label: 'Typing',
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 11, vertical: 9),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: const TypingDots(),
                    ),
                  ),
                )
              : const SizedBox(width: 0, height: 0),
        );
      },
    );
  }
}
