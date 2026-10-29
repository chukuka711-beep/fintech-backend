import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const secureStorage = FlutterSecureStorage();

class ApiClient {
  static const _configuredApiBaseUrl = String.fromEnvironment('API_BASE_URL');

  ApiClient() {
    dio = Dio(
      BaseOptions(
        baseUrl: _configuredApiBaseUrl.isNotEmpty
            ? _configuredApiBaseUrl
            : kIsWeb
            ? 'http://localhost:3000'
            : 'http://10.0.2.2:3000',
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 20),
        headers: {'Content-Type': 'application/json'},
      ),
    );
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await secureStorage.read(key: 'accessToken');
          if (token != null) options.headers['Authorization'] = 'Bearer $token';
          handler.next(options);
        },
        onError: (error, handler) async {
          if (error.response?.statusCode != 401 ||
              error.requestOptions.extra['retried'] == true ||
              error.requestOptions.path.startsWith('/auth/')) {
            handler.next(error);
            return;
          }
          final refreshToken = await secureStorage.read(key: 'refreshToken');
          if (refreshToken == null) {
            handler.next(error);
            return;
          }
          try {
            final response =
                await Dio(BaseOptions(baseUrl: dio.options.baseUrl))
                    .post<Map<String, dynamic>>(
                      '/auth/refresh',
                      data: {'refreshToken': refreshToken},
                    );
            await saveTokens(response.data!);
            final retry = error.requestOptions;
            retry.extra['retried'] = true;
            retry.headers['Authorization'] =
                'Bearer ${response.data!['accessToken']}';
            handler.resolve(await dio.fetch(retry));
          } on DioException {
            await clearTokens();
            handler.next(error);
          }
        },
      ),
    );
  }

  late final Dio dio;

  Future<void> saveTokens(Map<String, dynamic> tokens) async {
    await secureStorage.write(
      key: 'accessToken',
      value: tokens['accessToken'] as String,
    );
    await secureStorage.write(
      key: 'refreshToken',
      value: tokens['refreshToken'] as String,
    );
  }

  Future<void> clearTokens() async {
    await secureStorage.delete(key: 'accessToken');
    await secureStorage.delete(key: 'refreshToken');
  }
}
