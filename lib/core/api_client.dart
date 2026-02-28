/// Automate API HTTP 客户端（通用版）
/// 负责与 Automate Assistant 后端通信
/// 使用 TokenManager 统一管理 token
library;

import 'dart:convert';
import 'dart:ui';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'config.dart';
import 'token_manager.dart';
import '../utils/custom_http_client.dart';

/// API 响应包装
class ApiResponse<T> {
  final int code;
  final T? data;
  final String message;

  ApiResponse({
    required this.code,
    this.data,
    required this.message,
  });

  bool get isSuccess => code == 0;

  factory ApiResponse.fromJson(
    Map<String, dynamic> json,
    T Function(dynamic)? fromJsonT,
  ) {
    return ApiResponse(
      code: json['code'] as int,
      data: fromJsonT != null && json['data'] != null
          ? fromJsonT(json['data'])
          : null,
      message: json['message'] as String? ?? '',
    );
  }
}

/// API 异常
class ApiException implements Exception {
  final int code;
  final String message;

  ApiException(this.code, this.message);

  @override
  String toString() => 'ApiException(code: $code, message: $message)';
}

/// Automate API 客户端（通用版，用于 Repository）
/// 使用 TokenManager 统一管理 token
class PsygoApiClient {
  final http.Client _httpClient;
  final TokenManager _tokenManager;

  PsygoApiClient({
    http.Client? httpClient,
    TokenManager? tokenManager,
  })  : _httpClient = httpClient ?? CustomHttpClient.createHTTPClient(),
        _tokenManager = tokenManager ?? TokenManager.instance;

  /// GET 请求
  Future<ApiResponse<T>> get<T>(
    String path, {
    Map<String, String>? queryParameters,
    T Function(dynamic)? fromJsonT,
    bool requiresAuth = true,
    bool noCache = false,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse(PsygoConfig.baseUrl + path).replace(
      queryParameters: queryParameters,
    );

    Future<http.Response> doRequest() async {
      final merged = await _buildHeaders(
        requiresAuth,
        noCache: noCache,
      );
      if (headers != null) {
        merged.addAll(headers);
      }
      return _httpClient
          .get(uri, headers: merged)
          .timeout(PsygoConfig.receiveTimeout);
    }

    final response = await doRequest();
    return _handleResponse<T>(
      response,
      fromJsonT,
      retryRequest: requiresAuth ? doRequest : null,
    );
  }

  /// POST 请求
  Future<ApiResponse<T>> post<T>(
    String path, {
    Map<String, dynamic>? body,
    T Function(dynamic)? fromJsonT,
    bool requiresAuth = true,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse(PsygoConfig.baseUrl + path);
    final encodedBody = body != null ? jsonEncode(body) : null;

    Future<http.Response> doRequest() async {
      final merged = await _buildHeaders(requiresAuth);
      if (headers != null) {
        merged.addAll(headers);
      }
      return _httpClient
          .post(uri, headers: merged, body: encodedBody)
          .timeout(PsygoConfig.receiveTimeout);
    }

    final response = await doRequest();
    return _handleResponse<T>(
      response,
      fromJsonT,
      retryRequest: requiresAuth ? doRequest : null,
    );
  }

  /// PUT 请求
  Future<ApiResponse<T>> put<T>(
    String path, {
    Map<String, dynamic>? body,
    T Function(dynamic)? fromJsonT,
    bool requiresAuth = true,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse(PsygoConfig.baseUrl + path);
    final encodedBody = body != null ? jsonEncode(body) : null;

    Future<http.Response> doRequest() async {
      final merged = await _buildHeaders(requiresAuth);
      if (headers != null) {
        merged.addAll(headers);
      }
      return _httpClient
          .put(uri, headers: merged, body: encodedBody)
          .timeout(PsygoConfig.receiveTimeout);
    }

    final response = await doRequest();
    return _handleResponse<T>(
      response,
      fromJsonT,
      retryRequest: requiresAuth ? doRequest : null,
    );
  }

  /// DELETE 请求
  Future<ApiResponse<T>> delete<T>(
    String path, {
    Map<String, String>? queryParameters,
    T Function(dynamic)? fromJsonT,
    bool requiresAuth = true,
    Map<String, String>? headers,
  }) async {
    final uri = Uri.parse(PsygoConfig.baseUrl + path).replace(
      queryParameters: queryParameters,
    );

    Future<http.Response> doRequest() async {
      final merged = await _buildHeaders(requiresAuth);
      if (headers != null) {
        merged.addAll(headers);
      }
      return _httpClient
          .delete(uri, headers: merged)
          .timeout(PsygoConfig.receiveTimeout);
    }

    final response = await doRequest();
    return _handleResponse<T>(
      response,
      fromJsonT,
      retryRequest: requiresAuth ? doRequest : null,
    );
  }

  /// 构建请求头
  Future<Map<String, String>> _buildHeaders(
    bool requiresAuth, {
    bool noCache = false,
  }) async {
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept-Language': PlatformDispatcher.instance.locale.languageCode,
    };

    if (noCache) {
      headers['Cache-Control'] = 'no-cache, no-store, max-age=0';
      headers['Pragma'] = 'no-cache';
      headers['Expires'] = '0';
    }

    if (requiresAuth) {
      // 使用 TokenManager 获取 token（自动处理刷新）
      final accessToken = await _tokenManager.getAccessToken(autoRefresh: true);
      if (accessToken == null || accessToken.isEmpty) {
        throw ApiException(7, 'No access token available');
      }
      headers['Authorization'] = 'Bearer $accessToken';
    }

    return headers;
  }

  /// 处理响应，支持 token 失效时自动重试
  Future<ApiResponse<T>> _handleResponse<T>(
    http.Response response,
    T Function(dynamic)? fromJsonT, {
    Future<http.Response> Function()? retryRequest,
    bool isRetry = false,
  }) async {
    // 解析 JSON
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      throw ApiException(-1, 'Invalid JSON response: ${response.body}');
    }

    final apiResponse = ApiResponse<T>.fromJson(json, fromJsonT);

    // 处理业务错误
    if (!apiResponse.isSuccess) {
      // Token 失效（10002/10003）- 尝试刷新后重试
      if ((apiResponse.code == 10002 || apiResponse.code == 10003) &&
          !isRetry &&
          retryRequest != null) {
        Logs().w(
            '[AutomateApi] Token invalid (code=${apiResponse.code}), attempting refresh...');

        try {
          final refreshSuccess = await _tokenManager.refreshAccessToken();
          if (refreshSuccess) {
            Logs().i('[AutomateApi] Token refreshed, retrying request...');
            final retryResponse = await retryRequest();
            return _handleResponse<T>(retryResponse, fromJsonT, isRetry: true);
          }
        } catch (e) {
          Logs().e('[AutomateApi] Token refresh failed: $e');
        }

        // 刷新失败，触发登出
        Logs().w('[AutomateApi] Token refresh failed, triggering logout');
        _tokenManager.logout();
      }
      throw ApiException(apiResponse.code, apiResponse.message);
    }

    return apiResponse;
  }

  /// 关闭客户端
  void dispose() {
    _httpClient.close();
  }
}
