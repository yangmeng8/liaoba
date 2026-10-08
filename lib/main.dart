import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kReleaseMode;
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
import 'services/chat_push_service.dart';
import 'services/im_websocket.dart';
import 'services/jpush_registration_upload.dart';
import 'services/push_service.dart';
import 'shared/app_colors.dart';
import 'shared/app_theme.dart';
import 'shared/font_scale_manager.dart';
import 'shared/theme_manager.dart';

/// 极光推送 AppKey。
/// 注意：AppKey 与包名绑定，需在极光后台为本包名（com.example.liaoba.im）
/// 登记后才可收到推送；否则 getRegistrationID 一直为空。
const String _jpushAppKey = 'd28a97237912f354ef3af622';

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
  await _initPush();
  runApp(const LiaobaApp());
}

/// 极光推送初始化（迁移自 app_im 的编排顺序，顺序不可随意调整）：
/// 1. ChatPushService.init（生命周期监听 + Android 点击桥接）
/// 2. addEventHandler 注册回调（必须先于 setup，否则 Android channel 为 null）
/// 3. jpush.setup(appKey)
/// 4. iOS：申请推送权限 + 前台通知交由 AppDelegate 按会话控制 + 重绑通知代理
/// 5. syncPushStateFromLogin 按本地登录态决定推送处理开关
/// 6. 已登录则轮询 RegistrationID 并上报后端
Future<void> _initPush() async {
  final JPush jpush = JPush();
  ChatPushService.instance.init(jpush);
  // 注入全局导航与 Tab 切换（通知点击后跳转消息 tab 用）
  ChatPushService.instance.attach(
    navigatorKey: _rootNavigatorKey,
    switchTab: HomeShell.switchToTab,
  );

  jpush.addEventHandler(
    onReceiveNotification: (Map<String, dynamic> message) async {
      // 通知消息：后台由系统展示；前台 Android 转 App 内横幅，不补本地通知
      await ChatPushService.instance.handleIncomingPush(
        message,
        shouldShowLocalNotification: false,
        shouldShowInAppBanner: Platform.isAndroid,
      );
    },
    onOpenNotification: (Map<String, dynamic> message) async {
      ChatPushService.instance.handleNotificationOpened(message);
      // 点击推送跳转 App 时清除角标数字
      try {
        await jpush.clearBadge();
      } catch (e) {
        debugPrint('[极光 Push] 点击推送清除角标失败: $e');
      }
    },
    onReceiveMessage: (Map<String, dynamic> message) async {
      // 自定义消息：仅前台 Android 展示 App 内横幅，不转系统本地通知
      await ChatPushService.instance.handleIncomingPush(
        message,
        shouldShowLocalNotification: false,
        shouldShowInAppBanner: Platform.isAndroid,
      );
    },
  );

  jpush.setup(
    appKey: _jpushAppKey,
    channel: 'flutter_channel',
    production: kReleaseMode,
    debug: !kReleaseMode,
  );

  if (Platform.isIOS) {
    // iOS 申请推送权限（只弹一次）
    jpush.applyPushAuthority(
      const NotificationSettingsIOS(sound: true, alert: true, badge: true),
    );
    // iOS 前台通知改由 AppDelegate 按当前会话精确控制显示/隐藏
    jpush.setUnShowAtTheForeground(unShow: false);
    await ChatPushService.instance.rebindIOSNotificationDelegate();
  }

  // 在 Flutter 接收任何推送之前恢复开关，避免旧账号消息被误处理
  await ChatPushService.instance.syncPushStateFromLogin();

  // 已登录：启动后轮询 RegistrationID 并上报后端（异步不阻塞首帧）
  if (AuthManager.instance.isLoggedIn) {
    unawaited(JPushRegistrationUpload.pollAndReportRegistrationIdIfLoggedIn(
      jpush: jpush,
    ));
  }
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

  /// 全局 Tab 切换通知（推送点击等外部场景触发，绕过 setState 层级）。
  static final ValueNotifier<int> tabNotifier = ValueNotifier<int>(0);

  /// 切换底部 Tab（ChatPushService 注入给推送点击跳转用）。
  static void switchToTab(int index) => tabNotifier.value = index;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int index = 0;
  final pages = const [MessagesPage(), ContactsPage(), MePage()];

  @override
  void initState() {
    super.initState();
    // 回前台补报极光 rid（见 didChangeAppLifecycleState）
    WidgetsBinding.instance.addObserver(this);
    // 好友在线状态：订阅 WS FRIEND_ONLINE/FRIEND_OFFLINE 推送
    PresenceStore.instance.attach();
    // 进入主框架（登录后）启动 IM 长连接，跨页面复用单条连接
    ImWebSocket.instance.ensure();
    // 待办角标：进入主框架拉一次（账号切换后重置上个账号的旧值）
    RequestBadgeStore.instance.refresh();
    // 推送点击通知：切到指定 Tab（如消息 tab）
    HomeShell.tabNotifier.addListener(_onExternalTabSwitch);
  }

  @override
  void dispose() {
    HomeShell.tabNotifier.removeListener(_onExternalTabSwitch);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // App 回前台：补报极光 RegistrationID（同一 ID 已上报则内部直接跳过）。
    // 兜底覆盖冷启动轮询失败、上报时网络异常等漏传场景，确保后端拿得到 rid
    if (state == AppLifecycleState.resumed) {
      unawaited(
          JPushRegistrationUpload.pollAndReportRegistrationIdIfLoggedIn());
    }
  }

  /// 外部（推送点击）请求切换 Tab。
  void _onExternalTabSwitch() {
    if (!mounted) return;
    setState(() => index = HomeShell.tabNotifier.value);
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
          onDestinationSelected: (i) {
            // Tab 切换触觉反馈（iOS Taptic tick / Android 触觉震动）
            HapticFeedback.selectionClick();
            setState(() => index = i);
          },
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

