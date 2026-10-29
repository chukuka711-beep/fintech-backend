import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';

class PurchaseResultScreen extends ConsumerStatefulWidget {
  const PurchaseResultScreen({required this.reference, super.key});
  final String reference;
  @override
  ConsumerState<PurchaseResultScreen> createState() =>
      _PurchaseResultScreenState();
}

class _PurchaseResultScreenState extends ConsumerState<PurchaseResultScreen> {
  String _status = 'pending';
  Timer? _timer;

  Future<void> _poll() async {
    try {
      final result = await ref
          .read(apiProvider)
          .dio
          .get<Map<String, dynamic>>(
            '/transactions/${Uri.encodeComponent(widget.reference)}',
          );
      final status = result.data?['status']?.toString() ?? 'pending';
      if (mounted && status != _status) setState(() => _status = status);
      if (status == 'success' || status == 'failed') _timer?.cancel();
    } catch (_) {
      // A polling timeout does not change a pending payment into a failure.
    }
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _poll());
    WidgetsBinding.instance.addPostFrameCallback((_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _status == 'success'
                  ? Icons.check_circle
                  : _status == 'failed'
                  ? Icons.error
                  : Icons.hourglass_top,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text(
              _status == 'pending'
                  ? 'Processing…'
                  : _status == 'success'
                  ? 'Payment successful'
                  : 'Payment failed',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text('Reference: ${widget.reference}', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => context.go('/home'),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    ),
  );
}
