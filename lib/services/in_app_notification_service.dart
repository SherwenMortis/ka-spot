import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

enum InAppNotificationType { chat, arrival, request, generic }

class InAppNotificationPayload {
  final String id;
  final InAppNotificationType type;
  final String title;
  final String body;
  final String? avatarUrl;
  final String? relationship;
  final String? senderId;
  final VoidCallback? onTap;
  final DateTime timestamp;

  InAppNotificationPayload({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    this.avatarUrl,
    this.relationship,
    this.senderId,
    this.onTap,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

class InAppNotificationService {
  InAppNotificationService._();

  static final ValueNotifier<InAppNotificationPayload?> activeNotification =
      ValueNotifier<InAppNotificationPayload?>(null);

  static Timer? _dismissTimer;

  /// Cache of places a member is currently inside: memberId -> `Set<placeId>`
  static final Map<String, Set<String>> _memberInsidePlaces = {};

  static void show(InAppNotificationPayload payload) {
    _dismissTimer?.cancel();
    activeNotification.value = payload;
    _dismissTimer = Timer(const Duration(milliseconds: 4500), () {
      dismiss();
    });
  }

  static void dismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    activeNotification.value = null;
  }

  /// Dismisses any active in-app banner for [senderId].
  static void dismissForSender(String senderId) {
    final active = activeNotification.value;
    if (active != null && (active.senderId == senderId || active.id.contains(senderId))) {
      dismiss();
    }
  }

  /// Evaluates member coordinates against saved places and fires an in-app
  /// arrival alert if a member enters within 120m of a place.
  static void checkMemberArrivals({
    required List<Map<String, dynamic>> sharedMembers,
    required List<Map<String, dynamic>> savedPlaces,
    required bool arrivalAlertsEnabled,
    void Function(Map<String, dynamic> member, Map<String, dynamic> place)? onArrivalTap,
  }) {
    if (!arrivalAlertsEnabled || savedPlaces.isEmpty) return;

    const distanceCalculator = Distance();

    for (final member in sharedMembers) {
      final memberId = (member['user_id'] ?? member['other_id']) as String?;
      final lat = (member['latitude'] as num?)?.toDouble();
      final lon = (member['longitude'] as num?)?.toDouble();
      if (memberId == null || lat == null || lon == null) continue;

      final memberLoc = LatLng(lat, lon);
      final inside = _memberInsidePlaces.putIfAbsent(memberId, () => <String>{});

      for (final place in savedPlaces) {
        final placeId = place['id'] as String?;
        final pLat = (place['latitude'] as num?)?.toDouble();
        final pLon = (place['longitude'] as num?)?.toDouble();
        final placeName = place['name'] as String? ?? 'Saved Place';
        if (placeId == null || pLat == null || pLon == null) continue;

        final placeLoc = LatLng(pLat, pLon);
        final meters = distanceCalculator.as(LengthUnit.Meter, memberLoc, placeLoc);

        if (meters <= 120.0) {
          // Member is inside the place radius
          if (!inside.contains(placeId)) {
            inside.add(placeId);

            final name = member['display_name'] as String? ?? 'Circle Member';
            final rel = member['relationship'] as String? ?? 'Friend';
            final avatar = member['avatar_url'] as String?;

            show(InAppNotificationPayload(
              id: 'arr-$memberId-$placeId-${DateTime.now().millisecondsSinceEpoch}',
              type: InAppNotificationType.arrival,
              title: '📍 $rel Arrival Alert',
              body: '$name arrived at $placeName',
              avatarUrl: avatar,
              relationship: rel,
              onTap: onArrivalTap != null ? () => onArrivalTap(member, place) : null,
            ));
          }
        } else if (meters > 250.0) {
          // Member moved outside radius (hysteresis buffer avoids jitter)
          inside.remove(placeId);
        }
      }
    }
  }

  @visibleForTesting
  static void resetGeofenceState() {
    _memberInsidePlaces.clear();
    dismiss();
  }
}
