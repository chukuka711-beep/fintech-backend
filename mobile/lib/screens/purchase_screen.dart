import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import 'shared.dart';

class PurchaseScreen extends ConsumerStatefulWidget {
  const PurchaseScreen({required this.category, super.key});
  final String category;
  @override
  ConsumerState<PurchaseScreen> createState() => _PurchaseScreenState();
}

class _PurchaseScreenState extends ConsumerState<PurchaseScreen> {
  final _biller = TextEditingController();
  final _item = TextEditingController();
  final _recipient = TextEditingController();
  final _amount = TextEditingController();
  final _pin = TextEditingController();
  String? _customerName;
  String? _selectedBiller;
  String? _selectedItem;
  List<Map<String, dynamic>> _billers = [];
  List<Map<String, dynamic>> _items = [];
  bool _busy = false;
  final String _idempotencyKey =
      '${DateTime.now().microsecondsSinceEpoch}_${math.Random.secure().nextInt(1 << 32)}';

  String get _providerCategory => switch (widget.category) {
    'airtime' => 'AIRTIME',
    'data' => 'MOBILEDATA',
    'electricity' => 'UTILITYBILLS',
    'cable' => 'CABLEBILLS',
    _ => 'AIRTIME',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadBillers());
  }

  Future<void> _loadBillers() async {
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(apiProvider)
          .dio
          .get<Map<String, dynamic>>(
            '/bills/billers',
            queryParameters: {'category': _providerCategory},
          );
      final data = result.data?['data'];
      if (data is List && mounted) {
        setState(
          () => _billers = data
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList(),
        );
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

  Future<void> _loadItems(String biller) async {
    setState(() {
      _selectedBiller = biller;
      _selectedItem = null;
      _items = [];
    });
    try {
      final result = await ref
          .read(apiProvider)
          .dio
          .get<Map<String, dynamic>>(
            '/bills/items',
            queryParameters: {'biller': biller},
          );
      final data = result.data?['data'];
      if (data is List && mounted) {
        setState(
          () => _items = data
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList(),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
    }
  }

  @override
  void dispose() {
    _biller.dispose();
    _item.dispose();
    _recipient.dispose();
    _amount.dispose();
    _pin.dispose();
    super.dispose();
  }

  String get _title => switch (widget.category) {
    'airtime' => 'Buy airtime',
    'data' => 'Buy data',
    'electricity' => 'Pay electricity',
    'cable' => 'Pay cable TV',
    _ => 'Pay a bill',
  };

  Future<void> _validate() async {
    setState(() => _busy = true);
    try {
      final result = await ref
          .read(apiProvider)
          .dio
          .post<Map<String, dynamic>>(
            '/bills/validate',
            data: {
              'itemCode': _item.text.trim(),
              'customerId': _recipient.text.trim(),
            },
          );
      final data = result.data?['data'];
      setState(
        () => _customerName = data is Map ? data['name']?.toString() : null,
      );
      if (_customerName == null) {
        throw Exception('Customer could not be verified');
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

  Future<void> _buy() async {
    setState(() => _busy = true);
    try {
      if (_pin.text.length < 4) throw Exception('Enter your transaction PIN');
      final path = widget.category == 'airtime'
          ? '/purchase/airtime'
          : widget.category == 'data'
          ? '/purchase/data'
          : '/bills/pay';
      final response = await ref
          .read(apiProvider)
          .dio
          .post<Map<String, dynamic>>(
            path,
            options: Options(headers: {'Idempotency-Key': _idempotencyKey}),
            data: {
              'category': widget.category,
              'billerCode': _biller.text.trim(),
              'itemCode': _item.text.trim(),
              'recipient': _recipient.text.trim(),
              'amount': _amount.text.trim(),
              'pin': _pin.text,
            },
          );
      if (mounted) context.go('/result/${response.data!['reference']}');
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
      appBar: AppBar(title: Text(_title)),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          DropdownButtonFormField<String>(
            initialValue: _selectedBiller,
            decoration: const InputDecoration(labelText: 'Network / biller'),
            items: _billers.map((item) {
              final code = item['biller_code']?.toString() ?? '';
              final label =
                  item['name']?.toString() ??
                  item['short_name']?.toString() ??
                  code;
              return DropdownMenuItem(value: code, child: Text(label));
            }).toList(),
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null) {
                      _biller.text = value;
                      _loadItems(value);
                    }
                  },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _selectedItem,
            decoration: const InputDecoration(labelText: 'Plan / package'),
            items: _items.map((item) {
              final code = item['item_code']?.toString() ?? '';
              final label =
                  item['short_name']?.toString() ??
                  item['name']?.toString() ??
                  code;
              return DropdownMenuItem(value: code, child: Text(label));
            }).toList(),
            onChanged: (value) {
              if (value != null) {
                setState(() => _selectedItem = value);
                _item.text = value;
              }
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _recipient,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: switch (widget.category) {
                'electricity' => 'Meter number',
                'cable' => 'Smartcard number',
                _ => 'Phone number',
              },
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount (NGN)'),
          ),
          if (widget.category == 'electricity' ||
              widget.category == 'cable') ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy ? null : _validate,
              child: const Text('Validate customer'),
            ),
            if (_customerName != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text('Customer: $_customerName'),
              ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _pin,
            keyboardType: TextInputType.number,
            obscureText: true,
            maxLength: 6,
            decoration: const InputDecoration(labelText: 'Transaction PIN'),
          ),
          FilledButton(
            onPressed: _busy ? null : _buy,
            child: Text(_busy ? 'Processing…' : 'Confirm payment'),
          ),
        ],
      ),
    ),
  );
}
