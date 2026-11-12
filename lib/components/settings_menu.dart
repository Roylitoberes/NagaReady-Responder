// settings_menu.dart
//
// Responder app Settings dropdown. Only three options:
//   • Request Profile Update  → drop with 2 options:
//         - Change Password (original: change + forgot → request to admin)
//         - Update Profile  (specify → submit → pending → admin reviews)
//   • About NAGA READY
//   • Logout
//
// Change Password now lives in the Profile page flow:
//   Profile → Account Security → Change Password
//   Use `AccountSecurityCard()` or `showChangePasswordSheet(context)`
//   inside profile_page.dart.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// =============================================================
// DESIGN TOKENS
// =============================================================
class _S {
  static const primary = Color(0xFF075E3B);
  static const ink = Color(0xFF0F172A);
  static const slate = Color(0xFF64748B);
  static const muted = Color(0xFF94A3B8);
  static const line = Color(0xFFE5E9EE);
  static const danger = Color(0xFFDC2626);
  static const info = Color(0xFF2563EB);
  static const warn = Color(0xFFD97706);
  static const okBg = Color(0xFFE8F5EE);
}

// =============================================================
// PASSWORD RULES (12+ chars, upper, lower, number, special)
// =============================================================
const int _kPasswordMinLength = 12;

String _validateNewPassword(String pw) {
  if (pw.length < _kPasswordMinLength) {
    return 'Password must be at least $_kPasswordMinLength characters.';
  }
  if (!RegExp(r'[A-Z]').hasMatch(pw)) {
    return 'Include at least one uppercase letter.';
  }
  if (!RegExp(r'[a-z]').hasMatch(pw)) {
    return 'Include at least one lowercase letter.';
  }
  if (!RegExp(r'[0-9]').hasMatch(pw)) return 'Include at least one number.';
  if (!RegExp(r'[^A-Za-z0-9]').hasMatch(pw)) {
    return 'Include at least one special character.';
  }
  return '';
}

// =============================================================
// GEAR BUTTON (put this in the header row)
// =============================================================
class ResponderSettingsButton extends StatelessWidget {
  const ResponderSettingsButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showResponderSettingsMenu(context),
        child: const SizedBox(
          width: 40,
          height: 40,
          child: Icon(Icons.settings_outlined, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}

enum _SettingsAction {
  profileMenu, // opens the 2nd drop (Change Password / Update Profile)
  back, // from the 2nd drop back to Settings
  changePassword,
  profileUpdate,
  about,
  logout,
}

/// Shows a dropdown card under the gear button (top-right).
Future<_SettingsAction?> _showDrop(
  BuildContext context,
  Widget Function(void Function(_SettingsAction) onSelect) cardBuilder,
) {
  final topPad = MediaQuery.of(context).padding.top;

  return showGeneralDialog<_SettingsAction>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Settings',
    barrierColor: Colors.black.withValues(alpha: 0.12),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (ctx, _, _) {
      return Stack(
        children: [
          Positioned(
            top: topPad + 62,
            right: 12,
            child: Material(
              color: Colors.transparent,
              child: cardBuilder((a) => Navigator.pop(ctx, a)),
            ),
          ),
        ],
      );
    },
    transitionBuilder: (ctx, anim, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, -0.03),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
        child: child,
      ),
    ),
  );
}

/// Opens the Settings dropdown (top-right gear).
Future<void> showResponderSettingsMenu(BuildContext context) async {
  var action =
      await _showDrop(context, (sel) => _SettingsMenuCard(onSelect: sel));

  // Request Profile Update → second drop with the two options
  if (action == _SettingsAction.profileMenu && context.mounted) {
    action =
        await _showDrop(context, (sel) => _ProfileDropCard(onSelect: sel));

    if (action == _SettingsAction.back && context.mounted) {
      return showResponderSettingsMenu(context);
    }
  }

  if (action == null || !context.mounted) return;

  switch (action) {
    case _SettingsAction.changePassword:
      await showChangePasswordSheet(context);
      break;
    case _SettingsAction.profileUpdate:
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const _ProfileUpdateSheet(),
      );
      break;
    case _SettingsAction.about:
      await showDialog(
        context: context,
        builder: (_) => const _AboutDialog(),
      );
      break;
    case _SettingsAction.logout:
      await _confirmLogout(context);
      break;
    case _SettingsAction.profileMenu:
    case _SettingsAction.back:
      break;
  }
}

/// Opens the Change Password sheet.
/// Call this from the Profile page (Profile → Account Security).
Future<void> showChangePasswordSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _ChangePasswordSheet(),
  );
}

// =============================================================
// ACCOUNT SECURITY CARD  (drop into profile_page.dart)
//   Profile → Account Security → Change Password
// =============================================================
class AccountSecurityCard extends StatelessWidget {
  const AccountSecurityCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _S.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 14, 14, 6),
            child: Row(
              children: [
                Icon(Icons.shield_outlined, color: _S.primary, size: 20),
                SizedBox(width: 8),
                Text(
                  'Account Security',
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    color: _S.ink,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _S.line),
          _MenuRow(
            icon: Icons.lock_outline_rounded,
            iconColor: _S.primary,
            title: 'Change Password',
            subtitle: 'Update your account password.',
            onTap: () => showChangePasswordSheet(context),
          ),
        ],
      ),
    );
  }
}

// =============================================================
// DROPDOWN CARD (3 options only)
// =============================================================
BoxDecoration _dropDecoration() => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.18),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
      ],
    );

double _dropWidth(BuildContext context) =>
    (MediaQuery.of(context).size.width * 0.78).clamp(250.0, 330.0);

// ---------- 1st drop: Settings ----------
class _SettingsMenuCard extends StatelessWidget {
  final void Function(_SettingsAction) onSelect;
  const _SettingsMenuCard({required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _dropWidth(context),
      decoration: _dropDecoration(),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            color: Colors.white,
            padding: const EdgeInsets.all(14),
            child: const Row(
              children: [
                Icon(Icons.settings_rounded, color: _S.primary, size: 26),
                SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Settings',
                        style: TextStyle(
                          color: _S.ink,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Manage your account and preferences.',
                        style: TextStyle(color: _S.slate, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: _S.line),
          _MenuRow(
            icon: Icons.manage_accounts_outlined,
            iconColor: _S.primary,
            title: 'Request Profile Update',
            subtitle: 'Request changes to personal or responder information.',
            onTap: () => onSelect(_SettingsAction.profileMenu),
          ),
          const Divider(height: 1, color: _S.line),
          _MenuRow(
            icon: Icons.info_outline_rounded,
            iconColor: _S.info,
            title: 'About NAGA READY',
            subtitle: 'View application information and version.',
            onTap: () => onSelect(_SettingsAction.about),
          ),
          const Divider(height: 1, color: _S.line),
          _MenuRow(
            icon: Icons.logout_rounded,
            iconColor: _S.danger,
            title: 'Logout',
            titleColor: _S.danger,
            subtitle: 'Sign out of the responder account.',
            onTap: () => onSelect(_SettingsAction.logout),
          ),
        ],
      ),
    );
  }
}

// ---------- 2nd drop: Request Profile Update ----------
class _ProfileDropCard extends StatelessWidget {
  final void Function(_SettingsAction) onSelect;
  const _ProfileDropCard({required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _dropWidth(context),
      decoration: _dropDecoration(),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => onSelect(_SettingsAction.back),
            child: Container(
              width: double.infinity,
              color: Colors.white,
              padding: const EdgeInsets.all(14),
              child: const Row(
                children: [
                  Icon(Icons.arrow_back_rounded,
                      color: _S.primary, size: 26),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Request Profile Update',
                          style: TextStyle(
                            color: _S.ink,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Choose what you want to do.',
                          style: TextStyle(color: _S.slate, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1, color: _S.line),
          _MenuRow(
            icon: Icons.lock_outline_rounded,
            iconColor: _S.primary,
            title: 'Change Password',
            subtitle: 'Update your account password.',
            onTap: () => onSelect(_SettingsAction.changePassword),
          ),
          const Divider(height: 1, color: _S.line),
          _MenuRow(
            icon: Icons.edit_note_rounded,
            iconColor: _S.info,
            title: 'Update Profile',
            subtitle: 'Request changes to your responder details.',
            onTap: () => onSelect(_SettingsAction.profileUpdate),
          ),
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final Color titleColor;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  const _MenuRow({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.titleColor = _S.ink,
  }) : trailing = null;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: iconColor, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                      color: titleColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12, color: _S.slate),
                  ),
                ],
              ),
            ),
            trailing ??
                const Icon(Icons.chevron_right_rounded,
                    color: _S.ink, size: 22),
          ],
        ),
      ),
    );
  }
}

// =============================================================
// PROFILE FIELD DEFINITIONS (same rules as the admin's Manage Users)
// =============================================================
const List<String> _kResponderRoles = [
  'Emergency Responder',
  'Team Leader',
  'Rescue Officer',
  'Driver / Operator',
  'Medical Responder',
  'Search & Rescue Specialist',
  'Communications Officer',
  'Disaster Operations Officer',
];
const List<String> _kTeamOptions = [
  'Rescue Team',
  'Medical Team',
  'Search & Rescue Team',
  'Fire / Rescue Team',
  'Evacuation Team',
  'Logistics Team',
  'Communications Team',
];
const List<String> _kCapabilityOptions = [
  'Search and Rescue',
  'First Aid',
  'Medical Response',
  'Emergency Transport',
  'Fire Response',
  'Water Rescue',
  'Evacuation',
  'Disaster Assessment',
  'Communications',
];

class _FieldDef {
  final String key; // Firestore field name in manage_users
  final String label;
  final List<String>? options; // dropdown when not null
  final TextInputType keyboard;
  final String hint;
  const _FieldDef(
    this.key,
    this.label, {
    this.options,
    this.keyboard = TextInputType.text,
    this.hint = '',
  });
}

const List<_FieldDef> _kFields = [
  _FieldDef('name', 'Full Name', hint: 'e.g. Juan Dela Cruz'),
  _FieldDef('gender', 'Gender', options: ['Male', 'Female']),
  _FieldDef('age',
      'Age', keyboard: TextInputType.number, hint: '18 - 80'),
  _FieldDef('civilStatus', 'Status', options: ['Single', 'Married']),
  _FieldDef('phone', 'Mobile Number',
      keyboard: TextInputType.phone, hint: '09XXXXXXXXX'),
  _FieldDef('role', 'Role / Position', options: _kResponderRoles),
  _FieldDef('team', 'Team', options: _kTeamOptions),
  _FieldDef('capabilities', 'Capabilities', options: _kCapabilityOptions),
];

String _labelFor(String key) {
  for (final f in _kFields) {
    if (f.key == key) return f.label;
  }
  return key;
}

/// Returns an error message, or '' when the value is valid.
String _validateField(_FieldDef f, String v) {
  if (v.isEmpty) return 'Please fill in the new value for "${f.label}".';
  switch (f.key) {
    case 'phone':
      if (!RegExp(r'^\d{11}$').hasMatch(v)) {
        return 'Mobile Number must be exactly 11 digits.';
      }
      break;
    case 'age':
      final n = int.tryParse(v);
      if (n == null || n < 18 || n > 80) {
        return 'Age must be between 18 and 80.';
      }
      break;
  }
  if (f.options != null && !f.options!.contains(v)) {
    return 'Please choose a valid ${f.label}.';
  }
  return '';
}

/// "• Full Name: Old → New" lines
List<Widget> _changeLines(
  Map<String, dynamic> changes,
  Map<String, dynamic> previous,
) {
  return changes.entries.map((e) {
    final prev = (previous[e.key] ?? '').toString();
    final text = prev.isNotEmpty
        ? '• ${_labelFor(e.key)}: $prev → ${e.value}'
        : '• ${_labelFor(e.key)}: ${e.value}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        text,
        style: const TextStyle(fontSize: 12.5, color: _S.slate),
      ),
    );
  }).toList();
}

// =============================================================
// REQUEST PROFILE UPDATE SHEET
//   Specify Details → Submit → Pending Review → Admin Reviews
//   → Approved / Rejected
//   When approved, the admin's portal updates the responder's account
//   automatically and the app shows a "profile changed" popup.
//
// Firestore: collection `profile_update_requests`
//   requesterUid, email, responderName,
//   changes  {firestoreKey: newValue}   e.g. {name: 'Juan Dela Cruz'}
//   previous {firestoreKey: oldValue}
//   fields [labels], reason, status (pending | approved | rejected),
//   requestedAt, responderNotified,
//   adminRemarks / reviewedAt / reviewedBy (set by admin)
// =============================================================
class _ProfileUpdateSheet extends StatefulWidget {
  const _ProfileUpdateSheet();

  @override
  State<_ProfileUpdateSheet> createState() => _ProfileUpdateSheetState();
}

class _ProfileUpdateSheetState extends State<_ProfileUpdateSheet> {
  final Set<String> _selected = <String>{};
  final Map<String, TextEditingController> _ctrls = {};
  final _reasonCtrl = TextEditingController();

  Map<String, dynamic> _current = {};
  bool _loading = false;
  String _error = '';

  Stream<QuerySnapshot<Map<String, dynamic>>>? _stream;

  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();
    final uid = _user?.uid;
    if (uid != null) {
      _stream = FirebaseFirestore.instance
          .collection('profile_update_requests')
          .where('requesterUid', isEqualTo: uid)
          .snapshots();
      _loadCurrent(uid);
    }
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) {
      c.dispose();
    }
    _reasonCtrl.dispose();
    super.dispose();
  }

  TextEditingController _ctrlFor(String key) =>
      _ctrls.putIfAbsent(key, () => TextEditingController());

  Future<void> _loadCurrent(String uid) async {
    try {
      var doc = await FirebaseFirestore.instance
          .collection('manage_users')
          .doc(uid)
          .get();
      if (!doc.exists) {
        doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(uid)
            .get();
      }
      if (!mounted) return;
      setState(() => _current = doc.data() ?? {});
    } catch (_) {}
  }

  String _currentText(String key) => (_current[key] ?? '').toString().trim();

  Future<void> _submit() async {
    setState(() => _error = '');

    if (_selected.isEmpty) {
      return setState(
          () => _error = 'Select at least one detail you want to change.');
    }

    final changes = <String, String>{};
    final previous = <String, String>{};
    for (final f in _kFields) {
      if (!_selected.contains(f.key)) continue;
      final v = _ctrlFor(f.key).text.trim();
      final err = _validateField(f, v);
      if (err.isNotEmpty) return setState(() => _error = err);
      if (v == _currentText(f.key)) {
        return setState(() =>
            _error = '${f.label} is the same as your current information.');
      }
      changes[f.key] = v;
      previous[f.key] = _currentText(f.key);
    }

    setState(() => _loading = true);
    try {
      final name = _currentText('name').isNotEmpty
          ? _currentText('name')
          : (_user?.displayName ?? '');

      await FirebaseFirestore.instance
          .collection('profile_update_requests')
          .add({
        'requesterUid': _user?.uid ?? '',
        'email': _user?.email ?? '',
        'responderName': name,
        'changes': changes,
        'previous': previous,
        'fields': changes.keys.map(_labelFor).toList(),
        'reason': _reasonCtrl.text.trim(),
        'status': 'pending',
        'requestedAt': FieldValue.serverTimestamp(),
        'requestedBy': 'responder-app',
        'responderNotified': false,
      });
      if (!mounted) return;
      setState(() {
        _selected.clear();
        for (final c in _ctrls.values) {
          c.clear();
        }
        _reasonCtrl.clear();
      });
    } on FirebaseException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.code == 'permission-denied'
          ? 'Permission denied. Please contact the admin.'
          : 'Failed to submit request. Please try again.');
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Failed to submit request. Please try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.92,
        ),
        decoration: const BoxDecoration(
          color: Color(0xFFF5F7F8),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _SheetHandle(),
            _SheetHeader(
              icon: Icons.manage_accounts_outlined,
              title: 'Request Profile Update',
              onClose: () => Navigator.pop(context),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                child: _stream == null
                    ? _buildForm()
                    : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: _stream,
                        builder: (context, snap) {
                          final latest = _latest(snap.data);
                          final status =
                              (latest?['status'] ?? '').toString();
                          final isPending = status == 'pending';

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _FlowSteps(status: status),
                              const SizedBox(height: 14),
                              if (latest != null) ...[
                                _StatusCard(data: latest),
                                const SizedBox(height: 14),
                              ],
                              if (!isPending) _buildForm(),
                              if (isPending)
                                const Text(
                                  'You can submit a new request once the admin has reviewed this one.',
                                  style: TextStyle(
                                      fontSize: 12, color: _S.muted),
                                ),
                            ],
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Map<String, dynamic>? _latest(QuerySnapshot<Map<String, dynamic>>? snap) {
    if (snap == null || snap.docs.isEmpty) return null;
    final docs = snap.docs.toList()
      ..sort((a, b) {
        final at = a.data()['requestedAt'];
        final bt = b.data()['requestedAt'];
        final ad = at is Timestamp ? at.toDate() : DateTime.now();
        final bd = bt is Timestamp ? bt.toDate() : DateTime.now();
        return bd.compareTo(ad); // newest first (pending-write = now)
      });
    return docs.first.data();
  }

  Widget _dropdownField(_FieldDef f) {
    final ctrl = _ctrlFor(f.key);
    final cur = ctrl.text.isEmpty ? null : ctrl.text;
    return InputDecorator(
      decoration: _inputDecoration(''),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: cur,
          isExpanded: true,
          isDense: true,
          hint: Text(
            'Select ${f.label.toLowerCase()}',
            style: const TextStyle(color: _S.muted, fontSize: 13.5),
          ),
          style: const TextStyle(color: _S.ink, fontSize: 14),
          items: f.options!
              .map((o) => DropdownMenuItem<String>(
                    value: o,
                    child: Text(o, overflow: TextOverflow.ellipsis),
                  ))
              .toList(),
          onChanged: (v) => setState(() => ctrl.text = v ?? ''),
        ),
      ),
    );
  }

  Widget _textField(_FieldDef f) {
    final List<TextInputFormatter> formatters = f.key == 'phone'
        ? [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(11),
          ]
        : f.key == 'age'
            ? [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(2),
              ]
            : <TextInputFormatter>[];

    return TextField(
      controller: _ctrlFor(f.key),
      keyboardType: f.keyboard,
      inputFormatters: formatters,
      decoration: _inputDecoration(f.hint.isEmpty ? 'Enter new value' : f.hint),
    );
  }

  Widget _buildForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelTitle('Specify Details to Change'),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose what you want updated, then enter the new information. The admin will review your request.',
                style: TextStyle(fontSize: 12.5, color: _S.slate),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _kFields.map((f) {
                  final on = _selected.contains(f.key);
                  return FilterChip(
                    label: Text(f.label),
                    selected: on,
                    showCheckmark: false,
                    onSelected: (v) => setState(() {
                      v ? _selected.add(f.key) : _selected.remove(f.key);
                    }),
                    labelStyle: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: on ? Colors.white : _S.ink,
                    ),
                    backgroundColor: Colors.white,
                    selectedColor: _S.primary,
                    side: BorderSide(color: on ? _S.primary : _S.line),
                  );
                }).toList(),
              ),
              for (final f in _kFields)
                if (_selected.contains(f.key)) ...[
                  const SizedBox(height: 14),
                  _FieldLabel('New ${f.label}'),
                  if (_currentText(f.key).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Current: ${_currentText(f.key)}',
                        style:
                            const TextStyle(fontSize: 11.5, color: _S.muted),
                      ),
                    ),
                  f.options != null ? _dropdownField(f) : _textField(f),
                ],
              const SizedBox(height: 14),
              const _FieldLabel('Reason / Additional Details (optional)'),
              TextField(
                controller: _reasonCtrl,
                maxLines: 3,
                decoration: _inputDecoration('Why do you need this change?'),
              ),
              if (_error.isNotEmpty) _Msg(_error, isError: true),
              const SizedBox(height: 14),
              _PrimaryButton(
                label: 'Submit Request',
                loadingLabel: 'Submitting...',
                loading: _loading,
                onTap: _submit,
              ),
              const SizedBox(height: 8),
              const Text(
                'When approved, the admin updates your official account details automatically.',
                style: TextStyle(fontSize: 11.5, color: _S.muted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Step tracker: Submit → Pending Review → Admin Reviews → Approved/Rejected
class _FlowSteps extends StatelessWidget {
  final String status; // '', pending, approved, rejected
  const _FlowSteps({required this.status});

  @override
  Widget build(BuildContext context) {
    int done;
    switch (status) {
      case 'pending':
        done = 2; // submitted, pending review
        break;
      case 'approved':
      case 'rejected':
        done = 4;
        break;
      default:
        done = 0;
    }

    final last = status == 'approved'
        ? 'Approved'
        : status == 'rejected'
            ? 'Rejected'
            : 'Approved / Rejected';

    final steps = ['Submit Request', 'Pending Review', 'Admin Reviews', last];

    return _Card(
      child: Row(
        children: List.generate(steps.length, (i) {
          final ok = i < done;
          final rejected = status == 'rejected' && i == 3;
          final color = rejected
              ? _S.danger
              : ok
                  ? _S.primary
                  : _S.muted;
          return Expanded(
            child: Column(
              children: [
                Icon(
                  rejected
                      ? Icons.cancel_rounded
                      : ok
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: color,
                ),
                const SizedBox(height: 4),
                Text(
                  steps[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: ok ? FontWeight.w800 : FontWeight.w500,
                    color: ok ? color : _S.slate,
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final Map<String, dynamic> data;
  const _StatusCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final status = (data['status'] ?? 'pending').toString();
    final changes =
        Map<String, dynamic>.from((data['changes'] ?? const {}) as Map);
    final previous =
        Map<String, dynamic>.from((data['previous'] ?? const {}) as Map);
    final remarks = (data['adminRemarks'] ?? '').toString();

    late final Color color;
    late final String title;
    late final String body;
    late final IconData icon;

    switch (status) {
      case 'approved':
        color = _S.primary;
        icon = Icons.check_circle_rounded;
        title = 'Request Approved';
        body = 'The admin approved this request and updated your profile.';
        break;
      case 'rejected':
        color = _S.danger;
        icon = Icons.cancel_rounded;
        title = 'Request Rejected';
        body = 'The admin did not approve this request.';
        break;
      default:
        color = _S.warn;
        icon = Icons.hourglass_top_rounded;
        title = 'Pending Review';
        body = 'Your request was sent. Please wait for the admin to review it.';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(body, style: const TextStyle(fontSize: 12.5, color: _S.ink)),
          if (changes.isNotEmpty) ...[
            const SizedBox(height: 10),
            ..._changeLines(changes, previous),
          ],
          if (remarks.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Admin remarks: $remarks',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: _S.ink,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================
// PROFILE UPDATE WATCHER
//   Wrap the HomePage body with this. It:
//   1. keeps the profile data live (admin edits show up instantly), and
//   2. pops up "Your profile was changed by the admin" (or rejected)
//      once for each reviewed request.
// =============================================================
class ProfileUpdateWatcher extends StatefulWidget {
  final Widget child;
  final void Function(Map<String, dynamic> data)? onProfileChanged;

  const ProfileUpdateWatcher({
    super.key,
    required this.child,
    this.onProfileChanged,
  });

  @override
  State<ProfileUpdateWatcher> createState() => _ProfileUpdateWatcherState();
}

class _ProfileUpdateWatcherState extends State<ProfileUpdateWatcher> {
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _profileSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _reqSub;

  final Set<String> _shown = <String>{};
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _queue = [];
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final db = FirebaseFirestore.instance;

    // 1) live profile data
    _profileSub = db.collection('manage_users').doc(uid).snapshots().listen(
      (snap) async {
        if (!mounted) return;
        if (snap.exists) {
          final d = snap.data();
          if (d != null) widget.onProfileChanged?.call(d);
        } else {
          final u = await db.collection('users').doc(uid).get();
          final d = u.data();
          if (u.exists && d != null && mounted) {
            widget.onProfileChanged?.call(d);
          }
        }
      },
      onError: (e) => debugPrint('⚠️ profile listener error: $e'),
    );

    // 2) reviewed requests → popup
    _reqSub = db
        .collection('profile_update_requests')
        .where('requesterUid', isEqualTo: uid)
        .snapshots()
        .listen(
      (snap) {
        if (!mounted) return;
        for (final d in snap.docs) {
          final data = d.data();
          final status = (data['status'] ?? '').toString();
          if (status != 'approved' && status != 'rejected') continue;
          if (data['responderNotified'] == true) continue;
          if (_shown.contains(d.id)) continue;
          _shown.add(d.id);
          _queue.add(d);
        }
        _drain();
      },
      onError: (e) => debugPrint('⚠️ request listener error: $e'),
    );
  }

  Future<void> _drain() async {
    if (_dialogOpen || _queue.isEmpty || !mounted) return;
    _dialogOpen = true;

    final doc = _queue.removeAt(0);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProfileResultDialog(data: doc.data()),
    );

    // mark as seen so it never pops up again
    try {
      await doc.reference.update({
        'responderNotified': true,
        'responderNotifiedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('⚠️ could not mark request as notified: $e');
    }

    _dialogOpen = false;
    if (mounted) _drain();
  }

  @override
  void dispose() {
    _profileSub?.cancel();
    _reqSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ProfileResultDialog extends StatelessWidget {
  final Map<String, dynamic> data;
  const _ProfileResultDialog({required this.data});

  @override
  Widget build(BuildContext context) {
    final approved = (data['status'] ?? '') == 'approved';
    final color = approved ? _S.primary : _S.danger;
    final changes =
        Map<String, dynamic>.from((data['changes'] ?? const {}) as Map);
    final previous =
        Map<String, dynamic>.from((data['previous'] ?? const {}) as Map);
    final remarks = (data['adminRemarks'] ?? '').toString();

    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                shape: BoxShape.circle,
              ),
              child: Icon(
                approved ? Icons.check_circle_rounded : Icons.cancel_rounded,
                color: color,
                size: 30,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              approved ? 'Profile Updated' : 'Request Rejected',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: _S.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              approved
                  ? 'The admin changed your profile details.'
                  : 'The admin did not approve your profile update request.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: _S.slate),
            ),
            if (changes.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F7F8),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _S.line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _changeLines(changes, previous),
                ),
              ),
            ],
            if (remarks.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Admin remarks: $remarks',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: _S.ink,
                ),
              ),
            ],
            const SizedBox(height: 16),
            _PrimaryButton(
              label: 'Got it',
              loadingLabel: '',
              loading: false,
              onTap: () => Navigator.pop(context),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================
// CHANGE PASSWORD SHEET
//   1. Change Password
//   2. Forgot Password → Send Request to Admin
// =============================================================

// Remembers (for this app session) which "link sent" notices were dismissed
final Set<String> _seenResetNotices = <String>{};

class _ChangePasswordSheet extends StatefulWidget {
  const _ChangePasswordSheet();

  @override
  State<_ChangePasswordSheet> createState() => _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends State<_ChangePasswordSheet> {
  final _currentCtrl = TextEditingController();
  final _newCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  final _resetEmailCtrl = TextEditingController();
  final _newFocus = FocusNode();

  bool _showCurrent = false;
  bool _showNew = false;
  bool _showConfirm = false;

  bool _pwLoading = false;
  String _pwError = '';
  String _pwSuccess = '';

  bool _resetLoading = false;
  String _resetError = '';
  String _resetSuccess = '';

  // Shown when the admin has sent the reset link
  String? _noticeId;
  String? _noticeEmail;

  Stream<QuerySnapshot<Map<String, dynamic>>>? _noticeStream;

  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  void initState() {
    super.initState();

    final uid = _user?.uid;
    if (uid != null) {
      _noticeStream = FirebaseFirestore.instance
          .collection('password_reset_requests')
          .where('requesterUid', isEqualTo: uid)
          .snapshots();
    }
  }

  @override
  void dispose() {
    _currentCtrl.dispose();
    _newCtrl.dispose();
    _confirmCtrl.dispose();
    _resetEmailCtrl.dispose();
    _newFocus.dispose();
    super.dispose();
  }

  // ---------- 1. change password ----------
  Future<void> _updatePassword() async {
    final user = _user;
    if (user == null || user.email == null) return;

    setState(() {
      _pwError = '';
      _pwSuccess = '';
    });

    final current = _currentCtrl.text;
    final next = _newCtrl.text;
    final confirm = _confirmCtrl.text;

    if (current.isEmpty) {
      return setState(() => _pwError = 'Please enter your current password.');
    }
    final rule = _validateNewPassword(next);
    if (rule.isNotEmpty) return setState(() => _pwError = rule);
    if (next != confirm) {
      return setState(() => _pwError = 'Passwords do not match.');
    }
    if (next == current) {
      return setState(() => _pwError = 'New password must be different.');
    }

    setState(() => _pwLoading = true);
    try {
      final cred = EmailAuthProvider.credential(
        email: user.email!,
        password: current,
      );
      await user.reauthenticateWithCredential(cred);
      await user.updatePassword(next);

      if (!mounted) return;
      setState(() {
        _pwSuccess = 'Password updated successfully.';
        _currentCtrl.clear();
        _newCtrl.clear();
        _confirmCtrl.clear();
      });

      await Future.delayed(const Duration(milliseconds: 1600));
      if (mounted) Navigator.pop(context);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      String msg;
      if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
        msg = 'Current password is incorrect.';
      } else if (e.code == 'too-many-requests') {
        msg = 'Too many attempts. Please try again later.';
      } else {
        msg = e.message ?? 'Failed to update password.';
      }
      setState(() => _pwError = msg);
    } catch (e) {
      if (!mounted) return;
      setState(() => _pwError = 'Failed to update password.');
    } finally {
      if (mounted) setState(() => _pwLoading = false);
    }
  }

  // ---------- 2. forgot password → request to admin ----------
  Future<void> _sendRequestToAdmin() async {
    setState(() {
      _resetError = '';
      _resetSuccess = '';
    });

    final target = _resetEmailCtrl.text.trim();
    if (target.isEmpty) {
      return setState(
          () => _resetError = 'Please enter your registered email address.');
    }

    setState(() => _resetLoading = true);
    try {
      await FirebaseFirestore.instance
          .collection('password_reset_requests')
          .add({
        'email': target,
        'status': 'pending',
        'requestedAt': FieldValue.serverTimestamp(),
        'requestedBy': 'responder-app',
        'userAgent': 'responder-app',
        'requesterUid': _user?.uid ?? '',
      });
      if (!mounted) return;
      setState(() => _resetSuccess =
          'Request sent to admin for $target. Please wait for the reset link in your email.');
    } on FirebaseException catch (e) {
      if (!mounted) return;
      setState(() => _resetError = e.code == 'permission-denied'
          ? 'Permission denied. Please contact the admin.'
          : 'Failed to send request. Please try again.');
    } catch (_) {
      if (!mounted) return;
      setState(
          () => _resetError = 'Failed to send request. Please try again.');
    } finally {
      if (mounted) setState(() => _resetLoading = false);
    }
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.92,
        ),
        decoration: const BoxDecoration(
          color: Color(0xFFF5F7F8),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: _S.line,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline_rounded,
                      color: _S.primary, size: 24),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Change Password',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: _S.ink,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: _S.slate),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // admin sent the link
                    _buildLinkNotice(),

                    // ----- 1. change -----
                    const _PanelTitle('1. Change Password'),
                    _Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _PwField(
                            label: 'Current Password',
                            hint: 'Enter your current password',
                            controller: _currentCtrl,
                            visible: _showCurrent,
                            onToggle: () =>
                                setState(() => _showCurrent = !_showCurrent),
                          ),
                          const SizedBox(height: 12),
                          _PwField(
                            label: 'New Password',
                            hint: 'Enter your new password',
                            controller: _newCtrl,
                            focusNode: _newFocus,
                            visible: _showNew,
                            onToggle: () =>
                                setState(() => _showNew = !_showNew),
                          ),
                          ListenableBuilder(
                            listenable: _newFocus,
                            builder: (_, _) => _newFocus.hasFocus
                                ? const Padding(
                                    padding: EdgeInsets.only(top: 6),
                                    child: Text(
                                      '12+ characters with uppercase, lowercase, number, and symbol.',
                                      style: TextStyle(
                                          fontSize: 12, color: _S.slate),
                                    ),
                                  )
                                : const SizedBox.shrink(),
                          ),
                          const SizedBox(height: 12),
                          _PwField(
                            label: 'Confirm New Password',
                            hint: 'Re-enter your new password',
                            controller: _confirmCtrl,
                            visible: _showConfirm,
                            onToggle: () =>
                                setState(() => _showConfirm = !_showConfirm),
                          ),
                          ListenableBuilder(
                            listenable:
                                Listenable.merge([_newCtrl, _confirmCtrl]),
                            builder: (_, _) {
                              final mismatch = _confirmCtrl.text.isNotEmpty &&
                                  _newCtrl.text != _confirmCtrl.text;
                              return mismatch
                                  ? const _Msg('Passwords do not match.',
                                      isError: true)
                                  : const SizedBox.shrink();
                            },
                          ),
                          if (_pwError.isNotEmpty)
                            _Msg(_pwError, isError: true),
                          if (_pwSuccess.isNotEmpty) _Msg(_pwSuccess),
                          const SizedBox(height: 14),
                          _PrimaryButton(
                            label: 'Update Password',
                            loadingLabel: 'Updating...',
                            loading: _pwLoading,
                            onTap: _updatePassword,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // ----- 2. forgot -----
                    const _PanelTitle(
                        '2. Forgot Password (cannot remember current password)'),
                    _Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _FieldLabel('Registered Email Address'),
                          TextField(
                            controller: _resetEmailCtrl,
                            keyboardType: TextInputType.emailAddress,
                            autofillHints: const [AutofillHints.email],
                            decoration: _inputDecoration('Enter your email'),
                          ),
                          if (_resetError.isNotEmpty)
                            _Msg(_resetError, isError: true),
                          if (_resetSuccess.isNotEmpty && _noticeId == null)
                            _Msg(_resetSuccess),
                          const SizedBox(height: 14),
                          _PrimaryButton(
                            label: 'Send Request to Admin',
                            loadingLabel: 'Sending...',
                            loading: _resetLoading,
                            onTap: _sendRequestToAdmin,
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'The admin will review your request and send a reset link to your email.',
                            style: TextStyle(fontSize: 11.5, color: _S.muted),
                          ),
                        ],
                      ),
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

  /// Live notice: shown when the admin pressed "Send Reset Link".
  Widget _buildLinkNotice() {
    final stream = _noticeStream;
    if (stream == null) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();

        QueryDocumentSnapshot<Map<String, dynamic>>? hit;
        for (final d in snap.data!.docs) {
          if (d.data()['status'] == 'link_sent' &&
              !_seenResetNotices.contains(d.id)) {
            hit = d;
            break;
          }
        }
        if (hit == null) return const SizedBox.shrink();

        final email =
            (hit.data()['email'] ?? _user?.email ?? '').toString();
        final id = hit.id;
        _noticeId = id;
        _noticeEmail = email;

        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _S.okBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _S.primary.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '✅ The admin has sent your reset link.',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: _S.primary,
                  fontSize: 13.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Please check your inbox or spam folder at ${_noticeEmail ?? ''}.',
                style: const TextStyle(fontSize: 12.5, color: _S.ink),
              ),
              const SizedBox(height: 6),
              TextButton(
                onPressed: () {
                  setState(() {
                    _seenResetNotices.add(id);
                    _noticeId = null;
                    _noticeEmail = null;
                  });
                },
                style: TextButton.styleFrom(
                  foregroundColor: _S.primary,
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 30),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Got it',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          ),
        );
      },
    );
  }
}

// =============================================================
// ABOUT DIALOG
// =============================================================
class _AboutDialog extends StatelessWidget {
  const _AboutDialog();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: _S.okBg,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.shield_rounded,
                    color: _S.primary, size: 30),
              ),
              const SizedBox(height: 12),
              const Text(
                'About NAGA READY',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: _S.ink,
                ),
              ),
              const SizedBox(height: 14),
              const Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'NAGA READY is a mobile application designed for emergency responders of the City of Naga CDRRMO to support emergency assignments, field operations, and response coordination.',
                        style: TextStyle(
                            fontSize: 13, color: _S.ink, height: 1.4),
                      ),
                      SizedBox(height: 14),
                      Text(
                        'Key Features:',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                          color: _S.ink,
                        ),
                      ),
                      SizedBox(height: 8),
                      _FeatureLine('Home',
                          'View emergency updates and assigned incidents.'),
                      _FeatureLine('Tasks',
                          'Receive, review, and accept emergency dispatch assignments.'),
                      _FeatureLine('Map & Navigation',
                          'View incident locations and navigate to assigned emergency sites.'),
                      _FeatureLine('Incident Updates',
                          'Update response progress from En Route to Arrival and Resolution.'),
                      _FeatureLine('Backup Requests',
                          'Request additional assistance when needed.'),
                      _FeatureLine('Profile',
                          'View responder information and manage profile requests.'),
                      SizedBox(height: 14),
                      _AboutRow('Developed for', 'City of Naga CDRRMO'),
                      _AboutRow('Version', '1.0.0'),
                      SizedBox(height: 12),
                      Center(
                        child: Text(
                          '© 2026 NAGA READY. All Rights Reserved.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 11.5, color: _S.muted),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _PrimaryButton(
                label: 'Close',
                loadingLabel: '',
                loading: false,
                onTap: () => Navigator.pop(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeatureLine extends StatelessWidget {
  final String title;
  final String desc;
  const _FeatureLine(this.title, this.desc);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('•  ', style: TextStyle(fontSize: 13, color: _S.ink)),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '$title – ',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  TextSpan(text: desc),
                ],
              ),
              style:
                  const TextStyle(fontSize: 12.5, color: _S.ink, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _AboutRow extends StatelessWidget {
  final String label;
  final String value;
  const _AboutRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: _S.line)),
      ),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 13, color: _S.slate)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: _S.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================
// LOGOUT
// =============================================================
Future<void> _confirmLogout(BuildContext context) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text(
        'Confirm Logout',
        style: TextStyle(fontWeight: FontWeight.w800, color: _S.ink),
      ),
      content: const Text(
        'Are you sure you want to logout?\nYou will be redirected to the login page.',
        style: TextStyle(color: _S.slate, fontSize: 13.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel', style: TextStyle(color: _S.slate)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text(
            'Yes, Logout',
            style: TextStyle(color: _S.danger, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    ),
  );

  if (yes != true) return;

  await FirebaseAuth.instance.signOut();
  if (!context.mounted) return;

  // If your app listens to authStateChanges() in main.dart, the login
  // screen will show automatically.
  Navigator.of(context).popUntil((route) => route.isFirst);
}

// =============================================================
// SMALL SHARED WIDGETS
// =============================================================
InputDecoration _inputDecoration(String hint, {Widget? suffix}) {
  OutlineInputBorder border(Color c) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: c),
      );
  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: _S.muted, fontSize: 13.5),
    isDense: true,
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    enabledBorder: border(_S.line),
    focusedBorder: border(_S.primary),
    suffixIcon: suffix,
  );
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 10),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: _S.line,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ],
    );
  }
}

class _SheetHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onClose;
  const _SheetHeader({
    required this.icon,
    required this.title,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Icon(icon, color: _S.primary, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: _S.ink,
              ),
            ),
          ),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, color: _S.slate),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _S.line),
      ),
      child: child,
    );
  }
}

class _PanelTitle extends StatelessWidget {
  final String text;
  const _PanelTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w800,
          color: _S.ink,
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: _S.ink,
        ),
      ),
    );
  }
}

class _PwField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController controller;
  final bool visible;
  final VoidCallback onToggle;
  final FocusNode? focusNode;

  const _PwField({
    required this.label,
    required this.hint,
    required this.controller,
    required this.visible,
    required this.onToggle,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FieldLabel(label),
        TextField(
          controller: controller,
          focusNode: focusNode,
          obscureText: !visible,
          enableSuggestions: false,
          autocorrect: false,
          decoration: _inputDecoration(
            hint,
            suffix: IconButton(
              onPressed: onToggle,
              icon: Icon(
                visible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 20,
                color: _S.slate,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Msg extends StatelessWidget {
  final String text;
  final bool isError;
  const _Msg(this.text, {this.isError = false});

  @override
  Widget build(BuildContext context) {
    final color = isError ? _S.danger : _S.primary;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String label;
  final String loadingLabel;
  final bool loading;
  final VoidCallback onTap;

  const _PrimaryButton({
    required this.label,
    required this.loadingLabel,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 46,
      child: ElevatedButton(
        onPressed: loading ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: _S.primary,
          disabledBackgroundColor: _S.primary.withValues(alpha: 0.55),
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: Text(
          loading ? loadingLabel : label,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
        ),
      ),
    );
  }
}