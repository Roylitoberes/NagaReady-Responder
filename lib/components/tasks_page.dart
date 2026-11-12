// tasks_page.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';

import 'incident_details_page.dart';

class TasksPage extends StatefulWidget {
  final void Function({
    required LatLng location,
    required Map<String, dynamic> data,
  })? onNavigateToIncident;

  const TasksPage({
    super.key,
    this.onNavigateToIncident,
  });

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  List<Map<String, dynamic>> _notifications = [];
  bool _isLoading = true;
  bool _hasInitialLoad = false;
  String? _error;

  // ✅ Set of incident IDs that already have a submitted final report.
  Set<String> _solvedIncidentIds = <String>{};

  @override
  void initState() {
    super.initState();
    _loadNotifications();
    _listenToNotifications();
    _listenToSolvedReports();
  }

  // ============================================================
  // ✅ ASSIGNED TIME HELPERS
  //    - Reads the real assigned date/time
  //    - Ignores dates in the future (bad data)
  //    - Example label: "Nov 7, 2026 • 8:23 PM"
  // ============================================================
  DateTime? _parseDate(dynamic raw) {
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(
          raw < 100000000000 ? raw * 1000 : raw);
    }
    if (raw is String) return DateTime.tryParse(raw);
    if (raw is Map) {
      final s = raw['seconds'] ?? raw['_seconds'];
      if (s is int) return DateTime.fromMillisecondsSinceEpoch(s * 1000);
    }
    return null;
  }

  DateTime? _assignedDate(Map<String, dynamic> n) {
    final limit = DateTime.now().add(const Duration(minutes: 5));
    for (final key in [
      'assignedAt',
      'dispatchedAt',
      'createdAt',
      'submittedAt',
      'timestamp',
    ]) {
      final d = _parseDate(n[key]);
      if (d == null) continue;
      if (d.isAfter(limit)) {
        debugPrint(
            '⚠️ "$key" is in the future (${d.toIso8601String()}) — skipped');
        continue;
      }
      return d;
    }
    return null;
  }

  String _assignedLabel(Map<String, dynamic> n) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final d0 = _assignedDate(n);
    if (d0 == null) return n['time']?.toString() ?? 'Time not available';

    final d = d0.toLocal();
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final m = d.minute.toString().padLeft(2, '0');
    final ap = d.hour >= 12 ? 'PM' : 'AM';
    return '${months[d.month - 1]} ${d.day}, ${d.year} • $h:$m $ap';
  }

  // ✅ Newest first (first come → newest on top, NOT alphabetical)
  void _sortNewestFirst(List<Map<String, dynamic>> list) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    list.sort((a, b) =>
        (_assignedDate(b) ?? epoch).compareTo(_assignedDate(a) ?? epoch));
  }

  // ============================================================
  // LOAD ONE TIME
  // ============================================================
  Future<void> _loadNotifications() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      setState(() {
        _notifications = [];
        _isLoading = false;
        _error = 'User not authenticated';
      });
      return;
    }

    setState(() => _isLoading = true);

    try {
      debugPrint('📋 [Tasks] Loading notifications for: ${currentUser.uid}');

      final querySnapshot = await FirebaseFirestore.instance
          .collection('responder_notifications')
          .where('userId', isEqualTo: currentUser.uid)
          .get();

      final notifications = querySnapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'id': doc.id,
          ...data,
        };
      }).toList();

      _sortNewestFirst(notifications); // ✅ newest on top

      if (!mounted) return;

      setState(() {
        _notifications = notifications;
        _isLoading = false;
        _hasInitialLoad = true;
        _error = null;
      });
    } catch (e) {
      debugPrint('❌ [Tasks] Error loading notifications: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Error: ${e.toString()}';
      });
    }
  }

  // ============================================================
  // REAL-TIME LISTENER — NOTIFICATIONS
  // ============================================================
  void _listenToNotifications() {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    FirebaseFirestore.instance
        .collection('responder_notifications')
        .where('userId', isEqualTo: currentUser.uid)
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;

      final notifications = snapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'id': doc.id,
          ...data,
        };
      }).toList();

      _sortNewestFirst(notifications); // ✅ newest on top

      setState(() {
        _notifications = notifications;
        _isLoading = false;
        _error = null;
      });
    }, onError: (error) {
      debugPrint('❌ [Tasks] Listener error: $error');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Listener error: ${error.toString()}';
        });
      }
    });
  }

  // ============================================================
  // ✅ REAL-TIME LISTENER — SOLVED REPORTS
  // ============================================================
  void _listenToSolvedReports() {
    FirebaseFirestore.instance
        .collection('final_reports')
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;

      final ids = <String>{};
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final incidentId = (data['incidentId'] ?? doc.id).toString();
        if (incidentId.isNotEmpty) ids.add(incidentId);
      }

      setState(() {
        _solvedIncidentIds = ids;
      });

      debugPrint('✅ [Tasks] ${ids.length} solved incident IDs loaded');
    }, onError: (e) {
      debugPrint('❌ [Tasks] Solved reports listener error: $e');
    });
  }

  // ============================================================
  // ✅ Check if a task is solved
  //    - Solved if a final report exists for that incidentId
  //    - OR the notification's own status is 'solved'
  // ============================================================
  bool _isSolved(Map<String, dynamic> notification) {
    final incidentId = notification['incidentId']?.toString();
    final status =
        (notification['status'] ?? '').toString().toLowerCase();

    if (status == 'solved') return true;

    if (incidentId == null || incidentId.isEmpty) return false;
    return _solvedIncidentIds.contains(incidentId);
  }

  // ============================================================
  // ✅ DELETE HELPERS
  //    - Only SOLVED tasks can be deleted
  //    - Always asks "Are you sure?" first
  // ============================================================
  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xFF0F172A),
        ),
      );
  }

  Future<bool> _confirmDialog({
    required String title,
    required String message,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Row(
          children: [
            const Icon(Icons.delete_outline_rounded,
                color: Color(0xFFDC2626)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                ),
              ),
            ),
          ],
        ),
        content: Text(
          message,
          style: const TextStyle(fontSize: 14, color: Color(0xFF64748B)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Color(0xFF64748B)),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result == true;
  }

  // Delete ONE task (card delete button)
  Future<void> _deleteTask(Map<String, dynamic> notification) async {
    if (!_isSolved(notification)) {
      _showSnack("This task isn't solved yet, so it can't be deleted.");
      return;
    }

    final ok = await _confirmDialog(
      title: 'Delete task?',
      message: 'Are you sure you want to delete this task?',
    );
    if (!ok || !mounted) return;

    try {
      await FirebaseFirestore.instance
          .collection('responder_notifications')
          .doc(notification['id'].toString())
          .delete();
      _showSnack('Task deleted');
    } catch (e) {
      debugPrint('❌ [Tasks] Delete failed: $e');
      _showSnack('Failed to delete task: $e');
    }
  }

  // Delete ALL solved tasks (unsolved ones are always kept)
  Future<void> _deleteAllTasks() async {
    final solved = _notifications.where(_isSolved).toList();
    final unsolvedCount = _notifications.length - solved.length;

    if (_notifications.isEmpty) {
      _showSnack('There are no tasks to delete.');
      return;
    }
    if (solved.isEmpty) {
      _showSnack('No solved tasks to delete. Unsolved tasks cannot be deleted.');
      return;
    }

    final keepNote = unsolvedCount > 0
        ? '\n\n$unsolvedCount unsolved task${unsolvedCount == 1 ? "" : "s"} will be kept.'
        : '';

    final ok = await _confirmDialog(
      title: 'Delete all tasks?',
      message:
          'Are you sure you want to delete ${solved.length} solved task${solved.length == 1 ? "" : "s"}?$keepNote',
    );
    if (!ok || !mounted) return;

    try {
      final db = FirebaseFirestore.instance;
      // Firestore batches are limited to 500 writes
      for (var i = 0; i < solved.length; i += 400) {
        final chunk = solved.skip(i).take(400);
        final batch = db.batch();
        for (final n in chunk) {
          batch.delete(
              db.collection('responder_notifications').doc(n['id'].toString()));
        }
        await batch.commit();
      }
      _showSnack(
          '${solved.length} task${solved.length == 1 ? "" : "s"} deleted');
    } catch (e) {
      debugPrint('❌ [Tasks] Delete all failed: $e');
      _showSnack('Failed to delete tasks: $e');
    }
  }

  // ============================================================
  // BUILD
  // ============================================================
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth;
          final scale = availableWidth / 390;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ---------- Header ----------
              Padding(
                padding: EdgeInsets.fromLTRB(
                  16 * scale,
                  16 * scale,
                  16 * scale,
                  6 * scale,
                ),
                child: Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(8 * scale),
                      decoration: BoxDecoration(
                        color: const Color(0xFF075E3B)
                            .withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(10 * scale),
                      ),
                      child: Icon(
                        Icons.assignment_rounded,
                        color: const Color(0xFF075E3B),
                        size: 20 * scale,
                      ),
                    ),
                    SizedBox(width: 10 * scale),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Assigned Tasks',
                            style: TextStyle(
                              fontSize: 18 * scale,
                              fontWeight: FontWeight.w800,
                              color: const Color(0xFF0F172A),
                            ),
                          ),
                          SizedBox(height: 2 * scale),
                          Text(
                            '${_notifications.length} incident${_notifications.length == 1 ? "" : "s"} assigned to you',
                            style: TextStyle(
                              fontSize: 12 * scale,
                              color: const Color(0xFF64748B),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: _deleteAllTasks,
                      icon: const Icon(
                        Icons.delete_sweep_rounded,
                        color: Color(0xFFDC2626),
                      ),
                      tooltip: 'Delete all solved tasks',
                    ),
                    IconButton(
                      onPressed: _loadNotifications,
                      icon: const Icon(
                        Icons.refresh_rounded,
                        color: Color(0xFF075E3B),
                      ),
                      tooltip: 'Refresh',
                    ),
                  ],
                ),
              ),

              // ---------- Body ----------
              Expanded(
                child: _buildBody(scale),
              ),
            ],
          );
        },
      ),
    );
  }

  // ============================================================
  // BODY: loading / error / empty / list
  // ============================================================
  Widget _buildBody(double scale) {
    if (_isLoading && !_hasInitialLoad) {
      return const Center(
        child: CircularProgressIndicator(
          color: Color(0xFF075E3B),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(24 * scale),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: 48 * scale,
                color: const Color(0xFFDC2626),
              ),
              SizedBox(height: 8 * scale),
              Text(
                'Error loading tasks',
                style: TextStyle(
                  fontSize: 16 * scale,
                  color: const Color(0xFFDC2626),
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 12 * scale),
              TextButton(
                onPressed: _loadNotifications,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_notifications.isEmpty) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(24 * scale),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.assignment_outlined,
                size: 72 * scale,
                color: const Color(0xFF94A3B8),
              ),
              SizedBox(height: 12 * scale),
              Text(
                'No assigned tasks',
                style: TextStyle(
                  fontSize: 18 * scale,
                  color: const Color(0xFF64748B),
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 4 * scale),
              Text(
                'When incidents are dispatched to you, they will appear here.',
                style: TextStyle(
                  fontSize: 13 * scale,
                  color: const Color(0xFF94A3B8),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      physics: const BouncingScrollPhysics(),
      padding: EdgeInsets.fromLTRB(
        16 * scale,
        6 * scale,
        16 * scale,
        16 * scale,
      ),
      itemCount: _notifications.length,
      separatorBuilder: (_, _) => SizedBox(height: 10 * scale),
      itemBuilder: (context, index) {
        return _buildTaskCard(
          notification: _notifications[index],
          scale: scale,
        );
      },
    );
  }

  // ============================================================
  // TASK CARD
  // ============================================================
  Widget _buildTaskCard({
    required Map<String, dynamic> notification,
    required double scale,
  }) {
    final severity = notification['severity'] ?? 'medium';
    Color severityColor;

    switch (severity) {
      case 'emergency':
      case 'high':
        severityColor = const Color(0xFFDC2626);
        break;
      case 'medium':
        severityColor = const Color(0xFFF59E0B);
        break;
      default:
        severityColor = const Color(0xFF2563EB);
    }

    final iconMap = {
      'Fire': Icons.local_fire_department_rounded,
      'Vehicle Accident': Icons.car_crash_rounded,
      'Medical Emergency': Icons.medical_services_rounded,
      'Flood': Icons.water_drop_rounded,
    };

    IconData icon = Icons.warning_amber_rounded;
    for (final entry in iconMap.entries) {
      if (notification['type']?.contains(entry.key) ?? false) {
        icon = entry.value;
        break;
      }
    }

    // ✅ Check if the task is already solved
    final solved = _isSolved(notification);

    final status = (notification['status'] ?? 'pending').toString();
    final statusColor = solved
        ? const Color(0xFF075E3B)
        : status.toLowerCase() == 'dispatched' ||
                status.toLowerCase() == 'accepted'
            ? const Color(0xFF2563EB)
            : status.toLowerCase() == 'declined'
                ? const Color(0xFFDC2626)
                : const Color(0xFFF59E0B);

    final cardColor = solved ? const Color(0xFFF3FAF5) : Colors.white;
    final cardBorderColor = solved
        ? const Color(0xFF075E3B).withValues(alpha: 0.30)
        : const Color(0xFFE2E8F0);

    final displayIcon = solved ? Icons.verified_rounded : icon;
    final displayIconColor = solved ? const Color(0xFF075E3B) : severityColor;

    return Material(
      color: cardColor,
      borderRadius: BorderRadius.circular(18 * scale),
      child: InkWell(
        borderRadius: BorderRadius.circular(18 * scale),
        onTap: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => IncidentDetailsPage(
                incidentData: notification,
              ),
            ),
          );

          if (result is Map && result['action'] == 'open_map') {
            widget.onNavigateToIncident?.call(
              location: result['incidentLocation'] as LatLng,
              data: result['incidentData'] as Map<String, dynamic>,
            );
          }
        },
        child: Container(
          padding: EdgeInsets.all(14 * scale),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(18 * scale),
            border: Border.all(
              color: cardBorderColor,
              width: solved ? 1.4 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.03),
                blurRadius: 6 * scale,
                offset: Offset(0, 2 * scale),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48 * scale,
                height: 48 * scale,
                decoration: BoxDecoration(
                  color: displayIconColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12 * scale),
                ),
                child: Icon(
                  displayIcon,
                  color: displayIconColor,
                  size: 26 * scale,
                ),
              ),
              SizedBox(width: 12 * scale),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ---------- Title + Status badge ----------
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            notification['type'] ?? 'Unknown Incident',
                            style: TextStyle(
                              fontSize: 16 * scale,
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF0F172A),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        SizedBox(width: 6 * scale),
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 7 * scale,
                            vertical: 2 * scale,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10 * scale),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (solved) ...[
                                Icon(
                                  Icons.check_circle_rounded,
                                  size: 9.5 * scale,
                                  color: statusColor,
                                ),
                                SizedBox(width: 3 * scale),
                              ],
                              Flexible(
                                child: Text(
                                  solved ? 'SOLVED' : status.toUpperCase(),
                                  style: TextStyle(
                                    fontSize: 9 * scale,
                                    fontWeight: FontWeight.w800,
                                    color: statusColor,
                                    letterSpacing: 0.3,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                  maxLines: 1,
                                  softWrap: false,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 3 * scale),

                    // ---------- Location row ----------
                    Row(
                      children: [
                        Icon(
                          Icons.location_on_rounded,
                          size: 13 * scale,
                          color: const Color(0xFFDC2626),
                        ),
                        SizedBox(width: 4 * scale),
                        Expanded(
                          child: Text(
                            notification['location'] ?? 'Unknown location',
                            style: TextStyle(
                              fontSize: 12.5 * scale,
                              color: const Color(0xFF64748B),
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 2,
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 3 * scale),

                    // ---------- ✅ Assigned date + time row ----------
                    Row(
                      children: [
                        Icon(
                          Icons.schedule_rounded,
                          size: 13 * scale,
                          color: const Color(0xFF94A3B8),
                        ),
                        SizedBox(width: 4 * scale),
                        Flexible(
                          child: Text(
                            'Assigned: ${_assignedLabel(notification)}',
                            style: TextStyle(
                              fontSize: 11.5 * scale,
                              color: const Color(0xFF64748B),
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                      ],
                    ),

                    // ---------- Unit chip (own row so the date fits) ----------
                    if (notification['unitName'] != null) ...[
                      SizedBox(height: 4 * scale),
                      Row(
                        children: [
                          Flexible(
                            child: Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 6 * scale,
                                vertical: 2 * scale,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF075E3B)
                                    .withValues(alpha: 0.10),
                                borderRadius:
                                    BorderRadius.circular(10 * scale),
                              ),
                              child: Text(
                                '🚑 ${notification['unitName']}',
                                style: TextStyle(
                                  fontSize: 10 * scale,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF075E3B),
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                softWrap: false,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Column(
                children: [
                  // ✅ Delete button (only works when the task is solved)
                  InkWell(
                    borderRadius: BorderRadius.circular(20 * scale),
                    onTap: () => _deleteTask(notification),
                    child: Padding(
                      padding: EdgeInsets.all(4 * scale),
                      child: Icon(
                        Icons.delete_outline_rounded,
                        size: 22 * scale,
                        color: solved
                            ? const Color(0xFFDC2626)
                            : const Color(0xFFCBD5E1),
                      ),
                    ),
                  ),
                  SizedBox(height: 8 * scale),
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    size: 16 * scale,
                    color: const Color(0xFF94A3B8),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}