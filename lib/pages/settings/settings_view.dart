import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:psygo/backend/api_client.dart';
import 'package:psygo/config/app_config.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/utils/app_update_service.dart';
import 'package:psygo/utils/app_update_test.dart';
import 'package:psygo/utils/fluffy_share.dart';
import 'package:psygo/utils/platform_infos.dart';
import 'package:psygo/widgets/avatar.dart';
import 'package:psygo/widgets/matrix.dart';
import 'package:psygo/widgets/branded_progress_indicator.dart';
import '../../widgets/mxc_image_viewer.dart';
import 'settings.dart';

class SettingsView extends StatelessWidget {
  final SettingsController controller;

  const SettingsView(this.controller, {super.key});

  /// 检查更新
  Future<void> _checkForUpdate(BuildContext context) async {
    final api = context.read<PsygoApiClient>();
    final updateService = AppUpdateService(api);
    // showNoUpdateHint 为 true 表示没有更新时也提示
    await updateService.checkAndPrompt(context, showNoUpdateHint: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final client = Matrix.of(context).clientOrNull;

    // 如果客户端已经退出，显示空白或加载状态
    if (client == null) {
      return const Scaffold(
        body: Center(child: BrandedProgressIndicator()),
      );
    }

    // 主题切换后，GoRouter 的路由信息可能被缓存，导致高亮状态错误
    // 改用更可靠的方式：只在用户点击后短暂高亮，不依赖路由状态
    final accountManageUrl = client.wellKnown?.additionalProperties
        .tryGetMap<String, Object?>('org.matrix.msc2965.authentication')
        ?.tryGet<String>('account');
    return Row(
      children: [
        Expanded(
          child: Scaffold(
            appBar: AppBar(
              title: Text(L10n.of(context).settings),
              leading: Center(
                child: BackButton(
                  onPressed: () => context.go('/rooms'),
                ),
              ),
              automaticallyImplyLeading: false,
            ),
            body: ListTileTheme(
              iconColor: theme.colorScheme.onSurface,
              child: ListView(
                key: const Key('SettingsListViewContent'),
                children: <Widget>[
                  // 用户信息卡片
                  FutureBuilder<Profile>(
                    future: controller.profileFuture,
                    builder: (context, snapshot) {
                      final profile = snapshot.data;
                      final avatar = profile?.avatarUrl;
                      final mxid =
                          Matrix.of(context).client.userID ?? l10n.user;
                      final displayname =
                          profile?.displayName ?? mxid.localpart ?? mxid;
                      return Container(
                        margin: const EdgeInsets.all(16),
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              theme.colorScheme.primaryContainer.withAlpha(120),
                              theme.colorScheme.secondaryContainer
                                  .withAlpha(80),
                            ],
                          ),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: theme.colorScheme.shadow.withAlpha(15),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            // 头像带装饰环
                            Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                  colors: [
                                    theme.colorScheme.primary,
                                    theme.colorScheme.tertiary,
                                  ],
                                ),
                              ),
                              child: Container(
                                padding: const EdgeInsets.all(3),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: theme.colorScheme.surface,
                                ),
                                child: Avatar(
                                  mxContent: avatar,
                                  name: displayname,
                                  size: Avatar.defaultSize * 2,
                                  onTap: avatar != null
                                      ? () => showDialog(
                                            context: context,
                                            builder: (_) =>
                                                MxcImageViewer(avatar),
                                          )
                                      : null,
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // 显示昵称
                                  Text(
                                    displayname,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                      color: theme.colorScheme.onSurface,
                                      letterSpacing: -0.3,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  // 用户ID带复制按钮
                                  GestureDetector(
                                    onTap: () =>
                                        FluffyShare.share(mxid, context),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: theme.colorScheme.surface
                                            .withAlpha(200),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              mxid,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: theme.colorScheme
                                                    .onSurfaceVariant,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Icon(
                                            Icons.copy_rounded,
                                            size: 14,
                                            color: theme.colorScheme.primary,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 8),

                  // 账号管理卡片
                  if (accountManageUrl != null)
                    _buildSettingsCard(
                      theme,
                      children: [
                        _buildCardListTile(
                          theme,
                          icon: Icons.account_circle_outlined,
                          title: Text(L10n.of(context).manageAccount),
                          trailing:
                              const Icon(Icons.open_in_new_outlined, size: 20),
                          onTap: () => launchUrlString(
                            accountManageUrl,
                            mode: LaunchMode.inAppBrowserView,
                          ),
                        ),
                      ],
                    ),

                  const SizedBox(height: 12),

                  // 偏好设置卡片
                  _buildSettingsCard(
                    theme,
                    title: l10n.settingsPreferenceSectionTitle,
                    children: [
                      _buildCardListTile(
                        theme,
                        icon: Icons.palette_outlined,
                        title: Text(L10n.of(context).changeTheme),
                        onTap: () => context.go('/rooms/settings/style'),
                      ),
                      _buildDivider(theme),
                      _buildCardListTile(
                        theme,
                        icon: Icons.notifications_outlined,
                        title: Text(L10n.of(context).notifications),
                        onTap: () =>
                            context.go('/rooms/settings/notifications'),
                      ),
                      _buildDivider(theme),
                      _buildCardListTile(
                        theme,
                        icon: Icons.forum_outlined,
                        title: Text(L10n.of(context).chat),
                        onTap: () => context.go('/rooms/settings/chat'),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // 关于应用卡片
                  _buildSettingsCard(
                    theme,
                    title: l10n.settingsAboutSectionTitle,
                    children: [
                      _buildCardListTile(
                        theme,
                        icon: Icons.feedback_outlined,
                        title: Text(l10n.settingsFeedback),
                        onTap: controller.submitFeedbackAction,
                      ),
                      _buildDivider(theme),
                      _buildCardListTile(
                        theme,
                        icon: Icons.privacy_tip_outlined,
                        title: Text(l10n.settingsPrivacyPolicy),
                        trailing:
                            const Icon(Icons.open_in_new_outlined, size: 20),
                        onTap: () => launchUrlString(
                          AppConfig.privacyUrl.toString(),
                          mode: LaunchMode.inAppBrowserView,
                        ),
                      ),
                      _buildDivider(theme),
                      _buildCardListTile(
                        theme,
                        icon: Icons.info_outline_rounded,
                        title: Text(L10n.of(context).about),
                        onTap: () => PlatformInfos.showDialog(context),
                      ),
                      _buildDivider(theme),
                      Builder(
                        builder: (context) {
                          final screenWidth = MediaQuery.of(context).size.width;
                          final isDesktop = screenWidth > 600;
                          return _buildCardListTile(
                            theme,
                            icon: isDesktop
                                ? Icons.downloading_rounded
                                : Icons.system_update_outlined,
                            title: Text(l10n.settingsCheckUpdates),
                            onTap: () => _checkForUpdate(context),
                          );
                        },
                      ),
                      if (kDebugMode) ...[
                        _buildDivider(theme),
                        _buildCardListTile(
                          theme,
                          icon: Icons.bug_report_outlined,
                          title: Text(l10n.settingsTestUpdateDialog),
                          subtitle: Text(l10n.settingsTestUpdateDialogSubtitle),
                          onTap: () => AppUpdateTest.showTestDialog(context),
                        ),
                      ],
                    ],
                  ),

                  const SizedBox(height: 12),

                  // 危险操作卡片
                  _buildSettingsCard(
                    theme,
                    title: l10n.settingsAccountActionsTitle,
                    isDanger: true,
                    children: [
                      _buildCardListTile(
                        theme,
                        icon: Icons.logout_outlined,
                        iconColor: theme.colorScheme.error,
                        title: Text(
                          l10n.logout,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                        onTap: controller.logoutAction,
                      ),
                      _buildDivider(theme),
                      _buildCardListTile(
                        theme,
                        icon: Icons.delete_forever_outlined,
                        iconColor: theme.colorScheme.error,
                        title: Text(
                          l10n.settingsDeleteAccountTitle,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                        subtitle: Text(
                          l10n.settingsDeleteAccountSubtitle,
                          style: TextStyle(
                              color: theme.colorScheme.error
                                  .withValues(alpha: 0.7)),
                        ),
                        onTap: controller.deleteAccountAction,
                      ),
                    ],
                  ),

                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 构建设置卡片容器
  Widget _buildSettingsCard(
    ThemeData theme, {
    String? title,
    required List<Widget> children,
    bool isDanger = false,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDanger
              ? [
                  theme.colorScheme.errorContainer.withValues(alpha: 0.15),
                  theme.colorScheme.errorContainer.withValues(alpha: 0.08),
                ]
              : [
                  theme.colorScheme.surfaceContainerLow,
                  theme.colorScheme.surface,
                ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDanger
              ? theme.colorScheme.error.withValues(alpha: 0.2)
              : theme.colorScheme.outlineVariant.withValues(alpha: 0.15),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDanger
                ? theme.colorScheme.error.withValues(alpha: 0.05)
                : theme.colorScheme.primary.withValues(alpha: 0.03),
            blurRadius: 12,
            spreadRadius: -2,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: isDanger
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
          ...children,
        ],
      ),
    );
  }

  /// 构建卡片内的列表项
  Widget _buildCardListTile(
    ThemeData theme, {
    required IconData icon,
    Color? iconColor,
    required Widget title,
    Widget? subtitle,
    Widget? trailing,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        splashColor:
            (iconColor ?? theme.colorScheme.primary).withValues(alpha: 0.15),
        highlightColor:
            (iconColor ?? theme.colorScheme.primary).withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: (iconColor ?? theme.colorScheme.primary)
                      .withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: (iconColor ?? theme.colorScheme.primary)
                        .withValues(alpha: 0.15),
                    width: 1,
                  ),
                ),
                child: Icon(
                  icon,
                  size: 22,
                  color: iconColor ?? theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DefaultTextStyle(
                      style: theme.textTheme.bodyLarge!.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      child: title,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      DefaultTextStyle(
                        style: theme.textTheme.bodySmall!.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        child: subtitle,
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                IconTheme(
                  data: IconThemeData(
                    color: theme.colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                  child: trailing,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 构建分隔线
  Widget _buildDivider(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(left: 68),
      child: Divider(
        height: 1,
        thickness: 1,
        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.1),
      ),
    );
  }
}
