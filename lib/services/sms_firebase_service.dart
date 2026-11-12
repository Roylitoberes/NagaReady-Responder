// services/sms_firebase_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_sms_inbox/flutter_sms_inbox.dart';

class SmsFirebaseService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Maps an emergency SMS body to a short code used by the React app.
  /// React sends: MED, FIRE, CRIME, ACC, FLOOD, OTHER
  static String _detectCode(String message) {
    final text = message.toUpperCase();

    if (text.contains('[FIRE]') || text.contains('FIRE EMERGENCY')) {
      return 'FIRE';
    }
    if (text.contains('[MED]') ||
        text.contains('[MEDICAL]') ||
        text.contains('MEDICAL EMERGENCY')) {
      return 'MED';
    }
    if (text.contains('[ACC]') ||
        text.contains('[ACCIDENT]') ||
        text.contains('ACCIDENT')) {
      return 'ACC';
    }
    if (text.contains('[FLOOD]') || text.contains('FLOODING')) {
      return 'FLOOD';
    }
    if (text.contains('[CRIME]') ||
        text.contains('CRIME') ||
        text.contains('ROBBERY')) {
      return 'CRIME';
    }
    if (text.contains('[OTHER]')) {
      return 'OTHER';
    }
    return 'OTHER';
  }

  /// Extracts a human-readable location string from the SMS body.
  /// React format example:
  ///   📍 Location: Lat:14.123456,Long:121.123456
  ///   📍 Address: Some Street, Naga City
  ///   📍 Accuracy: ±10m
  static String _extractLocation(String message) {
    // 1. Prefer the human-readable address
    final addressMatch = RegExp(
      r'📍\s*Address:\s*([^\n\r]+)',
      caseSensitive: false,
    ).firstMatch(message);
    if (addressMatch != null) {
      final value = addressMatch.group(1)?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }

    // 2. Fall back to the coordinates line
    final coordsMatch = RegExp(
      r'📍\s*Location:\s*([^\n\r]+)',
      caseSensitive: false,
    ).firstMatch(message);
    if (coordsMatch != null) {
      final value = coordsMatch.group(1)?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }

    // 3. Legacy fallback
    final legacy = RegExp(
      r'(?:location|at)[:\s]+([^\n\r]+)',
      caseSensitive: false,
    ).firstMatch(message);
    return legacy?.group(1)?.trim() ?? 'Unknown location';
  }

  /// Extracts latitude and longitude from the React SMS format.
  /// Returns (0.0, 0.0) if not found.
  static (double, double) _extractCoords(String message) {
    final match = RegExp(
      r'Lat:\s*(-?\d+\.?\d*)\s*,\s*Long:\s*(-?\d+\.?\d*)',
      caseSensitive: false,
    ).firstMatch(message);

    if (match != null) {
      final lat = double.tryParse(match.group(1) ?? '') ?? 0.0;
      final lng = double.tryParse(match.group(2) ?? '') ?? 0.0;
      return (lat, lng);
    }
    return (0.0, 0.0);
  }

  /// Extracts the "specific type" for OTHER emergencies.
  /// React sends: "[OTHER] Landslide: ⚠️ EMERGENCY: ..."
  /// Returns null if not an OTHER message.
  static String? _extractOtherSpecificType(String message) {
    final match = RegExp(
      r'\[OTHER\]\s*([^:\n]+):',
      caseSensitive: false,
    ).firstMatch(message.toUpperCase());
    if (match != null) {
      final value = match.group(1)?.trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  /// Saves a single SMS to Firestore as an emergency message.
  /// Returns true if newly created, false if it already existed.
  static Future<bool> saveEmergencySms(SmsMessage sms) async {
    try {
      final timestamp = sms.date ?? DateTime.now();
      final sender = sms.address ?? 'Unknown';
      final body = sms.body ?? '';

      // Deterministic ID to prevent duplicates when re-reading SMS inbox
      final docId =
          '${timestamp.millisecondsSinceEpoch}_${sender.hashCode}_${body.hashCode}';

      final docRef = _firestore.collection('emergencyMessages').doc(docId);

      final existing = await docRef.get();
      if (existing.exists) {
        return false;
      }

      final code = _detectCode(body);
      final location = _extractLocation(body);
      final (lat, lng) = _extractCoords(body);
      final otherSpecific = _extractOtherSpecificType(body);

      final Map<String, dynamic> payload = {
        'citizenPhone': sender,
        'fullMessage': body,
        'message':
            body.length > 120 ? '${body.substring(0, 120)}...' : body,
        'code': code,
        'timestamp': Timestamp.fromDate(timestamp),
        'isRead': sms.read ?? false,
        'source': 'SMS',
        'location': {
          'address': location,
          'latitude': lat,
          'longitude': lng,
        },
        'createdAt': FieldValue.serverTimestamp(),
      };

      // ✅ Save the specific type when the React app used "Other"
      if (otherSpecific != null) {
        payload['specificType'] = otherSpecific;
      }

      await docRef.set(payload);

      debugPrint('✅ Saved SMS to Firestore: $code from $sender');
      return true;
    } catch (e, stack) {
      debugPrint('❌ Failed to save SMS to Firestore: $e');
      debugPrint('$stack');
      return false;
    }
  }

  /// Saves a batch of SMS messages. Returns the count of newly saved ones.
  static Future<int> saveEmergencySmsBatch(
      List<SmsMessage> messages) async {
    int savedCount = 0;

    for (final sms in messages) {
      final saved = await saveEmergencySms(sms);
      if (saved) savedCount++;
    }

    debugPrint('📤 Batch complete: $savedCount new SMS saved to Firestore');
    return savedCount;
  }

  // ============================================================
  // DELETE METHODS
  // ============================================================

  /// Deletes a single emergency message from Firestore by its document ID.
  /// Returns true on success.
  static Future<bool> deleteEmergencyMessage(String docId) async {
    try {
      await _firestore.collection('emergencyMessages').doc(docId).delete();
      debugPrint('🗑️ Deleted emergency message: $docId');
      return true;
    } catch (e, stack) {
      debugPrint('❌ Failed to delete emergency message: $e');
      debugPrint('$stack');
      return false;
    }
  }

  /// Deletes ALL documents in the emergencyMessages collection from Firestore.
  /// Uses batched writes to handle Firestore's 500-operation limit per batch.
  /// Returns the number of documents deleted.
  static Future<int> deleteAllEmergencyMessages() async {
    try {
      final snapshot =
          await _firestore.collection('emergencyMessages').get();

      if (snapshot.docs.isEmpty) {
        debugPrint('📭 No emergency messages to delete');
        return 0;
      }

      // Firestore batches are limited to 500 writes
      const int batchLimit = 500;
      int deletedCount = 0;

      for (int i = 0; i < snapshot.docs.length; i += batchLimit) {
        final batch = _firestore.batch();
        final end = (i + batchLimit < snapshot.docs.length)
            ? i + batchLimit
            : snapshot.docs.length;

        for (int j = i; j < end; j++) {
          batch.delete(snapshot.docs[j].reference);
        }

        await batch.commit();
        deletedCount += (end - i);
      }

      debugPrint('🗑️ Deleted $deletedCount emergency messages from Firestore');
      return deletedCount;
    } catch (e, stack) {
      debugPrint('❌ Failed to delete all emergency messages: $e');
      debugPrint('$stack');
      return 0;
    }
  }
}