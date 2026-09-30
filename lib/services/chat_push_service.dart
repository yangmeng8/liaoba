import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auth_manager.dart';
import 'push_service.dart';

/// 聊天推送服务（单例）：消息过滤、去重、前台横幅、本地通知、点击跳转。
///
/// 消息到达过滤链：
/// 推送开关启用？（未登录=关）→ 有登录 token？（异步读后再查开关防竞态）
/// → 解析 payload（兼容极光 extras/message/content 多层结构）
/// → messageId 去重（LRU 200 条）→ 不是自己发的？→ 不在当前会话聊天页？
/// → needNotify != false？→ 前台 Android → App 内横幅；否则本地通知 + 角标。
///
/// 点击通知跳转：Android 走原生 `im/push_open` channel 拉起 App（含冷启动
/// pending 点击消费）→ popUntil 根路由 → 切换到消息 tab。
class ChatPushService with WidgetsBindingObserver {
  ChatPushService._();

  static final ChatPushService instance = ChatPushService._();

  static const int _maxDedupCacheSize = 200;
  static const MethodChannel _androidPushOpenChannel =
      MethodChannel('im/push_open');
  static const MethodChannel _notificationVisibilityChannel =
      MethodChannel('im/notification_visibility');

  final LinkedHashMap<String, DateTime> _seenMessageIds =
      LinkedHashMap<String, DateTime>();

  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  JPush? _jpush;
  GlobalKey<NavigatorState>? _navigatorKey;
  void Function(int tabIndex)? _switchTab;
  String? _activeTargetId;
  int _badgeCount = 0;
  bool _initialized = false;
  bool _pendingOpenMessagePage = false;
  bool _androidPushOpenBridgeInitialized = false;
  // 退出登录后，即使系统/极光还有延迟回调到达，也不能再展示旧账号消息。
  bool _pushHandlingEnabled = false;

  // App 内横幅（OverlayEntry + 定时移除）
  OverlayEntry? _bannerEntry;
  Timer? _bannerTimer;

  void init(JPush jpush) {
    _jpush = jpush;
    if (_initialized) {
      return;
    }
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initNativePushOpenBridge());
  }

  /// main.dart 注入全局导航 Key 与底部 Tab 切换能力（避免与 main.dart 循环依赖）。
  void attach({
    required GlobalKey<NavigatorState> navigatorKey,
    required void Function(int tabIndex) switchTab,
  }) {
    _navigatorKey = navigatorKey;
    _switchTab = switchTab;
  }

  /// 根据本地登录态同步推送处理开关。应用启动时调用，避免未登录处理旧回调。
  Future<void> syncPushStateFromLogin() async {
    await setPushHandlingEnabled(AuthManager.instance.isLoggedIn);
  }

  /// 登录成功后恢复 Flutter/原生推送处理。
  Future<void> enablePushHandling() async {
    await setPushHandlingEnabled(true);
  }

  /// 退出登录时立即关闭推送处理，并清理当前会话状态。
  Future<void> disablePushHandlingForLogout() async {
    _pushHandlingEnabled = false;
    _activeTargetId = null;
    _pendingOpenMessagePage = false;
    _seenMessageIds.clear();
    _badgeCount = 0;
    _removeBanner();
    await _syncNativeChatVisibility(false);
    await _syncNativePushEnabled(false);
    debugPrint('[ChatPush] 已关闭退出账号后的消息/通知处理');
  }

  Future<void> setPushHandlingEnabled(bool enabled) async {
    _pushHandlingEnabled = enabled;
    if (!enabled) {
      _activeTargetId = null;
      _pendingOpenMessagePage = false;
    }
    await _syncNativePushEnabled(enabled);
    debugPrint('[ChatPush] 推送处理状态: $enabled');
  }

  /// 进入聊天页时标记当前会话可见：正在聊天时新消息不弹通知/横幅。
  /// [targetId] 私聊=对方 userId、群聊=groupId、频道=channelId（与推送
  /// payload 解析出的 targetId 同源，可直接比对）。
  void markConversationVisible({required String targetId}) {
    if (targetId.isEmpty) {
      return;
    }
    _activeTargetId = targetId;
    debugPrint('[ChatPush] 当前可见会话: targetId=$_activeTargetId');
    unawaited(_syncNativeChatVisibility(true));
  }

  /// 离开聊天页时清除标记（仅当离开的正是当前标记的会话）。
  void markConversationHidden({required String targetId}) {
    if (targetId.isNotEmpty && _activeTargetId != targetId) {
      return;
    }
    _activeTargetId = null;
    debugPrint('[ChatPush] 当前会话已隐藏: targetId=$targetId');
    unawaited(_syncNativeChatVisibility(false));
  }

  Future<void> handleIncomingPush(
    Map<String, dynamic> rawMessage, {
    bool shouldShowLocalNotification = true,
    bool shouldShowInAppBanner = false,
  }) async {
    if (!_pushHandlingEnabled) {
      debugPrint('[ChatPush] 推送处理已关闭，忽略收到的消息');
      return;
    }
    if (!await _hasLoginInfo()) {
      debugPrint('[ChatPush] 当前无登录信息，忽略收到的消息');
      return;
    }
    // 登录态读取是异步的，期间可能刚好完成退出；再次检查开关，避免竞态下补发通知。
    if (!_pushHandlingEnabled) {
      debugPrint('[ChatPush] 检查登录态后推送处理已关闭，忽略收到的消息');
      return;
    }
    // 推送规则：
    // 1. 通知消息：后台由系统展示，前台 Android 转 App 内横幅，不补发本地通知；
    // 2. 自定义消息：前台可展示 App 内横幅；
    // 3. 命中当前聊天页（无论群聊/私聊）不显示任何额外提醒。
    final ChatPushPayload? payload = ChatPushPayload.fromRaw(rawMessage);
    if (payload == null) {
      debugPrint('[ChatPush] 忽略无法识别的推送消息: $rawMessage');
      return;
    }

    if (!_rememberMessage(payload.messageId)) {
      debugPrint('[ChatPush] 命中去重，跳过重复推送: ${payload.messageId}');
      return;
    }

    final String currentUserId = AuthManager.instance.userId?.toString() ?? '';
    final bool isSelfSent = payload.isSender(currentUserId);
    final bool isCurrentConversation =
        _isAppForeground && _isActiveConversation(payload);

    debugPrint(
      '[ChatPush] 收到消息: msgId=${payload.messageId}, '
      'targetId=${payload.targetId}, activeTargetId=${_activeTargetId ?? ''}, '
      'senderId=${payload.senderId}, currentUserId=$currentUserId, '
      'isSelfSent=$isSelfSent, needNotify=${payload.needNotify}, '
      'shouldShowLocalNotification=$shouldShowLocalNotification, '
      'shouldShowInAppBanner=$shouldShowInAppBanner, '
      'foreground=$_isAppForeground, lifecycle=$_appLifecycleState, '
      'currentConversation=$isCurrentConversation',
    );

    if (isSelfSent) {
      debugPrint('[ChatPush] 自己发送的消息，跳过通知');
      return;
    }

    if (isCurrentConversation) {
      debugPrint('[ChatPush] 当前正停留在该聊天页，跳过通知');
      return;
    }

    if (!payload.needNotify) {
      debugPrint('[ChatPush] 消息标记为无需提醒，跳过通知');
      return;
    }

    if (shouldShowInAppBanner && _isAppForeground) {
      if (!_pushHandlingEnabled) return;
      _showInAppBanner(payload);
      return;
    }

    // 通知消息本身已由系统远程推送链路覆盖（后台时）；
    // 前台时由上方横幅分支处理，一般无需补发本地通知。
    if (!shouldShowLocalNotification) {
      debugPrint('[ChatPush] 当前回调不补本地通知');
      return;
    }

    if (_pushHandlingEnabled) {
      await _showLocalNotification(payload);
    }
  }

  void handleNotificationOpened(Map<String, dynamic> rawMessage) {
    if (!_pushHandlingEnabled) {
      debugPrint('[ChatPush] 推送处理已关闭，忽略通知点击');
      return;
    }
    _badgeCount = 0;
    _pendingOpenMessagePage = true;
    final ChatPushPayload? payload = ChatPushPayload.fromRaw(rawMessage);
    debugPrint(
      '[ChatPush] 点击通知: targetId=${payload?.targetId ?? ''}, raw=$rawMessage',
    );
    unawaited(_requestAndroidBringAppToFront());
    unawaited(_flushPendingOpenMessagePage());
  }

  /// iOS：把 UNUserNotificationCenter.delegate 重新绑定到 AppDelegate
  /// （极光插件可能抢走代理，导致前台抑制逻辑失效）。
  Future<void> rebindIOSNotificationDelegate() async {
    if (!Platform.isIOS) {
      return;
    }
    try {
      await _notificationVisibilityChannel.invokeMethod<void>(
        'rebindNotificationDelegate',
      );
      debugPrint('[ChatPush] 已重新绑定 iOS 通知代理到 AppDelegate');
    } catch (e, st) {
      debugPrint('[ChatPush] 重新绑定 iOS 通知代理失败: $e\n$st');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appLifecycleState = state;
    debugPrint('[ChatPush] 生命周期变化: $state');
    if (state == AppLifecycleState.resumed) {
      _badgeCount = 0;
      unawaited(rebindIOSNotificationDelegate());
      unawaited(_flushPendingOpenMessagePage());
      return;
    }
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _badgeCount = 0;
      _removeBanner();
      unawaited(_clearSystemBadgeOnBackground(state));
    }
  }

  bool get _isAppForeground => _appLifecycleState == AppLifecycleState.resumed;

  bool _isActiveConversation(ChatPushPayload payload) {
    return _activeTargetId != null &&
        payload.targetId.isNotEmpty &&
        payload.targetId == _activeTargetId;
  }

  /// messageId 去重：LRU 200 条（通知与自定义消息回调可能重复收到同一消息）。
  bool _rememberMessage(String messageId) {
    if (messageId.isEmpty) {
      return true;
    }
    if (_seenMessageIds.containsKey(messageId)) {
      return false;
    }
    _seenMessageIds[messageId] = DateTime.now();
    while (_seenMessageIds.length > _maxDedupCacheSize) {
      _seenMessageIds.remove(_seenMessageIds.keys.first);
    }
    return true;
  }

  /// Android：建立与 MainActivity 的通知点击桥接，并消费冷启动时的
  /// pending 点击（点击通知拉起已 killed 的 App 时，Flutter 尚未就绪，
  /// 原生先缓存 payload，等 channel 就绪后在此消费）。
  Future<void> _initNativePushOpenBridge() async {
    if (!Platform.isAndroid || _androidPushOpenBridgeInitialized) {
      return;
    }
    _androidPushOpenBridgeInitialized = true;
    _androidPushOpenChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'onNotificationOpened') {
        return;
      }
      final Map<String, dynamic> rawMessage =
          _coerceStringDynamicMap(call.arguments);
      debugPrint('[ChatPush] 收到 Android 原生通知点击回调: $rawMessage');
      handleNotificationOpened(rawMessage);
    });

    try {
      final dynamic pending =
          await _androidPushOpenChannel.invokeMethod<dynamic>(
        'consumePendingNotificationOpen',
      );
      final Map<String, dynamic> pendingMessage =
          _coerceStringDynamicMap(pending);
      if (pendingMessage.isNotEmpty) {
        debugPrint('[ChatPush] 消费 Android 原生待处理通知点击: $pendingMessage');
        handleNotificationOpened(pendingMessage);
      }
    } catch (e, st) {
      debugPrint('[ChatPush] 初始化 Android 原生通知点击桥接失败: $e\n$st');
    }
  }

  Future<void> _requestAndroidBringAppToFront() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _androidPushOpenChannel.invokeMethod<void>('bringAppToFront');
      debugPrint('[ChatPush] 已请求 Android 原生将 App 拉到前台');
    } catch (e, st) {
      debugPrint('[ChatPush] 请求 Android 原生拉起 App 失败: $e\n$st');
    }
  }

  Future<void> _clearSystemBadgeOnBackground(AppLifecycleState state) async {
    final JPush? jpush = _jpush;
    if (jpush == null) {
      debugPrint('[ChatPush] 进入后台时清角标失败: JPush 未初始化');
      return;
    }
    try {
      await jpush.clearBadge();
      debugPrint('[ChatPush] 应用进入后台，已清空系统角标: state=$state');
    } catch (e, st) {
      debugPrint('[ChatPush] 应用进入后台清空系统角标失败: $e\n$st');
    }
  }

  Map<String, dynamic> _coerceStringDynamicMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value.map<String, dynamic>(
        (String key, dynamic val) => MapEntry(key, _normalizeChannelValue(val)),
      );
    }
    if (value is Map) {
      return value.map<String, dynamic>(
        (dynamic key, dynamic val) =>
            MapEntry(key.toString(), _normalizeChannelValue(val)),
      );
    }
    return <String, dynamic>{};
  }

  dynamic _normalizeChannelValue(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value.map<String, dynamic>(
        (String key, dynamic val) => MapEntry(key, _normalizeChannelValue(val)),
      );
    }
    if (value is Map) {
      return value.map<String, dynamic>(
        (dynamic key, dynamic val) =>
            MapEntry(key.toString(), _normalizeChannelValue(val)),
      );
    }
    if (value is List) {
      return value.map<dynamic>(_normalizeChannelValue).toList();
    }
    return value;
  }

  /// 重试 5 次 × 250ms 等 Navigator 就绪（冷启动点击通知时首帧可能未渲染）。
  Future<void> _flushPendingOpenMessagePage() async {
    if (!_pendingOpenMessagePage) {
      return;
    }
    for (int attempt = 1; attempt <= 5; attempt++) {
      if (!_pendingOpenMessagePage) {
        return;
      }
      final bool opened = await _openMessagePageFromNotification(
        attempt: attempt,
      );
      if (opened) {
        _pendingOpenMessagePage = false;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    debugPrint('[ChatPush] 点击通知跳转消息页失败: 多次重试后仍未成功');
  }

  Future<bool> _openMessagePageFromNotification({
    required int attempt,
  }) async {
    try {
      final NavigatorState? navigator = _navigatorKey?.currentState;
      debugPrint(
        '[ChatPush] 尝试跳转消息页: attempt=$attempt, '
        'foreground=$_isAppForeground, navigatorReady=${navigator != null}',
      );
      if (navigator == null) {
        debugPrint('[ChatPush] Navigator 尚未就绪，等待下一次重试');
        return false;
      }
      // 清掉上层路由回到主框架（已登录时根路由即 HomeShell），再切到消息 tab
      navigator.popUntil((route) => route.isFirst);
      _switchTab?.call(0);
      debugPrint('[ChatPush] 点击通知后已跳转到主页消息 tab');
      return true;
    } catch (e, st) {
      debugPrint('[ChatPush] 点击通知跳转消息页异常: $e\n$st');
      return false;
    }
  }

  /// iOS：同步聊天页可见状态（AppDelegate 前台通知按会话抑制用）。
  Future<void> _syncNativeChatVisibility(bool visible) async {
    if (!Platform.isIOS) {
      return;
    }
    try {
      await _notificationVisibilityChannel.invokeMethod<void>(
        'setChatPageVisible',
        <String, dynamic>{
          'visible': visible,
          'targetId': visible ? (_activeTargetId ?? '') : '',
        },
      );
      debugPrint('[ChatPush] 已同步原生聊天页可见状态: $visible');
    } catch (e, st) {
      debugPrint('[ChatPush] 同步原生聊天页可见状态失败: $e\n$st');
    }
  }

  /// iOS：同步推送处理开关（登出后忽略前台通知与点击）。
  Future<void> _syncNativePushEnabled(bool enabled) async {
    if (!Platform.isIOS) {
      return;
    }
    try {
      await _notificationVisibilityChannel.invokeMethod<void>(
        'setPushEnabled',
        <String, dynamic>{'enabled': enabled},
      );
      debugPrint('[ChatPush] 已同步 iOS 推送开关: $enabled');
    } catch (e, st) {
      debugPrint('[ChatPush] 同步 iOS 推送开关失败: $e\n$st');
    }
  }

  Future<bool> _hasLoginInfo() async => AuthManager.instance.isLoggedIn;

  Future<void> _showLocalNotification(ChatPushPayload payload) async {
    final JPush? jpush = _jpush;
    if (jpush == null) {
      debugPrint('[ChatPush] JPush 未初始化，无法发送本地通知');
      return;
    }

    _badgeCount += 1;
    final int notificationId = payload.messageId.hashCode & 0x7fffffff;
    final Map<String, String> extra = <String, String>{
      'msgId': payload.messageId,
      ...payload.extraStringMap,
    };

    final LocalNotification notification = LocalNotification(
      id: notificationId,
      // 标题固定用 App 名「IM」（通知左侧为 App 图标，
      // 右侧上行标题、下行正文），正文显示消息内容/兜底文案
      title: 'IM',
      content: payload.notificationBody,
      fireTime: DateTime.now().add(const Duration(milliseconds: 300)),
      badge: _badgeCount,
      extra: extra,
    );

    try {
      await jpush.sendLocalNotification(notification);
      await jpush.setBadge(_badgeCount);
      debugPrint(
        '[ChatPush] 已发送本地通知: id=$notificationId, badge=$_badgeCount',
      );
    } catch (e, st) {
      debugPrint('[ChatPush] 发送本地通知失败: $e\n$st');
    }
  }

  /// 前台 App 内横幅（顶部卡片，3 秒自动消失，附震动反馈）。
  void _showInAppBanner(ChatPushPayload payload) {
    debugPrint('[ChatPush] 前台展示 App 内横幅: targetId=${payload.targetId}');
    final OverlayState? overlay = _navigatorKey?.currentState?.overlay;
    if (overlay == null) {
      debugPrint('[ChatPush] Overlay 未就绪，跳过 App 内横幅');
      return;
    }
    unawaited(HapticFeedback.mediumImpact());
    _removeBanner();
    _bannerEntry = OverlayEntry(
      builder: (context) => _PushBanner(payload: payload),
    );
    overlay.insert(_bannerEntry!);
    _bannerTimer = Timer(const Duration(seconds: 3), _removeBanner);
  }

  void _removeBanner() {
    _bannerTimer?.cancel();
    _bannerTimer = null;
    _bannerEntry?.remove();
    _bannerEntry = null;
  }
}

/// 顶部横幅：图标 + 标题 + 「发送者：内容」，明暗主题自适应。
class _PushBanner extends StatelessWidget {
  final ChatPushPayload payload;

  const _PushBanner({required this.payload});

  @override
  Widget build(BuildContext context) {
    final bool isDark = Theme.of(context).brightness == Brightness.dark;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF2C2C2E) : Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x22000000),
                    blurRadius: 18,
                    offset: Offset(0, 10),
                  ),
                ],
              ),
              child: Row(
                children: <Widget>[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset(
                      'assets/icon.png',
                      width: 36,
                      height: 36,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          payload.notificationTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF111827),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          payload.bannerText,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isDark
                                ? const Color(0xFFB0B0B3)
                                : const Color(0xFF374151),
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 推送消息实体：兼容极光通知/自定义消息的多种 payload 结构。
class ChatPushPayload {
  const ChatPushPayload({
    required this.messageId,
    required this.conversationId,
    required this.targetId,
    required this.senderId,
    required this.title,
    required this.body,
    required this.needNotify,
    required this.extras,
  });

  final String messageId;
  final String conversationId;
  final String targetId;
  final String senderId;
  final String title;
  final String body;
  final bool needNotify;
  final Map<String, dynamic> extras;

  String get notificationTitle => title.isNotEmpty
      ? title
      : (senderName?.isNotEmpty ?? false)
          ? senderName!
          : '新消息';

  String get notificationBody => body.isNotEmpty ? body : '你收到一条新消息';

  String get bannerSender =>
      (senderName?.isNotEmpty ?? false) ? senderName! : senderId;

  String get bannerContent => body.isNotEmpty ? body : notificationBody;

  String get bannerText {
    final String sender = bannerSender.trim();
    final String content = bannerContent.trim();
    if (sender.isEmpty) {
      return content;
    }
    if (content.isEmpty) {
      return sender;
    }
    return '$sender：$content';
  }

  bool isSender(String currentUserId) {
    if (currentUserId.isEmpty) {
      return false;
    }
    return senderId == currentUserId;
  }

  String? get senderName => _readString(
        <Map<String, dynamic>>[
          _asMap(extras['params']),
          extras,
        ],
        const <String>[
          'senderName',
          'senderNickname',
          'senderNickName',
          'fromName',
          'nickname',
          'nickName',
          'fromUserName',
          'fromAccount',
        ],
      );

  Map<String, String> get extraStringMap {
    return extras.map(
      (String key, dynamic value) => MapEntry(key, value?.toString() ?? ''),
    );
  }

  /// 从原始推送 map 解析出结构化实体；完全无法识别时返回 null。
  static ChatPushPayload? fromRaw(Map<String, dynamic> raw) {
    final Map<String, dynamic> extras = _asMap(raw['extras']);
    final Map<String, dynamic> jpushExtra =
        _asMap(extras['cn.jpush.android.EXTRA']);
    final Map<String, dynamic> paramsData = _asMap(jpushExtra['params']);
    final Map<String, dynamic> messageData = _asMap(raw['message']);
    final Map<String, dynamic> contentData = _asMap(raw['content']);
    final List<Map<String, dynamic>> structuredSources =
        <Map<String, dynamic>>[
      paramsData,
      jpushExtra,
      messageData,
      contentData,
      extras,
      raw,
    ];
    final List<Map<String, dynamic>> titleSources = <Map<String, dynamic>>[
      raw,
      messageData,
      contentData,
      extras,
    ];

    final String? messageId = _readString(
      structuredSources,
      const <String>[
        '_j_msgid',
        'MsgId',
        'MsgID',
        'msgId',
        'msgID',
        'messageId',
        'messageID',
        'cn.jpush.android.MSG_ID',
        'id',
        'mesageId',
      ],
    );

    final String conversationId = _resolveConversationId(structuredSources);
    final String targetId = _resolveTargetId(structuredSources);
    final String? senderId = _readString(
      structuredSources,
      const <String>[
        'From_Account',
        'fromAccount',
        'senderId',
        'senderID',
        'fromUserId',
        'fromUserID',
        'fromUid',
        'from_uid',
        'sendUserId',
        'sendUserID',
        'sender',
        'from',
      ],
    );
    final String? title = _readString(
      titleSources,
      const <String>[
        'title',
        'alert',
      ],
    );
    final String? body = _readString(
      <Map<String, dynamic>>[
        paramsData,
        jpushExtra,
        messageData,
        contentData,
        raw,
        extras,
      ],
      const <String>[
        'messageContent',
        'message_content',
        'content',
        'message',
        'msg_content',
        'msgContent',
        'preview',
        'text',
        'alert',
      ],
    );
    final bool needNotify = _readBool(
          structuredSources,
          const <String>[
            'needNotify',
            'need_notify',
            'shouldNotify',
            'isRemind',
            'is_remind',
          ],
        ) ??
        true;

    if ((messageId == null || messageId.isEmpty) &&
        conversationId.isEmpty &&
        (body == null || body.isEmpty)) {
      return null;
    }

    return ChatPushPayload(
      messageId: messageId ?? _buildFallbackMessageId(raw, extras, body),
      conversationId: conversationId,
      targetId: targetId,
      senderId: senderId ?? '',
      title: title ?? '',
      body: body ?? '',
      needNotify: needNotify,
      extras: <String, dynamic>{
        ...extras,
        ...jpushExtra,
      },
    );
  }

  static String _buildFallbackMessageId(
    Map<String, dynamic> raw,
    Map<String, dynamic> extras,
    String? body,
  ) {
    final Object seed = <String, Object?>{
      'raw': raw,
      'extras': extras,
      'body': body,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    return seed.hashCode.toString();
  }

  static String _resolveConversationId(List<Map<String, dynamic>> sources) {
    final String? directConversationId = _readString(
      sources,
      const <String>[
        'conversationId',
        'conversationID',
        'conversation_id',
        'convId',
        'convID',
        'sessionId',
        'sessionID',
        'session_id',
      ],
    );
    if (directConversationId != null && directConversationId.isNotEmpty) {
      return directConversationId;
    }

    final String? groupId = _readString(
      sources,
      const <String>[
        'GroupId',
        'groupId',
        'groupID',
        'toGroupId',
      ],
    );
    if (groupId != null && groupId.isNotEmpty) {
      return 'group_$groupId';
    }

    final String? userId = _readString(
      sources,
      const <String>[
        'From_Account',
        'fromAccount',
        'userId',
        'userID',
        'toUserId',
        'peerId',
      ],
    );
    if (userId != null && userId.isNotEmpty) {
      return 'c2c_$userId';
    }

    return '';
  }

  static String _resolveTargetId(List<Map<String, dynamic>> sources) {
    final String? groupId = _readString(
      sources,
      const <String>[
        'GroupId',
        'groupId',
        'groupID',
        'toGroupId',
      ],
    );
    if (groupId != null && groupId.isNotEmpty) {
      return groupId;
    }

    final String? peerId = _readString(
      sources,
      const <String>[
        'From_Account',
        'fromAccount',
        'userId',
        'userID',
        'fromUserId',
        'fromUserID',
        'peerId',
        'peerID',
        'senderId',
        'senderID',
        'from',
      ],
    );
    if (peerId != null && peerId.isNotEmpty) {
      return peerId;
    }

    final String conversationId = _resolveConversationId(sources);
    if (conversationId.startsWith('group_')) {
      return conversationId.substring('group_'.length);
    }
    if (conversationId.startsWith('c2c_')) {
      return conversationId.substring('c2c_'.length);
    }

    return '';
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map(
        (dynamic key, dynamic val) => MapEntry(key.toString(), val),
      );
    }
    if (value is String) {
      final dynamic decoded = _tryDecodeJson(value);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      if (decoded is Map) {
        return decoded.map(
          (dynamic key, dynamic val) => MapEntry(key.toString(), val),
        );
      }
    }
    return <String, dynamic>{};
  }

  static dynamic _tryDecodeJson(String value) {
    final String trimmed = value.trim();
    if (!(trimmed.startsWith('{') && trimmed.endsWith('}')) &&
        !(trimmed.startsWith('[') && trimmed.endsWith(']'))) {
      return null;
    }
    try {
      return jsonDecode(trimmed);
    } catch (_) {
      return null;
    }
  }

  static String? _readString(
    List<Map<String, dynamic>> sources,
    List<String> keys,
  ) {
    for (final Map<String, dynamic> source in sources) {
      for (final String key in keys) {
        final dynamic value = source[key];
        if (value is String) {
          final String trimmed = value.trim();
          if (trimmed.isNotEmpty) {
            return trimmed;
          }
          continue;
        }
        if (value != null && value is! Map && value is! List) {
          final String text = value.toString().trim();
          if (text.isNotEmpty) {
            return text;
          }
        }
      }
    }
    return null;
  }

  static bool? _readBool(
    List<Map<String, dynamic>> sources,
    List<String> keys,
  ) {
    for (final Map<String, dynamic> source in sources) {
      for (final String key in keys) {
        final dynamic value = source[key];
        if (value is bool) {
          return value;
        }
        if (value is num) {
          return value != 0;
        }
        if (value is String) {
          final String normalized = value.trim().toLowerCase();
          if (normalized == 'true' || normalized == '1') {
            return true;
          }
          if (normalized == 'false' || normalized == '0') {
            return false;
          }
        }
      }
    }
    return null;
  }
}
