import 'package:flutter/material.dart';

class StatusUpdateBottomSheet extends StatefulWidget {
  final Function(String)? onStatusSelected;

  const StatusUpdateBottomSheet({
    super.key,
    this.onStatusSelected,
  });

  @override
  State<StatusUpdateBottomSheet> createState() => _StatusUpdateBottomSheetState();
}

class _StatusUpdateBottomSheetState extends State<StatusUpdateBottomSheet> {
  String _selectedStatus = 'En Route';

  final List<Map<String, dynamic>> _statuses = [
    {
      'id': 'En Route',
      'label': 'En Route',
      'icon': Icons.directions_car_rounded,
      'iconColor': const Color(0xFFF59E0B),
      'description': 'Responding to incident location',
    },
    {
      'id': 'Arrived On Scene',
      'label': 'Arrived On Scene',
      'icon': Icons.location_on_rounded,
      'iconColor': const Color(0xFFF97316),
      'description': 'On site at incident location',
    },
    {
      'id': 'Transporting Patient',
      'label': 'Transporting Patient',
      'icon': Icons.local_hospital_rounded,
      'iconColor': const Color(0xFF3B82F6),
      'description': 'Transporting patient to hospital',
    },
    {
      'id': 'Incident Resolved',
      'label': 'Incident Resolved',
      'icon': Icons.check_circle_rounded,
      'iconColor': const Color(0xFF22C55E),
      'description': 'Incident has been resolved',
    },
  ];

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final scale = screenWidth / 390;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag Handle
          Container(
            margin: EdgeInsets.only(top: 12 * scale),
            width: 40 * scale,
            height: 4 * scale,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2 * scale),
            ),
          ),
          // Header
          _buildHeader(scale),
          // Status List
          _buildStatusList(scale),
          // Update Button - With much larger height
          _buildUpdateButton(scale),
          // Extra bottom padding for safe area
          SizedBox(height: 30 * scale),
        ],
      ),
    );
  }

  Widget _buildHeader(double scale) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20 * scale, 16 * scale, 16 * scale, 12 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Icon
          Container(
            width: 56 * scale,
            height: 56 * scale,
            decoration: BoxDecoration(
              color: const Color(0xFF0B6B43).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(16 * scale),
            ),
            child: const Icon(
              Icons.check_circle_rounded,
              color: Color(0xFF0B6B43),
              size: 32,
            ),
          ),
          SizedBox(width: 14 * scale),
          // Title and Subtitle
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Dispatch Accepted',
                  style: TextStyle(
                    fontSize: 20 * scale,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF0F172A),
                    letterSpacing: -0.3,
                  ),
                ),
                SizedBox(height: 4 * scale),
                Text(
                  'You have been assigned to this incident.',
                  style: TextStyle(
                    fontSize: 14 * scale,
                    color: const Color(0xFF64748B),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          // Close Button
          IconButton(
            onPressed: () => Navigator.pop(context),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Container(
              width: 32 * scale,
              height: 32 * scale,
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8 * scale),
              ),
              child: Icon(
                Icons.close_rounded,
                size: 20 * scale,
                color: Colors.grey.shade600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusList(double scale) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20 * scale),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section Title
          Padding(
            padding: EdgeInsets.only(bottom: 12 * scale),
            child: Text(
              'Update Status',
              style: TextStyle(
                fontSize: 16 * scale,
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
                letterSpacing: -0.2,
              ),
            ),
          ),
          // Status Items
          ..._statuses.map((status) {
            final isSelected = _selectedStatus == status['id'];
            return Padding(
              padding: EdgeInsets.only(bottom: 8 * scale),
              child: _buildStatusItem(
                status: status,
                isSelected: isSelected,
                scale: scale,
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildStatusItem({
    required Map<String, dynamic> status,
    required bool isSelected,
    required double scale,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          setState(() {
            _selectedStatus = status['id'] as String;
          });
        },
        borderRadius: BorderRadius.circular(14 * scale),
        child: Container(
          padding: EdgeInsets.all(14 * scale),
          decoration: BoxDecoration(
            color: isSelected 
                ? const Color(0xFF0B6B43).withValues(alpha: 0.05)
                : Colors.white,
            borderRadius: BorderRadius.circular(14 * scale),
            border: Border.all(
              color: isSelected 
                  ? const Color(0xFF0B6B43).withValues(alpha: 0.3)
                  : Colors.grey.shade200,
              width: isSelected ? 2 : 1,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: const Color(0xFF0B6B43).withValues(alpha: 0.08),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            children: [
              // Icon Container
              Container(
                width: 44 * scale,
                height: 44 * scale,
                decoration: BoxDecoration(
                  color: (status['iconColor'] as Color).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12 * scale),
                ),
                child: Icon(
                  status['icon'],
                  color: status['iconColor'],
                  size: 24 * scale,
                ),
              ),
              SizedBox(width: 12 * scale),
              // Label and Description
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status['label'],
                      style: TextStyle(
                        fontSize: 15 * scale,
                        fontWeight: isSelected ? FontWeight.w700 : FontWeight.w600,
                        color: isSelected 
                            ? const Color(0xFF0B6B43)
                            : const Color(0xFF0F172A),
                      ),
                    ),
                    SizedBox(height: 2 * scale),
                    Text(
                      status['description'],
                      style: TextStyle(
                        fontSize: 12 * scale,
                        color: const Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ),
              // Radio/Check Indicator
              Container(
                width: 24 * scale,
                height: 24 * scale,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isSelected 
                      ? const Color(0xFF0B6B43)
                      : Colors.transparent,
                  border: Border.all(
                    color: isSelected 
                        ? const Color(0xFF0B6B43)
                        : Colors.grey.shade400,
                    width: isSelected ? 0 : 2,
                  ),
                ),
                child: isSelected
                    ? Icon(
                        Icons.check_rounded,
                        size: 16 * scale,
                        color: Colors.white,
                      )
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUpdateButton(double scale) {
    return Padding(
      padding: EdgeInsets.fromLTRB(20 * scale, 24 * scale, 20 * scale, 0),
      child: SizedBox(
        width: double.infinity,
        height: 80 * scale, // ✅ Increased from 68 to 80 - much larger and easier to tap
        child: ElevatedButton(
          onPressed: () {
            if (widget.onStatusSelected != null) {
              widget.onStatusSelected!(_selectedStatus);
            }
            Navigator.pop(context, _selectedStatus);
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF0B6B43),
            foregroundColor: Colors.white,
            elevation: 6, // ✅ Increased elevation for better visibility
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18 * scale), // ✅ Increased from 16 to 18
            ),
          ),
          child: Text(
            'Update Status',
            style: TextStyle(
              fontSize: 20 * scale, // ✅ Increased from 18 to 20
              fontWeight: FontWeight.w700,
              color: Colors.white,
              letterSpacing: 1.0, // ✅ Increased for better readability
            ),
          ),
        ),
      ),
    );
  }
}

// Helper function to show the bottom sheet
Future<String?> showStatusUpdateBottomSheet(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => const StatusUpdateBottomSheet(),
  );
}