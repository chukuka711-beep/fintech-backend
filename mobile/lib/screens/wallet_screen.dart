import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import 'shared.dart';

class WalletScreen extends ConsumerStatefulWidget {
  const WalletScreen({super.key});
  @override
  ConsumerState<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends ConsumerState<WalletScreen> {
  Map<String, dynamic>? _wallet;
  final _amount = TextEditingController();
  final _bvn = TextEditingController();
  bool _busy = false;

  Future<void> _load() async {
    try {
      final result = await ref
          .read(apiProvider)
          .dio
          .get<Map<String, dynamic>>('/wallet');
      if (mounted) setState(() => _wallet = result.data);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _amount.dispose();
    _bvn.dispose();
    super.dispose();
  }

  Future<void> _createVirtualAccount() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(apiProvider)
          .dio
          .post('/wallet/virtual-account', data: {'bvn': _bvn.text});
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fundCard() async {
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(apiProvider)
          .dio
          .post<Map<String, dynamic>>(
            '/wallet/fund-card',
            data: {'amount': _amount.text},
          );
      final url = Uri.parse(result.data!['checkoutUrl'] as String);
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw Exception('Unable to open checkout');
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SecureScreen(
    child: Scaffold(
      appBar: AppBar(title: const Text('Fund wallet')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Bank transfer',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          if (_wallet?['account_number'] is String) ...[
            Card(
              child: Column(
                children: [
                  ListTile(
                    title: const Text('Bank'),
                    subtitle: Text(_wallet?['bank_name']?.toString() ?? ''),
                  ),
                  ListTile(
                    title: const Text('Account number'),
                    subtitle: Text(
                      _wallet?['account_number']?.toString() ?? '',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.copy),
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(
                            text: _wallet!['account_number'] as String,
                          ),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Copied')),
                          );
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            const Text(
              'Set up your dedicated account. Flutterwave requires identity verification for permanent NGN accounts.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _bvn,
              keyboardType: TextInputType.number,
              maxLength: 11,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'BVN'),
            ),
            FilledButton(
              onPressed: _busy ? null : _createVirtualAccount,
              child: Text(_busy ? 'Creating…' : 'Create dedicated account'),
            ),
          ],
          const Divider(height: 36),
          const Text(
            'Card top-up',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount (NGN)'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _busy ? null : _fundCard,
            child: const Text('Continue to secure checkout'),
          ),
        ],
      ),
    ),
  );
}
