import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import '../core/notification_service.dart';
import 'shared.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});
  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  Map<String, dynamic>? _wallet;
  List<dynamic> _transactions = [];
  bool _busy = true;
  NotificationService? _notificationService;

  Future<void> _load() async {
    try {
      final api = ref.read(apiProvider);
      _notificationService ??= NotificationService(api);
      await _notificationService!.register();
      final wallet = await api.dio.get<Map<String, dynamic>>('/wallet');
      final transactions = await api.dio.get<List<dynamic>>(
        '/transactions',
        queryParameters: {'limit': 5},
      );
      if (mounted) {
        setState(() {
          _wallet = wallet.data;
          _transactions = transactions.data ?? [];
          _busy = false;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _busy = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
    }
  }

  @override
  void dispose() {
    unawaited(_notificationService?.dispose());
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  Widget build(BuildContext context) => SecureScreen(
    child: Scaffold(
      appBar: AppBar(
        title: const Text('NaijaPay'),
        actions: [
          IconButton(
            onPressed: () => context.push('/settings'),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    color: const Color(0xff087e68),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Wallet balance',
                            style: TextStyle(color: Colors.white70),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            formatNaira(
                              _wallet?['balance_kobo']?.toString() ?? '0',
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 30,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () => context.push('/wallet'),
                              child: const Text(
                                'Fund wallet',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Pay a bill',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      _action(
                        context,
                        'Airtime',
                        Icons.phone_android,
                        'airtime',
                      ),
                      _action(context, 'Data', Icons.wifi, 'data'),
                      _action(
                        context,
                        'Electricity',
                        Icons.bolt,
                        'electricity',
                      ),
                      _action(context, 'Cable TV', Icons.tv, 'cable'),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Recent activity',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                      TextButton(
                        onPressed: () => context.push('/transactions'),
                        child: const Text('See all'),
                      ),
                    ],
                  ),
                  for (final item in _transactions)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(
                        child: Icon(Icons.receipt_long),
                      ),
                      title: Text(
                        item['description']?.toString() ??
                            item['type']?.toString() ??
                            'Transaction',
                      ),
                      subtitle: Text(item['status']?.toString() ?? ''),
                      trailing: Text(
                        formatNaira(item['amount_kobo']?.toString() ?? '0'),
                      ),
                      onTap: () =>
                          context.push('/transactions/${item['reference']}'),
                    ),
                ],
              ),
            ),
      bottomNavigationBar: NavigationBar(
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(
            icon: Icon(Icons.receipt_long),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            label: 'Settings',
          ),
        ],
        selectedIndex: 0,
        onDestinationSelected: (index) {
          if (index == 1) context.push('/transactions');
          if (index == 2) context.push('/settings');
        },
      ),
    ),
  );

  Widget _action(
    BuildContext context,
    String label,
    IconData icon,
    String category,
  ) => SizedBox(
    width: (MediaQuery.sizeOf(context).width - 52) / 2,
    child: OutlinedButton.icon(
      onPressed: () => context.push('/purchase/$category'),
      icon: Icon(icon),
      label: Text(label),
    ),
  );
}
