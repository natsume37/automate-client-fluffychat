import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:psygo/backend/api_client.dart';
import 'package:psygo/utils/custom_http_client.dart';
import 'package:psygo/utils/localized_exception_extension.dart';
import 'package:psygo/utils/platform_infos.dart';

/// 版本跳过存储 key
const String _skipVersionKey = 'app_update_skip_version';

/// 应用更新服务
class AppUpdateService {
  final PsygoApiClient _apiClient;

  // 后台定时检查
  static Timer? _backgroundTimer;
  static bool _isDialogShowing = false;
  static bool _hasSuccessfulCheck = false;  // 是否成功检查过一次
  static const Duration _checkInterval = Duration(minutes: 5);
  static const Duration _retryInterval = Duration(seconds: 30);  // 首次失败后的重试间隔
  static const Duration _resumeDebounce = Duration(seconds: 3);  // 恢复检查的防抖时间

  // 保存引用以便重试
  static PsygoApiClient? _apiClient_;
  static BuildContext Function()? _getContext;

  // 网络监听
  static StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  static bool _wasOffline = false;  // 上次是否处于离线状态
  static DateTime? _lastCheckTime;  // 上次检查时间，用于防抖

  AppUpdateService(this._apiClient);

  /// 获取用户跳过的版本号
  static Future<String?> getSkipVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_skipVersionKey);
  }

  /// 设置用户跳过的版本号
  static Future<void> setSkipVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_skipVersionKey, version);
  }

  /// 清除用户跳过的版本号
  static Future<void> clearSkipVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_skipVersionKey);
  }

  /// 比较版本号，返回 1 如果 v1 > v2，0 如果相等，-1 如果 v1 < v2
  static int compareVersion(String v1, String v2) {
    final parts1 = v1.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final parts2 = v2.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    // 补齐长度
    while (parts1.length < parts2.length) {
      parts1.add(0);
    }
    while (parts2.length < parts1.length) {
      parts2.add(0);
    }

    for (var i = 0; i < parts1.length; i++) {
      if (parts1[i] > parts2[i]) return 1;
      if (parts1[i] < parts2[i]) return -1;
    }
    return 0;
  }

  /// 检查是否应该跳过此版本（非强制更新且版本 <= skip_version）
  static Future<bool> shouldSkipVersion(String latestVersion, bool forceUpdate) async {
    // 强制更新不跳过
    if (forceUpdate) return false;

    final skipVersion = await getSkipVersion();
    if (skipVersion == null || skipVersion.isEmpty) return false;

    // 新版本 > skip_version 则不跳过（显示弹窗）
    // 新版本 <= skip_version 则跳过（不显示弹窗）
    return compareVersion(latestVersion, skipVersion) <= 0;
  }

  /// 启动后台定时检查
  static void startBackgroundCheck(PsygoApiClient apiClient, BuildContext Function() getContext) {
    // 避免重复启动
    if (_backgroundTimer != null) return;

    _apiClient_ = apiClient;
    _getContext = getContext;

    // 1. 定时检查（每5分钟）
    _backgroundTimer = Timer.periodic(_checkInterval, (_) async {
      await _doBackgroundCheck();
    });

    // 2. 网络恢复时检查
    _startNetworkListener();
  }

  /// 启动网络状态监听
  static void _startNetworkListener() {
    _connectivitySubscription?.cancel();
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((results) {
      final isOffline = results.isEmpty || results.every((r) => r == ConnectivityResult.none);

      if (_wasOffline && !isOffline) {
        // 从离线恢复到在线
        _triggerCheckWithDebounce();
      }

      _wasOffline = isOffline;
    });

    // 初始化离线状态
    Connectivity().checkConnectivity().then((results) {
      _wasOffline = results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    });
  }

  /// 应用从后台恢复时调用
  static void onAppResumed() {
    _triggerCheckWithDebounce();
  }

  /// 带防抖的检查触发
  static void _triggerCheckWithDebounce() {
    final now = DateTime.now();
    if (_lastCheckTime != null && now.difference(_lastCheckTime!) < _resumeDebounce) {
      return;
    }
    _lastCheckTime = now;
    _doBackgroundCheck();
  }

  /// 执行后台检查
  static Future<void> _doBackgroundCheck() async {
    // 如果已经有弹窗在显示，跳过本次检查
    if (_isDialogShowing) return;

    if (_apiClient_ == null || _getContext == null) return;

    final context = _getContext!();
    if (!context.mounted) return;

    final service = AppUpdateService(_apiClient_!);
    await service._silentCheck(context);
  }

  /// 首次检查失败时调用，启动短间隔重试
  static void _scheduleRetry() {
    if (_hasSuccessfulCheck) return;  // 已经成功检查过，不需要重试

    Future.delayed(_retryInterval, () async {
      if (_hasSuccessfulCheck) return;  // 再次检查，避免重复
      await _doBackgroundCheck();
    });
  }

  /// 标记首次检查成功
  static void _markCheckSuccess() {
    _hasSuccessfulCheck = true;
  }

  /// 停止后台定时检查
  static void stopBackgroundCheck() {
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    _hasSuccessfulCheck = false;
    _wasOffline = false;
    _lastCheckTime = null;
    _apiClient_ = null;
    _getContext = null;
  }

  /// 静默检查更新（后台调用，只在有更新时才弹窗）
  Future<void> _silentCheck(BuildContext context) async {
    try {
      final currentVersion = await PlatformInfos.getVersion();
      final platform = _getPlatformName();

      final response = await _apiClient.checkAppVersion(
        currentVersion: currentVersion,
        platform: platform,
      );

      // 检查成功，标记已成功检查
      _markCheckSuccess();

      if (!response.hasUpdate) return;
      if (!context.mounted) return;

      // 检查是否应该跳过此版本
      if (await shouldSkipVersion(response.latestVersion, response.forceUpdate)) {
        return;
      }

      // 确保 downloadUrl 不为空
      final downloadUrl = response.downloadUrl;
      if (downloadUrl == null || downloadUrl.isEmpty) return;

      // 检查当前 context 是否有 Navigator
      if (Navigator.maybeOf(context) == null) {
        _scheduleRetry();
        return;
      }

      // 标记弹窗正在显示
      _isDialogShowing = true;

      // 显示更新弹窗（禁止点击遮罩层关闭，只能通过按钮操作）
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => _UpdateDialog(
          latestVersion: response.latestVersion,
          forceUpdate: response.forceUpdate,
          downloadUrl: downloadUrl,
          changelog: response.changelog,
          refreshDownloadUrl: () => _refreshDownloadUrl(currentVersion, platform),
        ),
      );

      _isDialogShowing = false;
    } catch (e) {
      // 静默检查失败，如果从未成功检查过，安排重试
      // 但如果是 404/500 等服务器错误，不重试（API 不存在或服务器问题）
      if (!_isServerError(e)) {
        _scheduleRetry();
      }
    }
  }

  /// 判断是否为服务器错误（不需要重试）
  static bool _isServerError(dynamic e) {
    if (e is DioException) {
      final statusCode = e.response?.statusCode;
      // 404 = API 不存在, 500/502/503 = 服务器错误
      if (statusCode != null && (statusCode == 404 || statusCode >= 500)) {
        return true;
      }
    }
    return false;
  }

  /// 检查更新并显示弹窗
  /// 返回 true 表示用户可以继续使用，false 表示被强制更新阻止
  /// [showNoUpdateHint] 为 true 时，如果没有更新也会显示提示
  Future<bool> checkAndPrompt(BuildContext context, {bool showNoUpdateHint = false}) async {
    try {
      final currentVersion = await PlatformInfos.getVersion();
      final platform = _getPlatformName();

      final response = await _apiClient.checkAppVersion(
        currentVersion: currentVersion,
        platform: platform,
      );

      // 检查成功，标记已成功检查
      _markCheckSuccess();

      if (!response.hasUpdate) {
        // 已是最新版本
        if (showNoUpdateHint && context.mounted) {
          await _showNoUpdateDialog(context, response.latestVersion, response.changelog);
        }
        return true;
      }

      if (!context.mounted) return true;

      // 如果不是手动检查（showNoUpdateHint=false），检查是否应该跳过此版本
      if (!showNoUpdateHint && await shouldSkipVersion(response.latestVersion, response.forceUpdate)) {
        return true;
      }

      // 确保 downloadUrl 不为空
      final downloadUrl = response.downloadUrl;
      if (downloadUrl == null || downloadUrl.isEmpty) {
        debugPrint('[AppUpdate] Error: hasUpdate=true but downloadUrl is null/empty');
        return true;
      }

      // 显示更新弹窗（非手动检查时禁止点击遮罩层关闭）
      final shouldContinue = await showDialog<bool>(
        context: context,
        barrierDismissible: showNoUpdateHint ? !response.forceUpdate : false,
        builder: (builderContext) => _UpdateDialog(
          latestVersion: response.latestVersion,
          forceUpdate: response.forceUpdate,
          downloadUrl: downloadUrl,
          changelog: response.changelog,
          refreshDownloadUrl: () => _refreshDownloadUrl(currentVersion, platform),
        ),
      );

      // 如果是强制更新且用户没有点击更新，返回 false
      if (response.forceUpdate && shouldContinue != true) {
        return false;
      }

      return true;
    } catch (e) {
      debugPrint('[AppUpdate] Check failed: $e');
      // 首次检查失败，安排重试（服务器错误除外）
      if (!_isServerError(e)) {
        _scheduleRetry();
      }
      // 检查失败时不阻止用户使用，但如果是手动检查则显示错误
      if (showNoUpdateHint && context.mounted) {
        final message = (e as Object).toLocalizedString(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检查更新失败: $message')),
        );
      }
      return true;
    }
  }

  /// 获取平台名称
  String _getPlatformName() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// 显示"已是最新版本"弹窗（包含当前版本 changelog）
  Future<void> _showNoUpdateDialog(BuildContext context, String currentVersion, String? changelog) async {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final isDesktop = screenWidth > 600;

    final dialogWidth = isDesktop ? 420.0 : 320.0;
    final padding = isDesktop ? 32.0 : 24.0;
    final iconSize = isDesktop ? 80.0 : 64.0;
    final iconInnerSize = isDesktop ? 40.0 : 32.0;
    // changelog 最大高度，确保弹窗不会超出屏幕
    final maxChangelogHeight = screenHeight * 0.3;

    await showDialog(
      context: context,
      builder: (context) => Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: dialogWidth,
            maxHeight: screenHeight * 0.85,
          ),
          child: Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            child: Padding(
              padding: EdgeInsets.all(padding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 成功图标
                  Container(
                    width: iconSize,
                    height: iconSize,
                    decoration: BoxDecoration(
                      color: Colors.green.withAlpha(30),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.check_circle_rounded,
                      color: Colors.green,
                      size: iconInnerSize,
                    ),
                  ),
                  SizedBox(height: isDesktop ? 24.0 : 20.0),

                  // 标题
                  Text(
                    '已是最新版本',
                    style: (isDesktop
                            ? theme.textTheme.headlineSmall
                            : theme.textTheme.titleLarge)
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),

                  // 版本号
                  Text(
                    'v$currentVersion',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),

                  // 更新日志
                  if (changelog != null && changelog.isNotEmpty) ...[
                    SizedBox(height: isDesktop ? 20.0 : 16.0),
                    Container(
                      width: double.infinity,
                      constraints: BoxConstraints(maxHeight: maxChangelogHeight),
                      padding: EdgeInsets.all(isDesktop ? 16.0 : 12.0),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest.withAlpha(128),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '当前版本更新内容',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              changelog,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                  SizedBox(height: isDesktop ? 28.0 : 24.0),

                  // 确定按钮
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.symmetric(
                          vertical: isDesktop ? 16.0 : 14.0,
                        ),
                        backgroundColor: Colors.green,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        '知道了',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 刷新下载链接（下载链接 10 分钟有效，过期后需要重新获取）
  Future<String?> _refreshDownloadUrl(String currentVersion, String platform) async {
    try {
      final response = await _apiClient.checkAppVersion(
        currentVersion: currentVersion,
        platform: platform,
      );
      return response.downloadUrl;
    } catch (e) {
      return null;
    }
  }
}

/// 更新弹窗（支持下载进度）
class _UpdateDialog extends StatefulWidget {
  final String latestVersion;
  final bool forceUpdate;
  final String downloadUrl;
  final String? changelog;
  final Future<String?> Function() refreshDownloadUrl;  // 刷新下载链接的回调

  const _UpdateDialog({
    required this.latestVersion,
    required this.forceUpdate,
    required this.downloadUrl,
    this.changelog,
    required this.refreshDownloadUrl,
  });

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

enum _UpdateState {
  idle,        // 等待用户点击
  downloading, // 下载中
  downloaded,  // 下载完成
  error,       // 下载失败
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _UpdateState _state = _UpdateState.idle;
  double _progress = 0;
  String? _errorMessage;
  String? _downloadedFilePath;
  CancelToken? _cancelToken;
  bool _allowPop = false;  // 是否允许关闭弹窗（只有按钮点击时才设为true）
  late String _currentDownloadUrl;  // 当前下载链接（可能会刷新）
  DateTime? _lastProgressUpdate;  // 上次更新进度的时间

  @override
  void initState() {
    super.initState();
    _currentDownloadUrl = widget.downloadUrl;
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }

  /// 是否需要应用内下载（桌面端和 Android）
  bool get _needsInAppDownload {
    if (kIsWeb) return false;
    if (Platform.isIOS) return false; // iOS 必须跳转 App Store
    return true;
  }

  /// 获取下载文件名
  String _getFileName() {
    final uri = Uri.parse(_currentDownloadUrl);
    final pathSegments = uri.pathSegments;
    if (pathSegments.isNotEmpty) {
      final fileName = pathSegments.last;
      // 去掉查询参数中可能包含的部分
      final dotIndex = fileName.lastIndexOf('.');
      if (dotIndex > 0) {
        return fileName;
      }
    }
    // 默认文件名
    if (Platform.isWindows) return 'psygo-setup.exe';
    if (Platform.isMacOS) return 'psygo.dmg';
    if (Platform.isLinux) return 'psygo.deb';
    if (Platform.isAndroid) return 'psygo.apk';
    return 'psygo-update';
  }

  /// 开始下载
  Future<void> _startDownload({bool isRetry = false}) async {
    setState(() {
      _state = _UpdateState.downloading;
      _progress = 0;
      _errorMessage = null;
    });

    try {
      // 获取下载目录
      final dir = await getTemporaryDirectory();
      final fileName = _getFileName();
      final filePath = '${dir.path}/$fileName';

      _cancelToken = CancelToken();
      final dio = CustomHttpClient.createDio();

      await dio.download(
        _currentDownloadUrl,
        filePath,
        cancelToken: _cancelToken,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            final newProgress = received / total;
            final now = DateTime.now();
            // 每 1 秒更新一次 UI，或下载完成时立即更新
            final shouldUpdate = newProgress >= 1.0 ||
                _lastProgressUpdate == null ||
                now.difference(_lastProgressUpdate!).inMilliseconds >= 1000;
            if (shouldUpdate) {
              _lastProgressUpdate = now;
              setState(() {
                _progress = newProgress >= 1.0 ? 0.99 : newProgress;  // 下载中最多显示 99%
              });
            }
          }
        },
      );

      setState(() {
        _state = _UpdateState.downloaded;
        _progress = 1.0;  // 下载完成后设为 100%
        _downloadedFilePath = filePath;
      });
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) {
        // 用户取消
        setState(() {
          _state = _UpdateState.idle;
        });
      } else if (e is DioException && _isLinkExpiredError(e) && !isRetry) {
        // 链接可能过期，尝试刷新
        await _refreshAndRetry();
      } else {
        setState(() {
          _state = _UpdateState.error;
          _errorMessage = '下载失败，请重试';
        });
      }
    }
  }

  /// 判断是否为链接过期错误（403/401/410 等）
  bool _isLinkExpiredError(DioException e) {
    final statusCode = e.response?.statusCode;
    return statusCode == 403 || statusCode == 401 || statusCode == 410;
  }

  /// 刷新下载链接并重试
  Future<void> _refreshAndRetry() async {
    try {
      final newUrl = await widget.refreshDownloadUrl();
      if (newUrl != null && newUrl.isNotEmpty) {
        _currentDownloadUrl = newUrl;
        await _startDownload(isRetry: true);
      } else {
        setState(() {
          _state = _UpdateState.error;
          _errorMessage = '获取下载链接失败，请重试';
        });
      }
    } catch (e) {
      setState(() {
        _state = _UpdateState.error;
        _errorMessage = '获取下载链接失败，请重试';
      });
    }
  }

  /// 取消下载（带二次确认）
  Future<void> _cancelDownload() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认取消'),
        content: const Text('确定要取消下载吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('继续下载'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              '取消下载',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _cancelToken?.cancel();
    }
  }

  /// 安装/打开下载的文件
  Future<void> _installUpdate() async {
    if (_downloadedFilePath == null) return;

    try {
      // Android 8.0+ 需要检查"安装未知应用"权限
      if (Platform.isAndroid) {
        final canInstall = await _checkInstallPermission();
        if (!canInstall) {
          // 引导用户去设置页面开启权限
          final granted = await _requestInstallPermission();
          if (!granted) {
            setState(() {
              _errorMessage = '需要开启"安装未知应用"权限才能安装更新';
            });
            return;
          }
        }
      }

      final result = await OpenFile.open(_downloadedFilePath!);
      if (result.type != ResultType.done) {
        // 打开失败
        setState(() {
          _errorMessage = '无法打开文件，请稍后重试';
        });
        return;
      }

      if (context.mounted) {
        setState(() => _allowPop = true);
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      setState(() {
        _errorMessage = '无法打开文件，请稍后重试';
      });
    }
  }

  /// 检查是否有安装未知应用权限 (Android)
  Future<bool> _checkInstallPermission() async {
    try {
      const channel = MethodChannel('com.psygo.app/install');
      final result = await channel.invokeMethod<bool>('canRequestPackageInstalls');
      return result ?? false;
    } catch (e) {
      // 如果检查失败，假设有权限，让系统处理
      return true;
    }
  }

  /// 请求安装未知应用权限 (Android)
  Future<bool> _requestInstallPermission() async {
    try {
      const channel = MethodChannel('com.psygo.app/install');
      final result = await channel.invokeMethod<bool>('requestInstallPermission');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 跳转外部链接（iOS 或下载失败时）
  Future<void> _openExternalUrl() async {
    final uri = Uri.parse(widget.downloadUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    if (context.mounted) {
      setState(() => _allowPop = true);
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    // PC端（宽度 > 600）使用更大的尺寸
    final isDesktop = screenWidth > 600;

    final dialogWidth = isDesktop ? 480.0 : 340.0;
    final padding = isDesktop ? 36.0 : 24.0;
    final iconSize = isDesktop ? 88.0 : 64.0;
    final iconInnerSize = isDesktop ? 44.0 : 32.0;
    final titleStyle = isDesktop ? theme.textTheme.headlineMedium : theme.textTheme.titleLarge;
    final versionStyle = isDesktop ? theme.textTheme.titleLarge : theme.textTheme.titleMedium;
    final progressHeight = isDesktop ? 8.0 : 6.0;
    final buttonPadding = isDesktop ? 16.0 : 14.0;
    // changelog 最大高度
    final maxChangelogHeight = screenHeight * 0.25;

    return PopScope(
      // 只有按钮点击设置 _allowPop = true 后才允许关闭
      canPop: _allowPop,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: dialogWidth,
            maxHeight: screenHeight * 0.85,
          ),
          child: Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(28),
            ),
            child: Padding(
              padding: EdgeInsets.all(padding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 图标
                  Container(
                    width: iconSize,
                    height: iconSize,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withAlpha(77),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _state == _UpdateState.downloaded
                          ? Icons.check_circle_rounded
                          : isDesktop
                              ? Icons.downloading_rounded  // PC端用下载图标
                              : Icons.system_update_rounded,  // 移动端用系统更新图标
                      color: _state == _UpdateState.downloaded
                          ? Colors.green
                          : theme.colorScheme.primary,
                      size: iconInnerSize,
                    ),
                  ),
                  SizedBox(height: isDesktop ? 28.0 : 20.0),

                  // 标题
                  Text(
                    _getTitle(),
                    style: titleStyle?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // 版本号
                  Text(
                    'v${widget.latestVersion}',
                    style: versionStyle?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w500,
                    ),
                  ),

                  // 更新日志
                  if (widget.changelog != null && widget.changelog!.isNotEmpty) ...[
                    SizedBox(height: isDesktop ? 16.0 : 12.0),
                    Container(
                      width: double.infinity,
                      constraints: BoxConstraints(maxHeight: maxChangelogHeight),
                      padding: EdgeInsets.all(isDesktop ? 16.0 : 12.0),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest.withAlpha(128),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SingleChildScrollView(
                        child: Text(
                          widget.changelog!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                          textAlign: TextAlign.start,
                        ),
                      ),
                    ),
                  ],
                  SizedBox(height: isDesktop ? 24.0 : 16.0),

                  // 下载进度条（使用自定义进度条，避免 LinearProgressIndicator 的动画延迟）
                  if (_state == _UpdateState.downloading) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        height: progressHeight,
                        width: double.infinity,
                        color: theme.colorScheme.surfaceContainerHighest,
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: _progress.clamp(0.0, 1.0),
                          child: Container(
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${(_progress * 100).toStringAsFixed(0)}%',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    SizedBox(height: isDesktop ? 24.0 : 16.0),
                  ],

                  // 错误信息
                  if (_errorMessage != null) ...[
                    Container(
                      padding: EdgeInsets.all(isDesktop ? 16.0 : 12.0),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer.withAlpha(77),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: theme.colorScheme.error,
                            size: isDesktop ? 24.0 : 20.0,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: isDesktop ? 24.0 : 16.0),
                  ],

                  // 强制更新提示
                  if (widget.forceUpdate && _state == _UpdateState.idle)
                    Container(
                      padding: EdgeInsets.all(isDesktop ? 16.0 : 12.0),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer.withAlpha(77),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: theme.colorScheme.error,
                            size: isDesktop ? 24.0 : 20.0,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '当前版本过低，请更新后继续使用',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                  SizedBox(height: isDesktop ? 32.0 : 24.0),

                  // 按钮
                  _buildButtons(theme, buttonPadding),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _getTitle() {
    switch (_state) {
      case _UpdateState.idle:
        return '发现新版本';
      case _UpdateState.downloading:
        return '正在下载';
      case _UpdateState.downloaded:
        return '下载完成';
      case _UpdateState.error:
        return '下载失败';
    }
  }

  Widget _buildButtons(ThemeData theme, double buttonPadding) {
    switch (_state) {
      case _UpdateState.idle:
        return Row(
          children: [
            // 稍后更新按钮（强制更新时不显示）
            if (!widget.forceUpdate) ...[
              Expanded(
                child: TextButton(
                  onPressed: () async {
                    // 保存跳过版本号
                    await AppUpdateService.setSkipVersion(widget.latestVersion);
                    if (context.mounted) {
                      setState(() => _allowPop = true);
                      Navigator.of(context).pop(false);
                    }
                  },
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.symmetric(vertical: buttonPadding),
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    '稍后更新',
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
            ],
            // 立即更新按钮
            Expanded(
              child: FilledButton(
                onPressed: _needsInAppDownload ? _startDownload : _openExternalUrl,
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.symmetric(vertical: buttonPadding),
                  backgroundColor: theme.colorScheme.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  '立即更新',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        );

      case _UpdateState.downloading:
        return TextButton(
          onPressed: _cancelDownload,
          style: TextButton.styleFrom(
            padding: EdgeInsets.symmetric(vertical: buttonPadding, horizontal: 32),
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(
            '取消下载',
            style: TextStyle(
              color: theme.colorScheme.error,
              fontWeight: FontWeight.w600,
            ),
          ),
        );

      case _UpdateState.downloaded:
        return FilledButton(
          onPressed: _installUpdate,
          style: FilledButton.styleFrom(
            padding: EdgeInsets.symmetric(vertical: buttonPadding, horizontal: 32),
            backgroundColor: Colors.green,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text(
            '立即安装',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
        );

      case _UpdateState.error:
        return Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: () => setState(() => _state = _UpdateState.idle),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.symmetric(vertical: buttonPadding),
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  '重试',
                  style: TextStyle(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: _openExternalUrl,
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.symmetric(vertical: buttonPadding),
                  backgroundColor: theme.colorScheme.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  '浏览器下载',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        );
    }
  }
}
