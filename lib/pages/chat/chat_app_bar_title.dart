import 'dart:async';

import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:psygo/config/themes.dart';
import 'package:psygo/l10n/l10n.dart';
import 'package:psygo/models/agent.dart';
import 'package:psygo/pages/chat/chat.dart';
import 'package:psygo/repositories/agent_repository.dart';
import 'package:psygo/services/agent_service.dart';
import 'package:psygo/utils/date_time_extension.dart';
import 'package:psygo/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:psygo/utils/sync_status_localization.dart';
import 'package:psygo/widgets/avatar.dart';
import 'package:psygo/widgets/presence_builder.dart';

class ChatAppBarTitle extends StatefulWidget {
  final ChatController controller;
  const ChatAppBarTitle(this.controller, {super.key});

  @override
  State<ChatAppBarTitle> createState() => _ChatAppBarTitleState();
}

class _ChatAppBarTitleState extends State<ChatAppBarTitle> {
  /// 员工信息（如果对方是员工）
  Agent? _employee;

  /// 轮询定时器
  Timer? _pollingTimer;

  /// 轮询间隔
  static const _pollingInterval = Duration(seconds: 10);

  /// Agent 仓库
  final AgentRepository _repository = AgentRepository();

  ChatController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _initEmployeeStatus();
  }

  @override
  void dispose() {
    _stopPolling();
    _repository.dispose();
    super.dispose();
  }

  /// 初始化员工状态
  void _initEmployeeStatus() {
    final room = controller.room;
    final directChatMatrixID = room.directChatMatrixID;

    if (directChatMatrixID == null) return;

    // 从缓存中快速查找（用于立即显示）
    final cachedEmployee = AgentService.instance.getAgentByMatrixUserId(directChatMatrixID);
    if (cachedEmployee != null) {
      setState(() => _employee = cachedEmployee);
      _startPolling(cachedEmployee.agentId);
    } else {
      // 缓存没有，直接调用 API 获取
      _fetchAndCheckEmployee(directChatMatrixID);
    }
  }

  /// 获取并检查是否是员工
  Future<void> _fetchAndCheckEmployee(String matrixUserId) async {
    try {
      final page = await _repository.getUserAgents(limit: 50);
      final agent = page.agents.where((a) => a.matrixUserId == matrixUserId).firstOrNull;
      if (mounted && agent != null) {
        setState(() => _employee = agent);
        _startPolling(agent.agentId);
      }
      // 如果没找到，_employee 保持 null，显示在线状态
    } catch (_) {
      // 出错时显示在线状态
    }
  }

  /// 开始轮询
  void _startPolling(String agentId) {
    _stopPolling();
    // 立即获取一次最新状态
    _fetchEmployeeStatus(agentId);
    // 启动定时轮询
    _pollingTimer = Timer.periodic(_pollingInterval, (_) {
      _fetchEmployeeStatus(agentId);
    });
  }

  /// 停止轮询
  void _stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
  }

  /// 获取员工最新状态
  Future<void> _fetchEmployeeStatus(String agentId) async {
    if (!mounted) return;

    try {
      final page = await _repository.getUserAgents(limit: 50);
      final agent = page.agents.where((a) => a.agentId == agentId).firstOrNull;
      if (mounted && agent != null) {
        setState(() => _employee = agent);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final room = controller.room;
    if (controller.selectedEvents.isNotEmpty) {
      return Text(
        controller.selectedEvents.length.toString(),
        style: TextStyle(
          color: Theme.of(context).colorScheme.onTertiaryContainer,
        ),
      );
    }

    final theme = Theme.of(context);
    return InkWell(
      hoverColor: Colors.transparent,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      onTap: controller.isArchived
          ? null
          : () => FluffyThemes.isThreeColumnMode(context)
              ? controller.toggleDisplayChatDetailsColumn()
              : context.go('/rooms/${room.id}/details'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Hero(
              tag: 'content_banner',
              child: _buildAvatar(room, context),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    room.getLocalizedDisplayname(MatrixLocals(L10n.of(context))),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // 私聊：显示员工工作状态或在线状态
                  // 群聊：不显示状态
                  room.directChatMatrixID != null
                      ? (_employee != null
                          ? _buildEmployeeWorkStatus(context, _employee!)
                          : _buildPresenceStatus(context, room))
                      : const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建头像 - 私聊时显示对方头像，群聊显示房间头像
  Widget _buildAvatar(Room room, BuildContext context) {
    final directChatMatrixID = room.directChatMatrixID;

    // 如果是私聊，获取对方用户的头像
    if (directChatMatrixID != null) {
      // 优先使用已加载的员工数据（来自轮询 API，数据更新）
      if (_employee != null && _employee!.avatarUrl != null && _employee!.avatarUrl!.isNotEmpty) {
        try {
          final avatarUri = Uri.parse(_employee!.avatarUrl!);
          return Avatar(
            mxContent: avatarUri,
            name: _employee!.displayName,
            size: 32,
          );
        } catch (_) {
          // URI 解析失败，继续 fallback
        }
      }
      // 其次从 AgentService 缓存获取员工头像
      final agentAvatarUri = AgentService.instance.getAgentAvatarUri(directChatMatrixID);
      if (agentAvatarUri != null) {
        final agent = AgentService.instance.getAgentByMatrixUserId(directChatMatrixID);
        return Avatar(
          mxContent: agentAvatarUri,
          name: agent!.displayName,
          size: 32,
        );
      }
      // 非员工或员工没有头像，使用 Matrix 用户头像
      final user = room.unsafeGetUserFromMemoryOrFallback(directChatMatrixID);
      return Avatar(
        mxContent: user.avatarUrl,
        name: user.calcDisplayname(),
        size: 36,
        borderRadius: BorderRadius.circular(12),
      );
    }

    // 群聊使用房间头像
    return Avatar(
      mxContent: room.avatar,
      name: room.getLocalizedDisplayname(
        MatrixLocals(L10n.of(context)),
      ),
      size: 36,
      borderRadius: BorderRadius.circular(12),
    );
  }

  /// 构建员工工作状态显示
  Widget _buildEmployeeWorkStatus(BuildContext context, Agent employee) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);

    final isWorking = employee.isWorking;
    final statusText = isWorking
        ? '💼 ${l10n.employeeWorking}'
        : '😴 ${l10n.employeeSleeping}';
    final dotColor = isWorking ? Colors.green : Colors.blue;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: dotColor.withAlpha(100),
                blurRadius: 4,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Text(
          statusText,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w400,
          ),
        ),
      ],
    );
  }

  /// 构建原有的在线状态显示
  Widget _buildPresenceStatus(BuildContext context, Room room) {
    return StreamBuilder(
      stream: room.client.onSyncStatus.stream,
      builder: (context, snapshot) {
        final status = room.client.onSyncStatus.value ??
            const SyncStatusUpdate(SyncStatus.waitingForResponse);
        final hide = FluffyThemes.isColumnMode(context) ||
            (room.client.onSync.value != null &&
                status.status != SyncStatus.error &&
                room.client.prevBatch != null);
        return AnimatedSize(
          duration: FluffyThemes.animationDuration,
          child: hide
              ? PresenceBuilder(
                  userId: room.directChatMatrixID,
                  builder: (context, presence) {
                    final lastActiveTimestamp = presence?.lastActiveTimestamp;
                    final style = TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline,
                    );
                    if (presence?.currentlyActive == true) {
                      return Text(
                        L10n.of(context).currentlyActive,
                        style: style,
                      );
                    }
                    if (lastActiveTimestamp != null) {
                      return Text(
                        L10n.of(context).lastActiveAgo(
                          lastActiveTimestamp.localizedTimeShort(context),
                        ),
                        style: style,
                      );
                    }
                    return const SizedBox.shrink();
                  },
                )
              : Row(
                  children: [
                    SizedBox.square(
                      dimension: 10,
                      child: CircularProgressIndicator.adaptive(
                        strokeWidth: 1,
                        value: status.progress,
                        valueColor: status.error != null
                            ? AlwaysStoppedAnimation<Color>(
                                Theme.of(context).colorScheme.error,
                              )
                            : null,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        status.calcLocalizedString(context),
                        style: TextStyle(
                          fontSize: 12,
                          color: status.error != null
                              ? Theme.of(context).colorScheme.error
                              : null,
                        ),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}
