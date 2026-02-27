import 'dart:io';

import 'package:flutter/material.dart';
import 'package:cross_file/cross_file.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as path_lib;
import 'package:path_provider/path_provider.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/utils/localized_exception_extension.dart';
import 'package:psygo/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:psygo/utils/other_party_can_receive.dart';
import 'package:psygo/utils/platform_infos.dart';
import 'package:psygo/utils/size_string.dart';
import '../../utils/resize_video.dart';

class SendFileDialog extends StatefulWidget {
  final Room room;
  final List<XFile> files;
  final BuildContext outerContext;
  final String? threadLastEventId, threadRootEventId;

  const SendFileDialog({
    required this.room,
    required this.files,
    required this.outerContext,
    required this.threadLastEventId,
    required this.threadRootEventId,
    super.key,
  });

  @override
  SendFileDialogState createState() => SendFileDialogState();
}

class SendFileDialogState extends State<SendFileDialog> {
  bool compress = true;

  /// Images smaller than 20kb don't need compression.
  static const int minSizeToCompress = 20 * 1000;

  final TextEditingController _labelTextController = TextEditingController();

  String _fileDisplayName(BuildContext context, XFile file) {
    if (file.name.isNotEmpty) {
      return file.name;
    }
    if (file.path.isNotEmpty) {
      return path_lib.basename(file.path);
    }
    return L10n.of(context).sendFileUnnamed;
  }

  Future<void> _openFilePreview(BuildContext context, XFile file) async {
    final scaffoldMessenger = ScaffoldMessenger.of(widget.outerContext);
    final l10n = L10n.of(context);
    if (PlatformInfos.isWeb) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text(l10n.sendFileWebPreviewNotSupported)),
      );
      return;
    }

    var path = file.path;
    if (path.isEmpty) {
      final bytes = await file.readAsBytes();
      final tempDir = await getTemporaryDirectory();
      final fileName = _fileDisplayName(context, file).trim().isEmpty
          ? 'attachment'
          : _fileDisplayName(context, file).trim();
      final tempPath = path_lib.join(
        tempDir.path,
        '${DateTime.now().millisecondsSinceEpoch}_$fileName',
      );
      await File(tempPath).writeAsBytes(bytes, flush: true);
      path = tempPath;
    }

    try {
      final result = await OpenFile.open(path);
      if (result.type != ResultType.done) {
        debugPrint(
          '[SendFileDialog] Open file failed: ${result.type}, ${result.message}',
        );
        scaffoldMessenger.showSnackBar(
          SnackBar(content: Text(l10n.sendFileCannotOpen)),
        );
      }
    } catch (_) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text(l10n.sendFileCannotOpen)),
      );
    }
  }

  Widget _buildFilePreviewItem(BuildContext context, XFile file) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    final fileName = _fileDisplayName(context, file);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openFilePreview(context, file),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.insert_drive_file_outlined,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    FutureBuilder<int>(
                      future: file.length(),
                      builder: (context, snapshot) {
                        final subtitle = snapshot.hasData
                            ? '${snapshot.data!.sizeString} · ${l10n.sendFileTapToOpen}'
                            : l10n.sendFileTapToPreview;
                        return Text(
                          subtitle,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.open_in_new,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _send() async {
    final scaffoldMessenger = ScaffoldMessenger.of(widget.outerContext);
    final l10n = L10n.of(context);

    try {
      if (!widget.room.otherPartyCanReceiveMessages) {
        throw OtherPartyCanNotReceiveMessages();
      }
      scaffoldMessenger.showLoadingSnackBar(l10n.prepareSendingAttachment);
      Navigator.of(context, rootNavigator: false).pop();
      final clientConfig = await widget.room.client.getConfig();
      final maxUploadSize = clientConfig.mUploadSize ?? 100 * 1000 * 1000;

      for (final xfile in widget.files) {
        final MatrixFile file;
        MatrixImageFile? thumbnail;
        final length = await xfile.length();
        final mimeType = xfile.mimeType ?? lookupMimeType(xfile.path);

        // Generate video thumbnail
        if (PlatformInfos.isMobile &&
            mimeType != null &&
            mimeType.startsWith('video')) {
          scaffoldMessenger.showLoadingSnackBar(l10n.generatingVideoThumbnail);
          thumbnail = await xfile.getVideoThumbnail();
        }

        // If file is a video, shrink it!
        if (PlatformInfos.isMobile &&
            mimeType != null &&
            mimeType.startsWith('video')) {
          scaffoldMessenger.showLoadingSnackBar(l10n.compressVideo);
          file = await xfile.getVideoInfo(
            compress: length > minSizeToCompress && compress,
          );
        } else {
          if (length > maxUploadSize) {
            throw FileTooBigMatrixException(length, maxUploadSize);
          }
          // Else we just create a MatrixFile
          file = MatrixFile(
            bytes: await xfile.readAsBytes(),
            name: xfile.name,
            mimeType: mimeType,
          ).detectFileType;
        }

        if (file.bytes.length > maxUploadSize) {
          throw FileTooBigMatrixException(length, maxUploadSize);
        }

        if (widget.files.length > 1) {
          scaffoldMessenger.showLoadingSnackBar(
            l10n.sendingAttachmentCountOfCount(
              widget.files.indexOf(xfile) + 1,
              widget.files.length,
            ),
          );
        }

        final label = _labelTextController.text.trim();

        try {
          await widget.room.sendFileEvent(
            file,
            thumbnail: thumbnail,
            shrinkImageMaxDimension: compress ? 1600 : null,
            extraContent: label.isEmpty ? null : {'body': label},
            threadRootEventId: widget.threadRootEventId,
            threadLastEventId: widget.threadLastEventId,
          );
        } on MatrixException catch (e) {
          final retryAfterMs = e.retryAfterMs;
          if (e.error != MatrixError.M_LIMIT_EXCEEDED || retryAfterMs == null) {
            rethrow;
          }
          final retryAfterDuration =
              Duration(milliseconds: retryAfterMs + 1000);

          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(
                l10n.serverLimitReached(retryAfterDuration.inSeconds),
              ),
            ),
          );
          await Future.delayed(retryAfterDuration);

          scaffoldMessenger.showLoadingSnackBar(l10n.sendingAttachment);

          await widget.room.sendFileEvent(
            file,
            thumbnail: thumbnail,
            shrinkImageMaxDimension: compress ? 1600 : null,
            extraContent: label.isEmpty ? null : {'body': label},
          );
        }
      }
      scaffoldMessenger.clearSnackBars();
    } catch (e) {
      scaffoldMessenger.clearSnackBars();
      final theme = Theme.of(context);
      scaffoldMessenger.showSnackBar(
        SnackBar(
          backgroundColor: theme.colorScheme.errorContainer,
          closeIconColor: theme.colorScheme.onErrorContainer,
          content: Text(
            e.toLocalizedString(widget.outerContext),
            style: TextStyle(color: theme.colorScheme.onErrorContainer),
          ),
          duration: const Duration(seconds: 30),
          showCloseIcon: true,
        ),
      );
      rethrow;
    }

    return;
  }

  Future<String> _calcCombinedFileSize() async {
    final lengths =
        await Future.wait(widget.files.map((file) => file.length()));
    return lengths.fold<double>(0, (p, length) => p + length).sizeString;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    var sendStr = L10n.of(context).sendFile;
    final uniqueFileType = widget.files
        .map((file) => file.mimeType ?? lookupMimeType(file.name))
        .map((mimeType) => mimeType?.split('/').first)
        .toSet()
        .singleOrNull;

    final isImage = uniqueFileType == 'image';
    final l10n = L10n.of(context);
    final labelTitle =
        isImage ? l10n.sendFileImageName : l10n.sendFileDocumentName;
    final labelHint =
        isImage ? l10n.sendFileImageNameHint : l10n.sendFileDocumentNameHint;

    if (isImage) {
      if (widget.files.length == 1) {
        sendStr = L10n.of(context).sendImage;
      } else {
        sendStr = L10n.of(context).sendImages(widget.files.length);
      }
    } else if (uniqueFileType == 'audio') {
      sendStr = L10n.of(context).sendAudio;
    } else if (uniqueFileType == 'video') {
      sendStr = L10n.of(context).sendVideo;
    }

    final compressionSupported =
        uniqueFileType != 'video' || PlatformInfos.isMobile;

    return FutureBuilder<String>(
      future: _calcCombinedFileSize(),
      builder: (context, snapshot) {
        return Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Container(
            constraints: const BoxConstraints(maxWidth: 600),
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 顶部区域（标题 + 关闭按钮）
                Row(
                  children: [
                    // 蓝色圆形图标
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2196F3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.auto_awesome,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    // 标题
                    Expanded(
                      child: Text(
                        sendStr,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    // 关闭按钮
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () =>
                          Navigator.of(context, rootNavigator: false).pop(),
                      style: IconButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(28, 28),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Divider(color: theme.dividerColor, height: 1),
                const SizedBox(height: 12),
                // 内容区域
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 图片预览
                        if (isImage)
                          Center(
                            child: Stack(
                              children: [
                                Container(
                                  height: 300,
                                  constraints:
                                      const BoxConstraints(maxWidth: 400),
                                  decoration: BoxDecoration(
                                    color: Colors.grey[200],
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  clipBehavior: Clip.hardEdge,
                                  child: widget.files.length == 1
                                      ? FutureBuilder(
                                          future: widget.files[0].readAsBytes(),
                                          builder: (context, snapshot) {
                                            final bytes = snapshot.data;
                                            if (bytes == null) {
                                              return const Center(
                                                child: CircularProgressIndicator
                                                    .adaptive(),
                                              );
                                            }
                                            return Image.memory(
                                              bytes,
                                              fit: BoxFit.contain,
                                            );
                                          },
                                        )
                                      : ListView.builder(
                                          scrollDirection: Axis.horizontal,
                                          itemCount: widget.files.length,
                                          itemBuilder: (context, i) => Padding(
                                            padding: const EdgeInsets.only(
                                                right: 8.0),
                                            child: FutureBuilder(
                                              future:
                                                  widget.files[i].readAsBytes(),
                                              builder: (context, snapshot) {
                                                final bytes = snapshot.data;
                                                if (bytes == null) {
                                                  return const SizedBox(
                                                    width: 200,
                                                    child: Center(
                                                      child:
                                                          CircularProgressIndicator
                                                              .adaptive(),
                                                    ),
                                                  );
                                                }
                                                return Image.memory(
                                                  bytes,
                                                  fit: BoxFit.contain,
                                                );
                                              },
                                            ),
                                          ),
                                        ),
                                ),
                                // 右下角放大按钮
                                Positioned(
                                  right: 12,
                                  bottom: 12,
                                  child: Material(
                                    color: Colors.black.withValues(alpha: 0.6),
                                    borderRadius: BorderRadius.circular(20),
                                    child: InkWell(
                                      onTap: () =>
                                          _showFullScreenImage(context),
                                      borderRadius: BorderRadius.circular(20),
                                      child: Container(
                                        padding: const EdgeInsets.all(8),
                                        child: const Icon(
                                          Icons.zoom_in,
                                          color: Colors.white,
                                          size: 24,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (!isImage)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.sendFilePreviewTitle,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 8),
                              for (var i = 0; i < widget.files.length; i++) ...[
                                _buildFilePreviewItem(context, widget.files[i]),
                                if (i != widget.files.length - 1)
                                  const SizedBox(height: 8),
                              ],
                            ],
                          ),
                        const SizedBox(height: 12),
                        // 图片名称输入框
                        Text(
                          labelTitle,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _labelTextController,
                          decoration: InputDecoration(
                            hintText: labelHint,
                            filled: true,
                            fillColor:
                                theme.colorScheme.surfaceContainerHighest,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                          ),
                          maxLines: 1,
                          maxLength: 255,
                          buildCounter: (
                            context, {
                            required currentLength,
                            required isFocused,
                            maxLength,
                          }) =>
                              null,
                        ),
                        const SizedBox(height: 12),
                        // 压缩选项
                        if ({'image', 'video'}.contains(uniqueFileType))
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE8F5E9),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF4CAF50),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(
                                    Icons.image_outlined,
                                    color: Colors.white,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        l10n.sendFileCompressMedia,
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                          fontWeight: FontWeight.w600,
                                          color: const Color(0xFF2E7D32),
                                        ),
                                      ),
                                      const SizedBox(height: 1),
                                      Text(
                                        l10n.sendFileCompressMediaHint,
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          color: const Color(0xFF2E7D32),
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value: compressionSupported && compress,
                                  onChanged: compressionSupported
                                      ? (v) => setState(() => compress = v)
                                      : null,
                                  activeTrackColor: const Color(0xFF4CAF50),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // 底部按钮
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () =>
                            Navigator.of(context, rootNavigator: false).pop(),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          L10n.of(context).cancel,
                          style: TextStyle(
                            color: theme.colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: _send,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          backgroundColor: const Color(0xFF2196F3),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          L10n.of(context).send,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // 显示全屏图片预览
  void _showFullScreenImage(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          children: [
            // 全屏图片
            Center(
              child: InteractiveViewer(
                minScale: 0.5,
                maxScale: 4.0,
                child: widget.files.length == 1
                    ? FutureBuilder(
                        future: widget.files[0].readAsBytes(),
                        builder: (context, snapshot) {
                          final bytes = snapshot.data;
                          if (bytes == null) {
                            return const CircularProgressIndicator.adaptive();
                          }
                          return Image.memory(
                            bytes,
                            fit: BoxFit.contain,
                          );
                        },
                      )
                    : PageView.builder(
                        itemCount: widget.files.length,
                        itemBuilder: (context, i) => FutureBuilder(
                          future: widget.files[i].readAsBytes(),
                          builder: (context, snapshot) {
                            final bytes = snapshot.data;
                            if (bytes == null) {
                              return const Center(
                                child: CircularProgressIndicator.adaptive(),
                              );
                            }
                            return InteractiveViewer(
                              minScale: 0.5,
                              maxScale: 4.0,
                              child: Image.memory(
                                bytes,
                                fit: BoxFit.contain,
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ),
            // 关闭按钮
            Positioned(
              top: 40,
              right: 16,
              child: IconButton(
                icon: const Icon(
                  Icons.close,
                  color: Colors.white,
                  size: 32,
                ),
                onPressed: () => Navigator.of(context).pop(),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

extension on ScaffoldMessengerState {
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showLoadingSnackBar(
    String title,
  ) {
    clearSnackBars();
    return showSnackBar(
      SnackBar(
        duration: const Duration(minutes: 5),
        dismissDirection: DismissDirection.none,
        content: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator.adaptive(
                strokeWidth: 2,
              ),
            ),
            const SizedBox(width: 16),
            Text(title),
          ],
        ),
      ),
    );
  }
}
