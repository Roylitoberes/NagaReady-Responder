// profile_page.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// ---------------------------------------------------------------------------
// Design tokens
// ---------------------------------------------------------------------------
class _C {
  static const brand = Color(0xFF075E3B);
  static const brandTint = Color(0xFFE6F4EC);

  static const ink = Color(0xFF0F172A);
  static const body = Color(0xFF475569);
  static const muted = Color(0xFF94A3B8);
  static const line = Color(0xFFE8EDF2);
  static const surface = Colors.white;
  static const tile = Color(0xFFF1F5F9);

  static const danger = Color(0xFFDC2626);
  static const dangerTint = Color(0xFFFEF2F2);
  static const dangerLine = Color(0xFFFECACA);

}

class ProfilePage extends StatefulWidget {
  // Optional — pass userData + user from HomePage so we don't re-fetch.
  final Map<String, dynamic>? userData;
  final User? user;

  const ProfilePage({
    super.key,
    this.userData,
    this.user,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late Map<String, dynamic> _userData;
  late User _user;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _user = widget.user ?? FirebaseAuth.instance.currentUser!;
    _userData = widget.userData ?? {};

    if (_userData.isEmpty) {
      _fetchUserData();
    } else {
      _isLoading = false;
    }
  }

  // ✅ When HomePage's live data changes (e.g. the admin approved a profile
  //    update in Manage Users), refresh what this page shows.
  @override
  void didUpdateWidget(covariant ProfilePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.userData;
    if (incoming != null &&
        incoming.isNotEmpty &&
        incoming != oldWidget.userData) {
      _userData = incoming;
      _isLoading = false;
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
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error fetching user data: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  // ---------------- Masking helpers ----------------

  // admin -> admi•••
  String _maskText(String value) {
    final v = value.trim();
    if (v.isEmpty) return v;
    final visible = v.length > 4 ? 4 : 1;
    final hidden = (v.length - visible) < 3 ? 3 : v.length - visible;
    return '${v.substring(0, visible)}${'•' * hidden}';
  }

  // admin@gmail.com -> admi•••@gmail.com
  String _maskEmail(String email) {
    if (!email.contains('@')) return email;
    final parts = email.split('@');
    return '${_maskText(parts.first)}@${parts.sublist(1).join('@')}';
  }

  Future<void> _handleLogout() async {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
        contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
        actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(
                color: _C.dangerTint,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.logout_rounded,
                color: _C.danger,
                size: 26,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Logout',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: _C.ink,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Are you sure you want to logout?',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: _C.body,
                height: 1.45,
              ),
            ),
          ],
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _C.body,
                    side: const BorderSide(color: _C.line, width: 1.5),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Cancel',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () async {
                    Navigator.pop(dialogContext);
                    await FirebaseAuth.instance.signOut();
                    if (mounted) {
                      // ignore: use_build_context_synchronously
                      Navigator.pushReplacementNamed(context, '/login');
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _C.danger,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Logout',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth;
          final scale = (availableWidth / 390).clamp(0.85, 1.25).toDouble();

          if (_isLoading) {
            return const Center(
              child: CircularProgressIndicator(
                color: _C.brand,
              ),
            );
          }

          // ---------- Basic fields ----------
          final name = _userData['name'] ?? 'Responder';
          final firstName = _userData['firstName'] ?? '';
          final lastName = _userData['lastName'] ?? '';
          final role = _userData['role'] ?? _userData['type'] ?? 'Responder';
          final email = _userData['email'] ?? _user.email ?? 'No email';

          // ---------- Contact ----------
          final phone = _userData['phone'] ??
              _userData['phoneNumber'] ??
              _userData['contact'] ??
              '';

          // ---------- Responder info ----------
          final responderId = _userData['responderId'] ?? '';
          final agency = _userData['agency'] ?? '';
          final team = _userData['team'] ?? '';
          final resourceName = _userData['resourceName'] ?? '';
          final resourceType = _userData['resourceType'] ?? '';
          final gender = _userData['gender'] ?? '';
          final age = _userData['age']?.toString() ?? '';
          // Single / Married (saved by Manage Users as `civilStatus`)
          final civilStatus = (_userData['civilStatus'] ?? '').toString();
          final specialization = _userData['specialization'] ?? '';
          final certification = _userData['certification'] ?? '';
          final capabilities = _userData['capabilities'] ?? '';

          // ---------- Operational ----------
          final vehicleUnit = _userData['vehicleUnit'] ?? '';
          final vehicleType = _userData['vehicleType'] ?? '';
          final plateNumber = _userData['plateNumber'] ?? '';

          // ---------- Legacy fallbacks ----------
          final department = _userData['department'] ??
              _userData['station'] ??
              agency ??
              'Naga City';
          final unitName = _userData['unitName'] ?? '';
          final unitCode = _userData['unitCode'] ?? '';
          final badgeNumber = _userData['badgeNumber'] ?? '';

          return SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              16 * scale,
              12 * scale,
              16 * scale,
              28 * scale,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ---------- Personal Information ----------
                _sectionTitle(
                  icon: Icons.person_outline_rounded,
                  title: 'Personal Information',
                  scale: scale,
                ),
                SizedBox(height: 10 * scale),

                _card(
                  scale: scale,
                  rows: [
                    if (firstName.isNotEmpty)
                      _infoRow(
                        icon: Icons.person_outline_rounded,
                        label: 'First Name',
                        value: firstName,
                        scale: scale,
                      ),
                    if (lastName.isNotEmpty)
                      _infoRow(
                        icon: Icons.person_outline_rounded,
                        label: 'Last Name',
                        value: lastName,
                        scale: scale,
                      ),
                    _infoRow(
                      icon: Icons.badge_outlined,
                      label: 'Full Name',
                      value: name,
                      scale: scale,
                    ),
                    _infoRow(
                      icon: Icons.email_outlined,
                      label: 'Email',
                      value: _maskEmail(email.toString()),
                      scale: scale,
                    ),
                    if (phone.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.phone_outlined,
                        label: 'Phone',
                        value: phone,
                        scale: scale,
                      ),
                    if (gender.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.wc_outlined,
                        label: 'Gender',
                        value: gender,
                        scale: scale,
                      ),
                    if (age.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.cake_outlined,
                        label: 'Age',
                        value: age,
                        scale: scale,
                      ),
                    if (civilStatus.isNotEmpty)
                      _infoRow(
                        icon: Icons.favorite_border_rounded,
                        label: 'Status',
                        value: civilStatus,
                        scale: scale,
                      ),
                  ],
                ),

                SizedBox(height: 24 * scale),

                // ---------- Responder Information ----------
                _sectionTitle(
                  icon: Icons.work_outline_rounded,
                  title: 'Responder Information',
                  scale: scale,
                ),
                SizedBox(height: 10 * scale),

                _card(
                  scale: scale,
                  rows: [
                    if (responderId.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.tag_outlined,
                        label: 'Responder ID',
                        value: responderId,
                        scale: scale,
                      ),
                    _infoRow(
                      icon: Icons.shield_outlined,
                      label: 'Role / Position',
                      value: role,
                      scale: scale,
                    ),
                    if (agency.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.apartment_outlined,
                        label: 'Agency / Office / Home Base',
                        value: agency,
                        scale: scale,
                      ),
                    if (team.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.groups_outlined,
                        label: 'Team / Unit',
                        value: team,
                        scale: scale,
                      ),
                    if (badgeNumber.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.credit_card_outlined,
                        label: 'Badge / Employee ID',
                        value: badgeNumber,
                        scale: scale,
                      ),
                    if (department.toString().isNotEmpty &&
                        department.toString() != agency.toString())
                      _infoRow(
                        icon: Icons.location_city_outlined,
                        label: 'Department / Location',
                        value: department,
                        scale: scale,
                      ),
                    if (resourceName.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.inventory_2_outlined,
                        label: 'Resource / Unit Name',
                        value: resourceName,
                        scale: scale,
                      ),
                    if (resourceType.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.category_outlined,
                        label: 'Resource Type',
                        value: resourceType,
                        scale: scale,
                      ),
                    if (specialization.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.workspace_premium_outlined,
                        label: 'Specialization / Skills',
                        value: specialization,
                        scale: scale,
                      ),
                    if (certification.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.verified_outlined,
                        label: 'Certification',
                        value: certification,
                        scale: scale,
                      ),
                    // Legacy unit fields (only if present)
                    if (unitName.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.local_shipping_outlined,
                        label: 'Assigned Unit',
                        value: unitCode.toString().isNotEmpty
                            ? '$unitName ($unitCode)'
                            : unitName,
                        scale: scale,
                      ),
                  ],
                ),

                SizedBox(height: 24 * scale),

                // ---------- Emergency / Operational Information ----------
                _sectionTitle(
                  icon: Icons.emergency_outlined,
                  title: 'Emergency / Operational Information',
                  scale: scale,
                ),
                SizedBox(height: 10 * scale),

                _card(
                  scale: scale,
                  rows: [
                    if (capabilities.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.bolt_outlined,
                        label: 'Capabilities',
                        value: capabilities,
                        scale: scale,
                      ),
                    if (vehicleUnit.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.directions_car_outlined,
                        label: 'Vehicle / Unit',
                        value: vehicleUnit,
                        scale: scale,
                      ),
                    if (vehicleType.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.local_taxi_outlined,
                        label: 'Vehicle Type',
                        value: vehicleType,
                        scale: scale,
                      ),
                    if (plateNumber.toString().isNotEmpty)
                      _infoRow(
                        icon: Icons.pin_outlined,
                        label: 'Plate Number',
                        value: plateNumber,
                        scale: scale,
                      ),
                    if (capabilities.toString().isEmpty &&
                        vehicleUnit.toString().isEmpty &&
                        vehicleType.toString().isEmpty &&
                        plateNumber.toString().isEmpty)
                      _infoRow(
                        icon: Icons.info_outline,
                        label: 'Operational Details',
                        value: 'No operational information on file',
                        scale: scale,
                      ),
                  ],
                ),

                SizedBox(height: 24 * scale),

                // ---------- Account ----------
                _sectionTitle(
                  icon: Icons.security_rounded,
                  title: 'Account',
                  scale: scale,
                ),
                SizedBox(height: 10 * scale),

                _card(
                  scale: scale,
                  rows: [
                    _infoRow(
                      icon: Icons.fingerprint_rounded,
                      label: 'User ID',
                      value: _user.uid,
                      scale: scale,
                    ),
                  ],
                ),

                SizedBox(height: 28 * scale),

                // ---------- Logout Button ----------
                SizedBox(
                  width: double.infinity,
                  height: 52 * scale,
                  child: OutlinedButton.icon(
                    onPressed: _handleLogout,
                    icon: Icon(
                      Icons.logout_rounded,
                      size: 20 * scale,
                    ),
                    label: Text(
                      'Logout',
                      style: TextStyle(
                        fontSize: 15 * scale,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _C.danger,
                      backgroundColor: _C.dangerTint,
                      side: const BorderSide(color: _C.dangerLine),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14 * scale),
                      ),
                    ),
                  ),
                ),

                SizedBox(height: 8 * scale),
              ],
            ),
          );
        },
      ),
    );
  }

  // ---------------- Helpers ----------------

  Widget _sectionTitle({
    required IconData icon,
    required String title,
    required double scale,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 4 * scale),
      child: Row(
        children: [
          Container(
            width: 30 * scale,
            height: 30 * scale,
            decoration: BoxDecoration(
              color: _C.brandTint,
              borderRadius: BorderRadius.circular(9 * scale),
            ),
            child: Icon(
              icon,
              color: _C.brand,
              size: 16 * scale,
            ),
          ),
          SizedBox(width: 10 * scale),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 15.5 * scale,
                fontWeight: FontWeight.w800,
                color: _C.ink,
                letterSpacing: -0.1,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }

  /// White rounded card that lays out [rows] with dividers between them.
  Widget _card({
    required double scale,
    required List<Widget> rows,
  }) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      children.add(rows[i]);
      if (i != rows.length - 1) children.add(_divider(scale));
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _C.surface,
        borderRadius: BorderRadius.circular(18 * scale),
        border: Border.all(color: _C.line),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF0F172A).withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  Widget _divider(double scale) {
    return Divider(
      height: 1,
      thickness: 1,
      color: const Color(0xFFF1F5F9),
      indent: 14 * scale + 36 * scale + 12 * scale,
      endIndent: 14 * scale,
    );
  }

  Widget _infoRow({
    required IconData icon,
    required String label,
    required String value,
    required double scale,
  }) {
    final isNone =
        value.trim().isEmpty || value.trim().toLowerCase() == 'none';

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 14 * scale,
        vertical: 12 * scale,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 36 * scale,
            height: 36 * scale,
            decoration: BoxDecoration(
              color: _C.tile,
              borderRadius: BorderRadius.circular(11 * scale),
            ),
            child: Icon(
              icon,
              color: _C.brand,
              size: 18 * scale,
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
                    fontSize: 11.5 * scale,
                    color: _C.muted,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.1,
                  ),
                ),
                SizedBox(height: 3 * scale),
                Text(
                  isNone ? 'None' : value,
                  style: TextStyle(
                    fontSize: 14.5 * scale,
                    color: isNone ? _C.muted : _C.ink,
                    fontWeight: isNone ? FontWeight.w400 : FontWeight.w600,
                    fontStyle: isNone ? FontStyle.italic : FontStyle.normal,
                    height: 1.3,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}