import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/im_conversation.dart';
import 'pages/chat/chat_page.dart';
import 'pages/contacts/contacts_page.dart';
import 'pages/contacts/user_profile_page.dart';
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
import 'services/desktop_notify_service.dart';
import 'services/im_websocket.dart';
import 'services/jpush_registration_upload.dart';
import 'services/push_service.dart';
import 'services/version_service.dart';
import 'shared/app_colors.dart';
import 'shared/app_theme.dart';
import 'shared/desktop_layout.dart';
import 'shared/diag_log.dart';
import 'shared/font_scale_manager.dart';
import 'shared/im_avatar.dart';
import 'shared/theme_manager.dart';

/// 极光推送 AppKey。 555
/// 注意：AppKey 与包名绑定，需在极光后台为本包名（com.example.liaoba.im）
/// 登记后才可收到推送；否则 getRegistrationID 一直为空。
const String _jpushAppKey = 'd28a97237912f354ef3af622';

/// 全局导航 Key：接口 401 时从任意页面清栈跳转登录页。
final GlobalKey<NavigatorState> _rootNavigatorKey =
    GlobalKey<NavigatorState>(debugLabel: 'root');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 日志通路标记：每次冷启动落一条，装包后拉 im_diag.log 即可确认
  // Dart → 原生（appendDiagLog）这条路是通的，也方便区分不同次会话。
  DiagLog.log('[APP] 冷启动 (release=$kReleaseMode, '
      '${Platform.operatingSystemVersion})');
  // 启动时恢复字体档位、主题模式和登录态
  await FontScaleManager.instance.load();
  await ThemeManager.instance.load();
  await AuthManager.instance.load();
  // 注入全局导航 Key（AuthManager 401 处理用）
  AuthManager.instance.rootNavigatorKey = _rootNavigatorKey;
  // 注入 RTC 全局导航 Key（来电信令自动拉起通话页）；
  // 触发 RtcController 单例构造，启动 WebSocket 信令监听
  RtcController.instance.navigatorKey = _rootNavigatorKey;
  // 注入版本更新全局导航 Key（进主框架自动检查时弹更新框）
  VersionService.instance.navigatorKey = _rootNavigatorKey;
  // 恢复登录态后补拉用户资料与权限码（昵称/头像/permissions 缓存；
  // 异步执行不阻塞首帧，401 时会自动跳登录页）
  if (AuthManager.instance.isLoggedIn) {
    AuthApi.loadUserProfile().catchError((Object _) {});
  }
  await _initPush();
  // 桌面端：任务栏未读角标 + 系统 Toast + 新消息提示音（移动端自动忽略）
  DesktopNotifyService.instance.init();
  runApp(const LiaobaApp());
  // 冷启动点「接听」：原生 CallKit 事件在 Dart/导航器就绪前就到达，
  // 首帧后再取一次缓存事件，否则来电页 push 不出来（跳进 App 却停在首页）
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(RtcController.instance.syncPendingCallkitEvents());
    // 好友「离线」（App 被杀 / 锁屏进程被回收）时来电只落到原生持久化存档里，
    // 首帧后补读一次：点接听拉起 App 时靠它还原通话页
    unawaited(RtcController.instance.syncPendingCall());
  });
}

/// 极光推送初始化（迁移自 app_im 的编排顺序，顺序不可随意调整）：
/// 1. ChatPushService.init（生命周期监听 + Android 点击桥接）
/// 2. addEventHandler 注册回调（必须先于 setup，否则 Android channel 为 null）
/// 3. jpush.setup(appKey)
/// 4. iOS：申请推送权限 + 前台通知交由 AppDelegate 按会话控制 + 重绑通知代理
/// 5. syncPushStateFromLogin 按本地登录态决定推送处理开关
/// 6. 已登录则轮询 RegistrationID 并上报后端
/// 极光 setup 的 APNs 环境必须与包内实际的 aps-environment 一致。
/// 常见坑：Release 配置 + 开发签名（Development profile）→ 令牌仍是沙箱令牌，
/// 此时若按 kReleaseMode 传 production=true，极光会推生产网关，APNs 以
/// BadDeviceToken 拒收，表现为「Debug 正常，打成 IPA 后收不到任何推送/来电」。
Future<bool> _resolveApsProduction() async {
  try {
    final env = await const MethodChannel('im/push_env')
        .invokeMethod<String>('getApsEnvironment');
    if (env == 'production') {
      debugPrint('[极光 Push] 包内 aps-environment=production → 按生产环境上报');
      return true;
    }
    if (env == 'development') {
      debugPrint('[极光 Push] 包内 aps-environment=development → 按沙箱环境上报');
      return false;
    }
  } catch (e) {
    debugPrint('[极光 Push] 读取 aps-environment 失败，回退构建模式: $e');
  }
  return kReleaseMode;
}

Future<void> _initPush() async {
  // 桌面端（macOS/Windows）：极光无桌面 SDK，跳过推送体系；
  // 桌面 App 常驻在线，消息/来电全走 WebSocket 实时通道
  if (!Platform.isAndroid && !Platform.isIOS) {
    debugPrint('[极光 Push] 桌面平台，跳过推送初始化');
    return;
  }
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
    production: await _resolveApsProduction(),
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

  // ==================== 桌面三栏（微信 PC 风格）右栏状态 ====================
  // 右栏互斥展示：聊天会话 / 好友资料 / 我的面板；全空显示占位空态。

  /// 右栏当前展示的聊天会话。
  ImConversation? _desktopConv;

  /// 右栏当前展示的好友资料页目标 userId。
  int? _desktopProfileUserId;

  /// 右栏是否展示「我的」面板。
  bool _desktopShowMe = false;

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
    // 版本更新：进主框架延迟 2s 自动检查（等页面就绪；
    // 无更新静默，有更新弹框，强制更新不可关闭）
    Future<void>.delayed(const Duration(seconds: 2)).then((_) {
      if (!mounted) return;
      unawaited(VersionService.instance.checkAndShow());
    });
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
    // 桌面三栏只有 消息/通讯录 两个导航项（「我的」并入右栏面板）
    final target = HomeShell.tabNotifier.value.clamp(0, isDesktop ? 1 : 2);
    setState(() => index = target);
  }

  /// 当前是否运行在桌面三栏布局（供无 context 场景判断窗口宽度）。
  bool get isDesktop =>
      _desktopWidth != null && _desktopWidth! >= kDesktopBreakpoint;

  /// 最近一次 build 量到的窗口宽度（null = 还没 build 过）。
  double? _desktopWidth;

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
    // 记录窗口宽度供无 context 场景（外部 tab 切换 clamp）判断布局
    _desktopWidth = MediaQuery.of(context).size.width;
    // 桌面三栏（微信 PC 风格）：左导航 Rail + 中列表 + 右内容区
    if (isDesktopLayout(context)) {
      return _buildDesktopLayout(context, colors);
    }
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

  // ==================== 桌面三栏布局（微信 PC 风格） ====================

  /// 桌面三栏骨架：左 64px 导航 Rail + 中 300px 列表面板 + 右内容区。
  Widget _buildDesktopLayout(BuildContext context, ThemeColors colors) {
    return Scaffold(
      backgroundColor: colors.bg,
      body: Row(
        // stretch：三栏各自撑满窗口高度（Rail 内含 Spacer，
        // 默认 center 收缩高度会导致无界约束异常）
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 左栏：导航 Rail（角标数据源必须在 builder 内读取保证实时刷新）
          ListenableBuilder(
            listenable: Listenable.merge([
              ConversationStore.instance,
              RequestBadgeStore.instance,
            ]),
            builder: (context, _) => _DesktopRail(
              selectedIndex: index.clamp(0, 1),
              totalUnread: _totalUnread,
              pendingRequests: RequestBadgeStore.instance.pending,
              onSelect: (i) {
                HapticFeedback.selectionClick();
                setState(() => index = i);
              },
              onAvatarTap: _openDesktopMe,
              onSettingsTap: _openDesktopMe,
            ),
          ),
          // 中栏：消息 / 通讯录 列表（IndexedStack 保滚动位置）
          SizedBox(
            width: 300,
            child: IndexedStack(
              index: index.clamp(0, 1),
              children: [
                MessagesPage(onOpenConversation: _openDesktopConversation),
                ContactsPage(onOpenFriend: _openDesktopFriend),
              ],
            ),
          ),
          // 中右分隔线
          VerticalDivider(width: 1, thickness: 1, color: colors.divider),
          // 右栏：聊天 / 资料 / 我的 / 空态
          Expanded(child: _buildDesktopRightPanel(context, colors)),
        ],
      ),
    );
  }

  /// 桌面右栏打开会话聊天（来自中栏消息列表点击）。
  void _openDesktopConversation(ImConversation conv) {
    setState(() {
      _desktopConv = conv;
      _desktopProfileUserId = null;
      _desktopShowMe = false;
      index = 0;
    });
  }

  /// 桌面右栏打开好友资料（来自中栏通讯录点击）。
  void _openDesktopFriend(int userId) {
    setState(() {
      _desktopProfileUserId = userId;
      _desktopConv = null;
      _desktopShowMe = false;
      index = 1;
    });
  }

  /// 桌面右栏打开「我的」面板（Rail 头像 / 底部设置点击）。
  void _openDesktopMe() {
    setState(() {
      _desktopShowMe = true;
      _desktopConv = null;
      _desktopProfileUserId = null;
    });
  }

  /// 桌面右栏内容：聊天 / 好友资料 / 我的 / 空态（互斥）。
  Widget _buildDesktopRightPanel(BuildContext context, ThemeColors colors) {
    final conv = _desktopConv;
    if (conv != null) {
      return ChatPage(
        key: ValueKey('desktop_chat_${conv.type.value}_${conv.targetId}'),
        type: conv.type,
        targetId: conv.targetId,
        title: conv.title,
        avatar: conv.avatar,
        embedded: true,
      );
    }
    final profileUserId = _desktopProfileUserId;
    if (profileUserId != null) {
      return UserProfilePage(
        key: ValueKey('desktop_profile_$profileUserId'),
        userId: profileUserId,
        embedded: true,
        onSendMessage: (userId, name, avatar) {
          setState(() {
            _desktopProfileUserId = null;
            _desktopConv = ImConversation(
              type: ImConversationType.private,
              targetId: userId,
              title: name,
              avatar: avatar,
              lastMessageText: '',
              lastMessageTime: null,
              unreadCount: 0,
              pinned: false,
              silent: false,
            );
          });
        },
      );
    }
    if (_desktopShowMe) {
      // MePage 自带渐变头部，直接嵌入右栏
      return const MePage();
    }
    return _DesktopEmptyPlaceholder(colors: colors);
  }
}

/// 桌面左栏导航 Rail（微信 PC 风格）：
/// 深色竖条（不随明暗主题大变），顶部头像 + 消息/通讯录图标，底部设置。
class _DesktopRail extends StatelessWidget {
  /// 当前选中项：0=消息 1=通讯录。
  final int selectedIndex;

  /// 消息未读总数（图标角标）。
  final int totalUnread;

  /// 好友申请待办数（图标角标）。
  final int pendingRequests;

  final ValueChanged<int> onSelect;
  final VoidCallback onAvatarTap;
  final VoidCallback onSettingsTap;

  const _DesktopRail({
    required this.selectedIndex,
    required this.totalUnread,
    required this.pendingRequests,
    required this.onSelect,
    required this.onAvatarTap,
    required this.onSettingsTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 微信 PC：导航条深灰，不随内容区主题大变
    final railBg = isDark ? const Color(0xFF17171A) : const Color(0xFF2E2E2E);
    final unselected = const Color(0xFF9C9C9C);
    final selected = AppColors.lime;
    final nickname = (AuthManager.instance.nickname ?? '').trim();
    return Container(
      width: 64,
      color: railBg,
      child: Column(
        children: [
          const SizedBox(height: 18),
          // 头像：点击打开「我的」面板
          GestureDetector(
            onTap: onAvatarTap,
            child: ImAvatar(
              src: AuthManager.instance.avatar ?? '',
              name: nickname.isNotEmpty ? nickname : '我',
              size: 36,
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(height: 22),
          _railItem(
            icon: Icons.chat_bubble_outline,
            selectedIcon: Icons.chat_bubble,
            label: '消息',
            selected: selectedIndex == 0,
            selectedColor: selected,
            unselectedColor: unselected,
            badge: totalUnread,
            onTap: () => onSelect(0),
          ),
          const SizedBox(height: 10),
          _railItem(
            icon: Icons.person_outline,
            selectedIcon: Icons.person,
            label: '通讯录',
            selected: selectedIndex == 1,
            selectedColor: selected,
            unselectedColor: unselected,
            badge: pendingRequests,
            onTap: () => onSelect(1),
          ),
          const Spacer(),
          // 底部设置：打开「我的」面板
          _railIcon(
            icon: Icons.settings_outlined,
            color: unselected,
            onTap: onSettingsTap,
          ),
          const SizedBox(height: 18),
        ],
      ),
    );
  }

  /// 图标按钮（无角标）。
  Widget _railIcon({
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) =>
      Tooltip(
        message: '设置',
        waitDuration: const Duration(milliseconds: 500),
        child: IconButton(
          onPressed: onTap,
          icon: Icon(icon, size: 24, color: color),
        ),
      );

  /// 带选中态 + 角标的导航项（微信 PC：选中图标变色，无大背景块）。
  Widget _railItem({
    required IconData icon,
    required IconData selectedIcon,
    required String label,
    required bool selected,
    required Color selectedColor,
    required Color unselectedColor,
    required int badge,
    required VoidCallback onTap,
  }) =>
      Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 500),
        child: GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Center(
                  child: Icon(
                    selected ? selectedIcon : icon,
                    size: 26,
                    color: selected ? selectedColor : unselectedColor,
                  ),
                ),
                if (badge > 0)
                  Positioned(
                    top: 4,
                    right: 0,
                    child: _TabBadge(count: badge),
                  ),
              ],
            ),
          ),
        ),
      );
}

/// 桌面右栏空态占位（微信 PC 首页大 Logo + slogan 风格）。
class _DesktopEmptyPlaceholder extends StatelessWidget {
  final ThemeColors colors;

  const _DesktopEmptyPlaceholder({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.forum_outlined, size: 88, color: colors.muted),
          const SizedBox(height: 20),
          Text(
            'IM，让沟通更简单',
            style: TextStyle(fontSize: 16, color: colors.muted),
          ),
          const SizedBox(height: 8),
          Text(
            '从左侧选择一个会话开始聊天',
            style: TextStyle(fontSize: 13, color: colors.muted),
          ),
        ],
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

