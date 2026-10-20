import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/in_app_notification_service.dart';
import '../services/kaspot_service.dart';
import '../widgets/in_app_notification_banner.dart';
import '../widgets/interactive_nav_bar.dart';
import 'circle_chat_screen.dart';
import 'connections_screen.dart';
import 'map_screen.dart';
import 'places_screen.dart';
import 'profile_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _selected = 0;
  RealtimeChannel? _msgChannel;

  @override
  void initState() {
    super.initState();
    _subscribeNotifications();
  }

  void _subscribeNotifications() {
    if (!KaSpotService.isConfigured) return;
    final myId = KaSpotService.userId;
    if (myId.isEmpty) return;

    final channel = KaSpotService.client!.channel('kaspot-inapp-$myId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'circle_messages',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'recipient_id',
          value: myId,
        ),
        callback: (payload) async {
          final newRecord = payload.newRecord;
          final senderId = newRecord['sender_id'] as String?;
          final content = newRecord['content'] as String? ?? '';
          if (senderId == null || senderId == myId) return;

          // If the user is currently viewing this conversation, the chat screen
          // immediately displays it and marks it read. Suppress badge increment and banner.
          if (KaSpotService.activeChatUserId == senderId) return;

          // Always increment the unread counter so badge stays accurate even
          // when the user is on a different tab or the in-app banner is missed.
          KaSpotService.incrementUnread(senderId);

          final prefs = await KaSpotService.notificationPreferences();
          if (prefs['connection_notifications_enabled'] == false) return;

          final conns = await KaSpotService.connections();
          final sender = conns.firstWhere(
            (c) => c['other_id'] == senderId,
            orElse: () => <String, dynamic>{},
          );
          final senderName = sender['display_name'] as String? ?? 'Circle Member';
          final rel = sender['relationship'] as String? ?? 'Friend';
          final avatar = sender['avatar_url'] as String?;

          InAppNotificationService.show(InAppNotificationPayload(
            id: 'msg-${newRecord['id'] ?? DateTime.now().millisecondsSinceEpoch}',
            type: InAppNotificationType.chat,
            title: '$rel · $senderName',
            body: content,
            avatarUrl: avatar,
            relationship: rel,
            senderId: senderId,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => CircleChatScreen(
                    otherId: senderId,
                    displayName: senderName,
                    avatarUrl: avatar,
                  ),
                ),
              );
            },
          ));
        },
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'connection_requests',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'recipient_id',
          value: myId,
        ),
        callback: (payload) async {
          final prefs = await KaSpotService.notificationPreferences();
          if (prefs['connection_notifications_enabled'] == false) return;

          InAppNotificationService.show(InAppNotificationPayload(
            id: 'req-${DateTime.now().millisecondsSinceEpoch}',
            type: InAppNotificationType.request,
            title: '👋 New Circle Invitation',
            body: 'Someone sent you an invitation to join their circle',
            onTap: () {
              if (mounted) setState(() => _selected = 1);
            },
          ));
        },
      );

    _msgChannel = channel;
    channel.subscribe();
  }

  @override
  void dispose() {
    final ch = _msgChannel;
    if (ch != null && KaSpotService.isConfigured) {
      unawaited(KaSpotService.client!.removeChannel(ch));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      const MapScreen(key: ValueKey('tab_map')),
      const ConnectionsScreen(key: ValueKey('tab_connections')),
      const PlacesScreen(key: ValueKey('tab_places')),
      const ProfileScreen(key: ValueKey('tab_profile')),
    ];

    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _selected,
            children: screens,
          ),
          const InAppNotificationBanner(),
        ],
      ),
      bottomNavigationBar: ValueListenableBuilder<Map<String, int>>(
        valueListenable: KaSpotService.unreadCounts,
        builder: (context, counts, _) {
          final totalUnread = counts.values.fold(0, (s, n) => s + n);
          return InteractiveNavBar(
            selectedIndex: _selected,
            onTap: (index) => setState(() => _selected = index),
            items: [
              const InteractiveNavItem(
                icon: Icons.explore_outlined,
                selectedIcon: Icons.explore_rounded,
                label: 'Map',
              ),
              InteractiveNavItem(
                icon: Icons.people_outline_rounded,
                selectedIcon: Icons.people_rounded,
                label: 'Circle',
                badgeCount: totalUnread,
              ),
              const InteractiveNavItem(
                icon: Icons.place_outlined,
                selectedIcon: Icons.place_rounded,
                label: 'Places',
              ),
              const InteractiveNavItem(
                icon: Icons.person_outline_rounded,
                selectedIcon: Icons.person_rounded,
                label: 'You',
              ),
            ],
          );
        },
      ),
    );
  }
}

