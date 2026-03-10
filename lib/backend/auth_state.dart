import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/token_manager.dart';

class PsygoAuthState extends ChangeNotifier {
  PsygoAuthState({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage() {
    // 监听 TokenManager 事件，保持状态同步
    _tokenEventSubscription = TokenManager.instance.events.listen(
      _onTokenEvent,
    );
  }

  final FlutterSecureStorage _storage;
  StreamSubscription<TokenEvent>? _tokenEventSubscription;

  static const _primaryKey = 'automate_primary_token';
  static const _refreshKey = 'automate_refresh_token';
  static const _expiresAtKey = 'automate_expires_at';
  static const _lifetimeSecondsKey = 'automate_token_lifetime_seconds';
  static const _userIdKey = 'automate_user_id';
  static const _onboardingCompletedKey = 'automate_onboarding_completed';
  static const _matrixAccessTokenKey = 'automate_matrix_access_token';
  static const _matrixUserIdKey = 'automate_matrix_user_id';
  static const _matrixDeviceIdKey = 'automate_matrix_device_id';

  static const Duration _defaultRefreshThreshold = Duration(minutes: 5);
  static const Duration _minimumRefreshThreshold = Duration(seconds: 2);

  bool _loggedIn = false;
  String? _primaryToken;
  String? _refreshToken;
  DateTime? _expiresAt;
  int? _tokenLifetimeSeconds;
  String? _userId;
  bool _onboardingCompleted = true;
  String? _matrixAccessToken;
  String? _matrixUserId;
  String? _matrixDeviceId;

  bool get isLoggedIn => _loggedIn;
  String? get primaryToken => _primaryToken;
  String? get refreshToken => _refreshToken;
  DateTime? get expiresAt => _expiresAt;
  String? get userId => _userId;
  bool get onboardingCompleted => _onboardingCompleted;
  String? get matrixAccessToken => _matrixAccessToken;
  String? get matrixUserId => _matrixUserId;
  String? get matrixDeviceId => _matrixDeviceId;

  /// Check if token is expired
  /// Returns false if expiresAt is null (let server validate)
  bool get isTokenExpired {
    if (_expiresAt == null) return false;
    return DateTime.now().isAfter(_expiresAt!);
  }

  /// Check if token is expiring soon (within 5 minutes)
  bool get isTokenExpiringSoon {
    if (_expiresAt == null) return true;
    final timeUntilExpiry = _expiresAt!.difference(DateTime.now());
    return timeUntilExpiry <= _resolveRefreshThreshold();
  }

  /// Check if we have a valid (non-expired) token
  bool get hasValidToken {
    return _primaryToken != null &&
        _primaryToken!.isNotEmpty &&
        !isTokenExpired;
  }

  Future<void> load() async {
    _primaryToken = await _storage.read(key: _primaryKey);
    _refreshToken = await _storage.read(key: _refreshKey);
    final expiresAtStr = await _storage.read(key: _expiresAtKey);
    _expiresAt = expiresAtStr != null
        ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(expiresAtStr) ?? 0)
        : null;
    _tokenLifetimeSeconds = int.tryParse(
      await _storage.read(key: _lifetimeSecondsKey) ?? '',
    );
    _userId = await _storage.read(key: _userIdKey);
    final onboardingCompletedStr = await _storage.read(
      key: _onboardingCompletedKey,
    );
    _onboardingCompleted = onboardingCompletedStr == null
        ? true
        : onboardingCompletedStr.toLowerCase() == 'true';
    _matrixAccessToken = await _storage.read(key: _matrixAccessTokenKey);
    _matrixUserId = await _storage.read(key: _matrixUserIdKey);
    _matrixDeviceId = await _storage.read(key: _matrixDeviceIdKey);
    _loggedIn = _primaryToken != null && _primaryToken!.isNotEmpty;
    notifyListeners();
  }

  Future<void> save({
    required String primaryToken,
    required String userId,
    bool onboardingCompleted = true,
    String? refreshToken,
    int? expiresIn,
    String? matrixAccessToken,
    String? matrixUserId,
    String? matrixDeviceId,
  }) async {
    _primaryToken = primaryToken;
    _userId = userId;
    _onboardingCompleted = onboardingCompleted;
    _loggedIn = true;

    // Handle refresh token
    if (refreshToken != null) {
      _refreshToken = refreshToken;
      await _storage.write(key: _refreshKey, value: refreshToken);
    }

    // Handle token expiry
    if (expiresIn != null) {
      _tokenLifetimeSeconds = expiresIn;
      _expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
      await _storage.write(
        key: _expiresAtKey,
        value: _expiresAt!.millisecondsSinceEpoch.toString(),
      );
      await _storage.write(
        key: _lifetimeSecondsKey,
        value: expiresIn.toString(),
      );
    }

    // Handle Matrix access token
    if (matrixAccessToken != null) {
      _matrixAccessToken = matrixAccessToken;
      await _storage.write(
        key: _matrixAccessTokenKey,
        value: matrixAccessToken,
      );
    }

    // Handle Matrix user ID
    if (matrixUserId != null) {
      _matrixUserId = matrixUserId;
      await _storage.write(key: _matrixUserIdKey, value: matrixUserId);
    }

    // Handle Matrix device ID (CRITICAL for encryption!)
    if (matrixDeviceId != null) {
      _matrixDeviceId = matrixDeviceId;
      await _storage.write(key: _matrixDeviceIdKey, value: matrixDeviceId);
    }

    await _storage.write(key: _primaryKey, value: primaryToken);
    await _storage.write(key: _userIdKey, value: userId);
    await _storage.write(
      key: _onboardingCompletedKey,
      value: onboardingCompleted.toString(),
    );
    notifyListeners();
  }

  /// Update access token after refresh
  /// 通过 TokenManager 更新，确保状态一致
  Future<void> updateAccessToken(
    String accessToken,
    int expiresIn, {
    String? refreshToken,
  }) async {
    // 通过 TokenManager 更新，会触发 refreshed 事件
    await TokenManager.instance.updateAccessToken(
      accessToken,
      expiresIn,
      refreshToken: refreshToken,
    );
    // 同步更新内存状态（避免等待事件回调）
    _primaryToken = accessToken;
    _tokenLifetimeSeconds = expiresIn;
    _expiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    if (refreshToken != null && refreshToken.isNotEmpty) {
      _refreshToken = refreshToken;
    }
    notifyListeners();
  }

  Future<void> markLoggedOut() async {
    _clearInMemoryState();
    // 通过 TokenManager 清除 token（会触发 loggedOut 事件）
    // 使用 clearTokens 而非 logout 避免重复触发事件
    await TokenManager.instance.clearTokens();
    // 清除 Matrix 和其他状态
    await Future.wait([
      _storage.delete(key: _userIdKey),
      _storage.delete(key: _onboardingCompletedKey),
      _storage.delete(key: _matrixAccessTokenKey),
      _storage.delete(key: _matrixUserIdKey),
      _storage.delete(key: _matrixDeviceIdKey),
      _storage.delete(key: _lifetimeSecondsKey),
    ]);
    notifyListeners();
  }

  /// 标记用户完成新手引导
  Future<void> markOnboardingCompleted() async {
    _onboardingCompleted = true;
    await _storage.write(key: _onboardingCompletedKey, value: 'true');
    notifyListeners();
  }

  /// 处理 TokenManager 事件
  void _onTokenEvent(TokenEvent event) {
    switch (event) {
      case TokenEvent.refreshed:
        // Token 刷新成功，重新加载状态
        load();
        break;
      case TokenEvent.expired:
      case TokenEvent.loggedOut:
        // Token 过期或登出，清除状态
        _clearInMemoryState();
        notifyListeners();
        break;
    }
  }

  /// 清除内存中的状态（不操作存储，存储由 TokenManager 处理）
  void _clearInMemoryState() {
    _primaryToken = null;
    _refreshToken = null;
    _expiresAt = null;
    _tokenLifetimeSeconds = null;
    _userId = null;
    _onboardingCompleted = false;
    _matrixAccessToken = null;
    _matrixUserId = null;
    _matrixDeviceId = null;
    _loggedIn = false;
  }

  @override
  void dispose() {
    _tokenEventSubscription?.cancel();
    super.dispose();
  }

  Duration _resolveRefreshThreshold() {
    final lifetimeSeconds = _tokenLifetimeSeconds;
    if (lifetimeSeconds == null || lifetimeSeconds <= 0) {
      return _defaultRefreshThreshold;
    }

    final lifetime = Duration(seconds: lifetimeSeconds);
    if (lifetime <= const Duration(seconds: 30)) {
      return _minimumRefreshThreshold;
    }
    if (lifetime <= const Duration(minutes: 2)) {
      return const Duration(seconds: 10);
    }

    final adaptive = Duration(seconds: lifetime.inSeconds ~/ 5);
    if (adaptive > _defaultRefreshThreshold) {
      return _defaultRefreshThreshold;
    }
    if (adaptive < _minimumRefreshThreshold) {
      return _minimumRefreshThreshold;
    }
    return adaptive;
  }
}
