import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import '../services/background_location_service.dart';
import '../services/kaspot_service.dart';
import '../utils/image_optimizer.dart';
import '../utils/location_tracking_config.dart';
import '../utils/release_flags.dart';
import '../widgets/kaspot_avatar.dart';
import 'delete_account_screen.dart';
import 'privacy_policy_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  /// The consent disclosure for background location sharing.
  ///
  /// Every number and every limitation shown here comes from
  /// [LocationTrackingConfig] — the same values the tracking service applies —
  /// so the dialog cannot drift away from what the code really does. Nothing in
  /// it promises continuous tracking, exact cadence or GPS accuracy.
  static Future<bool?> showBackgroundConsentDialog(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.location_on_rounded, color: Color(0xFF1E60AA)),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Background Sharing',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Keep sharing your latest position with your authorized circle '
                'after you leave KaSpot or lock your phone.',
                style: TextStyle(height: 1.45, fontSize: 13.5),
              ),
              const SizedBox(height: 14),
              _ConsentBullet(
                icon: Icons.battery_charging_full_rounded,
                color: Color(0xFF10B981),
                text: LocationTrackingConfig.cadenceSummary,
              ),
              _ConsentBullet(
                icon: Icons.speed_rounded,
                color: Color(0xFF64748B),
                text: LocationTrackingConfig.cadenceDisclaimer,
              ),
              _ConsentBullet(
                icon: Icons.close_rounded,
                color: Color(0xFFD97706),
                text: LocationTrackingConfig.lifecycleDisclosure,
              ),
              _ConsentBullet(
                icon: Icons.lock_outline_rounded,
                color: Color(0xFF1E60AA),
                text: LocationTrackingConfig.permissionDisclosure,
              ),
              _ConsentBullet(
                icon: Icons.gps_fixed_rounded,
                color: Color(0xFF64748B),
                text: LocationTrackingConfig.accuracyDisclaimer,
              ),
              _ConsentBullet(
                icon: Icons.notifications_active_outlined,
                color: Color(0xFF2563EB),
                text: LocationTrackingConfig.notificationDisclosure,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Turn ON'),
          ),
        ],
      ),
    );
  }

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

/// One honest line of background-sharing disclosure, rendered in the existing
/// KaSpot bullet style. The text always comes from [LocationTrackingConfig].
class _ConsentBullet extends StatelessWidget {
  const _ConsentBullet({
    required this.icon,
    required this.color,
    required this.text,
  });

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12.5,
                color: Color(0xFF475569),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileScreenState extends State<ProfileScreen> {
  String _name = 'KaSpot Member';
  String? _avatarUrl;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profile = await KaSpotService.myProfile();
      if (mounted && profile != null) {
        setState(() {
          _name = profile['display_name'] as String? ?? _name;
          _avatarUrl = profile['avatar_url'] as String?;
        });
      }
    } catch (_) {}
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();

    final isMobile =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);

    final source = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Change Profile Picture',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFFEBF5FF),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isMobile
                        ? Icons.photo_library_rounded
                        : Icons.computer_rounded,
                    color: const Color(0xFF1E60AA),
                  ),
                ),
                title: Text(
                  isMobile ? 'Choose from Gallery' : 'Upload from Computer',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  isMobile
                      ? 'Pick an image from your device storage'
                      : 'Choose an image file from your PC',
                ),
                onTap: () => Navigator.pop(context, 'gallery'),
              ),
              if (isMobile)
                ListTile(
                  leading: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEBF5FF),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.camera_alt_rounded,
                      color: Color(0xFF1E60AA),
                    ),
                  ),
                  title: const Text(
                    'Take a Photo',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text('Use camera to take a new picture'),
                  onTap: () => Navigator.pop(context, 'camera'),
                ),
              ListTile(
                leading: Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFFECFDF5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.face_rounded,
                    color: Color(0xFF059669),
                  ),
                ),
                title: const Text(
                  'Choose from Presets',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text('Select a curated portrait avatar'),
                onTap: () => Navigator.pop(context, 'presets'),
              ),
              if (_avatarUrl != null) ...[
                const Divider(),
                ListTile(
                  leading: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF2F2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.delete_outline_rounded,
                      color: Color(0xFFEF4444),
                    ),
                  ),
                  title: const Text(
                    'Remove Photo',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFEF4444),
                    ),
                  ),
                  subtitle: const Text('Revert to initial gradient avatar'),
                  onTap: () => Navigator.pop(context, 'remove'),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (source == null) return;

    if (source == 'presets') {
      await _selectPresetAvatar();
      return;
    }

    if (source == 'remove') {
      try {
        await KaSpotService.updateMyAvatar(null);
        if (mounted) {
          setState(() => _avatarUrl = null);
          _notify('Profile photo removed.');
        }
      } catch (e) {
        if (mounted) _notify(e.toString());
      }
      return;
    }

    try {
      final xFile = await picker.pickImage(
        source: source == 'camera' ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
      );

      if (xFile == null) return;

      final rawBytes = await xFile.readAsBytes();
      final optimized = await ImageOptimizer.compressAvatar(rawBytes);

      await KaSpotService.updateMyAvatar(optimized.base64DataUri);

      if (mounted) {
        setState(() => _avatarUrl = optimized.base64DataUri);
        _notify(
          'Profile photo updated! (Optimized to ${optimized.kilobytes.toStringAsFixed(1)} KB)',
        );
      }
    } catch (e) {
      if (e.toString().contains('cameraDelegate') ||
          e.toString().contains('ImageSource.camera')) {
        if (mounted) {
          _notify(
            'Live camera capture is for mobile devices (Android/iOS). Please choose a photo from your computer.',
          );
        }
      } else if (e is MissingPluginException ||
          e.toString().contains('MissingPluginException')) {
        if (mounted) {
          showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              title: const Row(
                children: [
                  Icon(Icons.restart_alt_rounded, color: Color(0xFF1E60AA)),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Restart App to Enable Picker',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              content: const Text(
                'Because image_picker uses a native Windows C++ plugin, Hot Reload cannot attach the system file dialog while the app is actively running.\n\n'
                '👉 In Android Studio, please Stop the app (Red Stop button ⏹) and Run it again (Green Play button ▶) to rebuild with native file dialog support.\n\n'
                'Tip: You can use "Choose from Presets" right now without restarting!',
                style: TextStyle(height: 1.45, fontSize: 13.5),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _selectPresetAvatar();
                  },
                  child: const Text('Try a Preset Photo'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Got it'),
                ),
              ],
            ),
          );
        }
      } else {
        if (mounted) _notify('Could not update image: $e');
      }
    }
  }

  Future<void> _selectPresetAvatar() async {
    final presets = [
      'https://images.unsplash.com/photo-1534528741775-53994a69daeb?w=300&fit=crop',
      'https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=300&fit=crop',
      'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=300&fit=crop',
      'https://images.unsplash.com/photo-1500648767791-00dcc994a43e?w=300&fit=crop',
      'https://images.unsplash.com/photo-1517841905240-472988babdf9?w=300&fit=crop',
      'https://images.unsplash.com/photo-1539571696357-5a69c17a67c6?w=300&fit=crop',
    ];

    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Choose a Preset Avatar'),
        content: SizedBox(
          width: 300,
          child: Wrap(
            spacing: 14,
            runSpacing: 14,
            alignment: WrapAlignment.center,
            children: presets.map((url) {
              return GestureDetector(
                onTap: () => Navigator.pop(context, url),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF2563EB),
                      width: 2,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x20000000),
                        blurRadius: 4,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: ClipOval(
                    child: Image.network(
                      url,
                      width: 60,
                      height: 60,
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (chosen != null) {
      try {
        await KaSpotService.updateMyAvatar(chosen);
        if (mounted) {
          setState(() => _avatarUrl = chosen);
          _notify('Preset avatar applied!');
        }
      } catch (e) {
        if (mounted) _notify(e.toString());
      }
    }
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Display Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(labelText: 'Display name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (ok != true || controller.text.trim().isEmpty) {
      controller.dispose();
      return;
    }

    try {
      await KaSpotService.updateMyName(controller.text);
      if (mounted) {
        setState(() => _name = controller.text.trim());
        _notify('Display name updated.');
      }
    } catch (e) {
      if (mounted) _notify(e.toString());
    }
    controller.dispose();
  }

  void _notify(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  /// Signing out is destructive for the current session, so it always goes
  /// through an explicit confirmation dialog first — a single accidental tap
  /// must never log the user out.
  Future<void> _confirmSignOut() async {
    if (_busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.logout_rounded, color: Color(0xFFDC2626)),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Sign Out?',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        content: const Text(
          'You will be signed out on this device. Your circle and sharing settings stay saved to your account — you can sign back in anytime.',
          style: TextStyle(height: 1.45, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await KaSpotService.signOut();
      // The auth-state notifier now routes the app back to the Welcome flow.
    } catch (e) {
      if (mounted) _notify(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Opens the deletion screen. Nothing is deleted here: the screen explains
  /// the consequences, requires the typed confirmation and re-authenticates
  /// before it sends anything.
  Future<void> _openDeleteAccount() async {
    if (_busy) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const DeleteAccountScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final id = KaSpotService.userId;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Account & Privacy'),
        actions: [
          IconButton(
            tooltip: 'Notification Settings',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const NotificationsScreen()),
            ),
            icon: const Icon(Icons.notifications_none_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: [
          // 1. Profile Identity Header Card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: const Color(0xFFE2E8F0)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x0A000000),
                  blurRadius: 12,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _pickAvatar,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      KaSpotAvatar(
                        name: _name,
                        avatarUrl: _avatarUrl,
                        size: 60,
                        isCircle: true,
                        showBorder: true,
                        borderColor: const Color(0xFF2563EB),
                        borderWidth: 2,
                      ),
                      Positioned(
                        right: -2,
                        bottom: -2,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E60AA),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x30000000),
                                blurRadius: 4,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.camera_alt_rounded,
                            size: 11,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              _name,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 18,
                                color: Color(0xFF0F172A),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: _rename,
                            child: const Icon(
                              Icons.edit_outlined,
                              size: 18,
                              color: Color(0xFF1E60AA),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // 2. Account ID Quick Copy
          if (id.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.badge_outlined,
                    color: Color(0xFF1E60AA),
                    size: 22,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Your KaSpot Circle Code',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF64748B),
                          ),
                        ),
                        Text(
                          KaSpotService.accountCode,
                          style: const TextStyle(
                            fontSize: 15,
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.5,
                            color: Color(0xFF0F172A),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      final code = KaSpotService.accountCode;
                      Clipboard.setData(ClipboardData(text: code));
                      _notify('Circle Code $code copied to clipboard.');
                    },
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    label: const Text('Copy'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ),

          const SizedBox(height: 20),

          // 3. Privacy & Safety Shield Section
          _heading('Privacy & Controls'),
          _SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.shield_outlined,
                iconColor: const Color(0xFF1E60AA),
                title: 'Privacy & Sharing Rules',
                subtitle: 'Control who sees you and pause sharing',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const PrivacyScreen()),
                ),
              ),
              _SettingsTile(
                icon: Icons.notifications_none_rounded,
                iconColor: const Color(0xFFF59E0B),
                title: 'Notifications',
                subtitle: 'Messages, invitations and arrival alerts',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const NotificationsScreen(),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // 4. App & Support Section
          _heading('About KaSpot'),
          _SettingsGroup(
            children: [
              _SettingsTile(
                icon: Icons.privacy_tip_outlined,
                iconColor: const Color(0xFF10B981),
                title: 'Privacy Policy',
                subtitle: 'How KaSpot handles your data',
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const PrivacyPolicyScreen(),
                  ),
                ),
              ),
              _SettingsTile(
                icon: Icons.info_outline_rounded,
                iconColor: const Color(0xFF64748B),
                title: 'About KaSpot',
                subtitle: 'Consent-first location sharing',
                onTap: () => showAboutDialog(
                  context: context,
                  applicationName: 'KaSpot',
                  applicationVersion: '1.0.0 (Release Candidate)',
                  applicationLegalese:
                      '© 2026 KaSpot. Privacy-first architecture.',
                  children: const [
                    SizedBox(height: 8),
                    Text('Your people. Your places. Your peace of mind.'),
                    SizedBox(height: 8),
                    Text('Built with Flutter, OpenStreetMap, and Supabase.'),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // 5. Session: Delete Account / Sign Out
          _heading('Session'),
          _SettingsGroup(
            children: [
              // Hidden unless the build was produced for a project where the
              // delete-account function is deployed and verified — a deletion
              // screen that cannot delete is worse than no button.
              if (ReleaseFlags.accountDeletionEnabled) ...[
                _SettingsTile(
                  icon: Icons.delete_forever_rounded,
                  iconColor: const Color(0xFFDC2626),
                  title: 'Delete Account',
                  subtitle: 'Permanently erase your account and its data',
                  titleColor: const Color(0xFFDC2626),
                  onTap: _busy ? null : _openDeleteAccount,
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
              ],
              _SettingsTile(
                icon: Icons.logout_rounded,
                iconColor: const Color(0xFFDC2626),
                title: 'Sign Out',
                subtitle: 'Log out of your KaSpot account',
                titleColor: const Color(0xFFDC2626),
                onTap: _busy ? null : _confirmSignOut,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heading(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: Color(0xFF64748B),
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  bool _isPaused = false;
  bool _loading = true;
  bool _busy = false;
  String? _loadError;
  List<Map<String, dynamic>> _members = [];
  Map<String, bool> _grants = {};

  @override
  void initState() {
    super.initState();
    _loadSharingStatus();
  }

  Future<void> _loadSharingStatus() async {
    try {
      final results = await Future.wait([
        KaSpotService.anySharingEnabled(),
        KaSpotService.connections(),
        KaSpotService.sharingGrants(),
      ]);
      if (!mounted) return;
      setState(() {
        _isPaused = !(results[0] as bool);
        _members = results[1] as List<Map<String, dynamic>>;
        _grants = {
          for (final row in results[2] as List<Map<String, dynamic>>)
            row['recipient_id'] as String: row['is_enabled'] as bool? ?? false,
        };
        _loadError = null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not load your sharing settings. Check your connection and try again.';
      });
    }
  }

  Future<void> _retryLoad() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    await _loadSharingStatus();
  }

  /// Enables or disables location sharing for a single circle member. This
  /// mirrors the Circle tab: enabling requires a live location fix, and
  /// anything the backend rejects rolls the switch straight back.
  Future<void> _setMemberSharing(String otherId, bool enabled) async {
    if (_busy) return;
    final wasEnabled = _grants[otherId] ?? false;
    setState(() {
      _busy = true;
      _grants[otherId] = enabled;
    });

    try {
      if (enabled) {
        if (!await Geolocator.isLocationServiceEnabled()) {
          throw Exception('Turn on device location services before sharing.');
        }
        var permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          permission = await Geolocator.requestPermission();
        }
        if (permission == LocationPermission.denied ||
            permission == LocationPermission.deniedForever) {
          throw Exception(
            'Location permission was not granted. Sharing remains off.',
          );
        }
        final position = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        );
        await KaSpotService.setSharing(otherId, true);
        await KaSpotService.upsertOwnLocation(position);
      } else {
        await KaSpotService.setSharing(otherId, false);
      }

      // Keep the global "paused" indicator in sync with the per-member grants.
      try {
        final active = await KaSpotService.anySharingEnabled();
        if (mounted) setState(() => _isPaused = !active);
      } catch (_) {
        // The grant itself was saved; the pause state refreshes on next load.
      }
      if (!mounted) return;
      _notify(
        enabled
            ? 'Location sharing enabled for this person.'
            : 'Location sharing stopped for this person.',
      );
    } catch (e) {
      if (mounted) {
        setState(() => _grants[otherId] = wasEnabled); // rollback on failure
        _notify(e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notify(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  Widget _sectionHeading(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: Color(0xFF64748B),
          letterSpacing: 0.8,
        ),
      ),
    );
  }

  Widget _memberTile(Map<String, dynamic> member) {
    final otherId = member['other_id'] as String;
    final name = member['display_name'] as String? ?? 'KaSpot member';
    final shares = _grants[otherId] ?? false;

    return SwitchListTile.adaptive(
      value: shares,
      onChanged: _busy ? null : (val) => _setMemberSharing(otherId, val),
      secondary: KaSpotAvatar(
        name: name,
        avatarUrl: member['avatar_url'] as String?,
        size: 40,
        isCircle: true,
      ),
      title: Text(
        name,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 14,
          color: Color(0xFF0F172A),
        ),
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        shares
            ? 'Can see your latest location'
            : 'Location hidden from this person',
        style: TextStyle(
          fontSize: 12,
          color: shares ? const Color(0xFF059669) : const Color(0xFF64748B),
          fontWeight: shares ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    );
  }

  Widget _errorCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFDC2626),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _loadError!,
              style: const TextStyle(
                color: Color(0xFFB91C1C),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(onPressed: _retryLoad, child: const Text('Try Again')),
        ],
      ),
    );
  }

  Widget _emptyMembersCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: const [
          Icon(
            Icons.visibility_off_outlined,
            size: 32,
            color: Color(0xFF94A3B8),
          ),
          SizedBox(height: 10),
          Text(
            'No circle members yet',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 14,
              color: Color(0xFF0F172A),
            ),
          ),
          SizedBox(height: 6),
          Text(
            'Invite trusted people from the Circle tab. Your location stays hidden until you explicitly enable sharing for each person.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Color(0xFF64748B),
              height: 1.4,
              fontSize: 12.5,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _togglePause(bool shouldPause) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _isPaused = shouldPause;
    });

    try {
      // shouldPause == true -> pause all sharing (set is_enabled to false)
      // shouldPause == false -> resume circle sharing (set is_enabled to true)
      await KaSpotService.setSharingForAll(!shouldPause);
      if (mounted) {
        setState(() {
          // Mirror the change on every visible per-member switch.
          for (final member in _members) {
            _grants[member['other_id'] as String] = !shouldPause;
          }
        });
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              shouldPause
                  ? 'All location sharing paused. Your position is hidden from all members.'
                  : 'Location sharing resumed for your authorized circle.',
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isPaused = !shouldPause); // rollback on error
        _loadSharingStatus(); // resync any partial changes from the source of truth
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update sharing: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Privacy & Safety')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Icon(
                  Icons.verified_user_rounded,
                  size: 32,
                  color: Color(0xFF1E60AA),
                ),
                SizedBox(height: 12),
                Text(
                  'You Control Every Coordinate',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                    color: Color(0xFF0F172A),
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Adding someone to your circle never shares your location automatically. Each sharing grant is a separate, explicit choice that you can revoke at any time.',
                  style: TextStyle(height: 1.45, color: Color(0xFF64748B)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _SettingsGroup(
            children: [
              ListenableBuilder(
                listenable: Listenable.merge([
                  BackgroundLocationService.isBackgroundSharingEnabled,
                  BackgroundLocationService.state,
                ]),
                builder: (context, _) {
                  final bgEnabled = BackgroundLocationService
                      .isBackgroundSharingEnabled
                      .value;
                  // The switch shows the user's choice; the line under it shows
                  // what the service is really doing, so a failed start can never
                  // read as "Active".
                  final statusLine = bgEnabled
                      ? BackgroundLocationService.describeState()
                      : 'Off · Only updates while the app is on screen';
                  return SwitchListTile.adaptive(
                    value: bgEnabled,
                    onChanged: (val) async {
                      if (val) {
                        final confirmed =
                            await ProfileScreen.showBackgroundConsentDialog(
                              context,
                            );
                        if (confirmed == true) {
                          try {
                            await BackgroundLocationService.startBackgroundTracking();
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Background location sharing enabled.',
                                  ),
                                ),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    e.toString().replaceFirst(
                                      'Exception: ',
                                      '',
                                    ),
                                  ),
                                ),
                              );
                            }
                          }
                        }
                      } else {
                        await BackgroundLocationService.stopBackgroundTracking();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Background sharing stopped.'),
                            ),
                          );
                        }
                      }
                    },
                    secondary: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color:
                            (bgEnabled
                                    ? const Color(0xFF10B981)
                                    : const Color(0xFF1E60AA))
                                .withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        bgEnabled
                            ? Icons.fmd_good_rounded
                            : Icons.location_on_outlined,
                        color: bgEnabled
                            ? const Color(0xFF10B981)
                            : const Color(0xFF1E60AA),
                        size: 20,
                      ),
                    ),
                    title: const Text(
                      'Background Location Sharing',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    subtitle: Text(
                      statusLine,
                      style: TextStyle(
                        fontSize: 12,
                        color:
                            bgEnabled &&
                                (BackgroundLocationService.state.value ==
                                        TrackingState.failed ||
                                    BackgroundLocationService.state.value ==
                                        TrackingState.blockedPermission ||
                                    BackgroundLocationService.state.value ==
                                        TrackingState.blockedLocationServices)
                            ? const Color(0xFFD97706)
                            : const Color(0xFF64748B),
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                  );
                },
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              SwitchListTile.adaptive(
                value: _isPaused,
                onChanged: (_loading || _busy) ? null : _togglePause,
                secondary: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color:
                        (_isPaused
                                ? const Color(0xFFD97706)
                                : const Color(0xFF1E60AA))
                            .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    _isPaused
                        ? Icons.pause_circle_rounded
                        : Icons.share_location_rounded,
                    color: _isPaused
                        ? const Color(0xFFD97706)
                        : const Color(0xFF1E60AA),
                    size: 20,
                  ),
                ),
                title: const Text(
                  'Pause Sharing for Everyone',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: Color(0xFF0F172A),
                  ),
                ),
                subtitle: Text(
                  _isPaused
                      ? 'Paused · Your location is completely hidden from all members'
                      : 'Active · Location sharing is enabled for your circle',
                  style: TextStyle(
                    fontSize: 12,
                    color: _isPaused
                        ? const Color(0xFFD97706)
                        : const Color(0xFF64748B),
                    fontWeight: _isPaused ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _sectionHeading('Who can see you'),
          if (_loadError != null)
            _errorCard()
          else if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_members.isEmpty)
            _emptyMembersCard()
          else
            _SettingsGroup(
              children: [
                for (var i = 0; i < _members.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                  _memberTile(_members[i]),
                ],
              ],
            ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Text(
              LocationTrackingConfig.privacyCardSummary,
              style: const TextStyle(
                color: Color(0xFF64748B),
                height: 1.45,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  Map<String, dynamic> _prefs = {
    'connection_notifications_enabled': true,
    'arrival_alerts_enabled': false,
  };
  bool _loading = true;
  String? _loadError;
  String? _savingField;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final results = await KaSpotService.notificationPreferences();
      if (!mounted) return;
      setState(() {
        _prefs = results;
        _loadError = null;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Could not load your notification settings. Check your connection and try again.';
      });
    }
  }

  Future<void> _retryLoad() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    await _load();
  }

  Future<void> _toggle(String field, bool value) async {
    if (_savingField != null) return;
    final previous = _prefs[field] as bool? ?? false;
    setState(() {
      _prefs[field] = value;
      _savingField = field;
    });
    try {
      await KaSpotService.setNotificationPreference(field, value);
      if (mounted) _notify('Notification preference updated.');
    } catch (e) {
      if (mounted) {
        setState(() => _prefs[field] = previous); // rollback on failure
        _notify(e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _savingField = null);
    }
  }

  void _notify(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFFFECACA)),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        color: Color(0xFFDC2626),
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _loadError!,
                          style: const TextStyle(
                            color: Color(0xFFB91C1C),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _retryLoad,
                        child: const Text('Try Again'),
                      ),
                    ],
                  ),
                ),
              ],
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const _NotificationScopeNote(),
                const SizedBox(height: 16),
                _SettingsGroup(
                  children: [
                    SwitchListTile.adaptive(
                      value:
                          _prefs['connection_notifications_enabled'] as bool? ??
                          true,
                      onChanged: _savingField == null
                          ? (v) =>
                                _toggle('connection_notifications_enabled', v)
                          : null,
                      title: const Text(
                        'Messages & invitations',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: const Text(
                        'Banners for new messages and circle invitations, and push '
                        'alerts for new messages. Messages still arrive in the chat '
                        'when this is off.',
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    SwitchListTile.adaptive(
                      value: _prefs['arrival_alerts_enabled'] as bool? ?? false,
                      onChanged: _savingField == null
                          ? (v) => _toggle('arrival_alerts_enabled', v)
                          : null,
                      title: const Text(
                        'Arrival & Departure Alerts',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: const Text(
                        'Shown inside KaSpot while it is open, based on the '
                        'places you saved.',
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

class _NotificationScopeNote extends StatelessWidget {
  const _NotificationScopeNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: const [
          Text(
            'Two separate things',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
            ),
          ),
          SizedBox(height: 6),
          Text(
            'These switches are KaSpot\'s own settings. Android notifications are '
            'separate: if the system permission is off, no alert can appear even '
            'when these are turned on.',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.45,
              color: Color(0xFF64748B),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});
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
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFFE2E8F0)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: children),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.titleColor,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Color? titleColor;

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
        style: TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 14,
          color: titleColor ?? const Color(0xFF0F172A),
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
