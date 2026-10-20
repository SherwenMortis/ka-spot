import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Renders the KaSpot Privacy Policy from the bundled HTML asset.
/// Uses a WebView-style scrollable view via a simple HTML renderer.
/// Falls back to a clean text layout if the asset cannot be loaded.
class PrivacyPolicyScreen extends StatefulWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  State<PrivacyPolicyScreen> createState() => _PrivacyPolicyScreenState();
}

class _PrivacyPolicyScreenState extends State<PrivacyPolicyScreen> {
  String? _content;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadPolicy();
  }

  Future<void> _loadPolicy() async {
    try {
      final raw = await rootBundle.loadString('assets/privacy_policy.html');
      // Strip HTML tags for a clean native text rendering.
      final text = _stripHtml(raw);
      if (mounted) setState(() { _content = text; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _content = null; _loading = false; });
    }
  }

  /// Minimal HTML stripper — removes tags and decodes common entities.
  String _stripHtml(String html) {
    // Remove <style> blocks
    var text = html.replaceAll(RegExp(r'<style[^>]*>.*?</style>', dotAll: true), '');
    // Remove all tags
    text = text.replaceAll(RegExp(r'<[^>]+>'), '\n');
    // Decode common HTML entities
    text = text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#39;', "'")
        .replaceAll('&quot;', '"');
    // Collapse multiple blank lines to max two
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return text.trim();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Privacy Policy'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _content == null
              ? _buildError()
              : _buildContent(_content!),
    );
  }

  Widget _buildContent(String text) {
    // Parse the stripped text into sections for nicer native rendering.
    final lines = text.split('\n');
    final widgets = <Widget>[];

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) {
        widgets.add(const SizedBox(height: 6));
        continue;
      }

      // Detect section headers (short all-caps or title-case lines preceded by marker)
      final isHeader = line.length < 60 &&
          !line.endsWith('.') &&
          !line.endsWith(',') &&
          (line.startsWith('Information') ||
           line.startsWith('How We') ||
           line.startsWith('Zero') ||
           line.startsWith('Who Can') ||
           line.startsWith('Data') ||
           line.startsWith('Push') ||
           line.startsWith('Your Rights') ||
           line.startsWith('Children') ||
           line.startsWith('Changes') ||
           line.startsWith('Contact'));

      final isTitle = line.contains('KaSpot') && line.contains('Privacy Policy');
      final isEffective = line.startsWith('Effective');
      final isBullet = line.startsWith('•') || line.startsWith('-') ||
          line.startsWith('✅') || line.startsWith('📍');
      final isHighlight = line.startsWith('✅') || line.startsWith('📍');

      if (isTitle) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(line, style: const TextStyle(
            fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF1E60AA),
          ), textAlign: TextAlign.center),
        ));
      } else if (isEffective) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFFEFF6FF),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFBFDBFE)),
              ),
              child: Text(line, style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF1E60AA),
              )),
            ),
          ),
        ));
      } else if (isHeader) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 20, bottom: 8),
          child: Row(
            children: [
              Container(
                width: 4, height: 18,
                decoration: BoxDecoration(
                  color: const Color(0xFF1E60AA),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(line, style: const TextStyle(
                fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF0F172A),
              ))),
            ],
          ),
        ));
      } else if (isHighlight) {
        widgets.add(Container(
          margin: const EdgeInsets.symmetric(vertical: 8),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF0FDF4),
            borderRadius: BorderRadius.circular(10),
            border: const Border(left: BorderSide(color: Color(0xFF10B981), width: 3)),
          ),
          child: Text(line, style: const TextStyle(
            fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xFF065F46), height: 1.5,
          )),
        ));
      } else if (isBullet) {
        final content = line.replaceFirst(RegExp(r'^[•\-]\s*'), '');
        widgets.add(Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 7),
                child: CircleAvatar(
                  radius: 3,
                  backgroundColor: Color(0xFF1E60AA),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(content, style: const TextStyle(
                fontSize: 14, color: Color(0xFF334155), height: 1.55,
              ))),
            ],
          ),
        ));
      } else {
        widgets.add(Padding(
          padding: const EdgeInsets.only(bottom: 5),
          child: Text(line, style: const TextStyle(
            fontSize: 14, color: Color(0xFF334155), height: 1.6,
          )),
        ));
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 48),
      children: [
        // Header card
        Container(
          padding: const EdgeInsets.all(16),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF1E60AA), Color(0xFF2196F3)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.shield_rounded, color: Colors.white, size: 26),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Privacy Policy', style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800, color: Colors.white,
                    )),
                    SizedBox(height: 2),
                    Text('How KaSpot handles your data', style: TextStyle(
                      fontSize: 12.5, color: Colors.white70,
                    )),
                  ],
                ),
              ),
            ],
          ),
        ),
        ...widgets,
        const SizedBox(height: 16),
        // Footer
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: const Text(
            '© 2026 KaSpot · Privacy-first location sharing\nThis policy applies to the KaSpot mobile application.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8), height: 1.6),
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline_rounded, size: 48, color: Color(0xFF94A3B8)),
            SizedBox(height: 16),
            Text(
              'Could not load the Privacy Policy.',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              'Please check your connection and try again.',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
