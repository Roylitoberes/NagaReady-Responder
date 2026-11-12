// lib/screens/login_screen.dart

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:responder_app/components/home_page.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _rememberMe = false;
  bool _obscurePassword = true;
  bool _isLoading = false;

  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  final FocusNode _emailFocusNode = FocusNode();
  final FocusNode _passwordFocusNode = FocusNode();

  // Polling variables
  Timer? _pollingTimer;
  String? _pendingResetEmail;
  // ignore: unused_field
  String? _currentRequestId;
  bool _isDialogShowing = false;
  bool _isPendingDialogOpen = false;

  static const Color primaryGreen = Color(0xFF008F5A);
  static const Color darkGreen = Color(0xFF006B45);
  static const Color lightGreen = Color(0xFFE8F7F0);
  static const Color veryLightGreen = Color(0xFFF4FBF7);
  static const Color darkText = Color(0xFF12372A);
  static const Color secondaryText = Color(0xFF64748B);
  static const Color borderColor = Color(0xFFD8E5DF);

  // Path to your logo (matches the folder name in pubspec.yaml)
  static const String _logoAsset = 'lib/assests/images/app_icon.png';

  @override
  void initState() {
    super.initState();
    _emailFocusNode.addListener(_handleFocusChange);
    _passwordFocusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.removeListener(_handleFocusChange);
    _passwordFocusNode.removeListener(_handleFocusChange);
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (!mounted) return;
    final node = _emailFocusNode.hasFocus
        ? _emailFocusNode
        : (_passwordFocusNode.hasFocus ? _passwordFocusNode : null);
    if (node == null) return;
    Future.delayed(const Duration(milliseconds: 250), () {
      if (mounted && node.context != null) {
        Scrollable.ensureVisible(
          node.context!,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
          alignment: 0.25,
        );
      }
    });
  }

  Future<void> _handleLogin() async {
    if (_emailController.text.trim().isEmpty || _passwordController.text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please fill in all fields'), backgroundColor: Color(0xFFDC2626)),
        );
      }
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() => _isLoading = true);

    try {
      UserCredential userCredential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      DocumentSnapshot userDoc = await FirebaseFirestore.instance.collection('manage_users').doc(userCredential.user!.uid).get();
      if (!userDoc.exists) {
        userDoc = await FirebaseFirestore.instance.collection('users').doc(userCredential.user!.uid).get();
      }

      if (!userDoc.exists) {
        await FirebaseAuth.instance.signOut();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('User account not found. Please contact administrator.'), backgroundColor: Color(0xFFDC2626)),
          );
          setState(() => _isLoading = false);
        }
        return;
      }

      final userData = userDoc.data() as Map<String, dynamic>;

      if (userData['status'] == 'inactive') {
        await FirebaseAuth.instance.signOut();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Your account has been deactivated. Please contact your administrator.'), backgroundColor: Color(0xFFDC2626), duration: Duration(seconds: 5)),
          );
          setState(() => _isLoading = false);
        }
        return;
      }

      if (userData['userType'] != 'responder' && userData['type'] != 'responder') {
        await FirebaseAuth.instance.signOut();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('This account is not authorized for Responder access.'), backgroundColor: Color(0xFFDC2626)),
          );
          setState(() => _isLoading = false);
        }
        return;
      }

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => HomePage(userData: userData, user: userCredential.user!)),
        );
      }
    } on FirebaseAuthException catch (e) {
      String message = 'Login failed. Please try again.';
      if (e.code == 'user-not-found') {
        message = 'No user found with this email.';
      } else if (e.code == 'wrong-password') {
        message = 'Incorrect password.';
      } else if (e.code == 'invalid-email') {
        message = 'Invalid email address.';
      } else if (e.code == 'too-many-requests') {
        message = 'Too many failed attempts. Please try again later.';
      } else if (e.code == 'invalid-credential') {
        message = 'Invalid email or password.';
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message), backgroundColor: const Color(0xFFDC2626)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: ${e.toString()}'), backgroundColor: const Color(0xFFDC2626)));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ───────────────────────── UI ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: true,
      body: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: const BouncingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  children: [
                    _buildHeader(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 8, 22, 20),
                      child: Column(
                        children: [
                          _buildInputField(
                            controller: _emailController,
                            focusNode: _emailFocusNode,
                            hintText: 'Email Address',
                            icon: Icons.email_outlined,
                            keyboardType: TextInputType.emailAddress,
                          ),
                          const SizedBox(height: 14),
                          _buildInputField(
                            controller: _passwordController,
                            focusNode: _passwordFocusNode,
                            hintText: 'Password',
                            icon: Icons.lock_outline_rounded,
                            obscureText: _obscurePassword,
                            textInputAction: TextInputAction.done,
                            suffixIcon: IconButton(
                              icon: Icon(
                                _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                                color: secondaryText,
                                size: 21,
                              ),
                              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                            ),
                          ),
                          const SizedBox(height: 6),
                          _buildRememberAndForgotRow(),
                          const SizedBox(height: 14),
                          _buildSignInButton(),
                          const SizedBox(height: 26),
                          _buildPrivacyNote(),
                        ],
                      ),
                    ),
                    const Spacer(),
                    _buildFooter(),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Wavy green footer — the header wave flipped upside-down, pinned to the bottom.
  Widget _buildFooter() {
    final double bottomInset = MediaQuery.of(context).padding.bottom;
    final double h = 120 + bottomInset;
    return SizedBox(
      width: double.infinity,
      height: h,
      child: Stack(
        children: [
          // Back wave (lighter tint)
          RotatedBox(
            quarterTurns: 2,
            child: ClipPath(
              clipper: const WaveClipper(offset: 16),
              child: Container(
                height: h,
                width: double.infinity,
                color: primaryGreen.withValues(alpha: 0.35),
              ),
            ),
          ),
          // Front wave (solid)
          RotatedBox(
            quarterTurns: 2,
            child: ClipPath(
              clipper: const WaveClipper(),
              child: Container(
                height: h,
                width: double.infinity,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [primaryGreen, darkGreen],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return SizedBox(
      height: 296,
      width: double.infinity,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          // Back wave (lighter tint)
          ClipPath(
            clipper: const WaveClipper(offset: 16),
            child: Container(
              height: 216,
              width: double.infinity,
              color: primaryGreen.withValues(alpha: 0.35),
            ),
          ),
          // Front wave (solid)
          ClipPath(
            clipper: const WaveClipper(),
            child: Container(
              height: 200,
              width: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [primaryGreen, darkGreen],
                ),
              ),
            ),
          ),
          // Top-right small icon
          Positioned(
            top: MediaQuery.of(context).padding.top + 10,
            right: 16,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.2),
                border: Border.all(color: Colors.white.withValues(alpha: 0.5)),
              ),
              child: const Icon(Icons.support_agent_rounded, color: Colors.white, size: 20),
            ),
          ),
          // Logo
          Positioned(
            top: MediaQuery.of(context).padding.top + 34,
            child: _buildLogo(),
          ),
          // Title (on the white area under the wave)
          const Positioned(
            top: 234,
            child: Text(
              'Responder',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: darkText, letterSpacing: 0.3),
            ),
          ),
        ],
      ),
    );
  }

  /// Header logo using app_icon.png (falls back to the shield icon if the
  /// image can't be loaded).
  Widget _buildLogo() {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 20, offset: const Offset(0, 8)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Image.asset(
            _logoAsset,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => const Icon(
              Icons.shield_rounded,
              color: primaryGreen,
              size: 48,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required FocusNode focusNode,
    required String hintText,
    required IconData icon,
    TextInputType? keyboardType,
    bool obscureText = false,
    Widget? suffixIcon,
    TextInputAction textInputAction = TextInputAction.next,
  }) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onSubmitted: textInputAction == TextInputAction.done ? (_) => _handleLogin() : null,
      style: const TextStyle(color: darkText, fontSize: 15, fontWeight: FontWeight.w500),
      cursorColor: primaryGreen,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(color: Color(0xFF8A9AAA), fontSize: 15),
        prefixIcon: Icon(icon, color: primaryGreen, size: 22),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: borderColor)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: borderColor)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: primaryGreen, width: 1.8)),
      ),
    );
  }

  /// "Remember me" on the left, "Forgot Password?" on the right — same row.
  Widget _buildRememberAndForgotRow() {
    return Row(
      children: [
        Checkbox(
          value: _rememberMe,
          onChanged: (value) => setState(() => _rememberMe = value ?? false),
          activeColor: primaryGreen,
          checkColor: Colors.white,
          side: const BorderSide(color: Color(0xFFB8CEC3), width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
        ),
        const Flexible(
          child: Text(
            'Remember me',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: secondaryText, fontWeight: FontWeight.w500),
          ),
        ),
        const Spacer(),
        TextButton(
          onPressed: _showForgotPasswordDialog,
          style: TextButton.styleFrom(
            foregroundColor: primaryGreen,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: const Text(
            'Forgot Password?',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: primaryGreen),
          ),
        ),
      ],
    );
  }

  Widget _buildSignInButton() {
    return Opacity(
      opacity: _isLoading ? 0.75 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: _isLoading ? null : _handleLogin,
          child: Ink(
            height: 68,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [primaryGreen, darkGreen],
              ),
              boxShadow: [
                BoxShadow(color: primaryGreen.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 8)),
              ],
            ),
            child: _isLoading
                ? const Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5, valueColor: AlwaysStoppedAnimation<Color>(Colors.white)),
                    ),
                  )
                : Row(
                    children: [
                      const Icon(Icons.shield_rounded, color: Colors.white, size: 24),
                      const SizedBox(width: 14),
                      const Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('RESPONDER SIGN IN', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 1)),
                            SizedBox(height: 2),
                            Text('Access your Responder Account', style: TextStyle(color: Color(0xFFCFF5E3), fontSize: 12)),
                          ],
                        ),
                      ),
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.2)),
                        child: const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 22),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildPrivacyNote() {
    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(color: lightGreen, borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.verified_user_outlined, color: primaryGreen, size: 21),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Your privacy is important', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: darkText)),
              SizedBox(height: 2),
              Text('We secure your data to only be used within this app.', style: TextStyle(fontSize: 11.5, color: secondaryText)),
            ],
          ),
        ),
      ],
    );
  }

  // ─────────────────── Forgot password flow (unchanged logic) ───────────────────

  void _showForgotPasswordDialog() {
    final TextEditingController emailController = TextEditingController(text: _emailController.text.trim());
    bool submitting = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
              title: const Text('Request Password Reset', style: TextStyle(color: darkText, fontWeight: FontWeight.w800)),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Enter your registered email. An administrator will send you a secure password-reset link.', style: TextStyle(color: secondaryText, fontSize: 14)),
                  ),
                  const SizedBox(height: 18),
                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    enabled: !submitting,
                    decoration: InputDecoration(
                      hintText: 'Email Address',
                      prefixIcon: const Icon(Icons.email_outlined, color: primaryGreen),
                      filled: true,
                      fillColor: veryLightGreen,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: borderColor)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: primaryGreen, width: 1.5)),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: submitting ? null : () => Navigator.pop(context),
                  child: const Text('Cancel', style: TextStyle(color: secondaryText)),
                ),
                ElevatedButton(
                  onPressed: submitting
                      ? null
                      : () async {
                          final email = emailController.text.trim();
                          if (email.isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter your email address'), backgroundColor: Color(0xFFDC2626)));
                            return;
                          }
                          setDialogState(() => submitting = true);
                          try {
                            final docRef = await FirebaseFirestore.instance.collection('password_reset_requests').add({
                              'email': email,
                              'status': 'pending',
                              'requestedAt': FieldValue.serverTimestamp(),
                              'requestedBy': 'responder',
                              'userAgent': 'flutter-responder-app',
                            });

                            if (mounted) {
                              // ignore: use_build_context_synchronously
                              Navigator.pop(context);
                              _pendingResetEmail = email;
                              _currentRequestId = docRef.id;
                              _showRequestSubmittedDialog();
                              _startPollingForApproval(docRef.id);
                            }
                          } catch (e) {
                            if (mounted) {
                              setDialogState(() => submitting = false);
                              // ignore: use_build_context_synchronously
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: ${e.toString()}'), backgroundColor: const Color(0xFFDC2626)));
                            }
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryGreen,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: submitting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation<Color>(Colors.white)))
                      : const Text('Send Request'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showRequestSubmittedDialog() {
    _isPendingDialogOpen = true;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          backgroundColor: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(color: lightGreen, shape: BoxShape.circle),
                  child: const Icon(Icons.access_time_rounded, color: primaryGreen, size: 32),
                ),
                const SizedBox(height: 20),
                const Text('Request Submitted', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: darkText)),
                const SizedBox(height: 6),
                const Text('Password reset request', style: TextStyle(fontSize: 14, color: secondaryText)),
                const SizedBox(height: 20),
                const Text(
                  'Your password-reset request has been submitted successfully. Please wait for the administrator to review and approve your request.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: secondaryText, height: 1.5),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFDE68A)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Color(0xFFD97706), size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Status: Pending Approval', style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFD97706), fontSize: 13)),
                            const SizedBox(height: 4),
                            Text('Keep this screen open. You will get a popup the moment it is approved.', style: TextStyle(color: const Color(0xFFD97706).withValues(alpha: 0.8), fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _isPendingDialogOpen = false;
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: primaryGreen, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    child: const Text('OK, I will wait', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // Polling: checks ONLY the specific request ID every 2 seconds
  void _startPollingForApproval(String requestId) {
    _pollingTimer?.cancel();

    _pollingTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_isDialogShowing) {
        timer.cancel();
        return;
      }

      try {
        final doc = await FirebaseFirestore.instance.collection('password_reset_requests').doc(requestId).get();

        if (doc.exists && doc.data()?['status'] == 'link_sent') {
          timer.cancel();

          if (mounted && !_isDialogShowing) {
            _isDialogShowing = true;

            if (_isPendingDialogOpen) {
              Navigator.of(context, rootNavigator: true).pop();
              _isPendingDialogOpen = false;
            }

            // ignore: use_build_context_synchronously
            _showCheckYourEmailDialog();

            await doc.reference.delete();
          }
        }
      } catch (e) {
        // ignore: avoid_print
        print("Polling safe check: $e");
      }
    });
  }

  void _showCheckYourEmailDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          backgroundColor: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(color: lightGreen, shape: BoxShape.circle),
                  child: const Icon(Icons.mark_email_read_rounded, color: primaryGreen, size: 32),
                ),
                const SizedBox(height: 20),
                const Text('Check Your Email', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: darkText)),
                const SizedBox(height: 6),
                const Text('Password reset approved', style: TextStyle(fontSize: 14, color: secondaryText)),
                const SizedBox(height: 20),
                const Text(
                  'Your password-reset request has been approved, and a password-reset link has been sent to your registered email address. Please check your inbox and follow the link to create a new password.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: secondaryText, height: 1.5),
                ),
                const SizedBox(height: 20),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0FDF4),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFBBF7D0)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.check_circle_rounded, color: Color(0xFF16A34A), size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Status: Reset Link Sent', style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF16A34A), fontSize: 13)),
                            const SizedBox(height: 4),
                            Text('Check your registered Gmail account to continue.', style: TextStyle(color: const Color(0xFF16A34A).withValues(alpha: 0.8), fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      _isDialogShowing = false;

                      if (_pendingResetEmail != null) {
                        _emailController.text = _pendingResetEmail!;
                      }
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: primaryGreen, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    child: const Text('OK', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Wavy bottom edge for the header.
class WaveClipper extends CustomClipper<Path> {
  final double offset;
  const WaveClipper({this.offset = 0});

  @override
  Path getClip(Size size) {
    final Path path = Path();
    final double h = size.height;
    final double w = size.width;
    path.lineTo(0, h - 45 + offset);
    path.quadraticBezierTo(w * 0.22, h + 12 + offset, w * 0.5, h - 28 + offset);
    path.quadraticBezierTo(w * 0.78, h - 68 + offset, w, h - 22 + offset);
    path.lineTo(w, 0);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant WaveClipper oldClipper) => oldClipper.offset != offset;
}