import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Spacer(),
            const Icon(Icons.bolt, size: 56, color: Color(0xff087e68)),
            const SizedBox(height: 20),
            Text(
              'Everyday payments, made easy.',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              'Fund your wallet, buy airtime and data, and pay electricity or TV bills securely.',
            ),
            const Spacer(),
            FilledButton(
              onPressed: () => context.go('/register'),
              child: const SizedBox(
                width: double.infinity,
                child: Center(child: Text('Create account')),
              ),
            ),
            TextButton(
              onPressed: () => context.go('/login'),
              child: const SizedBox(
                width: double.infinity,
                child: Center(child: Text('I already have an account')),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
