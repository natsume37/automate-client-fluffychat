import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:go_router/go_router.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/widgets/layouts/login_scaffold.dart';
import 'package:psygo/utils/platform_infos.dart';
import 'package:psygo/widgets/branded_progress_indicator.dart';
import 'login_signup.dart';

class LoginSignupView extends StatelessWidget {
  final LoginSignupController controller;

  const LoginSignupView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textTheme = theme.textTheme;
    final l10n = L10n.of(context);

    return LoginScaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
      ),
      body: Column(
        children: [
          // Main content - centered
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Product Logo with scale animation
                    Hero(
                      tag: 'product-logo',
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0.8, end: 1.0),
                        duration: const Duration(milliseconds: 800),
                        curve: Curves.elasticOut,
                        builder: (context, scale, child) => Transform.scale(
                          scale: scale,
                          child: child,
                        ),
                        child: Image.asset(
                          'assets/logo_transparent.png',
                          height: 120,
                        ),
                      ),
                    ),

                    const SizedBox(height: 32),

                    // EULA Agreement Checkbox
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Checkbox(
                            value: controller.agreedToEula,
                            onChanged: controller.loading
                                ? null
                                : (_) => controller.toggleEulaAgreement(),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                          Flexible(
                            child: Text.rich(
                              TextSpan(
                                style: textTheme.bodyMedium,
                                children: [
                                  TextSpan(text: l10n.authAgreementPrefix),
                                  WidgetSpan(
                                    child: InkWell(
                                      onTap: controller.loading
                                          ? null
                                          : controller.showEula,
                                      child: Text(
                                        l10n.authTermsOfService,
                                        style: textTheme.bodyMedium?.copyWith(
                                          color: theme.colorScheme.primary,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                  TextSpan(text: l10n.authAgreementAnd),
                                  WidgetSpan(
                                    child: InkWell(
                                      onTap: controller.loading
                                          ? null
                                          : controller.showPrivacyPolicy,
                                      child: Text(
                                        l10n.authPrivacyPolicy,
                                        style: textTheme.bodyMedium?.copyWith(
                                          color: theme.colorScheme.primary,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // One-click login button (Mobile only - SDK not supported on desktop)
                    if (PlatformInfos.isMobile) ...[
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              theme.colorScheme.primary,
                              theme.colorScheme.primary.withValues(alpha: 0.85),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.3),
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            foregroundColor: theme.colorScheme.onPrimary,
                            shadowColor: Colors.transparent,
                            minimumSize: const Size.fromHeight(56),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: controller.loading
                              ? null
                              : controller.oneClickLogin,
                          icon: controller.loading
                              ? const BrandedProgressIndicator.small(
                                  backgroundColor: Colors.transparent,
                                )
                              : const Icon(Icons.phone_android, size: 28),
                          label: Text(
                            controller.loading
                                ? l10n.authLoginInProgress
                                : l10n.authOneClickButton,
                            style: TextStyle(
                              fontSize: textTheme.titleMedium?.fontSize,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ],

                    // SMS verification code login (Desktop/Web only)
                    if (kIsWeb || PlatformInfos.isDesktop) ...[
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              theme.colorScheme.primary,
                              theme.colorScheme.primary.withValues(alpha: 0.85),
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.3),
                              blurRadius: 12,
                              offset: const Offset(0, 6),
                            ),
                          ],
                        ),
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            foregroundColor: theme.colorScheme.onPrimary,
                            shadowColor: Colors.transparent,
                            minimumSize: const Size.fromHeight(56),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                          ),
                          onPressed: controller.loading
                              ? null
                              : () => context.go('/login/phone'),
                          icon: controller.loading
                              ? const BrandedProgressIndicator.small(
                                  backgroundColor: Colors.transparent,
                                )
                              : const Icon(Icons.sms_outlined, size: 28),
                          label: Text(
                            controller.loading
                                ? l10n.authLoginInProgress
                                : l10n.authSmsLoginButton,
                            style: TextStyle(
                              fontSize: textTheme.titleMedium?.fontSize,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ],

                    // Error message
                    if (controller.phoneError != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        controller.phoneError!,
                        style: textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
