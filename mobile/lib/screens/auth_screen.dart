import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../app.dart';
import 'shared.dart';

class AuthForm extends ConsumerStatefulWidget {
  const AuthForm({required this.register, super.key});
  final bool register;
  @override
  ConsumerState<AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends ConsumerState<AuthForm> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final api = ref.read(apiProvider);
      if (widget.register) {
        await api.dio.post(
          '/auth/register',
          data: {
            'email': _email.text.trim(),
            'fullName': _name.text.trim(),
            'phone': _phone.text.trim(),
            'password': _password.text,
          },
        );
        if (mounted) context.go('/otp', extra: _email.text.trim());
      } else {
        final response = await api.dio.post<Map<String, dynamic>>(
          '/auth/login',
          data: {'email': _email.text.trim(), 'password': _password.text},
        );
        await api.saveTokens(response.data!);
        if (mounted) context.go('/home');
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(apiError(error))));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.register ? 'Create account' : 'Log in')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Form(
          key: _form,
          child: Column(
            children: [
              if (widget.register) ...[
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Full name'),
                  validator: _required,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone number'),
                  validator: _required,
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
                validator: _required,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
                validator: (value) => (value?.length ?? 0) < 10
                    ? 'Use at least 10 characters'
                    : null,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(
                  _busy
                      ? 'Please wait…'
                      : widget.register
                      ? 'Continue'
                      : 'Log in',
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Required' : null;
}

class RegisterScreen extends StatelessWidget {
  const RegisterScreen({super.key});
  @override
  Widget build(BuildContext context) => const AuthForm(register: true);
}

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});
  @override
  Widget build(BuildContext context) => const AuthForm(register: false);
}
