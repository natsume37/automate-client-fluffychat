/// The main login page with one-click login.
/// User is automatically redirected to this page if credentials are not found or invalid.
library;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:provider/provider.dart';
import 'package:psygo/backend/backend.dart';
import 'package:psygo/services/one_click_login.dart';
import 'package:psygo/pages/login_signup/login_flow_mixin.dart';
import 'package:psygo/utils/localized_exception_extension.dart';
import 'package:psygo/widgets/agreement_webview_page.dart';
import 'login_signup_view.dart';

class LoginSignup extends StatefulWidget {
  const LoginSignup({super.key});

  @override
  LoginSignupController createState() => LoginSignupController();
}

class LoginSignupController extends State<LoginSignup> with WidgetsBindingObserver, LoginFlowMixin {
  @override
  PsygoApiClient get backend => context.read<PsygoApiClient>();

  String? phoneError;
  bool loading = false;
  bool agreedToEula = false;
  bool _isInAuthFlow = false; // 是否正在进行授权流程

  // 协议 URL（从 API 获取）
  String? _termsUrl;
  String? _privacyUrl;
  bool _loadingAgreements = false;

  // LoginFlowMixin 实现
  @override
  void setLoginError(String? error) {
    setState(() => phoneError = error);
  }

  @override
  void setLoading(bool value) {
    setState(() => loading = value);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 当 app 从后台恢复时，如果正在授权流程中，关闭可能残留的授权页面
    if (state == AppLifecycleState.resumed && _isInAuthFlow) {
      debugPrint('App resumed during auth flow, closing auth page to prevent black screen');
      OneClickLoginService.quitLoginPage();
      setState(() {
        _isInAuthFlow = false;
        loading = false;
      });
    }
  }

  void toggleEulaAgreement() {
    setState(() => agreedToEula = !agreedToEula);
  }

  /// One-click login (Aliyun Official SDK)
  /// 新流程：调用 /api/auth/one-click-login 直接完成登录
  void oneClickLogin() async {
    // Web platform doesn't support one-click login
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('网页版暂不支持一键登录，请点击下方"登录其他账号"')),
      );
      return;
    }

    if (!await _ensureEulaAccepted()) {
      return;
    }

    setState(() {
      phoneError = null;
      loading = true;
      _isInAuthFlow = true; // 标记进入授权流程
    });

    try {
      // 阿里云控制台获取的密钥
      // 通过 --dart-define=ALIYUN_SECRET_KEY=your-secret-key 指定
      const secretKey = String.fromEnvironment('ALIYUN_SECRET_KEY', defaultValue: '');

      debugPrint('=== 使用官方 SDK 进行一键登录 ===');

      // 执行完整的一键登录流程，获取 fusion_token
      final fusionToken = await OneClickLoginService.performOneClickLogin(
        secretKey: secretKey,
        timeout: 10000,
      );

      debugPrint('=== 调用后端一键登录 ===');
      final authResponse = await backend.oneClickLogin(fusionToken);

      if (!mounted) return;

      final success = await handlePostLogin(authResponse);

      _isInAuthFlow = false;
      if (success) {
        await OneClickLoginService.quitLoginPage();
      }
    } on SwitchLoginMethodException {
      // 用户点击了"其他方式登录"按钮（但按钮已隐藏，理论上不会触发）
      // 不跳转，只显示错误提示
      debugPrint('用户选择其他登录方式（不应该发生）');
      setState(() {
        _isInAuthFlow = false;
        phoneError = '当前仅支持本机号码一键登录';
        loading = false;
      });
    } catch (e, stackTrace) {
      debugPrint('一键登录错误: $e');
      debugPrint('堆栈: $stackTrace');
      // 出错时关闭授权页
      _isInAuthFlow = false;
      await OneClickLoginService.quitLoginPage();
      setState(() {
        phoneError = (e as Object).toLocalizedString(
          context,
          ExceptionContext.oneClickLogin,
        );
        loading = false;
      });
    }
  }

  Future<bool> _ensureEulaAccepted() async {
    if (agreedToEula) return true;

    final shouldAccept = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('同意最终用户许可协议'),
        content: const Text('继续操作前，请阅读并同意《最终用户许可协议》。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('同意'),
          ),
        ],
      ),
    );

    if (shouldAccept == true) {
      setState(() => agreedToEula = true);
      return true;
    }

    return false;
  }

  void showEula() async {
    if (_termsUrl == null) {
      // URL 未加载，尝试重新加载
      await _loadAgreements();
      if (_termsUrl == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法加载用户协议，请检查网络连接')),
        );
        return;
      }
    }
    await AgreementWebViewPage.open(context, '用户协议', _termsUrl!);
  }

  void showPrivacyPolicy() async {
    if (_privacyUrl == null) {
      // URL 未加载，尝试重新加载
      await _loadAgreements();
      if (_privacyUrl == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法加载隐私政策，请检查网络连接')),
        );
        return;
      }
    }
    await AgreementWebViewPage.open(context, '隐私政策', _privacyUrl!);
  }

  @override
  Widget build(BuildContext context) => LoginSignupView(this);
}
