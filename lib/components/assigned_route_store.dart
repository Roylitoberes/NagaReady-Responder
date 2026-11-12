// lib/components/assigned_route_store.dart
// ✅ Persistent storage for the EOC-assigned route so a fresh MapPage
//    can restore it even if the parent forgets to pass `assignedRoute`.

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'map_page.dart' show AssignedRoute;

class AssignedRouteStore {
  static const String _kKey = 'eoc_assigned_route';

  /// Save the EOC-assigned route to disk.
  static Future<void> save(AssignedRoute route) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        'incidentId': route.incidentId,
        'distanceMeters': route.distanceMeters,
        'durationSeconds': route.durationSeconds,
        // Store under "geometry" so AssignedRoute.fromRouteData() can parse it.
        'geometry': route.points
            .map((p) => {'lat': p.latitude, 'lng': p.longitude})
            .toList(),
        'steps': route.steps,
        'avoidedLocation': route.avoidedLocation,
        'savedAt': DateTime.now().millisecondsSinceEpoch,
      };
      await prefs.setString(_kKey, jsonEncode(payload));
    } catch (_) {
      // Silent — persistence is best-effort.
    }
  }

  /// Load a previously saved EOC-assigned route.
  static Future<AssignedRoute?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return AssignedRoute.fromRouteData(map);
    } catch (_) {
      return null;
    }
  }

  /// Remove the saved route (call when the mission is complete).
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kKey);
    } catch (_) {
      // Silent.
    }
  }
}