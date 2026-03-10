import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:psygo/l10n/l10n.dart';
import '../core/config.dart';
import '../core/api_client.dart';
import '../models/hire_result.dart';
import '../repositories/agent_template_repository.dart';
import '../utils/platform_infos.dart';
import '../utils/localized_exception_extension.dart';
import 'dicebear_avatar_picker.dart';

/// 招聘（单步创建）
class CustomHireDialog extends StatefulWidget {
  final AgentTemplateRepository repository;
  final bool isDialog;
  final bool showRecruitGuide;
  final Future<void> Function()? onRecruitGuideCompleted;

  const CustomHireDialog({
    super.key,
    required this.repository,
    this.isDialog = false,
    this.showRecruitGuide = false,
    this.onRecruitGuideCompleted,
  });

  @override
  State<CustomHireDialog> createState() => _CustomHireDialogState();
}

class _CustomHireDialogState extends State<CustomHireDialog> {
  // 表单控制器
  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocusNode = FocusNode();
  final GlobalKey _guideStackKey = GlobalKey();
  final GlobalKey _avatarGuideKey = GlobalKey();
  final GlobalKey _nameGuideKey = GlobalKey();
  final GlobalKey _createGuideKey = GlobalKey();

  // 提交状态
  bool _isSubmitting = false;
  String? _error;

  // 头像 URL
  String? _avatarUrl;
  late bool _showRecruitGuide;
  bool _recruitGuideHandled = false;
  int _recruitGuideStepIndex = 0;

  // 名称长度限制
  static const int _maxNameLength = 20;
  static const double _guideBubbleWidth = 280;
  static const double _guideBubbleHeight = 176;
  static const double _guideHighlightPadding = 10;
  static const double _guideScreenPadding = 16;
  static const double _guideConnectorGap = 36;
  static const List<String> _zhGuideNameSuggestions = [
    '知夏',
    '明远',
    '安禾',
    '若溪',
  ];
  static const List<String> _enGuideNameSuggestions = [
    'Avery',
    'Iris',
    'Milo',
    'Clara',
  ];

  // 验证状态
  bool get _isNameValid =>
      _nameController.text.trim().isNotEmpty &&
      !_isNameNumericOnly &&
      !_isNameTooLong;
  bool get _isNameNumericOnly =>
      _nameController.text.isNotEmpty &&
      _nameController.text
          .trim()
          .split('')
          .every((c) => '0123456789'.contains(c));
  bool get _isNameTooLong =>
      _nameController.text.trim().length > _maxNameLength;
  bool get _isGuideNameSelectionLocked => _showRecruitGuide;

  @override
  void initState() {
    super.initState();
    _showRecruitGuide = widget.showRecruitGuide;
    // 初始化随机头像
    _initRandomAvatar();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_showRecruitGuide) {
        setState(() {});
        return;
      }
      _nameFocusNode.requestFocus();
    });
  }

  void _initRandomAvatar() {
    final random = Random();
    final styles = [
      'avataaars',
      'bottts',
      'fun-emoji',
      'adventurer',
      'adventurer-neutral',
      'big-smile',
      'lorelei',
      'notionists',
      'open-peeps',
      'personas',
      'pixel-art',
      'thumbs',
    ];
    final style = styles[random.nextInt(styles.length)];
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final seed =
        List.generate(8, (_) => chars[random.nextInt(chars.length)]).join();
    _avatarUrl =
        '${PsygoConfig.dicebearBaseUrl}/$style/png?seed=$seed&size=256';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  /// 提交创建
  Future<void> _onSubmit() async {
    if (_isSubmitting) return;

    // 直接创建前保留名称校验（与原步骤1一致）
    if (!_isNameValid) {
      setState(() {
        if (_nameController.text.trim().isEmpty) {
          _error = L10n.of(context).employeeNameRequired;
        } else if (_isNameNumericOnly) {
          _error = L10n.of(context).employeeNameCannotBeNumeric;
        } else if (_isNameTooLong) {
          _error = L10n.of(context).employeeNameTooLong;
        }
      });
      _nameFocusNode.requestFocus();
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    // 调用创建接口（异步），先返回 UI 结果让入职动画接管
    try {
      final accepted = await widget.repository.createCustomAgentWithPlugins(
        name: _nameController.text.trim(),
        plugins: null,
        avatarUrl: _avatarUrl,
      );
      await _completeRecruitGuideIfNeeded();
      if (!mounted) return;
      Navigator.of(context).pop(
        HireResult(
          responseFuture:
              widget.repository.waitCreateOperation(accepted.operationId),
          displayName: _nameController.text.trim(),
          agentId: accepted.agentId,
          avatarUrl: _avatarUrl,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _formatError(e);
        _isSubmitting = false;
      });
    }
  }

  String _formatError(Object error) {
    if (error is ApiException) {
      return error.message;
    }
    return error.toLocalizedString(
      context,
      ExceptionContext.customHireEmployee,
    );
  }

  Future<void> _completeRecruitGuideIfNeeded() async {
    if (_recruitGuideHandled || !widget.showRecruitGuide) {
      return;
    }
    _recruitGuideHandled = true;
    await widget.onRecruitGuideCompleted?.call();
  }

  void _dismissRecruitGuide() {
    if (!_showRecruitGuide) return;
    _nameFocusNode.requestFocus();
    setState(() {
      _showRecruitGuide = false;
    });
    unawaited(_completeRecruitGuideIfNeeded());
  }

  void _nextRecruitGuide() {
    final steps = _guideSteps(L10n.of(context));
    if (_recruitGuideStepIndex >= steps.length - 1) {
      _dismissRecruitGuide();
      return;
    }
    setState(() {
      _recruitGuideStepIndex++;
    });
  }

  Future<void> _handleGuidePrimaryAction(L10n l10n) async {
    switch (_recruitGuideStepIndex) {
      case 0:
        _nextRecruitGuide();
        return;
      case 1:
        if (!_isNameValid) {
          setState(() {
            if (_nameController.text.trim().isEmpty) {
              _error = l10n.employeeNameRequired;
            } else if (_isNameNumericOnly) {
              _error = l10n.employeeNameCannotBeNumeric;
            } else if (_isNameTooLong) {
              _error = l10n.employeeNameTooLong;
            }
          });
          _nameFocusNode.requestFocus();
          return;
        }
        _nextRecruitGuide();
        return;
      default:
        await _onSubmit();
    }
  }

  bool get _isGuidePrimaryActionEnabled {
    if (_isSubmitting) return false;
    if (_recruitGuideStepIndex == 1) {
      return _isNameValid;
    }
    return true;
  }

  void _handleNameChanged(String value) {
    setState(() {
      if (_error != null) {
        _error = null;
      }
    });
  }

  List<String> _guideNameSuggestions() {
    final languageCode = Localizations.localeOf(context).languageCode;
    if (languageCode == 'zh' || languageCode == 'yue') {
      return _zhGuideNameSuggestions;
    }
    return _enGuideNameSuggestions;
  }

  void _selectGuideNameSuggestion(String name) {
    _nameController.value = TextEditingValue(
      text: name,
      selection: TextSelection.collapsed(offset: name.length),
    );
    setState(() {
      _error = null;
    });

    if (_showRecruitGuide && _recruitGuideStepIndex == 1) {
      _nextRecruitGuide();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    return PopScope(
      canPop: !_isSubmitting,
      child: AbsorbPointer(
        absorbing: _isSubmitting,
        child: widget.isDialog
            ? _buildGuideFrame(_buildDialogContent(theme, l10n), theme, l10n)
            : GestureDetector(
                onTap: () {}, // 阻止点击传递到背景
                child: DraggableScrollableSheet(
                  initialChildSize: 0.9,
                  minChildSize: 0.3,
                  maxChildSize: 0.95,
                  snap: true,
                  snapSizes: const [0.9],
                  builder: (context, scrollController) {
                    return _buildGuideFrame(
                      Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surface,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(28),
                          ),
                        ),
                        child: Column(
                          children: [
                            // 顶部拖拽指示器 - 可拖拽区域
                            Container(
                              width: double.infinity,
                              color: Colors.transparent,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Center(
                                child: Container(
                                  width: 40,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.onSurfaceVariant
                                        .withValues(alpha: 0.4),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                              ),
                            ),
                            // 标题栏
                            _buildHeader(theme, l10n),
                            // 内容区域
                            Expanded(
                              child: ListView(
                                controller: scrollController,
                                padding:
                                    const EdgeInsets.fromLTRB(24, 16, 24, 24),
                                children: [
                                  _buildContent(theme, l10n),
                                ],
                              ),
                            ),
                            // 错误提示
                            if (_error != null) _buildErrorBanner(theme),
                            // 底部按钮
                            _buildActions(theme, l10n),
                          ],
                        ),
                      ),
                      theme,
                      l10n,
                    );
                  },
                ),
              ),
      ),
    );
  }

  /// PC 端 Dialog 样式
  Widget _buildDialogContent(ThemeData theme, L10n l10n) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 640),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题栏
          _buildHeader(theme, l10n),
          // 内容区域
          Flexible(
            child: ScrollConfiguration(
              behavior:
                  ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: _buildContent(theme, l10n),
              ),
            ),
          ),
          // 错误提示
          if (_error != null) _buildErrorBanner(theme),
          // 底部按钮
          _buildActions(theme, l10n),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, L10n l10n) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 18),
      child: Row(
        children: [
          // 左侧图标
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.person_add_alt_1_rounded,
              color: theme.colorScheme.primary,
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          // 标题和副标题
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.customHire,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.customHireDescription,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(ThemeData theme, L10n l10n) {
    return _buildBasicInfoStep(theme, l10n);
  }

  Widget _buildGuideFrame(Widget child, ThemeData theme, L10n l10n) {
    return Stack(
      key: _guideStackKey,
      children: [
        child,
        if (_showRecruitGuide)
          Positioned.fill(
            child: _buildRecruitGuideOverlay(theme, l10n),
          ),
      ],
    );
  }

  List<_RecruitGuideStepData> _guideSteps(L10n l10n) {
    return [
      _RecruitGuideStepData(
        targetKey: _avatarGuideKey,
        title: l10n.recruitGuideStepAvatarTitle,
        description: l10n.recruitGuideStepAvatarBody,
      ),
      _RecruitGuideStepData(
        targetKey: _nameGuideKey,
        title: l10n.recruitGuideStepNameTitle,
        description: l10n.recruitGuideStepNameBody,
      ),
      _RecruitGuideStepData(
        targetKey: _createGuideKey,
        title: l10n.recruitGuideStepCreateTitle,
        description: l10n.recruitGuideStepCreateBody,
      ),
    ];
  }

  Widget _buildRecruitGuideOverlay(ThemeData theme, L10n l10n) {
    final steps = _guideSteps(l10n);
    final currentStepIndex = _recruitGuideStepIndex.clamp(0, steps.length - 1);
    final currentStep = steps[currentStepIndex];

    return LayoutBuilder(
      builder: (context, constraints) {
        final targetRect = _resolveGuideTargetRect(currentStep.targetKey);
        if (targetRect == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _showRecruitGuide) {
              setState(() {});
            }
          });
          return const SizedBox.shrink();
        }

        final highlightRect = targetRect.inflate(_guideHighlightPadding);
        final bubbleSize = _resolveGuideBubbleSize(
          availableSize: Size(constraints.maxWidth, constraints.maxHeight),
          theme: theme,
          title: currentStep.title,
          description: currentStep.description,
        );
        final bubbleLayout = _buildGuideBubbleLayout(
          Size(constraints.maxWidth, constraints.maxHeight),
          highlightRect,
          bubbleSize,
        );

        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _RecruitGuideScrimPainter(
                    highlightRect: highlightRect,
                    color: Colors.black.withValues(alpha: 0.72),
                  ),
                ),
              ),
            ),
            ..._buildGuideBlockerRegions(
              Size(constraints.maxWidth, constraints.maxHeight),
              highlightRect,
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _RecruitGuideConnectorPainter(
                    start: bubbleLayout.connectorStart,
                    end: bubbleLayout.connectorEnd,
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                ),
              ),
            ),
            Positioned(
              left: highlightRect.left,
              top: highlightRect.top,
              width: highlightRect.width,
              height: highlightRect.height,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.18),
                        blurRadius: 18,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: bubbleLayout.left,
              top: bubbleLayout.top,
              width: bubbleSize.width,
              height: bubbleSize.height,
              child: _buildGuideBubble(
                theme: theme,
                l10n: l10n,
                title: currentStep.title,
                description: currentStep.description,
                currentStep: currentStepIndex + 1,
                totalSteps: steps.length,
                isLastStep: currentStepIndex == steps.length - 1,
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _buildGuideBlockerRegions(Size size, Rect highlightRect) {
    return [
      Positioned(
        left: 0,
        top: 0,
        right: 0,
        height: max(0.0, highlightRect.top),
        child: _buildGuideBlocker(),
      ),
      Positioned(
        left: 0,
        top: highlightRect.top,
        width: max(0.0, highlightRect.left),
        height: max(0.0, highlightRect.height),
        child: _buildGuideBlocker(),
      ),
      Positioned(
        left: highlightRect.right,
        top: highlightRect.top,
        width: max(0.0, size.width - highlightRect.right),
        height: max(0.0, highlightRect.height),
        child: _buildGuideBlocker(),
      ),
      Positioned(
        left: 0,
        top: highlightRect.bottom,
        right: 0,
        height: max(0.0, size.height - highlightRect.bottom),
        child: _buildGuideBlocker(),
      ),
    ];
  }

  Widget _buildGuideBlocker() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: const SizedBox.expand(),
    );
  }

  Rect? _resolveGuideTargetRect(GlobalKey targetKey) {
    final targetContext = targetKey.currentContext;
    final stackContext = _guideStackKey.currentContext;
    if (targetContext == null || stackContext == null) {
      return null;
    }

    final targetBox = targetContext.findRenderObject();
    final stackBox = stackContext.findRenderObject();
    if (targetBox is! RenderBox ||
        stackBox is! RenderBox ||
        !targetBox.attached ||
        !stackBox.attached) {
      return null;
    }

    final origin = targetBox.localToGlobal(Offset.zero, ancestor: stackBox);
    return origin & targetBox.size;
  }

  _RecruitGuideBubbleLayout _buildGuideBubbleLayout(
    Size size,
    Rect highlightRect,
    Size bubbleSize,
  ) {
    final bubbleWidth = bubbleSize.width;
    final bubbleHeight = bubbleSize.height;
    final spaceAbove =
        highlightRect.top - _guideScreenPadding - _guideConnectorGap;
    final spaceBelow = size.height -
        highlightRect.bottom -
        _guideScreenPadding -
        _guideConnectorGap;
    final showAbove = spaceAbove >= bubbleHeight
        ? true
        : (spaceBelow >= bubbleHeight ? false : spaceAbove > spaceBelow);
    final maxLeft = max(
      _guideScreenPadding,
      size.width - bubbleWidth - _guideScreenPadding,
    );
    final left = (highlightRect.center.dx - (bubbleWidth / 2))
        .clamp(_guideScreenPadding, maxLeft)
        .toDouble();
    final top = showAbove
        ? max(
            _guideScreenPadding,
            highlightRect.top - bubbleHeight - _guideConnectorGap,
          ).toDouble()
        : min(
            size.height - bubbleHeight - _guideScreenPadding,
            highlightRect.bottom + _guideConnectorGap,
          ).toDouble();
    final connectorX = highlightRect.center.dx
        .clamp(left + 28, left + bubbleWidth - 28)
        .toDouble();

    return _RecruitGuideBubbleLayout(
      left: left,
      top: top,
      connectorStart: Offset(
        connectorX,
        showAbove ? top + bubbleHeight : top,
      ),
      connectorEnd: Offset(
        highlightRect.center.dx,
        showAbove ? highlightRect.top : highlightRect.bottom,
      ),
    );
  }

  Size _resolveGuideBubbleSize({
    required Size availableSize,
    required ThemeData theme,
    required String title,
    required String description,
  }) {
    final isDesktop = PlatformInfos.isDesktop;
    final maxWidth =
        max(240.0, availableSize.width - (_guideScreenPadding * 2));
    final preferredWidth = isDesktop ? 500.0 : _guideBubbleWidth;
    final width = min(preferredWidth, maxWidth);
    const horizontalPadding = 36.0;
    final titleWidth = max(120.0, width - horizontalPadding - 52.0);
    final bodyWidth = max(120.0, width - horizontalPadding);
    final titleHeight = _measureGuideTextHeight(
      text: title,
      maxWidth: titleWidth,
      style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: const Color(0xFF111827),
          ) ??
          const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
    );
    final bodyHeight = _measureGuideTextHeight(
      text: description,
      maxWidth: bodyWidth,
      style: theme.textTheme.bodyMedium?.copyWith(
            color: const Color(0xFF374151),
            height: 1.45,
            fontWeight: FontWeight.w500,
          ) ??
          const TextStyle(
            fontSize: 14,
            height: 1.45,
            fontWeight: FontWeight.w500,
          ),
    );
    final preferredHeight =
        18.0 + max(titleHeight, 22.0) + 14.0 + bodyHeight + 16.0 + 52.0 + 16.0;
    final minHeight = isDesktop ? 220.0 : _guideBubbleHeight;
    final maxHeight = max(
      minHeight,
      min(
        isDesktop ? 320.0 : 280.0,
        availableSize.height - (_guideScreenPadding * 2),
      ),
    );
    final height = preferredHeight.clamp(minHeight, maxHeight).toDouble();
    return Size(width, height);
  }

  double _measureGuideTextHeight({
    required String text,
    required double maxWidth,
    required TextStyle style,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: null,
    )..layout(maxWidth: maxWidth);
    return painter.height;
  }

  Widget _buildGuideBubble({
    required ThemeData theme,
    required L10n l10n,
    required String title,
    required String description,
    required int currentStep,
    required int totalSteps,
    required bool isLastStep,
  }) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 28,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: const Color(0xFF111827),
                    ),
                  ),
                ),
                Text(
                  '$currentStep/$totalSteps',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: const Color(0xFF6B7280),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  description,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF374151),
                    height: 1.45,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButton(
                  onPressed: _isGuidePrimaryActionEnabled
                      ? () => unawaited(_handleGuidePrimaryAction(l10n))
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                  ),
                  child: Text(
                    isLastStep ? l10n.confirm : l10n.next,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 第1步：基本信息
  Widget _buildBasicInfoStep(ThemeData theme, L10n l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 头像选择
        Center(
          child: KeyedSubtree(
            key: _avatarGuideKey,
            child: DiceBearAvatarPicker(
              initialAvatarUrl: _avatarUrl,
              onAvatarChanged: (url) {
                setState(() {
                  _avatarUrl = url;
                });
              },
              size: 88,
            ),
          ),
        ),
        const SizedBox(height: 20),

        // 员工名称
        Container(
          key: _nameGuideKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildInputField(
                theme: theme,
                controller: _nameController,
                focusNode: _nameFocusNode,
                label: l10n.employeeName,
                hint: _isGuideNameSelectionLocked
                    ? l10n.selectEmployeeNameExample
                    : l10n.enterEmployeeName,
                icon: Icons.badge_outlined,
                isError: _isNameNumericOnly || _isNameTooLong,
                errorText: _isNameNumericOnly
                    ? l10n.employeeNameCannotBeNumeric
                    : (_isNameTooLong ? l10n.employeeNameTooLong : null),
                enabled: !_isSubmitting,
                readOnly: _isGuideNameSelectionLocked,
                onChanged: _handleNameChanged,
                maxLength: _maxNameLength,
                showCounter: true,
              ),
              const SizedBox(height: 12),
              _buildGuideNameSuggestions(theme, l10n),
            ],
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildGuideNameSuggestions(ThemeData theme, L10n l10n) {
    final suggestions = _guideNameSuggestions();
    final selectedName = _nameController.text.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.employeeNameExamples,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: suggestions.map((name) {
            final isSelected = selectedName == name;
            return ChoiceChip(
              label: Text(name),
              selected: isSelected,
              onSelected: _isSubmitting
                  ? null
                  : (_) => _selectGuideNameSuggestion(name),
              backgroundColor: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.45),
              selectedColor: theme.colorScheme.primaryContainer,
              side: BorderSide(
                color: isSelected
                    ? theme.colorScheme.primary.withValues(alpha: 0.45)
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
              ),
              labelStyle: theme.textTheme.bodyMedium?.copyWith(
                color: isSelected
                    ? theme.colorScheme.onPrimaryContainer
                    : theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              visualDensity: VisualDensity.compact,
            );
          }).toList(),
        ),
      ],
    );
  }

  // ===== Helper Widgets =====

  Widget _buildInputField({
    required ThemeData theme,
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    FocusNode? focusNode,
    int minLines = 1,
    int maxLines = 1,
    bool enabled = true,
    bool readOnly = false,
    bool isError = false,
    String? errorText,
    bool isOptional = false,
    ValueChanged<String>? onChanged,
    int? maxLength,
    bool showCounter = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标签行
        Row(
          children: [
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            if (isOptional) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  L10n.of(context).optional,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),
        // 输入框
        TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: Icon(icon, size: 22),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: isError
                    ? theme.colorScheme.error
                    : theme.colorScheme.outlineVariant,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(
                color: isError
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
                width: 2,
              ),
            ),
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.3),
            alignLabelWithHint: minLines > 1,
            contentPadding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: minLines > 1 ? 16 : 14,
            ),
            counterText: showCounter && maxLength != null
                ? '${controller.text.length}/$maxLength'
                : null,
            counterStyle: TextStyle(
              color: controller.text.length > (maxLength ?? 0)
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          minLines: minLines,
          maxLines: maxLines,
          enabled: enabled,
          readOnly: readOnly,
          showCursor: !readOnly,
          enableInteractiveSelection: !readOnly,
          onChanged: onChanged,
        ),
        // 错误提示
        if (errorText != null) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 14,
                color: theme.colorScheme.error,
              ),
              const SizedBox(width: 4),
              Text(
                errorText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildErrorBanner(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 0, 24, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 20,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _error = null),
            icon: Icon(
              Icons.close_rounded,
              size: 18,
              color: theme.colorScheme.error,
            ),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(ThemeData theme, L10n l10n) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: widget.isDialog
            ? const BorderRadius.vertical(bottom: Radius.circular(24))
            : null,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          // 返回/取消按钮
          Expanded(
            child: OutlinedButton(
              onPressed: _isSubmitting ? null : () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                side: BorderSide(
                  color: theme.colorScheme.outline.withValues(alpha: 0.5),
                ),
              ),
              child: Text(
                l10n.cancel,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(width: 14),
          // 创建按钮（直接提交）
          Expanded(
            child: FilledButton(
              key: _createGuideKey,
              onPressed: _isSubmitting ? null : _onSubmit,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: _isSubmitting
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: theme.colorScheme.onPrimary,
                      ),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          l10n.createEmployee,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.add_rounded, size: 20),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RecruitGuideStepData {
  final GlobalKey targetKey;
  final String title;
  final String description;

  const _RecruitGuideStepData({
    required this.targetKey,
    required this.title,
    required this.description,
  });
}

class _RecruitGuideBubbleLayout {
  final double left;
  final double top;
  final Offset connectorStart;
  final Offset connectorEnd;

  const _RecruitGuideBubbleLayout({
    required this.left,
    required this.top,
    required this.connectorStart,
    required this.connectorEnd,
  });
}

class _RecruitGuideScrimPainter extends CustomPainter {
  final Rect highlightRect;
  final Color color;

  const _RecruitGuideScrimPainter({
    required this.highlightRect,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final highlightPath = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          highlightRect,
          const Radius.circular(18),
        ),
      );
    final overlayPath = Path.combine(
      PathOperation.difference,
      backgroundPath,
      highlightPath,
    );
    canvas.drawPath(
      overlayPath,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _RecruitGuideScrimPainter oldDelegate) {
    return oldDelegate.highlightRect != highlightRect ||
        oldDelegate.color != color;
  }
}

class _RecruitGuideConnectorPainter extends CustomPainter {
  final Offset start;
  final Offset end;
  final Color color;

  const _RecruitGuideConnectorPainter({
    required this.start,
    required this.end,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final vector = end - start;
    final distance = vector.distance;
    if (distance <= 0) return;

    final direction = vector / distance;
    final dotPaint = Paint()..color = color;
    const step = 10.0;

    for (double current = 0; current < distance; current += step) {
      final point = start + (direction * current);
      canvas.drawCircle(point, current == 0 ? 2.8 : 1.8, dotPaint);
    }

    canvas.drawCircle(end, 4.5, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _RecruitGuideConnectorPainter oldDelegate) {
    return oldDelegate.start != start ||
        oldDelegate.end != end ||
        oldDelegate.color != color;
  }
}
