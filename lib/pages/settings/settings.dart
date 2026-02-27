import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:psygo/backend/api_client.dart';
import 'package:psygo/backend/auth_state.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:psygo/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:psygo/widgets/future_loading_dialog.dart';
import 'package:psygo/widgets/layouts/desktop_layout.dart';
import '../../widgets/matrix.dart';
import '../bootstrap/bootstrap_dialog.dart';
import 'settings_view.dart';

class Settings extends StatefulWidget {
  const Settings({super.key});

  @override
  SettingsController createState() => SettingsController();
}

class SettingsController extends State<Settings> {
  Future<Profile>? profileFuture;
  bool profileUpdated = false;

  void updateProfile() => setState(() {
        profileUpdated = true;
        profileFuture = null;
        // 清除侧边栏的 profile 缓存，确保头像同步更新
        DesktopLayout.clearUserCache();
      });

  void setDisplaynameAction() async {
    final profile = await profileFuture;
    final input = await showTextInputDialog(
      useRootNavigator: false,
      context: context,
      title: L10n.of(context).editDisplayname,
      okLabel: L10n.of(context).ok,
      cancelLabel: L10n.of(context).cancel,
      initialText:
          profile?.displayName ?? Matrix.of(context).client.userID!.localpart,
    );
    if (input == null) return;
    final matrix = Matrix.of(context);
    final success = await showFutureLoadingDialog(
      context: context,
      future: () => matrix.client.setProfileField(
        matrix.client.userID!,
        'displayname',
        {'displayname': input},
      ),
    );
    if (success.error == null) {
      updateProfile();
    }
  }

  void deleteAccountAction() async {
    final l10n = L10n.of(context);
    final confirmKeyword = l10n.settingsDeleteAccountInputKeyword;

    // 第一次确认
    final firstConfirm = await showOkCancelAlertDialog(
      context: context,
      title: l10n.settingsDeleteAccountConfirmTitle,
      message: l10n.settingsDeleteAccountConfirmMessage,
      okLabel: l10n.settingsDeleteAccountContinue,
      cancelLabel: l10n.cancel,
      isDestructive: true,
    );
    if (firstConfirm != OkCancelResult.ok) return;

    // 第二次确认，输入"注销"
    final input = await showTextInputDialog(
      useRootNavigator: false,
      context: context,
      title: l10n.settingsDeleteAccountInputTitle,
      message: l10n.settingsDeleteAccountInputMessage(confirmKeyword),
      okLabel: l10n.settingsDeleteAccountInputConfirm,
      cancelLabel: l10n.cancel,
      isDestructive: true,
    );
    if (input == null || input.trim() != confirmKeyword) {
      if (input != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.settingsDeleteAccountInputInvalid)),
        );
      }
      return;
    }

    final matrix = Matrix.of(context);
    final auth = context.read<PsygoAuthState>();
    final apiClient = context.read<PsygoApiClient>();

    final success = await showFutureLoadingDialog(
      context: context,
      future: () async {
        // 调用后端 API 注销账号（级联删除 Agent、Matrix 账号等）
        await apiClient.deleteAccount();
      },
    );

    final error = success.error;
    if (error != null) {
      debugPrint('[Settings] Delete account failed: $error');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.settingsDeleteAccountFailed)),
      );
      return;
    }

    try {
      debugPrint('[Settings] Account deletion successful, cleaning up...');

      // 1. 先清理 Matrix 客户端（本地清理，不调用服务端 API，因为账号已删除）
      final clients = List.from(matrix.widget.clients);
      for (final client in clients) {
        try {
          await client.dispose();
          debugPrint('[Settings] Matrix client disposed');
        } catch (e) {
          debugPrint('[Settings] Matrix client cleanup error: $e');
        }
      }
      // 清空客户端列表
      matrix.widget.clients.clear();

      // 2. 清除 Automate 认证状态
      // AuthGate 会监听到状态变化，自动处理：
      // - 切换窗口大小（PC端）
      // - 跳转到登录页
      // - 触发一键登录（移动端）
      // 注意：Matrix 客户端已经被清理，AuthGate 不会重复操作
      await auth.markLoggedOut();

      debugPrint('[Settings] Account deletion cleanup completed');
    } catch (e) {
      debugPrint('[Settings] Account deletion cleanup error: $e');
    }
  }

  void logoutAction() async {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth > 600;
    final dialogWidth = isDesktop ? 400.0 : screenWidth;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (context) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        child: Container(
          width: dialogWidth,
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部图标
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color:
                      theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.logout_rounded,
                  color: theme.colorScheme.primary,
                  size: 32,
                ),
              ),
              const SizedBox(height: 20),

              // 标题
              Text(
                l10n.settingsLogoutConfirmTitle,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 20),

              // 提示信息卡片
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F5E9), // 浅绿色背景
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.check_circle_outline,
                      color: Color(0xFF4CAF50),
                      size: 20,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.settingsLogoutConfirmHint,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF2E7D32),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // 按钮
              Row(
                children: [
                  // 取消按钮
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        l10n.cancel,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),

                  // 退出登录按钮
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(true),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: theme.colorScheme.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        l10n.logout,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    // 只有明确点击"退出登录"按钮才继续
    if (confirmed != true) {
      return;
    }

    // 在 context 失效前获取需要的引用
    final auth = context.read<PsygoAuthState>();

    try {
      debugPrint('[Settings] Starting logout...');

      // 清除 Automate 认证状态
      // AuthGate 会监听到状态变化，自动处理：
      // - 退出 Matrix 客户端
      // - 清除缓存
      // - 切换窗口大小
      // - 跳转到登录页
      await auth.markLoggedOut();

      debugPrint('[Settings] Logout completed');
    } catch (e) {
      debugPrint('[Settings] Logout error: $e');
    }
  }

  void submitFeedbackAction() async {
    final theme = Theme.of(context);

    // 弹出反馈对话框
    final result = await showDialog<Map<String, String>>(
      context: context,
      barrierDismissible: true,
      builder: (context) => _FeedbackDialog(theme: theme),
    );

    if (result == null) return;

    final content = result['content'] ?? '';
    final category = result['category'] ?? 'other';
    final replyEmail = result['reply_email'];

    if (content.isEmpty) return;

    // 获取设备信息
    String? deviceInfo;
    String? appVersion;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
      deviceInfo =
          '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {}

    final apiClient = context.read<PsygoApiClient>();
    final success = await showFutureLoadingDialog(
      context: context,
      future: () => apiClient.submitFeedback(
        content: content,
        category: category,
        replyEmail: replyEmail,
        appVersion: appVersion,
        deviceInfo: deviceInfo,
      ),
    );

    if (success.error == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).settingsFeedbackSubmitted)),
      );
    }
  }

  @override
  void initState() {
    WidgetsBinding.instance.addPostFrameCallback((_) => checkBootstrap());

    super.initState();
  }

  void checkBootstrap() async {
    final client = Matrix.of(context).clientOrNull;
    if (client == null || !client.encryptionEnabled) return;
    await client.accountDataLoading;
    await client.userDeviceKeysLoading;
    if (client.prevBatch == null) {
      await client.onSync.stream.first;
    }
    final crossSigning =
        await client.encryption?.crossSigning.isCached() ?? false;
    final needsBootstrap =
        await client.encryption?.keyManager.isCached() == false ||
            client.encryption?.crossSigning.enabled == false ||
            crossSigning == false;
    final isUnknownSession = client.isUnknownSession;
    setState(() {
      showChatBackupBanner = needsBootstrap || isUnknownSession;
    });
  }

  bool? crossSigningCached;
  bool? showChatBackupBanner;

  void firstRunBootstrapAction([_]) async {
    if (showChatBackupBanner != true) {
      showOkAlertDialog(
        context: context,
        title: L10n.of(context).chatBackup,
        message: L10n.of(context).onlineKeyBackupEnabled,
        okLabel: L10n.of(context).close,
      );
      return;
    }
    await BootstrapDialog(
      client: Matrix.of(context).client,
    ).show(context);
    checkBootstrap();
  }

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).clientOrNull;
    final userID = client?.userID;
    if (client != null && userID != null) {
      profileFuture ??= client.getProfileFromUserId(userID);
    }
    return SettingsView(this);
  }
}

enum AvatarAction { camera, file, remove }

/// 反馈对话框
class _FeedbackDialog extends StatefulWidget {
  final ThemeData theme;

  const _FeedbackDialog({required this.theme});

  @override
  State<_FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<_FeedbackDialog> {
  final _contentController = TextEditingController();
  final _emailController = TextEditingController();
  String _selectedCategory = 'suggestion';

  final _categories = [
    {'value': 'bug', 'icon': Icons.bug_report_outlined},
    {'value': 'suggestion', 'icon': Icons.lightbulb_outlined},
    {'value': 'complaint', 'icon': Icons.report_outlined},
    {'value': 'other', 'icon': Icons.more_horiz},
  ];

  @override
  void dispose() {
    _contentController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  String _categoryLabel(L10n l10n, String value) {
    switch (value) {
      case 'bug':
        return l10n.settingsFeedbackTypeBug;
      case 'suggestion':
        return l10n.settingsFeedbackTypeSuggestion;
      case 'complaint':
        return l10n.settingsFeedbackTypeComplaint;
      default:
        return l10n.settingsFeedbackTypeOther;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final l10n = L10n.of(context);

    return Dialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题
              Row(
                children: [
                  Icon(
                    Icons.feedback_outlined,
                    color: theme.colorScheme.primary,
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    l10n.settingsFeedbackTitle,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // 可滚动内容区域
              Flexible(
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context)
                      .copyWith(scrollbars: false),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 反馈类型选择
                        Text(
                          l10n.settingsFeedbackType,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _categories.map((cat) {
                            final isSelected =
                                _selectedCategory == cat['value'];
                            return ChoiceChip(
                              label: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    cat['icon'] as IconData,
                                    size: 16,
                                    color: isSelected
                                        ? theme.colorScheme.onPrimary
                                        : theme.colorScheme.onSurface,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _categoryLabel(
                                        l10n, cat['value'] as String),
                                  ),
                                ],
                              ),
                              selected: isSelected,
                              onSelected: (selected) {
                                if (selected) {
                                  setState(() => _selectedCategory =
                                      cat['value'] as String);
                                }
                              },
                            );
                          }).toList(),
                        ),
                        const SizedBox(height: 16),

                        // 反馈内容
                        Text(
                          l10n.settingsFeedbackContent,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _contentController,
                          maxLines: 4,
                          maxLength: 500,
                          decoration: InputDecoration(
                            hintText: l10n.settingsFeedbackContentHint,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // 回复邮箱（可选）
                        Text(
                          l10n.settingsFeedbackReplyEmailOptional,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          decoration: InputDecoration(
                            hintText: l10n.settingsFeedbackReplyEmailHint,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // 按钮（固定在底部）
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor:
                            theme.colorScheme.surfaceContainerHighest,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        l10n.cancel,
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
                      onPressed: () {
                        if (_contentController.text.trim().isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                l10n.settingsFeedbackContentRequired,
                              ),
                            ),
                          );
                          return;
                        }
                        Navigator.of(context).pop({
                          'content': _contentController.text.trim(),
                          'category': _selectedCategory,
                          'reply_email': _emailController.text.trim(),
                        });
                      },
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: theme.colorScheme.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(
                        l10n.submit,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
