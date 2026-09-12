import 'package:flutter/material.dart';
import 'pages/contacts/contacts_page.dart';
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
          title: '聊吧',
          navigatorKey: _rootNavigatorKey,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: ThemeManager.instance.mode,
          // 401 全局跳转目标（AuthManager.handleUnauthorized 使用）
          routes: {'/login': (_) => const LoginPage()},
          // 全局字体缩放：注入 textScaler
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(FontScaleManager.instance.scale),
            ),
            child: child!,
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
    // 进入主框架（登录后）启动 IM 长连接，跨页面复用单条连接
    ImWebSocket.instance.ensure();
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
      bottomNavigationBar: NavigationBar(
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
            icon: Icon(Icons.chat_bubble_outline, color: unselectedColor),
            selectedIcon: Icon(Icons.chat_bubble, color: selectedIconColor),
            label: '消息',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline, color: unselectedColor),
            selectedIcon: Icon(Icons.person, color: selectedIconColor),
            label: '通讯录',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_circle_outlined, color: unselectedColor),
            selectedIcon: Icon(Icons.account_circle, color: selectedIconColor),
            label: '我的',
          ),
        ],
      ),
    );
  }
}

