// notification_modal.dart
import 'package:flutter/material.dart';
import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';

import '../services/sms_firebase_service.dart';
import '../services/sms_watcher_service.dart';

class NotificationModal extends StatefulWidget {
  const NotificationModal({super.key});

  @override
  State<NotificationModal> createState() => _NotificationModalState();
}

class _NotificationModalState extends State<NotificationModal> {
  final SmsQuery _smsQuery = SmsQuery();

  List<SmsMessage> _smsMessages = [];

  bool _isLoading = true;
  String? _errorMessage;

  // ✅ prevents two reads / permission requests running at the same time
  bool _isReading = false;

  @override
  void initState() {
    super.initState();
    _loadSmsMessages();
    // ✅ Refresh automatically when the watcher detects a new emergency SMS
    SmsWatcherService.instance.newEmergencyCount.addListener(_onNewSms);
  }

  @override
  void dispose() {
    SmsWatcherService.instance.newEmergencyCount.removeListener(_onNewSms);
    super.dispose();
  }

  void _onNewSms() {
    if (!mounted) return;
    _loadSmsMessages(silent: true); // no spinner, list just updates
  }

  // ============================================================
  // READ SMS FROM PHONE + AUTO-SYNC TO FIREBASE
  // ============================================================
  Future<void> _loadSmsMessages({bool silent = false}) async {
    if (!mounted || _isReading) return;
    _isReading = true;

    if (!silent) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      // ✅ Check first; only ask if not already granted
      var permission = await Permission.sms.status;
      if (!permission.isGranted) {
        permission = await Permission.sms.request();
      }

      if (!permission.isGranted) {
        if (!mounted) return;

        setState(() {
          _isLoading = false;
          _errorMessage =
              'SMS permission was not granted.\n\n'
              'Please allow SMS permission in your phone settings.';
        });

        return;
      }

      // ✅ Read ONLY the newest 200 inbox messages (not the whole phone).
      final fetched = await _smsQuery.querySms(
        kinds: [SmsQueryKind.inbox],
        count: 200,
      );
      final messages = List<SmsMessage>.from(fetched);

      messages.sort((a, b) {
        final dateA = a.date ?? DateTime.fromMillisecondsSinceEpoch(0);
        final dateB = b.date ?? DateTime.fromMillisecondsSinceEpoch(0);
        return dateB.compareTo(dateA);
      });

      if (!mounted) return;

      setState(() {
        _smsMessages = messages;
        _isLoading = false;
      });

      debugPrint('SMS messages found: ${messages.length}');

      // ✅ AUTO-SYNC emergency SMS to Firestore in the background
      if (!silent) _syncEmergencySmsToFirebase();
    } catch (e, stackTrace) {
      debugPrint('SMS ERROR: $e');
      debugPrint('$stackTrace');

      if (!mounted || silent) return;

      setState(() {
        _isLoading = false;
        _errorMessage = 'Unable to read SMS messages.\n\nError: $e';
      });
    } finally {
      _isReading = false;
    }
  }

  // ============================================================
  // SYNC EMERGENCY SMS → FIRESTORE
  // ============================================================
  bool _isSyncing = false;

  Future<void> _syncEmergencySmsToFirebase() async {
    if (_isSyncing) return;

    final emergency = _emergencyMessages.take(30).toList();
    if (emergency.isEmpty) return;

    _isSyncing = true;
    try {
      final savedCount =
          await SmsFirebaseService.saveEmergencySmsBatch(emergency);
      if (savedCount > 0) {
        debugPrint('🔥 $savedCount emergency SMS synced to Firestore');
      }
    } catch (e) {
      debugPrint('❌ Sync failed: $e');
    } finally {
      _isSyncing = false;
    }
  }

  // ============================================================
  // FILTER EMERGENCY SMS — supports React app format
  // ============================================================
  List<SmsMessage> get _emergencyMessages {
    return _smsMessages.where((sms) {
      final message = (sms.body ?? '').toUpperCase();

      // ✅ React app codes: [MED], [FIRE], [CRIME], [ACC], [FLOOD], [OTHER]
      return message.contains('[MED]') ||
          message.contains('[FIRE]') ||
          message.contains('[CRIME]') ||
          message.contains('[ACC]') ||
          message.contains('[FLOOD]') ||
          message.contains('[OTHER]') ||
          // Legacy / fallback phrases
          message.contains('[MEDICAL]') ||
          message.contains('[ACCIDENT]') ||
          message.contains('[EMERGENCY]') ||
          message.contains('MEDICAL EMERGENCY') ||
          message.contains('FIRE EMERGENCY') ||
          message.contains('ACCIDENT') ||
          message.contains('FLOODING') ||
          message.contains('CRIME') ||
          message.contains('EMERGENCY ALERT');
    }).toList();
  }

  // ============================================================
  // UNREAD COUNT
  // ============================================================
  int get _unreadCount {
    return _emergencyMessages.where((sms) => sms.read == false).length;
  }

  // ============================================================
  // EMERGENCY TYPE — with [OTHER] specific-type extraction
  // ============================================================
  String _getEmergencyType(String message) {
    final text = message.toUpperCase();

    if (text.contains('[FIRE]') || text.contains('FIRE EMERGENCY')) {
      return 'FIRE EMERGENCY';
    }
    if (text.contains('[MED]') ||
        text.contains('[MEDICAL]') ||
        text.contains('MEDICAL EMERGENCY')) {
      return 'MEDICAL EMERGENCY';
    }
    if (text.contains('[ACC]') ||
        text.contains('[ACCIDENT]') ||
        text.contains('ACCIDENT')) {
      return 'ACCIDENT';
    }
    if (text.contains('[FLOOD]') || text.contains('FLOODING')) {
      return 'FLOODING';
    }
    if (text.contains('[CRIME]') || text.contains('CRIME')) {
      return 'CRIME';
    }
    if (text.contains('[OTHER]')) {
      // Extract the specific type if present, e.g. "[OTHER] LANDSLIDE: ..."
      final match = RegExp(r'\[OTHER\]\s*([^:\n]+):').firstMatch(text);
      if (match != null) {
        final specific = match.group(1)?.trim() ?? '';
        if (specific.isNotEmpty) {
          return 'OTHER — ${specific.toUpperCase()}';
        }
      }
      return 'OTHER EMERGENCY';
    }
    return 'EMERGENCY ALERT';
  }

  // ============================================================
  // EMERGENCY ICON
  // ============================================================
  IconData _getEmergencyIcon(String message) {
    final text = message.toUpperCase();

    if (text.contains('FIRE')) return Icons.local_fire_department_rounded;
    if (text.contains('MED') || text.contains('MEDICAL')) {
      return Icons.medical_services_rounded;
    }
    if (text.contains('ACC') || text.contains('ACCIDENT')) {
      return Icons.car_crash_rounded;
    }
    if (text.contains('FLOOD')) return Icons.water_drop_rounded;
    if (text.contains('CRIME')) return Icons.shield_rounded;
    if (text.contains('OTHER')) return Icons.help_outline_rounded;

    return Icons.warning_amber_rounded;
  }

  // ============================================================
  // EMERGENCY COLOR
  // ============================================================
  Color _getEmergencyColor(String message) {
    final text = message.toUpperCase();

    if (text.contains('FIRE')) return const Color(0xFFDC2626);
    if (text.contains('MED') || text.contains('MEDICAL')) {
      return const Color(0xFFF59E0B);
    }
    if (text.contains('ACC') || text.contains('ACCIDENT')) {
      return const Color(0xFF7C3AED);
    }
    if (text.contains('FLOOD')) return const Color(0xFF2563EB);
    if (text.contains('CRIME')) return const Color(0xFFB45309);
    if (text.contains('OTHER')) return const Color(0xFF64748B);

    return const Color(0xFFDC2626);
  }

  // ============================================================
  // FORMAT DATE
  // ============================================================
  String _formatDate(DateTime? date) {
    if (date == null) return 'Unknown time';

    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inSeconds < 60) return 'Just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes} min ago';
    if (difference.inHours < 24) return '${difference.inHours} hr ago';
    if (difference.inDays == 1) {
      return 'Yesterday ${DateFormat('h:mm a').format(date)}';
    }

    return DateFormat('MMM d, yyyy • h:mm a').format(date);
  }

  // ============================================================
  // SHOW COMPLETE SMS
  // ============================================================
  void _showSmsDetails(SmsMessage sms) {
    final body = sms.body ?? '';
    final address = sms.address ?? 'Unknown sender';

    final color = _getEmergencyColor(body);
    final icon = _getEmergencyIcon(body);
    final type = _getEmergencyType(body);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.72,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFE2E8F0),
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 12, 14),
                child: Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(icon, color: color, size: 25),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            type,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'SMS from $address',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Color(0xFFE2E8F0)),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'FROM',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF94A3B8),
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        address,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'RECEIVED',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF94A3B8),
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        sms.date != null
                            ? DateFormat('MMMM d, yyyy • h:mm:ss a')
                                .format(sms.date!)
                            : 'Unknown time',
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF334155),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'MESSAGE',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF94A3B8),
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: const Color(0xFFE2E8F0),
                          ),
                        ),
                        child: SelectableText(
                          body.isEmpty ? 'No message content' : body,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.5,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Icon(
                            sms.read == true
                                ? Icons.mark_email_read_rounded
                                : Icons.mark_email_unread_rounded,
                            size: 18,
                            color: sms.read == true
                                ? const Color(0xFF075E3B)
                                : const Color(0xFFDC2626),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            sms.read == true ? 'Read SMS' : 'Unread SMS',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: sms.read == true
                                  ? const Color(0xFF075E3B)
                                  : const Color(0xFFDC2626),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ============================================================
  // MAIN BUILD
  // ============================================================
  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.72,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: const Color(0xFFE2E8F0),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 16,
            ),
            child: Row(
              children: [
                const Text(
                  'Notifications',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(width: 10),
                if (_unreadCount > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFDC2626)
                          .withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$_unreadCount New',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFDC2626),
                      ),
                    ),
                  ),
                const Spacer(),
                IconButton(
                  tooltip: 'Refresh SMS',
                  onPressed: _isLoading ? null : _loadSmsMessages,
                  icon: const Icon(
                    Icons.refresh_rounded,
                    color: Color(0xFF475569),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.pop(context),
                  color: const Color(0xFF64748B),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          Expanded(child: _buildContent()),
        ],
      ),
    );
  }

  // ============================================================
  // CONTENT
  // ============================================================
  Widget _buildContent() {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF075E3B)),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.sms_failed_rounded,
                size: 55,
                color: Color(0xFFDC2626),
              ),
              const SizedBox(height: 16),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: Color(0xFF475569),
                ),
              ),
              const SizedBox(height: 18),
              ElevatedButton.icon(
                onPressed: _loadSmsMessages,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try Again'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF075E3B),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final messages = _emergencyMessages;

    if (messages.isEmpty) {
      return RefreshIndicator(
        onRefresh: _loadSmsMessages,
        color: const Color(0xFF075E3B),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 100),
            Icon(
              Icons.notifications_none_rounded,
              size: 64,
              color: Color(0xFFCBD5E1),
            ),
            SizedBox(height: 16),
            Center(
              child: Text(
                'No emergency notifications',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF475569),
                ),
              ),
            ),
            SizedBox(height: 6),
            Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 30),
                child: Text(
                  'Emergency SMS messages received by this phone will appear here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: Color(0xFF94A3B8),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadSmsMessages,
      color: const Color(0xFF075E3B),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: messages.length,
        itemBuilder: (context, index) {
          final sms = messages[index];

          return _SmsNotificationItem(
            sms: sms,
            icon: _getEmergencyIcon(sms.body ?? ''),
            iconColor: _getEmergencyColor(sms.body ?? ''),
            title: _getEmergencyType(sms.body ?? ''),
            time: _formatDate(sms.date),
            onTap: () => _showSmsDetails(sms),
          );
        },
      ),
    );
  }
}

// ============================================================
// SMS NOTIFICATION ITEM
// ============================================================
class _SmsNotificationItem extends StatelessWidget {
  final SmsMessage sms;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String time;
  final VoidCallback onTap;

  const _SmsNotificationItem({
    required this.sms,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.time,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final body = sms.body ?? '';
    final address = sms.address ?? 'Unknown sender';
    final isRead = sms.read == true;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: isRead ? Colors.white : const Color(0xFFF0F9FF),
          border: Border(
            bottom: BorderSide(
              color: const Color(0xFFE2E8F0).withValues(alpha: 0.6),
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: iconColor, size: 23),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: isRead
                                ? FontWeight.w600
                                : FontWeight.w800,
                            color: const Color(0xFF0F172A),
                          ),
                        ),
                      ),
                      if (!isRead)
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: Color(0xFFDC2626),
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    body.isEmpty ? 'No message content' : body,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.35,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  const SizedBox(height: 7),
                  Row(
                    children: [
                      const Icon(
                        Icons.phone_rounded,
                        size: 12,
                        color: Color(0xFF94A3B8),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          address,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 10,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        time,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Color(0xFF94A3B8),
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
    );
  }
}