// home_page.dart

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:latlong2/latlong.dart';

import 'notification_modal.dart';
import 'map_page.dart';
import 'incident_details_page.dart';
import 'tasks_page.dart'; // real Tasks page
import 'profile_page.dart'; // real Profile page
import 'message_box.dart'; // EOC message inbox
import 'incident_report_page.dart'; // ✅ SOS Emergency Report (content-only)
import 'settings_menu.dart'; // ✅ Settings dropdown + ProfileUpdateWatcher
import '../services/sms_firebase_service.dart';
import '../services/sms_watcher_service.dart'; // ✅ real-time SMS detection
import '../services/local_notification_service.dart'; // 👈 NEW

// =============================================================
// DESIGN TOKENS
// =============================================================
class _C {
  static const primary = Color(0xFF075E3B);
  static const bg = Color(0xFFF5F7F8);
  static const surface = Colors.white;
  static const ink = Color(0xFF0F172A);
  static const slate = Color(0xFF64748B);
  static const muted = Color(0xFF94A3B8);
  static const line = Color(0xFFE5E9EE);
  static const danger = Color(0xFFDC2626);
  static const info = Color(0xFF2563EB);
}

class HomePage extends StatefulWidget {
  final Map<String, dynamic>? userData;
  final User? user;

  const HomePage({super.key, this.userData, this.user});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedIndex = 0;
  late Map<String, dynamic> _userData;
  late User _user;

  // ✅ Controls whether the Home tab shows the report form instead of HomeContent
  bool _showIncidentReport = false;

  // Holds the incident the Map tab should display
  LatLng? _activeIncidentLocation;
  Map<String, dynamic>? _activeIncidentData;

  // Holds the EOC-assigned route (if any)
  AssignedRoute? _activeAssignedRoute;

  // ✅ Number of unread EOC messages (shown as a badge on the mail icon)
  int _unreadMessageCount = 0;
  StreamSubscription<QuerySnapshot>? _messageSub;

  // ✅ NEW: tracks which EOC message IDs have already fired a notification
  final Set<String> _notifiedMessageIds = <String>{};

  // ✅ NEW: skip the FIRST message listener snapshot
  bool _firstMessageSnapshotReceived = false;

  // ✅ NEW: stream subscription for messages (separate from unread counter)
  StreamSubscription<QuerySnapshot>? _messageNotifSub;

  // ✅ Lets HomePage ask the MapPage to re-check mission status when
  //    the user switches to the Map tab.
  final GlobalKey<MapPageState> _mapPageKey = GlobalKey<MapPageState>();

  // Called from HomeContent or TasksPage when user taps "Navigate to Incident"
  void _openMapForIncident({
    required LatLng location,
    required Map<String, dynamic> data,
  }) {
    setState(() {
      _activeIncidentLocation = location;
      _activeIncidentData = data;
      _activeAssignedRoute = null;
      _selectedIndex = 2;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapPageKey.currentState?.refreshMissionStatus();
    });
  }

  // Called when the EOC sends "Navigate New Assigned Route"
  void _openAssignedRouteOnMap({
    required LatLng location,
    required Map<String, dynamic> data,
    AssignedRoute? assignedRoute,
  }) {
    setState(() {
      _activeIncidentLocation = location;
      _activeIncidentData = data;
      _activeAssignedRoute = assignedRoute;
      _selectedIndex = 2;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapPageKey.currentState?.refreshMissionStatus();
    });
  }

  // ✅ Open the SOS Emergency Report inside the Home tab
  void _openIncidentReport() {
    setState(() => _showIncidentReport = true);
  }

  // ✅ Close it and return to the normal Home content
  void _closeIncidentReport() {
    setState(() => _showIncidentReport = false);
  }

  // ✅ Jump straight to the Map tab from the Quick Actions "Navigate" card
  void _openMapTab() {
    setState(() {
      _selectedIndex = 2;
      _showIncidentReport = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mapPageKey.currentState?.refreshMissionStatus();
    });
  }

  @override
  void initState() {
    super.initState();
    _userData = widget.userData ?? {};
    _user = widget.user ?? FirebaseAuth.instance.currentUser!;

    if (_userData.isEmpty) {
      _fetchUserData();
    }

    _autoSyncSmsToFirebase();
    SmsWatcherService.instance.start(); // ✅ detect new SMS in real time
    _listenToUnreadMessages(); // ✅ start unread-message listener
    _listenForNewMessages(); // ✅ fire local notification on new EOC messages
  }

  @override
  void dispose() {
    SmsWatcherService.instance.stop(); // ✅ stop SMS watcher
    _messageSub?.cancel(); // ✅ stop unread-message listener
    _messageNotifSub?.cancel(); // ✅ stop new-message listener
    super.dispose();
  }

  // ============================================================
  // ✅ Listen for unread EOC messages for this responder
  // ============================================================
  void _listenToUnreadMessages() {
    final uid = _user.uid;
    _messageSub?.cancel();
    _messageSub = FirebaseFirestore.instance
        .collection('responder_messages')
        .where('userId', isEqualTo: uid)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final unread = snap.docs.where((d) {
        final data = d.data();
        return data['read'] != true;
      }).length;
      setState(() => _unreadMessageCount = unread);
    }, onError: (e) {
      debugPrint('⚠️ unread message listener error: $e');
    });
  }

  // ============================================================
  // ✅ Fire a local notification whenever a NEW EOC message arrives
  // ============================================================
  void _listenForNewMessages() {
    final uid = _user.uid;
    _messageNotifSub?.cancel();
    _messageNotifSub = FirebaseFirestore.instance
        .collection('responder_messages')
        .where('userId', isEqualTo: uid)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;

      // First snapshot = existing messages → silence them all
      if (!_firstMessageSnapshotReceived) {
        for (final d in snap.docs) {
          _notifiedMessageIds.add(d.id);
        }
        _firstMessageSnapshotReceived = true;
        debugPrint(
            '📬 First message snapshot — silenced ${_notifiedMessageIds.length} existing messages');
        return;
      }

      // Subsequent snapshots: find messages we haven't notified for yet
      for (final doc in snap.docs) {
        if (_notifiedMessageIds.contains(doc.id)) continue;
        _notifiedMessageIds.add(doc.id);

        final data = doc.data();
        final subject = (data['subject'] ?? 'New message').toString();
        final from = (data['from'] ?? 'EOC').toString();
        final body = (data['message'] ?? '').toString();

        debugPrint('🔔 Firing EOC message notification for ${doc.id}');

        LocalNotificationService.showMessageNotification(
          id: doc.id,
          subject: subject,
          from: from,
          preview: body,
        );
      }
    }, onError: (e) {
      debugPrint('⚠️ new-message listener error: $e');
    });
  }

  // ============================================================
  // AUTO-SYNC EMERGENCY SMS → FIRESTORE
  // ✅ UPDATED: now recognizes React app codes
  //    ([MED], [FIRE], [CRIME], [ACC], [FLOOD], [OTHER])
  // ============================================================
  Future<void> _autoSyncSmsToFirebase() async {
    try {
      // ✅ Check first; only ask if not already granted (avoids clashing
      //    with the Notification modal's own permission request)
      var permission = await Permission.sms.status;
      if (!permission.isGranted) {
        permission = await Permission.sms.request();
      }
      if (!permission.isGranted) {
        debugPrint('⚠️ SMS permission not granted — skipping auto-sync');
        return;
      }

      final query = SmsQuery();
      // ✅ Only the newest 200 inbox messages (not the whole phone)
      final messages = await query.querySms(
        kinds: [SmsQueryKind.inbox],
        count: 200,
      );

      final emergency = messages.where((sms) {
        final body = (sms.body ?? '').toUpperCase();
        return body.contains('[MED]') ||
            body.contains('[FIRE]') ||
            body.contains('[CRIME]') ||
            body.contains('[ACC]') ||
            body.contains('[FLOOD]') ||
            body.contains('[OTHER]') ||
            // Legacy / fallback phrases
            body.contains('[MEDICAL]') ||
            body.contains('[ACCIDENT]') ||
            body.contains('[EMERGENCY]') ||
            body.contains('MEDICAL EMERGENCY') ||
            body.contains('FIRE EMERGENCY') ||
            body.contains('ACCIDENT') ||
            body.contains('FLOODING') ||
            body.contains('CRIME') ||
            body.contains('EMERGENCY ALERT');
      }).take(30).toList(); // ✅ sync at most 30 at a time

      if (emergency.isEmpty) {
        debugPrint('📭 No emergency SMS found for auto-sync');
        return;
      }

      final savedCount =
          await SmsFirebaseService.saveEmergencySmsBatch(emergency);

      debugPrint(
          '🔥 Auto-sync complete: $savedCount new emergency SMS saved to Firestore');
    } catch (e) {
      debugPrint('❌ Auto-sync failed: $e');
    }
  }

  Future<void> _fetchUserData() async {
    try {
      DocumentSnapshot userDoc = await FirebaseFirestore.instance
          .collection('manage_users')
          .doc(_user.uid)
          .get();

      if (!userDoc.exists) {
        userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(_user.uid)
            .get();
      }

      if (userDoc.exists && mounted) {
        setState(() {
          _userData = userDoc.data() as Map<String, dynamic>;
        });
      }
    } catch (e) {
      debugPrint('Error fetching user data: $e');
    }
  }

  void _showNotificationModal(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => const NotificationModal(),
    );
  }

  // Opens the EOC MessageBox bottom sheet, wiring the callback
  void _showMessageBox(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => MessageBox(
        onNavigateToAssignedRoute: ({
          required LatLng location,
          required Map<String, dynamic> data,
          AssignedRoute? assignedRoute,
        }) {
          _openAssignedRouteOnMap(
            location: location,
            data: data,
            assignedRoute: assignedRoute,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final userName = _userData['name'] ?? 'Responder';
    final userRole = _userData['role'] ?? _userData['type'] ?? 'Responder';
    final userProfile = _userData['profile'];

    const double avatarRadius = 26;
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: _C.bg,

      // ---------- Header (compact, single row) ----------
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(topPad + 84),
        child: Container(
          padding: EdgeInsets.fromLTRB(16, topPad + 12, 12, 14),
          decoration: const BoxDecoration(
            color: _C.primary,
          ),
          child: Row(
            children: [
              // ---- Avatar ----
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white54, width: 1.5),
                ),
                child: CircleAvatar(
                  radius: avatarRadius,
                  backgroundColor: Colors.white24,
                  child: userProfile != null && userProfile.isNotEmpty
                      ? ClipOval(
                          child: Image.network(
                            userProfile,
                            width: avatarRadius * 2,
                            height: avatarRadius * 2,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stackTrace) {
                              return const Icon(
                                Icons.person_rounded,
                                color: Colors.white,
                                size: avatarRadius * 1.2,
                              );
                            },
                          ),
                        )
                      : const Icon(
                          Icons.person_rounded,
                          color: Colors.white,
                          size: avatarRadius * 1.2,
                        ),
                ),
              ),

              const SizedBox(width: 12),

              // ---- Vertical divider ----
              Container(width: 1, height: 38, color: Colors.white38),

              const SizedBox(width: 12),

              // ---- Name + role ----
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      userName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.verified_user_outlined,
                            color: Colors.white70, size: 15),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            userRole,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              // ---- Actions ----
              _HeaderIconButton(
                icon: Icons.mail_outline_rounded,
                badgeCount: _unreadMessageCount, // ✅ unread badge
                onTap: () => _showMessageBox(context),
              ),
              const SizedBox(width: 8),
              _HeaderIconButton(
                icon: Icons.notifications_none_rounded,
                showDot: true,
                onTap: () => _showNotificationModal(context),
              ),
              const SizedBox(width: 8),
              // Settings (Request Profile Update / About / Logout) — remove
              // these two lines if you move it to the Profile page instead.
              const ResponderSettingsButton(),
            ],
          ),
        ),
      ),

      // ✅ ProfileUpdateWatcher:
      //    1. keeps _userData live (admin edits in Manage Users show up instantly)
      //    2. pops up "Profile Updated" / "Request Rejected" once per reviewed request
      body: ProfileUpdateWatcher(
        onProfileChanged: (data) {
          if (!mounted) return;
          setState(() => _userData = {..._userData, ...data});
        },

        // ✅ Home tab swaps between HomeContent and IncidentReportPage in-place.
        child: IndexedStack(
          index: _selectedIndex,
          children: [
            // ---------- Home ----------
            _showIncidentReport
                ? IncidentReportPage(
                    isAuthenticated: _user.uid.isNotEmpty,
                    initialFullName: _userData['name'] as String?,
                    initialPhoneNumber: (_userData['phone'] ??
                        _userData['mobileNumber']) as String?,
                    onClose: _closeIncidentReport,
                    onSubmit: (result) {
                      debugPrint(
                          '✅ Emergency report submitted: ${result.incidentId}');
                    },
                    onAuthRequired: () {
                      debugPrint('🔐 Sign-in required for report submission');
                    },
                  )
                : HomeContent(
                    onNavigateToIncident: _openMapForIncident,
                    onReportEmergency: _openIncidentReport,
                    onOpenMap: _openMapTab,
                  ),

            // ---------- Tasks ----------
            TasksPage(
              onNavigateToIncident: _openMapForIncident,
            ),

            // ---------- Map ----------
            MapPage(
              key: _mapPageKey,
              incidentLocation: _activeIncidentLocation,
              incidentData: _activeIncidentData,
              assignedRoute: _activeAssignedRoute,
            ),

            // ---------- Profile ----------
            ProfilePage(
              userData: _userData,
              user: _user,
            ),
          ],
        ),
      ),

      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: _C.line)),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _ResponsiveNavItem(
                  icon: Icons.home_rounded,
                  label: 'Home',
                  isActive: _selectedIndex == 0,
                  onTap: () => setState(() {
                    _selectedIndex = 0;
                    _showIncidentReport = false;
                  }),
                ),
                _ResponsiveNavItem(
                  icon: Icons.assignment_rounded,
                  label: 'Tasks',
                  isActive: _selectedIndex == 1,
                  onTap: () => setState(() {
                    _selectedIndex = 1;
                    _showIncidentReport = false;
                  }),
                ),
                _ResponsiveNavItem(
                  icon: Icons.map_rounded,
                  label: 'Map',
                  isActive: _selectedIndex == 2,
                  onTap: () {
                    setState(() {
                      _selectedIndex = 2;
                      _showIncidentReport = false;
                    });
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _mapPageKey.currentState?.refreshMissionStatus();
                    });
                  },
                ),
                _ResponsiveNavItem(
                  icon: Icons.person_rounded,
                  label: 'Profile',
                  isActive: _selectedIndex == 3,
                  onTap: () => setState(() {
                    _selectedIndex = 3;
                    _showIncidentReport = false;
                  }),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================
// HOME CONTENT
// =============================================================
class HomeContent extends StatefulWidget {
  final void Function({
    required LatLng location,
    required Map<String, dynamic> data,
  })? onNavigateToIncident;

  final VoidCallback? onReportEmergency;
  final VoidCallback? onOpenMap;

  const HomeContent({
    super.key,
    this.onNavigateToIncident,
    this.onReportEmergency,
    this.onOpenMap,
  });

  @override
  State<HomeContent> createState() => _HomeContentState();
}

class _HomeContentState extends State<HomeContent> {
  List<Map<String, dynamic>> _notifications = [];
  bool _isLoading = true;
  bool _hasInitialLoad = false;
  String? _error;

  final Set<String> _autoPoppedIds = <String>{};
  bool _isAutoPopupOpen = false;

  // 👈 NEW: tracks which incident IDs have already fired a phone notification
  final Set<String> _notifiedIds = <String>{};

  // 👈 NEW: skip the FIRST listener snapshot (contains all existing incidents)
  bool _firstSnapshotReceived = false;

  // ✅ Incident IDs that already have a submitted final report (= resolved)
  Set<String> _solvedIncidentIds = <String>{};
  StreamSubscription<QuerySnapshot>? _solvedSub;

  @override
  void initState() {
    super.initState();
    _loadNotifications();
    _listenToNotifications();
    _listenToSolvedReports();
  }

  @override
  void dispose() {
    _solvedSub?.cancel();
    super.dispose();
  }

  // ✅ Watches final_reports so resolved incidents vanish from Home live
  void _listenToSolvedReports() {
    _solvedSub = FirebaseFirestore.instance
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
      setState(() => _solvedIncidentIds = ids);
    }, onError: (e) {
      debugPrint('❌ [Home] Solved reports listener error: $e');
    });
  }

  // ✅ Resolved = status is solved/resolved/completed OR a final report exists
  bool _isResolved(Map<String, dynamic> n) {
    final status = (n['status'] ?? '').toString().toLowerCase();
    if (status == 'solved' ||
        status == 'resolved' ||
        status == 'completed') {
      return true;
    }
    final incidentId = n['incidentId']?.toString();
    if (incidentId == null || incidentId.isEmpty) return false;
    return _solvedIncidentIds.contains(incidentId);
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

  DateTime _tsOf(Map<String, dynamic> n) =>
      _assignedDate(n) ?? DateTime.fromMillisecondsSinceEpoch(0);

  // ✅ Newest first (first come → newest on top, NOT alphabetical)
  void _sortNewestFirst(List<Map<String, dynamic>> list) {
    list.sort((a, b) => _tsOf(b).compareTo(_tsOf(a)));
  }

  // ✅ NEW: status badge color (same colors as the Tasks page)
  Color _statusColor(String status) {
    switch (status.toLowerCase()) {
      case 'solved':
      case 'resolved':
      case 'completed':
        return const Color(0xFF075E3B);
      case 'dispatched':
      case 'accepted':
        return const Color(0xFF2563EB);
      case 'declined':
        return const Color(0xFFDC2626);
      default:
        return const Color(0xFFF59E0B);
    }
  }

  // 👈 NEW: helper to fire phone system notifications for new incidents
  void _fireSystemNotifications(List<Map<String, dynamic>> notifications) {
    for (final n in notifications) {
      final id = n['id']?.toString();
      if (id == null || id.isEmpty) continue;
      if (_notifiedIds.contains(id)) continue;

      if (_isResolved(n)) {
        _notifiedIds.add(id);
        continue;
      }

      final status = (n['status'] ?? '').toString().toLowerCase();
      if (status == 'solved' ||
          status == 'resolved' ||
          status == 'completed' ||
          status == 'declined') {
        _notifiedIds.add(id);
        continue;
      }

      _notifiedIds.add(id);

      debugPrint('🔔 Firing phone notification for incident $id');

      LocalNotificationService.showIncidentNotification(
        id: id,
        type: (n['type'] ?? 'Emergency').toString(),
        location: (n['location'] ?? 'Unknown location').toString(),
        unitName: n['unitName']?.toString(),
      );
    }
  }

  Future<void> _loadNotifications() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      if (!mounted) return;
      setState(() {
        _notifications = [];
        _isLoading = false;
        _error = 'User not authenticated';
      });
      return;
    }

    setState(() => _isLoading = true);

    try {
      debugPrint('📱 Loading notifications for user: ${currentUser.uid}');

      final querySnapshot = await FirebaseFirestore.instance
          .collection('responder_notifications')
          .where('userId', isEqualTo: currentUser.uid)
          .get();

      debugPrint('📱 Found ${querySnapshot.docs.length} notifications');

      final notifications = querySnapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'id': doc.id,
          ...data,
        };
      }).toList();

      _sortNewestFirst(notifications); // ✅ newest on top

      // ✅ NEW: don't touch state if the widget is already gone
      if (!mounted) return;

      setState(() {
        _notifications = notifications;
        _isLoading = false;
        _hasInitialLoad = true;
        _error = null;
      });

      // ❌ We intentionally do NOT fire notifications here.
      //    Only live-arriving incidents should trigger a phone notification.

      if (notifications.isNotEmpty) {
        _maybeAutoPopNewest(notifications);
      }
    } catch (e) {
      debugPrint('❌ Error loading notifications: $e');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Error: ${e.toString()}';
      });
    }
  }

  void _listenToNotifications() {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    debugPrint('📱 Starting real-time listener for user: ${currentUser.uid}');

    FirebaseFirestore.instance
        .collection('responder_notifications')
        .where('userId', isEqualTo: currentUser.uid)
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;

      debugPrint('📱 Real-time update: ${snapshot.docs.length} notifications');

      final notifications = snapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'id': doc.id,
          ...data,
        };
      }).toList();

      _sortNewestFirst(notifications); // ✅ newest on top

      // 👈 Only fire notifications for incidents arriving AFTER the first
      //    snapshot. The first snapshot contains all existing incidents
      //    and we must NOT notify for those.
      if (_firstSnapshotReceived) {
        _fireSystemNotifications(notifications);
      } else {
        // Mark all existing incident IDs as already-seen
        for (final n in notifications) {
          final id = n['id']?.toString();
          if (id != null && id.isNotEmpty) {
            _notifiedIds.add(id);
          }
        }
        _firstSnapshotReceived = true;
        debugPrint(
            '📱 First snapshot received — silenced ${_notifiedIds.length} existing incidents');
      }

      setState(() {
        _notifications = notifications;
        _isLoading = false;
        _error = null;
      });

      if (_hasInitialLoad) {
        _maybeAutoPopNewest(notifications);
      }
    }, onError: (error) {
      debugPrint('❌ Error listening to notifications: $error');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Listener error: ${error.toString()}';
        });
      }
    });
  }

  void _maybeAutoPopNewest(List<Map<String, dynamic>> notifications) {
    if (_isAutoPopupOpen) return;

    // ✅ NEW: don't auto-open the incident page while another screen/modal
    // is on top (e.g. the Notifications bottom sheet or SMS details, or
    // the "Profile Updated" dialog).
    // The incident ID is NOT marked as popped, so it can still open later.
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;

    final candidates = notifications.where((n) {
      final id = n['id']?.toString();
      if (id == null || id.isEmpty) return false;
      if (_autoPoppedIds.contains(id)) return false;
      if (_isResolved(n)) return false;

      final status = (n['status'] ?? '').toString().toLowerCase();
      if (status == 'solved' ||
          status == 'resolved' ||
          status == 'completed' ||
          status == 'declined') {
        return false;
      }
      return true;
    }).toList();

    if (candidates.isEmpty) return;

    // Newest first
    candidates.sort((a, b) => _tsOf(b).compareTo(_tsOf(a)));

    final newest = candidates.first;
    final id = newest['id']?.toString();
    if (id != null) _autoPoppedIds.add(id);

    _autoOpenIncidentDetails(newest);
  }

  Future<void> _autoOpenIncidentDetails(
      Map<String, dynamic> notification) async {
    if (_isAutoPopupOpen) return;
    _isAutoPopupOpen = true;

    await Future.delayed(const Duration(milliseconds: 350));
    if (!mounted) {
      _isAutoPopupOpen = false;
      return;
    }

    // ✅ NEW: the user may have opened the Notifications modal during the
    // short delay above. If so, cancel and let it open again later.
    if (ModalRoute.of(context)?.isCurrent != true) {
      final id = notification['id']?.toString();
      if (id != null) _autoPoppedIds.remove(id);
      _isAutoPopupOpen = false;
      return;
    }

    try {
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
    } catch (e) {
      debugPrint('❌ Auto-open incident failed: $e');
    } finally {
      _isAutoPopupOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // The page itself is fixed (does not scroll). Only the notification
    // list scrolls, and Quick Actions stay pinned at the bottom.
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------- Notifications header ----------
            const _SectionLabel('Incident Notifications'),
            const SizedBox(height: 10),

            // ---------- Scrollable notification list ----------
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.zero,
                children: _buildNotificationSection(),
              ),
            ),

            const SizedBox(height: 12),

            // ---------- Quick actions (pinned at the bottom) ----------
            const _SectionLabel('Quick Actions'),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _ResponsiveQuickAction(
                    icon: Icons.add_alert_rounded,
                    title: 'Report Emergency',
                    subtitle: 'New incident',
                    iconColor: _C.danger,
                    onTap: widget.onReportEmergency,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ResponsiveQuickAction(
                    icon: Icons.navigation_rounded,
                    title: 'Navigate',
                    subtitle: 'Open in map',
                    iconColor: _C.info,
                    onTap: widget.onOpenMap,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stateCard(Widget child) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _C.line),
      ),
      child: child,
    );
  }

  List<Widget> _buildNotificationSection() {
    if (_isLoading && !_hasInitialLoad) {
      return [
        _stateCard(
          const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                color: _C.primary,
                strokeWidth: 3,
              ),
            ),
          ),
        ),
      ];
    }

    if (_error != null) {
      return [
        _stateCard(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded,
                  size: 36, color: _C.danger),
              const SizedBox(height: 8),
              const Text(
                'Error loading notifications',
                style: TextStyle(
                  fontSize: 15,
                  color: _C.danger,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                _error!,
                style: const TextStyle(fontSize: 12.5, color: _C.slate),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _loadNotifications,
                style: TextButton.styleFrom(foregroundColor: _C.primary),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      ];
    }

    // ✅ Only ACTIVE incidents are shown here (resolved ones vanish)
    final activeNotifications =
        _notifications.where((n) => !_isResolved(n)).toList();

    if (activeNotifications.isEmpty) {
      return [
        _stateCard(
          const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.notifications_none_rounded,
                  size: 38, color: _C.muted),
              SizedBox(height: 8),
              Text(
                'No active incidents',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: _C.ink,
                ),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 4),
              Text(
                'When incidents are dispatched to you, they will appear here',
                style: TextStyle(fontSize: 12.5, color: _C.slate),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ];
    }

    return [
      ...activeNotifications.map((notification) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _buildNotificationCard(notification: notification),
        );
      }),
    ];
  }

  Widget _buildNotificationCard({
    required Map<String, dynamic> notification,
  }) {
    // All emergencies are treated as priority
    const severityColor = _C.danger;

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

    // ✅ NEW: status + badge color
    final status = (notification['status'] ?? 'pending').toString();
    final statusColor = _statusColor(status);

    return Material(
      color: _C.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
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
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _C.line),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: severityColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: severityColor, size: 22),
              ),
              const SizedBox(width: 12),
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
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                              color: _C.ink,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            status.toUpperCase(),
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                              color: statusColor,
                              letterSpacing: 0.3,
                            ),
                            maxLines: 1,
                            softWrap: false,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      notification['location'] ?? 'Unknown location',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: _C.slate,
                        height: 1.3,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 2,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        // ✅ Exact assigned date + time
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.schedule_rounded,
                                size: 13, color: _C.muted),
                            const SizedBox(width: 4),
                            Text(
                              'Assigned: ${_assignedLabel(notification)}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: _C.slate,
                              ),
                            ),
                          ],
                        ),
                        if (notification['unitName'] != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.local_hospital_outlined,
                                  size: 13, color: _C.primary),
                              const SizedBox(width: 3),
                              Text(
                                '${notification['unitName']}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: _C.primary,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: Icon(Icons.chevron_right_rounded,
                    size: 20, color: _C.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================
// REUSABLE WIDGETS
// =============================================================

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool showDot;

  /// ✅ Shows a numeric badge when > 0 (used for unread message count)
  final int badgeCount;

  const _HeaderIconButton({
    required this.icon,
    required this.onTap,
    this.showDot = false,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final showCount = badgeCount > 0;
    final label = badgeCount > 99 ? '99+' : '$badgeCount';

    return Material(
      color: Colors.white.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          width: 40,
          height: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, color: Colors.white, size: 22),

              // Red dot (existing behavior)
              if (showDot && !showCount)
                Positioned(
                  right: 9,
                  top: 9,
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: _C.danger,
                      shape: BoxShape.circle,
                      border: Border.all(color: _C.primary, width: 1.5),
                    ),
                  ),
                ),

              // ✅ Unread count badge
              if (showCount)
                Positioned(
                  right: 2,
                  top: 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    constraints: const BoxConstraints(minWidth: 18),
                    decoration: BoxDecoration(
                      color: _C.danger,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _C.primary, width: 1.5),
                    ),
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        height: 1.1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w800,
        color: _C.ink,
        letterSpacing: -0.2,
      ),
    );
  }
}

class _ResponsiveQuickAction extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color iconColor;
  final VoidCallback? onTap;

  const _ResponsiveQuickAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.iconColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final darker = Color.lerp(iconColor, Colors.black, 0.28)!;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [iconColor, darker],
        ),
        boxShadow: [
          BoxShadow(
            color: iconColor.withValues(alpha: 0.35),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            children: [
              // Large faded icon as a subtle design accent
              Positioned(
                right: -14,
                bottom: -18,
                child: Icon(
                  icon,
                  size: 96,
                  color: Colors.white.withValues(alpha: 0.12),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.20),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Icon(icon, color: Colors.white, size: 30),
                        ),
                        const Spacer(),
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.20),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.arrow_forward_rounded,
                            color: Colors.white,
                            size: 16,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: Colors.white.withValues(alpha: 0.80),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ResponsiveNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _ResponsiveNavItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isActive ? _C.primary : _C.muted,
              size: 24,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: isActive ? FontWeight.w800 : FontWeight.w500,
                color: isActive ? _C.primary : _C.muted,
              ),
            ),
            const SizedBox(height: 3),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: isActive ? 18 : 0,
              height: 3,
              decoration: BoxDecoration(
                color: _C.primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}