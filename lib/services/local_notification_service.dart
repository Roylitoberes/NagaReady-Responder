
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class LocalNotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  static const AndroidNotificationChannel _channel =
      AndroidNotificationChannel(
    'incident_alerts_v2',
    'Incident Alerts',
    description: 'Emergency incident assignments',
    importance: Importance.max,
    playSound: true,
    enableVibration: true,
  );

  static Future<void> init() async {
    if (_initialized) {
      debugPrint('ℹ️ LocalNotificationService already initialized');
      return;
    }

    const androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    try {
      final ok = await _plugin.initialize(
        const InitializationSettings(
          android: androidInit,
          iOS: iosInit,
        ),
      );

      debugPrint('✅ plugin.initialize returned: $ok');
    } catch (e) {
      debugPrint('❌ plugin.initialize FAILED: $e');
      return;
    }

    // Request normal notification permission (Android 13+)
    try {
      final status = await Permission.notification.request();

      debugPrint('🔔 Notification permission status: $status');

      if (!status.isGranted) {
        debugPrint(
          '⚠️ Notification permission denied — '
          'user must enable it in Settings',
        );
      }
    } catch (e) {
      debugPrint('⚠️ Permission.notification FAILED: $e');
    }

    // Create Android notification channel
    try {
      final androidImpl = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

      if (androidImpl == null) {
        debugPrint('❌ androidImpl is null — not running on Android?');
      } else {
        await androidImpl.createNotificationChannel(_channel);

        debugPrint('✅ Channel "${_channel.id}" created');

        final enabled = await androidImpl.areNotificationsEnabled();

        debugPrint('🔔 areNotificationsEnabled: $enabled');
      }
    } catch (e) {
      debugPrint('⚠️ createNotificationChannel FAILED: $e');
    }

    // Full-screen intent permission request REMOVED.
    // Normal notifications will continue working.

    _initialized = true;

    debugPrint('✅ LocalNotificationService READY');
  }

  // Incident notification
  static Future<void> showIncidentNotification({
    required String id,
    required String type,
    required String location,
    String? unitName,
  }) async {
    debugPrint(
      '🔔 showIncidentNotification called for '
      '$id ($type @ $location)',
    );

    final androidDetails = AndroidNotificationDetails(
      _channel.id,
      _channel.name,
      channelDescription: _channel.description,
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.alarm,
      fullScreenIntent: false,
      ticker: 'New $type incident',
      styleInformation: BigTextStyleInformation(
        '$type at $location'
        '${unitName != null ? '\nUnit: $unitName' : ''}',
        contentTitle: '🚨 New Incident: $type',
        summaryText: 'Naga-Ready Dispatch',
      ),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    try {
      await _plugin.show(
        id.hashCode,
        '🚨 New Incident: $type',
        '$location${unitName != null ? ' • $unitName' : ''}',
        NotificationDetails(
          android: androidDetails,
          iOS: iosDetails,
        ),
        payload: id,
      );

      debugPrint('✅ show() completed for $id');
    } catch (e) {
      debugPrint('❌ show() FAILED for $id: $e');
    }
  }

  // EOC message notification
  static Future<void> showMessageNotification({
    required String id,
    required String subject,
    required String from,
    String? preview,
  }) async {
    debugPrint('🔔 showMessageNotification called for $id');

    final androidDetails = AndroidNotificationDetails(
      _channel.id,
      _channel.name,
      channelDescription: _channel.description,
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      ticker: 'New EOC message',
      styleInformation: BigTextStyleInformation(
        preview ?? subject,
        contentTitle: '📬 New EOC Message',
        summaryText: from,
      ),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    try {
      await _plugin.show(
        id.hashCode,
        '📬 New EOC Message',
        '$subject${from.isNotEmpty ? ' • $from' : ''}',
        NotificationDetails(
          android: androidDetails,
          iOS: iosDetails,
        ),
        payload: id,
      );

      debugPrint('✅ showMessageNotification completed for $id');
    } catch (e) {
      debugPrint('❌ showMessageNotification FAILED: $e');
    }
  }

  // Test notification
  static Future<void> showTestNotification() async {
    debugPrint('🧪 Sending TEST notification...');

    await showIncidentNotification(
      id: 'test-${DateTime.now().millisecondsSinceEpoch}',
      type: 'TEST Fire',
      location: 'TEST — Naga City',
      unitName: 'TEST Unit',
    );
  }
}
