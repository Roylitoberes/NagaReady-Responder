// incident_report_page.dart
//
// SOS Emergency Report — SINGLE SOURCE OF TRUTH for location.
// Whatever `_location` holds is:
//   (a) what the map pin renders from,
//   (b) what the location card shows,
//   (c) what gets written to Firestore (under every alias so any
//       downstream system finds the same value).

import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:location/location.dart' as loc;

class _IRC {
  static const primary = Color(0xFF075E3B);
  static const bg = Color(0xFFF5F7F8);
  static const card = Color(0xFFFFFFFF);
  static const cardAlt = Color(0xFFF1F5F9);
  static const ink = Color(0xFF0F172A);
  static const slate = Color(0xFF64748B);
  static const muted = Color(0xFF94A3B8);
  static const line = Color(0xFFE5E9EE);
  static const headerRed = Color(0xFFB00000);
  static const danger = Color(0xFFDC2626);
  static const dangerDeep = Color(0xFF8B0000);
  static const success = Color(0xFF16A34A);
  static const warning = Color(0xFFF59E0B);
}

class IncidentType {
  final String id;
  final String name;
  final IconData icon;
  final Color color;
  final Color solidBg;
  const IncidentType({
    required this.id,
    required this.name,
    required this.icon,
    required this.color,
    required this.solidBg,
  });
}

class Casualties {
  final int injured;
  final int fatalities;
  final int trapped;
  const Casualties({
    this.injured = 0,
    this.fatalities = 0,
    this.trapped = 0,
  });
  Casualties copyWith({int? injured, int? fatalities, int? trapped}) {
    return Casualties(
      injured: injured ?? this.injured,
      fatalities: fatalities ?? this.fatalities,
      trapped: trapped ?? this.trapped,
    );
  }
}

class LocationData {
  final double latitude;
  final double longitude;
  final String address;
  const LocationData({
    required this.latitude,
    required this.longitude,
    required this.address,
  });
}

class IncidentReportResult {
  final String incidentId;
  final String incidentType;
  final String? specificType;
  final String fullName;
  final String phoneNumber;
  final LocationData? location;
  final Casualties casualties;
  final String? firestoreId;
  IncidentReportResult({
    required this.incidentId,
    required this.incidentType,
    required this.specificType,
    required this.fullName,
    required this.phoneNumber,
    required this.location,
    required this.casualties,
    this.firestoreId,
  });
}

class IncidentReportPage extends StatefulWidget {
  final void Function(IncidentReportResult result)? onSubmit;
  final VoidCallback? onClose;
  final VoidCallback? onAuthRequired;
  final String? initialFullName;
  final String? initialPhoneNumber;
  final bool isAuthenticated;

  const IncidentReportPage({
    super.key,
    this.onSubmit,
    this.onClose,
    this.onAuthRequired,
    this.initialFullName,
    this.initialPhoneNumber,
    this.isAuthenticated = false,
  });

  @override
  State<IncidentReportPage> createState() => _IncidentReportPageState();
}

class _IncidentReportPageState extends State<IncidentReportPage> {
  int _selectedIndex = -1;
  String _selectedIncident = '';
  String _otherSpecificType = '';

  late final TextEditingController _fullNameController;
  late final TextEditingController _phoneController;

  // ═══════════════════════════════════════════════════════════
  //  ONE location variable. The map pin reads from this.
  //  The card reads from this. Firestore writes this.
  // ═══════════════════════════════════════════════════════════
  LocationData? _location;

  bool _isGettingLocation = false;
  bool _locationRequested = false;
  bool _locationManuallyConfirmed = false;

  Casualties _casualties = const Casualties();
  bool _isSubmitting = false;
  bool _isSubmitted = false;

  bool _showSuccessModal = false;
  bool _showOtherTypeModal = false;
  bool _showMapModal = false;
  IncidentReportResult? _submittedReport;

  final MapController _mapController = MapController();
  Timer? _reverseDebounce;

  final loc.Location _locationService = loc.Location();

  static const List<IncidentType> _incidentTypes = [
    IncidentType(
        id: 'fire',
        name: 'Fire',
        icon: Icons.local_fire_department_rounded,
        color: Color(0xFFEF4444),
        solidBg: Color(0xFFFEE2E2)),
    IncidentType(
        id: 'medical',
        name: 'Medical',
        icon: Icons.medical_services_rounded,
        color: Color(0xFFDC2626),
        solidBg: Color(0xFFFEE2E2)),
    IncidentType(
        id: 'flood',
        name: 'Flood',
        icon: Icons.water_drop_rounded,
        color: Color(0xFF2563EB),
        solidBg: Color(0xFFDBEAFE)),
    IncidentType(
        id: 'crime',
        name: 'Crime',
        icon: Icons.shield_rounded,
        color: Color(0xFF7C3AED),
        solidBg: Color(0xFFEDE9FE)),
    IncidentType(
        id: 'accident',
        name: 'Accident',
        icon: Icons.directions_car_rounded,
        color: Color(0xFFF59E0B),
        solidBg: Color(0xFFFEF3C7)),
    IncidentType(
        id: 'other',
        name: 'Other',
        icon: Icons.more_horiz_rounded,
        color: Color(0xFF475569),
        solidBg: Color(0xFFE2E8F0)),
  ];

  @override
  void initState() {
    super.initState();
    _fullNameController =
        TextEditingController(text: widget.initialFullName ?? '');
    _phoneController =
        TextEditingController(text: widget.initialPhoneNumber ?? '');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestAutoLocation();
    });
  }

  @override
  void dispose() {
    _reverseDebounce?.cancel();
    _fullNameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  // ============================================================
  // AUTO LOCATION
  // ============================================================
  Future<void> _requestAutoLocation() async {
    if (_locationRequested) return;
    _locationRequested = true;
    setState(() => _isGettingLocation = true);

    try {
      bool serviceEnabled = await _locationService.serviceEnabled();
      if (!serviceEnabled) {
        serviceEnabled = await _locationService.requestService();
        if (!serviceEnabled) {
          _showLocationAlert(
            'Location Services Disabled',
            'Please turn on your device location so we can auto-detect where the emergency is.',
          );
          setState(() => _isGettingLocation = false);
          _locationRequested = false;
          return;
        }
      }

      loc.PermissionStatus permission =
          await _locationService.hasPermission();
      if (permission == loc.PermissionStatus.denied) {
        permission = await _locationService.requestPermission();
      }
      if (permission != loc.PermissionStatus.granted &&
          permission != loc.PermissionStatus.grantedLimited) {
        _showLocationAlert(
          'Location Permission Needed',
          'Please allow location access so we can auto-detect where the emergency is.',
        );
        setState(() => _isGettingLocation = false);
        _locationRequested = false;
        return;
      }

      await Future.delayed(const Duration(milliseconds: 500));

      LocationData? detected;
      for (int attempt = 1; attempt <= 3; attempt++) {
        try {
          final data = await _locationService.getLocation();
          final lat = data.latitude;
          final lng = data.longitude;
          if (lat == null || lng == null) {
            await Future.delayed(const Duration(milliseconds: 700));
            continue;
          }
          final address = await _reverseGeocode(lat, lng);
          detected = LocationData(
            latitude: lat,
            longitude: lng,
            address: address ??
                '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}',
          );
          break;
        } catch (_) {
          await Future.delayed(const Duration(milliseconds: 800));
        }
      }

      if (detected != null && mounted) {
        // 🔒 DO NOT overwrite a manual pin.
        if (!_locationManuallyConfirmed) {
          setState(() => _location = detected);
        } else {
          debugPrint('⏭️ Auto-location skipped (user confirmed a manual pin)');
        }
      } else {
        _locationRequested = false;
      }
    } catch (e) {
      debugPrint('❌ Auto-location error: $e');
      _locationRequested = false;
    } finally {
      if (mounted) setState(() => _isGettingLocation = false);
    }
  }

  Future<String?> _reverseGeocode(double lat, double lng) async {
    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$lat&lon=$lng&zoom=18&addressdetails=1',
      );
      final res = await http.get(uri, headers: {
        'Accept': 'application/json',
        'User-Agent': 'ResponderApp/1.0',
      });
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return data['display_name'] as String?;
      }
    } catch (_) {}
    return null;
  }

  void _showLocationAlert(String title, String message) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _IRC.card,
        title: Text(title, style: const TextStyle(color: _IRC.ink)),
        content: Text(message, style: const TextStyle(color: _IRC.slate)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: _IRC.primary)),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // CASUALTIES
  // ============================================================
  void _changeCasualty(String key, bool increment) {
    setState(() {
      int current = key == 'injured'
          ? _casualties.injured
          : key == 'fatalities'
              ? _casualties.fatalities
              : _casualties.trapped;
      final next = (current + (increment ? 1 : -1)).clamp(0, 9999);
      if (key == 'injured') {
        _casualties = _casualties.copyWith(injured: next);
      } else if (key == 'fatalities') {
        _casualties = _casualties.copyWith(fatalities: next);
      } else {
        _casualties = _casualties.copyWith(trapped: next);
      }
    });
  }

  void _handleIncidentSelect(IncidentType type, int index) {
    setState(() {
      _selectedIndex = index;
      _selectedIncident = type.name;
    });
    if (type.name == 'Other') {
      setState(() => _showOtherTypeModal = true);
    }
  }

  // ============================================================
  // MAP: tap updates _location DIRECTLY (no temp variable)
  // ============================================================
  void _onMapTap(LatLng pos) {
    _reverseDebounce?.cancel();

    // 1️⃣ Immediately set _location to the tapped coords.
    setState(() {
      _location = LocationData(
        latitude: pos.latitude,
        longitude: pos.longitude,
        address: 'Locating address…',
      );
      _locationManuallyConfirmed = true;
    });

    debugPrint('📍 Pin moved: ${pos.latitude}, ${pos.longitude}');

    // 2️⃣ Reverse geocode in background; update ONLY address.
    _reverseDebounce = Timer(const Duration(milliseconds: 350), () async {
      final addr = await _reverseGeocode(pos.latitude, pos.longitude);
      if (!mounted) return;

      final cur = _location;
      if (cur == null) return;
      // Guard against stale responses overriding a newer tap.
      if (cur.latitude != pos.latitude || cur.longitude != pos.longitude) {
        return;
      }

      setState(() {
        _location = LocationData(
          latitude: pos.latitude,
          longitude: pos.longitude,
          address: addr ??
              '${pos.latitude.toStringAsFixed(6)}, '
                  '${pos.longitude.toStringAsFixed(6)}',
        );
      });

      debugPrint('📍 Address updated for pin: ${_location?.address}');
    });
  }

  void _openMapForConfirmation() {
    if (!widget.isAuthenticated) {
      _showAuthRequired();
      return;
    }

    if (_location == null) {
      _requestAutoLocation().then((_) {
        if (!mounted) return;
        if (_location != null) {
          setState(() => _showMapModal = true);
        }
      });
      return;
    }

    setState(() => _showMapModal = true);
  }

  void _confirmLocationFromMap() {
    // _location is ALREADY the pin. Nothing to copy. Just lock it.
    setState(() {
      _locationManuallyConfirmed = true;
      _showMapModal = false;
    });
    debugPrint(
        '✅ Location confirmed: ${_location?.latitude}, '
        '${_location?.longitude} — ${_location?.address}');
  }

  // ============================================================
  // SUBMIT
  // ============================================================
  Future<void> _handleSubmit() async {
    if (_isSubmitted || _isSubmitting) return;

    if (!widget.isAuthenticated) {
      _showAuthRequired();
      return;
    }

    if (_selectedIncident.isEmpty) {
      _showAlert('Error', 'Please select the type of emergency.');
      return;
    }

    if (_selectedIncident == 'Other' && _otherSpecificType.trim().isEmpty) {
      setState(() => _showOtherTypeModal = true);
      return;
    }

    if (_fullNameController.text.trim().isEmpty) {
      _showAlert('Error', 'Please enter your full name.');
      return;
    }

    if (_phoneController.text.trim().isEmpty) {
      _showAlert('Error', 'Please enter your mobile number.');
      return;
    }

    if (_location == null) {
      _showAlert('Error', 'Please wait for your location to be detected.');
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      final now = DateTime.now();
      final reportId = 'INC-${now.millisecondsSinceEpoch}';

      final submittedAtString =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}:'
          '${now.second.toString().padLeft(2, '0')}';

      final incidentTypeValue = _selectedIncident == 'Other'
          ? (_otherSpecificType.trim().isEmpty
              ? 'Other'
              : 'Other - ${_otherSpecificType.trim()}')
          : _selectedIncident;

      final description = _selectedIncident == 'Other'
          ? 'Reported via SOS Emergency Report — ${_otherSpecificType.trim()}'
          : 'Reported via SOS Emergency Report — $_selectedIncident';

      // ═══════════════════════════════════════════════════════
      //  Snapshot the SINGLE source of truth.
      //  Whatever the pin shows is EXACTLY what we write.
      // ═══════════════════════════════════════════════════════
      final lat = _location!.latitude;
      final lng = _location!.longitude;
      final addr = _location!.address;

      debugPrint('📤 SUBMIT: lat=$lat lng=$lng addr=$addr');

      // ── incident_reports/{auto} ──────────────────────────
      final reportPayload = <String, dynamic>{
        'incidentId': reportId,
        'timestamp': FieldValue.serverTimestamp(),
        'incidentType': incidentTypeValue,
        'reporter': {
          'fullName': _fullNameController.text.trim(),
          'phoneNumber': _phoneController.text.trim(),
        },

        // ─── location (nested, with every alias) ─────────────
        'location': {
          'latitude': lat,
          'longitude': lng,
          'lat': lat,
          'lng': lng,
          'address': addr,
          'isManual': _locationManuallyConfirmed,
          'coordinates': {
            'lat': lat,
            'lng': lng,
            'latitude': lat,
            'longitude': lng,
          },
        },

        // ─── top-level aliases ───────────────────────────────
        'lat': lat,
        'lng': lng,
        'latitude': lat,
        'longitude': lng,
        'address': addr,
        'coordinates': {
          'lat': lat,
          'lng': lng,
          'latitude': lat,
          'longitude': lng,
        },

        'description': description,
        'casualties': {
          'injured': _casualties.injured,
          'fatalities': _casualties.fatalities,
          'trapped': _casualties.trapped,
        },
        'status': 'submitted',
        'submittedAt': submittedAtString,
        'userId': user?.uid ?? 'guest_${now.millisecondsSinceEpoch}',
        'isGuest': user == null,
        'source': 'responder_app',
        'createdAt': FieldValue.serverTimestamp(),
      };

      final docRef = await FirebaseFirestore.instance
          .collection('incident_reports')
          .add(reportPayload);

      debugPrint('✅ incident_reports/${docRef.id} ($reportId) '
          'lat=$lat lng=$lng');

      // ── Verify what was ACTUALLY written ─────────────────
      try {
        final verify =
            await FirebaseFirestore.instance
                .collection('incident_reports')
                .doc(docRef.id)
                .get();
        debugPrint('🔍 FIRESTORE SAVED: '
            'lat=${verify.data()?['location']?['latitude']} '
            'lng=${verify.data()?['location']?['longitude']}');
      } catch (_) {}

      // ── notifications/{auto} — same lat/lng ──────────────
      final notificationPayload = <String, dynamic>{
        'reportId': reportId,
        'incidentType': _selectedIncident,
        'specificType':
            _selectedIncident == 'Other' ? _otherSpecificType.trim() : null,
        'reporter': {
          'fullName': _fullNameController.text.trim(),
          'phoneNumber': _phoneController.text.trim(),
        },
        'location': {
          'latitude': lat,
          'longitude': lng,
          'lat': lat,
          'lng': lng,
          'address': addr,
          'coordinates': {
            'lat': lat,
            'lng': lng,
            'latitude': lat,
            'longitude': lng,
          },
        },
        'lat': lat,
        'lng': lng,
        'latitude': lat,
        'longitude': lng,
        'address': addr,
        'coordinates': {
          'lat': lat,
          'lng': lng,
          'latitude': lat,
          'longitude': lng,
        },
        'description': description,
        'photoUrl': null,
        'hasPhoto': false,
        'status': 'pending',
        'read': false,
        'type': 'incident_report',
        'priority': _priorityFor(_selectedIncident),
        'timestamp': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
        'casualties': {
          'injured': _casualties.injured,
          'fatalities': _casualties.fatalities,
          'trapped': _casualties.trapped,
        },
        'userId': user?.uid ?? '',
        'source': 'responder_app',
      };

      await FirebaseFirestore.instance
          .collection('notifications')
          .add(notificationPayload);

      debugPrint('🔔 notifications/ written for $reportId '
          'lat=$lat lng=$lng');

      final result = IncidentReportResult(
        incidentId: reportId,
        incidentType: _selectedIncident,
        specificType:
            _selectedIncident == 'Other' ? _otherSpecificType.trim() : null,
        fullName: _fullNameController.text.trim(),
        phoneNumber: _phoneController.text.trim(),
        location: _location,
        casualties: _casualties,
        firestoreId: docRef.id,
      );

      if (!mounted) return;
      setState(() {
        _submittedReport = result;
        _isSubmitted = true;
        _showSuccessModal = true;
      });

      widget.onSubmit?.call(result);

      if (_selectedIncident == 'Medical') {
        Future.delayed(const Duration(milliseconds: 500), () {
          if (!mounted) return;
          _showAlert(
            '🚨 Medical Emergency',
            'Emergency responders have been automatically dispatched to your location.',
          );
        });
      }
    } catch (e) {
      debugPrint('❌ Failed to submit report: $e');
      if (!mounted) return;
      setState(() => _isSubmitting = false);
      _showAlert(
        'Error',
        'Failed to submit report. Please check your connection and try again.',
      );
    }
  }

  String _priorityFor(String incidentType) {
    switch (incidentType) {
      case 'Fire':
      case 'Medical':
      case 'Accident':
        return 'critical';
      case 'Flood':
      case 'Crime':
        return 'high';
      default:
        return 'normal';
    }
  }

  void _showAuthRequired() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _IRC.card,
        title: const Text('Sign In Required',
            style: TextStyle(color: _IRC.ink)),
        content: const Text('Please sign in to submit your report.',
            style: TextStyle(color: _IRC.slate)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: _IRC.slate)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              widget.onAuthRequired?.call();
            },
            child: const Text('Sign In',
                style: TextStyle(color: _IRC.primary)),
          ),
        ],
      ),
    );
  }

  void _showAlert(String title, String message) {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _IRC.card,
        title: Text(title, style: const TextStyle(color: _IRC.ink)),
        content: Text(message, style: const TextStyle(color: _IRC.slate)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: _IRC.primary)),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // BUILD
  // ============================================================
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildIncidentTypeSection(),
                    _buildCasualtiesSection(),
                    _buildLocationSection(),
                    _buildNameSection(),
                    _buildPhoneSection(),
                    _buildEmergencyNote(),
                  ],
                ),
              ),
            ),
            _buildStickyFooter(),
          ],
        ),
        _buildMapModal(),
        _buildSuccessModal(),
        _buildOtherTypeModal(),
      ],
    );
  }

  Widget _buildIncidentTypeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('🚨 What type of emergency?',
            style: TextStyle(
                color: _IRC.ink,
                fontSize: 16,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _incidentTypes.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.95,
          ),
          itemBuilder: (context, index) {
            final type = _incidentTypes[index];
            return _IncidentTypeTile(
              type: type,
              isSelected: _selectedIndex == index,
              onTap: () => _handleIncidentSelect(type, index),
            );
          },
        ),
        if (_selectedIncident == 'Other' &&
            _otherSpecificType.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _IRC.success.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: _IRC.success.withValues(alpha: 0.35)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.local_offer_rounded,
                      color: _IRC.success, size: 14),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Specific Type: $_otherSpecificType',
                      style: const TextStyle(
                          color: _IRC.success,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  GestureDetector(
                    onTap: () =>
                        setState(() => _showOtherTypeModal = true),
                    child: const Text(
                      'Edit',
                      style: TextStyle(
                        color: _IRC.ink,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCasualtiesSection() {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('👥 Casualties',
              style: TextStyle(
                  color: _IRC.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _CasualtyCard(
                  label: 'Injured',
                  icon: Icons.medical_services_rounded,
                  iconBg: _IRC.danger,
                  value: _casualties.injured,
                  enabled: widget.isAuthenticated,
                  onIncrement: () => _changeCasualty('injured', true),
                  onDecrement: () => _changeCasualty('injured', false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CasualtyCard(
                  label: 'Fatalities',
                  icon: Icons.error_outline_rounded,
                  iconBg: _IRC.dangerDeep,
                  value: _casualties.fatalities,
                  enabled: widget.isAuthenticated,
                  onIncrement: () => _changeCasualty('fatalities', true),
                  onDecrement: () => _changeCasualty('fatalities', false),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _CasualtyCard(
                  label: 'Trapped',
                  icon: Icons.people_alt_rounded,
                  iconBg: const Color(0xFF6B7280),
                  value: _casualties.trapped,
                  enabled: widget.isAuthenticated,
                  onIncrement: () => _changeCasualty('trapped', true),
                  onDecrement: () => _changeCasualty('trapped', false),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLocationSection() {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('📍 Your Location (Auto-detected)',
              style: TextStyle(
                  color: _IRC.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          _InputContainer(
            enabled: widget.isAuthenticated,
            onTap: _openMapForConfirmation,
            child: Row(
              children: [
                Icon(Icons.location_on_outlined,
                    size: 20,
                    color:
                        widget.isAuthenticated ? _IRC.danger : _IRC.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _isGettingLocation
                        ? 'Auto-detecting your location...'
                        : _location?.address ??
                            (widget.isAuthenticated
                                ? 'Auto-detecting your location...'
                                : 'Sign in to access location'),
                    style: TextStyle(
                      color: widget.isAuthenticated
                          ? _IRC.slate
                          : _IRC.muted,
                      fontSize: 13.5,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.isAuthenticated)
                  const Icon(Icons.chevron_right_rounded,
                      size: 20, color: _IRC.muted),
              ],
            ),
          ),
          if (_location != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: Row(
                children: [
                  Text(
                    '${_location!.latitude.toStringAsFixed(6)}, '
                    '${_location!.longitude.toStringAsFixed(6)}',
                    style: const TextStyle(
                        color: _IRC.muted,
                        fontSize: 11,
                        fontFamily: 'monospace'),
                  ),
                  if (_locationManuallyConfirmed) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.push_pin_rounded,
                        size: 12, color: _IRC.success),
                    const SizedBox(width: 4),
                    const Text('Manual pin',
                        style: TextStyle(
                            color: _IRC.success,
                            fontSize: 10,
                            fontWeight: FontWeight.w700)),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNameSection() {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('👤 Your Full Name',
              style: TextStyle(
                  color: _IRC.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          _InputContainer(
            enabled: widget.isAuthenticated,
            child: Row(
              children: [
                Icon(Icons.person_outline_rounded,
                    size: 20,
                    color:
                        widget.isAuthenticated ? _IRC.danger : _IRC.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _fullNameController,
                    enabled: widget.isAuthenticated,
                    style: const TextStyle(
                        color: _IRC.ink, fontSize: 14.5),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      hintText: widget.isAuthenticated
                          ? 'Enter your full name'
                          : 'Sign in to fill automatically',
                      hintStyle: const TextStyle(
                          color: _IRC.muted, fontSize: 14.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (widget.isAuthenticated &&
              (widget.initialFullName ?? '').isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6, left: 4),
              child: Text('✓ Auto-filled from your profile',
                  style: TextStyle(color: _IRC.success, fontSize: 11)),
            ),
        ],
      ),
    );
  }

  Widget _buildPhoneSection() {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('📱 Your Mobile Number',
              style: TextStyle(
                  color: _IRC.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          _InputContainer(
            enabled: widget.isAuthenticated,
            child: Row(
              children: [
                Icon(Icons.call_outlined,
                    size: 20,
                    color:
                        widget.isAuthenticated ? _IRC.danger : _IRC.muted),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _phoneController,
                    enabled: widget.isAuthenticated,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(11),
                    ],
                    style: const TextStyle(
                        color: _IRC.ink, fontSize: 14.5),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      isDense: true,
                      hintText: widget.isAuthenticated
                          ? 'Enter your mobile number'
                          : 'Sign in to fill automatically',
                      hintStyle: const TextStyle(
                          color: _IRC.muted, fontSize: 14.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (widget.isAuthenticated &&
              (widget.initialPhoneNumber ?? '').isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 6, left: 4),
              child: Text('✓ Auto-filled from your profile',
                  style: TextStyle(color: _IRC.success, fontSize: 11)),
            ),
        ],
      ),
    );
  }

  Widget _buildEmergencyNote() {
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.verified_user_rounded,
              color: _IRC.success, size: 16),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'For emergencies, responders will be dispatched immediately',
              style: TextStyle(color: _IRC.muted, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStickyFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        color: _IRC.bg,
        border: Border(top: BorderSide(color: _IRC.line)),
      ),
      child: widget.isAuthenticated
          ? _PrimaryButton(
              icon: Icons.send_rounded,
              label: _isSubmitted
                  ? 'REPORT SENT ✓'
                  : _isSubmitting
                      ? 'SUBMITTING...'
                      : 'SUBMIT EMERGENCY REPORT',
              onTap: _isSubmitted || _isSubmitting ? null : _handleSubmit,
            )
          : _OutlineButton(
              icon: Icons.login_rounded,
              label: 'SIGN IN TO SUBMIT REPORT',
              onTap: () => widget.onAuthRequired?.call(),
            ),
    );
  }

  // ============================================================
  // MAP MODAL — pin reads DIRECTLY from _location
  // ============================================================
  Widget _buildMapModal() {
    if (!_showMapModal) return const SizedBox.shrink();
    final loc0 = _location;

    return Positioned.fill(
      child: Material(
        color: _IRC.bg,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () =>
                          setState(() => _showMapModal = false),
                      icon: const Icon(Icons.arrow_back_rounded,
                          color: _IRC.ink),
                    ),
                    const Expanded(
                      child: Text(
                        'Confirm Your Location',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: _IRC.ink,
                            fontSize: 18,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      onPressed: _confirmLocationFromMap,
                      icon: const Icon(Icons.check_circle_rounded,
                          color: _IRC.success, size: 28),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: loc0 == null
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: _IRC.primary))
                    : FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          // ✅ Pin location IS the map center.
                          initialCenter:
                              LatLng(loc0.latitude, loc0.longitude),
                          initialZoom: 17,
                          minZoom: 10,
                          maxZoom: 19,
                          onTap: (_, pos) => _onMapTap(pos),
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName:
                                'com.example.responder_app',
                          ),
                          MarkerLayer(
                            // ✅ Rebuild marker whenever _location changes.
                            key: ValueKey(
                                'pin-${loc0.latitude}-${loc0.longitude}'),
                            markers: [
                              Marker(
                                // ✅ Pin point == _location == saved value.
                                point: LatLng(
                                    loc0.latitude, loc0.longitude),
                                width: 44,
                                height: 44,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: _IRC.danger,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.white, width: 3),
                                    boxShadow: [
                                      BoxShadow(
                                        color: _IRC.danger
                                            .withValues(alpha: 0.45),
                                        blurRadius: 10,
                                        spreadRadius: 2,
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.location_on_rounded,
                                    color: Colors.white,
                                    size: 24,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
              ),
              // Live coordinate readout
              if (loc0 != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 8),
                  child: Text(
                    '${loc0.latitude.toStringAsFixed(6)}, '
                    '${loc0.longitude.toStringAsFixed(6)}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: _IRC.muted,
                        fontSize: 11,
                        fontFamily: 'monospace'),
                  ),
                ),
              Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: _IRC.card,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _IRC.line),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.location_on_outlined,
                        color: _IRC.danger, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        loc0?.address ??
                            'Tap the map to set your location',
                        style: const TextStyle(
                            color: _IRC.ink, fontSize: 13.5),
                      ),
                    ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.info_outline_rounded,
                        color: _IRC.muted, size: 16),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Tap anywhere on the map to change your location',
                        style:
                            TextStyle(color: _IRC.muted, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _confirmLocationFromMap,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _IRC.primary,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14)),
                    ),
                    child: const Text(
                      'Confirm Location',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700),
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

  Widget _buildSuccessModal() {
    if (!_showSuccessModal) return const SizedBox.shrink();
    final report = _submittedReport;
    return Positioned.fill(
      child: Material(
        color: Colors.black.withValues(alpha: 0.60),
        child: Center(
          child: Container(
            width: MediaQuery.of(context).size.width * 0.85,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: _IRC.card,
              borderRadius: BorderRadius.circular(24),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.check_circle_rounded,
                      color: _IRC.success, size: 72),
                  const SizedBox(height: 16),
                  const Text('Report Submitted!',
                      style: TextStyle(
                          color: _IRC.ink,
                          fontSize: 22,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 8),
                  const Text(
                    'Your emergency report has been sent to CDRRMO.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _IRC.slate, fontSize: 13.5),
                  ),
                  if (report?.incidentType == 'Medical') ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: _IRC.danger.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.error_outline_rounded,
                              color: _IRC.danger, size: 18),
                          SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Medical team has been automatically dispatched',
                              style: TextStyle(
                                  color: _IRC.danger,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: _IRC.cardAlt,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _detailRow(
                          'Reference',
                          '#${(report?.incidentId ?? '').length >= 8 ? report!.incidentId.substring(report.incidentId.length - 8) : (report?.incidentId ?? '')}',
                        ),
                        _detailRow(
                          'Incident Type',
                          report?.incidentType == 'Other'
                              ? 'Others'
                              : report?.incidentType ?? '',
                        ),
                        if (report?.incidentType == 'Other' &&
                            (report?.specificType ?? '').isNotEmpty)
                          _detailRow('Specific Type',
                              report!.specificType!),
                        _detailRow('Location',
                            report?.location?.address ?? 'Unknown location'),
                        if (report?.location != null)
                          _detailRow(
                            'Coordinates',
                            '${report!.location!.latitude.toStringAsFixed(6)}, '
                                '${report.location!.longitude.toStringAsFixed(6)}',
                          ),
                        _detailRow('Reporter', report?.fullName ?? ''),
                        _detailRow('Phone', report?.phoneNumber ?? ''),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _showSuccessModal = false;
                          _isSubmitted = false;
                          _selectedIncident = '';
                          _selectedIndex = -1;
                          _otherSpecificType = '';
                          _casualties = const Casualties();
                          _locationManuallyConfirmed = false;
                          _locationRequested = false;
                        });
                        widget.onClose?.call();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _IRC.primary,
                        padding:
                            const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text(
                        'Close',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text('$label: $value',
          style: const TextStyle(color: _IRC.slate, fontSize: 12)),
    );
  }

  Widget _buildOtherTypeModal() {
    if (!_showOtherTypeModal) return const SizedBox.shrink();
    return _OtherTypeModal(
      initialValue: _otherSpecificType,
      onClose: () => setState(() => _showOtherTypeModal = false),
      onSave: (value) {
        setState(() {
          _otherSpecificType = value;
          _showOtherTypeModal = false;
        });
        _showAlert(
            'Specific Type Saved',
            'Incident Type: Others\nSpecific Type: $value');
      },
    );
  }
}

// ============================================================
// REUSABLE WIDGETS
// ============================================================

class _IncidentTypeTile extends StatelessWidget {
  final IncidentType type;
  final bool isSelected;
  final VoidCallback onTap;
  const _IncidentTypeTile({
    required this.type,
    required this.isSelected,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected ? type.solidBg : _IRC.card,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isSelected ? type.color : _IRC.line,
              width: isSelected ? 1.5 : 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: type.color.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                ),
                child: Icon(type.icon, color: type.color, size: 26),
              ),
              const SizedBox(height: 8),
              Text(
                type.name,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight:
                      isSelected ? FontWeight.w800 : FontWeight.w600,
                  color: isSelected ? type.color : _IRC.ink,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CasualtyCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color iconBg;
  final int value;
  final bool enabled;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;
  const _CasualtyCard({
    required this.label,
    required this.icon,
    required this.iconBg,
    required this.value,
    required this.enabled,
    required this.onIncrement,
    required this.onDecrement,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
      decoration: BoxDecoration(
        color: _IRC.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _IRC.line),
      ),
      child: Column(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration:
                BoxDecoration(color: iconBg, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 18),
          ),
          const SizedBox(height: 4),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: _IRC.slate,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _CounterButton(
                  icon: Icons.remove_rounded,
                  enabled: enabled,
                  onTap: onDecrement),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  value.toString(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: _IRC.ink,
                      fontSize: 16,
                      fontWeight: FontWeight.w800),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              _CounterButton(
                  icon: Icons.add_rounded,
                  enabled: enabled,
                  onTap: onIncrement),
            ],
          ),
        ],
      ),
    );
  }
}

class _CounterButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;
  const _CounterButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: enabled ? _IRC.line : _IRC.line.withValues(alpha: 0.5),
            ),
          ),
          child: Icon(icon,
              size: 13, color: enabled ? _IRC.slate : _IRC.muted),
        ),
      ),
    );
  }
}

class _InputContainer extends StatelessWidget {
  final bool enabled;
  final VoidCallback? onTap;
  final Widget child;
  const _InputContainer({
    required this.enabled,
    required this.child,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final content = Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: _IRC.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _IRC.line),
      ),
      child: child,
    );

    if (onTap != null) {
      return Opacity(
        opacity: enabled ? 1 : 0.6,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: enabled ? onTap : null,
            child: content,
          ),
        ),
      );
    }
    return Opacity(opacity: enabled ? 1 : 0.6, child: content);
  }
}

class _PrimaryButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  const _PrimaryButton({
    required this.icon,
    required this.label,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: _IRC.headerRed,
          disabledBackgroundColor: _IRC.headerRed.withValues(alpha: 0.7),
          padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 2,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutlineButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _OutlineButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          backgroundColor: _IRC.card,
          side: const BorderSide(color: _IRC.primary),
          padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: _IRC.primary, size: 18),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _IRC.primary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OtherTypeModal extends StatefulWidget {
  final String initialValue;
  final VoidCallback onClose;
  final void Function(String value) onSave;
  const _OtherTypeModal({
    required this.initialValue,
    required this.onClose,
    required this.onSave,
  });
  @override
  State<_OtherTypeModal> createState() => _OtherTypeModalState();
}

class _OtherTypeModalState extends State<_OtherTypeModal> {
  late final TextEditingController _controller;

  static const List<String> _examples = [
    'Landslide',
    'Earthquake',
    'Road obstruction',
    'Missing person',
    'Structural collapse',
    'Other emergency',
  ];

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleSave() {
    final trimmed = _controller.text.trim();
    if (trimmed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter the incident type.')),
      );
      return;
    }
    widget.onSave(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Material(
        color: Colors.black.withValues(alpha: 0.60),
        child: Center(
          child: Container(
            width: MediaQuery.of(context).size.width * 0.88,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _IRC.card,
              borderRadius: BorderRadius.circular(20),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: _IRC.warning.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.help_outline_rounded,
                            color: _IRC.warning, size: 24),
                      ),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Other Incident Type',
                          style: TextStyle(
                              color: _IRC.ink,
                              fontSize: 18,
                              fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Please specify the type of emergency.',
                    style: TextStyle(color: _IRC.slate, fontSize: 13),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _controller,
                    autofocus: true,
                    style: const TextStyle(
                        color: _IRC.ink, fontSize: 14.5),
                    decoration: InputDecoration(
                      hintText: 'Enter incident type...',
                      hintStyle: const TextStyle(color: _IRC.muted),
                      filled: true,
                      fillColor: _IRC.cardAlt,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _IRC.line),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _IRC.line),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: _IRC.primary),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 14),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text('Examples:',
                      style: TextStyle(
                          color: _IRC.slate,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _examples.map((ex) {
                      return GestureDetector(
                        onTap: () => _controller.text = ex,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: _IRC.cardAlt,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: _IRC.line),
                          ),
                          child: Text(
                            ex,
                            style: const TextStyle(
                                color: _IRC.ink,
                                fontSize: 12,
                                fontWeight: FontWeight.w500),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: widget.onClose,
                          style: OutlinedButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 12),
                            side: const BorderSide(color: _IRC.line),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            backgroundColor: _IRC.cardAlt,
                          ),
                          child: const Text('Cancel',
                              style: TextStyle(
                                  color: _IRC.ink,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _handleSave,
                          icon: const Icon(Icons.check_rounded,
                              color: Colors.white, size: 18),
                          label: const Text('Save Type',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _IRC.primary,
                            padding:
                                const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}