// lib/components/map_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'assigned_route_store.dart';
import 'incident_details_page.dart';
import '../services/send_push_notification.dart';

// Keys shared with incident_details_page.dart
const String kActiveDispatchKey = 'active_dispatch_incident';
const String kActiveDispatchIdKey = 'active_dispatch_incident_id';

// Separate keys for "last incident the responder opened in the map"
const String kLastNavigatedKey = 'last_navigated_incident';
const String kLastNavigatedIdKey = 'last_navigated_incident_id';

// ✅ explicit destination keys — always the INCIDENT location
const String kActiveIncidentLatKey = 'active_incident_lat';
const String kActiveIncidentLngKey = 'active_incident_lng';

// ✅ Cached lifecycle times — persist across page exits
const String kAcceptedTimeKey = 'active_dispatch_accepted_time';
const String kArrivalTimeKey = 'active_dispatch_arrival_time';

// ─────────────────────────────────────────────────────────────────────────
// DEEP-CAST helpers
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

// ✅ Makes Firestore types (Timestamp, GeoPoint, DateTime) safe for jsonEncode
Object? _jsonSafe(Object? o) {
  if (o is Timestamp) return o.millisecondsSinceEpoch;
  if (o is DateTime) return o.toIso8601String();
  if (o is GeoPoint) return {'lat': o.latitude, 'lng': o.longitude};
  return o.toString();
}

String _safeJsonEncode(Map<String, dynamic> data) =>
    jsonEncode(data, toEncodable: _jsonSafe);

// ✅ Lightweight container for an EOC-assigned route.
class AssignedRoute {
  final String incidentId;
  final List<LatLng> points;
  final double distanceMeters;
  final double durationSeconds;
  final List<Map<String, dynamic>> steps;
  final Map<String, dynamic>? avoidedLocation;

  // ✅ incident details carried with the route
  final String incidentType;
  final String incidentTitle;
  final String incidentLocation;
  final String incidentDate;
  final String incidentTime;
  final String incidentDescription;
  final String incidentSeverity;
  final String reporterName;
  final String reporterPhone;
  final Map<String, dynamic> casualties;

  const AssignedRoute({
    required this.incidentId,
    required this.points,
    required this.distanceMeters,
    required this.durationSeconds,
    required this.steps,
    this.avoidedLocation,
    this.incidentType = '',
    this.incidentTitle = '',
    this.incidentLocation = '',
    this.incidentDate = '',
    this.incidentTime = '',
    this.incidentDescription = '',
    this.incidentSeverity = 'medium',
    this.reporterName = '',
    this.reporterPhone = '',
    this.casualties = const {},
  });

  static AssignedRoute? fromRouteData(dynamic raw) {
    if (raw is! Map) return null;

    final incidentId = (raw['incidentId'] ?? '').toString();
    final distanceMeters = (raw['distanceMeters'] is num)
        ? (raw['distanceMeters'] as num).toDouble()
        : 0.0;
    final durationSeconds = (raw['durationSeconds'] is num)
        ? (raw['durationSeconds'] as num).toDouble()
        : 0.0;

    final List<LatLng> pts = [];

    final geom = raw['geometry'] ?? raw['points'];
    if (geom is List) {
      for (final g in geom) {
        if (g is Map) {
          final la = (g['lat'] as num?)?.toDouble();
          final ln = (g['lng'] as num?)?.toDouble();
          if (la != null && ln != null) pts.add(LatLng(la, ln));
        }
      }
    }

    final List<Map<String, dynamic>> steps = [];
    final stepsRaw = raw['steps'];
    if (stepsRaw is List) {
      for (final s in stepsRaw) {
        if (s is Map) {
          steps.add(_deepCastMap(s));
        }
      }
    }

    Map<String, dynamic>? avoided;
    final avoidedRaw = raw['avoidedLocation'];
    if (avoidedRaw is Map) {
      avoided = _deepCastMap(avoidedRaw);
    }

    Map<String, dynamic> cas = {};
    final casRaw = raw['casualties'];
    if (casRaw is Map) cas = _deepCastMap(casRaw);

    if (pts.length < 2) return null;

    return AssignedRoute(
      incidentId: incidentId,
      points: pts,
      distanceMeters: distanceMeters,
      durationSeconds: durationSeconds,
      steps: steps,
      avoidedLocation: avoided,
      incidentType: (raw['incidentType'] ?? '').toString(),
      incidentTitle: (raw['incidentTitle'] ?? '').toString(),
      incidentLocation: (raw['incidentLocation'] ?? '').toString(),
      incidentDate: (raw['incidentDate'] ?? '').toString(),
      incidentTime: (raw['incidentTime'] ?? '').toString(),
      incidentDescription: (raw['incidentDescription'] ?? '').toString(),
      incidentSeverity:
          (raw['incidentSeverity'] ?? 'medium').toString(),
      reporterName: (raw['reporterName'] ?? '').toString(),
      reporterPhone: (raw['reporterPhone'] ?? '').toString(),
      casualties: cas,
    );
  }
}

class MapPage extends StatefulWidget {
  final LatLng? incidentLocation;
  final Map<String, dynamic>? incidentData;

  final AssignedRoute? assignedRoute;

  const MapPage({
    super.key,
    this.incidentLocation,
    this.incidentData,
    this.assignedRoute,
  });

  @override
  State<MapPage> createState() => MapPageState();
}

class MapPageState extends State<MapPage> {
  final MapController _mapController = MapController();
  final Location _locationService = Location();

  double _currentZoom = 15.5;
  bool _isSatellite = false;
  bool _isLoadingRoute = false;
  String? _routeError;

  LatLng _responderLocation = const LatLng(13.6248, 123.1862);

  static const String _streetMapUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  static const String _satelliteMapUrl =
      'https://server.arcgisonline.com/ArcGIS/rest/services/'
      'World_Imagery/MapServer/tile/{z}/{y}/{x}';

  List<LatLng> _routePoints = [];
  double _distanceKm = 0.0;
  int _estimatedMinutes = 0;

  bool _arrivedAtScene = false;
  bool _missionCompleted = false;

  AssignedRoute? _assignedRoute;

  StreamSubscription<LocationData>? _locationSubscription;
  String? _trackingIncidentId;
  DateTime _lastFirestoreWrite = DateTime.fromMillisecondsSinceEpoch(0);

  // ✅ auto-refresh timer (keeps map + route fresh every 20s)
  Timer? _autoRefreshTimer;
  static const Duration _autoRefreshInterval = Duration(seconds: 20);

  String _cachedResponderName = '';
  String? _cachedResponderPhoto;

  static const double _detailsMaxHeight = 110.0;

  final ScrollController _detailsScrollController = ScrollController();

  Map<String, dynamic>? _resolvedIncidentData;
  LatLng? _resolvedIncidentLocation;

  bool _restoring = false;

  bool _assignedRouteApplied = false;

  String? _consumedAssignedRouteForIncident;

  // ✅ Bumped whenever the route is cleared / replaced so that any
  //    in-flight OSRM request from the OLD route is ignored when it returns.
  int _routeGeneration = 0;

  // ✅ true when the road route could not be fetched and we show a direct line
  bool _isFallbackRoute = false;

  // ✅ throttle for the self-healing route check
  DateTime _lastEnsureRoute = DateTime.fromMillisecondsSinceEpoch(0);

  // ✅ Helper: 12-hour formatted time string
  String _formatTime12h(DateTime dt) {
    final hour = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final minute = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
  }

  // ============================================================
  // ✅ Central "wipe the old polyline" helper.
  //    Clears local state, the persisted assigned route, and
  //    (optionally) the Firestore mirror the EOC is watching.
  // ============================================================
  Future<void> _clearRouteState({bool publish = true}) async {
    _routeGeneration++;
    _assignedRoute = null;
    _assignedRouteApplied = false;
    _consumedAssignedRouteForIncident = null;

    try {
      await AssignedRouteStore.clear();
    } catch (_) {}

    if (mounted) {
      setState(() {
        _routePoints = [];
        _distanceKm = 0.0;
        _estimatedMinutes = 0;
        _routeError = null;
        _isLoadingRoute = false;
        _isFallbackRoute = false;
      });
    }

    if (publish) {
      _publishRouteToFirestore(
        points: const [],
        distanceKm: 0,
        etaMinutes: 0,
        isAssigned: false,
      );
    }
  }

  @override
  void initState() {
    super.initState();

    _resolvedIncidentData = widget.incidentData;
    _resolvedIncidentLocation = widget.incidentLocation;

    _assignedRoute = widget.assignedRoute;
    _assignedRouteApplied = false;

    _bootstrap();
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _locationSubscription?.cancel();
    _detailsScrollController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant MapPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    final newId = widget.incidentData?['incidentId']?.toString();
    final oldId = _resolvedIncidentData?['incidentId']?.toString();

    final incidentChanged = widget.incidentData != null &&
        widget.incidentData!.isNotEmpty &&
        newId != null &&
        newId != oldId;

    // ─────────────────────────────────────────────
    // A DIFFERENT incident was opened → wipe everything
    // from the previous one and start fresh.
    // ─────────────────────────────────────────────
    if (incidentChanged) {
      _autoRefreshTimer?.cancel();

      _resolvedIncidentData = widget.incidentData;
      _resolvedIncidentLocation = widget.incidentLocation;
      _missionCompleted = false;
      _arrivedAtScene = false;

      _persistLastNavigated(_resolvedIncidentData!);
      _maybePersistAsActiveDispatch(_resolvedIncidentData!);

      final keepAssigned = widget.assignedRoute != null &&
          widget.assignedRoute!.incidentId == newId;

      if (!keepAssigned) {
        _clearRouteState(publish: false).then((_) {
          if (mounted) _bootstrap();
        });
      } else {
        _routeGeneration++;
        _assignedRoute = widget.assignedRoute;
        _assignedRouteApplied = false;
        _consumedAssignedRouteForIncident = null;
        _routePoints = [];
        _bootstrap();
      }
      return;
    }

    // ─────────────────────────────────────────────
    // Same incident, but the parent now passes NO assigned route
    // (e.g. responder tapped "Navigate to Incident") → drop the
    // old assigned polyline and fall back to a fresh OSRM route.
    // ─────────────────────────────────────────────
    if (widget.assignedRoute == null &&
        oldWidget.assignedRoute != null &&
        _assignedRouteApplied) {
      _clearRouteState(publish: false).then((_) {
        if (mounted && !_missionCompleted) _initializeMap();
      });
    }

    // ─────────────────────────────────────────────
    // EOC sent a NEW assigned route → replace the old polyline.
    // ─────────────────────────────────────────────
    if (widget.assignedRoute != null &&
        !identical(widget.assignedRoute, oldWidget.assignedRoute)) {
      _routeGeneration++;
      _assignedRoute = widget.assignedRoute;
      _assignedRouteApplied = false;
      _consumedAssignedRouteForIncident = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _assignedRoute != null) {
          _applyAssignedRoute(_assignedRoute!);
        }
      });
    }

    if (oldWidget.incidentLocation != widget.incidentLocation &&
        widget.incidentLocation != null) {
      _resolvedIncidentLocation = widget.incidentLocation;

      if (_assignedRouteApplied) {
        setState(() {});
      } else {
        _initializeMap();
      }
    }

    // ✅ Whatever changed, make sure a route exists for the active incident
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureRoute());
  }

  // ============================================================
  // ✅ Called from HomePage when the Map tab becomes visible
  //    (and every auto-refresh tick).
  //    Re-checks whether a final report has been submitted so the
  //    bottom button flips to "Report Submitted" and the old
  //    polyline vanishes without needing to reload.
  // ============================================================
  Future<void> refreshMissionStatus({bool ensureRoute = true}) async {
    final incidentId = _resolvedIncidentData?['incidentId']?.toString();
    if (incidentId == null || incidentId.isEmpty) return;

    try {
      final doc = await FirebaseFirestore.instance
          .collection('final_reports')
          .doc(incidentId)
          .get();

      if (!mounted) return;

      if (doc.exists) {
        if (!_missionCompleted) {
          setState(() {
            _missionCompleted = true;
            _arrivedAtScene = true;
            _resolvedIncidentData?['status'] = 'solved';
          });

          _autoRefreshTimer?.cancel();

          // ✅ Polyline vanishes immediately + EOC mirror is cleared
          await _clearRouteState();
          await _clearPersistedIncident();

          debugPrint(
            '✅ [MAP REFRESH] Final report detected — route cleared, '
            'button → Report Submitted',
          );
        } else if (_routePoints.isNotEmpty || _assignedRoute != null) {
          // Already completed but a stale polyline is still around
          await _clearRouteState();
        }
      }
    } catch (e) {
      debugPrint('refreshMissionStatus error: $e');
    }

    // ✅ Map tab opened / accept dispatch → guarantee the polyline exists
    if (ensureRoute) _ensureRoute();
  }

  // ============================================================
  // BOOTSTRAP
  // ============================================================
  Future<void> _bootstrap() async {
    setState(() {
      _restoring = true;
    });

    try {
      await _loadResponderIdentity();

      Map<String, dynamic>? baseline;

      if (_resolvedIncidentData != null && _resolvedIncidentData!.isNotEmpty) {
        baseline = Map<String, dynamic>.from(_resolvedIncidentData!);
      } else {
        baseline = await _loadLastNavigatedFromDisk();
        if (baseline == null) {
          baseline = await _loadActiveDispatchFromDisk();
        }

        // ✅ If this saved incident already has a final report, drop it.
        //    Otherwise keep restoring it, even after the app was closed.
        final savedId = baseline?['incidentId']?.toString();
        if (savedId != null && savedId.isNotEmpty) {
          try {
            final done = await FirebaseFirestore.instance
                .collection('final_reports')
                .doc(savedId)
                .get();
            if (done.exists) {
              await _clearPersistedIncident();
              baseline = null;
            }
          } catch (e) {
            debugPrint('Could not verify final report on restore: $e');
          }
        }
      }

      final prefs = await SharedPreferences.getInstance();
      final explicitLat = prefs.getDouble(kActiveIncidentLatKey);
      final explicitLng = prefs.getDouble(kActiveIncidentLngKey);

      if (baseline == null) {
        baseline = <String, dynamic>{};
      }
      if (explicitLat != null && explicitLng != null) {
        baseline['lat'] = explicitLat;
        baseline['lng'] = explicitLng;
      }

      // ✅ Merge cached lifecycle times so they survive page exits
      try {
        final cachedAccepted = prefs.getString(kAcceptedTimeKey);
        final cachedArrival = prefs.getString(kArrivalTimeKey);
        if (cachedAccepted != null && cachedAccepted.isNotEmpty) {
          baseline['dispatchTime'] ??= cachedAccepted;
          baseline['acceptedAtTime'] ??= cachedAccepted;
        }
        if (cachedArrival != null && cachedArrival.isNotEmpty) {
          baseline['arrivalTime'] ??= cachedArrival;
          baseline['arrivedAtTime'] ??= cachedArrival;
        }
      } catch (e) {
        debugPrint('Could not merge cached times in bootstrap: $e');
      }

      final fresh = await _restoreActiveIncidentFromFirestore();

      final incidentLoc = await _fetchIncidentLocationFromFirestore(
        baseline['incidentId']?.toString() ?? fresh?['incidentId']?.toString(),
      );

      if (baseline.isNotEmpty) {
        final merged = Map<String, dynamic>.from(baseline);

        if (fresh != null) {
          _mergeIfPresent(merged, fresh, 'status');
          _mergeIfPresent(merged, fresh, 'acceptedAt');
          _mergeIfPresent(merged, fresh, 'updatedAt');
          _mergeIfPresent(merged, fresh, 'arrivedAt');
          _mergeIfPresent(merged, fresh, 'incidentId');
          _mergeIfPresent(merged, fresh, 'responderId');
          _mergeIfPresent(merged, fresh, 'responderName');
          _mergeIfPresent(merged, fresh, 'dispatchTime');
          _mergeIfPresent(merged, fresh, 'acceptedAtTime');
          _mergeIfPresent(merged, fresh, 'arrivalTime');
          _mergeIfPresent(merged, fresh, 'arrivedAtTime');
        }

        if (incidentLoc != null) {
          merged['lat'] = incidentLoc['lat'];
          merged['lng'] = incidentLoc['lng'];
          _mergeIfPresent(merged, incidentLoc, 'location');
          _mergeIfPresent(merged, incidentLoc, 'address');
        }

        _resolvedIncidentData = merged;
      } else if (fresh != null) {
        final merged = Map<String, dynamic>.from(fresh);
        if (incidentLoc != null) {
          merged['lat'] = incidentLoc['lat'];
          merged['lng'] = incidentLoc['lng'];
          _mergeIfPresent(merged, incidentLoc, 'location');
          _mergeIfPresent(merged, incidentLoc, 'address');
        }
        _resolvedIncidentData = merged;
      }

      if (_assignedRoute != null) {
        final r = _assignedRoute!;
        final merged = Map<String, dynamic>.from(_resolvedIncidentData ?? {});

        if (r.incidentType.isNotEmpty) merged['type'] = r.incidentType;
        if (r.incidentTitle.isNotEmpty) merged['title'] = r.incidentTitle;
        if (r.incidentLocation.isNotEmpty) {
          merged['location'] = r.incidentLocation;
        }
        if (r.incidentDate.isNotEmpty) merged['date'] = r.incidentDate;
        if (r.incidentTime.isNotEmpty) merged['time'] = r.incidentTime;
        if (r.incidentDescription.isNotEmpty) {
          merged['description'] = r.incidentDescription;
        }
        if (r.incidentSeverity.isNotEmpty) {
          merged['severity'] = r.incidentSeverity;
        }
        if (r.reporterName.isNotEmpty) {
          merged['reporterName'] = r.reporterName;
        }
        if (r.reporterPhone.isNotEmpty) {
          merged['reporterPhone'] = r.reporterPhone;
        }
        if (r.casualties.isNotEmpty) {
          merged['casualties'] = r.casualties;
        }
        merged['incidentId'] = r.incidentId;

        _resolvedIncidentData = merged;
      }

      if (_resolvedIncidentData != null && _resolvedIncidentData!.isNotEmpty) {
        _applyIncidentData(_resolvedIncidentData!);
        await _persistLastNavigated(_resolvedIncidentData!);
        await _maybePersistAsActiveDispatch(_resolvedIncidentData!);
      }
    } finally {
      if (mounted) {
        setState(() {
          _restoring = false;
        });
      }
    }

    // ✅ Incident already solved → never draw (or restore) any polyline
    if (_missionCompleted) {
      await _clearRouteState();
      _startLiveTracking();
      return;
    }

    if (_assignedRoute != null) {
      _applyAssignedRoute(_assignedRoute!);
      _startLiveTracking();
      return;
    }

    final persisted = await AssignedRouteStore.load();
    if (persisted != null) {
      final currentId = _resolvedIncidentData?['incidentId']?.toString();

      // ✅ Only reuse a persisted route if it belongs to THIS incident
      final matches = currentId != null && currentId == persisted.incidentId;

      if (matches &&
          _consumedAssignedRouteForIncident != persisted.incidentId) {
        _consumedAssignedRouteForIncident = persisted.incidentId;
        _assignedRoute = persisted;
        _applyAssignedRoute(persisted);
        _startLiveTracking();
        return;
      } else if (!matches) {
        // Stale route from an older incident → throw it away
        try {
          await AssignedRouteStore.clear();
        } catch (_) {}
      }
    }

    await _initializeMap();
    _startLiveTracking();
  }

  // ============================================================
  // Apply an EOC-assigned route + publish to Firestore for EOC mirror
  // ============================================================
  void _applyAssignedRoute(AssignedRoute route) {
    debugPrint(
      '🗺️ [ASSIGNED ROUTE] incident=${route.incidentId} '
      'points=${route.points.length} '
      'distance=${route.distanceMeters}m '
      'duration=${route.durationSeconds}s ',
    );

    if (_missionCompleted) return;

    // ✅ invalidate any in-flight OSRM request
    _routeGeneration++;

    _assignedRoute = route;
    _assignedRouteApplied = true;

    if (!mounted) return;
    setState(() {
      _routePoints = List<LatLng>.from(route.points);
      _distanceKm = route.distanceMeters / 1000.0;
      _estimatedMinutes = math.max(1, (route.durationSeconds / 60.0).ceil());
      _isFallbackRoute = false;
      _routeError = null;
      _isLoadingRoute = false;
    });

    // ✅ publish to Firestore so EOC mirrors this exact route live
    _publishRouteToFirestore(
      points: _routePoints,
      distanceKm: _distanceKm,
      etaMinutes: _estimatedMinutes,
      isAssigned: true,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitAssignedRoute();
    });
  }

  void _fitAssignedRoute() {
    if (_assignedRoute == null) return;
    if (_assignedRoute!.points.length < 2) return;

    final bounds = LatLngBounds.fromPoints(_assignedRoute!.points);
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.fromLTRB(45, 45, 45, 240),
      ),
    );
    if (!mounted) return;
    setState(() {
      _currentZoom = _mapController.camera.zoom;
    });
  }

  // ============================================================
  // ✅ PUBLISH CURRENT ROUTE → Firestore so EOC mirrors it live
  // ============================================================
  Future<void> _publishRouteToFirestore({
    required List<LatLng> points,
    required double distanceKm,
    required int etaMinutes,
    bool isAssigned = false,
  }) async {
    final incidentId = _resolvedIncidentData?['incidentId']?.toString();
    if (incidentId == null || incidentId.isEmpty) return;

    try {
      final user = FirebaseAuth.instance.currentUser;

      if (points.length < 2) {
        await FirebaseFirestore.instance
            .collection('responder_routes')
            .doc(incidentId)
            .set({
          'incidentId': incidentId,
          'responderId': user?.uid ?? '',
          'points': [],
          'distanceKm': 0,
          'etaMinutes': 0,
          'distanceText': '--',
          'etaText': '--',
          'isAssigned': false,
          'cleared': true,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        debugPrint('🛰️ [EOC SYNC] Route CLEARED for $incidentId');
        return;
      }

      // ✅ Never publish a route for a completed mission
      if (_missionCompleted) return;

      final distanceText = distanceKm < 1
          ? '${(distanceKm * 1000).round()} m'
          : '${distanceKm.toStringAsFixed(1)} km';
      final etaText = etaMinutes <= 1 ? '1 min' : '$etaMinutes min';

      final payload = <String, dynamic>{
        'incidentId': incidentId,
        'responderId': user?.uid ?? '',
        'points': points
            .map((p) => {'lat': p.latitude, 'lng': p.longitude})
            .toList(),
        'distanceKm': distanceKm,
        'etaMinutes': etaMinutes,
        'distanceText': distanceText,
        'etaText': etaText,
        'isAssigned': isAssigned,
        'cleared': false,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('responder_routes')
          .doc(incidentId)
          .set(payload, SetOptions(merge: true));

      debugPrint(
        '🛰️ [EOC SYNC] Route published for $incidentId — '
        '${points.length} pts, $distanceText, $etaText '
        '(assigned=$isAssigned)',
      );
    } catch (e) {
      debugPrint('⚠️ Failed to publish route to Firestore: $e');
    }
  }

  // ============================================================
  // Responder identity — cached, fetched once
  // ============================================================
  Future<void> _loadResponderIdentity() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (_cachedResponderName.isNotEmpty) return;

    try {
      DocumentSnapshot<Map<String, dynamic>> snap =
          await FirebaseFirestore.instance
              .collection('manage_users')
              .doc(user.uid)
              .get();

      if (!snap.exists) {
        snap = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
      }

      if (snap.exists) {
        final data = snap.data() ?? {};
        final nameFromDb =
            (data['name'] ?? data['fullName'] ?? data['displayName'])
                ?.toString();
        final photoFromDb =
            (data['profile'] ?? data['photoUrl'] ?? data['avatar'])
                ?.toString();

        if (nameFromDb != null && nameFromDb.isNotEmpty) {
          _cachedResponderName = nameFromDb;
        }
        if (photoFromDb != null && photoFromDb.isNotEmpty) {
          _cachedResponderPhoto = photoFromDb;
        }
      }
    } catch (e) {
      debugPrint('⚠️ Could not load responder identity: $e');
    }

    if (_cachedResponderName.isEmpty) {
      _cachedResponderName = user.displayName ?? 'Responder';
    }

    debugPrint(
      '✅ Responder identity cached: '
      'name="$_cachedResponderName" '
      'photo="${_cachedResponderPhoto ?? "none"}"',
    );
  }

  void _applyIncidentData(Map<String, dynamic> data) {
    final lat = (data['lat'] as num?)?.toDouble() ?? 13.6248;
    final lng = (data['lng'] as num?)?.toDouble() ?? 123.1862;
    _resolvedIncidentLocation = LatLng(lat, lng);

    final status = (data['status'] ?? '').toString().toLowerCase();
    _arrivedAtScene = (status == 'on_scene');

    _missionCompleted =
        status == 'solved' || status == 'resolved' || status == 'completed';
  }

  // ============================================================
  // Persistence
  // ============================================================
  Future<void> _persistLastNavigated(Map<String, dynamic> data) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      if (lat != null && lng != null) {
        await prefs.setDouble(kActiveIncidentLatKey, lat);
        await prefs.setDouble(kActiveIncidentLngKey, lng);
      }

      await prefs.setString(kLastNavigatedKey, _safeJsonEncode(data));
      await prefs.setString(
        kLastNavigatedIdKey,
        data['incidentId']?.toString() ?? '',
      );
    } catch (e) {
      debugPrint('Error persisting last navigated incident: $e');
    }
  }

  Future<void> _maybePersistAsActiveDispatch(Map<String, dynamic> data) async {
    final status = (data['status'] ?? '').toString().toLowerCase();
    final accepted = status == 'enroute' || status == 'on_scene';

    if (!accepted) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kActiveDispatchKey, _safeJsonEncode(data));
      await prefs.setString(
        kActiveDispatchIdKey,
        data['incidentId']?.toString() ?? '',
      );
    } catch (e) {
      debugPrint('Error persisting active dispatch: $e');
    }
  }

  Future<Map<String, dynamic>?> _loadLastNavigatedFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kLastNavigatedKey);
      if (raw == null || raw.isEmpty) return null;
      return _deepCastMap(jsonDecode(raw));
    } catch (e) {
      debugPrint('Error decoding last navigated from disk: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>?> _loadActiveDispatchFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(kActiveDispatchKey);
      if (raw == null || raw.isEmpty) return null;
      return _deepCastMap(jsonDecode(raw));
    } catch (e) {
      debugPrint('Error decoding active dispatch from disk: $e');
    }
    return null;
  }

  // ✅ Saved incident data is removed ONLY after the final report is submitted
  Future<void> _clearPersistedIncident() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(kLastNavigatedKey);
      await prefs.remove(kLastNavigatedIdKey);
      await prefs.remove(kActiveDispatchKey);
      await prefs.remove(kActiveDispatchIdKey);
      await prefs.remove(kActiveIncidentLatKey);
      await prefs.remove(kActiveIncidentLngKey);
      await prefs.remove(kAcceptedTimeKey);
      await prefs.remove(kArrivalTimeKey);
    } catch (e) {
      debugPrint('Error clearing persisted incident: $e');
    }
  }

  void _mergeIfPresent(
    Map<String, dynamic> dst,
    Map<String, dynamic> src,
    String key,
  ) {
    final val = src[key];
    if (val == null) return;

    final existing = dst[key];
    final existingEmpty = existing == null ||
        (existing is String &&
            (existing.isEmpty || existing.toLowerCase() == 'none'));

    if (existingEmpty) {
      dst[key] = val;
    }
  }

  Future<Map<String, dynamic>?> _fetchIncidentLocationFromFirestore(
    String? incidentId,
  ) async {
    if (incidentId == null || incidentId.isEmpty) return null;

    try {
      final snap = await FirebaseFirestore.instance
          .collection('monitoring_status')
          .where('incidentId', isEqualTo: incidentId)
          .limit(1)
          .get();

      if (snap.docs.isNotEmpty) {
        final monData = _deepCastMap(snap.docs.first.data());
        final lat = (monData['lat'] as num?)?.toDouble();
        final lng = (monData['lng'] as num?)?.toDouble();

        if (lat != null && lng != null) {
          return {
            'lat': lat,
            'lng': lng,
            'location': monData['location'],
            'address': monData['address'],
          };
        }
      }

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return null;

      final notifSnap = await FirebaseFirestore.instance
          .collection('responder_notifications')
          .where('incidentId', isEqualTo: incidentId)
          .where('userId', isEqualTo: user.uid)
          .limit(1)
          .get();

      if (notifSnap.docs.isEmpty) return null;

      final notifData = _deepCastMap(notifSnap.docs.first.data());
      final nLat = (notifData['lat'] as num?)?.toDouble();
      final nLng = (notifData['lng'] as num?)?.toDouble();
      if (nLat == null || nLng == null) return null;

      return {
        'lat': nLat,
        'lng': nLng,
        'location': notifData['location'],
        'address': notifData['address'],
      };
    } catch (e) {
      debugPrint('Error fetching incident location: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> _restoreActiveIncidentFromFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;

    try {
      final snap = await FirebaseFirestore.instance
          .collection('responder_tracking')
          .where('responderId', isEqualTo: user.uid)
          .where('status', whereIn: ['enroute', 'on_scene'])
          .limit(1)
          .get();

      if (snap.docs.isEmpty) return null;

      final trackData = _deepCastMap(snap.docs.first.data());
      final incidentId = trackData['incidentId']?.toString();

      if (incidentId != null) {
        final monSnap = await FirebaseFirestore.instance
            .collection('monitoring_status')
            .where('incidentId', isEqualTo: incidentId)
            .limit(1)
            .get();

        if (monSnap.docs.isNotEmpty) {
          final monData = _deepCastMap(monSnap.docs.first.data());
          _mergeIfPresent(trackData, monData, 'type');
          _mergeIfPresent(trackData, monData, 'location');
          _mergeIfPresent(trackData, monData, 'description');
          _mergeIfPresent(trackData, monData, 'reporterName');
          _mergeIfPresent(trackData, monData, 'reporterPhone');
          _mergeIfPresent(trackData, monData, 'unitName');
          _mergeIfPresent(trackData, monData, 'unitCode');
          _mergeIfPresent(trackData, monData, 'date');
          _mergeIfPresent(trackData, monData, 'time');
          _mergeIfPresent(trackData, monData, 'severity');
          if (monData['casualties'] != null) {
            trackData['casualties'] = monData['casualties'];
          }
        }

        final notifSnap = await FirebaseFirestore.instance
            .collection('responder_notifications')
            .where('incidentId', isEqualTo: incidentId)
            .where('userId', isEqualTo: user.uid)
            .limit(1)
            .get();

        if (notifSnap.docs.isNotEmpty) {
          final notifData = _deepCastMap(notifSnap.docs.first.data());
          _mergeIfPresent(trackData, notifData, 'type');
          _mergeIfPresent(trackData, notifData, 'location');
          _mergeIfPresent(trackData, notifData, 'description');
          _mergeIfPresent(trackData, notifData, 'reporterName');
          _mergeIfPresent(trackData, notifData, 'reporterPhone');
          _mergeIfPresent(trackData, notifData, 'unitName');
          _mergeIfPresent(trackData, notifData, 'unitCode');
          _mergeIfPresent(trackData, notifData, 'date');
          _mergeIfPresent(trackData, notifData, 'time');
          _mergeIfPresent(trackData, notifData, 'severity');
          if (notifData['reporter'] is Map) {
            final rep = notifData['reporter'] as Map;
            if (rep['fullName'] != null) {
              trackData['reporterName'] ??= rep['fullName'];
            }
            if (rep['phoneNumber'] != null) {
              trackData['reporterPhone'] ??= rep['phoneNumber'];
            }
          }
          if (notifData['casualties'] != null) {
            trackData['casualties'] = notifData['casualties'];
          }
        }
      }

      // ✅ Merge cached lifecycle times from SharedPreferences so they
      //    survive page exits and appear in the final report.
      try {
        final prefs = await SharedPreferences.getInstance();
        final cachedAccepted = prefs.getString(kAcceptedTimeKey);
        final cachedArrival = prefs.getString(kArrivalTimeKey);

        if (cachedAccepted != null && cachedAccepted.isNotEmpty) {
          trackData['dispatchTime'] ??= cachedAccepted;
          trackData['acceptedAtTime'] ??= cachedAccepted;
        }
        if (cachedArrival != null && cachedArrival.isNotEmpty) {
          trackData['arrivalTime'] ??= cachedArrival;
          trackData['arrivedAtTime'] ??= cachedArrival;
        }
      } catch (e) {
        debugPrint('Could not restore cached times: $e');
      }

      return trackData;
    } catch (e) {
      debugPrint('Error restoring active incident from Firestore: $e');
      return null;
    }
  }

  // =====================================================================
  // LIVE GPS TRACKING
  // =====================================================================
  Future<void> _startLiveTracking() async {
    await _locationSubscription?.cancel();
    _locationSubscription = null;

    final incidentId = _resolvedIncidentData?['incidentId']?.toString();
    _trackingIncidentId = incidentId;

    try {
      bool serviceEnabled = await _locationService.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await _locationService.requestService();
        if (!serviceEnabled) return;
      }

      PermissionStatus permission = await _locationService.hasPermission();
      if (permission == PermissionStatus.denied) {
        permission = await _locationService.requestPermission();
      }
      if (permission != PermissionStatus.granted &&
          permission != PermissionStatus.grantedLimited) {
        return;
      }
    } catch (e) {
      debugPrint('Location permission error: $e');
      return;
    }

    _locationSubscription = _locationService.onLocationChanged.listen(
      (LocationData locationData) async {
        final double? latitude = locationData.latitude;
        final double? longitude = locationData.longitude;
        if (latitude == null || longitude == null) return;
        if (!mounted) return;

        setState(() {
          _responderLocation = LatLng(latitude, longitude);
        });

        if (_assignedRouteApplied) return;

        // ✅ First GPS fix after "Accept Dispatch" → draw the polyline
        _ensureRoute();

        final now = DateTime.now();
        if (now.difference(_lastFirestoreWrite).inSeconds < 5) return;
        _lastFirestoreWrite = now;

        await _pushLocationToFirestore(latitude, longitude);
      },
    );

    // ✅ Start the 20-second auto-refresh cycle
    _startAutoRefreshTimer();
  }

  // =====================================================================
  // ✅ AUTO-REFRESH MAP EVERY 20 SECONDS
  // Keeps the responder's position + route fresh without manual taps.
  // Also detects a resolved incident (final report submitted) and clears
  // the old polyline automatically — no reload needed.
  // =====================================================================
  void _startAutoRefreshTimer() {
    _autoRefreshTimer?.cancel();

    // Nothing to refresh for a finished mission
    if (_missionCompleted) return;

    debugPrint(
      '⏱️ [AUTO-REFRESH] Started — every ${_autoRefreshInterval.inSeconds}s',
    );

    _autoRefreshTimer = Timer.periodic(_autoRefreshInterval, (_) async {
      if (!mounted) return;
      if (_isLoadingRoute || _restoring) return;

      if (_missionCompleted) {
        _autoRefreshTimer?.cancel();
        return;
      }

      // ✅ Picks up a resolved incident without leaving the page
      await refreshMissionStatus(ensureRoute: false);
      if (!mounted) return;
      if (_missionCompleted) return;

      // ─────────────────────────────────────────────
      // ✅ EOC-assigned route: re-fit camera AND
      //    republish to Firestore so updatedAt changes
      //    and the EOC / TrackResponder stay in sync.
      // ─────────────────────────────────────────────
      if (_assignedRouteApplied && _routePoints.length >= 2) {
        debugPrint('⏱️ [AUTO-REFRESH] tick (assigned)');
        _fitAssignedRoute();
        await _publishRouteToFirestore(
          points: _routePoints,
          distanceKm: _distanceKm,
          etaMinutes: _estimatedMinutes,
          isAssigned: true,
        );
        return;
      }

      // No active incident → nothing to refresh.
      if (_resolvedIncidentLocation == null) {
        debugPrint('⏱️ [AUTO-REFRESH] tick (no incident — skipped)');
        return;
      }

      // ─────────────────────────────────────────────
      // OSRM route: new GPS fix + recalculate the
      // road route (which publishes to Firestore).
      // ─────────────────────────────────────────────
      debugPrint('⏱️ [AUTO-REFRESH] tick (OSRM)');
      await _getCurrentLocation();
      if (!mounted) return;

      await _createRoadRoute();
      if (!mounted) return;

      if (_missionCompleted) return;

      if (_assignedRouteApplied) {
        _fitAssignedRoute();
      } else {
        _fitRoute();
      }
    });
  }

  Future<void> _pushLocationToFirestore(double lat, double lng) async {
    final incidentId = _trackingIncidentId;
    if (incidentId == null || incidentId.isEmpty) return;

    final status =
        (_resolvedIncidentData?['status'] ?? '').toString().toLowerCase();
    final accepted = status == 'enroute' || status == 'on_scene';
    if (!accepted) return;

    try {
      final user = FirebaseAuth.instance.currentUser;

      if (_cachedResponderName.isEmpty) {
        await _loadResponderIdentity();
      }

      final effectiveName = _cachedResponderName.isNotEmpty
          ? _cachedResponderName
          : (user?.displayName ?? 'Responder');

      final payload = <String, dynamic>{
        'incidentId': incidentId,
        'responderId': user?.uid ?? 'unknown',
        'userId': user?.uid ?? '',
        'responderName': effectiveName,
        'responderPhoto': _cachedResponderPhoto,
        'lat': lat,
        'lng': lng,
        'status': _arrivedAtScene ? 'on_scene' : 'enroute',
        'updatedAt': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('responder_tracking')
          .doc(incidentId)
          .set(payload, SetOptions(merge: true));

      debugPrint(
        '📍 Responder location pushed for $incidentId: $lat,$lng ',
      );
    } catch (e) {
      debugPrint('Error pushing responder location: $e');
    }
  }

  // =====================================================================
  // MAP INIT
  // =====================================================================
  Future<void> _initializeMap() async {
    if (_missionCompleted) {
      await _getCurrentLocation();
      if (!mounted) return;
      _centerOnResponder();
      return;
    }

    if (_assignedRouteApplied) {
      await _getCurrentLocation();
      if (!mounted) return;
      _fitAssignedRoute();
      return;
    }

    await _getCurrentLocation();
    if (!mounted) return;

    if (_assignedRoute != null) {
      _applyAssignedRoute(_assignedRoute!);
      return;
    }

    await _createRoadRoute();
    if (!mounted) return;

    if (_assignedRouteApplied) {
      _fitAssignedRoute();
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      if (_resolvedIncidentLocation != null) {
        _fitRoute();
      } else {
        _centerOnResponder();
      }
    });
  }

  Future<void> _getCurrentLocation() async {
    try {
      bool serviceEnabled = await _locationService.serviceEnabled();

      if (!serviceEnabled) {
        serviceEnabled = await _locationService.requestService();
        if (!serviceEnabled) return;
      }

      PermissionStatus permission = await _locationService.hasPermission();

      if (permission == PermissionStatus.denied) {
        permission = await _locationService.requestPermission();
      }

      if (permission != PermissionStatus.granted &&
          permission != PermissionStatus.grantedLimited) {
        return;
      }

      final LocationData locationData = await _locationService
          .getLocation()
          .timeout(const Duration(seconds: 8));

      final double? latitude = locationData.latitude;
      final double? longitude = locationData.longitude;

      if (latitude == null || longitude == null) return;

      if (!mounted) return;

      setState(() {
        _responderLocation = LatLng(latitude, longitude);
      });
    } catch (e) {
      debugPrint('Unable to get current location: $e');
    }
  }

  // Public OSRM-compatible routing servers, tried in order.
  static const List<String> _routingBaseUrls = [
    'https://router.project-osrm.org/route/v1/driving/',
    'https://routing.openstreetmap.de/routed-car/route/v1/driving/',
  ];

  Future<Map<String, dynamic>?> _fetchRoadRoute(LatLng from, LatLng to) async {
    final String coordinates = '${from.longitude},${from.latitude};'
        '${to.longitude},${to.latitude}';

    for (final String base in _routingBaseUrls) {
      try {
        final Uri uri = Uri.parse(
          '$base$coordinates?overview=full&geometries=geojson&steps=false',
        );

        final http.Response response = await http.get(
          uri,
          headers: const {
            'Accept': 'application/json',
            'User-Agent': 'ResponderApp/1.0',
          },
        ).timeout(const Duration(seconds: 12));

        if (response.statusCode != 200) {
          debugPrint('Routing server $base returned ${response.statusCode}');
          continue;
        }

        final Map<String, dynamic> data =
            jsonDecode(response.body) as Map<String, dynamic>;
        if ((data['code']?.toString() ?? '') != 'Ok') continue;

        final List<dynamic> routes = data['routes'] as List<dynamic>? ?? [];
        if (routes.isEmpty) continue;

        final Map<String, dynamic> route =
            routes.first as Map<String, dynamic>;
        final Map<String, dynamic>? geometry =
            route['geometry'] as Map<String, dynamic>?;
        final List<dynamic> coordsList =
            geometry?['coordinates'] as List<dynamic>? ?? [];

        final List<LatLng> pts = [];
        for (final dynamic c in coordsList) {
          if (c is! List || c.length < 2) continue;
          final double? lng = (c[0] as num?)?.toDouble();
          final double? lat = (c[1] as num?)?.toDouble();
          if (lat == null || lng == null) continue;
          pts.add(LatLng(lat, lng));
        }
        if (pts.length < 2) continue;

        return {
          'points': pts,
          'meters': (route['distance'] as num?)?.toDouble() ?? 0.0,
          'seconds': (route['duration'] as num?)?.toDouble() ?? 0.0,
        };
      } catch (e) {
        debugPrint('Routing error ($base): $e');
      }
    }
    return null;
  }

  // ============================================================
  // ✅ SELF-HEALING: if there is an active incident but no polyline
  //    (e.g. right after "Accept Dispatch"), build one now.
  //    Called from the GPS listener, the Map tab, and widget updates.
  // ============================================================
  void _ensureRoute() {
    if (!mounted) return;
    if (_missionCompleted || _assignedRouteApplied) return;
    if (_resolvedIncidentLocation == null) return;
    if (_isLoadingRoute || _restoring) return;
    if (_routePoints.length >= 2 && !_isFallbackRoute) return;

    final now = DateTime.now();
    if (now.difference(_lastEnsureRoute).inSeconds < 8) return;
    _lastEnsureRoute = now;

    debugPrint('🛟 [ENSURE ROUTE] no polyline yet — building one');
    _createRoadRoute().then((_) {
      if (mounted && _routePoints.length >= 2 && !_assignedRouteApplied) {
        _fitRoute();
      }
    });
  }

  Future<void> _createRoadRoute() async {
    if (_assignedRouteApplied || _missionCompleted) return;

    // ✅ Token: if the route is cleared / replaced while the request is in
    //    flight, this response is ignored.
    final int myGen = _routeGeneration;

    final LatLng? destination = _resolvedIncidentLocation;

    if (destination == null) {
      if (!mounted) return;
      setState(() {
        _routePoints = [];
        _distanceKm = 0.0;
        _estimatedMinutes = 0;
        _routeError = null;
        _isLoadingRoute = false;
        _isFallbackRoute = false;
      });
      return;
    }

    const Distance probe = Distance();
    final double distToDestMeters = probe.as(
      LengthUnit.Meter,
      _responderLocation,
      destination,
    );
    if (distToDestMeters < 3.0) {
      debugPrint('⚠️ Destination is basically at the responder');
      if (!mounted) return;
      setState(() {
        _routePoints = [];
        _distanceKm = 0.0;
        _estimatedMinutes = 0;
        _routeError = null;
        _isLoadingRoute = false;
        _isFallbackRoute = false;
      });
      _publishRouteToFirestore(
        points: const [],
        distanceKm: 0,
        etaMinutes: 0,
        isAssigned: false,
      );
      return;
    }

    if (mounted) {
      setState(() {
        _isLoadingRoute = true;
        _routeError = null;
      });
    }

    final Map<String, dynamic>? result =
        await _fetchRoadRoute(_responderLocation, destination);

    if (!mounted) return;

    if (_assignedRouteApplied ||
        _missionCompleted ||
        myGen != _routeGeneration) {
      if (myGen == _routeGeneration) {
        setState(() => _isLoadingRoute = false);
      }
      return;
    }

    if (result != null) {
      final List<LatLng> roadPoints = result['points'] as List<LatLng>;
      final double meters = result['meters'] as double;
      final double seconds = result['seconds'] as double;

      setState(() {
        _routePoints = roadPoints;
        _distanceKm = meters / 1000.0;
        _estimatedMinutes = math.max(1, (seconds / 60.0).ceil());
        _isFallbackRoute = false;
        _routeError = null;
        _isLoadingRoute = false;
      });

      // ✅ Publish road route to EOC
      _publishRouteToFirestore(
        points: _routePoints,
        distanceKm: _distanceKm,
        etaMinutes: _estimatedMinutes,
        isAssigned: false,
      );
      return;
    }

    // ── All routing servers failed ──
    if (_routePoints.length >= 2 && !_isFallbackRoute) {
      // Keep the last good road route instead of replacing it.
      setState(() => _isLoadingRoute = false);
      return;
    }

    // Show a direct line so the responder still sees where to go.
    final double meters = probe.as(
      LengthUnit.Meter,
      _responderLocation,
      destination,
    );
    setState(() {
      _routePoints = [_responderLocation, destination];
      _distanceKm = meters / 1000.0;
      _estimatedMinutes = math.max(1, (meters / 1000.0 / 30.0 * 60.0).ceil());
      _isFallbackRoute = true;
      _routeError = 'Road route unavailable — showing direct line. Retrying…';
      _isLoadingRoute = false;
    });
  }

  void _requestBackup() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return _BackupRequestSheet(
          onSubmit: (category, description) async {
            Navigator.pop(sheetContext);

            final message = description.isEmpty
                ? '📡 Backup requested: $category'
                : '📡 Backup requested: $category\n$description';

            _sendBackupRequestToFirestore(category, description);

            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(message),
                backgroundColor: const Color(0xFFF59E0B),
                duration: const Duration(seconds: 3),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _sendBackupRequestToFirestore(
      String category, String description) async {
    final incidentId = _resolvedIncidentData?['incidentId']?.toString();
    if (incidentId == null || incidentId.isEmpty) return;

    try {
      final user = FirebaseAuth.instance.currentUser;

      if (_cachedResponderName.isEmpty) {
        await _loadResponderIdentity();
      }

      final responderName = _cachedResponderName.isNotEmpty
          ? _cachedResponderName
          : (user?.displayName ?? 'Responder');

      await FirebaseFirestore.instance.collection('backup_requests').add({
        'incidentId': incidentId,
        'reportId': incidentId,
        'category': category,
        'description': description,
        'responderId': user?.uid ?? 'unknown',
        'userId': user?.uid ?? '',
        'responderName': responderName,
        'responderPhoto': _cachedResponderPhoto,
        'lat': _responderLocation.latitude,
        'lng': _responderLocation.longitude,
        'status': 'pending',
        'isRead': false,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (user != null) {
        try {
          final notifSnap = await FirebaseFirestore.instance
              .collection('responder_notifications')
              .where('incidentId', isEqualTo: incidentId)
              .where('userId', isEqualTo: user.uid)
              .get();

          for (final doc in notifSnap.docs) {
            await doc.reference.update({
              'status': 'backup',
              'backupRequestedAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
            });
          }

          debugPrint(
            '✅ responder_notifications → backup for $incidentId ',
          );
        } catch (e) {
          debugPrint('⚠️ Could not update responder_notifications: $e');
        }
      }

      try {
        final monSnap = await FirebaseFirestore.instance
            .collection('monitoring_status')
            .where('incidentId', isEqualTo: incidentId)
            .limit(1)
            .get();

        if (monSnap.docs.isNotEmpty) {
          await monSnap.docs.first.reference.update({
            'status': 'backup',
            'backupRequestedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        } else {
          await FirebaseFirestore.instance
              .collection('monitoring_status')
              .doc(incidentId)
              .set({
            'incidentId': incidentId,
            'status': 'backup',
            'backupRequestedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }

        debugPrint('✅ monitoring_status → backup for $incidentId');
      } catch (e) {
        debugPrint('⚠️ Could not update monitoring_status: $e');
      }

      debugPrint(
        '📡 Backup request sent by $responderName ',
      );
    } catch (e) {
      debugPrint('Error sending backup request: $e');
    }
  }

  void _markArrivedAtScene() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFFE6F4EC),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF0B6B43),
                size: 24,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(
                'Arrived at Scene',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F172A),
                ),
              ),
            ),
          ],
        ),
        content: const Text(
          'Confirm that you have arrived at the incident scene. This will update your status to on scene.',
          style: TextStyle(
            fontSize: 14,
            color: Color(0xFF475569),
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text(
              'Cancel',
              style: TextStyle(
                color: Color(0xFF475569),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(dialogContext);

              final arrivalTime = _formatTime12h(DateTime.now());

              setState(() {
                _arrivedAtScene = true;
              });

              if (_resolvedIncidentData != null) {
                _resolvedIncidentData!['status'] = 'on_scene';
                _resolvedIncidentData!['arrivalTime'] = arrivalTime;
                _resolvedIncidentData!['arrivedAtTime'] = arrivalTime;

                // ✅ Persist arrival time to SharedPreferences so it
                //    survives page exits and shows in the final report.
                try {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString(
                    kArrivalTimeKey,
                    arrivalTime,
                  );
                } catch (e) {
                  debugPrint('Could not cache arrival time: $e');
                }

                try {
                  final incidentId =
                      _resolvedIncidentData!['incidentId']?.toString();
                  if (incidentId != null && incidentId.isNotEmpty) {
                    await FirebaseFirestore.instance
                        .collection('responder_tracking')
                        .doc(incidentId)
                        .set({
                      'arrivalTime': arrivalTime,
                      'arrivedAtTime': arrivalTime,
                      'updatedAt': FieldValue.serverTimestamp(),
                    }, SetOptions(merge: true));
                  }
                } catch (e) {
                  debugPrint('Could not persist arrival time: $e');
                }

                await _persistLastNavigated(_resolvedIncidentData!);
                await _maybePersistAsActiveDispatch(_resolvedIncidentData!);
              }

              await _persistArrival();

              await _notifyReporterArrivedAtScene();

              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('✅ Status updated: Arrived at Scene'),
                  backgroundColor: Color(0xFF0B6B43),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0B6B43),
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Confirm Arrival'),
          ),
        ],
      ),
    );
  }

  Future<void> _persistArrival() async {
    final incidentId = _resolvedIncidentData?['incidentId']?.toString();
    final user = FirebaseAuth.instance.currentUser;
    if (incidentId == null || incidentId.isEmpty) return;

    try {
      await FirebaseFirestore.instance
          .collection('responder_tracking')
          .doc(incidentId)
          .set({
        'status': 'on_scene',
        'arrivedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'userId': user?.uid ?? '',
      }, SetOptions(merge: true));

      if (user != null) {
        final snap = await FirebaseFirestore.instance
            .collection('responder_notifications')
            .where('incidentId', isEqualTo: incidentId)
            .where('userId', isEqualTo: user.uid)
            .limit(1)
            .get();

        if (snap.docs.isNotEmpty) {
          await snap.docs.first.reference.update({
            'status': 'on_scene',
            'arrivedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
        }
      }

      final monSnap = await FirebaseFirestore.instance
          .collection('monitoring_status')
          .where('incidentId', isEqualTo: incidentId)
          .limit(1)
          .get();

      final responderLabel = _cachedResponderName.isNotEmpty
          ? _cachedResponderName
          : (user?.displayName ?? 'Responder');

      if (monSnap.docs.isNotEmpty) {
        await monSnap.docs.first.reference.update({
          'status': 'on_scene',
          'arrivedAt': FieldValue.serverTimestamp(),
          'responder': responderLabel,
          'updatedAt': FieldValue.serverTimestamp(),
        });
      } else {
        await FirebaseFirestore.instance
            .collection('monitoring_status')
            .doc(incidentId)
            .set({
          'incidentId': incidentId,
          'status': 'on_scene',
          'arrivedAt': FieldValue.serverTimestamp(),
          'responder': responderLabel,
          'responderId': user?.uid,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }

      try {
        final now = TimeOfDay.now();
        final hour = now.hourOfPeriod == 0 ? 12 : now.hourOfPeriod;
        final minute = now.minute.toString().padLeft(2, '0');
        final period = now.period == DayPeriod.am ? 'AM' : 'PM';
        final timeNow = '$hour:$minute $period';

        await FirebaseFirestore.instance
            .collection('incident_progress')
            .doc(incidentId)
            .set({
          'incidentId': incidentId,
          'status': 'arrived',
          'statusLabel': 'Arrived',
          'arrivedTime': timeNow,
          'responder': responderLabel,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        debugPrint('✅ [incident_progress] $incidentId → arrived');
      } catch (e) {
        debugPrint('❌ Failed to sync incident_progress (arrived): $e');
      }
    } catch (e) {
      debugPrint('Error persisting arrival: $e');
    }
  }

  Future<void> _notifyReporterArrivedAtScene() async {
    try {
      final incidentId = _resolvedIncidentData?['incidentId']?.toString();
      if (incidentId == null || incidentId.isEmpty) return;

      final currentUser = FirebaseAuth.instance.currentUser;

      if (_cachedResponderName.isEmpty) {
        await _loadResponderIdentity();
      }

      String responderName = _cachedResponderName.isNotEmpty
          ? _cachedResponderName
          : (currentUser?.displayName ?? 'Responder');

      String? reporterUserId;

      try {
        final directDoc = await FirebaseFirestore.instance
            .collection('incident_reports')
            .doc(incidentId)
            .get();
        if (directDoc.exists) {
          final uid = directDoc.data()?['userId']?.toString();
          if (uid != null && uid.isNotEmpty && uid != 'eoc-user') {
            reporterUserId = uid;
          }
        }
      } catch (_) {}

      if (reporterUserId == null) {
        try {
          final snap = await FirebaseFirestore.instance
              .collection('incident_reports')
              .get();

          for (final doc in snap.docs) {
            final data = doc.data();
            final matches = doc.id == incidentId ||
                data['incidentId']?.toString() == incidentId ||
                data['reportId']?.toString() == incidentId;

            if (!matches) continue;

            final uid = data['userId']?.toString();
            if (uid != null && uid.isNotEmpty && uid != 'eoc-user') {
              reporterUserId = uid;
            }
          }
        } catch (e) {
          debugPrint('Error querying incident_reports: $e');
        }
      }

      if (reporterUserId == null) {
        debugPrint(
          '⚠️ Could not find reporter userId for $incidentId.',
        );
        return;
      }

      await FirebaseFirestore.instance.collection('user_notifications').add({
        'userId': reporterUserId,
        'reportId': incidentId,
        'title': '🚑 Responder Arrived at Scene',
        'message': 'A responder has arrived at your reported location.',
        'incidentType': _resolvedIncidentData?['type'] ?? 'Unknown',
        'responderName': responderName,
        'responderId': currentUser?.uid ?? '',
        'read': false,
        'type': 'dispatch',
        'createdAt': FieldValue.serverTimestamp(),
      });

      debugPrint(
        '✅ Arrival notification sent to reporter: $reporterUserId',
      );

      await sendPushToUser(
        userId: reporterUserId,
        title: '🚑 Responder Arrived at Scene',
        body: 'A responder has arrived at your reported location.',
        data: {'reportId': incidentId, 'type': 'dispatch'},
      );
    } catch (e) {
      debugPrint('❌ Error sending arrival notification: $e');
    }
  }

  Future<void> _openMissionComplete() async {
    final data = _resolvedIncidentData;
    if (data == null || data.isEmpty) return;

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => IncidentDetailsPage(
          incidentData: data,
        ),
      ),
    );

    if (!mounted) return;

    if (result is Map && result['action'] == 'open_map') {
      final loc = result['incidentLocation'] as LatLng?;
      final newData = result['incidentData'] as Map<String, dynamic>?;

      setState(() {
        if (loc != null) _resolvedIncidentLocation = loc;
        if (newData != null) _resolvedIncidentData = newData;
      });

      if (newData != null) {
        _applyIncidentData(newData);
      }
    }

    final incidentId = _resolvedIncidentData?['incidentId']?.toString();
    if (incidentId == null || incidentId.isEmpty) return;

    try {
      final reportDoc = await FirebaseFirestore.instance
          .collection('final_reports')
          .doc(incidentId)
          .get();

      if (!mounted) return;

      if (reportDoc.exists) {
        setState(() {
          _missionCompleted = true;
          _arrivedAtScene = true;
          if (_resolvedIncidentData != null) {
            _resolvedIncidentData!['status'] = 'solved';
          }
        });

        // ✅ Stop refresh + wipe the old polyline locally and on EOC
        _autoRefreshTimer?.cancel();
        await _clearRouteState();
        await _clearPersistedIncident();

        try {
          await FirebaseFirestore.instance
              .collection('responder_tracking')
              .doc(incidentId)
              .set({
            'status': 'resolved',
            'completedAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        } catch (e) {
          debugPrint('Could not refresh responder_tracking: $e');
        }

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Mission complete. Report submitted.'),
            backgroundColor: Color(0xFF0B6B43),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('Error checking final_reports after mission complete: $e');
    }
  }

  Future<void> _refreshRoute() async {
    if (_missionCompleted) {
      await _clearRouteState();
      return;
    }

    if (_assignedRouteApplied) {
      _fitAssignedRoute();
      await _publishRouteToFirestore(
        points: _routePoints,
        distanceKm: _distanceKm,
        etaMinutes: _estimatedMinutes,
        isAssigned: true,
      );
      return;
    }

    await _getCurrentLocation();
    if (!mounted) return;

    await _createRoadRoute();
    if (!mounted) return;

    if (_assignedRouteApplied) {
      _fitAssignedRoute();
      return;
    }

    _fitRoute();
  }

  double _calculateStraightDistance() {
    final LatLng? destination = _resolvedIncidentLocation;
    if (destination == null) return 0.0;

    const Distance distance = Distance();

    return distance.as(
      LengthUnit.Kilometer,
      _responderLocation,
      destination,
    );
  }

  String get _distanceText {
    if (_distanceKm > 0) {
      if (_distanceKm < 1) {
        return '${(_distanceKm * 1000).round()} m';
      }
      return '${_distanceKm.toStringAsFixed(1)} km';
    }

    final double fallbackDistance = _calculateStraightDistance();

    if (fallbackDistance <= 0) return '0 m';
    if (fallbackDistance < 1) {
      return '${(fallbackDistance * 1000).round()} m';
    }
    return '${fallbackDistance.toStringAsFixed(1)} km';
  }

  String get _etaText {
    if (_estimatedMinutes > 0) {
      if (_estimatedMinutes <= 1) return '1 min';
      return '$_estimatedMinutes min';
    }
    return '--';
  }

  LatLng? get _routeMidpoint {
    if (_routePoints.length < 2) return null;
    return _routePoints[_routePoints.length ~/ 2];
  }

  String get _incidentLocationName {
    final Map<String, dynamic>? data = _resolvedIncidentData;
    if (data == null) return 'Naga City';

    return data['location']?.toString() ??
        data['address']?.toString() ??
        'Naga City';
  }

  void _centerOnResponder() {
    _mapController.move(_responderLocation, 16.0);
    if (!mounted) return;
    setState(() {
      _currentZoom = 16.0;
    });
  }

  void _fitRoute() {
    if (_assignedRouteApplied) {
      _fitAssignedRoute();
      return;
    }

    final LatLng? destination = _resolvedIncidentLocation;
    if (destination == null) {
      _centerOnResponder();
      return;
    }

    final List<LatLng> points = _routePoints.isNotEmpty
        ? _routePoints
        : [_responderLocation, destination];

    if (points.isEmpty) return;

    final LatLngBounds bounds = LatLngBounds.fromPoints(points);

    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.fromLTRB(45, 45, 45, 240),
      ),
    );

    if (!mounted) return;
    setState(() {
      _currentZoom = _mapController.camera.zoom;
    });
  }

  void _zoomIn() {
    final double newZoom = _currentZoom + 1;
    if (newZoom > 19) return;

    _mapController.move(_mapController.camera.center, newZoom);
    if (!mounted) return;
    setState(() {
      _currentZoom = newZoom;
    });
  }

  void _zoomOut() {
    final double newZoom = _currentZoom - 1;
    if (newZoom < 10) return;

    _mapController.move(_mapController.camera.center, newZoom);
    if (!mounted) return;
    setState(() {
      _currentZoom = newZoom;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Size screenSize = MediaQuery.of(context).size;
    final double screenWidth = screenSize.width;
    final double scale = screenWidth / 390;

    final LatLng initialCenter =
        _resolvedIncidentLocation ?? _responderLocation;

    final bool hasIncident = _resolvedIncidentLocation != null;

    final bool hasAssignedRoute = _assignedRouteApplied &&
        _assignedRoute != null &&
        _assignedRoute!.points.length >= 2;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: initialCenter,
                initialZoom: hasIncident ? 15.5 : 14.0,
                minZoom: 10,
                maxZoom: 19,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all,
                ),
                onPositionChanged: (position, hasGesture) {
                  if (!mounted) return;
                  if (hasGesture) {
                    setState(() {
                      _currentZoom = position.zoom;
                    });
                  }
                },
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      _isSatellite ? _satelliteMapUrl : _streetMapUrl,
                  userAgentPackageName: 'com.example.responder_app',
                  tileProvider: NetworkTileProvider(),
                ),

                // ✅ Never draw a polyline for a completed mission
                if (_routePoints.length >= 2 && !_missionCompleted)
                  PolylineLayer(
                    polylines: [
                      // white outline
                      Polyline(
                        points: _routePoints,
                        strokeWidth: 12 * scale,
                        color: Colors.white,
                        strokeCap: StrokeCap.round,
                        strokeJoin: StrokeJoin.round,
                      ),
                      // green route
                      Polyline(
                        points: _routePoints,
                        strokeWidth: 7.5 * scale,
                        color: _isFallbackRoute
                            ? const Color(0xFF94A3B8)
                            : const Color(0xFF16A34A),
                        strokeCap: StrokeCap.round,
                        strokeJoin: StrokeJoin.round,
                      ),
                    ],
                  ),

                MarkerLayer(
                  markers: [
                    Marker(
                      point: _responderLocation,
                      width: 64 * scale,
                      height: 64 * scale,
                      child: _ResponderMarker(scale: scale),
                    ),
                    if (_resolvedIncidentLocation != null)
                      Marker(
                        point: _resolvedIncidentLocation!,
                        width: 140 * scale,
                        height: 96 * scale,
                        alignment: Alignment.topCenter, // pin tip sits on the location
                        child: _IncidentMarker(
                          scale: scale,
                          label:
                              'Incident #${_resolvedIncidentData?['incidentId'] ?? ''}',
                        ),
                      ),
                    if (_routeMidpoint != null && !_missionCompleted)
                      Marker(
                        point: _routeMidpoint!,
                        width: 112 * scale,
                        height: 60 * scale,
                        child: Center(
                          child: _RouteInfoBubble(
                            distance: _distanceText,
                            eta: _etaText,
                            scale: scale,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),

          if (_restoring)
            Positioned.fill(
              child: Container(
                color: Colors.white.withValues(alpha: 0.75),
                child: const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: Color(0xFF0B6B43)),
                      SizedBox(height: 12),
                      Text(
                        'Restoring active dispatch…',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_isLoadingRoute)
            Positioned(
              top: MediaQuery.of(context).padding.top + 20 * scale,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 13 * scale,
                    vertical: 8 * scale,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20 * scale),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16 * scale,
                        height: 16 * scale,
                        child: const CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      ),
                      SizedBox(width: 8 * scale),
                      Text(
                        'Loading road route...',
                        style: TextStyle(
                          fontSize: 11 * scale,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFF374151),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          if (_routeError != null)
            Positioned(
              top: MediaQuery.of(context).padding.top + 20 * scale,
              left: 20 * scale,
              right: 20 * scale,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 12 * scale,
                  vertical: 9 * scale,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12 * scale),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: const Color(0xFFDC2626),
                      size: 20 * scale,
                    ),
                    SizedBox(width: 8 * scale),
                    Expanded(
                      child: Text(
                        _routeError!,
                        style: TextStyle(
                          fontSize: 10 * scale,
                          color: const Color(0xFF374151),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: _refreshRoute,
                      icon: Icon(
                        Icons.refresh_rounded,
                        size: 19 * scale,
                      ),
                    ),
                  ],
                ),
              ),
            ),

          if (hasAssignedRoute && !_missionCompleted)
            Positioned(
              top: MediaQuery.of(context).padding.top + 12 * scale,
              left: 12 * scale,
              right: 12 * scale,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: 12 * scale,
                  vertical: 8 * scale,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B6B43),
                  borderRadius: BorderRadius.circular(12 * scale),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 8,
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.alt_route_rounded,
                      color: Colors.white,
                      size: 18 * scale,
                    ),
                    SizedBox(width: 8 * scale),
                    Expanded(
                      child: Text(
                        'Following EOC-assigned route',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12.5 * scale,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          Positioned(
            top: MediaQuery.of(context).padding.top + 12 * scale,
            right: 12 * scale,
            child: Column(
              children: [
                _RoundMapButton(
                  icon: Icons.my_location_rounded,
                  onTap: _centerOnResponder,
                  scale: scale,
                ),
                SizedBox(height: 9 * scale),
                _RoundMapButton(
                  icon: Icons.route_rounded,
                  onTap: _refreshRoute,
                  scale: scale,
                ),
                SizedBox(height: 9 * scale),
                _RoundMapButton(
                  icon: _isSatellite
                      ? Icons.map_rounded
                      : Icons.satellite_alt_rounded,
                  onTap: () {
                    setState(() {
                      _isSatellite = !_isSatellite;
                    });
                  },
                  scale: scale,
                ),
                SizedBox(height: 9 * scale),
                _RoundMapButton(
                  icon: Icons.add_rounded,
                  onTap: _zoomIn,
                  scale: scale,
                ),
                SizedBox(height: 9 * scale),
                _RoundMapButton(
                  icon: Icons.remove_rounded,
                  onTap: _zoomOut,
                  scale: scale,
                ),
              ],
            ),
          ),

          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Container(
                padding: EdgeInsets.fromLTRB(
                  12 * scale,
                  6 * scale,
                  12 * scale,
                  8 * scale,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(18 * scale),
                    topRight: Radius.circular(18 * scale),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.14),
                      blurRadius: 14,
                      offset: const Offset(0, -3),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasIncident)
                      Row(
                        children: [
                          Container(
                            width: 34 * scale,
                            height: 34 * scale,
                            decoration: const BoxDecoration(
                              color: Color(0xFFE8F5EE),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _arrivedAtScene
                                  ? Icons.check_circle_rounded
                                  : Icons.navigation_rounded,
                              color: const Color(0xFF0B6B43),
                              size: 18 * scale,
                            ),
                          ),
                          SizedBox(width: 9 * scale),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 8 * scale,
                                      height: 8 * scale,
                                      decoration: BoxDecoration(
                                        color: _arrivedAtScene
                                            ? const Color(0xFF0B6B43)
                                            : const Color(0xFF16A34A),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                    SizedBox(width: 5 * scale),
                                    Text(
                                      _arrivedAtScene
                                          ? 'On Scene'
                                          : 'En Route',
                                      style: TextStyle(
                                        color: const Color(0xFF172033),
                                        fontSize: 15 * scale,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                                SizedBox(height: 2 * scale),
                                Text(
                                  _incidentLocationName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: const Color(0xFF64748B),
                                    fontSize: 11 * scale,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _etaText,
                                style: TextStyle(
                                  color: const Color(0xFF0B6B43),
                                  fontSize: 17 * scale,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                _distanceText,
                                style: TextStyle(
                                  color: const Color(0xFF64748B),
                                  fontSize: 11 * scale,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),

                    if (hasIncident) SizedBox(height: 8 * scale),

                    if (_resolvedIncidentData != null) ...[
                      SizedBox(
                        height: _detailsMaxHeight,
                        child: Scrollbar(
                          controller: _detailsScrollController,
                          thumbVisibility: true,
                          thickness: 3,
                          radius: const Radius.circular(3),
                          child: SingleChildScrollView(
                            controller: _detailsScrollController,
                            physics: const BouncingScrollPhysics(),
                            padding: EdgeInsets.only(right: 6 * scale),
                            child: _IncidentDetailsCard(
                              incidentData: _resolvedIncidentData,
                              scale: scale,
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: 8 * scale),
                    ],

                    if (hasIncident)
                      Row(
                        children: [
                          Expanded(
                            child: _NavigationButton(
                              icon: Icons.support_agent_rounded,
                              label: 'Request Backup',
                              onTap: _requestBackup,
                              scale: scale,
                            ),
                          ),
                          SizedBox(width: 8 * scale),
                          Expanded(
                            child: _arrivedAtScene
                                ? _NavigationButton(
                                    icon: Icons.task_alt_rounded,
                                    label: _missionCompleted
                                        ? 'Report Submitted'
                                        : 'Mission Complete',
                                    filled: true,
                                    onTap: _missionCompleted
                                        ? () {}
                                        : _openMissionComplete,
                                    scale: scale,
                                  )
                                : _NavigationButton(
                                    icon: Icons.place_rounded,
                                    label: 'Arrived at Scene',
                                    filled: true,
                                    onTap: _markArrivedAtScene,
                                    scale: scale,
                                  ),
                          ),
                        ],
                      )
                    else
                      Container(
                        width: double.infinity,
                        padding: EdgeInsets.symmetric(
                          horizontal: 12 * scale,
                          vertical: 10 * scale,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(10 * scale),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              color: const Color(0xFF64748B),
                              size: 18 * scale,
                            ),
                            SizedBox(width: 10 * scale),
                            Expanded(
                              child: Text(
                                'No active incident. Tap a notification to start navigating.',
                                style: TextStyle(
                                  fontSize: 11.5 * scale,
                                  fontWeight: FontWeight.w600,
                                  color: const Color(0xFF475569),
                                  height: 1.3,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================
// BACKUP REQUEST SHEET
// ================================================================

class _BackupRequestSheet extends StatefulWidget {
  final void Function(String category, String description) onSubmit;

  const _BackupRequestSheet({required this.onSubmit});

  @override
  State<_BackupRequestSheet> createState() => _BackupRequestSheetState();
}

class _BackupRequestSheetState extends State<_BackupRequestSheet> {
  static const List<Map<String, dynamic>> _options = [
    {'label': 'Need More Responders', 'icon': Icons.groups_rounded, 'color': Color(0xFF2563EB)},
    {'label': 'Need Medical Assistance', 'icon': Icons.medical_services_rounded, 'color': Color(0xFFDC2626)},
    {'label': 'Need Additional Equipment', 'icon': Icons.build_rounded, 'color': Color(0xFFF59E0B)},
    {'label': 'Traffic Assistance Needed', 'icon': Icons.traffic_rounded, 'color': Color(0xFF0B6B43)},
    {'label': 'Need Another Route', 'icon': Icons.alt_route_rounded, 'color': Color(0xFF7C3AED)},
    {'label': 'Dangerous Situation', 'icon': Icons.warning_amber_rounded, 'color': Color(0xFFDC2626)},
    {'label': 'Other', 'icon': Icons.more_horiz_rounded, 'color': Color(0xFF475569)},
  ];

  String? _selectedCategory;
  final TextEditingController _descriptionController = TextEditingController();
  bool _isOther = false;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  void _selectOption(String label) {
    setState(() {
      _selectedCategory = label;
      _isOther = label == 'Other';
      if (!_isOther) _descriptionController.clear();
    });
  }

  void _submit() {
    final category = _selectedCategory;
    if (category == null || category.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a backup request type.'),
          backgroundColor: Color(0xFFDC2626),
        ),
      );
      return;
    }

    final description = _isOther ? _descriptionController.text.trim() : '';

    if (_isOther && description.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please describe what you need.'),
          backgroundColor: Color(0xFFDC2626),
        ),
      );
      return;
    }

    widget.onSubmit(category, description);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFD1D5DB),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(9),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFEF3E2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.support_agent_rounded,
                        color: Color(0xFFF59E0B),
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Request Backup',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Choose what kind of help you need.',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(
                        Icons.close_rounded,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                ..._options.map((option) {
                  final String label = option['label'] as String;
                  final IconData icon = option['icon'] as IconData;
                  final Color color = option['color'] as Color;
                  final bool selected = _selectedCategory == label;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: selected
                          ? color.withValues(alpha: 0.10)
                          : const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _selectOption(label),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color:
                                  selected ? color : const Color(0xFFE7EBEF),
                              width: selected ? 1.5 : 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(7),
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: Icon(icon, color: color, size: 18),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  label,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: selected
                                        ? FontWeight.w800
                                        : FontWeight.w600,
                                    color: selected
                                        ? color
                                        : const Color(0xFF0F172A),
                                  ),
                                ),
                              ),
                              if (selected)
                                Icon(
                                  Icons.check_circle_rounded,
                                  color: color,
                                  size: 20,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
                AnimatedSize(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  child: _isOther
                      ? Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Describe what you need',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF0F172A),
                                ),
                              ),
                              const SizedBox(height: 6),
                              TextField(
                                controller: _descriptionController,
                                maxLines: 4,
                                autofocus: true,
                                textInputAction: TextInputAction.newline,
                                decoration: InputDecoration(
                                  hintText:
                                      'e.g., Need 2 more ambulances and a rescue team...',
                                  hintStyle: const TextStyle(
                                    fontSize: 13,
                                    color: Color(0xFF94A3B8),
                                  ),
                                  filled: true,
                                  fillColor: const Color(0xFFF8FAFC),
                                  contentPadding: const EdgeInsets.all(12),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: const BorderSide(
                                      color: Color(0xFFE7EBEF),
                                    ),
                                  ),
                                  enabledBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: const BorderSide(
                                      color: Color(0xFFE7EBEF),
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: const BorderSide(
                                      color: Color(0xFFF59E0B),
                                      width: 1.5,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: const Text(
                      'Send Backup Request',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF59E0B),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ================================================================
// RESPONDER MARKER (ambulance in a green-ringed badge)
// ================================================================

class _ResponderMarker extends StatelessWidget {
  final double scale;

  const _ResponderMarker({required this.scale});

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // soft glow
        Container(
          width: 60 * scale,
          height: 60 * scale,
          decoration: BoxDecoration(
            color: const Color(0xFF16A34A).withValues(alpha: 0.18),
            shape: BoxShape.circle,
          ),
        ),
        // badge
        Container(
          width: 44 * scale,
          height: 44 * scale,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF16A34A), width: 3),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.28),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text('🚑', style: TextStyle(fontSize: 24 * scale)),
        ),
      ],
    );
  }
}

// ================================================================
// INCIDENT MARKER (label bubble + red pin)
// ================================================================

class _IncidentMarker extends StatelessWidget {
  final double scale;
  final String label;

  const _IncidentMarker({required this.scale, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // label bubble
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10 * scale,
            vertical: 4 * scale,
          ),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8 * scale),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12 * scale,
              fontWeight: FontWeight.w800,
              color: const Color(0xFF0F172A),
            ),
          ),
        ),
        SizedBox(height: 3 * scale),
        // pin
        Icon(
          Icons.location_on_rounded,
          color: const Color(0xFFDC2626),
          size: 46 * scale,
          shadows: [
            Shadow(
              color: Colors.black.withValues(alpha: 0.30),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
      ],
    );
  }
}

// ================================================================
// (kept for compatibility — no longer used by the incident marker)
// ================================================================

class _MarkerTrianglePainter extends CustomPainter {
  @override
  void paint(ui.Canvas canvas, ui.Size size) {
    final ui.Paint paint = ui.Paint()
      ..color = const Color(0xFFDC2626)
      ..style = ui.PaintingStyle.fill;

    final ui.Path path = ui.Path();

    path.moveTo(size.width / 2, size.height);
    path.lineTo(0, 0);
    path.lineTo(size.width, 0);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}

// ================================================================
// INCIDENT DETAILS CARD
// ================================================================

class _IncidentDetailsCard extends StatelessWidget {
  final Map<String, dynamic>? incidentData;
  final double scale;

  const _IncidentDetailsCard({
    required this.incidentData,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    if (incidentData == null) return const SizedBox.shrink();

    final type = incidentData!['type']?.toString() ?? 'Emergency Incident';
    final location = incidentData!['location']?.toString() ?? 'Unknown location';
    final description = incidentData!['description']?.toString() ?? '';
    final severity = incidentData!['severity']?.toString() ?? 'medium';
    final date = incidentData!['date']?.toString() ?? '';
    final time = incidentData!['time']?.toString() ?? '';
    final incidentId = incidentData!['incidentId']?.toString() ?? '';

    final reporterName = incidentData!['reporterName']?.toString() ??
        (incidentData!['reporter'] is Map
            ? incidentData!['reporter']['fullName']?.toString()
            : null) ??
        'None';
    final reporterPhone = incidentData!['reporterPhone']?.toString() ??
        (incidentData!['reporter'] is Map
            ? incidentData!['reporter']['phoneNumber']?.toString()
            : null) ??
        incidentData!['phone']?.toString() ??
        'None';

    final casualties =
        incidentData!['casualties'] as Map<String, dynamic>? ?? {};
    final injured = casualties['injured'] ?? 0;
    final fatalities = casualties['fatalities'] ?? 0;
    final trapped = casualties['trapped'] ?? 0;

    final severityColor = _severityColor(severity);

    return Container(
      padding: EdgeInsets.all(10 * scale),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12 * scale),
        border: Border.all(color: const Color(0xFFE7EBEF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: EdgeInsets.all(5 * scale),
                decoration: BoxDecoration(
                  color: severityColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(7 * scale),
                ),
                child: Icon(
                  Icons.report_problem_rounded,
                  color: severityColor,
                  size: 15 * scale,
                ),
              ),
              SizedBox(width: 7 * scale),
              Expanded(
                child: Text(
                  type.toString().toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13 * scale,
                    fontWeight: FontWeight.w800,
                    color: const Color(0xFF0F172A),
                  ),
                ),
              ),
              if (incidentId.isNotEmpty)
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 6 * scale,
                    vertical: 2 * scale,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(6 * scale),
                  ),
                  child: Text(
                    incidentId,
                    style: TextStyle(
                      fontSize: 9.5 * scale,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF475569),
                    ),
                  ),
                ),
            ],
          ),

          SizedBox(height: 6 * scale),

          _detailRow(
            Icons.location_on_rounded,
            location,
            const Color(0xFFDC2626),
            scale,
          ),

          _detailRow(
            Icons.person_outline_rounded,
            'Reporter: $reporterName',
            const Color(0xFF0B6B43),
            scale,
          ),

          _detailRow(
            Icons.phone_outlined,
            'Contact: $reporterPhone',
            const Color(0xFFF59E0B),
            scale,
          ),

          if (date.isNotEmpty || time.isNotEmpty)
            _detailRow(
              Icons.schedule_rounded,
              '$date${date.isNotEmpty && time.isNotEmpty ? " • " : ""}$time',
              const Color(0xFF64748B),
              scale,
            ),

          if (description.isNotEmpty)
            _detailRow(
              Icons.description_outlined,
              description,
              const Color(0xFF2563EB),
              scale,
              maxLines: 3,
            ),

          if (injured > 0 || fatalities > 0 || trapped > 0) ...[
            SizedBox(height: 5 * scale),
            Wrap(
              spacing: 5 * scale,
              runSpacing: 5 * scale,
              children: [
                if (injured > 0)
                  _casualtyChip(
                      '🤕 $injured injured', const Color(0xFFF59E0B), scale),
                if (fatalities > 0)
                  _casualtyChip('💀 $fatalities fatalities',
                      const Color(0xFFDC2626), scale),
                if (trapped > 0)
                  _casualtyChip(
                      '🚧 $trapped trapped', const Color(0xFF2563EB), scale),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Color _severityColor(String? severity) {
    switch (severity?.toLowerCase()) {
      case 'emergency':
      case 'high':
        return const Color(0xFFDC2626);
      case 'medium':
        return const Color(0xFFF59E0B);
      default:
        return const Color(0xFF2563EB);
    }
  }

  Widget _detailRow(
    IconData icon,
    String text,
    Color color,
    double scale, {
    int maxLines = 1,
  }) {
    return Padding(
      padding: EdgeInsets.only(top: 4 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13 * scale, color: color),
          SizedBox(width: 6 * scale),
          Expanded(
            child: Text(
              text,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12 * scale,
                fontWeight: FontWeight.w600,
                color: const Color(0xFF334155),
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _casualtyChip(String label, Color color, double scale) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 7 * scale,
        vertical: 3 * scale,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(7 * scale),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10 * scale,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

// ================================================================
// ROUTE INFO BUBBLE
// ================================================================

class _RouteInfoBubble extends StatelessWidget {
  final String distance;
  final String eta;
  final double scale;

  const _RouteInfoBubble({
    required this.distance,
    required this.eta,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 12 * scale,
        vertical: 6 * scale,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF172033),
        borderRadius: BorderRadius.circular(10 * scale),
        border: Border.all(color: const Color(0xFF06B6D4), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            distance,
            style: TextStyle(
              color: const Color(0xFF22D3EE),
              fontSize: 14 * scale,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: 1 * scale),
          Text(
            eta == '--' ? 'drive' : '$eta drive',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 10.5 * scale,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ================================================================
// ROUND MAP BUTTON
// ================================================================

class _RoundMapButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final double scale;

  const _RoundMapButton({
    required this.icon,
    required this.onTap,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.20),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 43 * scale,
          height: 43 * scale,
          child: Icon(
            icon,
            color: const Color(0xFF374151),
            size: 21 * scale,
          ),
        ),
      ),
    );
  }
}

// ================================================================
// NAVIGATION BUTTON
// ================================================================

class _NavigationButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final double scale;
  final bool filled;

  const _NavigationButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.scale,
    this.filled = false,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 42 * scale,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 17 * scale),
        label: Text(
          label,
          style: TextStyle(
            fontSize: 12.5 * scale,
            fontWeight: FontWeight.w700,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: filled ? const Color(0xFF0B6B43) : Colors.white,
          foregroundColor: filled ? Colors.white : const Color(0xFF0B6B43),
          elevation: filled ? 1 : 0,
          side: filled
              ? null
              : const BorderSide(color: Color(0xFFD1D5DB)),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11 * scale),
          ),
        ),
      ),
    );
  }
}