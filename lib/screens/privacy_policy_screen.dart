import 'package:flutter/material.dart';

import '../utils/privacy_policy_content.dart';
// The "Your Privacy Choices" section links to the real settings screens that
// own those controls. The import is only for navigation: opening this page
// never mutates location, notification, or account state.
import 'profile_screen.dart';

/// The KaSpot Privacy Policy, rendered from structured content.
///
/// The previous version loaded `assets/privacy_policy.html`, stripped every tag
/// to a newline and re-detected headings from line prefixes, which split each
/// wrapped sentence into a separate paragraph and dropped the bullets. The
/// policy now lives in [privacyPolicySections] and is laid out once, here.
class PrivacyPolicyScreen extends StatefulWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  State<PrivacyPolicyScreen> createState() => _PrivacyPolicyScreenState();
}

class _PrivacyPolicyScreenState extends State<PrivacyPolicyScreen> {
  static const _primary = Color(0xFF1E60AA);
  static const _heading = Color(0xFF0F172A);
  static const _body = Color(0xFF334155);
  static const _muted = Color(0xFF64748B);
  static const _faint = Color(0xFF94A3B8);
  static const _border = Color(0xFFE2E8F0);

  final _scrollController = ScrollController();
  final Map<String, GlobalKey> _sectionKeys = {
    for (final section in privacyPolicySections) section.id: GlobalKey(),
  };

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Scrolls a section to the top of the viewport. The page is one scroll view
  /// with every section built, so the target context always exists.
  void _jumpToSection(String id) {
    final target = _sectionKeys[id]?.currentContext;
    if (target == null) return;
    Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _openPrivacyControls() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const PrivacyScreen()),
    );
  }

  void _openNotificationPreferences() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const NotificationsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy Policy')),
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          controller: _scrollController,
          // Bottom padding clears the system navigation area; the page itself
          // has no fixed height, so it grows with the text scale.
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          child: Center(
            child: ConstrainedBox(
              // Keeps the reading measure comfortable on tablets.
              constraints: const BoxConstraints(maxWidth: 640),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _effectiveChip(),
                  const SizedBox(height: 18),
                  _tableOfContents(),
                  const SizedBox(height: 10),
                  for (var i = 0; i < privacyPolicySections.length; i++) ...[
                    _sectionDivider(),
                    _section(privacyPolicySections[i], i + 1),
                  ],
                  _footer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _effectiveChip() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF6FF),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFBFDBFE)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.verified_outlined, size: 14, color: _primary),
              const SizedBox(width: 6),
              // Flexible: at large text scales the label wraps inside the chip
              // instead of pushing the chip past the screen edge.
              Flexible(
                child: Text(
                  'Effective $privacyPolicyEffective',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: _primary,
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _border),
          ),
          child: Text(
            '${privacyPolicySections.length} sections',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _muted,
            ),
          ),
        ),
      ],
    );
  }

  Widget _tableOfContents() {
    return Container(
      decoration: const BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: _border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Row(
                children: [
                  const Icon(Icons.list_alt_rounded, size: 17, color: _primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'IN THIS POLICY',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: _muted,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            for (var i = 0; i < privacyPolicySections.length; i++)
              _tocRow(privacyPolicySections[i], i + 1),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _tocRow(PolicySection section, int number) {
    return InkWell(
      onTap: () => _jumpToSection(section.id),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 46),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: 26,
                child: Text(
                  number.toString().padLeft(2, '0'),
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: _faint,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  section.title,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _heading,
                    height: 1.35,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded, size: 18, color: _faint),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionDivider() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 24),
      child: Divider(height: 1, thickness: 1, color: Color(0xFFEDF2F7)),
    );
  }

  Widget _section(PolicySection section, int number) {
    return Column(
      key: _sectionKeys[section.id],
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A heading row rather than a card: nine stacked cards is what made the
        // previous page feel like a pile of boxes.
        Semantics(
          header: true,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 1),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFFEBF5FF),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  number.toString().padLeft(2, '0'),
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: _primary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  section.title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: _heading,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        for (final block in section.blocks) _block(block),
      ],
    );
  }

  Widget _block(PolicyBlock block) {
    switch (block) {
      case PolicyParagraph():
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            block.text,
            style: const TextStyle(fontSize: 14.5, color: _body, height: 1.6),
          ),
        );
      case PolicySubheading():
        return Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 8),
          child: Text(
            block.text,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: _primary,
              height: 1.3,
            ),
          ),
        );
      case PolicyBulletList():
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final bullet in block.bullets) _bullet(bullet)],
          ),
        );
      case PolicyCallout():
        return Container(
          margin: const EdgeInsets.only(top: 2, bottom: 14),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF0FDF4),
            borderRadius: BorderRadius.circular(12),
            border: const Border(
              left: BorderSide(color: Color(0xFF10B981), width: 3),
            ),
          ),
          child: Text(
            block.text,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: Color(0xFF065F46),
              height: 1.5,
            ),
          ),
        );
      case PolicyContactCard():
        return Container(
          margin: const EdgeInsets.only(top: 2),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                block.title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: _heading,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                block.text,
                style: const TextStyle(
                  fontSize: 13.5,
                  color: Color(0xFF475569),
                  height: 1.55,
                ),
              ),
            ],
          ),
        );
      case PolicyControls():
        return _choicesLauncher();
    }
  }

  Widget _bullet(PolicyBullet bullet) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 7, left: 3, right: 3),
            child: CircleAvatar(radius: 3, backgroundColor: _primary),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${bullet.title} — ',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: _heading,
                    ),
                  ),
                  TextSpan(text: bullet.text),
                ],
              ),
              style: const TextStyle(fontSize: 14, color: _body, height: 1.55),
            ),
          ),
        ],
      ),
    );
  }

  /// Links to the screens that own the actual controls. These navigate; they
  /// never toggle anything from here.
  Widget _choicesLauncher() {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'MANAGE IN THE APP',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: _faint,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 8),
          _ChoiceGroup(
            children: [
              _ChoiceTile(
                icon: Icons.shield_outlined,
                iconColor: _primary,
                title: 'Privacy & sharing rules',
                subtitle: 'Pause sharing or update who sees you',
                onTap: _openPrivacyControls,
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              _ChoiceTile(
                icon: Icons.notifications_none_rounded,
                iconColor: const Color(0xFFF59E0B),
                title: 'Notification preferences',
                subtitle: 'Messages, invitations and arrival alerts',
                onTap: _openNotificationPreferences,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _footer() {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 28, bottom: 18),
          child: Divider(height: 1, thickness: 1, color: _border),
        ),
        Text(
          privacyPolicyFooterCopyright,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: _faint, height: 1.5),
        ),
        const SizedBox(height: 4),
        Text(
          privacyPolicyFooterScope,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 12, color: _faint, height: 1.5),
        ),
      ],
    );
  }
}

/// Compact settings-style card, matching the tiles on Account & Privacy.
class _ChoiceGroup extends StatelessWidget {
  const _ChoiceGroup({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        boxShadow: [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: children),
      ),
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: iconColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(icon, color: iconColor, size: 20),
      ),
      title: Text(
        title,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 14,
          color: Color(0xFF0F172A),
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: Color(0xFF94A3B8),
        size: 20,
      ),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    );
  }
}
