import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import 'shared.dart';

class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});
  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  List<dynamic> _items = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final result = await ref
            .read(apiProvider)
            .dio
            .get<List<dynamic>>('/transactions');
        if (mounted) setState(() => _items = result.data ?? []);
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
    appBar: AppBar(title: const Text('Transactions')),
    body: ListView(
      children: [
        for (final item in _items)
          ListTile(
            title: Text(
              item['description']?.toString() ??
                  item['type']?.toString() ??
                  'Transaction',
            ),
            subtitle: Text('${item['status']} · ${item['reference']}'),
            trailing: Text(formatNaira(item['amount_kobo']?.toString() ?? '0')),
            onTap: () => context.push('/transactions/${item['reference']}'),
          ),
      ],
    ),
  );
}
