import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:psygo/core/config.dart';
import 'package:psygo/core/token_manager.dart';
import 'package:psygo/utils/custom_http_client.dart';

class PushStateReporter {
  PushStateReporter._();

  static final PushStateReporter instance = PushStateReporter._();

  static const Duration _debounceDuration = Duration(milliseconds: 300);
  static const Duration _heartbeatInterval = Duration(seconds: 30);

  final http.Client _httpClient = CustomHttpClient.createHTTPClient();

  Timer? _debounceTimer;
  Timer? _heartbeatTimer;
  _PushState? _pendingState;
  _PushState? _lastSentState;

  void updateState({
    required bool isForeground,
    required String? activeRoomId,
    required String? matrixUserId,
    required String? deviceId,
    required String? pushKey,
  }) {
    if (matrixUserId == null || matrixUserId.isEmpty) return;
    if (deviceId == null || deviceId.isEmpty) return;
    if (pushKey == null || pushKey.isEmpty) return;

    final state = _PushState(
      matrixUserId: matrixUserId,
      deviceId: deviceId,
      pushKey: pushKey,
      isForeground: isForeground,
      activeRoomId: isForeground ? activeRoomId : null,
    );

    _scheduleHeartbeat(state);

    if (_lastSentState?.isSame(state) == true) {
      return;
    }

    _pendingState = state;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDuration, () {
      _flushPendingState();
    });
  }

  void stop() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _scheduleHeartbeat(_PushState state) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    if (!state.isForeground) {
      return;
    }

    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      _sendState(state, isHeartbeat: true);
    });
  }

  Future<void> _flushPendingState() async {
    final state = _pendingState;
    if (state == null) return;
    _pendingState = null;
    await _sendState(state);
  }

  Future<void> _sendState(_PushState state, {bool isHeartbeat = false}) async {
    if (!isHeartbeat && _lastSentState?.isSame(state) == true) {
      return;
    }

    final uri = Uri.parse('${PsygoConfig.baseUrl}/api/push/status');
    final body = <String, dynamic>{
      'matrix_user_id': state.matrixUserId,
      'device_id': state.deviceId,
      'push_key': state.pushKey,
      'app_state': state.isForeground ? 'foreground' : 'background',
      'active_room_id': state.activeRoomId,
      'client_ts': DateTime.now().toUtc().toIso8601String(),
    };

    final headers = <String, String>{
      'Content-Type': 'application/json',
    };

    try {
      final token = await TokenManager.instance.getAccessToken(autoRefresh: true);
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    } catch (e) {
      Logs().w('[PushState] Unable to read access token', e);
    }

    try {
      final response = await _httpClient
          .post(uri, headers: headers, body: jsonEncode(body))
          .timeout(PsygoConfig.receiveTimeout);

      if (response.statusCode == 200) {
        _lastSentState = state;
        Logs().d('[PushState] State reported: ${state.debugLabel}');
      } else {
        Logs().w('[PushState] Report failed: ${response.statusCode}');
      }
    } catch (e) {
      Logs().w('[PushState] Report exception', e);
    }
  }
}

class _PushState {
  final String matrixUserId;
  final String deviceId;
  final String pushKey;
  final bool isForeground;
  final String? activeRoomId;

  _PushState({
    required this.matrixUserId,
    required this.deviceId,
    required this.pushKey,
    required this.isForeground,
    required this.activeRoomId,
  });

  bool isSame(_PushState other) {
    return matrixUserId == other.matrixUserId &&
        deviceId == other.deviceId &&
        pushKey == other.pushKey &&
        isForeground == other.isForeground &&
        activeRoomId == other.activeRoomId;
  }

  String get debugLabel =>
      'user=$matrixUserId device=$deviceId foreground=$isForeground room=$activeRoomId';
}
