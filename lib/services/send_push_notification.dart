// lib/services/send_push_notification.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

Future<void> sendPushToUser({
  required String userId,
  required String title,
  required String body,
  Map<String, dynamic> data = const {},
}) async {
  try {
    final tokenDoc = await FirebaseFirestore.instance
        .collection('user_push_tokens')
        .doc(userId)
        .get();

    if (!tokenDoc.exists) {
      debugPrint('No push token for user: $userId');
      return;
    }

    final token = tokenDoc.data()?['token'] as String?;
    if (token == null || token.isEmpty) return;

    final response = await http.post(
      Uri.parse('https://exp.host/--/api/v2/push/send'),
      headers: {
        'Accept': 'application/json',
        'Accept-Encoding': 'gzip, deflate',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'to': token,
        'sound': 'default',
        'title': title,
        'body': body,
        'data': data,
        'priority': 'high',
        'channelId': 'default',
      }),
    );

    debugPrint('Push sent: ${response.body}');
  } catch (e) {
    debugPrint('sendPushToUser error: $e');
  }
}