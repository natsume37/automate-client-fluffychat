import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 自定义网络图片组件
///
/// 使用 Image.network 加载图片，通过 HttpOverrides 处理证书问题
class CustomNetworkImage extends StatelessWidget {
  /// 清除所有图片缓存（退出登录时调用）
  static void clearCache() {
    final cache = PaintingBinding.instance.imageCache;
    cache.clear();
    cache.clearLiveImages();
  }

  final String url;
  final BoxFit? fit;
  final double? width;
  final double? height;
  final Widget Function(BuildContext, Widget, ImageChunkEvent?)? loadingBuilder;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  const CustomNetworkImage(
    this.url, {
    super.key,
    this.fit,
    this.width,
    this.height,
    this.loadingBuilder,
    this.errorBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    final memCacheWidth = width == null ? null : (width! * devicePixelRatio).round();
    final memCacheHeight = height == null ? null : (height! * devicePixelRatio).round();

    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      width: width,
      height: height,
      memCacheWidth: memCacheWidth,
      memCacheHeight: memCacheHeight,
      placeholder: loadingBuilder == null
          ? null
          : (context, _) => loadingBuilder!(
                context,
                const SizedBox.shrink(),
                const ImageChunkEvent(
                  cumulativeBytesLoaded: 0,
                  expectedTotalBytes: 1,
                ),
              ),
      imageBuilder: (context, imageProvider) {
        final image = Image(
          image: imageProvider,
          fit: fit,
          width: width,
          height: height,
        );
        if (loadingBuilder == null) {
          return image;
        }
        return loadingBuilder!(context, image, null);
      },
      errorWidget: errorBuilder == null
          ? null
          : (context, _, error) =>
              errorBuilder!(context, error, StackTrace.current),
    );
  }
}
