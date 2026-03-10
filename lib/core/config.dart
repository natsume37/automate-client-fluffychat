/// Psygo 配置管理
library;

/// Psygo 配置
/// 所有环境相关配置通过 --dart-define-from-file=env.json 注入
class PsygoConfig {
  /// 应用名称（用于数据库隔离）
  static const String appName = String.fromEnvironment('APP_NAME', defaultValue: 'Psygo');

  /// K8s Namespace
  static const String k8sNamespace = String.fromEnvironment('K8S_NAMESPACE', defaultValue: 'dev');

  /// Psygo Assistant 后端 URL
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://development-api.psygoai.com/assistant',
  );

  /// User Service 集群内部 URL
  /// Synapse 调用 Push Gateway 用这个（K8s FQDN，Twisted 解析不了短名）
  static String get internalBaseUrl => 'http://user-service.$k8sNamespace.svc.cluster.local:8080';

  /// Matrix Synapse Homeserver URL
  static const String matrixHomeserver = String.fromEnvironment(
    'MATRIX_HOMESERVER',
    defaultValue: 'https://development-matrix.psygoai.com',
  );

  /// API 版本前缀
  static const String apiPrefix = '/api';

  /// 完整 API URL
  static String get apiUrl => baseUrl + apiPrefix;

  /// DiceBear API 基础 URL（可通过 dart-define 覆盖）
  /// 例如: https://api.dicebear.com/9.x
  static String get dicebearBaseUrl {
    const explicit = String.fromEnvironment('DICEBEAR_BASE_URL', defaultValue: '');
    final raw = explicit.isNotEmpty ? explicit : 'https://api.dicebear.com/9.x';
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  /// HTTP 超时配置
  static const Duration connectTimeout = Duration(seconds: 10);
  static const Duration receiveTimeout = Duration(seconds: 120);

  /// LLM 默认配置
  static const String defaultLLMProvider = 'openrouter';
  static const String defaultLLMModel = 'openai/gpt-5';
  static const int defaultMaxMemoryTokens = 3500000;
}
