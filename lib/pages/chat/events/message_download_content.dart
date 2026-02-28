import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:matrix/matrix.dart';
import 'package:open_file/open_file.dart';
import 'package:path/path.dart' as path_lib;
import 'package:path_provider/path_provider.dart';

import 'package:psygo/config/app_config.dart';
import 'package:psygo/config/setting_keys.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/utils/file_description.dart';
import 'package:psygo/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:psygo/utils/platform_infos.dart';
import 'package:psygo/utils/url_launcher.dart';
import 'package:psygo/widgets/future_loading_dialog.dart';

class MessageDownloadContent extends StatelessWidget {
  final Event event;
  final Color textColor;
  final Color linkColor;

  const MessageDownloadContent(
    this.event, {
    required this.textColor,
    required this.linkColor,
    super.key,
  });

  Future<MatrixFile?> _downloadAttachment(BuildContext context) async {
    final result = await showFutureLoadingDialog(
      context: context,
      futureWithProgress: (onProgress) {
        final fileSize = event.infoMap['size'] is int
            ? event.infoMap['size'] as int
            : null;
        return event.downloadAndDecryptAttachment(
          onDownloadProgress: fileSize == null
              ? null
              : (bytes) => onProgress(bytes / fileSize),
        );
      },
    );
    return result.result;
  }

  Future<void> _openFilePreview(BuildContext context) async {
    if (PlatformInfos.isWeb) return;
    final scaffoldMessenger = ScaffoldMessenger.of(context);

    try {
      final matrixFile = await _downloadAttachment(context);
      if (matrixFile == null) return;

      final fileName =
          matrixFile.name.isNotEmpty ? matrixFile.name : 'attachment';
      final tempDir = await getTemporaryDirectory();
      final tempPath = path_lib.join(
        tempDir.path,
        '${DateTime.now().millisecondsSinceEpoch}_$fileName',
      );
      await File(tempPath).writeAsBytes(matrixFile.bytes, flush: true);

      final result = await OpenFile.open(tempPath);
      if (result.type != ResultType.done) {
        final message =
            result.message.isNotEmpty ? result.message : L10n.of(context).open;
        scaffoldMessenger.showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (_) {
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text(L10n.of(context).open)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final filename = event.content.tryGet<String>('filename') ?? event.body;
    final filetype = (filename.contains('.')
        ? filename.split('.').last.toUpperCase()
        : event.content
                .tryGetMap<String, dynamic>('info')
                ?.tryGet<String>('mimetype')
                ?.toUpperCase() ??
            'UNKNOWN');
    final sizeString = event.sizeString ?? '?MB';
    final fileDescription = event.fileDescription;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppConfig.borderRadius / 2),
            onTap: () => event.saveFile(context),
            child: Container(
              width: 400,
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 16,
                children: [
                  CircleAvatar(
                    backgroundColor: textColor.withAlpha(32),
                    child: Icon(Icons.file_download_outlined, color: textColor),
                  ),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        Text(
                          '$sizeString | $filetype',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: textColor, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                  if (!PlatformInfos.isWeb)
                    IconButton(
                      icon: const Icon(Icons.visibility_outlined),
                      color: textColor,
                      tooltip: L10n.of(context).open,
                      onPressed: () => _openFilePreview(context),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (fileDescription != null) ...[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 8.0,
            ),
            child: Linkify(
              text: fileDescription,
              textScaleFactor: MediaQuery.textScalerOf(context).scale(1),
              style: TextStyle(
                color: textColor,
                fontSize: AppSettings.fontSizeFactor.value *
                    AppConfig.messageFontSize,
              ),
              options: const LinkifyOptions(humanize: false),
              linkStyle: TextStyle(
                color: linkColor,
                fontSize: AppSettings.fontSizeFactor.value *
                    AppConfig.messageFontSize,
                decoration: TextDecoration.underline,
                decorationColor: linkColor,
              ),
              onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
            ),
          ),
        ],
      ],
    );
  }
}
