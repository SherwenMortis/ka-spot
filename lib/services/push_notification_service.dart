import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'kaspot_service.dart';
import 'notification_navigation.dart';

/// Encodes the routing payload attached to a chat notification so a tap can be
/// resolved back to the correct conversation. Sender/message IDs are UUIDs and
/// never contain '|', so a simple delimiter is safe.
String encodeChatNotificationPayload(String senderId, String? messageId) =>
    '$senderId|${messageId ?? ''}';

/// Decodes a payload produced by [encodeChatNotificationPayload]. Returns null
/// if the payload is not a chat routing payload.
({String senderId, String? messageId})? decodeChatNotificationPayload(
    String? payload) {
  if (payload == null || !payload.contains('|')) return null;
  final parts = payload.split('|');
  final senderId = parts.first;
  if (senderId.isEmpty) return null;
  final messageId = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : null;
  return (senderId: senderId, messageId: messageId);
}

const _kChannelId = 'kaspot_messages';
const _kChannelName = 'Circle Messages';
const _kChannelDesc = 'Notifications for new messages from your circle';

const _kAndroidChannel = AndroidNotificationChannel(
  _kChannelId,
  _kChannelName,
  description: _kChannelDesc,
  importance: Importance.high,
  playSound: true,
);

/// Builds the notification details for a chat message from [senderId]. The
/// Android tag is included here (not on `show`) so that `cancel(id, tag)` can
/// later match and remove the exact notification that was posted. The tag comes
/// from [PushNotificationService.tagForSender] so posting and cancelling can
/// never drift apart.
NotificationDetails chatNotificationDetails(String senderId) =>
    NotificationDetails(
      android: AndroidNotificationDetails(
        _kChannelId,
        _kChannelName,
        channelDescription: _kChannelDesc,
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
        playSound: true,
        enableVibration: true,
        tag: PushNotificationService.tagForSender(senderId),
      ),
    );

/// Top-level handler required by Firebase for messages received while
/// the app is in the background or fully terminated.
/// Must be a top-level (non-class) function annotated with `vm:entry-point`.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  // Firebase is already initialised by the time this runs, but we call
  // ensureInitialized defensively in case the isolate is fresh.
  await Firebase.initializeApp();

  final data = message.data;
  if (data['type'] != 'circle_message') return;

  // Transitional safety: the server still sends a legacy OS-rendered
  // `notification` payload to builds that have not reported the data-only
  // capability. If such a message ever reaches this handler, the notification
  // bar is already drawn by the OS, so rendering here would duplicate both the
  // notification and its sound.
  if (message.notification != null) return;

  final senderId = data['sender_id'] as String?;
  if (senderId == null || senderId.isEmpty) return;

  // In a background/terminated data-only delivery nothing is shown by the OS,
  // so we display it here through a dedicated plugin instance. The channel is
  // created first so the notification uses KaSpot's sound-enabled channel even
  // when the app process was never started.
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );
  await plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_kAndroidChannel);

  final messageId = data['message_id'] as String?;
  final title = data['title'] as String? ?? 'New message';
  final body = data['body'] as String? ?? '';

  await plugin.show(
    PushNotificationService.notificationIdForSender(senderId),
    title,
    body,
    chatNotificationDetails(senderId),
    payload: encodeChatNotificationPayload(senderId, messageId),
  );
}

class PushNotificationService {
  PushNotificationService._();

  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static bool _listenersRegistered = false;

  /// Initialise Firebase, request permission, configure the local notification
  /// channel, register tap callbacks, and register the device token with
  /// Supabase. Safe to call multiple times: FCM/plugin listeners are only
  /// attached once (preventing duplicate notifications/sounds), while the token
  /// is refreshed on every call (e.g. after sign-in).
  static Future<void> initialize() async {
    // 1. Register the top-level background message handler.
    FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

    // 2. Create the Android notification channel (required on Android 8+).
    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_kAndroidChannel);

    // 3. Initialise flutter_local_notifications for tap handling + display.
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _localNotifications.initialize(
      const InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: _onLocalNotificationResponse,
    );

    // 4. Ask Android 13+ / iOS for notification permission.
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    debugPrint('[FCM] Permission: ${settings.authorizationStatus}');

    // Only wire the (potentially multiple) streams/callbacks once.
    if (!_listenersRegistered) {
      _listenersRegistered = true;

      // 5. Foreground: a data-only message arrives here. Show a single local
      //    notification (the OS does not display data-only messages itself).
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        final data = message.data;
        if (data['type'] != 'circle_message') return;
        final senderId = data['sender_id'] as String?;
        if (senderId == null || senderId.isEmpty) return;

        // If the user is actively viewing this conversation, the chat screen
        // shows the message and marks it read — suppress the redundant system
        // alert (and its sound).
        if (KaSpotService.activeChatUserId == senderId) return;

        final messageId = data['message_id'] as String?;
        _localNotifications.show(
          notificationIdForSender(senderId),
          data['title'] as String? ?? 'New message',
          data['body'] as String? ?? '',
          chatNotificationDetails(senderId),
          payload: encodeChatNotificationPayload(senderId, messageId),
        );
      });

      // 6. App in background resumed by tapping an FCM notification message
      //    (legacy / non-chat notification types). Chat notifications now come
      //    through the local-notification tap path above.
      FirebaseMessaging.onMessageOpenedApp.listen(_onRemoteMessageOpened);

      // 7. App cold-started by tapping an FCM notification message.
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        _onRemoteMessageOpened(initialMessage);
      }

      // 8. App cold-started by tapping one of our local notifications.
      final launchDetails =
          await _localNotifications.getNotificationAppLaunchDetails();
      if (launchDetails?.didNotificationLaunchApp ?? false) {
        _onLocalNotificationResponse(launchDetails!.notificationResponse);
      }

      // Re-register whenever FCM rotates the token. Registered inside the guard
      // so repeated initialize() calls (one per auth change) cannot pile up
      // listeners and issue duplicate registrations.
      messaging.onTokenRefresh.listen((newToken) {
        unawaited(KaSpotService.registerFcmToken(newToken));
      });
    }

    // 9. Register (or refresh) the FCM token with Supabase.
    await _registerToken();
  }

  static void _onRemoteMessageOpened(RemoteMessage message) {
    final data = message.data;
    if (data['type'] != 'circle_message') return;
    final senderId = data['sender_id'] as String?;
    if (senderId == null || senderId.isEmpty) return;
    NotificationNavigation.route(senderId, messageId: data['message_id'] as String?);
  }

  static void _onLocalNotificationResponse(NotificationResponse? response) {
    final decoded = decodeChatNotificationPayload(response?.payload);
    if (decoded == null) return;
    NotificationNavigation.route(decoded.senderId, messageId: decoded.messageId);
  }

  /// Calculates a stable, non-negative 31-bit notification ID for a sender.
  /// Uses an FNV-1a hash over the code units so the value is deterministic
  /// across isolates and app runs — required so cancel() targets the same
  /// notification that show() posted.
  static int notificationIdForSender(String senderId) {
    var h = 0x811c9dc5;
    for (final code in senderId.codeUnits) {
      h ^= code & 0xff;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h & 0x7FFFFFFF;
  }

  /// Returns the Android notification tag used when posting a notification for
  /// [senderId]. Must match the tag passed to cancel() — Android requires the
  /// same (id, tag) pair that was used when posting.
  static String tagForSender(String senderId) => 'sender_$senderId';

  /// Clears OS notification tray items associated with [senderId].
  ///
  /// Because chat notifications are now app-managed local notifications, we
  /// always know the exact (id, tag) pair used to post them, so this reliably
  /// removes the notification from the tray. Android requires the same tag that
  /// was used when posting; without it `cancel(id)` silently does nothing.
  static Future<void> clearNotificationsForSender(String senderId) async {
    try {
      await _localNotifications
          .cancel(notificationIdForSender(senderId), tag: tagForSender(senderId));
    } catch (e) {
      debugPrint(
          '[PushNotificationService] Failed to cancel notification for sender $senderId: $e');
    }
  }

  /// Clears all local notifications currently in the tray.
  static Future<void> clearAll() async {
    try {
      await _localNotifications.cancelAll();
    } catch (e) {
      debugPrint('[PushNotificationService] Failed to clear all notifications: $e');
    }
  }

  static Future<void> _registerToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.isNotEmpty) {
        await KaSpotService.registerFcmToken(token);
        debugPrint('[FCM] Token registered.');
      }
    } catch (e) {
      debugPrint('[FCM] Token registration failed: $e');
    }
  }
}

// Tap routing lives in [NotificationNavigation] (see notification_navigation.dart).
