import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import 'package:http/http.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import 'package:psygo/backend/exceptions.dart';
import 'package:psygo/core/api_client.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/utils/other_party_can_receive.dart';
import 'uia_request_manager.dart';

extension LocalizedExceptionExtension on Object {
  static String _formatFileSize(int size) {
    if (size < 1000) return '$size B';
    final i = (log(size) / log(1000)).floor();
    final num = (size / pow(1000, i));
    final round = num.round();
    final numString = round < 10
        ? num.toStringAsFixed(2)
        : round < 100
            ? num.toStringAsFixed(1)
            : round.toString();
    return '$numString ${'kMGTPEZY'[i - 1]}B';
  }

  String toLocalizedString(
    BuildContext context, [
    ExceptionContext? exceptionContext,
  ]) {
    if (this is FileTooBigMatrixException) {
      final exception = this as FileTooBigMatrixException;
      return L10n.of(context).fileIsTooBigForServer(
        _formatFileSize(exception.maxFileSize),
      );
    }
    if (this is OtherPartyCanNotReceiveMessages) {
      return L10n.of(context).otherPartyNotLoggedIn;
    }
    if (this is AutomateBackendException) {
      final exception = this as AutomateBackendException;
      if (exception.message.trim().isNotEmpty) {
        return exception.message;
      }
      if (exception.statusCode == null) {
        return L10n.of(context).noConnectionToTheServer;
      }
      return L10n.of(context).serverError;
    }
    if (this is ApiException) {
      final exception = this as ApiException;
      if (exception.message.trim().isNotEmpty) {
        return exception.message;
      }
      return exception.toString();
    }
    if (this is MatrixException) {
      switch ((this as MatrixException).error) {
        case MatrixError.M_FORBIDDEN:
          if (exceptionContext == ExceptionContext.changePassword) {
            return L10n.of(context).passwordIsWrong;
          }
          return L10n.of(context).noPermission;
        case MatrixError.M_LIMIT_EXCEEDED:
          return L10n.of(context).tooManyRequestsWarning;
        default:
          if (exceptionContext == ExceptionContext.joinRoom) {
            return L10n.of(context).unableToJoinChat;
          }
          return L10n.of(context).serverError;
      }
    }
    if (this is InvalidPassphraseException) {
      return L10n.of(context).wrongRecoveryKey;
    }
    if (this is BadServerLoginTypesException) {
      final serverVersions = (this as BadServerLoginTypesException)
          .serverLoginTypes
          .toString()
          .replaceAll('{', '"')
          .replaceAll('}', '"');
      final supportedVersions = (this as BadServerLoginTypesException)
          .supportedLoginTypes
          .toString()
          .replaceAll('{', '"')
          .replaceAll('}', '"');
      return L10n.of(context).badServerLoginTypesException(
        serverVersions,
        supportedVersions,
        supportedVersions,
      );
    }
    if (this is IOException ||
        this is SocketException ||
        this is SyncConnectionException ||
        this is ClientException) {
      return L10n.of(context).noConnectionToTheServer;
    }
    if (this is FormatException &&
        exceptionContext == ExceptionContext.checkHomeserver) {
      return L10n.of(context).doesNotSeemToBeAValidHomeserver;
    }
    if (this is FormatException &&
        exceptionContext == ExceptionContext.checkServerSupportInfo) {
      return L10n.of(context).noContactInformationProvided;
    }
    if (this is Exception || this is Error) {
      final message = toString().trim();
      if (message.isNotEmpty && !message.startsWith('Instance of ')) {
        return message;
      }
    }
    if (this is String) return toString();
    if (this is UiaException) return toString();

    if (exceptionContext == ExceptionContext.joinRoom) {
      return L10n.of(context).unableToJoinChat;
    }

    Logs().w('Something went wrong: ', this);
    return L10n.of(context).oopsSomethingWentWrong;
  }
}

enum ExceptionContext {
  changePassword,
  checkHomeserver,
  checkServerSupportInfo,
  joinRoom,
  // 业务场景
  hireEmployee,
  customHireEmployee,
  loadEmployeeList,
  loadTrainingList,
  loadRecruitTemplates,
  loadTrainingDetail,
  installPlugin,
  uninstallPlugin,
  // 登录认证
  phoneLogin,
  requestVerifyCode,
  verifyCode,
  oneClickLogin,
  matrixLogin,
  // 其他功能
  startChat,
  sendMessage,
  getLocation,
  recordVoice,
  onboarding,
  matrixConnection,
}
