import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// Import with prefix to avoid conflicts
import 'screens/login_screen.dart' as login;
import 'components/home_page.dart';
import 'services/local_notification_service.dart'; // 👈 NEW

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: const FirebaseOptions(
      apiKey: "AIzaSyDatcY_KIr6lT5BZCt2M5LYb7j8WvwHJtI",
      appId: "1:731882278333:android:e598c0fc33e3265984d6d4",
      messagingSenderId: "731882278333",
      projectId: "capstone-fe988",
      storageBucket: "capstone-fe988.firebasestorage.app",
    ),
  );

  await LocalNotificationService.init(); // 👈 NEW

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'NagaReady',

      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E9E4F),
        ),
        useMaterial3: true,
      ),

      // Start with the AUTH CHECK screen
      home: const AuthCheckScreen(),

      routes: {
        '/login': (context) => const login.LoginScreen(),
        '/home': (context) => const HomePage(),
      },
    );
  }
}

// ============================================================
// AUTH CHECK SCREEN
// Decides whether to go to Login or Home on app start.
// ============================================================
class AuthCheckScreen extends StatefulWidget {
  const AuthCheckScreen({super.key});

  @override
  State<AuthCheckScreen> createState() => _AuthCheckScreenState();
}

class _AuthCheckScreenState extends State<AuthCheckScreen> {
  // NagaReady brand colors
  static const Color brandGreen = Color(0xFF2E9E4F);
  static const Color brandNavy  = Color(0xFF102A43);

  @override
  void initState() {
    super.initState();
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    // Small delay so the splash/loading shows briefly
    await Future.delayed(const Duration(milliseconds: 300));

    final user = FirebaseAuth.instance.currentUser;

    // Not logged in → Login
    if (user == null) {
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/login');
      return;
    }

    // Logged in → fetch userData then go to Home
    try {
      DocumentSnapshot userDoc = await FirebaseFirestore.instance
          .collection('manage_users')
          .doc(user.uid)
          .get();

      if (!userDoc.exists) {
        userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
      }

      if (!userDoc.exists) {
        // Account missing in Firestore → force logout
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        Navigator.pushReplacementNamed(context, '/login');
        return;
      }

      final userData = userDoc.data() as Map<String, dynamic>;

      // Check status / responder access (same rules as LoginScreen)
      if (userData['status'] == 'inactive') {
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        Navigator.pushReplacementNamed(context, '/login');
        return;
      }

      if (userData['userType'] != 'responder' &&
          userData['type'] != 'responder') {
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        Navigator.pushReplacementNamed(context, '/login');
        return;
      }

      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => HomePage(
            userData: userData,
            user: user,
          ),
        ),
      );
    } catch (e) {
      // Any error → go to Login
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/login');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 🛡️ NagaReady shield logo
            Image.asset(
              'lib/assests/images/splash_logo.png',
              width: 160,
              height: 160,
            ),
            const SizedBox(height: 24),

            // 🏷️ NagaReady text (navy + green)
            RichText(
              text: const TextSpan(
                style: TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  fontFamily: 'Roboto',
                ),
                children: [
                  TextSpan(
                    text: 'Naga',
                    style: TextStyle(color: brandNavy),
                  ),
                  TextSpan(
                    text: 'Ready',
                    style: TextStyle(color: brandGreen),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // 📝 Tagline
            const Text(
              'E M E R G E N C Y   R E S P O N S E',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 3,
                color: brandNavy,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 40),

            // ⏳ Green loading spinner
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation<Color>(brandGreen),
              ),
            ),
          ],
        ),
      ),
    );
  }
}