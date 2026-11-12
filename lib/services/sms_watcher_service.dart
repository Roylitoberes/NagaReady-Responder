// services/sms_watcher_service.dart
//
// Watches the phone's SMS inbox while the app is open and detects NEW
// emergency SMS (e.g. the NagaReady citizen app's SMS fallback) in near
// real time. It only reads a few of the newest messages each time, so it is
// light on memory and will not close or restart the app.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:permission_handler/permission_handler.dart';

import 'sms_firebase_service.dart';

class SmsWatcherService with WidgetsBindingObserver {
  SmsWatcherService._();
  static final SmsWatcherService instance = SmsWatcherService._();

  /// How often the inbox is checked while the app is in the foreground.
  static const Duration _interval = Duration(seconds: 5);

  /// How many of the newest inbox messages are checked each time.
  static const int _peekCount = 20;

  final SmsQuery _query = SmsQuery();

  /// Increases every time a NEW emergency SMS is detected.
  /// Screens (like the Notifications modal) listen to this to refresh.
  final ValueNotifier<int> newEmergencyCount = ValueNotifier<int>(0);

  final Set<String> _seen = <String>{};
  Timer? _timer;
  bool _started = false;
  bool _busy = false;
  bool _baselineDone = false;

  // ------------------------------------------------------------
  // START / STOP
  // ------------------------------------------------------------
  void start() {
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
    debugPrint('📡 SMS watcher started');
  }

  void stop() {
    if (!_started) return;
    _started = false;
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
    _seen.clear();
    _baselineDone = false;
    debugPrint('📡 SMS watcher stopped');
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_interval, (_) => _poll());
    _poll(); // check right away
  }

  // Pause while the app is in the background, check immediately on return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started) return;
    if (state == AppLifecycleState.resumed) {
      _startTimer();
    } else if (state == AppLifecycleState.paused) {
      _timer?.cancel();
      _timer = null;
    }
  }

  // ------------------------------------------------------------
  // POLL THE INBOX
  // ------------------------------------------------------------
  Future<void> _poll() async {
    if (_busy) return;
    _busy = true;

    try {
      // Only CHECK the permission here. HomePage is the one that asks for it,
      // so two permission requests never run at the same time.
      final status = await Permission.sms.status;
      if (!status.isGranted) return;

      final fetched = await _query.querySms(
        kinds: [SmsQueryKind.inbox],
        count: _peekCount,
      );

      final fresh = <SmsMessage>[];
      final freshKeys = <String>[];

      for (final sms in fetched) {
        final key = _keyOf(sms);
        final isNew = _seen.add(key);
        if (isNew && _baselineDone && _isEmergency(sms.body ?? '')) {
          fresh.add(sms);
          freshKeys.add(key);
        }
      }

      // The very first check only records what is already in the inbox
      // (HomePage's auto-sync handles those old messages).
      _baselineDone = true;

      if (fresh.isEmpty) return;

      debugPrint('📩 ${fresh.length} NEW emergency SMS detected');

      // Tell open screens right away so the list updates instantly.
      newEmergencyCount.value++;

      try {
        await SmsFirebaseService.saveEmergencySmsBatch(fresh);
      } catch (e) {
        debugPrint('❌ Watcher sync failed: $e');
        // Forget them so they are retried on the next check.
        _seen.removeAll(freshKeys);
      }
    } catch (e) {
      // Never let a read error close the app.
      debugPrint('⚠️ SMS watcher error: $e');
    } finally {
      _busy = false;
    }
  }

  String _keyOf(SmsMessage sms) {
    final ts = sms.date?.millisecondsSinceEpoch ?? 0;
    return '${ts}_${(sms.address ?? '').hashCode}_${(sms.body ?? '').hashCode}';
  }

  /// Detects emergency SMS in BOTH the React app format
  /// ([MED], [FIRE], [CRIME], [ACC], [FLOOD], [OTHER]) and legacy phrases.
  bool _isEmergency(String body) {
    final text = body.toUpperCase();
    return text.contains('[MED]') ||
        text.contains('[FIRE]') ||
        text.contains('[CRIME]') ||
        text.contains('[ACC]') ||
        text.contains('[FLOOD]') ||
        text.contains('[OTHER]') ||
        text.contains('[MEDICAL]') ||
        text.contains('[ACCIDENT]') ||
        text.contains('[EMERGENCY]') ||
        text.contains('MEDICAL EMERGENCY') ||
        text.contains('FIRE EMERGENCY') ||
        text.contains('ACCIDENT') ||
        text.contains('FLOODING') ||
        text.contains('CRIME') ||
        text.contains('EMERGENCY ALERT');
  }
}