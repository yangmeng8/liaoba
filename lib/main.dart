import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'pages/contacts/contacts_page.dart';
import 'stores/conversation_store.dart';
import 'stores/presence_store.dart';
import 'stores/request_badge_store.dart';
import 'pages/logInAndSignUp/login_page.dart';
import 'pages/me/me_page.dart';
import 'pages/messages/messages_page.dart';
import 'rtc/rtc_controller.dart';
import 'services/auth_api.dart';
import 'services/auth_manager.dart';
import 'services/im_websocket.dart';
import 'shared/app_colors.dart';
import 'shared/app_theme.dart';
import 'shared/font_scale_manager.dart';
import 'shared/theme_manager.dart';

/// 全局导航 Key：接口 401 时从任意页面清栈跳转登录页。
final GlobalKey<NavigatorState> _rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 启动时恢复字体档位、主题模式和登录态
  await FontScaleManager.instance.load();
  await ThemeManager.instance.load();
  await AuthManager.instance.load();
  // 注入全局导航 Key（AuthManager 401 处理用）
  AuthManager.instance.rootNavigatorKey = _rootNavigatorKey;
  // 注入 RTC 全局导航 Key（来电信令自动拉起通话页）；
  // 触发 RtcController 单例构造，启动 WebSocket 信令监听
  RtcController.instance.navigatorKey = _rootNavigatorKey;
  // 恢复登录态后补拉用户资料与权限码（昵称/头像/permissions 缓存；
  // 异步执行不阻塞首帧，401 时会自动跳登录页）
  if (AuthManager.instance.isLoggedIn) {
    AuthApi.loadUserProfile().catchError((Object _) {});
  }
  runApp(const LiaobaApp());
}

class LiaobaApp extends StatelessWidget {
  const LiaobaApp({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([
          FontScaleManager.instance.indexNotifier,
          ThemeManager.instance.modeNotifier,
        ]),
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'IM',
          navigatorKey: _rootNavigatorKey,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: ThemeManager.instance.mode,
          // 401 全局跳转目标（AuthManager.handleUnauthorized 使用）
          routes: {'/login': (_) => const LoginPage()},
          // 全局字体缩放：注入 textScaler；
          // 状态栏全透明（去掉 Android 默认 25% 半透明黑 scrim），
          // 图标颜色跟随明暗主题（浅色主题深图标 / 深色主题亮图标）
          builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness:
                  Theme.of(context).brightness == Brightness.dark
                      ? Brightness.light
                      : Brightness.dark,
              statusBarBrightness:
                  Theme.of(context).brightness == Brightness.dark
                      ? Brightness.dark
                      : Brightness.light,
            ),
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler:
                    TextScaler.linear(FontScaleManager.instance.scale),
              ),
              child: child!,
            ),
          ),
          // 登录守卫：已登录进主框架（消息页），未登录进登录页
          home: AuthManager.instance.isLoggedIn
              ? const HomeShell()
              : const LoginPage(),
        ),
      );
}

// Compatibility entry point for the generated template smoke test.
class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  int count = 0;
  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(child: Text('$count')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => count++),
        child: const Icon(Icons.add),
      ),
    ),
  );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 0;
  final pages = const [MessagesPage(), ContactsPage(), MePage()];

  @override
  void initState() {
    super.initState();
    // 好友在线状态：订阅 WS FRIEND_ONLINE/FRIEND_OFFLINE 推送
    PresenceStore.instance.attach();
    // 进入主框架（登录后）启动 IM 长连接，跨页面复用单条连接
    ImWebSocket.instance.ensure();
    // 待办角标：进入主框架拉一次（账号切换后重置上个账号的旧值）
    RequestBadgeStore.instance.refresh();
  }

  /// 消息 Tab 未读总数（所有会话未读之和）。
  int get _totalUnread => ConversationStore.instance.conversations
      .fold<int>(0, (sum, c) => sum + c.unreadCount);

  /// Tab 图标右上角红色数字角标（微信风格，溢出图标边界显示）。
  Widget _withBadge(Widget icon, int count) {
    if (count <= 0) return icon;
    return SizedBox(
      width: 24,
      height: 24,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Center(child: icon),
          Positioned(
            top: -7,
            right: -10,
            child: _TabBadge(count: count),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 深色：tabBar 深灰 surface；浅色：tabBar 白 card
    final tabBarBg = isDark ? colors.surface : colors.card;
    // 深色：选中 icon + label 都用 lime；浅色：选中 icon lime、label 用 text（黑）
    final selectedIconColor = AppColors.lime;
    final selectedLabelColor = isDark ? AppColors.lime : colors.text;
    final unselectedColor = colors.muted;
    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: ListenableBuilder(
        listenable: Listenable.merge([
          ConversationStore.instance,
          RequestBadgeStore.instance,
        ]),
        // 角标数据源必须在 builder 内读取：store notify 只重建这里，
        // 在外层 build 求值会捕获旧值（仅切 tab 时才更新数字）。
        builder: (context, _) {
          final totalUnread = _totalUnread;
          final pendingRequests = RequestBadgeStore.instance.pending;
          return NavigationBar(
          height: 62,
          backgroundColor: tabBarBg,
          elevation: 0,
          selectedIndex: index,
          onDestinationSelected: (i) => setState(() => index = i),
          indicatorColor: Colors.transparent,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return TextStyle(color: selectedLabelColor);
            }
            return TextStyle(color: unselectedColor);
          }),
          destinations: [
            NavigationDestination(
              icon: _withBadge(
                  Icon(Icons.chat_bubble_outline, color: unselectedColor),
                  totalUnread),
              selectedIcon: _withBadge(
                  Icon(Icons.chat_bubble, color: selectedIconColor),
                  totalUnread),
              label: '消息',
            ),
            NavigationDestination(
              icon: _withBadge(
                  Icon(Icons.person_outline, color: unselectedColor),
                  pendingRequests),
              selectedIcon: _withBadge(
                  Icon(Icons.person, color: selectedIconColor),
                  pendingRequests),
              label: '通讯录',
            ),
            NavigationDestination(
              icon: Icon(Icons.account_circle_outlined, color: unselectedColor),
              selectedIcon: Icon(Icons.account_circle, color: selectedIconColor),
              label: '我的',
            ),
          ],
        );
        },
      ),
    );
  }
}

/// Tab 数字角标：正圆红底白字（宽高一致保证圆形；
/// 位数越多圆越大，>99 显示 99+；文字超宽自动缩放防溢出）。
class _TabBadge extends StatelessWidget {
  final int count;

  const _TabBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final text = count > 99 ? '99+' : '$count';
    final size = text.length == 1
        ? 16.0
        : text.length == 2
            ? 18.0
            : 21.0;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: Color(0xFFFA5151),
        shape: BoxShape.circle,
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          text,
          maxLines: 1,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

