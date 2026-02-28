/// Phone number + verification code login page.
/// Desktop: Centered single column with glassmorphic card
/// Mobile: Single column with LoginScaffold
library;

import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:psygo/backend/backend.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/pages/login_signup/login_flow_mixin.dart';
import 'package:psygo/utils/localized_exception_extension.dart';
import 'package:psygo/widgets/agreement_webview_page.dart';
import 'package:psygo/utils/platform_infos.dart';
import 'package:psygo/utils/window_service.dart';
import 'package:psygo/widgets/branded_progress_indicator.dart';

class PhoneLoginPage extends StatefulWidget {
  const PhoneLoginPage({super.key});

  @override
  PhoneLoginController createState() => PhoneLoginController();
}

class PhoneLoginController extends State<PhoneLoginPage> with LoginFlowMixin {
  final TextEditingController phoneController = TextEditingController();
  final TextEditingController codeController = TextEditingController();

  @override
  PsygoApiClient get backend => context.read<PsygoApiClient>();

  String? phoneError;
  String? codeError;
  bool loading = false;
  bool agreedToEula = false;
  bool codeSent = false;
  int countdown = 0; // 倒计时秒数
  Timer? _countdownTimer;

  // 协议 URL（从 API 获取）
  String? _termsUrl;
  String? _privacyUrl;
  bool _loadingAgreements = false;

  @override
  void initState() {
    super.initState();
    _loadAgreements();
  }

  /// 加载协议 URL
  Future<void> _loadAgreements() async {
    if (_loadingAgreements) return;
    setState(() => _loadingAgreements = true);

    try {
      final agreements = await backend.getAgreements();
      if (!mounted) return;

      for (final agreement in agreements) {
        if (agreement.type == 'terms') {
          _termsUrl = agreement.url;
        } else if (agreement.type == 'privacy') {
          _privacyUrl = agreement.url;
        }
      }
      setState(() {});
    } catch (e) {
      debugPrint('Failed to load agreements: $e');
      // 静默失败，用户点击时会再次尝试或提示错误
    } finally {
      if (mounted) {
        setState(() => _loadingAgreements = false);
      }
    }
  }

  // LoginFlowMixin 实现
  @override
  void setLoginError(String? error) {
    if (!mounted) return;
    setState(() => codeError = error);
  }

  @override
  void setLoading(bool value) {
    if (!mounted) return;
    setState(() => loading = value);
  }

  void toggleEulaAgreement() {
    setState(() => agreedToEula = !agreedToEula);
  }

  void requestVerificationCode() async {
    final l10n = L10n.of(context);
    if (!await _ensureEulaAccepted()) {
      return;
    }

    if (phoneController.text.isEmpty) {
      setState(() => phoneError = l10n.authPhoneRequired);
      return;
    }

    if (!phoneController.text.isPhoneNumber) {
      setState(() => phoneError = l10n.authPhoneInvalid);
      return;
    }

    setState(() {
      phoneError = null;
      loading = true;
    });

    try {
      await backend.sendVerificationCode(phoneController.text);
      if (!mounted) return;

      setState(() {
        codeSent = true;
        loading = false;
        countdown = 60; // 启动60秒倒计时
      });

      // 启动倒计时
      _startCountdown();

      _showSuccessToast(l10n.authCodeSentToast);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        phoneError = e.toLocalizedString(
          context,
          ExceptionContext.requestVerifyCode,
        );
        loading = false;
      });
    }
  }

  // 显示成功提示（与主题风格一致）
  void _showSuccessToast(String message) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accentColor =
        isDark ? const Color(0xFF00FF9F) : const Color(0xFF00A878);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(
                  Icons.check_circle_outline,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        backgroundColor: isDark ? const Color(0xFF00B386) : accentColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        margin: const EdgeInsets.all(16),
        elevation: 8,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // 启动倒计时
  void _startCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (countdown > 0) {
        setState(() {
          countdown--;
        });
      } else {
        timer.cancel();
      }
    });
  }

  /// 验证码登录
  void verifyAndLogin() async {
    final l10n = L10n.of(context);
    if (!await _ensureEulaAccepted()) {
      return;
    }

    if (phoneController.text.isEmpty) {
      setState(() => phoneError = l10n.authPhoneRequired);
      return;
    }

    if (codeController.text.isEmpty) {
      setState(() => codeError = l10n.authCodeRequired);
      return;
    }

    setState(() {
      phoneError = null;
      codeError = null;
      loading = true;
    });

    try {
      debugPrint('=== 调用后端短信登录 ===');
      final authResponse = await backend.smsLogin(
        phoneController.text,
        codeController.text,
      );
      if (!mounted) return;

      await handlePostLogin(authResponse);
    } catch (e) {
      debugPrint('验证码登录错误: $e');
      if (!mounted) return;
      setState(() {
        codeError = e.toLocalizedString(
          context,
          ExceptionContext.verifyCode,
        );
        loading = false;
      });
    }
  }

  Future<bool> _ensureEulaAccepted() async {
    if (agreedToEula) return true;

    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : const Color(0xFF1A2332);
    final accentColor =
        isDark ? const Color(0xFF00FF9F) : const Color(0xFF00A878);

    final shouldAccept = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [
                    const Color(0xFF0A1628).withValues(alpha: 0.95),
                    const Color(0xFF0D2233).withValues(alpha: 0.95),
                    const Color(0xFF0F3D3E).withValues(alpha: 0.95),
                  ]
                : [
                    const Color(0xFFF0F4F8).withValues(alpha: 0.98),
                    const Color(0xFFE8EFF5).withValues(alpha: 0.98),
                    const Color(0xFFE0F2F1).withValues(alpha: 0.98),
                  ],
          ),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(
            color: isDark
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.black.withValues(alpha: 0.08),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: isDark
                  ? Colors.black.withValues(alpha: 0.3)
                  : Colors.black.withValues(alpha: 0.08),
              blurRadius: 20,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 顶部装饰条
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.2)
                            : Colors.black.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // 标题
                  Text(
                    l10n.authServiceAgreementTitle,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: textColor,
                      letterSpacing: 0.5,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),

                  // 说明文字
                  Text.rich(
                    TextSpan(
                      text: l10n.authAgreementReadHint,
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.7)
                            : const Color(0xFF666666),
                        height: 1.6,
                      ),
                      children: [
                        WidgetSpan(
                          alignment: PlaceholderAlignment.baseline,
                          baseline: TextBaseline.alphabetic,
                          child: _ClickableLink(
                            text: l10n.authTermsOfService,
                            accentColor: accentColor,
                            onTap: () {
                              Navigator.of(context).pop(false);
                              showEula();
                            },
                          ),
                        ),
                        TextSpan(text: l10n.authAgreementAnd),
                        WidgetSpan(
                          alignment: PlaceholderAlignment.baseline,
                          baseline: TextBaseline.alphabetic,
                          child: _ClickableLink(
                            text: l10n.authPrivacyPolicy,
                            accentColor: accentColor,
                            onTap: () {
                              Navigator.of(context).pop(false);
                              showPrivacyPolicy();
                            },
                          ),
                        ),
                        TextSpan(text: l10n.authAgreementConsentSuffix),
                      ],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),

                  // 同意按钮（使用渐变样式）
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: isDark
                            ? [
                                const Color(0xFF00B386),
                                const Color(0xFF00D4A1),
                              ]
                            : [
                                accentColor.withValues(alpha: 0.9),
                                accentColor,
                              ],
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color:
                              (isDark ? const Color(0xFF00D3A1) : accentColor)
                                  .withValues(alpha: 0.3),
                          blurRadius: 15,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () => Navigator.of(context).pop(true),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          alignment: Alignment.center,
                          child: Text(
                            l10n.authAgreeAndContinue,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 不同意按钮
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      foregroundColor: isDark
                          ? Colors.white.withValues(alpha: 0.5)
                          : const Color(0xFF999999),
                    ),
                    child: Text(
                      l10n.authDisagree,
                      style: TextStyle(fontSize: 15),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    if (shouldAccept == true) {
      setState(() => agreedToEula = true);
      return true;
    }

    return false;
  }

  void showEula() async {
    final l10n = L10n.of(context);
    if (_termsUrl == null) {
      // URL 未加载，尝试重新加载
      await _loadAgreements();
      if (_termsUrl == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.authAgreementLoadFailedTerms)),
        );
        return;
      }
    }
    await AgreementWebViewPage.open(
        context, l10n.authTermsOfService, _termsUrl!);
  }

  void showPrivacyPolicy() async {
    final l10n = L10n.of(context);
    if (_privacyUrl == null) {
      // URL 未加载，尝试重新加载
      await _loadAgreements();
      if (_privacyUrl == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.authAgreementLoadFailedPrivacy)),
        );
        return;
      }
    }
    await AgreementWebViewPage.open(
        context, l10n.authPrivacyPolicy, _privacyUrl!);
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    phoneController.dispose();
    codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 统一使用新的响应式设计，自动适配所有屏幕尺寸
    return _buildDesktopLayout(context);
  }

  /// Desktop: Centered single-column layout with dark gradient background and glassmorphism
  Widget _buildDesktopLayout(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Theme detection
          final theme = Theme.of(context);
          final isDark = theme.brightness == Brightness.dark;

          // Responsive sizing based on available width
          final screenWidth = constraints.maxWidth;
          final screenHeight = constraints.maxHeight;

          // Responsive breakpoints
          // 超小屏: < 400px (小手机竖屏)
          // 小屏幕: 400-600px (普通手机竖屏)
          // 中等屏幕: 600-900px (平板竖屏/小窗口)
          // 大屏幕: > 900px (平板横屏/桌面)
          final isExtraSmallScreen = screenWidth < 400;
          final isSmallScreen = screenWidth >= 400 && screenWidth < 600;
          final isMediumScreen = screenWidth >= 600 && screenWidth < 900;

          // Logo 尺寸响应式 - 更大 Logo
          final logoSize = isExtraSmallScreen
              ? 100.0
              : (isSmallScreen ? 110.0 : (isMediumScreen ? 120.0 : 130.0));
          final logoImageHeight = isExtraSmallScreen
              ? 55.0
              : (isSmallScreen ? 60.0 : (isMediumScreen ? 65.0 : 70.0));

          // 卡片宽度响应式
          final cardMaxWidth = (isExtraSmallScreen || isSmallScreen)
              ? screenWidth * 0.92
              : (isMediumScreen ? 420.0 : 480.0);

          // 间距响应式 - Logo与卡片间距
          final cardSpacingTop = isExtraSmallScreen
              ? 28.0
              : (isSmallScreen ? 32.0 : (isMediumScreen ? 40.0 : 48.0));
          final verticalPadding = screenHeight < 700 ? 12.0 : 24.0;
          final horizontalPadding =
              (isExtraSmallScreen || isSmallScreen) ? 12.0 : 20.0;

          // Theme-based colors
          final bgColors = isDark
              ? [
                  const Color(0xFF0A1628), // Deep blue
                  const Color(0xFF0D2233), // Mid blue
                  const Color(0xFF0F3D3E), // Teal
                ]
              : [
                  const Color(0xFFF0F4F8), // Light blue-gray
                  const Color(0xFFE8EFF5), // Lighter blue
                  const Color(0xFFE0F2F1), // Light cyan
                ];

          final textColor = isDark ? Colors.white : const Color(0xFF1A2332);
          final accentColor =
              isDark ? const Color(0xFF00FF9F) : const Color(0xFF00A878);

          // PC端使用圆角无边框窗口
          Widget content = Container(
            width: double.infinity,
            height: double.infinity,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: bgColors,
              ),
              // PC端添加圆角
              borderRadius:
                  PlatformInfos.isDesktop ? BorderRadius.circular(6) : null,
            ),
            child: Stack(
              children: [
                // Background glowing orbs with pulsing animation
                _buildGlowingOrbs(isDark),

                // PC端：顶部拖拽区域
                if (PlatformInfos.isDesktop)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 40,
                    child: WindowDragArea(
                      child: Container(color: Colors.transparent),
                    ),
                  ),

                // PC端：窗口控制按钮（最小化、关闭，不显示最大化）
                if (PlatformInfos.isDesktop)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: WindowControlButtons(
                      showMaximize: false,
                      iconColor: isDark
                          ? Colors.white.withValues(alpha: 0.6)
                          : Colors.black.withValues(alpha: 0.4),
                    ),
                  ),

                // Main content - centered without scrolling
                Center(
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: horizontalPadding,
                      vertical: verticalPadding,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Logo with floating animation
                        _AnimatedFloatingLogo(
                          size: logoSize,
                          imageHeight: logoImageHeight,
                          isDark: isDark,
                        ),
                        SizedBox(height: cardSpacingTop),

                        // Glassmorphic login card
                        ConstrainedBox(
                          constraints: BoxConstraints(maxWidth: cardMaxWidth),
                          child: _buildGlassmorphicCard(
                            context,
                            isExtraSmallScreen || isSmallScreen,
                            isDark,
                            textColor,
                            accentColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );

          // PC端：添加圆角裁剪
          if (PlatformInfos.isDesktop) {
            content = ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: content,
            );
          }

          return content;
        },
      ),
    );
  }

  /// Build animated glowing orbs for background
  Widget _buildGlowingOrbs(bool isDark) {
    // Theme-based glow colors
    final glowColor1 =
        isDark ? const Color(0xFF00D4FF) : const Color(0xFF4FC3F7);
    final glowColor2 =
        isDark ? const Color(0xFF00FF9F) : const Color(0xFF81C784);
    final glowColor3 =
        isDark ? const Color(0xFF0099FF) : const Color(0xFF64B5F6);

    return Stack(
      children: [
        // Top-left glow
        Positioned(
          top: -200,
          left: -200,
          child: _PulsingGlow(
            size: 500,
            color: glowColor1,
            delay: Duration.zero,
            isDark: isDark,
          ),
        ),
        // Bottom-right glow
        Positioned(
          bottom: -200,
          right: -200,
          child: _PulsingGlow(
            size: 500,
            color: glowColor2,
            delay: const Duration(seconds: 2),
            isDark: isDark,
          ),
        ),
        // Center glow
        Positioned.fill(
          child: Center(
            child: _PulsingGlow(
              size: 500,
              color: glowColor3,
              delay: const Duration(seconds: 1),
              isDark: isDark,
            ),
          ),
        ),
      ],
    );
  }

  /// Glassmorphic card container
  Widget _buildGlassmorphicCard(
    BuildContext context,
    bool isSmallScreen,
    bool isDark,
    Color textColor,
    Color accentColor,
  ) {
    final horizontalPadding = isSmallScreen ? 16.0 : 22.0;
    final verticalPadding = isSmallScreen ? 18.0 : 24.0;

    // Theme-based card colors
    final cardBgColor = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.white.withValues(alpha: 0.4);
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.white.withValues(alpha: 0.5);
    final shadowColor = isDark
        ? Colors.black.withValues(alpha: 0.3)
        : Colors.black.withValues(alpha: 0.1);

    return Container(
      decoration: BoxDecoration(
        color: cardBgColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: borderColor,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: shadowColor,
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: verticalPadding,
            ),
            child: _buildGlassmorphicLoginForm(
              context,
              isSmallScreen,
              isDark,
              textColor,
              accentColor,
            ),
          ),
        ),
      ),
    );
  }

  /// Login form content inside glassmorphic card
  Widget _buildGlassmorphicLoginForm(
    BuildContext context,
    bool isSmallScreen,
    bool isDark,
    Color textColor,
    Color accentColor,
  ) {
    final l10n = L10n.of(context);
    final titleFontSize = isSmallScreen ? 20.0 : 22.0;
    final spacingTop = isSmallScreen ? 14.0 : 16.0;
    final spacingBetween = isSmallScreen ? 10.0 : 12.0;

    final subtitleColor =
        isDark ? Colors.white.withValues(alpha: 0.6) : const Color(0xFF5A6A7A);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Title
        Text(
          l10n.authLoginOrRegister,
          style: TextStyle(
            fontSize: titleFontSize,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
        ),
        SizedBox(height: spacingTop),

        // Phone input with glow on focus
        // 获取验证码后也允许修改手机号；修改后重置验证码状态
        _GlowingTextField(
          controller: phoneController,
          hintText: l10n.authPhoneInputHint,
          prefixIcon: Icons.phone_outlined,
          errorText: phoneError,
          readOnly: loading,
          keyboardType: TextInputType.phone,
          textInputAction:
              codeSent ? TextInputAction.next : TextInputAction.done,
          isDark: isDark,
          accentColor: accentColor,
          onChanged: (value) {
            setState(() {
              phoneError = null;
              if (codeSent) {
                codeSent = false;
                codeError = null;
                codeController.clear();
              }
            });
          },
          onSubmitted: (_) {
            if (!codeSent && !loading && countdown == 0) {
              requestVerificationCode();
            }
          },
        ),
        SizedBox(height: spacingBetween),

        // Verification code input (shown after code is sent)
        if (codeSent) ...[
          _GlowingTextField(
            controller: codeController,
            hintText: l10n.authCodeInputHint,
            prefixIcon: Icons.lock_outline,
            errorText: codeError,
            readOnly: loading,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            isDark: isDark,
            accentColor: accentColor,
            onChanged: (value) {
              setState(() => codeError = null);
            },
            onSubmitted: (_) {
              if (!loading) {
                verifyAndLogin();
              }
            },
          ),
          const SizedBox(height: 12),
          // Resend button
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: countdown > 0 ? null : requestVerificationCode,
              child: Text(
                countdown > 0
                    ? l10n.authResendCountdown(countdown)
                    : l10n.authResendCode,
                style: TextStyle(
                  color: countdown > 0
                      ? (isDark
                          ? Colors.white.withValues(alpha: 0.4)
                          : const Color(0xFF9E9E9E))
                      : accentColor,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          SizedBox(height: spacingBetween),
        ],

        // Agreement checkbox
        Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: Checkbox(
                value: agreedToEula,
                onChanged:
                    (loading || codeSent) ? null : (_) => toggleEulaAgreement(),
                fillColor: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.selected)) {
                    return accentColor;
                  }
                  return Colors.transparent;
                }),
                side: BorderSide(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.3)
                      : Colors.black.withValues(alpha: 0.3),
                  width: 2,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  style: TextStyle(
                    fontSize: 11,
                    color: subtitleColor,
                  ),
                  children: [
                    TextSpan(text: l10n.authAgreementPrefix),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: _ClickableLink(
                        text: l10n.authTermsOfService,
                        accentColor: accentColor,
                        onTap: loading ? () {} : showEula,
                        fontSize: 11,
                      ),
                    ),
                    TextSpan(text: l10n.authAgreementAnd),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: _ClickableLink(
                        text: l10n.authPrivacyPolicy,
                        accentColor: accentColor,
                        onTap: loading ? () {} : showPrivacyPolicy,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: spacingBetween),

        // Get verification code or Login button
        if (!codeSent)
          _GradientButton(
            onPressed:
                (loading || countdown > 0) ? null : requestVerificationCode,
            loading: loading,
            text: countdown > 0
                ? l10n.authRetryCountdown(countdown)
                : l10n.authGetVerificationCode,
            isDark: isDark,
            accentColor: accentColor,
          )
        else
          _GradientButton(
            onPressed: loading ? null : verifyAndLogin,
            loading: loading,
            text: l10n.authLoginOrRegister,
            isDark: isDark,
            accentColor: accentColor,
          ),
      ],
    );
  }
}

// ============================================================================
// Custom Components for Glassmorphic Design
// ============================================================================

/// Pulsing glow orb for background animation
class _PulsingGlow extends StatefulWidget {
  final double size;
  final Color color;
  final Duration delay;
  final bool isDark;

  const _PulsingGlow({
    required this.size,
    required this.color,
    required this.delay,
    required this.isDark,
  });

  @override
  State<_PulsingGlow> createState() => _PulsingGlowState();
}

class _PulsingGlowState extends State<_PulsingGlow>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacityAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 4),
      vsync: this,
    );

    // Light mode uses softer opacity
    final minOpacity = widget.isDark ? 0.2 : 0.15;
    final maxOpacity = widget.isDark ? 0.4 : 0.25;

    _opacityAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: minOpacity, end: maxOpacity),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: maxOpacity, end: minOpacity),
        weight: 50,
      ),
    ]).animate(_controller);

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.0, end: 1.1),
        weight: 50,
      ),
      TweenSequenceItem(
        tween: Tween<double>(begin: 1.1, end: 1.0),
        weight: 50,
      ),
    ]).animate(_controller);

    Future.delayed(widget.delay, () {
      if (mounted) {
        _controller.repeat();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  widget.color.withValues(alpha: _opacityAnimation.value),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.7],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Floating logo with animation
class _AnimatedFloatingLogo extends StatefulWidget {
  final double size;
  final double imageHeight;
  final bool isDark;

  const _AnimatedFloatingLogo({
    this.size = 120.0,
    this.imageHeight = 65.0,
    this.isDark = true,
  });

  @override
  State<_AnimatedFloatingLogo> createState() => _AnimatedFloatingLogoState();
}

class _AnimatedFloatingLogoState extends State<_AnimatedFloatingLogo>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _floatAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 3),
      vsync: this,
    )..repeat(reverse: true);

    _floatAnimation = Tween<double>(begin: 0, end: -10).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _floatAnimation,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, _floatAnimation.value),
          child: Image.asset(
            widget.isDark
                ? 'assets/logo_dark.png'
                : 'assets/logo_transparent.png',
            width: widget.size,
            height: widget.size,
          ),
        );
      },
    );
  }
}

/// Glowing text field with focus animation
class _GlowingTextField extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final IconData prefixIcon;
  final String? errorText;
  final bool readOnly;
  final TextInputType keyboardType;
  final bool isDark;
  final Color accentColor;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;

  const _GlowingTextField({
    required this.controller,
    required this.hintText,
    required this.prefixIcon,
    this.errorText,
    required this.readOnly,
    required this.keyboardType,
    required this.isDark,
    required this.accentColor,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
  });

  @override
  State<_GlowingTextField> createState() => _GlowingTextFieldState();
}

class _GlowingTextFieldState extends State<_GlowingTextField> {
  bool _isFocused = false;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(() {
      setState(() {
        _isFocused = _focusNode.hasFocus;
      });
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Theme-based colors
    final textColor = widget.isDark ? Colors.white : const Color(0xFF1A2332);
    final hintColor = widget.isDark
        ? Colors.white.withValues(alpha: 0.4)
        : const Color(0xFF9E9E9E);
    final iconColor = widget.isDark
        ? Colors.white.withValues(alpha: 0.5)
        : const Color(0xFF757575);
    final fillColor = widget.isDark
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.black.withValues(alpha: 0.03);
    final borderColor = widget.isDark
        ? Colors.white.withValues(alpha: 0.1)
        : Colors.black.withValues(alpha: 0.15);
    final focusBorderColor =
        widget.isDark ? const Color(0xFF00D4FF) : widget.accentColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _isFocused ? focusBorderColor : borderColor,
              width: _isFocused ? 2 : 1,
            ),
            boxShadow: _isFocused
                ? [
                    BoxShadow(
                      color: widget.accentColor.withValues(alpha: 0.3),
                      blurRadius: 30,
                      spreadRadius: 0,
                    ),
                  ]
                : null,
          ),
          child: TextField(
            controller: widget.controller,
            focusNode: _focusNode,
            readOnly: widget.readOnly,
            keyboardType: widget.keyboardType,
            textInputAction: widget.textInputAction,
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            style: TextStyle(
              color: textColor,
              fontSize: 14,
            ),
            decoration: InputDecoration(
              hintText: widget.hintText,
              hintStyle: TextStyle(
                color: hintColor,
              ),
              prefixIcon: Icon(
                widget.prefixIcon,
                color: iconColor,
                size: 18,
              ),
              filled: true,
              fillColor: fillColor,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
          ),
        ),
        if (widget.errorText != null) ...[
          const SizedBox(height: 8),
          Text(
            widget.errorText!,
            style: const TextStyle(
              color: Color(0xFFFF6B6B),
              fontSize: 13,
            ),
          ),
        ],
      ],
    );
  }
}

/// Gradient button with loading state
class _GradientButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool loading;
  final String text;
  final bool isDark;
  final Color accentColor;

  const _GradientButton({
    required this.onPressed,
    required this.loading,
    required this.text,
    this.isDark = true,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    // Theme-based gradient colors
    final gradientColors = isDark
        ? [
            const Color(0xFF00B386),
            const Color(0xFF00D4A1),
          ]
        : [
            accentColor.withValues(alpha: 0.9),
            accentColor,
          ];

    final shadowColor = isDark
        ? const Color(0xFF00D3A1).withValues(alpha: 0.3)
        : accentColor.withValues(alpha: 0.25);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: gradientColors,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: shadowColor,
            blurRadius: 15,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: loading ? null : onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            alignment: Alignment.center,
            child: loading
                ? const BrandedProgressIndicator.small(
                    backgroundColor: Colors.transparent,
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        text,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Icon(
                        Icons.arrow_forward,
                        color: Colors.white,
                        size: 14,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// Clickable link with hover effect
class _ClickableLink extends StatefulWidget {
  final String text;
  final Color accentColor;
  final VoidCallback onTap;
  final double fontSize;

  const _ClickableLink({
    required this.text,
    required this.accentColor,
    required this.onTap,
    this.fontSize = 14,
  });

  @override
  State<_ClickableLink> createState() => _ClickableLinkState();
}

class _ClickableLinkState extends State<_ClickableLink> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: _isHovered ? widget.accentColor : Colors.transparent,
                width: 1.5,
              ),
            ),
          ),
          child: Text(
            widget.text,
            style: TextStyle(
              fontSize: widget.fontSize,
              color: _isHovered
                  ? widget.accentColor.withValues(alpha: 0.8)
                  : widget.accentColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Extensions
// ============================================================================

extension on String {
  static final RegExp _phoneRegex =
      RegExp(r'^[+]*[(]{0,1}[0-9]{1,4}[)]{0,1}[-\s\./0-9]*$');

  bool get isPhoneNumber => _phoneRegex.hasMatch(this);
}
