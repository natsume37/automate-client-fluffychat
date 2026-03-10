import 'dart:math';

import 'package:flutter/material.dart';

import '../core/config.dart';
import 'custom_network_image.dart';

/// DiceBear 头像风格
enum DiceBearStyle {
  avataaars,
  bottts,
  funEmoji,
  adventurer,
  adventurerNeutral,
  bigSmile,
  lorelei,
  notionists,
  openPeeps,
  personas,
  pixelArt,
  thumbs,
}

extension DiceBearStyleExtension on DiceBearStyle {
  String get apiName {
    switch (this) {
      case DiceBearStyle.avataaars:
        return 'avataaars';
      case DiceBearStyle.bottts:
        return 'bottts';
      case DiceBearStyle.funEmoji:
        return 'fun-emoji';
      case DiceBearStyle.adventurer:
        return 'adventurer';
      case DiceBearStyle.adventurerNeutral:
        return 'adventurer-neutral';
      case DiceBearStyle.bigSmile:
        return 'big-smile';
      case DiceBearStyle.lorelei:
        return 'lorelei';
      case DiceBearStyle.notionists:
        return 'notionists';
      case DiceBearStyle.openPeeps:
        return 'open-peeps';
      case DiceBearStyle.personas:
        return 'personas';
      case DiceBearStyle.pixelArt:
        return 'pixel-art';
      case DiceBearStyle.thumbs:
        return 'thumbs';
    }
  }

  String get displayName {
    switch (this) {
      case DiceBearStyle.avataaars:
        return 'Avataaars';
      case DiceBearStyle.bottts:
        return 'Bottts';
      case DiceBearStyle.funEmoji:
        return 'Fun Emoji';
      case DiceBearStyle.adventurer:
        return 'Adventurer';
      case DiceBearStyle.adventurerNeutral:
        return 'Adventurer Neutral';
      case DiceBearStyle.bigSmile:
        return 'Big Smile';
      case DiceBearStyle.lorelei:
        return 'Lorelei';
      case DiceBearStyle.notionists:
        return 'Notionists';
      case DiceBearStyle.openPeeps:
        return 'Open Peeps';
      case DiceBearStyle.personas:
        return 'Personas';
      case DiceBearStyle.pixelArt:
        return 'Pixel Art';
      case DiceBearStyle.thumbs:
        return 'Thumbs';
    }
  }
}

/// DiceBear 头像选择器
class DiceBearAvatarPicker extends StatefulWidget {
  /// 初始头像 URL
  final String? initialAvatarUrl;

  /// 头像变化回调
  final ValueChanged<String> onAvatarChanged;

  /// 头像大小
  final double size;

  const DiceBearAvatarPicker({
    super.key,
    this.initialAvatarUrl,
    required this.onAvatarChanged,
    this.size = 80,
  });

  @override
  State<DiceBearAvatarPicker> createState() => _DiceBearAvatarPickerState();
}

class _DiceBearAvatarPickerState extends State<DiceBearAvatarPicker> {
  final _random = Random();

  late DiceBearStyle _currentStyle;
  late String _currentSeed;
  late String _currentAvatarUrl;

  @override
  void initState() {
    super.initState();
    if (widget.initialAvatarUrl != null &&
        _isDiceBearAvatarUrl(widget.initialAvatarUrl!)) {
      _parseAvatarUrl(widget.initialAvatarUrl!);
    } else {
      _currentStyle = DiceBearStyle.values[_random.nextInt(DiceBearStyle.values.length)];
      _currentSeed = _generateSeed();
      _currentAvatarUrl = _buildAvatarUrl();
    }
  }

  void _parseAvatarUrl(String url) {
    // 尝试从 URL 解析 style 和 seed
    final uri = Uri.tryParse(url);
    if (uri != null) {
      final pathSegments = uri.pathSegments;
      if (pathSegments.length >= 2) {
        final styleStr = pathSegments[1];
        _currentStyle = DiceBearStyle.values.firstWhere(
          (s) => s.apiName == styleStr,
          orElse: () => DiceBearStyle.avataaars,
        );
      }
      _currentSeed = uri.queryParameters['seed'] ?? _generateSeed();
    } else {
      _currentStyle = DiceBearStyle.avataaars;
      _currentSeed = _generateSeed();
    }
    _currentAvatarUrl = _buildAvatarUrl();
  }

  String _generateSeed() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(8, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  String _buildAvatarUrl() {
    return '${PsygoConfig.dicebearBaseUrl}/${_currentStyle.apiName}/png?seed=$_currentSeed&size=256';
  }

  bool _isDiceBearAvatarUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final segments = uri.pathSegments;
    return segments.length >= 3 && segments[0] == '9.x';
  }

  void _randomizeAvatar() {
    setState(() {
      _currentStyle = DiceBearStyle.values[_random.nextInt(DiceBearStyle.values.length)];
      _currentSeed = _generateSeed();
      _currentAvatarUrl = _buildAvatarUrl();
    });
    widget.onAvatarChanged(_currentAvatarUrl);
  }

  void _changeStyle(DiceBearStyle style) {
    setState(() {
      _currentStyle = style;
      _currentAvatarUrl = _buildAvatarUrl();
    });
    widget.onAvatarChanged(_currentAvatarUrl);
  }

  void _refreshSeed() {
    setState(() {
      _currentSeed = _generateSeed();
      _currentAvatarUrl = _buildAvatarUrl();
    });
    widget.onAvatarChanged(_currentAvatarUrl);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 头像显示区域
        GestureDetector(
          onTap: _randomizeAvatar,
          child: Stack(
            children: [
              Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(widget.size * 0.2),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                    width: 2,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(widget.size * 0.2 - 2),
                  child: CustomNetworkImage(
                    _currentAvatarUrl,
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Center(
                        child: SizedBox(
                          width: widget.size * 0.3,
                          height: widget.size * 0.3,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            value: loadingProgress.expectedTotalBytes != null
                                ? loadingProgress.cumulativeBytesLoaded /
                                    loadingProgress.expectedTotalBytes!
                                : null,
                          ),
                        ),
                      );
                    },
                    errorBuilder: (_, __, ___) => Icon(
                      Icons.person_outline,
                      size: widget.size * 0.4,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
              // 刷新按钮
              Positioned(
                right: -4,
                bottom: -4,
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: theme.colorScheme.shadow.withValues(alpha: 0.2),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _refreshSeed,
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          Icons.refresh_rounded,
                          size: 16,
                          color: theme.colorScheme.onPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 风格选择
        SizedBox(
          height: 32,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: DiceBearStyle.values.asMap().entries.map((entry) {
                final index = entry.key;
                final style = entry.value;
                final isSelected = style == _currentStyle;
                return Padding(
                  padding: EdgeInsets.only(left: index > 0 ? 6 : 0),
                  child: FilterChip(
                    label: Text(
                      style.displayName,
                      style: TextStyle(
                        fontSize: 11,
                        color: isSelected
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    selected: isSelected,
                    onSelected: (_) => _changeStyle(style),
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    selectedColor: theme.colorScheme.primary,
                    showCheckmark: false,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    labelPadding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }
}
