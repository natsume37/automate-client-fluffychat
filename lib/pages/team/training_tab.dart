import 'package:flutter/material.dart';

import 'package:psygo/config/themes.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/utils/localized_exception_extension.dart';

import '../../models/plugin.dart';
import '../../repositories/plugin_repository.dart';
import '../../utils/retry_helper.dart';
import '../../widgets/empty_state.dart';
import '../../widgets/skeleton_card.dart';
import '../../widgets/plugin_card.dart';
import '../../widgets/training_detail_sheet.dart';

/// 培训市场 Tab
/// 展示可安装的插件（技能培训）
class TrainingTab extends StatefulWidget {
  const TrainingTab({super.key});

  @override
  State<TrainingTab> createState() => TrainingTabState();
}

class TrainingTabState extends State<TrainingTab>
    with AutomaticKeepAliveClientMixin {
  final PluginRepository _repository = PluginRepository();

  List<Plugin> _plugins = [];
  bool _isLoading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadPlugins();
  }

  @override
  void dispose() {
    _repository.dispose();
    super.dispose();
  }

  Future<void> _loadPlugins() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final plugins = await RetryHelper.withRetry(
        operation: () => _repository.getPluginsWithStats(),
        maxRetries: 2,
        retryDelayMs: 3000,
        onRetry: (attempt, error) {
          debugPrint('Retrying plugins load, attempt $attempt');
        },
      );
      if (mounted) {
        setState(() {
          _plugins = plugins;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toLocalizedString(
            context,
            ExceptionContext.loadTrainingList,
          );
          _isLoading = false;
        });
      }
    }
  }

  /// 公开的刷新方法，供外部调用
  Future<void> refresh() => _loadPlugins();

  Future<void> _onPluginTap(Plugin plugin) async {
    final isDesktop = FluffyThemes.isColumnMode(context);

    if (isDesktop) {
      // PC端使用居中对话框
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
          backgroundColor: Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: TrainingDetailSheet(
              plugin: plugin,
              onInstalled: () {
                _loadPlugins();
              },
              isDialog: true,
            ),
          ),
        ),
      );
    } else {
      // 移动端使用底部弹窗
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        isDismissible: true,
        enableDrag: true,
        builder: (context) => TrainingDetailSheet(
          plugin: plugin,
          onInstalled: () {
            _loadPlugins();
          },
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final l10n = L10n.of(context);

    return RefreshIndicator(
      onRefresh: _loadPlugins,
      color: theme.colorScheme.primary,
      child: _buildBody(context, theme, l10n),
    );
  }

  Widget _buildBody(BuildContext context, ThemeData theme, L10n l10n) {
    // 加载状态
    if (_isLoading) {
      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: 5,
        itemBuilder: (context, index) => const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: SkeletonCard(height: 88),
        ),
      );
    }

    // 错误状态 - 包裹在可滚动组件中以支持下拉刷新
    if (_error != null && _plugins.isEmpty) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        theme.colorScheme.errorContainer.withAlpha(120),
                        theme.colorScheme.errorContainer.withAlpha(60),
                      ],
                    ),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.error.withAlpha(20),
                        blurRadius: 24,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: Center(
                    child: Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer.withAlpha(150),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.error_outline_rounded,
                        size: 36,
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  l10n.errorLoadingData,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _loadPlugins,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  label: Text(
                    l10n.tryAgain,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 空状态 - 包裹在可滚动组件中以支持下拉刷新
    if (_plugins.isEmpty) {
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: EmptyState(
            icon: Icons.school_outlined,
            title: l10n.noTrainingAvailable,
            subtitle: l10n.noTrainingHint,
          ),
        ),
      );
    }

    // 插件列表 - PC端使用响应式网格布局，移动端使用列表布局
    final isDesktop = FluffyThemes.isColumnMode(context);

    if (isDesktop) {
      // PC端：响应式网格布局，根据屏幕宽度自动调整列数
      return LayoutBuilder(
        builder: (context, constraints) {
          // 计算最佳列数：每列最小宽度 280，最大宽度 400
          const minCardWidth = 280.0;
          final availableWidth = constraints.maxWidth - 32; // 减去左右 padding

          // 计算列数（至少 2 列，最多 5 列）
          int crossAxisCount = (availableWidth / minCardWidth).floor();
          crossAxisCount = crossAxisCount.clamp(2, 5);

          // 计算实际卡片宽度
          final cardWidth = availableWidth / crossAxisCount - 12; // 减去间距

          // 根据卡片宽度调整宽高比（数值越小，卡片越高）
          final aspectRatio =
              cardWidth > 350 ? 3.2 : (cardWidth > 300 ? 2.8 : 2.5);

          return GridView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: 32,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: aspectRatio,
            ),
            itemCount: _plugins.length,
            itemBuilder: (context, index) {
              final plugin = _plugins[index];
              return PluginCard(
                plugin: plugin,
                onTap: () => _onPluginTap(plugin),
              );
            },
          );
        },
      );
    }

    // 移动端：列表布局
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: 96,
      ),
      itemCount: _plugins.length,
      itemBuilder: (context, index) {
        final plugin = _plugins[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: PluginCard(
            plugin: plugin,
            onTap: () => _onPluginTap(plugin),
          ),
        );
      },
    );
  }
}
