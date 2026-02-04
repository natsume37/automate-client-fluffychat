import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:psygo/config/themes.dart';
import 'package:psygo/utils/client_download_content_extension.dart';
import 'package:psygo/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:psygo/widgets/matrix.dart';
import 'custom_network_image.dart';

class MxcImage extends StatefulWidget {
  /// 清除所有图片缓存（退出登录时调用）
  static void clearCache() {
    _MxcImageState.clearCache();
  }

  final Uri? uri;
  final Event? event;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final bool isThumbnail;
  final bool animated;
  final Duration retryDuration;
  final Duration animationDuration;
  final Curve animationCurve;
  final ThumbnailMethod thumbnailMethod;
  final Widget Function(BuildContext context)? placeholder;
  final String? cacheKey;
  final Client? client;
  final BorderRadius borderRadius;

  const MxcImage({
    this.uri,
    this.event,
    this.width,
    this.height,
    this.fit,
    this.placeholder,
    this.isThumbnail = true,
    this.animated = false,
    this.animationDuration = FluffyThemes.animationDuration,
    this.retryDuration = const Duration(milliseconds: 500),
    this.animationCurve = FluffyThemes.animationCurve,
    this.thumbnailMethod = ThumbnailMethod.scale,
    this.cacheKey,
    this.client,
    this.borderRadius = BorderRadius.zero,
    super.key,
  });

  @override
  State<MxcImage> createState() => _MxcImageState();
}

class _MxcImageState extends State<MxcImage> {
  static final Map<String, Uint8List> _imageDataCache = {};
  Uint8List? _imageDataNoCache;

  /// 清除所有图片缓存（退出登录时调用）
  static void clearCache() {
    _imageDataCache.clear();
  }

  Uint8List? get _imageData => widget.cacheKey == null
      ? _imageDataNoCache
      : _imageDataCache[widget.cacheKey];

  set _imageData(Uint8List? data) {
    if (data == null) return;
    final cacheKey = widget.cacheKey;
    cacheKey == null
        ? _imageDataNoCache = data
        : _imageDataCache[cacheKey] = data;
  }

  /// 检查是否是普通 HTTP/HTTPS URL（非 mxc://）
  bool get _isHttpUrl {
    final uri = widget.uri;
    if (uri == null) return false;
    final scheme = uri.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  Future<void> _load() async {
    if (!mounted) return;
    final client =
        widget.client ?? widget.event?.room.client ?? Matrix.of(context).client;
    final uri = widget.uri;
    final event = widget.event;

    // 检查 client 和 URI 是否有效
    if (uri != null && uri.host.isNotEmpty && client.homeserver != null) {
      final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
      final width = widget.width;
      final realWidth = width == null ? null : width * devicePixelRatio;
      final height = widget.height;
      final realHeight = height == null ? null : height * devicePixelRatio;

      final remoteData = await client.downloadMxcCached(
        uri,
        width: realWidth,
        height: realHeight,
        thumbnailMethod: widget.thumbnailMethod,
        isThumbnail: widget.isThumbnail,
        animated: widget.animated,
      );
      if (!mounted) return;
      // 只有下载到有效数据时才更新状态
      if (remoteData.isNotEmpty) {
        setState(() {
          _imageData = remoteData;
        });
      }
    }

    if (event != null) {
      final data = await event.downloadAndDecryptAttachment(
        getThumbnail: widget.isThumbnail,
      );
      if (data.detectFileType is MatrixImageFile || widget.isThumbnail) {
        if (!mounted) return;
        setState(() {
          _imageData = data.bytes;
        });
        return;
      }
    }
  }

  void _tryLoad() async {
    if (_imageData != null) {
      return;
    }
    try {
      await _load();
    } on IOException catch (_) {
      if (!mounted) return;
      await Future.delayed(widget.retryDuration);
      _tryLoad();
    }
  }

  @override
  void initState() {
    super.initState();
    // 如果缓存中已有数据，不需要等待 postFrameCallback
    if (_imageData != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryLoad());
  }

  @override
  void didUpdateWidget(MxcImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当关键属性变化时，重新加载图片
    if (oldWidget.uri != widget.uri ||
        oldWidget.event != widget.event ||
        oldWidget.cacheKey != widget.cacheKey) {
      // 清除当前图片数据，触发重新加载
      if (mounted) {
        setState(() {
          if (widget.cacheKey == null) {
            _imageDataNoCache = null;
          }
          // 注意：不清除 _imageDataCache，因为它是静态缓存
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _tryLoad());
      }
    }
  }

  Widget placeholder(BuildContext context) {
    if (widget.placeholder != null) {
      return widget.placeholder!(context);
    }

    final theme = Theme.of(context);
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.surfaceContainerHighest.withAlpha(60),
            theme.colorScheme.surfaceContainer.withAlpha(40),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOut,
        builder: (context, value, child) => Opacity(
          opacity: 0.4 + (value * 0.3),
          child: child,
        ),
        child: Icon(
          Icons.image_outlined,
          size: min((widget.height ?? 64) / 2, 32),
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 普通 HTTP/HTTPS URL 使用 CustomNetworkImage（包含 ISRG X1 证书）
    if (_isHttpUrl) {
      return ClipRRect(
        borderRadius: widget.borderRadius,
        child: CustomNetworkImage(
          widget.uri.toString(),
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return placeholder(context);
          },
          errorBuilder: (context, e, s) {
            Logs().d('Unable to load network image', e, s);
            return placeholder(context);
          },
        ),
      );
    }

    // mxc:// URL 使用原来的逻辑
    final data = _imageData;
    final hasData = data != null && data.isNotEmpty;

    // 使用稳定的 cacheKey 作为 key，避免 data 变化导致不必要的重建
    final stableKey = widget.cacheKey ?? widget.uri?.toString() ?? 'no_key';

    return RepaintBoundary(
      child: AnimatedSwitcher(
        duration: FluffyThemes.animationDuration,
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: child,
        ),
        child: hasData
            ? ClipRRect(
                key: ValueKey('loaded_$stableKey'),
                borderRadius: widget.borderRadius,
                child: Image.memory(
                  data,
                  width: widget.width,
                  height: widget.height,
                  fit: widget.fit,
                  filterQuality: widget.isThumbnail
                      ? FilterQuality.low
                      : FilterQuality.medium,
                  // 启用 gaplessPlayback 避免闪烁
                  gaplessPlayback: true,
                  errorBuilder: (context, e, s) {
                    Logs().d('Unable to render mxc image', e, s);
                    return SizedBox(
                      width: widget.width,
                      height: widget.height,
                      child: Material(
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        child: Icon(
                          Icons.broken_image_outlined,
                          size: min(widget.height ?? 64, 64),
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    );
                  },
                ),
              )
            : KeyedSubtree(
                key: ValueKey('loading_$stableKey'),
                child: placeholder(context),
              ),
      ),
    );
  }
}
