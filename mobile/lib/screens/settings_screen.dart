import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';

import '../app.dart';
import '../core/api_client.dart';
import 'shared.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Map<String, dynamic> _notifications = {
    'push_enabled': true,
    'email_enabled': true,
    'transaction_alerts': true,
  };
  bool _biometricsEnabled = false;
  bool _busy = false;

  Future<void> _load() async {
    try {
      final result = await ref
          .read(apiProvider)
          .dio
          .get<Map<String, dynamic>>('/me/notification-settings');
      final biometrics =
          await secureStorage.read(key: 'biometricsEnabled') == 'true';
      if (mounted) {
        setState(() {
          _notifications = result.data ?? _notifications;
          _biometricsEnabled = biometrics;
        });
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
    }
  }

  Future<void> _setBiometrics(bool enabled) async {
    if (enabled) {
      try {
        final auth = LocalAuthentication();
        if (!await auth.isDeviceSupported() || !await auth.canCheckBiometrics) {
          throw Exception('Biometrics are not available on this device');
        }
        if (!await auth.authenticate(
          localizedReason: 'Enable biometric wallet unlock',
          biometricOnly: true,
        )) {
          return;
        }
      } on PlatformException catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error.message ?? 'Biometric authentication failed'),
            ),
          );
        }
        return;
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error.toString().replaceFirst('Exception: ', '')),
            ),
          );
        }
        return;
      }
    }
    await secureStorage.write(
      key: 'biometricsEnabled',
      value: enabled.toString(),
    );
    if (mounted) setState(() => _biometricsEnabled = enabled);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _setNotification(String key, bool value) async {
    final updated = Map<String, dynamic>.from(_notifications)..[key] = value;
    setState(() => _notifications = updated);
    try {
      await ref
          .read(apiProvider)
          .dio
          .put(
            '/me/notification-settings',
            data: {
              'pushEnabled': updated['push_enabled'],
              'emailEnabled': updated['email_enabled'],
              'transactionAlerts': updated['transaction_alerts'],
            },
          );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
      await _load();
    }
  }

  Future<void> _logout() async {
    final refresh = await secureStorage.read(key: 'refreshToken');
    try {
      await ref
          .read(apiProvider)
          .dio
          .post('/auth/logout', data: {'refreshToken': refresh});
    } catch (_) {
      // Clear local credentials even if the server is temporarily unavailable.
    }
    await ref.read(apiProvider).clearTokens();
    if (mounted) context.go('/login');
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'This cannot be undone. Your account can only be deleted after the wallet is empty and transactions are complete.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).dio.delete('/me');
      await ref.read(apiProvider).clearTokens();
      if (mounted) context.go('/onboarding');
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(
      children: [
        const ListTile(
          title: Text('Account', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        ListTile(
          leading: const Icon(Icons.person_outline),
          title: const Text('Profile'),
          onTap: () => _editProfile(context),
        ),
        const ListTile(
          title: Text(
            'Security',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.lock_outline),
          title: const Text('Change PIN'),
          onTap: () => _changePin(context),
        ),
        ListTile(
          leading: const Icon(Icons.password_outlined),
          title: const Text('Change password'),
          onTap: () => _changePassword(context),
        ),
        SwitchListTile(
          value: _biometricsEnabled,
          title: const Text('Biometric wallet unlock'),
          onChanged: _setBiometrics,
        ),
        ListTile(
          leading: const Icon(Icons.devices),
          title: const Text('Active sessions'),
          onTap: () => _showSessions(context),
        ),
        const ListTile(
          title: Text(
            'Notifications',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        SwitchListTile(
          value: _notifications['push_enabled'] == true,
          title: const Text('Push notifications'),
          onChanged: (value) => _setNotification('push_enabled', value),
        ),
        SwitchListTile(
          value: _notifications['email_enabled'] == true,
          title: const Text('Email notifications'),
          onChanged: (value) => _setNotification('email_enabled', value),
        ),
        SwitchListTile(
          value: _notifications['transaction_alerts'] == true,
          title: const Text('Transaction alerts'),
          onChanged: (value) => _setNotification('transaction_alerts', value),
        ),
        const ListTile(
          title: Text(
            'Preferences',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.people_outline),
          title: const Text('Beneficiaries'),
          onTap: () => _showBeneficiaries(context),
        ),
        const ListTile(
          title: Text(
            'Limits, support and legal',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.help_outline),
          title: const Text('Support'),
        ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Log out'),
          onTap: _logout,
        ),
        ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('Delete account'),
          onTap: _busy ? null : _deleteAccount,
        ),
      ],
    ),
  );

  Future<void> _changePin(BuildContext context) async {
    final pin = TextEditingController();
    final protectionEnabled = await ScreenshotProtection.setEnabled(true);
    if (!protectionEnabled && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Screenshot blocking is unavailable on this device.'),
        ),
      );
    }
    if (!context.mounted) {
      await ScreenshotProtection.setEnabled(false);
      pin.dispose();
      return;
    }
    String? newPin;
    try {
      newPin = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Set transaction PIN'),
          content: TextField(
            controller: pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(labelText: '4 to 6 digits'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, pin.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
    } finally {
      await ScreenshotProtection.setEnabled(false);
    }
    pin.dispose();
    if (newPin == null) return;
    try {
      await ref.read(apiProvider).dio.post('/me/pin', data: {'pin': newPin});
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('PIN updated')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
    }
  }

  Future<void> _editProfile(BuildContext context) async {
    late Response<Map<String, dynamic>> result;
    try {
      result = await ref.read(apiProvider).dio.get<Map<String, dynamic>>('/me');
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
      return;
    }
    if (!context.mounted) return;
    final name = TextEditingController(
      text: result.data?['full_name']?.toString(),
    );
    final phone = TextEditingController(
      text: result.data?['phone']?.toString(),
    );
    final values = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Full name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Phone'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, [name.text, phone.text]),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (values == null) {
      name.dispose();
      phone.dispose();
      return;
    }
    try {
      await ref
          .read(apiProvider)
          .dio
          .patch('/me', data: {'fullName': values[0], 'phone': values[1]});
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
    } finally {
      name.dispose();
      phone.dispose();
    }
  }

  Future<void> _changePassword(BuildContext context) async {
    final current = TextEditingController();
    final next = TextEditingController();
    final values = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Change password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: current,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Current password'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: next,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'New password'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, [current.text, next.text]),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (values == null) {
      current.dispose();
      next.dispose();
      return;
    }
    try {
      await ref
          .read(apiProvider)
          .dio
          .post(
            '/me/password',
            data: {'currentPassword': values[0], 'newPassword': values[1]},
          );
      await ref.read(apiProvider).clearTokens();
      if (context.mounted) context.go('/login');
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
    } finally {
      current.dispose();
      next.dispose();
    }
  }

  Future<void> _showSessions(BuildContext context) async {
    try {
      final response = await ref
          .read(apiProvider)
          .dio
          .get<List<dynamic>>('/me/sessions');
      if (!context.mounted) return;
      showModalBottomSheet<void>(
        context: context,
        builder: (context) => ListView(
          shrinkWrap: true,
          children: [
            for (final session in response.data ?? [])
              ListTile(
                title: Text(session['device_name']?.toString() ?? 'Device'),
                subtitle: Text(session['last_seen_at']?.toString() ?? ''),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    await ref
                        .read(apiProvider)
                        .dio
                        .delete('/me/sessions/${session['id']}');
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
              ),
          ],
        ),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
    }
  }

  Future<void> _showBeneficiaries(BuildContext context) async {
    try {
      final response = await ref
          .read(apiProvider)
          .dio
          .get<List<dynamic>>('/beneficiaries');
      if (!context.mounted) return;
      showModalBottomSheet<void>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final item in response.data ?? [])
                ListTile(
                  title: Text(item['name']?.toString() ?? ''),
                  subtitle: Text(item['recipient']?.toString() ?? ''),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      await ref
                          .read(apiProvider)
                          .dio
                          .delete('/beneficiaries/${item['id']}');
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Add beneficiary'),
                onTap: () {
                  Navigator.pop(context);
                  _addBeneficiary(this.context);
                },
              ),
            ],
          ),
        ),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
    }
  }

  Future<void> _addBeneficiary(BuildContext context) async {
    final name = TextEditingController();
    final recipient = TextEditingController();
    final category = TextEditingController();
    final values = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add beneficiary'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            TextField(
              controller: category,
              decoration: const InputDecoration(labelText: 'Category'),
            ),
            TextField(
              controller: recipient,
              decoration: const InputDecoration(
                labelText: 'Phone, meter or smartcard',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, [
              name.text,
              category.text,
              recipient.text,
            ]),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (values == null) {
      name.dispose();
      recipient.dispose();
      category.dispose();
      return;
    }
    try {
      await ref
          .read(apiProvider)
          .dio
          .post(
            '/beneficiaries',
            data: {
              'name': values[0],
              'category': values[1],
              'recipient': values[2],
            },
          );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
    } finally {
      name.dispose();
      recipient.dispose();
      category.dispose();
    }
  }
}
