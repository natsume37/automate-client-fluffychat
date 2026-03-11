/// 统一的 Token 管理器（单例）
/// 负责 token 的存储、刷新和状态通知
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'auth_device_identity.dart';
import 'config.dart';
import 'token_refresh_lock.dart';
import '../utils/custom_http_client.dart';

/// Token 状态变化事件
enum TokenEvent {
  refreshed, // Token 刷新成功
  expired, // Token 过期，需要重新登录
  loggedOut, // 用户主动登出或被强制登出
}

/// 统一的 Token 管理器
/// 所有需要 token 的地方都应该通过此管理器获取
class TokenManager {
  static TokenManager? _instance;
  static TokenManager get instance => _instance ??= TokenManager._();

  TokenManager._();

  static const _storage = FlutterSecureStorage();

  // Storage keys（与 PsygoAuthState 保持一致）
  static const String _primaryKey = 'automate_primary_token';
  static const String _refreshKey = 'automate_refresh_token';
  static const String _expiresAtKey = 'automate_expires_at';
  static const String _userIdKey = 'automate_user_id';

  // Token 过期前刷新阈值（5 分钟）
  static const Duration _refreshThreshold = Duration(minutes: 5);

  // HTTP client for refresh requests
  http.Client? _httpClient;
  http.Client get httpClient =>
      _httpClient ??= CustomHttpClient.createHTTPClient();

  // 事件流控制器
  final _eventController = StreamController<TokenEvent>.broadcast();

  /// Token 状态变化事件流
  Stream<TokenEvent> get events => _eventController.stream;

  /// 检查是否有有效的 token
  Future<bool> hasValidToken() async {
    final token = await _storage.read(key: _primaryKey);
    if (token == null || token.isEmpty) return false;

    final expiresAtStr = await _storage.read(key: _expiresAtKey);
    if (expiresAtStr == null) return true; // 无过期时间，让服务端验证

    final timestamp = int.tryParse(expiresAtStr);
    if (timestamp == null) return true;

    final expiresAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return DateTime.now().isBefore(expiresAt);
  }

  /// 检查 token 是否即将过期（5 分钟内）
  Future<bool> isTokenExpiringSoon() async {
    final expiresAtStr = await _storage.read(key: _expiresAtKey);
    if (expiresAtStr == null) return true; // 无过期时间，尝试刷新

    final timestamp = int.tryParse(expiresAtStr);
    if (timestamp == null) return true;

    final expiresAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final timeUntilExpiry = expiresAt.difference(DateTime.now());
    return timeUntilExpiry <= _refreshThreshold;
  }

  /// 获取当前 Access Token
  /// 如果 token 即将过期，会自动尝试刷新
  Future<String?> getAccessToken({bool autoRefresh = true}) async {
    if (autoRefresh && await isTokenExpiringSoon()) {
      final refreshToken = await _storage.read(key: _refreshKey);
      if (refreshToken != null && refreshToken.isNotEmpty) {
        await refreshAccessToken();
      }
    }
    return _storage.read(key: _primaryKey);
  }

  /// 获取 Refresh Token
  Future<String?> getRefreshToken() async {
    return _storage.read(key: _refreshKey);
  }

  /// 获取用户 ID
  Future<String?> getUserId() async {
    return _storage.read(key: _userIdKey);
  }

  /// 刷新 Access Token
  /// 返回 true 表示刷新成功，false 表示失败（需要重新登录）
  Future<bool> refreshAccessToken() async {
    return TokenRefreshLock.run(() async {
      final refreshToken = await _storage.read(key: _refreshKey);
      if (refreshToken == null || refreshToken.isEmpty) {
        Logs().e('[TokenManager] No refresh token available');
        _eventController.add(TokenEvent.expired);
        throw Exception('No refresh token available');
      }

      try {
        final authDevice = await AuthDeviceIdentity.current();
        final uri = Uri.parse('${PsygoConfig.baseUrl}/api/auth/refresh-token');
        final response = await httpClient
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({
                'refresh_token': refreshToken,
                'auth_device_id': authDevice.authDeviceId,
                'auth_device_platform': authDevice.authDevicePlatform,
              }),
            )
            .timeout(PsygoConfig.receiveTimeout);

        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final code = json['code'] as int? ?? -1;

        if (code != 0) {
          final errorMsg = json['message'] as String? ?? 'Token refresh failed';
          Logs().e(
              '[TokenManager] Token refresh failed: code=$code, msg=$errorMsg');

          // 10002/10003 表示认证失败，需要重新登录
          if (code == 10002 || code == 10003) {
            await clearTokens();
            _eventController.add(TokenEvent.expired);
          }
          throw Exception(errorMsg);
        }

        final data = json['data'] as Map<String, dynamic>;
        final newAccessToken = data['access_token'] as String;
        final expiresIn = data['expires_in'] as int;
        final newRefreshToken = data['refresh_token'] as String?;

        // 更新 tokens
        final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
        final writes = <Future<void>>[
          _storage.write(key: _primaryKey, value: newAccessToken),
          _storage.write(
              key: _expiresAtKey,
              value: expiresAt.millisecondsSinceEpoch.toString()),
        ];
        // 服务端返回新的 refresh token（一次性）
        if (newRefreshToken != null && newRefreshToken.isNotEmpty) {
          writes.add(_storage.write(key: _refreshKey, value: newRefreshToken));
        }
        await Future.wait(writes);

        Logs().i('[TokenManager] Access token refreshed successfully');
        _eventController.add(TokenEvent.refreshed);
      } catch (e) {
        Logs().e('[TokenManager] Token refresh error: $e');
        // 网络错误等不清除 token，让用户重试
        if (e.toString().contains('10002') || e.toString().contains('10003')) {
          await clearTokens();
          _eventController.add(TokenEvent.expired);
        }
        rethrow;
      }
    });
  }

  /// 保存登录后的 tokens
  Future<void> saveTokens({
    required String accessToken,
    required String userId,
    String? refreshToken,
    int? expiresIn,
  }) async {
    final writes = <Future<void>>[
      _storage.write(key: _primaryKey, value: accessToken),
      _storage.write(key: _userIdKey, value: userId),
    ];

    if (refreshToken != null && refreshToken.isNotEmpty) {
      writes.add(_storage.write(key: _refreshKey, value: refreshToken));
    }

    if (expiresIn != null) {
      final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
      writes.add(_storage.write(
          key: _expiresAtKey,
          value: expiresAt.millisecondsSinceEpoch.toString()));
    }

    await Future.wait(writes);
  }

  /// 更新 Access Token（刷新后调用）
  Future<void> updateAccessToken(String accessToken, int expiresIn,
      {String? refreshToken}) async {
    final expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    final writes = <Future<void>>[
      _storage.write(key: _primaryKey, value: accessToken),
      _storage.write(
          key: _expiresAtKey,
          value: expiresAt.millisecondsSinceEpoch.toString()),
    ];
    if (refreshToken != null && refreshToken.isNotEmpty) {
      writes.add(_storage.write(key: _refreshKey, value: refreshToken));
    }
    await Future.wait(writes);
    _eventController.add(TokenEvent.refreshed);
  }

  /// 清除所有 tokens
  Future<void> clearTokens() async {
    await Future.wait([
      _storage.delete(key: _primaryKey),
      _storage.delete(key: _refreshKey),
      _storage.delete(key: _expiresAtKey),
      _storage.delete(key: _userIdKey),
    ]);
  }

  /// 标记登出（清除 tokens 并发送事件）
  Future<void> logout() async {
    await clearTokens();
    _eventController.add(TokenEvent.loggedOut);
  }

  /// 释放资源
  void dispose() {
    _httpClient?.close();
    _eventController.close();
  }
}
