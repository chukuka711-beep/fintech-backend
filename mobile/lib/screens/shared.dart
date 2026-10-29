import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'dart:async';

String apiError(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map && data['error'] is String) return data['error'] as String;
    return 'The request could not be completed. Please try again.';
  }
  if (error is Exception) {
    return error.toString().replaceFirst('Exception: ', '');
  }
  return 'Something went wrong. Please try again.';
}

String formatNaira(String kobo) {
  final amount = BigInt.tryParse(kobo) ?? BigInt.zero;
  return '₦${amount ~/ BigInt.from(100)}.${(amount % BigInt.from(100)).toString().padLeft(2, '0')}';
}

class ScreenshotProtection {
  static const _channel = MethodChannel('naijapay/screenshot_protection');

  static Future<bool> setEnabled(bool enabled) async {
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux) {
      return false;
    }
    return await _channel.invokeMethod<bool>('setEnabled', {
          'enabled': enabled,
        }) ??
        false;
  }
}

class SecureScreen extends StatefulWidget {
  const SecureScreen({required this.child, super.key});
  final Widget child;

  @override
  State<SecureScreen> createState() => _SecureScreenState();
}

class _SecureScreenState extends State<SecureScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(_enableProtection());
  }

  Future<void> _enableProtection() async {
    final enabled = await ScreenshotProtection.setEnabled(true);
    if (mounted && !enabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Screenshot blocking is unavailable on this device.'),
        ),
      );
    }
  }

  @override
  void dispose() {
    unawaited(ScreenshotProtection.setEnabled(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
