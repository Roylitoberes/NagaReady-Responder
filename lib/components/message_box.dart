// lib/components/message_box.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';

// ✅ bring in MapPage + AssignedRoute + AssignedRouteStore
import 'map_page.dart';
import 'assigned_route_store.dart';

/// ============================================================
/// EOC MESSAGE BOX
/// Read-only inbox for messages sent by the EOC (Emergency
/// Operations Center) to this responder.
///
/// Firestore collection: `responder_messages`
/// Fields per doc:
///   - userId      : string   → responder's UID (recipient)
///   - from        : string   → sender name / EOC label
///   - subject     : string   → short title
///   - message     : string   → body
///   - priority    : string   → "normal" | "high" | "urgent"
///   - read        : bool     → whether responder has opened it
///   - createdAt   : timestamp
///   - routeData   : map      → OPTIONAL. Present only when the EOC sent
///                              a "Generate New Route" message.
///
/// ✅ NO COMPOSITE INDEX NEEDED:
///    We sort in Dart instead of using .orderBy() in the query.
/// ============================================================
class MessageBox extends StatefulWidget {
  /// ✅ Called when the responder taps "Navigate New Assigned Route".
  /// HomePage wires this to switch to the Map tab.
  final void Function({
    required LatLng location,
    required Map<String, dynamic> data,
    AssignedRoute? assignedRoute,
  })? onNavigateToAssignedRoute;

  const MessageBox({super.key, this.onNavigateToAssignedRoute});

  @override
  State<MessageBox> createState() => _MessageBoxState();
}

class _MessageBoxState extends State<MessageBox> {
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.80,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // ── Header ─────────────────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
              decoration: const BoxDecoration(
                color: Color(0xFF075E3B),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.mail_rounded,
                      color: Colors.white, size: 22),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'EOC Messages',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Messages from Emergency Operations Center',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 22),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // ── Messages list ──────────────────────────────────
            Expanded(
              child: user == null
                  ? const Center(child: Text('Not signed in'))
                  : StreamBuilder<QuerySnapshot>(
                      // ✅ ONLY .where() — NO .orderBy()
                      //    → no composite index required
                      stream: FirebaseFirestore.instance
                          .collection('responder_messages')
                          .where('userId', isEqualTo: user.uid)
                          .snapshots(),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState ==
                            ConnectionState.waiting) {
                          return const Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFF075E3B),
                            ),
                          );
                        }

                        if (snapshot.hasError) {
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Text(
                                'Error: ${snapshot.error}',
                                style: const TextStyle(
                                    color: Color(0xFFDC2626)),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          );
                        }

                        // ✅ Sort newest-first IN DART (no index needed)
                        final docs = List<QueryDocumentSnapshot>.from(
                          snapshot.data?.docs ?? [],
                        );

                        docs.sort((a, b) {
                          final ad = a.data() as Map<String, dynamic>;
                          final bd = b.data() as Map<String, dynamic>;
                          final at = ad['createdAt'];
                          final bt = bd['createdAt'];
                          final adt =
                              at is Timestamp ? at.toDate() : null;
                          final bdt =
                              bt is Timestamp ? bt.toDate() : null;
                          if (adt == null && bdt == null) return 0;
                          if (adt == null) return 1;
                          if (bdt == null) return -1;
                          return bdt.compareTo(adt); // newest first
                        });

                        if (docs.isEmpty) {
                          return const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.mark_email_read_outlined,
                                    size: 56, color: Color(0xFF94A3B8)),
                                SizedBox(height: 10),
                                Text(
                                  'No messages from EOC',
                                  style: TextStyle(
                                    color: Color(0xFF64748B),
                                    fontSize: 15,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  'Updates and advisories will appear here',
                                  style: TextStyle(
                                    color: Color(0xFF94A3B8),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          );
                        }

                        return ListView.builder(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          itemCount: docs.length,
                          itemBuilder: (context, index) {
                            final doc = docs[index];
                            final data =
                                doc.data() as Map<String, dynamic>;
                            return _buildMessageCard(
                              context,
                              docId: doc.id,
                              data: data,
                            );
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Single message card ────────────────────────────────────
  Widget _buildMessageCard(
    BuildContext context, {
    required String docId,
    required Map<String, dynamic> data,
  }) {
    final from = (data['from'] ?? 'EOC').toString();
    
    // ✅ FIX: Clean up raw SMS data in subject
    String subject = (data['subject'] ?? '').toString();
    if (subject.contains('SMS-')) {
      // Removes "- SMS-+639... " and leaves just the incident name
      subject = subject.replaceAll(RegExp(r'-\s*SMS-[^\s]+'), '').trim();
      // Removes trailing parentheses if they got left behind
      if (subject.endsWith('(')) {
        subject = subject.substring(0, subject.length - 1).trim();
      }
    }
    if (subject.isEmpty) subject = 'Incident Update';

    // ✅ FIX: Clean up message body if it's just the raw SMS string
    String message = (data['message'] ?? '').toString();
    if (message.startsWith('SMS-') || message.contains('SMS-+63')) {
      message = 'A new route has been assigned to you. Please check the details below and navigate to the location.';
    }

    final priority =
        (data['priority'] ?? 'normal').toString().toLowerCase();
    final isRead = data['read'] == true;

    // Priority colour
    Color priorityColor;
    IconData priorityIcon;
    String priorityLabel;
    switch (priority) {
      case 'urgent':
        priorityColor = const Color(0xFFDC2626);
        priorityIcon = Icons.priority_high_rounded;
        priorityLabel = 'URGENT';
        break;
      case 'high':
        priorityColor = const Color(0xFFF59E0B);
        priorityIcon = Icons.arrow_upward_rounded;
        priorityLabel = 'HIGH';
        break;
      default:
        priorityColor = const Color(0xFF2563EB);
        priorityIcon = Icons.info_outline_rounded;
        priorityLabel = 'NORMAL';
    }

    // Time string
    String time = '';
    final ts = data['createdAt'];
    if (ts is Timestamp) {
      final d = ts.toDate();
      final now = DateTime.now();
      final diff = now.difference(d);
      if (diff.inMinutes < 1) {
        time = 'Just now';
      } else if (diff.inMinutes < 60) {
        time = '${diff.inMinutes}m ago';
      } else if (diff.inHours < 24) {
        time = '${diff.inHours}h ago';
      } else if (diff.inDays < 7) {
        time = '${diff.inDays}d ago';
      } else {
        time =
            '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      }
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openMessageDetail(
          context,
          docId: docId,
          data: data,
          priorityColor: priorityColor,
          priorityLabel: priorityLabel,
          time: time,
        ),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isRead ? Colors.white : const Color(0xFFF0FDF4),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isRead
                  ? const Color(0xFFE2E8F0)
                  : const Color(0xFFBBF7D0),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top row: priority chip + time
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: priorityColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(priorityIcon,
                            size: 11, color: priorityColor),
                        const SizedBox(width: 3),
                        Text(
                          priorityLabel,
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            color: priorityColor,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    time,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF94A3B8),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Sender + unread dot
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: const Color(0xFF075E3B)
                          .withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.campaign_rounded,
                      size: 18,
                      color: Color(0xFF075E3B),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      from,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF075E3B),
                      ),
                      overflow: TextOverflow.ellipsis,
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
              const SizedBox(height: 8),

              // Subject
              if (subject.isNotEmpty)
                Text(
                  subject,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight:
                        isRead ? FontWeight.w600 : FontWeight.w800,
                    color: const Color(0xFF0F172A),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              if (subject.isNotEmpty) const SizedBox(height: 4),

              // Body preview
              Text(
                message,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: Color(0xFF64748B),
                  height: 1.35,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),

              // ✅ route card + Navigate button
              _buildRouteAttachment(data, context),
            ],
          ),
        ),
      ),
    );
  }

  // ── Detail view (bottom sheet on top of bottom sheet) ─────
  void _openMessageDetail(
    BuildContext context, {
    required String docId,
    required Map<String, dynamic> data,
    required Color priorityColor,
    required String priorityLabel,
    required String time,
  }) {
    // Mark as read (only once)
    if (data['read'] != true) {
      FirebaseFirestore.instance
          .collection('responder_messages')
          .doc(docId)
          .update({'read': true}).catchError((e) {
        debugPrint('⚠️ Failed to mark message as read: $e');
      });
    }

    final from = (data['from'] ?? 'EOC').toString();
    
    // ✅ FIX: Clean up subject for detail view as well
    String subject = (data['subject'] ?? 'No subject').toString();
    if (subject.contains('SMS-')) {
      subject = subject.replaceAll(RegExp(r'-\s*SMS-[^\s]+'), '').trim();
      if (subject.endsWith('(')) {
        subject = subject.substring(0, subject.length - 1).trim();
      }
    }
    if (subject.isEmpty) subject = 'Incident Update';

    // ✅ FIX: Clean up message for detail view as well
    String message = (data['message'] ?? '').toString();
    if (message.startsWith('SMS-') || message.contains('SMS-+63')) {
      message = 'A new route has been assigned to you. Please check the details below and navigate to the location.';
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        height: MediaQuery.of(ctx).size.height * 0.72,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
              decoration: const BoxDecoration(
                color: Color(0xFF075E3B),
                borderRadius:
                    BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.mail_rounded,
                      color: Colors.white, size: 22),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Message Details',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 22),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
            ),

            // Body
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Priority + time
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: priorityColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            priorityLabel,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: priorityColor,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          time,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // From
                    Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: const Color(0xFF075E3B)
                                .withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.campaign_rounded,
                            size: 20,
                            color: Color(0xFF075E3B),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                from,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: Color(0xFF075E3B),
                                ),
                              ),
                              const Text(
                                'Emergency Operations Center',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF94A3B8),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // Subject
                    Text(
                      subject,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Divider
                    Container(
                      height: 1,
                      color: const Color(0xFFE2E8F0),
                    ),
                    const SizedBox(height: 16),

                    // Body
                    Text(
                      message,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFF334155),
                        height: 1.55,
                      ),
                    ),

                    // ✅ route attachment in detail view too
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: _buildRouteAttachment(data, ctx),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // ✅ Renders the route card + "Navigate New Assigned Route"
  // ============================================================
  Widget _buildRouteAttachment(
    Map<String, dynamic> data,
    BuildContext context,
  ) {
    final route = data['routeData'];
    if (route is! Map) return const SizedBox.shrink();

    final distanceMeters = (route['distanceMeters'] is num)
        ? (route['distanceMeters'] as num).toDouble()
        : 0.0;
    final durationSeconds = (route['durationSeconds'] is num)
        ? (route['durationSeconds'] as num).toInt()
        : 0;

    // ✅ incident details attached to the route
    String incidentType = (route['incidentType'] ?? '').toString();
    String incidentTitle = (route['incidentTitle'] ?? '').toString();
    String incidentId = (route['incidentId'] ?? '').toString();
    final incidentLocation = (route['incidentLocation'] ?? '').toString();
    final incidentDate = (route['incidentDate'] ?? '').toString();
    final incidentTime = (route['incidentTime'] ?? '').toString();
    final reporterName = (route['reporterName'] ?? '').toString();
    final reporterPhone = (route['reporterPhone'] ?? '').toString();

    // ✅ FIX: Clean up incident strings if they contain the raw SMS ID
    if (incidentTitle.contains('SMS-')) {
      incidentTitle = incidentTitle.replaceAll(RegExp(r'-\s*SMS-[^\s]+'), '').trim();
    }
    if (incidentId.contains('SMS-')) {
      incidentId = incidentId.replaceAll(RegExp(r'SMS-[^\s]+'), '').trim();
    }
    // If the title was just the SMS string (or left empty), fall back to the incident type
    if (incidentTitle.isEmpty || incidentTitle.startsWith('SMS-')) {
      incidentTitle = incidentType.isNotEmpty ? incidentType.toUpperCase() : 'Incident';
    }

    final km = distanceMeters / 1000.0;
    final distanceText = km < 1
        ? '${(km * 1000).round()} m'
        : '${km.toStringAsFixed(1)} km';
    final etaMin = (durationSeconds / 60).ceil().clamp(1, 9999);

    final stepsRaw = route['steps'];
    final List<String> steps = [];
    if (stepsRaw is List) {
      for (final s in stepsRaw) {
        if (s is Map && s['instruction'] != null) {
          steps.add(s['instruction'].toString());
        }
      }
    }

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.route_rounded,
                  size: 16, color: Color(0xFF1E40AF)),
              const SizedBox(width: 6),
              const Text(
                'New Route Attached',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1E40AF),
                ),
              ),
            ],
          ),

          // ✅ Incident type + title line
          if (incidentType.isNotEmpty || incidentTitle.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFECACA)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.local_fire_department_rounded,
                      size: 15, color: Color(0xFFDC2626)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          incidentTitle,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (incidentType.isNotEmpty)
                          Text(
                            incidentType.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFDC2626),
                              letterSpacing: 0.4,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (incidentId.isNotEmpty)
                    Text(
                      '#$incidentId',
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF64748B),
                      ),
                    ),
                ],
              ),
            ),
          ],

          // ✅ location / reporter / contact / date
          if (incidentLocation.isNotEmpty ||
              reporterName.isNotEmpty ||
              reporterPhone.isNotEmpty ||
              incidentDate.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFBFDBFE)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (incidentLocation.isNotEmpty)
                    _routeDetailRow(
                      Icons.location_on_rounded,
                      incidentLocation,
                      const Color(0xFFDC2626),
                    ),
                  if (reporterName.isNotEmpty)
                    _routeDetailRow(
                      Icons.person_outline_rounded,
                      'Reporter: $reporterName',
                      const Color(0xFF0B6B43),
                    ),
                  if (reporterPhone.isNotEmpty)
                    _routeDetailRow(
                      Icons.phone_outlined,
                      'Contact: $reporterPhone',
                      const Color(0xFFF59E0B),
                    ),
                  if (incidentDate.isNotEmpty || incidentTime.isNotEmpty)
                    _routeDetailRow(
                      Icons.schedule_rounded,
                      '$incidentDate${incidentDate.isNotEmpty && incidentTime.isNotEmpty ? " • " : ""}$incidentTime',
                      const Color(0xFF64748B),
                    ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _routeChip(
                  Icons.straighten_rounded,
                  distanceText,
                  'Distance',
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _routeChip(
                  Icons.schedule_rounded,
                  '$etaMin min',
                  'ETA',
                ),
              ),
            ],
          ),
          if (steps.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'Directions',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1E40AF),
              ),
            ),
            const SizedBox(height: 4),
            ...steps.take(10).toList().asMap().entries.map(
              (e) => Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${e.key + 1}. ',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF1E40AF),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        e.value,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF1E3A8A),
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],

          // ✅ "Navigate New Assigned Route" button
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 42,
            child: ElevatedButton.icon(
              onPressed: () => _navigateNewAssignedRoute(context, data),
              icon: const Icon(Icons.navigation_rounded, size: 18),
              label: const Text(
                'Navigate New Assigned Route',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0B6B43),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _routeDetailRow(IconData icon, String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF334155),
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _routeChip(IconData icon, String value, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: const Color(0xFF2563EB)),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF1E3A8A),
                ),
              ),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF64748B),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ============================================================
  // ✅ Parse routeData → switch HomePage to the Map tab with the
  //    EOC-assigned route (instead of pushing a new MapPage).
  // ============================================================
  Future<void> _navigateNewAssignedRoute(
    BuildContext context,
    Map<String, dynamic> data,
  ) async {
    final route = data['routeData'];
    final parsed = AssignedRoute.fromRouteData(route);

    if (parsed == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ This message has no navigable route data.'),
          backgroundColor: Color(0xFFDC2626),
        ),
      );
      return;
    }

    // Persist the assigned route so a fresh MapPage can restore it.
    await AssignedRouteStore.save(parsed);

    if (!context.mounted) return;

    // ✅ Close every open bottom sheet (message detail + message box).
    final navigator = Navigator.of(context, rootNavigator: true);
    navigator.popUntil((r) => r.isFirst);

    // ✅ Build incidentData from the assigned route.
    final Map<String, dynamic> incidentData = <String, dynamic>{
      'incidentId': parsed.incidentId,
    };

    if (parsed.incidentType.isNotEmpty) {
      incidentData['type'] = parsed.incidentType;
    }
    if (parsed.incidentTitle.isNotEmpty) {
      incidentData['title'] = parsed.incidentTitle;
    }
    if (parsed.incidentLocation.isNotEmpty) {
      incidentData['location'] = parsed.incidentLocation;
    }
    if (parsed.incidentDate.isNotEmpty) {
      incidentData['date'] = parsed.incidentDate;
    }
    if (parsed.incidentTime.isNotEmpty) {
      incidentData['time'] = parsed.incidentTime;
    }
    if (parsed.incidentDescription.isNotEmpty) {
      incidentData['description'] = parsed.incidentDescription;
    }
    if (parsed.incidentSeverity.isNotEmpty) {
      incidentData['severity'] = parsed.incidentSeverity;
    }
    if (parsed.reporterName.isNotEmpty) {
      incidentData['reporterName'] = parsed.reporterName;
    }
    if (parsed.reporterPhone.isNotEmpty) {
      incidentData['reporterPhone'] = parsed.reporterPhone;
    }
    if (parsed.casualties.isNotEmpty) {
      incidentData['casualties'] = parsed.casualties;
    }
    if (parsed.points.isNotEmpty) {
      incidentData['lat'] = parsed.points.last.latitude;
      incidentData['lng'] = parsed.points.last.longitude;
    }

    // ✅ Tell HomePage to switch to the Map tab with this EOC route.
    widget.onNavigateToAssignedRoute?.call(
      location: parsed.points.isNotEmpty
          ? parsed.points.last
          : const LatLng(13.6248, 123.1862),
      data: incidentData,
      assignedRoute: parsed,
    );
  }
}