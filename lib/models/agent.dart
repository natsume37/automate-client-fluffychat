/// Agent 数据模型
/// 对应后端 automate-assistant 的 Agent 实体
library;

/// Agent 领域模型
class Agent {
  /// Agent 唯一标识（如 "agent_1_abc123"）
  final String agentId;

  /// 用户友好显示名称（用于 UI 展示，如 "Alice"）
  final String displayName;

  /// 系统内部名称（符合 K8s DNS-1035 规范，如 "alice" 或 "alice-abc123"）
  final String name;

  /// Agent 描述
  final String? description;

  /// 头像 URL
  final String? avatarUrl;

  /// 是否激活
  final bool isActive;

  /// Pod 就绪状态（插件恢复完成后为 true）
  /// 前端逻辑：isReady=false 时显示"入职中"，阻止用户交互
  final bool isReady;

  /// Web 入口是否已开启（用于在私聊会话中展示/启用 WebView 按钮）
  final bool webEntryEnabled;

  /// Agent 的 Matrix 账号 ID（如 @agent-1-abc:matrix.org）
  final String? matrixUserId;

  /// 创建时间（ISO 8601 格式）
  final String createdAt;

  /// 合同到期时间（ISO 8601 格式）
  final String? contractExpiresAt;

  /// 工作状态：busy/idle/suspending/suspended（busy 表示 loop 处理中）
  final String workStatus;

  /// 最后活跃时间（ISO 8601 格式）
  final String? lastActiveAt;

  const Agent({
    required this.agentId,
    required this.displayName,
    required this.name,
    this.description,
    this.avatarUrl,
    required this.isActive,
    required this.isReady,
    this.webEntryEnabled = false,
    this.matrixUserId,
    required this.createdAt,
    this.contractExpiresAt,
    this.workStatus = 'idle',
    this.lastActiveAt,
  });

  /// 从 JSON 创建 Agent
  factory Agent.fromJson(Map<String, dynamic> json) {
    return Agent(
      agentId: json['agent_id'] as String,
      displayName: json['display_name'] as String,
      name: json['name'] as String,
      description: json['description'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      isActive: json['is_active'] as bool? ?? false,
      isReady: json['is_ready'] as bool? ?? false,
      webEntryEnabled: json['web_entry_enabled'] as bool? ?? false,
      matrixUserId: json['matrix_user_id'] as String?,
      createdAt: json['created_at'] as String,
      contractExpiresAt: json['contract_expires_at'] as String?,
      workStatus: json['work_status'] as String? ?? 'idle',
      lastActiveAt: json['last_active_at'] as String?,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'agent_id': agentId,
      'display_name': displayName,
      'name': name,
      'description': description,
      'avatar_url': avatarUrl,
      'is_active': isActive,
      'is_ready': isReady,
      'web_entry_enabled': webEntryEnabled,
      'matrix_user_id': matrixUserId,
      'created_at': createdAt,
      'contract_expires_at': contractExpiresAt,
      'work_status': workStatus,
      'last_active_at': lastActiveAt,
    };
  }

  /// 复制并修改
  Agent copyWith({
    String? agentId,
    String? displayName,
    String? name,
    String? description,
    String? avatarUrl,
    bool? isActive,
    bool? isReady,
    bool? webEntryEnabled,
    String? matrixUserId,
    String? createdAt,
    String? contractExpiresAt,
    String? workStatus,
    String? lastActiveAt,
  }) {
    return Agent(
      agentId: agentId ?? this.agentId,
      displayName: displayName ?? this.displayName,
      name: name ?? this.name,
      description: description ?? this.description,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      isActive: isActive ?? this.isActive,
      isReady: isReady ?? this.isReady,
      webEntryEnabled: webEntryEnabled ?? this.webEntryEnabled,
      matrixUserId: matrixUserId ?? this.matrixUserId,
      createdAt: createdAt ?? this.createdAt,
      contractExpiresAt: contractExpiresAt ?? this.contractExpiresAt,
      workStatus: workStatus ?? this.workStatus,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
    );
  }

  /// 获取实际工作状态
  /// 规则：
  /// - work_status=busy/working/running → 工作中
  /// - work_status=idle → 摸鱼中
  /// - 其他状态 → 休息中
  String get computedWorkStatus {
    final normalized = workStatus.trim().toLowerCase();
    if (normalized == 'busy' || normalized == 'working' || normalized == 'running') {
      return 'working';
    }
    if (normalized == 'idle') {
      return 'slacking';
    }
    return 'resting';
  }

  /// 是否正在工作（基于计算的状态）
  bool get isWorking => computedWorkStatus == 'working';

  /// 是否摸鱼中（基于计算的状态）
  bool get isSlacking => computedWorkStatus == 'slacking';

  /// 是否休息中（基于计算的状态）
  bool get isResting => computedWorkStatus == 'resting';

  /// 获取工作状态显示文本的 key（基于计算的状态）
  String get workStatusKey {
    switch (computedWorkStatus) {
      case 'working':
        return 'employeeWorking';
      case 'slacking':
        return 'employeeSlacking';
      default:
        return 'employeeSleeping';
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Agent &&
          runtimeType == other.runtimeType &&
          agentId == other.agentId;

  @override
  int get hashCode => agentId.hashCode;

  @override
  String toString() => 'Agent(agentId: $agentId, displayName: $displayName)';
}

/// Agent 统计信息
class AgentStats {
  final String agentId;
  final int totalTasks;
  final int completedTasks;
  final int activeTasks;
  final int totalPlugins;
  final int activePlugins;
  final double workHours;
  final String lastActiveAt;
  final String createdAt;

  const AgentStats({
    required this.agentId,
    required this.totalTasks,
    required this.completedTasks,
    required this.activeTasks,
    required this.totalPlugins,
    required this.activePlugins,
    required this.workHours,
    required this.lastActiveAt,
    required this.createdAt,
  });

  factory AgentStats.fromJson(Map<String, dynamic> json) {
    return AgentStats(
      agentId: json['agent_id'] as String,
      totalTasks: json['total_tasks'] as int? ?? 0,
      completedTasks: json['completed_tasks'] as int? ?? 0,
      activeTasks: json['active_tasks'] as int? ?? 0,
      totalPlugins: json['total_plugins'] as int? ?? 0,
      activePlugins: json['active_plugins'] as int? ?? 0,
      workHours: (json['work_hours'] as num?)?.toDouble() ?? 0.0,
      lastActiveAt: json['last_active_at'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
    );
  }
}

/// Agent 分页结果
class AgentPage {
  final List<Agent> agents;
  final int? nextCursor;
  final bool hasNextPage;

  /// 试用期到期时间（ISO 8601 格式）
  /// 用于显示全局倒计时
  final String? trialExpiresAt;

  const AgentPage({
    required this.agents,
    this.nextCursor,
    required this.hasNextPage,
    this.trialExpiresAt,
  });

  factory AgentPage.fromJson(Map<String, dynamic> json) {
    final agentsJson = json['agents'] as List<dynamic>? ?? [];
    return AgentPage(
      agents: agentsJson.map((e) => Agent.fromJson(e as Map<String, dynamic>)).toList(),
      nextCursor: json['next_cursor'] as int?,
      hasNextPage: json['has_next_page'] as bool? ?? false,
      trialExpiresAt: json['trial_expires_at'] as String?,
    );
  }

  /// 获取试用期剩余时间
  /// 返回 null 表示没有试用期限制或已过期
  Duration? get trialRemaining {
    if (trialExpiresAt == null) return null;
    try {
      final expiresAt = DateTime.parse(trialExpiresAt!);
      final remaining = expiresAt.difference(DateTime.now());
      return remaining.isNegative ? null : remaining;
    } catch (_) {
      return null;
    }
  }

  /// 试用期是否已过期
  bool get isTrialExpired {
    if (trialExpiresAt == null) return false;
    try {
      final expiresAt = DateTime.parse(trialExpiresAt!);
      return DateTime.now().isAfter(expiresAt);
    } catch (_) {
      return false;
    }
  }
}
