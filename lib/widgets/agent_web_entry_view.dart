import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Inline WebView used by agent "web entry" (reverse-tunnel) feature.
///
/// Notes:
/// - `webview_flutter` supports Android/iOS/macOS only.
/// - On unsupported platforms, callers should open the URL in external browser instead.
class AgentWebEntryView extends StatefulWidget {
  final String url;

  const AgentWebEntryView({
    super.key,
    required this.url,
  });

  static bool get supportsWebView {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
  }

  @override
  State<AgentWebEntryView> createState() => _AgentWebEntryViewState();
}

class _AgentWebEntryViewState extends State<AgentWebEntryView> {
  late final WebViewController _controller;
  bool _isLoading = true;
  String? _errorMessage;
  late final String _allowedOrigin;

  @override
  void initState() {
    super.initState();
    _allowedOrigin = Uri.parse(widget.url).origin;
    _initWebView();
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _isLoading = true;
              _errorMessage = null;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() => _isLoading = false);
          },
          onWebResourceError: (err) {
            if (!mounted) return;
            // iOS may report subresource failures (e.g. favicon) via
            // onWebResourceError. Only treat main-frame errors as fatal.
            if (err.isForMainFrame == false) {
              debugPrint(
                '[AgentWebEntryView] Subresource load failed: '
                'code=${err.errorCode} desc=${err.description} url=${err.url}',
              );
              return;
            }

            debugPrint(
              '[AgentWebEntryView] Main-frame load failed: '
              'code=${err.errorCode} desc=${err.description} url=${err.url}',
            );

            setState(() {
              _isLoading = false;
              _errorMessage = '加载失败（${err.errorCode}）：${err.description}';
            });
          },
          onNavigationRequest: (request) {
            // Keep navigation inside the same origin. External links are opened
            // in system browser to avoid unexpected origin hops inside the app.
            final uri = Uri.tryParse(request.url);
            if (uri == null) {
              return NavigationDecision.prevent;
            }
            if (uri.scheme == 'about') {
              return NavigationDecision.navigate;
            }
            if (uri.origin == _allowedOrigin) {
              return NavigationDecision.navigate;
            }
            launchUrl(uri, mode: LaunchMode.externalApplication);
            return NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Stack(
      children: [
        if (_errorMessage != null)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
    );
  }
}
