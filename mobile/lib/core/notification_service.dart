import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';

const _firebaseEnabled = bool.fromEnvironment(
  'FIREBASE_ENABLED',
  defaultValue: false,
);

class NotificationService {
  NotificationService(this.api);

  final ApiClient api;
  StreamSubscription<String>? _tokenSubscription;
  bool _registered = false;

  Future<void> register() async {
    if (!_firebaseEnabled ||
        _registered ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return;
    }
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();
    _tokenSubscription ??= messaging.onRegistered.listen((value) {
      unawaited(
        _save(value).catchError((_) {
          debugPrint('Unable to register refreshed push token');
        }),
      );
    });
    await messaging.register();
    _registered = true;
  }

  Future<void> _save(String token) => api.dio.put(
    '/me/push-token',
    data: {
      'token': token,
      'platform': defaultTargetPlatform == TargetPlatform.iOS
          ? 'ios'
          : 'android',
    },
  );

  Future<void> dispose() async {
    await _tokenSubscription?.cancel();
  }
}
