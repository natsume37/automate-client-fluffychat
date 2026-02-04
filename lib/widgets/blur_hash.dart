import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:blurhash_dart/blurhash_dart.dart' as b;
import 'package:image/image.dart' as image;

class BlurHash extends StatefulWidget {
  /// 全局 BlurHash 缓存，避免重复计算
  static final Map<String, Uint8List> _globalCache = {};

  /// 正在计算中的 Future，避免重复计算
  static final Map<String, Future<Uint8List>> _pendingFutures = {};

  /// 清除缓存
  static void clearCache() {
    _globalCache.clear();
    _pendingFutures.clear();
  }

  final double width;
  final double height;
  final String blurhash;
  final BoxFit fit;

  const BlurHash({
    super.key,
    String? blurhash,
    required this.width,
    required this.height,
    this.fit = BoxFit.cover,
  }) : blurhash = blurhash ?? 'LEHV6nWB2yk8pyo0adR*.7kCMdnj';

  @override
  State<BlurHash> createState() => _BlurHashState();
}

class _BlurHashState extends State<BlurHash> {
  Uint8List? _data;
  bool _isLoading = false;

  /// 生成缓存 key
  String get _cacheKey {
    final ratio = widget.width / widget.height;
    var w = 32;
    var h = 32;
    if (ratio > 1.0) {
      h = (w / ratio).round();
    } else {
      w = (h * ratio).round();
    }
    return '${widget.blurhash}_${w}x$h';
  }

  static Future<Uint8List> _decodeBlurhash(BlurhashData data) async {
    final blurhash = b.BlurHash.decode(data.hsh);
    final img = blurhash.toImage(data.w, data.h);
    return Uint8List.fromList(image.encodePng(img));
  }

  @override
  void initState() {
    super.initState();
    _loadBlurhash();
  }

  @override
  void didUpdateWidget(BlurHash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.blurhash != widget.blurhash ||
        oldWidget.width != widget.width ||
        oldWidget.height != widget.height) {
      _loadBlurhash();
    }
  }

  void _loadBlurhash() {
    final cacheKey = _cacheKey;

    // 1. 检查全局缓存
    final cached = BlurHash._globalCache[cacheKey];
    if (cached != null) {
      _data = cached;
      return;
    }

    // 2. 检查是否已经在计算中
    final pending = BlurHash._pendingFutures[cacheKey];
    if (pending != null) {
      _isLoading = true;
      pending.then((data) {
        if (mounted) {
          setState(() {
            _data = data;
            _isLoading = false;
          });
        }
      });
      return;
    }

    // 3. 开始新的计算
    _isLoading = true;
    final ratio = widget.width / widget.height;
    var w = 32;
    var h = 32;
    if (ratio > 1.0) {
      h = (w / ratio).round();
    } else {
      w = (h * ratio).round();
    }

    final future = compute(
      _decodeBlurhash,
      BlurhashData(hsh: widget.blurhash, w: w, h: h),
    );

    BlurHash._pendingFutures[cacheKey] = future;

    future.then((data) {
      BlurHash._globalCache[cacheKey] = data;
      BlurHash._pendingFutures.remove(cacheKey);
      if (mounted) {
        setState(() {
          _data = data;
          _isLoading = false;
        });
      }
    }).catchError((e) {
      BlurHash._pendingFutures.remove(cacheKey);
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
      return Container(
        width: widget.width,
        height: widget.height,
        color: Theme.of(context).colorScheme.onInverseSurface,
      );
    }
    return Image.memory(
      data,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      // 禁用 gapless playback 以减少内存压力
      gaplessPlayback: true,
    );
  }
}

class BlurhashData {
  final String hsh;
  final int w;
  final int h;

  const BlurhashData({
    required this.hsh,
    required this.w,
    required this.h,
  });

  factory BlurhashData.fromJson(Map<String, dynamic> json) => BlurhashData(
        hsh: json['hsh'],
        w: json['w'],
        h: json['h'],
      );

  Map<String, dynamic> toJson() => {
        'hsh': hsh,
        'w': w,
        'h': h,
      };
}
