import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

/// 协议 WebView 页面
/// 用于展示用户协议和隐私政策
class AgreementWebViewPage extends StatefulWidget {
  final String title;
  final String url;

  const AgreementWebViewPage({
    super.key,
    required this.title,
    required this.url,
  });

  /// 检查当前平台是否支持 WebView
  static bool get _supportsWebView {
    if (kIsWeb) return false;
    // webview_flutter 支持：Android, iOS, macOS
    // 不支持：Linux, Windows
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  }

  /// 打开协议页面
  /// 支持 WebView 的平台使用 in-app WebView，其他平台使用外部浏览器
  static Future<void> open(BuildContext context, String title, String url) async {
    if (!_supportsWebView) {
      // 不支持 WebView 的平台：使用外部浏览器
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } else {
      // 支持 WebView 的平台：使用 in-app WebView
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => AgreementWebViewPage(title: title, url: url),
        ),
      );
    }
  }

  @override
  State<AgreementWebViewPage> createState() => _AgreementWebViewPageState();
}

class _AgreementWebViewPageState extends State<AgreementWebViewPage> {
  late final WebViewController _controller;
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            setState(() {
              _isLoading = true;
              _errorMessage = null;
            });
          },
          onPageFinished: (url) {
            setState(() => _isLoading = false);
          },
          onWebResourceError: (error) {
            setState(() {
              _isLoading = false;
              _errorMessage = '加载失败，请稍后重试';
            });
          },
          onNavigationRequest: (request) {
            // 只允许加载协议页面，阻止跳转到其他页面
            if (request.url.startsWith(widget.url) ||
                request.url == widget.url) {
              return NavigationDecision.navigate;
            }
            // 其他链接用外部浏览器打开
            launchUrl(Uri.parse(request.url), mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Stack(
        children: [
          if (_errorMessage != null)
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 48,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _errorMessage!,
                    style: TextStyle(color: theme.colorScheme.error),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _errorMessage = null;
                        _isLoading = true;
                      });
                      _controller.reload();
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            )
          else
            WebViewWidget(controller: _controller),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
        ],
      ),
    );
  }
}
