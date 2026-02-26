/// Agent 数据仓库
/// 负责 Agent 相关的 API 调用和数据转换
library;

import 'dart:math';

import '../core/api_client.dart';
import '../models/agent.dart';
import '../models/agent_style.dart';

/// Agent 数据仓库
class AgentRepository {
  final PsygoApiClient _apiClient;
  final Random _random = Random.secure();

  AgentRepository({PsygoApiClient? apiClient})
      : _apiClient = apiClient ?? PsygoApiClient();

  /// 获取当前用户的所有 Agent（支持游标分页）
  ///
  /// [cursor] 游标（首次请求传 null）
  /// [limit] 每页条数（默认 20）
  ///
  /// 返回 [AgentPage] 包含 agents 列表和分页信息
  Future<AgentPage> getUserAgents({int? cursor, int limit = 20}) async {
    final queryParams = <String, String>{
      'limit': limit.toString(),
    };
    if (cursor != null) {
      queryParams['cursor'] = cursor.toString();
    }

    final response = await _apiClient.get<Map<String, dynamic>>(
      '/api/agents/my-agents',
      queryParameters: queryParams,
      fromJsonT: (data) => data as Map<String, dynamic>,
    );

    if (response.data == null) {
      return const AgentPage(agents: [], hasNextPage: false);
    }

    return AgentPage.fromJson(response.data!);
  }

  /// 获取 Agent 统计信息
  ///
  /// [agentId] Agent ID
  ///
  /// 返回 [AgentStats] 统计信息，如果获取失败返回 null（降级处理）
  Future<AgentStats?> getAgentStats(String agentId) async {
    try {
      final response = await _apiClient.get<Map<String, dynamic>>(
        '/api/agents/$agentId/stats',
        fromJsonT: (data) => data as Map<String, dynamic>,
      );

      if (response.data == null) {
        return null;
      }

      return AgentStats.fromJson(response.data!);
    } catch (e) {
      // 统计信息获取失败不阻塞主流程
      return null;
    }
  }

  /// 删除 Agent
  ///
  /// [agentId] Agent ID
  /// [confirm] 确认删除（必须为 true）
  Future<void> deleteAgent(String agentId, {bool confirm = true}) async {
    final accepted = await _apiClient.delete<Map<String, dynamic>>(
      '/api/agents/$agentId',
      queryParameters: {'confirm': confirm.toString()},
      headers: {'Idempotency-Key': _newIdempotencyKey()},
      fromJsonT: (data) =>
          data is Map<String, dynamic> ? data : <String, dynamic>{},
    );

    final operationId =
        (accepted.data?['operation_id'] as String?)?.trim() ?? '';
    if (operationId.isEmpty) {
      throw ApiException(-1, 'Missing operation_id');
    }
    await _waitDeleteOperation(operationId);
  }

  String _newIdempotencyKey() {
    final ts = DateTime.now().microsecondsSinceEpoch;
    final rand = _random.nextInt(1 << 32);
    return '$ts-$rand';
  }

  Future<void> _waitDeleteOperation(String operationId) async {
    final deadline = DateTime.now().add(const Duration(minutes: 12));

    while (DateTime.now().isBefore(deadline)) {
      final resp = await _apiClient.get<Map<String, dynamic>>(
        '/api/operations/$operationId',
        fromJsonT: (data) =>
            data is Map<String, dynamic> ? data : <String, dynamic>{},
      );

      final data = resp.data ?? <String, dynamic>{};
      final status = (data['status'] as String?)?.trim().toLowerCase() ?? '';
      if (status == 'succeeded') {
        return;
      }
      if (status == 'failed') {
        final error = (data['error'] as String?)?.trim();
        throw ApiException(
            -1, error?.isNotEmpty == true ? error! : 'Operation failed');
      }

      await Future.delayed(const Duration(seconds: 1));
    }

    throw ApiException(-1, 'Operation timeout');
  }

  /// 获取可用的沟通和汇报风格列表
  ///
  /// 返回 [AvailableStyles] 包含所有可选风格
  Future<AvailableStyles> getAvailableStyles() async {
    final response = await _apiClient.get<Map<String, dynamic>>(
      '/api/agents/styles',
      fromJsonT: (data) => data as Map<String, dynamic>,
    );

    if (response.data == null) {
      throw Exception('Failed to load available styles');
    }

    return AvailableStyles.fromJson(response.data!);
  }

  /// 更新 Agent 的沟通和汇报风格
  ///
  /// [agentId] Agent ID
  /// [communicationStyle] 沟通风格 key（可选）
  /// [reportStyle] 汇报风格 key（可选）
  Future<void> updateAgentStyle(
    String agentId, {
    String? communicationStyle,
    String? reportStyle,
  }) async {
    final body = <String, dynamic>{};
    if (communicationStyle != null) {
      body['communication_style'] = communicationStyle;
    }
    if (reportStyle != null) {
      body['report_style'] = reportStyle;
    }

    if (body.isEmpty) {
      throw ArgumentError('At least one style must be provided');
    }

    await _apiClient.put<void>(
      '/api/agents/$agentId/style',
      body: body,
    );
  }

  /// 获取 Agent Web 入口 URL（用于 WebView 展示）
  ///
  /// 返回一个相对路径，例如：/w/<agent_id>/?t=...
  Future<String> getWebEntryUrl(String agentId) async {
    final response = await _apiClient.post<Map<String, dynamic>>(
      '/api/agents/$agentId/web-entry/url',
      fromJsonT: (data) => data as Map<String, dynamic>,
    );

    final url = (response.data?['url'] as String?)?.trim() ?? '';
    if (url.isEmpty) {
      throw ApiException(-1, 'Missing web entry url');
    }
    return url;
  }

  /// 释放资源
  void dispose() {
    _apiClient.dispose();
  }
}
