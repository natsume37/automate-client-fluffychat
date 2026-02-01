/// AgentTemplate 数据模型
/// 对应后端 automate-assistant 的 AgentTemplate 实体
/// 用于招聘中心展示可雇佣的 Agent 模板
library;

/// Agent 模板领域模型
class AgentTemplate {
  /// 模板 ID
  final int id;

  /// 模板名称（已本地化）
  final String name;

  /// 副标题（已本地化）
  final String subtitle;

  /// 描述（已本地化）
  final String description;

  /// 技能标签列表（已本地化）
  final List<String> skillTags;

  /// 头像 URL
  final String? avatarUrl;

  /// 系统提示词模板
  final String systemPrompt;

  /// 是否激活
  final bool isActive;

  const AgentTemplate({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.description,
    required this.skillTags,
    this.avatarUrl,
    required this.systemPrompt,
    this.isActive = true,
  });

  /// 从 JSON 创建 AgentTemplate
  factory AgentTemplate.fromJson(Map<String, dynamic> json) {
    // 解析 skill_tags，支持 List<String> 或 List<dynamic>
    final rawTags = json['skill_tags'];
    List<String> parsedTags = [];
    if (rawTags is List) {
      parsedTags = rawTags.map((e) => e.toString()).toList();
    }

    // 解析 is_active，兼容 status 字段
    bool isActive = true;
    if (json.containsKey('is_active')) {
      isActive = json['is_active'] as bool? ?? true;
    } else if (json.containsKey('status')) {
      isActive = json['status'] == 'active';
    }

    return AgentTemplate(
      id: json['id'] as int,
      name: json['name'] as String? ?? '',
      subtitle: json['subtitle'] as String? ?? '',
      description: json['description'] as String? ?? '',
      skillTags: parsedTags,
      avatarUrl: json['avatar_url'] as String?,
      systemPrompt: json['system_prompt'] as String? ?? '',
      isActive: isActive,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'subtitle': subtitle,
      'description': description,
      'skill_tags': skillTags,
      'avatar_url': avatarUrl,
      'system_prompt': systemPrompt,
      'is_active': isActive,
    };
  }

  /// 复制并修改
  AgentTemplate copyWith({
    int? id,
    String? name,
    String? subtitle,
    String? description,
    List<String>? skillTags,
    String? avatarUrl,
    String? systemPrompt,
    bool? isActive,
  }) {
    return AgentTemplate(
      id: id ?? this.id,
      name: name ?? this.name,
      subtitle: subtitle ?? this.subtitle,
      description: description ?? this.description,
      skillTags: skillTags ?? this.skillTags,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      systemPrompt: systemPrompt ?? this.systemPrompt,
      isActive: isActive ?? this.isActive,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentTemplate &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'AgentTemplate(id: $id, name: $name)';
}

/// 统一创建 Agent 请求（对应后端 UnifiedCreateAgentRequest）
/// 支持基于模板创建或定制创建两种模式
class UnifiedCreateAgentRequest {
  final String name; // Agent 名称（必填）
  final String invitationCode; // 邀请码（必填，开发环境可传空字符串）
  final int? templateId; // 模板 ID（可选，提供则基于模板创建）
  final String? systemPrompt; // 系统提示词（无模板时由服务端默认）
  final String? userRules; // 用户规则（可选，会追加到 system_prompt）
  final List<PluginConfig>? plugins; // 插件列表（可选）
  final String? apiKey; // Agent 专属 API Key（可选）
  final String? llmProvider; // LLM 厂商（可选）
  final String? llmModel; // LLM 模型（可选）
  final String? avatarUrl; // 头像 URL（可选，DiceBear 等）

  const UnifiedCreateAgentRequest({
    required this.name,
    required this.invitationCode,
    this.templateId,
    this.systemPrompt,
    this.userRules,
    this.plugins,
    this.apiKey,
    this.llmProvider,
    this.llmModel,
    this.avatarUrl,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'invitation_code': invitationCode,
      if (templateId != null) 'template_id': templateId,
      if (systemPrompt != null) 'system_prompt': systemPrompt,
      if (userRules != null) 'user_rules': userRules,
      if (plugins != null)
        'plugins': plugins!.map((p) => p.toJson()).toList(),
      if (apiKey != null) 'api_key': apiKey,
      if (llmProvider != null) 'llm_provider': llmProvider,
      if (llmModel != null) 'llm_model': llmModel,
      if (avatarUrl != null) 'avatar_url': avatarUrl,
    };
  }
}

/// 插件配置
class PluginConfig {
  final String pluginName;
  final Map<String, dynamic>? config;

  const PluginConfig({
    required this.pluginName,
    this.config,
  });

  Map<String, dynamic> toJson() {
    return {
      'plugin_name': pluginName,
      if (config != null) 'config': config,
    };
  }
}

/// 统一创建 Agent 响应
class UnifiedCreateAgentResponse {
  final String message;
  final String agentId;
  final String matrixUserId;
  final int pluginsCount;
  final String? podUrl;

  const UnifiedCreateAgentResponse({
    required this.message,
    required this.agentId,
    required this.matrixUserId,
    required this.pluginsCount,
    this.podUrl,
  });

  factory UnifiedCreateAgentResponse.fromJson(Map<String, dynamic> json) {
    return UnifiedCreateAgentResponse(
      message: json['message'] as String? ?? '',
      agentId: json['agent_id'] as String? ?? '',
      matrixUserId: json['matrix_user_id'] as String? ?? '',
      pluginsCount: json['plugins_count'] as int? ?? 0,
      podUrl: json['pod_url'] as String?,
    );
  }
}

/// 自定义创建 Agent 请求
class CustomCreateAgentRequest {
  final String userId;
  final String name;
  final String systemPrompt;
  final String llmProvider;
  final String llmModel;
  final int maxMemoryTokens;

  const CustomCreateAgentRequest({
    required this.userId,
    required this.name,
    required this.systemPrompt,
    this.llmProvider = 'openrouter',
    this.llmModel = 'openai/gpt-5',
    this.maxMemoryTokens = 3500000,
  });

  Map<String, dynamic> toJson() {
    return {
      'user_id': userId,
      'name': name,
      'system_prompt': systemPrompt,
      'llm_provider': llmProvider,
      'llm_model': llmModel,
      'max_memory_tokens': maxMemoryTokens,
    };
  }
}
