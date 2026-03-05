import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_windows/webview_windows.dart';

/// Inline WebView for Windows using WebView2 runtime.
class WindowsInlineWebView extends StatefulWidget {
  final String url;
  final String loadFailedMessage;
  final String? allowedOrigin;

  const WindowsInlineWebView({
    super.key,
    required this.url,
    required this.loadFailedMessage,
    this.allowedOrigin,
  });

  @override
  State<WindowsInlineWebView> createState() => _WindowsInlineWebViewState();
}

class _WindowsInlineWebViewState extends State<WindowsInlineWebView> {
  static const double _trackpadScrollBoostFactor = 2.0;

  late final WebviewController _controller;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _isLoading = true;
  String? _errorMessage;
  bool _navigatingExternal = false;
  bool _controllerReady = false;
  bool _hasCalledInitialize = false;

  @override
  void initState() {
    super.initState();
    _controller = WebviewController();
    _initWebView();
  }

  Future<void> _initWebView() async {
    if (kIsWeb || !Platform.isWindows) {
      setState(() {
        _isLoading = false;
        _errorMessage = widget.loadFailedMessage;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (_controllerReady || _controller.value.isInitialized) {
        _controllerReady = true;
        await _controller.loadUrl(widget.url);
        return;
      }

      final webviewVersion = await WebviewController.getWebViewVersion();
      if (webviewVersion == null) {
        setState(() {
          _isLoading = false;
          _errorMessage = '当前系统缺少 WebView2 Runtime';
        });
        return;
      }

      _hasCalledInitialize = true;
      await _controller.initialize();
      await _controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
      await _controller.setBackgroundColor(Colors.transparent);
      _controllerReady = true;
      if (mounted) {
        setState(() {});
      }

      for (final subscription in _subscriptions) {
        await subscription.cancel();
      }
      _subscriptions.clear();

      _subscriptions.add(
        _controller.loadingState.listen((state) {
          if (!mounted) return;
          setState(() {
            _isLoading = state == LoadingState.loading;
          });
        }),
      );

      _subscriptions.add(
        _controller.onLoadError.listen((error) {
          debugPrint('[WindowsInlineWebView] load failed: $error');
          if (!mounted) return;
          setState(() {
            _isLoading = false;
            _errorMessage = widget.loadFailedMessage;
          });
        }),
      );

      if (widget.allowedOrigin != null) {
        _subscriptions.add(
          _controller.url.listen((url) {
            unawaited(_handleUrlChanged(url));
          }),
        );
      }

      await _controller.loadUrl(widget.url);
    } on PlatformException catch (e, s) {
      debugPrint('[WindowsInlineWebView] init error: $e\n$s');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _controllerReady = false;
        _errorMessage = widget.loadFailedMessage;
      });
    } catch (e, s) {
      debugPrint('[WindowsInlineWebView] unknown error: $e\n$s');
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _controllerReady = false;
        _errorMessage = widget.loadFailedMessage;
      });
    }
  }

  Future<void> _handleUrlChanged(String url) async {
    final allowedOrigin = widget.allowedOrigin;
    if (allowedOrigin == null || _navigatingExternal) return;

    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme == 'about') {
      return;
    }

    if (uri.scheme != 'http' && uri.scheme != 'https') {
      _navigatingExternal = true;
      try {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        try {
          await _controller.goBack();
        } catch (_) {}
      } finally {
        _navigatingExternal = false;
      }
      return;
    }

    if (uri.origin == allowedOrigin) {
      return;
    }

    _navigatingExternal = true;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      try {
        await _controller.goBack();
      } catch (_) {}
    } finally {
      _navigatingExternal = false;
    }
  }

  void _retry() {
    unawaited(_initWebView());
  }

  void _onTrackpadPanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (!_controllerReady || _errorMessage != null) return;
    // webview_windows already handles trackpad pan; add a small extra delta to
    // make touchpad scrolling feel less "sticky" on Windows.
    final extraDx = event.panDelta.dx * (_trackpadScrollBoostFactor - 1.0);
    final extraDy = event.panDelta.dy * (_trackpadScrollBoostFactor - 1.0);
    if (extraDx.abs() < 0.1 && extraDy.abs() < 0.1) {
      return;
    }

    final js = 'window.scrollBy(${-extraDx}, ${-extraDy});';
    unawaited(_controller.executeScript(js).catchError((_) {}));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    if (_hasCalledInitialize) {
      unawaited(_controller.dispose().catchError((_) {}));
    }
    super.dispose();
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
                  onPressed: _retry,
                  child: const Text('重试'),
                ),
              ],
            ),
          )
        else if (_controllerReady)
          Listener(
            onPointerPanZoomUpdate: _onTrackpadPanZoomUpdate,
            child: Webview(_controller),
          ),
        if (_isLoading)
          const Center(
            child: CircularProgressIndicator(),
          ),
      ],
    );
  }
}
