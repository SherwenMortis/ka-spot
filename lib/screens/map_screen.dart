import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/background_location_service.dart';
import '../services/connectivity_service.dart';
import '../services/in_app_notification_service.dart';
import '../services/kaspot_service.dart';
import '../utils/location_tracking_config.dart';
import '../widgets/kaspot_avatar.dart';
import '../widgets/kaspot_logo.dart';
import 'profile_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

/// Selectable base tile source for the map.
enum _MapLayerMode { standard, satellite }

class _MapScreenState extends State<MapScreen> with SingleTickerProviderStateMixin {
  final _map = MapController();
  late final AnimationController _syncAnimController;
  LatLng? _myPoint;
  List<Map<String, dynamic>> _shared = [];
  bool _busy = false;
  bool _sharing = false;
  bool _refreshing = false;
  bool _online = true;
  String _myName = 'You';
  String? _myAvatarUrl;
  _MapLayerMode _layerMode = _MapLayerMode.standard;
  RealtimeChannel? _channel;
  // Safety-net: re-fetches shared locations every 30 s so missed Realtime
  // events (brief channel drops) are caught and staleness labels self-update.
  Timer? _safetyTimer;

  @override
  void initState() {
    super.initState();
    _syncAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    KaSpotService.profileNotifier.addListener(_onProfileUpdated);
    BackgroundLocationService.livePosition.addListener(_onLivePosition);
    _online = ConnectivityService.isOnline.value;
    ConnectivityService.isOnline.addListener(_onConnectivityChanged);
    if (KaSpotService.lastUserLatitude != null && KaSpotService.lastUserLongitude != null) {
      _myPoint = LatLng(KaSpotService.lastUserLatitude!, KaSpotService.lastUserLongitude!);
    }
    _refresh();
    _subscribe();
    _initAutoLocate();
    // 30-second safety-net: catches missed Realtime events and forces
    // staleness label re-evaluation without hammering the server.
    _safetyTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_refreshing) unawaited(_refresh());
    });
  }

  /// Called whenever the background GPS stream emits a new position.
  /// Updates the own-user marker in real-time without requiring a manual tap.
  void _onLivePosition() {
    final pos = BackgroundLocationService.livePosition.value;
    if (pos == null || !mounted) return;
    final point = LatLng(pos.latitude, pos.longitude);
    KaSpotService.lastUserLatitude = pos.latitude;
    KaSpotService.lastUserLongitude = pos.longitude;
    setState(() => _myPoint = point);
  }

  /// Connection state drives the offline banner, the status pill and an
  /// automatic resync so events missed while offline are pulled in.
  void _onConnectivityChanged() {
    final online = ConnectivityService.isOnline.value;
    if (!mounted) return;
    setState(() => _online = online);
    if (online) {
      unawaited(_refresh());
    }
  }

  Future<void> _initAutoLocate() async {
    // Go straight to a fresh high-precision GPS fix. Skip getLastKnownPosition()
    // because the OS cache can be hours old and causes the marker to jump to a
    // stale location before snapping to the real position.
    await _autoLocate();
  }

  Future<void> _autoLocate() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: LocationTrackingConfig.autoFixTimeLimit,
        ),
      );

      final point = LatLng(position.latitude, position.longitude);
      KaSpotService.lastUserLatitude = position.latitude;
      KaSpotService.lastUserLongitude = position.longitude;

      if (_sharing) {
        await KaSpotService.upsertOwnLocation(position);
      }

      if (mounted) {
        setState(() => _myPoint = point);
        _map.move(point, 16.0);
      }
    } catch (_) {
      // Quiet fail: Do not disrupt UI on background auto-locate failure
    }
  }

  void _onProfileUpdated() {
    final p = KaSpotService.profileNotifier.value;
    if (p != null && mounted) {
      setState(() {
        final name = p['display_name'] as String?;
        if (name != null && name.trim().isNotEmpty) {
          _myName = name.trim().split(' ').first;
        }
        _myAvatarUrl = p['avatar_url'] as String?;
      });
    }
  }

  void _subscribe() {
    if (!KaSpotService.isConfigured) return;
    final channel = KaSpotService.client!.channel('kaspot-location-map-${KaSpotService.userId}')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'locations',
        callback: (_) => _refresh(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'locations',
        callback: (_) => _refresh(),
      )
      // Fix: also catch DELETE so a member's pin disappears the instant they
      // turn off sharing and their locations row is removed.
      ..onPostgresChanges(
        event: PostgresChangeEvent.delete,
        schema: 'public',
        table: 'locations',
        callback: (_) => _refresh(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'location_sharing',
        callback: (_) => _refresh(),
      );
    _channel = channel;
    channel.subscribe();
  }

  @override
  void dispose() {
    _safetyTimer?.cancel();
    _syncAnimController.stop();
    _syncAnimController.dispose();
    KaSpotService.profileNotifier.removeListener(_onProfileUpdated);
    BackgroundLocationService.livePosition.removeListener(_onLivePosition);
    ConnectivityService.isOnline.removeListener(_onConnectivityChanged);
    final channel = _channel;
    if (channel != null && KaSpotService.isConfigured) {
      unawaited(KaSpotService.client!.removeChannel(channel));
    }
    _map.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    if (mounted) {
      unawaited(_syncAnimController.repeat());
    }
    try {
      final values = await Future.wait([
        KaSpotService.anySharingEnabled(),
        KaSpotService.sharedLocations(),
        KaSpotService.myProfile(),
      ]);
      if (mounted) {
        final profile = values[2] as Map<String, dynamic>?;
        final name = profile?['display_name'] as String?;
        final newShared = values[1] as List<Map<String, dynamic>>;
        setState(() {
          _sharing = values[0] as bool;
          _shared = newShared;
          if (name != null && name.trim().isNotEmpty) {
            _myName = name.trim().split(' ').first;
          }
          _myAvatarUrl = profile?['avatar_url'] as String?;
        });

        // Trigger in-app arrival detection
        _checkArrivals(newShared);
      }
    } catch (_) {
    } finally {
      if (mounted) {
        _syncAnimController.stop();
        _syncAnimController.reset();
        setState(() => _refreshing = false);
      } else {
        _refreshing = false;
      }
    }
  }

  Future<void> _checkArrivals(List<Map<String, dynamic>> sharedMembers) async {
    try {
      final prefs = await KaSpotService.notificationPreferences();
      final arrivalEnabled = prefs['arrival_alerts_enabled'] as bool? ?? false;
      if (!arrivalEnabled) return;

      final places = await KaSpotService.savedPlaces();
      InAppNotificationService.checkMemberArrivals(
        sharedMembers: sharedMembers,
        savedPlaces: places,
        arrivalAlertsEnabled: arrivalEnabled,
        onArrivalTap: (member, place) {
          final lat = (member['latitude'] as num?)?.toDouble();
          final lon = (member['longitude'] as num?)?.toDouble();
          if (lat != null && lon != null) {
            _map.move(LatLng(lat, lon), 16.0);
          }
        },
      );
    } catch (_) {}
  }

  Widget _relationshipPill(String rel) {
    Color bg;
    Color text;
    IconData icon;
    switch (rel) {
      case 'Partner':
        bg = const Color(0xFFFFE4E6);
        text = const Color(0xFFE11D48);
        icon = Icons.favorite_rounded;
        break;
      case 'Family':
        bg = const Color(0xFFF3E8FF);
        text = const Color(0xFF7C3AED);
        icon = Icons.family_restroom_rounded;
        break;
      case 'Friend':
      default:
        bg = const Color(0xFFE0F2FE);
        text = const Color(0xFF0284C7);
        icon = Icons.people_alt_rounded;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: text),
          const SizedBox(width: 3),
          Text(
            rel,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: text),
          ),
        ],
      ),
    );
  }

  Future<Position> _getPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw Exception('Turn on device location services to continue.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied) {
      throw Exception('Location permission was not granted.');
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location permission is permanently blocked. Enable it in Settings.');
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: LocationTrackingConfig.singleFixTimeLimit,
      ),
    );
  }

  Future<void> _locate() async {
    setState(() => _busy = true);
    try {
      final position = await _getPosition();
      final point = LatLng(position.latitude, position.longitude);
      KaSpotService.lastUserLatitude = position.latitude;
      KaSpotService.lastUserLongitude = position.longitude;

      if (_sharing) {
        await KaSpotService.upsertOwnLocation(position);
      }

      if (mounted) {
        setState(() {
          _myPoint = point;
        });
        _map.move(point, 16.0);
        _notify(
          _sharing
              ? 'Centered on your location · sharing is active'
              : 'Centered on your location · sharing is paused',
        );
      }
      await _refresh();
    } catch (e) {
      if (mounted) _notify(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleSharing(bool enabled) async {
    setState(() => _busy = true);
    try {
      final conns = await KaSpotService.connections();
      if (enabled && conns.isEmpty) {
        if (mounted) {
          setState(() => _sharing = false);
          _notify('No Circle members yet. Add someone in the Circle tab to share your location.');
        }
        return;
      }
      final position = enabled ? await _getPosition() : null;
      await KaSpotService.setSharingForAll(enabled);
      if (enabled && position != null) {
        await KaSpotService.upsertOwnLocation(position);
        if (mounted) {
          setState(() {
            _myPoint = LatLng(position.latitude, position.longitude);
            _sharing = true;
          });
        }
      } else {
        if (mounted) setState(() => _sharing = enabled);
      }

      if (mounted) {
        _notify(enabled
            ? 'Live location sharing is on for your circle.'
            : 'Location sharing paused. Your position is hidden.');
      }
      await _refresh();
    } catch (e) {
      if (mounted) _notify(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notify(String text) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _showMapStyleSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      backgroundColor: Colors.white,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFCBD5E1),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.layers_rounded, color: Color(0xFF1E60AA), size: 24),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Map style',
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Choose how the map looks',
                            style: TextStyle(fontSize: 12.5, color: Color(0xFF64748B)),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _mapStyleOption(
                  sheetContext: sheetContext,
                  mode: _MapLayerMode.standard,
                  icon: Icons.map_rounded,
                  title: 'Standard Map',
                  subtitle: 'Street map with labels',
                ),
                const SizedBox(height: 10),
                _mapStyleOption(
                  sheetContext: sheetContext,
                  mode: _MapLayerMode.satellite,
                  icon: Icons.satellite_alt_rounded,
                  title: 'Satellite',
                  subtitle: 'Real-world satellite imagery',
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _mapStyleOption({
    required BuildContext sheetContext,
    required _MapLayerMode mode,
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final selected = _layerMode == mode;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        setState(() => _layerMode = mode);
        Navigator.pop(sheetContext);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFEFF6FF) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? const Color(0xFF1E60AA) : const Color(0xFFE2E8F0),
            width: selected ? 1.6 : 1.2,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: selected ? Colors.white : const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Icon(icon, size: 20, color: const Color(0xFF1E60AA)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: Color(0xFF0F172A)),
                  ),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle_rounded, color: Color(0xFF1E60AA), size: 22),
          ],
        ),
      ),
    );
  }

  void _showSharingOptionsSheet() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      backgroundColor: Colors.white,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFCBD5E1),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0xFFEFF6FF),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.share_location_rounded, color: Color(0xFF1E60AA), size: 24),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Location Sharing Options',
                                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
                              ),
                              SizedBox(height: 2),
                              Text(
                                'Control how and when your circle sees you',
                                style: TextStyle(fontSize: 12.5, color: Color(0xFF64748B)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Column(
                        children: [
                          SwitchListTile.adaptive(
                            title: const Text('Live Sharing', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
                            subtitle: const Text('Share your location with authorized circle members', style: TextStyle(fontSize: 12)),
                            value: _sharing,
                            activeThumbColor: const Color(0xFF1E60AA),
                            onChanged: (val) async {
                              Navigator.pop(sheetContext);
                              await _toggleSharing(val);
                            },
                          ),
                          const Divider(height: 1, indent: 16, endIndent: 16),
                          ListenableBuilder(
                            listenable: Listenable.merge([
                              BackgroundLocationService.isBackgroundSharingEnabled,
                              BackgroundLocationService.state,
                            ]),
                            builder: (context, _) {
                              final bgEnabled =
                                  BackgroundLocationService.isBackgroundSharingEnabled.value;
                              return SwitchListTile.adaptive(
                                title: const Text('Background Sharing', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14.5)),
                                // Spelled out from the values the service really
                                // applies, and never claimed as a guarantee.
                                subtitle: Text(
                                  bgEnabled
                                      ? BackgroundLocationService.describeState()
                                      : 'Keep updating after you leave KaSpot: asks for a fix '
                                          'about every ${LocationTrackingConfig.streamInterval.inSeconds} s '
                                          'once you have moved ${LocationTrackingConfig.distanceFilterMeters} m',
                                  style: const TextStyle(fontSize: 12),
                                ),
                                value: bgEnabled,
                                activeThumbColor: const Color(0xFF10B981),
                                onChanged: (val) async {
                                  Navigator.pop(sheetContext);
                                  if (val) {
                                    final confirmed = await ProfileScreen.showBackgroundConsentDialog(this.context);
                                    if (confirmed == true) {
                                      try {
                                        await BackgroundLocationService.startBackgroundTracking();
                                        if (mounted) {
                                          _notify('Background location sharing enabled.');
                                        }
                                      } catch (e) {
                                        if (mounted) {
                                          _notify(e.toString().replaceFirst('Exception: ', ''));
                                        }
                                      }
                                    }
                                  } else {
                                    await BackgroundLocationService.stopBackgroundTracking();
                                    if (mounted) {
                                      _notify('Background sharing stopped. Location only updates while app is open.');
                                    }
                                  }
                                },
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.shield_outlined, size: 20, color: Color(0xFF64748B)),
                          SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Zero-Trail Privacy: KaSpot only keeps your latest coordinate and never stores historical movement tracks.',
                              style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Markers: friend pins first (lower Z), own beacon last (always on top).
    // flutter_map renders markers in list order using a Stack, so later entries
    // paint over earlier ones. Own marker must be last so it is never hidden
    // when two devices are at the same coordinate.
    final markers = <Marker>[
      ..._shared.map((item) {
        final recorded = DateTime.tryParse(item['recorded_at'] as String? ?? '')?.toLocal();
        // A member is only flagged inactive once they are well past the
        // stationary heartbeat window — see LocationTrackingConfig.
        final stale = recorded == null ||
            DateTime.now().difference(recorded) > LocationTrackingConfig.markerStaleAfter;
        final name = (item['display_name'] as String? ?? 'Friend').split(' ').first;
        final point = LatLng(
          (item['latitude'] as num).toDouble(),
          (item['longitude'] as num).toDouble(),
        );

        return Marker(
          point: point,
          width: 48,
          height: 54,
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onTap: () => _showPersonDetails(item, stale),
            child: _FriendLocationPin(
              name: name,
              avatarUrl: item['avatar_url'] as String?,
              color: stale ? const Color(0xFFD97706) : const Color(0xFF10B981),
            ),
          ),
        );
      }),
      // Own beacon is LAST so it paints on top of all friend markers.
      if (_myPoint != null)
        Marker(
          key: ValueKey('user-beacon-${_myAvatarUrl?.hashCode}-$_sharing'),
          point: _myPoint!,
          width: 96,
          height: 96,
          alignment: Alignment.center,
          child: _PulsingLocationBeacon(
            key: ValueKey('pulsing-beacon-$_myName-${_myAvatarUrl?.hashCode}-$_sharing'),
            name: _myName,
            avatarUrl: _myAvatarUrl,
            isSharing: _sharing,
          ),
        ),
    ];

    return Scaffold(
      body: Stack(
        children: [
          // 1. Full-screen clean Map
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _myPoint ??
                  (KaSpotService.lastUserLatitude != null && KaSpotService.lastUserLongitude != null
                      ? LatLng(KaSpotService.lastUserLatitude!, KaSpotService.lastUserLongitude!)
                      : const LatLng(14.5995, 120.9842)),
              initialZoom: _myPoint != null || KaSpotService.lastUserLatitude != null ? 16.0 : 13.0,
              minZoom: 2,
              maxZoom: 18,
              // North-locked, calm map: no two-finger twist rotation, no glide
              // after release, no two-finger pan while pinching. Single-finger
              // drag, pinch zoom and double-tap zooms remain available.
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all &
                    ~InteractiveFlag.rotate &
                    ~InteractiveFlag.flingAnimation &
                    ~InteractiveFlag.pinchMove,
              ),
            ),
            children: [
              TileLayer(
                key: ValueKey('map-layer-${_layerMode.name}'),
                urlTemplate: _layerMode == _MapLayerMode.satellite
                    ? 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'
                    : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.kaspot.kaspot',
              ),
              if (markers.isNotEmpty) MarkerLayer(markers: markers),
            ],
          ),

          // 2. Professional Grounded Top Header Bar (Full width, not a floating pill)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  color: Colors.white,
                  child: SafeArea(
                    bottom: false,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        border: Border(
                          bottom: BorderSide(color: Color(0xFFE2E8F0), width: 1),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Color(0x08000000),
                            blurRadius: 8,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        children: [
                          // Official KaSpot Brand Wordmark
                          const KaSpotWordmark(fontSize: 21),
                          const Spacer(),

                          // Option A: Unified Modern Control Capsule
                          ListenableBuilder(
                            listenable: Listenable.merge([
                              BackgroundLocationService.isBackgroundSharingEnabled,
                              BackgroundLocationService.state,
                            ]),
                            builder: (context, _) {
                              final bgActive =
                                  BackgroundLocationService.isBackgroundSharingEnabled.value;
                              final tracking = BackgroundLocationService.state.value;
                              final isOnline = _online;
                              // Honest label: nothing may read as "live" unless a
                              // position is actually being reported right now —
                              // a stored preference is not evidence of tracking.
                              final statusText = !isOnline
                                  ? 'Offline'
                                  : !_sharing
                                      ? 'Paused'
                                      : switch (tracking) {
                                          TrackingState.streaming =>
                                            bgActive ? 'Live · Bg' : 'Live',
                                          TrackingState.starting => 'Starting…',
                                          TrackingState.waitingForFix => 'Finding GPS',
                                          TrackingState.degraded => 'Not syncing',
                                          TrackingState.blockedLocationServices =>
                                            'Location off',
                                          TrackingState.blockedPermission =>
                                            'Needs permission',
                                          TrackingState.failed => 'Not reporting',
                                          TrackingState.suspendedNoSharing => 'Paused',
                                          TrackingState.off =>
                                            _myPoint != null ? 'Live' : 'Not reporting',
                                        };
                              final isLive = statusText == 'Live' || statusText == 'Live · Bg';
                              final isProblem = !isOnline ||
                                  (!isLive &&
                                      statusText != 'Paused' &&
                                      statusText != 'Starting…');
                              final dotColor = isLive
                                  ? const Color(0xFF10B981)
                                  : isProblem
                                      ? const Color(0xFFD97706)
                                      : const Color(0xFF94A3B8);
                              final textColor = isLive
                                  ? const Color(0xFF065F46)
                                  : isProblem
                                      ? const Color(0xFF92400E)
                                      : const Color(0xFF475569);
                              final capsuleBg = isLive
                                  ? const Color(0xFFECFDF5)
                                  : isProblem
                                      ? const Color(0xFFFFFBEB)
                                      : const Color(0xFFF8FAFC);
                              final capsuleBorder = isLive
                                  ? const Color(0xFFA7F3D0)
                                  : isProblem
                                      ? const Color(0xFFFDE68A)
                                      : const Color(0xFFCBD5E1);

                              return Container(
                                decoration: BoxDecoration(
                                  color: capsuleBg,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: capsuleBorder, width: 1.2),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Color(0x06000000),
                                      blurRadius: 4,
                                      offset: Offset(0, 1),
                                    ),
                                  ],
                                ),
                                child: Material(
                                  color: Colors.transparent,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      // Status trigger (1-tap toggle or long-press options)
                                      InkWell(
                                        borderRadius: const BorderRadius.horizontal(left: Radius.circular(20)),
                                        onTap: _busy ? null : () => _toggleSharing(!_sharing),
                                        onLongPress: _showSharingOptionsSheet,
                                        child: Padding(
                                          padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Container(
                                                width: 8,
                                                height: 8,
                                                decoration: BoxDecoration(
                                                  shape: BoxShape.circle,
                                                  color: dotColor,
                                                  boxShadow: isLive && _online
                                                      ? [
                                                          BoxShadow(
                                                            color: dotColor.withValues(alpha: 0.45),
                                                            blurRadius: 5,
                                                            spreadRadius: 1,
                                                          ),
                                                        ]
                                                      : null,
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Text(
                                                statusText,
                                                style: TextStyle(
                                                  fontSize: 12.5,
                                                  fontWeight: FontWeight.w800,
                                                  color: textColor,
                                                  letterSpacing: 0.1,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),

                                      // Subtle vertical hairline divider inside capsule
                                      Container(
                                        width: 1,
                                        height: 16,
                                        color: isLive && _online ? const Color(0xFFA7F3D0) : const Color(0xFFE2E8F0),
                                      ),

                                      // Animated sync button
                                      Tooltip(
                                        message: 'Sync location data',
                                        child: InkWell(
                                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(20)),
                                          onTap: _busy || _refreshing ? null : _refresh,
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                            child: RotationTransition(
                                              turns: _syncAnimController,
                                              child: Icon(
                                                Icons.sync_rounded,
                                                size: 17,
                                                color: isLive && _online ? const Color(0xFF059669) : const Color(0xFF64748B),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // Offline banner: explains that live updates are paused and
                // will sync automatically once internet returns.
                if (!_online)
                  Container(
                    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFFDE68A)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.wifi_off_rounded, size: 16, color: Color(0xFFB45309)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _sharing
                                ? "You're offline — live updates are paused. They'll send automatically when internet returns."
                                : "You're offline — showing last known positions.",
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF92400E),
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // 3. Right Floating Tools Column (Layers, Zoom & Re-center)
          Positioned(
            right: 16,
            bottom: 24,
            child: Column(
              children: [
                _FloatingToolButton(
                  icon: Icons.layers_rounded,
                  tooltip: 'Map layers',
                  onTap: _showMapStyleSheet,
                ),
                const SizedBox(height: 10),
                _FloatingToolButton(
                  icon: Icons.my_location_rounded,
                  tooltip: 'Center on my location',
                  busy: _busy,
                  color: const Color(0xFF1E60AA),
                  iconColor: Colors.white,
                  onTap: _locate,
                ),
                const SizedBox(height: 10),
                _FloatingToolButton(
                  icon: Icons.add_rounded,
                  tooltip: 'Zoom in',
                  onTap: () {
                    final zoom = _map.camera.zoom;
                    _map.move(_map.camera.center, zoom + 1);
                  },
                ),
                const SizedBox(height: 6),
                _FloatingToolButton(
                  icon: Icons.remove_rounded,
                  tooltip: 'Zoom out',
                  onTap: () {
                    final zoom = _map.camera.zoom;
                    _map.move(_map.camera.center, zoom - 1);
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showPersonDetails(Map<String, dynamic> item, bool stale) async {
    final name = item['display_name'] as String? ?? 'Friend';
    final lat = (item['latitude'] as num).toDouble();
    final lon = (item['longitude'] as num).toDouble();
    final time = DateTime.tryParse(item['recorded_at'] as String? ?? '')?.toLocal();

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                KaSpotAvatar(
                  name: name,
                  avatarUrl: item['avatar_url'] as String?,
                  size: 48,
                  isCircle: true,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              style: const TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _relationshipPill(item['relationship'] as String? ?? 'Friend'),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: stale ? const Color(0xFFD97706) : const Color(0xFF10B981),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            stale ? 'App inactive · Last seen' : 'Live · Sharing active',
                            style: TextStyle(
                              fontSize: 12,
                              color: stale ? const Color(0xFFD97706) : const Color(0xFF059669),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (time != null) ...[
                            const SizedBox(width: 6),
                            Text(
                              '· ${_formatTimeAgo(time)}',
                              style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.explore_outlined, color: Color(0xFF1E60AA), size: 20),
                  const SizedBox(width: 10),
                  Text(
                    '${lat.toStringAsFixed(4)}, ${lon.toStringAsFixed(4)}',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF334155),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () async {
                  final geoUri = Uri.parse('geo:$lat,$lon?q=$lat,$lon');
                  if (await canLaunchUrl(geoUri)) {
                    await launchUrl(geoUri);
                  } else {
                    final webUri = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lon');
                    if (await canLaunchUrl(webUri)) {
                      await launchUrl(webUri, mode: LaunchMode.externalApplication);
                    }
                  }
                },
                icon: const Icon(Icons.directions_rounded),
                label: const Text('Open in navigation app'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimeAgo(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

/// Radially-symmetric high-precision GPS beacon.
/// Perfectly centered on the exact GPS coordinate at all zoom levels (0 pixel drift).
/// High-precision pulsing GPS beacon with profile avatar and name tag.
/// Perfectly centered on the exact GPS coordinate at all zoom levels (0 pixel drift).
class _PulsingLocationBeacon extends StatefulWidget {
  const _PulsingLocationBeacon({
    super.key,
    required this.name,
    this.avatarUrl,
    this.isSharing = false,
  });

  final String name;
  final String? avatarUrl;
  final bool isSharing;

  @override
  State<_PulsingLocationBeacon> createState() => _PulsingLocationBeaconState();
}

class _PulsingLocationBeaconState extends State<_PulsingLocationBeacon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    // Calming 3200ms heartbeat cycle (~19 BPM relaxed cardiac cadence)
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  /// Cardiac double-thump (Lub-Dub) heartbeat scale curve
  double _getHeartbeatScale(double t) {
    // 1. First thump (Lub)
    if (t < 0.07) {
      return 1.0 + (t / 0.07) * 0.08;
    } else if (t < 0.14) {
      return 1.08 - ((t - 0.07) / 0.07) * 0.08;
    }
    // Brief interval
    else if (t < 0.18) {
      return 1.0;
    }
    // 2. Second thump (Dub)
    else if (t < 0.25) {
      return 1.0 + ((t - 0.18) / 0.07) * 0.05;
    } else if (t < 0.32) {
      return 1.05 - ((t - 0.25) / 0.07) * 0.05;
    }
    // 3. Resting relaxation phase
    return 1.0;
  }

  /// Emitted wave expansion progress with smooth cubic ease-out
  double _getWaveProgress(double t, double startOffset, double totalSpan) {
    if (t < startOffset) return 0.0;
    final elapsed = (t - startOffset) / totalSpan;
    if (elapsed >= 1.0) return 1.0;
    return Curves.easeOutCubic.transform(elapsed);
  }

  @override
  Widget build(BuildContext context) {
    final displayName = widget.name.isNotEmpty ? widget.name : 'You';
    final pulseColor = widget.isSharing ? const Color(0xFF10B981) : const Color(0xFF2196F3);

    return SizedBox(
      width: 96,
      height: 96,
      child: AnimatedBuilder(
        animation: _pulseController,
        builder: (context, _) {
          final t = _pulseController.value;
          final avatarScale = _getHeartbeatScale(t);
          final wave1 = _getWaveProgress(t, 0.0, 0.85);
          final wave2 = _getWaveProgress(t, 0.18, 0.77);

          return Stack(
            alignment: Alignment.center,
            clipBehavior: Clip.none,
            children: [
              // 1. Heartbeat Radar Waves (First & Second Beat Ripples)
              _buildPulseRing(wave1, pulseColor, maxOpacity: 0.38),
              _buildPulseRing(wave2, pulseColor, maxOpacity: 0.28),

              // 2. Profile Avatar Circle with Rhythmic Heartbeat Thump
              Transform.scale(
                scale: avatarScale,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x35000000),
                        blurRadius: 10,
                        offset: Offset(0, 3),
                      ),
                    ],
                  ),
                  child: KaSpotAvatar(
                    key: ValueKey('beacon-avatar-${widget.avatarUrl?.hashCode}'),
                    name: displayName,
                    avatarUrl: widget.avatarUrl,
                    size: 44,
                    isCircle: true,
                    showBorder: true,
                    borderColor: Colors.white,
                    borderWidth: 3.5,
                  ),
                ),
              ),

              // 3. Live Beacon Status Dot (Bottom-Right of Avatar)
              Positioned(
                right: 25,
                bottom: 25,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.isSharing ? const Color(0xFF10B981) : const Color(0xFF2196F3),
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x30000000),
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ),

              // 4. Name Tag Capsule Badge (Positioned directly above Avatar)
              Positioned(
                top: 2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFFE2E8F0), width: 1),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x20000000),
                        blurRadius: 6,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 5,
                        height: 5,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.isSharing ? const Color(0xFF10B981) : const Color(0xFF2196F3),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        displayName,
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          letterSpacing: -0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPulseRing(double progress, Color color, {double maxOpacity = 0.38}) {
    if (progress <= 0.0 || progress >= 1.0) return const SizedBox.shrink();
    final size = 44.0 + (progress * 48.0);
    final opacity = (1.0 - progress).clamp(0.0, 1.0) * maxOpacity;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: opacity * 0.5),
        border: Border.all(
          color: color.withValues(alpha: opacity),
          width: 1.5,
        ),
      ),
    );
  }
}

/// Member pin with needle tip pointing at the exact coordinate
class _FriendLocationPin extends StatelessWidget {
  const _FriendLocationPin({
    required this.name,
    this.avatarUrl,
    required this.color,
  });

  final String name;
  final String? avatarUrl;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2.5),
            boxShadow: const [
              BoxShadow(color: Color(0x28000000), blurRadius: 6, offset: Offset(0, 2)),
            ],
          ),
          child: ClipOval(
            child: KaSpotAvatar(
              name: name,
              avatarUrl: avatarUrl,
              size: 34,
              isCircle: true,
            ),
          ),
        ),
        Icon(Icons.arrow_drop_down, color: color, size: 18),
      ],
    );
  }
}

class _FloatingToolButton extends StatelessWidget {
  const _FloatingToolButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.color = Colors.white,
    this.iconColor = const Color(0xFF334155),
    this.busy = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final Color color;
  final Color iconColor;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color,
      elevation: 3,
      shadowColor: const Color(0x20000000),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: busy ? null : onTap,
        customBorder: const CircleBorder(),
        child: Tooltip(
          message: tooltip ?? '',
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            child: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Icon(icon, color: iconColor, size: 21),
          ),
        ),
      ),
    );
  }
}
