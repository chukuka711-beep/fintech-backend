import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';

import '../core/api_client.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});
  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final token = await secureStorage.read(key: 'accessToken');
      if (!mounted) return;
      final biometricEnabled =
          await secureStorage.read(key: 'biometricsEnabled') == 'true';
      if (token != null && biometricEnabled) {
        try {
          final authenticated = await LocalAuthentication().authenticate(
            localizedReason: 'Unlock your wallet',
            biometricOnly: true,
          );
          if (!authenticated) {
            if (mounted) context.go('/login');
            return;
          }
        } on PlatformException {
          if (mounted) context.go('/login');
          return;
        }
      }
      if (!mounted) return;
      context.go(token == null ? '/onboarding' : '/home');
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.account_balance_wallet,
            size: 56,
            color: Color(0xff087e68),
          ),
          SizedBox(height: 12),
          Text(
            'NaijaPay',
            style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 20),
          CircularProgressIndicator(),
        ],
      ),
    ),
  );
}
