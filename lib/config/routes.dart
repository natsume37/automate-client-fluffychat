import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:psygo/config/themes.dart';
import 'package:psygo/pages/chat/chat.dart';
import 'package:psygo/pages/chat_access_settings/chat_access_settings_controller.dart';
import 'package:psygo/pages/chat_details/chat_details.dart';
import 'package:psygo/pages/chat_members/chat_members.dart';
import 'package:psygo/pages/chat_permissions_settings/chat_permissions_settings.dart';
import 'package:psygo/pages/chat_search/chat_search_page.dart';
import 'package:psygo/pages/device_settings/device_settings.dart';
import 'package:psygo/pages/homeserver_picker/homeserver_picker.dart';
import 'package:psygo/pages/invitation_selection/invitation_selection.dart';
import 'package:psygo/pages/login_signup/phone_login_page.dart';
import 'package:psygo/pages/main_screen/main_screen.dart';
import 'package:psygo/pages/login/login.dart';
import 'package:psygo/pages/new_group/new_group.dart';
import 'package:psygo/pages/new_private_chat/new_private_chat.dart';
import 'package:psygo/pages/settings/settings.dart';
import 'package:psygo/pages/settings_chat/settings_chat.dart';
import 'package:psygo/pages/settings_notifications/settings_notifications.dart';
import 'package:psygo/pages/settings_style/settings_style.dart';
import 'package:psygo/widgets/config_viewer.dart';
import 'package:psygo/widgets/layouts/empty_page.dart';
import 'package:psygo/widgets/layouts/two_column_layout.dart';
import 'package:psygo/widgets/layouts/desktop_layout.dart';
import 'package:psygo/widgets/log_view.dart';
import 'package:psygo/widgets/matrix.dart';
import 'package:psygo/widgets/share_scaffold_dialog.dart';

abstract class AppRoutes {
  static FutureOr<String?> loggedInRedirect(
    BuildContext context,
    GoRouterState state,
  ) {
    return Matrix.of(context).widget.clients.any((client) => client.isLogged())
        ? '/rooms'
        : null;
  }

  static FutureOr<String?> loggedOutRedirect(
    BuildContext context,
    GoRouterState state,
  ) {
    final isLoggedIn = Matrix.of(context).widget.clients.any((client) => client.isLogged());
    if (isLoggedIn) return null;

    // Mobile: Let AuthGate handle login, don't redirect
    // Web: Redirect to /login-signup for manual login
    return kIsWeb ? '/login-signup' : null;
  }

  AppRoutes();

  static final List<RouteBase> routes = [
    GoRoute(
      path: '/',
      // Don't redirect to login-signup here - _AutomateAuthGate handles login flow
      // This prevents race condition where GoRouter redirects before AuthGate can navigate
      redirect: (context, state) =>
          Matrix.of(context).widget.clients.any((client) => client.isLogged())
              ? '/rooms'
              : null,  // Let AuthGate handle unauthenticated state
      // Empty page builder - AuthGate will show loading/login UI, not this page
      pageBuilder: (context, state) => defaultPageBuilder(
        context,
        state,
        const EmptyPage(),
      ),
    ),
    // 直接使用手机号登录页面作为登录入口
    GoRoute(
      path: '/login-signup',
      pageBuilder: (context, state) => defaultPageBuilder(
        context,
        state,
        const PhoneLoginPage(),
      ),
      redirect: loggedInRedirect,
    ),
    GoRoute(
      path: '/home',
      // 重定向到新版登录页面，不让用户看到旧版页面
      redirect: (context, state) {
        // 如果已登录，跳转到主页
        if (Matrix.of(context).widget.clients.any((client) => client.isLogged())) {
          return '/rooms';
        }
        // 未登录: Web 跳转到 /login-signup, Mobile 跳转到根路径让 AuthGate 处理
        return kIsWeb ? '/login-signup' : '/';
      },
      pageBuilder: (context, state) => defaultPageBuilder(
        context,
        state,
        const HomeserverPicker(addMultiAccount: false),
      ),
      routes: [
        GoRoute(
          path: 'login',
          // 同样重定向到新版登录
          redirect: (context, state) {
            if (Matrix.of(context).widget.clients.any((client) => client.isLogged())) {
              return '/rooms';
            }
            // Web 跳转到 /login-signup, Mobile 跳转到根路径让 AuthGate 处理
            return kIsWeb ? '/login-signup' : '/';
          },
          pageBuilder: (context, state) => defaultPageBuilder(
            context,
            state,
            Login(client: state.extra as Client),
          ),
        ),
      ],
    ),
    GoRoute(
      path: '/logs',
      pageBuilder: (context, state) => defaultPageBuilder(
        context,
        state,
        const LogViewer(),
      ),
    ),
    GoRoute(
      path: '/configs',
      pageBuilder: (context, state) => defaultPageBuilder(
        context,
        state,
        const ConfigViewer(),
      ),
    ),
    ShellRoute(
      // Never use a transition on the shell route. Changing the PageBuilder
      // here based on a MediaQuery causes the child to briefly be rendered
      // twice with the same GlobalKey, blowing up the rendering.
      pageBuilder: (context, state, child) {
        final path = state.fullPath ?? '';
        final locationPath = state.uri.path;
        // 这些路径不使用 DesktopLayout，使用原始 child
        final excludedPaths = [
          '/rooms/settings',
          '/rooms/newgroup',
          '/rooms/newprivatechat',
        ];
        // 聊天详情和搜索页面的子路由也需要排除
        final excludedSuffixes = ['/details', '/search', '/invite', '/encryption'];
        final shouldUseDesktopLayout = FluffyThemes.isColumnMode(context) &&
            !excludedPaths.any((p) => path.startsWith(p)) &&
            !excludedSuffixes.any((s) => path.endsWith(s));

        return noTransitionPageBuilder(
          context,
          state,
          shouldUseDesktopLayout
              ? DesktopLayout(
                  activeChat: state.pathParameters['roomid'],
                  initialPage: locationPath.startsWith('/rooms/team')
                      ? DesktopPageIndex.employees
                      : DesktopPageIndex.messages,
                )
              : child,
        );
      },
      routes: [
        GoRoute(
          path: '/rooms',
          redirect: loggedOutRedirect,
          pageBuilder: (context, state) => defaultPageBuilder(
            context,
            state,
            FluffyThemes.isColumnMode(context)
                ? const EmptyPage()
                : MainScreen(
                    activeChat: state.pathParameters['roomid'],
                    initialPage: 0,
                  ),
          ),
          routes: [
            GoRoute(
              path: 'team',
              pageBuilder: (context, state) => defaultPageBuilder(
                context,
                state,
                FluffyThemes.isColumnMode(context)
                    ? const EmptyPage()
                    : const MainScreen(initialPage: 1),
              ),
              redirect: loggedOutRedirect,
            ),
            GoRoute(
              path: 'newprivatechat',
              pageBuilder: (context, state) => defaultPageBuilder(
                context,
                state,
                const NewPrivateChat(),
              ),
              redirect: loggedOutRedirect,
            ),
            GoRoute(
              path: 'newgroup',
              pageBuilder: (context, state) => defaultPageBuilder(
                context,
                state,
                const NewGroup(),
              ),
              redirect: loggedOutRedirect,
            ),
            ShellRoute(
              pageBuilder: (context, state, child) => defaultPageBuilder(
                context,
                state,
                FluffyThemes.isColumnMode(context)
                    ? TwoColumnLayout(
                        mainView: Settings(key: state.pageKey),
                        sideView: child,
                      )
                    : child,
              ),
              routes: [
                GoRoute(
                  path: 'settings',
                  pageBuilder: (context, state) => defaultPageBuilder(
                    context,
                    state,
                    FluffyThemes.isColumnMode(context)
                        ? const EmptyPage()
                        : const Settings(),
                  ),
                  routes: [
                    GoRoute(
                      path: 'notifications',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const SettingsNotifications(),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'style',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const SettingsStyle(),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'devices',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const DevicesSettings(),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'chat',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const SettingsChat(),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                  ],
                  redirect: loggedOutRedirect,
                ),
              ],
            ),
            GoRoute(
              path: ':roomid',
              pageBuilder: (context, state) {
                final body = state.uri.queryParameters['body'];
                var shareItems = state.extra is List<ShareItem>
                    ? state.extra as List<ShareItem>
                    : null;
                if (body != null && body.isNotEmpty) {
                  shareItems ??= [];
                  shareItems.add(TextShareItem(body));
                }
                return defaultPageBuilder(
                  context,
                  state,
                  ChatPage(
                    roomId: state.pathParameters['roomid']!,
                    shareItems: shareItems,
                    eventId: state.uri.queryParameters['event'],
                  ),
                );
              },
              redirect: loggedOutRedirect,
              routes: [
                GoRoute(
                  path: 'search',
                  pageBuilder: (context, state) => defaultPageBuilder(
                    context,
                    state,
                    ChatSearchPage(
                      roomId: state.pathParameters['roomid']!,
                    ),
                  ),
                  redirect: loggedOutRedirect,
                ),
                GoRoute(
                  path: 'invite',
                  pageBuilder: (context, state) => defaultPageBuilder(
                    context,
                    state,
                    InvitationSelection(
                      roomId: state.pathParameters['roomid']!,
                    ),
                  ),
                  redirect: loggedOutRedirect,
                ),
                GoRoute(
                  path: 'details',
                  pageBuilder: (context, state) => defaultPageBuilder(
                    context,
                    state,
                    ChatDetails(
                      roomId: state.pathParameters['roomid']!,
                    ),
                  ),
                  routes: [
                    GoRoute(
                      path: 'access',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        ChatAccessSettings(
                          roomId: state.pathParameters['roomid']!,
                        ),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'members',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        ChatMembersPage(
                          roomId: state.pathParameters['roomid']!,
                        ),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'permissions',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const ChatPermissionsSettings(),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'invite',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        InvitationSelection(
                          roomId: state.pathParameters['roomid']!,
                        ),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                  ],
                  redirect: loggedOutRedirect,
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  ];

  static Page noTransitionPageBuilder(
    BuildContext context,
    GoRouterState state,
    Widget child,
  ) =>
      NoTransitionPage(
        key: state.pageKey,
        restorationId: state.pageKey.value,
        child: child,
      );

  static Page defaultPageBuilder(
    BuildContext context,
    GoRouterState state,
    Widget child,
  ) =>
      FluffyThemes.isColumnMode(context)
          ? noTransitionPageBuilder(context, state, child)
          : MaterialPage(
              key: state.pageKey,
              restorationId: state.pageKey.value,
              child: child,
            );
}
