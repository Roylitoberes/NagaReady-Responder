import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/send_push_notification.dart';

// ─────────────────────────────────────────────────────────────────────────
// Deep-cast helpers
// ─────────────────────────────────────────────────────────────────────────
Map<String, dynamic> _deepCastMap(dynamic value) {
  if (value is Map) {
    final result = <String, dynamic>{};
    value.forEach((k, v) {
      result[k.toString()] = _deepCastValue(v);
    });
    return result;
  }
  return <String, dynamic>{};
}

dynamic _deepCastValue(dynamic value) {
  if (value is Map) {
    final result = <String, dynamic>{};
    value.forEach((k, v) {
      result[k.toString()] = _deepCastValue(v);
    });
    return result;
  }
  if (value is List) {
    return value.map(_deepCastValue).toList();
  }
  return value;
}

// ─────────────────────────────────────────────────────────────────────────
// Design tokens
// ─────────────────────────────────────────────────────────────────────────
class _Palette {
  // Accent
  static const primary = Color(0xFF0B6B43);
  static const primaryDark = Color(0xFF07502F);
  static const primaryLight = Color(0xFFEAF3EE);

  // Destructive / error only
  static const danger = Color(0xFFC62828);
  static const dangerLight = Color(0xFFFBEAEA);

  // Neutrals
  static const bg = Color(0xFFF6F7F8);
  static const surface = Colors.white;
  static const border = Color(0xFFE3E7EA);
  static const textPrimary = Color(0xFF111827);
  static const textSecondary = Color(0xFF4B5563);
  static const textMuted = Color(0xFF9CA3AF);
}

const String kActiveDispatchKey = 'active_dispatch_incident';
const String kActiveDispatchIdKey = 'active_dispatch_incident_id';
const String kLastNavigatedKey = 'last_navigated_incident';
const String kLastNavigatedIdKey = 'last_navigated_incident_id';

// Cached lifecycle times — persist across page exits
const String kAcceptedTimeKey = 'active_dispatch_accepted_time';
const String kArrivalTimeKey = 'active_dispatch_arrival_time';

class IncidentDetailsPage extends StatefulWidget {
  final Map<String, dynamic>? incidentData;

  const IncidentDetailsPage({super.key, this.incidentData});

  @override
  State<IncidentDetailsPage> createState() => _IncidentDetailsPageState();
}

class _IncidentDetailsPageState extends State<IncidentDetailsPage> {
  Map<String, dynamic> _incidentData = {};
  bool _isLoading = true;
  String? _error;
  late MapController _mapController;
  bool _isSatelliteView = false;
  bool _dispatchAccepted = false;

  // Tracks whether the final report has already been submitted
  bool _reportSubmitted = false;

  // Tracks whether the responder has already marked "Arrived at Scene"
  bool _arrivedAtScene = false;

  LatLng _incidentLocation = const LatLng(13.6248, 123.1862);

  final Location _locationService = Location();

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
    _loadIncidentData();
  }

  // ============================================================
  // Helper: 12-hour formatted time string
  // ============================================================
  String _formatTime12h(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  // ============================================================
  // Helper: display incident type with specificType when "Others"
  // ============================================================
  String _getDisplayType(String? type, dynamic specificType) {
    final t = (type ?? 'Unknown Incident').toString();
    final lower = t.toLowerCase().trim();
    if (lower == 'other' ||
        lower == 'others' ||
        lower == 'other incident' ||
        lower == 'others incident') {
      final specific = specificType?.toString().trim() ?? '';
      if (specific.isNotEmpty) {
        return 'Others – $specific';
      }
    }
    return t;
  }

  // Helper: capitalize first letter for display
  String _capitalize(String value) {
    if (value.isEmpty) return value;
    return value[0].toUpperCase() + value.substring(1);
  }

  // ============================================================
  // Mirror status to incident_progress
  // ============================================================
  Future<void> _syncIncidentProgress({
    required String status,
    required String statusLabel,
    String? enRouteTime,
    String? arrivedTime,
    String? resolvedTime,
  }) async {
    final incidentId = _incidentData['incidentId']?.toString();
    if (incidentId == null || incidentId.isEmpty) return;

    final timeNow = _formatTime12h(DateTime.now());

    try {
      final ref = FirebaseFirestore.instance
          .collection('incident_progress')
          .doc(incidentId);

      const rank = {
        'submitted': 0,
        'dispatched': 1,
        'enroute': 2,
        'arrived': 3,
        'resolved': 4,
      };

      final snap = await ref.get();
      final existingStatus =
          (snap.data()?['status'] ?? '').toString().toLowerCase();
      final existingRank = rank[existingStatus] ?? -1;
      final newRank = rank[status] ?? -1;

      if (newRank <= existingRank) return;

      final payload = <String, dynamic>{
        'incidentId': incidentId,
        'status': status,
        'statusLabel': statusLabel,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (enRouteTime != null) payload['enRouteTime'] = enRouteTime;
      if (arrivedTime != null) payload['arrivedTime'] = arrivedTime;
      if (resolvedTime != null) payload['resolvedTime'] = resolvedTime;

      if (!snap.exists || snap.data()?['reportedTime'] == null) {
        payload['reportedTime'] = timeNow;
      }

      await ref.set(payload, SetOptions(merge: true));

      debugPrint('[incident_progress] $incidentId -> $status');
    } catch (e) {
      debugPrint('Failed to sync incident_progress: $e');
    }
  }

  // ============================================================
  // LOAD
  // ============================================================
  Future<void> _loadIncidentData() async {
    try {
      if (widget.incidentData != null && widget.incidentData!.isNotEmpty) {
        final incomingStatus =
            (widget.incidentData!['status'] ?? '').toString().toLowerCase();
        final alreadyAccepted = incomingStatus == 'enroute' ||
            incomingStatus == 'on_scene' ||
            incomingStatus == 'solved';

        // Merge cached lifecycle times from SharedPreferences so
        // accepted / arrival times survive page exits.
        try {
          final prefs = await SharedPreferences.getInstance();
          final cachedAccepted = prefs.getString(kAcceptedTimeKey);
          final cachedArrival = prefs.getString(kArrivalTimeKey);

          if (cachedAccepted != null && cachedAccepted.isNotEmpty) {
            widget.incidentData!['dispatchTime'] ??= cachedAccepted;
            widget.incidentData!['acceptedAtTime'] ??= cachedAccepted;
          }
          if (cachedArrival != null && cachedArrival.isNotEmpty) {
            widget.incidentData!['arrivalTime'] ??= cachedArrival;
            widget.incidentData!['arrivedAtTime'] ??= cachedArrival;
          }
        } catch (e) {
          debugPrint('Could not merge cached times: $e');
        }

        if (incomingStatus == 'solved') {
          await _saveLastNavigated(widget.incidentData!);
        } else if (alreadyAccepted) {
          await _saveActiveDispatch(widget.incidentData!);
        } else {
          await _saveLastNavigated(widget.incidentData!);
        }

        setState(() {
          _incidentData = widget.incidentData!;
          _incidentLocation = LatLng(
            _incidentData['lat'] ?? 13.6248,
            _incidentData['lng'] ?? 123.1862,
          );
          _dispatchAccepted =
              alreadyAccepted && incomingStatus != 'solved';
          _isLoading = false;
        });

        await _checkReportSubmitted();
        await _checkArrivalStatus();
        await _checkActiveDispatch();
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      final cachedJson = prefs.getString(kActiveDispatchKey);

      if (cachedJson != null && cachedJson.isNotEmpty) {
        try {
          final decoded = _deepCastMap(jsonDecode(cachedJson));

          setState(() {
            _incidentData = decoded;
            _incidentLocation = LatLng(
              decoded['lat'] ?? 13.6248,
              decoded['lng'] ?? 123.1862,
            );
            _dispatchAccepted = true;
            _isLoading = false;
          });

          await _verifyActiveDispatch(decoded['incidentId']?.toString());
          await _checkReportSubmitted();
          await _checkArrivalStatus();
          await _checkActiveDispatch();
          return;
        } catch (e) {
          debugPrint('Could not decode cached dispatch: $e');
          await _clearActiveDispatch();
        }
      }

      final restored = await _restoreActiveDispatchFromFirestore();
      if (restored != null) {
        setState(() {
          _incidentData = restored;
          _incidentLocation = LatLng(
            restored['lat'] ?? 13.6248,
            restored['lng'] ?? 123.1862,
          );
          _dispatchAccepted = true;
          _isLoading = false;
        });

        await _saveActiveDispatch(restored);
        await _checkReportSubmitted();
        await _checkArrivalStatus();
        await _checkActiveDispatch();
        return;
      }

      final incidentId = widget.incidentData?['incidentId'];
      if (incidentId != null) {
        final currentUser = FirebaseAuth.instance.currentUser;
        if (currentUser == null) {
          setState(() {
            _error = 'User not authenticated';
            _isLoading = false;
          });
          return;
        }

        final querySnapshot = await FirebaseFirestore.instance
            .collection('responder_notifications')
            .where('incidentId', isEqualTo: incidentId)
            .where('userId', isEqualTo: currentUser.uid)
            .limit(1)
            .get();

        if (querySnapshot.docs.isNotEmpty) {
          final data = _deepCastMap(querySnapshot.docs.first.data());
          setState(() {
            _incidentData = data;
            _incidentLocation = LatLng(
              data['lat'] ?? 13.6248,
              data['lng'] ?? 123.1862,
            );
            _isLoading = false;
          });
          await _checkReportSubmitted();
          await _checkArrivalStatus();
          await _checkActiveDispatch();
        } else {
          setState(() {
            _error = 'Incident not found';
            _isLoading = false;
          });
        }
      } else {
        setState(() {
          _error = 'No incident data available';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _error = 'Error loading incident: ${e.toString()}';
        _isLoading = false;
      });
    }
  }

  // ============================================================
  // Check if a final report was already submitted
  // ============================================================
  Future<void> _checkReportSubmitted() async {
    final incidentId = _incidentData['incidentId']?.toString();
    if (incidentId == null || incidentId.isEmpty) return;

    try {
      final doc = await FirebaseFirestore.instance
          .collection('final_reports')
          .doc(incidentId)
          .get();

      if (!mounted) return;

      if (doc.exists) {
        setState(() {
          _reportSubmitted = true;
          _dispatchAccepted = false;
        });
      }
    } catch (e) {
      debugPrint('Error checking final_reports: $e');
    }
  }

  // Reads the arrival status from SharedPreferences and/or
  // responder_tracking so the "Mark mission complete" button knows
  // whether "Arrived at Scene" was already tapped on the map page.
  Future<void> _checkArrivalStatus() async {
    bool arrived = false;

    // 1) Check SharedPreferences first (fast + survives page exits)
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedArrival = prefs.getString(kArrivalTimeKey);
      if (cachedArrival != null && cachedArrival.isNotEmpty) {
        arrived = true;
      }
    } catch (e) {
      debugPrint('Could not read cached arrival time: $e');
    }

    // 2) Fallback: check responder_tracking status in Firestore
    if (!arrived) {
      final incidentId = _incidentData['incidentId']?.toString();
      if (incidentId != null && incidentId.isNotEmpty) {
        try {
          final doc = await FirebaseFirestore.instance
              .collection('responder_tracking')
              .doc(incidentId)
              .get();

          if (doc.exists) {
            final status =
                (doc.data()?['status'] ?? '').toString().toLowerCase();
            if (status == 'on_scene') arrived = true;
          }
        } catch (e) {
          debugPrint('Could not read responder_tracking arrival: $e');
        }
      }
    }

    if (!mounted) return;

    setState(() {
      _arrivedAtScene = arrived;
    });
  }

  // ============================================================
  // Check active dispatch
  // ============================================================
  Future<void> _checkActiveDispatch() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    try {
      final snap = await FirebaseFirestore.instance
          .collection('responder_tracking')
          .where('responderId', isEqualTo: currentUser.uid)
          .where('status', whereIn: ['enroute', 'on_scene'])
          .limit(1)
          .get();

      if (snap.docs.isNotEmpty) {
        final doc = snap.docs.first;
        final data = _deepCastMap(doc.data());
        final otherIncidentId = data['incidentId']?.toString();
        debugPrint(
          'Another active dispatch exists: $otherIncidentId ',
        );
      }
    } catch (e) {
      debugPrint('Error checking active dispatch: $e');
    }
  }

  Future<void> _verifyActiveDispatch(String? incidentId) async {
    if (incidentId == null || incidentId.isEmpty) return;

    try {
      final doc = await FirebaseFirestore.instance
          .collection('responder_tracking')
          .doc(incidentId)
          .get();

      if (!doc.exists) {
        await _clearActiveDispatch();
        if (mounted) {
          setState(() {
            _dispatchAccepted = false;
          });
        }
        return;
      }

      final data = doc.data();
      final status = (data?['status'] ?? '').toString().toLowerCase();

      if (status == 'resolved' ||
          status == 'completed' ||
          status == 'declined') {
        await _clearActiveDispatch();
        if (mounted) {
          setState(() {
            _dispatchAccepted = false;
          });
        }
      }
    } catch (e) {
      debugPrint('Error verifying active dispatch: $e');
    }
  }

  Future<Map<String, dynamic>?> _restoreActiveDispatchFromFirestore() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return null;

    try {
      final snap = await FirebaseFirestore.instance
          .collection('responder_tracking')
          .where('responderId', isEqualTo: currentUser.uid)
          .where('status', whereIn: ['enroute', 'on_scene'])
          .limit(1)
          .get();

      if (snap.docs.isEmpty) return null;

      final data = _deepCastMap(snap.docs.first.data());

      final incidentId = data['incidentId']?.toString();
      if (incidentId != null) {
        final monSnap = await FirebaseFirestore.instance
            .collection('monitoring_status')
            .where('incidentId', isEqualTo: incidentId)
            .limit(1)
            .get();

        if (monSnap.docs.isNotEmpty) {
          final monData = _deepCastMap(monSnap.docs.first.data());
          for (final key in const [
            'type',
            'specificType',
            'location',
            'description',
            'reporterName',
            'reporterPhone',
            'casualties',
            'unitName',
            'date',
            'time',
          ]) {
            if (monData[key] != null) data[key] = monData[key];
          }
        }
      }

      // Merge cached lifecycle times from SharedPreferences so they
      // survive page exits and appear in the final report.
      try {
        final prefs = await SharedPreferences.getInstance();
        final cachedAccepted = prefs.getString(kAcceptedTimeKey);
        final cachedArrival = prefs.getString(kArrivalTimeKey);

        if (cachedAccepted != null && cachedAccepted.isNotEmpty) {
          data['dispatchTime'] ??= cachedAccepted;
          data['acceptedAtTime'] ??= cachedAccepted;
        }
        if (cachedArrival != null && cachedArrival.isNotEmpty) {
          data['arrivalTime'] ??= cachedArrival;
          data['arrivedAtTime'] ??= cachedArrival;
        }
      } catch (e) {
        debugPrint('Could not restore cached times: $e');
      }

      return data;
    } catch (e) {
      debugPrint('Error restoring active dispatch: $e');
      return null;
    }
  }

  Future<void> _saveActiveDispatch(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      await prefs.setString(kActiveDispatchKey, jsonEncode(data));
      await prefs.setString(
        kActiveDispatchIdKey,
        data['incidentId']?.toString() ?? '',
      );

      await prefs.setString(kLastNavigatedKey, jsonEncode(data));
      await prefs.setString(
        kLastNavigatedIdKey,
        data['incidentId']?.toString() ?? '',
      );
    } catch (e) {
      debugPrint('Error saving active dispatch: $e');
    }
  }

  Future<void> _saveLastNavigated(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kLastNavigatedKey, jsonEncode(data));
      await prefs.setString(
        kLastNavigatedIdKey,
        data['incidentId']?.toString() ?? '',
      );
    } catch (e) {
      debugPrint('Error saving last navigated: $e');
    }
  }

  Future<void> _clearActiveDispatch() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kActiveDispatchKey);
      await prefs.remove(kActiveDispatchIdKey);
    } catch (e) {
      debugPrint('Error clearing active dispatch: $e');
    }
  }

  Future<void> _clearAllPersistence() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kActiveDispatchKey);
      await prefs.remove(kActiveDispatchIdKey);
      await prefs.remove(kLastNavigatedKey);
      await prefs.remove(kLastNavigatedIdKey);
      // Clear cached lifecycle times too
      await prefs.remove(kAcceptedTimeKey);
      await prefs.remove(kArrivalTimeKey);
    } catch (e) {
      debugPrint('Error clearing persistence: $e');
    }
  }

  Future<void> _persistAcceptedDispatch() async {
    await _saveActiveDispatch(_incidentData);
  }

  Future<void> _clearAcceptedDispatch() async {
    await _clearActiveDispatch();
    if (mounted) {
      setState(() {
        _dispatchAccepted = false;
      });
    }
  }

  Future<void> _openInMaps() async {
    final url =
        'https://www.google.com/maps/search/?api=1&query=${_incidentLocation.latitude},${_incidentLocation.longitude}';
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    }
  }

  void _navigateToMap() {
    Navigator.pop(context, {
      'action': 'open_map',
      'incidentLocation': _incidentLocation,
      'incidentData': _incidentData,
    });
  }

  // Single accent color for every severity level
  Color _getSeverityColor(String? severity) {
    return _Palette.primary;
  }

  IconData _getIncidentIcon(String? type) {
    final typeLower = type?.toLowerCase() ?? '';
    if (typeLower.contains('fire')) return Icons.local_fire_department_rounded;
    if (typeLower.contains('vehicle') || typeLower.contains('accident')) {
      return Icons.car_crash_rounded;
    }
    if (typeLower.contains('medical') || typeLower.contains('ambulance')) {
      return Icons.medical_services_rounded;
    }
    if (typeLower.contains('flood') || typeLower.contains('water')) {
      return Icons.water_drop_rounded;
    }
    return Icons.warning_amber_rounded;
  }

  void _toggleMapView() {
    setState(() {
      _isSatelliteView = !_isSatelliteView;
    });
  }

  // Flat card: white surface, thin border, no shadow
  BoxDecoration _cardDecoration({double radius = 14}) {
    return BoxDecoration(
      color: _Palette.surface,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: _Palette.border, width: 1),
    );
  }

  Widget _sectionHeader(IconData icon, String title, double scale,
      {Widget? trailing}) {
    return Row(
      children: [
        Icon(icon, color: _Palette.primary, size: 18 * scale),
        SizedBox(width: 8 * scale),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 15 * scale,
              fontWeight: FontWeight.w700,
              color: _Palette.textPrimary,
            ),
          ),
        ),
        ?trailing,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // ✅ sizeOf / paddingOf only rebuild when those specific values change
    //    (not on every keyboard animation frame).
    final screenWidth = MediaQuery.sizeOf(context).width;
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final scale = (screenWidth / 390).clamp(0.85, 1.15);

    if (_isLoading) {
      return Scaffold(
        backgroundColor: _Palette.bg,
        appBar: _buildAppBar(),
        body: const Center(
          child: CircularProgressIndicator(
            color: _Palette.primary,
            strokeWidth: 3,
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        backgroundColor: _Palette.bg,
        appBar: _buildAppBar(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: const BoxDecoration(
                    color: _Palette.dangerLight,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.error_outline_rounded,
                    size: 40,
                    color: _Palette.danger,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Error loading incident',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: _Palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    color: _Palette.textSecondary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: 46,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      setState(() {
                        _isLoading = true;
                        _error = null;
                      });
                      _loadIncidentData();
                    },
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                    label: const Text(
                      'Retry',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _Palette.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
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

    final rawType = _incidentData['type'] ?? 'Unknown Incident';
    final specificType = _incidentData['specificType'];
    final type = _getDisplayType(rawType, specificType);
    final location = _incidentData['location'] ?? 'Unknown location';
    final date = _incidentData['date'] ?? 'Unknown date';
    final time = _incidentData['time'] ?? 'Unknown time';
    final status = _incidentData['status'] ?? 'Pending';
    final severity = _incidentData['severity'] ?? 'medium';
    final unitName = _incidentData['unitName'] ?? 'Unassigned';
    final unitCode = _incidentData['unitCode'] ?? '';
    final eta = _incidentData['eta'] ?? '5 mins';

    final reportedBy = _incidentData['reporterName'] ??
        _incidentData['reporter']?['fullName'] ??
        'None';
    final phone = _incidentData['reporterPhone'] ??
        _incidentData['reporter']?['phoneNumber'] ??
        _incidentData['phone'] ??
        'None';

    final incidentId = _incidentData['incidentId'] ?? 'INC-2026-00125';
    final lat = _incidentData['lat'] ?? 13.6248;
    final lng = _incidentData['lng'] ?? 123.1862;

    return Scaffold(
      backgroundColor: _Palette.bg,
      appBar: _buildAppBar(),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          16 * scale,
          16 * scale,
          16 * scale,
          16 * scale + bottomPadding,
        ),
        child: Column(
          children: [
            _buildIncidentCard(
              scale: scale,
              type: type,
              severity: severity,
              status: status,
              incidentId: incidentId,
              icon: _getIncidentIcon(rawType),
              date: date,
              time: time,
            ),
            SizedBox(height: 12 * scale),
            _buildInformationCard(
              scale: scale,
              location: location,
              date: date,
              time: time,
              reportedBy: reportedBy,
              phone: phone,
              lat: lat,
              lng: lng,
            ),
            SizedBox(height: 12 * scale),
            _buildResponderInfo(
              scale: scale,
              unitName: unitName,
              unitCode: unitCode,
              eta: eta,
              lat: lat,
              lng: lng,
            ),
            SizedBox(height: 12 * scale),
            _buildLocationCard(
              scale: scale,
              location: location,
              lat: lat,
              lng: lng,
            ),
            SizedBox(height: 24 * scale),
            _buildActionButtons(scale),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _Palette.primary,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
        onPressed: () => Navigator.pop(context),
      ),
      title: const Text(
        'Incident details',
        style: TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      centerTitle: false,
      actions: [
        IconButton(
          icon: const Icon(Icons.help_outline_rounded, color: Colors.white),
          onPressed: _showHelpDialog,
        ),
      ],
    );
  }

  void _showHelpDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _Palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text(
          'Help',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: _Palette.textPrimary,
          ),
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Accept Dispatch — confirm you are responding to this incident.',
              style: TextStyle(
                  fontSize: 13.5,
                  color: _Palette.textSecondary,
                  height: 1.5),
            ),
            SizedBox(height: 8),
            Text(
              'Navigate — open the location in Google Maps.',
              style: TextStyle(
                  fontSize: 13.5,
                  color: _Palette.textSecondary,
                  height: 1.5),
            ),
            SizedBox(height: 8),
            Text(
              'Request Backup — request additional units to respond.',
              style: TextStyle(
                  fontSize: 13.5,
                  color: _Palette.textSecondary,
                  height: 1.5),
            ),
            SizedBox(height: 14),
            Text(
              'An accepted dispatch is locked until you mark it as completed.',
              style: TextStyle(
                  fontSize: 12.5,
                  color: _Palette.primary,
                  fontWeight: FontWeight.w600,
                  height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Got it',
              style: TextStyle(
                color: _Palette.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIncidentCard({
    required double scale,
    required String type,
    required String severity,
    required String status,
    required String incidentId,
    required IconData icon,
    required String date,
    required String time,
  }) {
    final severityColor = _getSeverityColor(severity);
    final isDeclined = status.toLowerCase() == 'declined';

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 48 * scale,
                height: 48 * scale,
                decoration: BoxDecoration(
                  color: _Palette.primaryLight,
                  borderRadius: BorderRadius.circular(12 * scale),
                ),
                child: Icon(icon, color: severityColor, size: 26 * scale),
              ),
              SizedBox(width: 14 * scale),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      type.toString(),
                      style: TextStyle(
                        fontSize: 18 * scale,
                        fontWeight: FontWeight.w700,
                        color: _Palette.textPrimary,
                        height: 1.2,
                      ),
                    ),
                    SizedBox(height: 6 * scale),
                    _pillBadge(
                      label: _capitalize(status.toString()),
                      color: isDeclined ? _Palette.danger : _Palette.primary,
                      background: isDeclined
                          ? _Palette.dangerLight
                          : _Palette.primaryLight,
                      scale: scale,
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: 14 * scale),
          const Divider(color: _Palette.border, height: 1),
          SizedBox(height: 12 * scale),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.tag_rounded,
                      size: 15 * scale, color: _Palette.textMuted),
                  SizedBox(width: 6 * scale),
                  Expanded(
                    child: Text(
                      incidentId,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5 * scale,
                        color: _Palette.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8 * scale),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.schedule_rounded,
                      size: 15 * scale, color: _Palette.textMuted),
                  SizedBox(width: 6 * scale),
                  Expanded(
                    child: Text(
                      '$date, $time',
                      style: TextStyle(
                        fontSize: 12.5 * scale,
                        color: _Palette.textSecondary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _pillBadge({
    required String label,
    required Color color,
    required Color background,
    required double scale,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10 * scale, vertical: 3 * scale),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20 * scale),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5 * scale,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _buildInformationCard({
    required double scale,
    required String location,
    required String date,
    required String time,
    required String reportedBy,
    required String phone,
    required double lat,
    required double lng,
  }) {
    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(Icons.info_outline_rounded, 'Information', scale),
          SizedBox(height: 14 * scale),
          _buildInfoRow(
            Icons.location_on_outlined,
            'Location',
            location,
            scale,
          ),
          _buildInfoRow(
            Icons.calendar_today_outlined,
            'Reported',
            '$date - $time',
            scale,
          ),
          _buildInfoRow(
            Icons.person_outline_rounded,
            'Reported by',
            reportedBy,
            scale,
          ),
          _buildInfoRow(
            Icons.phone_outlined,
            'Contact',
            phone,
            scale,
          ),
          _buildInfoRow(
            Icons.my_location_rounded,
            'GPS coordinates',
            '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}',
            scale,
            isLast: true,
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(
    IconData icon,
    String label,
    String value,
    double scale, {
    bool isLast = false,
  }) {
    final isNone = value.trim().toLowerCase() == 'none' || value.trim().isEmpty;
    final displayValue = isNone ? 'None' : value;

    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 14 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: EdgeInsets.all(7 * scale),
            decoration: BoxDecoration(
              color: _Palette.bg,
              borderRadius: BorderRadius.circular(8 * scale),
            ),
            child: Icon(
              icon,
              size: 16 * scale,
              color: _Palette.textSecondary,
            ),
          ),
          SizedBox(width: 12 * scale),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12 * scale,
                    color: _Palette.textMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 2 * scale),
                Text(
                  displayValue,
                  style: TextStyle(
                    fontSize: 14 * scale,
                    color: isNone ? _Palette.textMuted : _Palette.textPrimary,
                    fontWeight: isNone ? FontWeight.w400 : FontWeight.w600,
                    fontStyle: isNone ? FontStyle.italic : FontStyle.normal,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResponderInfo({
    required double scale,
    required String unitName,
    required String unitCode,
    required String eta,
    required double lat,
    required double lng,
  }) {
    final distance = '1.8 km';

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(
              Icons.local_shipping_outlined, 'Response details', scale),
          SizedBox(height: 14 * scale),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Assigned unit',
                      style: TextStyle(
                        fontSize: 12 * scale,
                        color: _Palette.textMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    SizedBox(height: 6 * scale),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 10 * scale,
                        vertical: 5 * scale,
                      ),
                      decoration: BoxDecoration(
                        color: _Palette.primaryLight,
                        borderRadius: BorderRadius.circular(8 * scale),
                      ),
                      child: Text(
                        unitCode.isNotEmpty
                            ? '$unitName ($unitCode)'
                            : unitName,
                        style: TextStyle(
                          fontSize: 13.5 * scale,
                          fontWeight: FontWeight.w700,
                          color: _Palette.primaryDark,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                width: 1,
                height: 46 * scale,
                margin: EdgeInsets.symmetric(horizontal: 14 * scale),
                color: _Palette.border,
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Distance',
                      style: TextStyle(
                        fontSize: 12 * scale,
                        color: _Palette.textMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    SizedBox(height: 4 * scale),
                    Text(
                      distance,
                      style: TextStyle(
                        fontSize: 18 * scale,
                        fontWeight: FontWeight.w700,
                        color: _Palette.textPrimary,
                      ),
                    ),
                    Text(
                      'Estimated $eta',
                      style: TextStyle(
                        fontSize: 12 * scale,
                        color: _Palette.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLocationCard({
    required double scale,
    required String location,
    required double lat,
    required double lng,
  }) {
    final incidentLocation = LatLng(lat, lng);

    return Container(
      padding: EdgeInsets.all(16 * scale),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _sectionHeader(
                    Icons.map_outlined, 'Incident location', scale),
              ),
              Container(
                decoration: BoxDecoration(
                  color: _isSatelliteView ? _Palette.primary : _Palette.bg,
                  borderRadius: BorderRadius.circular(8 * scale),
                  border: Border.all(
                    color:
                        _isSatelliteView ? _Palette.primary : _Palette.border,
                  ),
                ),
                child: IconButton(
                  icon: Icon(
                    _isSatelliteView
                        ? Icons.map_rounded
                        : Icons.satellite_alt_rounded,
                    size: 18 * scale,
                    color: _isSatelliteView
                        ? Colors.white
                        : _Palette.textSecondary,
                  ),
                  onPressed: _toggleMapView,
                  padding: EdgeInsets.all(7 * scale),
                  constraints: const BoxConstraints(),
                  tooltip: _isSatelliteView
                      ? 'Switch to street view'
                      : 'Switch to satellite view',
                ),
              ),
              SizedBox(width: 8 * scale),
              OutlinedButton.icon(
                onPressed: _openInMaps,
                icon: Icon(Icons.directions_rounded, size: 15 * scale),
                label: Text(
                  'Open in Maps',
                  style: TextStyle(
                    fontSize: 12 * scale,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _Palette.primary,
                  side: const BorderSide(color: _Palette.primary),
                  padding: EdgeInsets.symmetric(
                    horizontal: 10 * scale,
                    vertical: 8 * scale,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8 * scale),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 12 * scale),
          Container(
            height: 190 * scale,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12 * scale),
              border: Border.all(
                color: _Palette.border,
                width: 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12 * scale),
              child: Stack(
                children: [
                  FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: incidentLocation,
                      initialZoom: 15.0,
                      interactionOptions: const InteractionOptions(
                        flags: InteractiveFlag.pinchZoom |
                            InteractiveFlag.drag,
                      ),
                    ),
                    children: [
                      _isSatelliteView
                          ? TileLayer(
                              urlTemplate:
                                  'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
                              userAgentPackageName:
                                  'com.example.responder_app',
                              tileProvider: NetworkTileProvider(),
                            )
                          : TileLayer(
                              urlTemplate:
                                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName:
                                  'com.example.responder_app',
                              tileProvider: NetworkTileProvider(),
                            ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: incidentLocation,
                            width: 38 * scale,
                            height: 38 * scale,
                            child: Container(
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _Palette.primary,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 2.5,
                                ),
                              ),
                              child: const Icon(
                                Icons.location_on_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Positioned(
                        top: 8 * scale,
                        right: 8 * scale,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: 9 * scale,
                            vertical: 4 * scale,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.65),
                            borderRadius: BorderRadius.circular(6 * scale),
                          ),
                          child: Text(
                            _isSatelliteView ? 'Satellite' : 'Street',
                            style: TextStyle(
                              fontSize: 10.5 * scale,
                              color: Colors.white,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    bottom: 10 * scale,
                    left: 10 * scale,
                    right: 10 * scale,
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12 * scale,
                        vertical: 9 * scale,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.96),
                        borderRadius: BorderRadius.circular(10 * scale),
                        border: Border.all(color: _Palette.border),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.location_on_outlined,
                            color: _Palette.primary,
                            size: 18 * scale,
                          ),
                          SizedBox(width: 8 * scale),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Incident location',
                                  style: TextStyle(
                                    fontSize: 12 * scale,
                                    fontWeight: FontWeight.w600,
                                    color: _Palette.textPrimary,
                                  ),
                                ),
                                Text(
                                  location,
                                  style: TextStyle(
                                    fontSize: 11 * scale,
                                    color: _Palette.textSecondary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: 8 * scale,
                              vertical: 3 * scale,
                            ),
                            decoration: BoxDecoration(
                              color: _reportSubmitted
                                  ? _Palette.bg
                                  : _Palette.primaryLight,
                              borderRadius: BorderRadius.circular(12 * scale),
                            ),
                            child: Text(
                              _reportSubmitted ? 'Completed' : 'Active',
                              style: TextStyle(
                                fontSize: 10.5 * scale,
                                fontWeight: FontWeight.w600,
                                color: _reportSubmitted
                                    ? _Palette.textSecondary
                                    : _Palette.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // Action buttons
  //   Accepted state:  [ Mark mission complete ]  (top, green)
  //                    [ Navigate to incident  ]  (bottom, green)
  // ============================================================
  Widget _buildActionButtons(double scale) {
    if (_reportSubmitted) {
      return _buildReportSubmittedBanner(scale);
    }

    if (!_dispatchAccepted) {
      return SizedBox(
        width: double.infinity,
        child: _buildActionButton(
          icon: Icons.check_rounded,
          label: 'Accept dispatch',
          color: _Palette.primary,
          onPressed: _showAcceptDialog,
          scale: scale,
        ),
      );
    }

    return Column(
      children: [
        // ✅ TOP: Mark mission complete (solid green)
        SizedBox(
          width: double.infinity,
          child: _buildActionButton(
            icon: Icons.check_circle_outline_rounded,
            label: 'Mark mission complete',
            color: _Palette.primary,
            onPressed: _onMarkMissionCompletePressed,
            scale: scale,
          ),
        ),
        SizedBox(height: 10 * scale),
        // ✅ BOTTOM: Navigate to incident (solid green)
        SizedBox(
          width: double.infinity,
          child: _buildActionButton(
            icon: Icons.navigation_rounded,
            label: 'Navigate to incident',
            color: _Palette.primary,
            onPressed: _navigateToMap,
            scale: scale,
          ),
        ),
      ],
    );
  }

  Widget _buildReportSubmittedBanner(double scale) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(20 * scale),
      decoration: BoxDecoration(
        color: _Palette.primaryLight,
        borderRadius: BorderRadius.circular(14 * scale),
        border: Border.all(
          color: _Palette.primary.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 52 * scale,
            height: 52 * scale,
            decoration: const BoxDecoration(
              color: _Palette.primary,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.check_rounded,
              color: Colors.white,
              size: 28 * scale,
            ),
          ),
          SizedBox(height: 14 * scale),
          Text(
            'Report submitted',
            style: TextStyle(
              fontSize: 17 * scale,
              fontWeight: FontWeight.w700,
              color: _Palette.primaryDark,
            ),
          ),
          SizedBox(height: 6 * scale),
          Text(
            'This mission is complete and your final report has been '
            'sent successfully. Thank you for your service.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13 * scale,
              color: _Palette.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // Mark mission complete — with arrival check
  // ============================================================
  Future<void> _onMarkMissionCompletePressed() async {
    // Refresh arrival state right before checking (in case the user just
    // came back from the map page after tapping Arrived at Scene).
    await _checkArrivalStatus();

    if (!mounted) return;

    if (!_arrivedAtScene) {
      final shouldGoToMap = await _showArrivalRequiredDialog();
      if (!mounted) return;

      if (shouldGoToMap == true) {
        _goToMapForArrival();
      }
      return;
    }

    // Arrival already marked → proceed to the normal completion dialog
    _showCompleteMissionDialog();
  }

  // Modal shown when the user taps "Mark mission complete" before
  // marking "Arrived at Scene".
  Future<bool?> _showArrivalRequiredDialog() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _Palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFFEF3E2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.warning_amber_rounded,
                color: Color(0xFFF59E0B),
                size: 22,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Arrival not confirmed',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: _Palette.textPrimary,
                ),
              ),
            ),
          ],
        ),
        content: const Text(
          'Please click the "Arrived at Scene" first before you click '
          'the Mission Complete button.',
          style: TextStyle(
            fontSize: 14,
            color: _Palette.textSecondary,
            height: 1.45,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text(
              'Cancel',
              style: TextStyle(
                color: _Palette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _Palette.primary,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Go to Map'),
          ),
        ],
      ),
    );
  }

  // Pops back to the MapPage with the open_map action so the responder
  // can tap "Arrived at Scene" there.
  void _goToMapForArrival() {
    Navigator.pop(context, {
      'action': 'open_map',
      'incidentLocation': _incidentLocation,
      'incidentData': _incidentData,
    });
  }

  // ============================================================
  // Complete Mission dialog
  // ============================================================
  void _showCompleteMissionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _Palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text(
          'Complete mission?',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: _Palette.textPrimary,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Submit your final report before closing this mission.',
              style: TextStyle(
                fontSize: 14,
                color: _Palette.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _openFinalReportForm();
                },
                icon: const Icon(Icons.description_outlined, size: 18),
                label: const Text('Send final report'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _Palette.primary,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => Navigator.pop(dialogContext),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _Palette.textSecondary,
                  side: const BorderSide(color: _Palette.border),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openFinalReportForm() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => FinalIncidentReportPage(
          incidentData: _incidentData,
          // ✅ Not awaited by the report page — it closes immediately and
          //    this runs in the background.
          onSubmitted: () async {
            await _markMissionComplete();
          },
        ),
      ),
    );
  }

  // ============================================================
  // Mark mission complete (fast: parallel reads + one batched write)
  // ============================================================
  Future<void> _markMissionComplete() async {
    final incidentId = _incidentData['incidentId']?.toString();
    final user = FirebaseAuth.instance.currentUser;
    if (incidentId == null || incidentId.isEmpty) return;

    try {
      final db = FirebaseFirestore.instance;

      // Run both lookups at the same time
      final monFuture = db
          .collection('monitoring_status')
          .where('incidentId', isEqualTo: incidentId)
          .limit(1)
          .get();

      final Future<QuerySnapshot<Map<String, dynamic>>>? notifFuture =
          user == null
              ? null
              : db
                  .collection('responder_notifications')
                  .where('incidentId', isEqualTo: incidentId)
                  .where('userId', isEqualTo: user.uid)
                  .get();

      final monSnap = await monFuture;
      final notifDocs = notifFuture == null
          ? <QueryDocumentSnapshot<Map<String, dynamic>>>[]
          : (await notifFuture).docs;

      // One batched write instead of many sequential ones
      final batch = db.batch();

      batch.set(
        db.collection('responder_tracking').doc(incidentId),
        {
          'status': 'resolved',
          'completedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      final monRef = monSnap.docs.isNotEmpty
          ? monSnap.docs.first.reference
          : db.collection('monitoring_status').doc(incidentId);

      batch.set(
        monRef,
        {
          'incidentId': incidentId,
          'status': 'resolved',
          'resolvedAt': FieldValue.serverTimestamp(),
          'completedAt': FieldValue.serverTimestamp(),
          'awaitingReport': false,
          'reportSubmitted': true,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );

      for (final doc in notifDocs) {
        batch.update(doc.reference, {
          'status': 'solved',
          'solvedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();

      // ✅ Update the UI right away
      if (mounted) {
        setState(() {
          _reportSubmitted = true;
          _dispatchAccepted = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          _buildSnackBar('Final report sent. Mission complete.'),
        );
      }

      // ✅ Slow stuff runs in the background
      unawaited(_syncIncidentProgress(
        status: 'resolved',
        statusLabel: 'Resolved',
        resolvedTime: _formatTime12h(DateTime.now()),
      ));
      unawaited(_notifyReporterResolved());

      await _clearAcceptedDispatch();
      await _clearAllPersistence();
    } catch (e) {
      debugPrint('Error completing mission: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          _buildSnackBar(
            'Error completing mission. Please try again.',
            isError: true,
          ),
        );
      }
    }
  }

  // Consistent snackbar styling
  SnackBar _buildSnackBar(String message, {bool isError = false}) {
    return SnackBar(
      content: Text(message),
      backgroundColor: isError ? _Palette.danger : _Palette.primary,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
      duration: const Duration(seconds: 2),
    );
  }

  void _showAcceptDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _Palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text(
          'Accept dispatch',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: _Palette.textPrimary,
          ),
        ),
        content: const Text(
          'Are you sure you want to accept this dispatch? You will be automatically en route to the incident.',
          style: TextStyle(
            fontSize: 14,
            color: _Palette.textSecondary,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(
              'Cancel',
              style: TextStyle(
                color: _Palette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              // Close the dialog immediately.
              Navigator.pop(dialogContext);

              final acceptedTime = _formatTime12h(DateTime.now());
              _incidentData['dispatchTime'] = acceptedTime;
              _incidentData['acceptedAtTime'] = acceptedTime;

              // Flip the flag so the UI reflects "accepted" state.
              setState(() {
                _dispatchAccepted = true;
              });

              // Kick off all the async Firestore / notification work in
              // the background — do NOT await it here.
              unawaited(_finishAcceptDispatchInBackground(acceptedTime));

              // Navigate to Map tab right away.
              _navigateToMap();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _Palette.primary,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }

  // Runs all the acceptance side-effects in the background.
  //
  // ORDER MATTERS: the En Route status is written to Firestore FIRST
  // (no GPS, no waiting) so the Track Responder screen moves to
  // "En Route" right when the responder taps Accept dispatch.
  Future<void> _finishAcceptDispatchInBackground(String acceptedTime) async {
    final incidentId = _incidentData['incidentId']?.toString();
    final currentUser = FirebaseAuth.instance.currentUser;

    // STEP 1 (FIRST, no GPS, no waiting): move Track Responder → En Route
    try {
      await _syncIncidentProgress(
        status: 'enroute',
        statusLabel: 'En Route',
        enRouteTime: acceptedTime,
      );
    } catch (e) {
      debugPrint('Could not sync incident_progress: $e');
    }

    try {
      if (incidentId != null && incidentId.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('responder_tracking')
            .doc(incidentId)
            .set({
          'incidentId': incidentId,
          'responderId': currentUser?.uid ?? '',
          'responderName': currentUser?.displayName ?? 'Responder',
          'status': 'enroute',
          'dispatchTime': acceptedTime,
          'acceptedAtTime': acceptedTime,
          'acceptedAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('Could not set responder_tracking enroute: $e');
    }

    // STEP 2: cache accepted time so it survives page exits and auto-fills
    // the final report's "Departure time".
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kAcceptedTimeKey, acceptedTime);
    } catch (e) {
      debugPrint('Could not cache accepted time: $e');
    }

    // STEP 3: the rest (these can be slow because of GPS)
    try {
      await _updateIncidentStatus('enroute');
    } catch (e) {
      debugPrint('Could not update incident status: $e');
    }

    try {
      await _persistAcceptedDispatch();
    } catch (e) {
      debugPrint('Could not persist accepted dispatch: $e');
    }

    try {
      await _seedResponderTracking();
    } catch (e) {
      debugPrint('Could not seed responder tracking: $e');
    }

    try {
      await _notifyReporterResponderAssigned();
    } catch (e) {
      debugPrint('Could not notify reporter: $e');
    }
  }

  Future<LatLng?> _getResponderLocation() async {
    try {
      bool serviceEnabled = await _locationService.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await _locationService.requestService();
        if (!serviceEnabled) {
          debugPrint('Location service disabled by user');
          return null;
        }
      }

      PermissionStatus permission = await _locationService.hasPermission();
      if (permission == PermissionStatus.denied) {
        permission = await _locationService.requestPermission();
      }
      if (permission != PermissionStatus.granted &&
          permission != PermissionStatus.grantedLimited) {
        debugPrint('Location permission not granted');
        return null;
      }

      // Timeout so GPS can never hang the accept-dispatch flow
      final LocationData data = await _locationService
          .getLocation()
          .timeout(const Duration(seconds: 8));
      final double? lat = data.latitude;
      final double? lng = data.longitude;
      if (lat == null || lng == null) {
        debugPrint('Location returned null lat/lng');
        return null;
      }

      debugPrint('Responder GPS acquired: $lat,$lng');
      return LatLng(lat, lng);
    } catch (e) {
      debugPrint('Failed to get responder location: $e');
      return null;
    }
  }

  Future<void> _seedResponderTracking() async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;

      final incidentId = _incidentData['incidentId'];
      if (incidentId == null) return;

      final incidentLat =
          (_incidentData['lat'] as num?)?.toDouble() ?? 13.6248;
      final incidentLng =
          (_incidentData['lng'] as num?)?.toDouble() ?? 123.1862;

      final responderLoc = await _getResponderLocation();

      final Map<String, dynamic> trackingPayload = <String, dynamic>{
        'incidentId': incidentId,
        'responderId': currentUser.uid,
        'responderName': currentUser.displayName ?? 'Responder',
        'incidentLat': incidentLat,
        'incidentLng': incidentLng,
        'lat': responderLoc?.latitude,
        'lng': responderLoc?.longitude,
        'status': 'enroute',
        'acceptedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

      if (responderLoc != null) {
        debugPrint('Seeded responder_tracking WITH real GPS.');
      } else {
        debugPrint(
          'Seeded responder_tracking WITHOUT GPS — lat/lng set to null.',
        );
      }

      await FirebaseFirestore.instance
          .collection('responder_tracking')
          .doc(incidentId)
          .set(trackingPayload, SetOptions(merge: true));

      final monSnap = await FirebaseFirestore.instance
          .collection('monitoring_status')
          .where('incidentId', isEqualTo: incidentId)
          .limit(1)
          .get();

      final responderLabel = currentUser.displayName ?? 'Responder';

      if (monSnap.docs.isNotEmpty) {
        await monSnap.docs.first.reference.update({
          'status': 'enroute',
          'responder': responderLabel,
          'responderId': currentUser.uid,
          'acceptedAt': FieldValue.serverTimestamp(),
          'dispatchTime': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } else {
        await FirebaseFirestore.instance
            .collection('monitoring_status')
            .doc(incidentId)
            .set({
          'incidentId': incidentId,
          'type': _incidentData['type'] ?? 'Emergency',
          'specificType': _incidentData['specificType'],
          'title': _incidentData['title'] ??
              _incidentData['type'] ??
              'Emergency',
          'location': _incidentData['location'] ?? '',
          'lat': incidentLat,
          'lng': incidentLng,
          'status': 'enroute',
          'responder': responderLabel,
          'responderId': currentUser.uid,
          'dispatchedUnits': _incidentData['unitName'] ?? '',
          'description': _incidentData['description'] ?? '',
          'acceptedAt': FieldValue.serverTimestamp(),
          'dispatchTime': FieldValue.serverTimestamp(),
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('Error seeding responder tracking: $e');
    }
  }

  // ============================================================
  // Shared helpers for reporter notifications
  // ============================================================
  Future<String> _resolveResponderName() async {
    final currentUser = FirebaseAuth.instance.currentUser;

    String responderName = currentUser?.displayName?.trim() ?? '';

    if (responderName.isEmpty && currentUser != null) {
      try {
        final userDoc = await FirebaseFirestore.instance
            .collection('manage_users')
            .doc(currentUser.uid)
            .get();
        if (userDoc.exists) {
          final data = userDoc.data() ?? {};
          responderName = (data['fullName'] ??
                  data['name'] ??
                  data['displayName'] ??
                  data['username'] ??
                  '')
              .toString()
              .trim();
        }
      } catch (_) {}
    }

    if (responderName.isEmpty) {
      final email = currentUser?.email;
      if (email != null && email.contains('@')) {
        responderName = email.split('@').first;
      }
    }
    if (responderName.isEmpty) responderName = 'Responder';
    return responderName;
  }

  // ✅ Targeted queries instead of downloading the whole incident_reports
  //    collection.
  Future<String?> _findReporterUserId(String incidentId) async {
    final db = FirebaseFirestore.instance;

    bool valid(String? uid) =>
        uid != null && uid.isNotEmpty && uid != 'eoc-user';

    try {
      final directDoc =
          await db.collection('incident_reports').doc(incidentId).get();
      if (directDoc.exists) {
        final uid = directDoc.data()?['userId']?.toString();
        if (valid(uid)) return uid;
      }
    } catch (_) {}

    for (final field in const ['incidentId', 'reportId']) {
      try {
        final snap = await db
            .collection('incident_reports')
            .where(field, isEqualTo: incidentId)
            .limit(1)
            .get();
        if (snap.docs.isNotEmpty) {
          final uid = snap.docs.first.data()['userId']?.toString();
          if (valid(uid)) return uid;
        }
      } catch (e) {
        debugPrint('Error querying incident_reports by $field: $e');
      }
    }

    return null;
  }

  Future<void> _notifyReporterResponderAssigned() async {
    try {
      final incidentId = _incidentData['incidentId']?.toString();
      if (incidentId == null || incidentId.isEmpty) return;

      final currentUser = FirebaseAuth.instance.currentUser;
      final responderName = await _resolveResponderName();
      final reporterUserId = await _findReporterUserId(incidentId);

      if (reporterUserId == null) {
        debugPrint('Could not find reporter userId for $incidentId.');
        return;
      }

      await FirebaseFirestore.instance.collection('user_notifications').add({
        'userId': reporterUserId,
        'reportId': incidentId,
        'title': 'Responder Assigned',
        'message':
            'A responder has accepted your emergency report and is on the way.',
        'incidentType': _incidentData['type'] ?? 'Unknown',
        'responderName': responderName,
        'responderId': currentUser?.uid ?? '',
        'read': false,
        'type': 'dispatch',
        'createdAt': FieldValue.serverTimestamp(),
      });

      debugPrint(
        'Responder-assigned notification sent to reporter: $reporterUserId',
      );

      await sendPushToUser(
        userId: reporterUserId,
        title: 'Responder Assigned',
        body:
            'A responder has accepted your emergency report and is on the way.',
        data: {'reportId': incidentId, 'type': 'dispatch'},
      );
    } catch (e) {
      debugPrint('Error sending responder-assigned notification: $e');
    }
  }

  Future<void> _notifyReporterResolved() async {
    try {
      final incidentId = _incidentData['incidentId']?.toString();
      if (incidentId == null || incidentId.isEmpty) return;

      final currentUser = FirebaseAuth.instance.currentUser;
      final responderName = await _resolveResponderName();
      final reporterUserId = await _findReporterUserId(incidentId);

      if (reporterUserId == null) {
        debugPrint('Could not find reporter userId for $incidentId.');
        return;
      }

      await FirebaseFirestore.instance.collection('user_notifications').add({
        'userId': reporterUserId,
        'reportId': incidentId,
        'title': 'Emergency Report Resolved',
        'message':
            'Your emergency report has been successfully resolved by the responding team.',
        'incidentType': _incidentData['type'] ?? 'Unknown',
        'responderName': responderName,
        'responderId': currentUser?.uid ?? '',
        'read': false,
        'type': 'verification',
        'createdAt': FieldValue.serverTimestamp(),
      });

      debugPrint(
        'Resolved notification sent to reporter: $reporterUserId',
      );

      await sendPushToUser(
        userId: reporterUserId,
        title: 'Emergency Report Resolved',
        body:
            'Your emergency report has been successfully resolved by the responding team.',
        data: {'reportId': incidentId, 'type': 'verification'},
      );
    } catch (e) {
      debugPrint('Error sending resolved notification: $e');
    }
  }

  void _showDeclineDialog() {
    final reasonController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _Palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: const Text(
          'Decline dispatch',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: _Palette.textPrimary,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Please provide a reason for declining this dispatch. (Optional)',
              style: TextStyle(
                fontSize: 14,
                color: _Palette.textSecondary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: reasonController,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: 'Enter reason (optional)',
                hintStyle: const TextStyle(color: _Palette.textMuted),
                filled: true,
                fillColor: _Palette.bg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(
                    color: _Palette.border,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(
                    color: _Palette.border,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(
                    color: _Palette.primary,
                    width: 1.5,
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              reasonController.dispose();
              Navigator.pop(dialogContext);
            },
            child: const Text(
              'Cancel',
              style: TextStyle(
                color: _Palette.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              final reason = reasonController.text.trim();

              Navigator.pop(dialogContext);

              await _declineIncidentWithReason(reason);

              reasonController.dispose();

              if (mounted) {
                Navigator.pop(context);
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _Palette.danger,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Decline'),
          ),
        ],
      ),
    );
  }

  Future<void> _declineIncidentWithReason(String reason) async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;

      if (currentUser == null) return;

      final incidentId = _incidentData['incidentId'];

      if (incidentId == null) return;

      final querySnapshot = await FirebaseFirestore.instance
          .collection('responder_notifications')
          .where('incidentId', isEqualTo: incidentId)
          .where('userId', isEqualTo: currentUser.uid)
          .limit(1)
          .get();

      if (querySnapshot.docs.isNotEmpty) {
        final docRef = querySnapshot.docs.first.reference;

        await docRef.update({
          'status': 'declined',
          'declineReason': reason.isEmpty ? 'No reason provided' : reason,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          _buildSnackBar('Dispatch declined.', isError: true),
        );
      }
    } catch (e) {
      debugPrint('Error declining incident: $e');
    }
  }

  Future<void> _updateIncidentStatus(String newStatus) async {
    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;

      final incidentId = _incidentData['incidentId'];
      if (incidentId == null) return;

      final querySnapshot = await FirebaseFirestore.instance
          .collection('responder_notifications')
          .where('incidentId', isEqualTo: incidentId)
          .where('userId', isEqualTo: currentUser.uid)
          .limit(1)
          .get();

      if (querySnapshot.docs.isNotEmpty) {
        final docRef = querySnapshot.docs.first.reference;
        await docRef.update({
          'status': newStatus,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
    } catch (e) {
      debugPrint('Error updating incident status: $e');
    }
  }

  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onPressed,
    required double scale,
    bool outlined = false,
  }) {
    if (outlined) {
      return SizedBox(
        height: 52 * scale,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 20 * scale, color: color),
          label: Text(
            label,
            style: TextStyle(
              fontSize: 14.5 * scale,
              fontWeight: FontWeight.w600,
              color: color,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          style: OutlinedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: color,
            side: BorderSide(color: color, width: 1.2),
            padding: EdgeInsets.symmetric(horizontal: 8 * scale),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12 * scale),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 52 * scale,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20 * scale, color: Colors.white),
        label: Text(
          label,
          style: TextStyle(
            fontSize: 14.5 * scale,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: EdgeInsets.symmetric(horizontal: 8 * scale),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12 * scale),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// FinalIncidentReportPage
// ============================================================
class FinalIncidentReportPage extends StatefulWidget {
  final Map<String, dynamic> incidentData;
  final Future<void> Function()? onSubmitted;

  const FinalIncidentReportPage({
    super.key,
    required this.incidentData,
    this.onSubmitted,
  });

  @override
  State<FinalIncidentReportPage> createState() =>
      _FinalIncidentReportPageState();
}

class _FinalIncidentReportPageState extends State<FinalIncidentReportPage> {
  final _formKey = GlobalKey<FormState>();

  // ── Section 1: Incident Information (read-only) ──
  late final TextEditingController _incidentNameController;
  late final TextEditingController _incidentReportIdController;
  late final TextEditingController _incidentTypeController;
  late final TextEditingController _incidentLocationController;
  late final TextEditingController _incidentDateController;

  // ── Section 2: Responder Information ──
  final _contactNumberController = TextEditingController();
  final _personnelCountController = TextEditingController();
  final _genderController = TextEditingController();

  // ── Section 3: Response Details ──
  final _departureTimeController = TextEditingController();
  final _arrivalTimeController = TextEditingController();
  final _completionTimeController = TextEditingController();

  // ── Section 4: Persons Affected ──
  final _personsAffectedController = TextEditingController(text: '0');
  final _injuredController = TextEditingController(text: '0');
  final _rescuedController = TextEditingController(text: '0');
  final _evacuatedController = TextEditingController(text: '0');

  // Focus nodes so the default "0" clears on first tap
  final _personsAffectedFocus = FocusNode();
  final _injuredFocus = FocusNode();
  final _rescuedFocus = FocusNode();
  final _evacuatedFocus = FocusNode();

  // ── Section 5: Submission ──
  String _responderName = 'Responder';
  bool _loadingResponder = true;
  late final String _submittedDateTime;

  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _initializeControllers();
    _loadResponderName();
    _submittedDateTime = _formatDateTimeNow();
    _attachZeroClearingListeners();
  }

  void _initializeControllers() {
    final d = widget.incidentData;

    _incidentNameController = TextEditingController(
      text: d['title'] ?? d['type'] ?? 'Incident/Event Name',
    );
    _incidentReportIdController = TextEditingController(
      text: d['incidentId']?.toString() ?? 'INC-0000-00000',
    );
    _incidentTypeController = TextEditingController(
      text: d['type'] ?? 'Unknown',
    );
    _incidentLocationController = TextEditingController(
      text: d['location'] ?? 'Unknown location',
    );
    _incidentDateController = TextEditingController(
      text: d['date'] ?? _formatDateNow(),
    );

    // Auto-fill from incidentData (dispatch lifecycle times)
    _departureTimeController.text = d['dispatchTime']?.toString() ??
        d['acceptedAtTime']?.toString() ??
        '';
    _arrivalTimeController.text = d['arrivalTime']?.toString() ??
        d['arrivedAtTime']?.toString() ??
        '';
    _completionTimeController.text = _formatTimeNow();

    // Fallback: read cached times directly from SharedPreferences
    _loadCachedLifecycleTimes();

    // Auto-fill responder info from incidentData
    _contactNumberController.text = d['responderPhone']?.toString() ??
        d['phone']?.toString() ??
        '';
    _genderController.text = d['gender']?.toString() ?? '';
  }

  // Clears the default "0" the moment a number field gains focus, so
  // the user can type directly. Restores "0" on blur if left empty.
  void _attachZeroClearingListeners() {
    final pairs = <FocusNode, TextEditingController>{
      _personsAffectedFocus: _personsAffectedController,
      _injuredFocus: _injuredController,
      _rescuedFocus: _rescuedController,
      _evacuatedFocus: _evacuatedController,
    };

    pairs.forEach((node, controller) {
      node.addListener(() {
        if (node.hasFocus) {
          final text = controller.text.trim();
          if (text == '0' || text.isEmpty) {
            controller.clear();
          }
        } else {
          if (controller.text.trim().isEmpty) {
            controller.text = '0';
          }
        }
      });
    });
  }

  // Fallback: read cached lifecycle times directly from SharedPreferences
  Future<void> _loadCachedLifecycleTimes() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final cachedAccepted = prefs.getString(kAcceptedTimeKey);
      final cachedArrival = prefs.getString(kArrivalTimeKey);

      if (!mounted) return;

      // Controllers update themselves — no setState needed (avoids a
      // full-form rebuild).
      if (_departureTimeController.text.trim().isEmpty &&
          cachedAccepted != null &&
          cachedAccepted.isNotEmpty) {
        _departureTimeController.text = cachedAccepted;
      }
      if (_arrivalTimeController.text.trim().isEmpty &&
          cachedArrival != null &&
          cachedArrival.isNotEmpty) {
        _arrivalTimeController.text = cachedArrival;
      }
    } catch (e) {
      debugPrint('Could not load cached lifecycle times: $e');
    }
  }

  @override
  void dispose() {
    _incidentNameController.dispose();
    _incidentReportIdController.dispose();
    _incidentTypeController.dispose();
    _incidentLocationController.dispose();
    _incidentDateController.dispose();

    _contactNumberController.dispose();
    _personnelCountController.dispose();
    _genderController.dispose();

    _departureTimeController.dispose();
    _arrivalTimeController.dispose();
    _completionTimeController.dispose();

    _personsAffectedController.dispose();
    _injuredController.dispose();
    _rescuedController.dispose();
    _evacuatedController.dispose();

    _personsAffectedFocus.dispose();
    _injuredFocus.dispose();
    _rescuedFocus.dispose();
    _evacuatedFocus.dispose();

    super.dispose();
  }

  String _formatDateNow() {
    final now = DateTime.now();
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${months[now.month - 1]} ${now.day}, ${now.year}';
  }

  String _formatTimeNow() {
    final now = DateTime.now();
    final hour = now.hour % 12 == 0 ? 12 : now.hour % 12;
    final minute = now.minute.toString().padLeft(2, '0');
    final period = now.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  String _formatDateTimeNow() {
    return '${_formatDateNow()} – ${_formatTimeNow()}';
  }

  // ✅ Single Firestore read (was reading manage_users twice)
  Future<void> _loadResponderName() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        if (mounted) {
          setState(() {
            _responderName = 'Responder';
            _loadingResponder = false;
          });
        }
        return;
      }

      Map<String, dynamic> profile = {};
      try {
        final doc = await FirebaseFirestore.instance
            .collection('manage_users')
            .doc(user.uid)
            .get();
        if (doc.exists) {
          profile = doc.data() ?? {};
        } else {
          final alt = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get();
          if (alt.exists) profile = alt.data() ?? {};
        }
      } catch (e) {
        debugPrint('Could not load responder profile: $e');
      }

      String? resolved = (profile['fullName'] ??
              profile['name'] ??
              profile['displayName'] ??
              profile['username'])
          ?.toString();

      resolved ??= user.displayName;

      final email = user.email;
      if ((resolved == null || resolved.trim().isEmpty) &&
          email != null &&
          email.contains('@')) {
        resolved = email.split('@').first;
      }

      if (!mounted) return;

      // Fill controllers directly (no rebuild needed for those)
      if (_contactNumberController.text.trim().isEmpty) {
        _contactNumberController.text = profile['phone']?.toString() ??
            profile['phoneNumber']?.toString() ??
            '';
      }
      if (_personnelCountController.text.trim().isEmpty) {
        _personnelCountController.text =
            profile['personnelCount']?.toString() ?? '';
      }
      if (_genderController.text.trim().isEmpty) {
        _genderController.text = profile['gender']?.toString() ?? '';
      }

      setState(() {
        _responderName = (resolved != null && resolved.trim().isNotEmpty)
            ? resolved.trim()
            : 'Responder';
        _loadingResponder = false;
      });
    } catch (e) {
      debugPrint('Error resolving responder name: $e');
      if (mounted) {
        setState(() {
          _responderName =
              FirebaseAuth.instance.currentUser?.displayName ?? 'Responder';
          _loadingResponder = false;
        });
      }
    }
  }

  // ============================================================
  // Submit — saves ONLY final_reports, then closes right away.
  // The parent's onSubmitted (fire-and-forget) does the rest in the
  // background, so the spinner never hangs.
  // ============================================================
  Future<void> _submitReport() async {
    if (_isSubmitting) return; // prevent double taps

    final missingField = _findFirstMissingRequiredField();
    if (missingField != null) {
      _showMissingFieldDialog(missingField);
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();
    setState(() => _isSubmitting = true);

    try {
      final currentUser = FirebaseAuth.instance.currentUser;
      final incidentId = widget.incidentData['incidentId']?.toString() ??
          'INC-${DateTime.now().millisecondsSinceEpoch}';

      final reportPayload = <String, dynamic>{
        'incidentId': incidentId,
        'incidentName': _incidentNameController.text.trim(),
        'incidentType': _incidentTypeController.text.trim(),
        'incidentLocation': _incidentLocationController.text.trim(),
        'incidentDate': _incidentDateController.text.trim(),

        'contactNumber': _contactNumberController.text.trim(),
        'numberOfPersonnel':
            int.tryParse(_personnelCountController.text.trim()) ?? 0,
        'gender': _genderController.text.trim(),

        'departureTime': _departureTimeController.text.trim(),
        'arrivalTime': _arrivalTimeController.text.trim(),
        'completionTime': _completionTimeController.text.trim(),

        'personsAffected':
            int.tryParse(_personsAffectedController.text.trim()) ?? 0,
        'injured': int.tryParse(_injuredController.text.trim()) ?? 0,
        'rescued': int.tryParse(_rescuedController.text.trim()) ?? 0,
        'evacuated': int.tryParse(_evacuatedController.text.trim()) ?? 0,

        'responderName': _responderName,
        'responderId': currentUser?.uid ?? '',
        'responderEmail': currentUser?.email ?? '',
        'submittedDateTime': _submittedDateTime,

        'status': 'pending',
        'submittedAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
        'severity': widget.incidentData['severity'] ?? 'medium',
        'description': widget.incidentData['description'] ?? '',
        'reportedBy': widget.incidentData['reporterName'] ??
            widget.incidentData['reporter']?['fullName'] ??
            'System record',
        'unitName': widget.incidentData['unitName'] ?? '',
        'date': widget.incidentData['date'] ?? '',
        'time': widget.incidentData['time'] ?? '',
        'lat': widget.incidentData['lat'],
        'lng': widget.incidentData['lng'],
      };

      await FirebaseFirestore.instance
          .collection('final_reports')
          .doc(incidentId)
          .set(reportPayload, SetOptions(merge: true));

      // ✅ Report is saved. Hand the remaining work (status updates,
      //    notifications) to the parent WITHOUT waiting for it.
      if (widget.onSubmitted != null) {
        unawaited(widget.onSubmitted!.call());
      }

      // ✅ Close immediately — the parent shows the success snackbar.
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint('Error submitting final report: $e');
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error submitting report: ${e.toString()}'),
            backgroundColor: _Palette.danger,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    }
  }

  // Returns the label of the first empty required field, or null if
  // all required fields are filled.
  String? _findFirstMissingRequiredField() {
    final checks = <String, TextEditingController>{
      'Contact number': _contactNumberController,
      'Number of personnel': _personnelCountController,
      'Departure time': _departureTimeController,
      'Arrival time': _arrivalTimeController,
      'Completion time': _completionTimeController,
    };

    for (final entry in checks.entries) {
      if (entry.value.text.trim().isEmpty) {
        return entry.key;
      }
    }
    return null;
  }

  // Modal that tells the user which required field is missing.
  void _showMissingFieldDialog(String fieldLabel) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: _Palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _Palette.dangerLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.warning_amber_rounded,
                color: _Palette.danger,
                size: 22,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Missing information',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: _Palette.textPrimary,
                ),
              ),
            ),
          ],
        ),
        content: RichText(
          text: TextSpan(
            style: const TextStyle(
              fontSize: 14,
              color: _Palette.textSecondary,
              height: 1.5,
            ),
            children: [
              const TextSpan(
                text: 'Please fill up the required field:\n\n',
              ),
              TextSpan(
                text: '• $fieldLabel',
                style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                  color: _Palette.danger,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(
              'OK',
              style: TextStyle(
                color: _Palette.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // ✅ sizeOf / paddingOf do NOT rebuild on every keyboard animation
    //    frame (MediaQuery.of did — that was the typing lag).
    final screenWidth = MediaQuery.sizeOf(context).width;
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final scale = (screenWidth / 390).clamp(0.85, 1.15);

    return Scaffold(
      backgroundColor: _Palette.bg,
      appBar: AppBar(
        backgroundColor: _Palette.primary,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Responder final report',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(
            16 * scale,
            16 * scale,
            16 * scale,
            24 * scale + bottomPadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSectionCard(
                scale: scale,
                number: '1',
                title: 'Incident information',
                children: [
                  _buildReadOnlyRow('Incident/Event name',
                      _incidentNameController.text, scale),
                  _buildReadOnlyRow('Incident report ID',
                      _incidentReportIdController.text, scale),
                  _buildReadOnlyRow('Incident type',
                      _incidentTypeController.text, scale),
                  _buildReadOnlyRow('Incident location',
                      _incidentLocationController.text, scale),
                  _buildReadOnlyRow('Date', _incidentDateController.text, scale,
                      isLast: true),
                ],
              ),
              SizedBox(height: 12 * scale),

              _buildSectionCard(
                scale: scale,
                number: '2',
                title: 'Responder information',
                children: [
                  _buildTextField(
                    label: 'Contact number',
                    controller: _contactNumberController,
                    scale: scale,
                    required: true,
                    hint: 'e.g., 09XX-XXX-XXXX',
                    keyboardType: TextInputType.phone,
                  ),
                  SizedBox(height: 12 * scale),
                  _buildTextField(
                    label: 'Number of personnel',
                    controller: _personnelCountController,
                    scale: scale,
                    required: true,
                    hint: 'e.g., 3',
                    keyboardType: TextInputType.number,
                  ),
                  SizedBox(height: 12 * scale),
                  _buildTextField(
                    label: 'Gender',
                    controller: _genderController,
                    scale: scale,
                    required: false,
                    hint: 'e.g., Male / Female',
                  ),
                ],
              ),
              SizedBox(height: 12 * scale),

              _buildSectionCard(
                scale: scale,
                number: '3',
                title: 'Response details',
                children: [
                  _buildTextField(
                    label: 'Departure time',
                    controller: _departureTimeController,
                    scale: scale,
                    required: true,
                    hint: 'e.g., 10:20 AM',
                  ),
                  SizedBox(height: 12 * scale),
                  _buildTextField(
                    label: 'Arrival time',
                    controller: _arrivalTimeController,
                    scale: scale,
                    required: true,
                    hint: 'e.g., 10:35 AM',
                  ),
                  SizedBox(height: 12 * scale),
                  _buildTextField(
                    label: 'Completion time',
                    controller: _completionTimeController,
                    scale: scale,
                    required: true,
                    hint: 'e.g., 11:20 AM',
                  ),
                ],
              ),
              SizedBox(height: 12 * scale),

              _buildSectionCard(
                scale: scale,
                number: '4',
                title: 'Persons affected',
                children: [
                  _buildNumberField(
                    label: 'Number of persons affected',
                    controller: _personsAffectedController,
                    scale: scale,
                    focusNode: _personsAffectedFocus,
                  ),
                  SizedBox(height: 12 * scale),
                  _buildNumberField(
                    label: 'Number injured',
                    controller: _injuredController,
                    scale: scale,
                    focusNode: _injuredFocus,
                  ),
                  SizedBox(height: 12 * scale),
                  _buildNumberField(
                    label: 'Number rescued',
                    controller: _rescuedController,
                    scale: scale,
                    focusNode: _rescuedFocus,
                  ),
                  SizedBox(height: 12 * scale),
                  _buildNumberField(
                    label: 'Number evacuated',
                    controller: _evacuatedController,
                    scale: scale,
                    focusNode: _evacuatedFocus,
                  ),
                ],
              ),
              SizedBox(height: 12 * scale),

              _buildSectionCard(
                scale: scale,
                number: '5',
                title: 'Submission',
                children: [
                  _buildReadOnlyRow(
                    'Responder name',
                    _loadingResponder ? 'Loading…' : _responderName,
                    scale,
                  ),
                  _buildReadOnlyRow(
                    'Date & time submitted',
                    _submittedDateTime,
                    scale,
                    isLast: true,
                  ),
                ],
              ),
              SizedBox(height: 20 * scale),

              SizedBox(
                width: double.infinity,
                height: 52 * scale,
                child: ElevatedButton.icon(
                  onPressed: _isSubmitting ? null : _submitReport,
                  icon: _isSubmitting
                      ? SizedBox(
                          width: 18 * scale,
                          height: 18 * scale,
                          child: const CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white,
                          ),
                        )
                      : Icon(Icons.send_rounded, size: 18 * scale),
                  label: Text(
                    _isSubmitting ? 'Submitting…' : 'Submit final report',
                    style: TextStyle(
                      fontSize: 15 * scale,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _Palette.primary,
                    disabledBackgroundColor:
                        _Palette.primary.withValues(alpha: 0.6),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12 * scale),
                    ),
                  ),
                ),
              ),
              SizedBox(height: 12 * scale),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  // Section card — grey header band + padded body
  // RepaintBoundary keeps typing in one section from repainting others.
  // ─────────────────────────────────────────────────────────
  Widget _buildSectionCard({
    required double scale,
    required String number,
    required String title,
    String? subtitle,
    required List<Widget> children,
  }) {
    return RepaintBoundary(
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16 * scale),
          border: Border.all(color: _Palette.border, width: 1),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15 * scale),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header band ──
              Container(
                width: double.infinity,
                color: const Color(0xFFF6F8FB),
                padding: EdgeInsets.symmetric(
                  horizontal: 16 * scale,
                  vertical: 14 * scale,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36 * scale,
                      height: 36 * scale,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _Palette.primaryLight,
                        borderRadius: BorderRadius.circular(10 * scale),
                      ),
                      child: Text(
                        number,
                        style: TextStyle(
                          fontSize: 16 * scale,
                          fontWeight: FontWeight.w800,
                          color: _Palette.primary,
                        ),
                      ),
                    ),
                    SizedBox(width: 12 * scale),
                    Container(
                      width: 1,
                      height: 28 * scale,
                      color: _Palette.border,
                    ),
                    SizedBox(width: 12 * scale),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 18 * scale,
                              fontWeight: FontWeight.w800,
                              color: _Palette.textPrimary,
                            ),
                          ),
                          if (subtitle != null) ...[
                            SizedBox(height: 2 * scale),
                            Text(
                              subtitle,
                              style: TextStyle(
                                fontSize: 12 * scale,
                                color: _Palette.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // ── Body ──
              Padding(
                padding: EdgeInsets.all(16 * scale),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────────────────
  // Read-only row — bold label : left-aligned value
  // ─────────────────────────────────────────────────────────
  Widget _buildReadOnlyRow(String label, String value, double scale,
      {bool isLast = false}) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : 16 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14 * scale,
                color: _Palette.textPrimary,
                fontWeight: FontWeight.w800,
                height: 1.3,
              ),
            ),
          ),
          SizedBox(
            width: 18 * scale,
            child: Text(
              ':',
              style: TextStyle(
                fontSize: 14 * scale,
                color: _Palette.textSecondary,
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
            ),
          ),
          Expanded(
            flex: 7,
            child: Text(
              value,
              textAlign: TextAlign.left,
              style: TextStyle(
                fontSize: 14 * scale,
                color: _Palette.textPrimary,
                fontWeight: FontWeight.w400,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required String label,
    required TextEditingController controller,
    required double scale,
    bool required = false,
    String? hint,
    TextInputType? keyboardType,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 13 * scale,
                fontWeight: FontWeight.w600,
                color: _Palette.textPrimary,
              ),
            ),
            if (required) ...[
              SizedBox(width: 4 * scale),
              Text(
                '*',
                style: TextStyle(
                  fontSize: 13 * scale,
                  fontWeight: FontWeight.w600,
                  color: _Palette.danger,
                ),
              ),
            ],
          ],
        ),
        SizedBox(height: 6 * scale),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          validator: required
              ? (v) => (v == null || v.trim().isEmpty)
                  ? '$label is required'
                  : null
              : null,
          decoration: _inputDecoration(hint: hint ?? '', scale: scale),
          style: TextStyle(
            fontSize: 13.5 * scale,
            color: _Palette.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildNumberField({
    required String label,
    required TextEditingController controller,
    required double scale,
    FocusNode? focusNode,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 13 * scale,
            color: _Palette.textSecondary,
            fontWeight: FontWeight.w500,
          ),
        ),
        SizedBox(height: 6 * scale),
        TextFormField(
          controller: controller,
          focusNode: focusNode,
          keyboardType: TextInputType.number,
          decoration: _inputDecoration(hint: '0', scale: scale),
          style: TextStyle(
            fontSize: 13.5 * scale,
            fontWeight: FontWeight.w600,
            color: _Palette.textPrimary,
          ),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration({
    required String hint,
    required double scale,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        fontSize: 12.5 * scale,
        color: _Palette.textMuted,
      ),
      filled: true,
      fillColor: _Palette.bg,
      contentPadding:
          EdgeInsets.symmetric(horizontal: 12 * scale, vertical: 12 * scale),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10 * scale),
        borderSide: const BorderSide(color: _Palette.border, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10 * scale),
        borderSide: const BorderSide(color: _Palette.border, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10 * scale),
        borderSide: const BorderSide(color: _Palette.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10 * scale),
        borderSide: const BorderSide(color: _Palette.danger, width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10 * scale),
        borderSide: const BorderSide(color: _Palette.danger, width: 1.5),
      ),
    );
  }
}