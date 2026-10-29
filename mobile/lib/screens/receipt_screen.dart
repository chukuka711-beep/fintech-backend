import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import 'shared.dart';

class ReceiptScreen extends ConsumerStatefulWidget {
  const ReceiptScreen({required this.reference, super.key});
  final String reference;
  @override
  ConsumerState<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends ConsumerState<ReceiptScreen> {
  Map<String, dynamic>? _transaction;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final result = await ref
            .read(apiProvider)
            .dio
            .get<Map<String, dynamic>>(
              '/transactions/${Uri.encodeComponent(widget.reference)}',
            );
        if (mounted) setState(() => _transaction = result.data);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(apiError(error))));
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Receipt')),
    body: _transaction == null
        ? const Center(child: CircularProgressIndicator())
        : Center(
            child: Card(
              margin: const EdgeInsets.all(20),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.receipt_long, size: 40),
                    const SizedBox(height: 16),
                    Text(
                      formatNaira(_transaction!['amount_kobo'].toString()),
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    Text(_transaction!['status'].toString().toUpperCase()),
                    const SizedBox(height: 12),
                    SelectableText('Reference: ${_transaction!['reference']}'),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(
                            text:
                                'NaijaPay receipt ${_transaction!['reference']} · ${formatNaira(_transaction!['amount_kobo'].toString())} · ${_transaction!['status']}',
                          ),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Receipt copied')),
                          );
                        }
                      },
                      icon: const Icon(Icons.share),
                      label: const Text('Copy shareable receipt'),
                    ),
                  ],
                ),
              ),
            ),
          ),
  );
}
