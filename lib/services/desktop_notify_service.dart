import 'dart:async';
import 'dart:convert' show JsonDecoder;
import 'dart:io' show Directory, File, Platform;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:windows_taskbar/windows_taskbar.dart';

import '../models/im_ws_frame.dart';
import '../services/auth_manager.dart';
import '../services/chat_push_service.dart';
import '../services/im_websocket.dart';
import '../shared/json_utils.dart';
import '../stores/conversation_store.dart';

/// 桌面端通知服务（Windows/macOS，对齐 Telegram 桌面版行为）：
///
/// - 任务栏角标：会话未读总数实时画成「红底白字数字」覆盖到任务栏图标右下角
/// - 系统通知：App 在后台（最小化/失焦）收到消息弹 Windows Toast，点击把
///   窗口还原置前
/// - 提示音：前台时收到「非当前会话」的消息、或后台收到消息，播放
///   assets/sounds/notify.wav（正在看的会话不响，与移动端推送抑制一致）
///
/// 消息来源与移动端不同：桌面无极光 SDK，直接监听 WebSocket 通知流
/// （ImWebSocket.notificationStream）；未读总数取 ConversationStore 聚合结果。
///
/// 提示音与「点击 Toast 置前」走原生方法通道 im/desktop_notify（Windows
/// runner 内实现，见 windows/runner/flutter_window.cpp）。
class DesktopNotifyService with WidgetsBindingObserver {
  DesktopNotifyService._();

  static final DesktopNotifyService instance = DesktopNotifyService._();

  static const MethodChannel _channel = MethodChannel('im/desktop_notify');

  /// 已知的聊天内容消息类型（后端 ImMessageContentTypeEnum）。
  /// 只对真实聊天内容响铃/弹通知；系统事件（撤回 2101/已读/关系事件）、
  /// 通话记录（1610/1611）不提醒。新增后端消息类型时在此补充。
  static const Set<int> _chatContentTypes = <int>{
    101, // 文本
    102, // 图片
    103, // 语音
    104, // 视频
    105, // 文件
    108, // 名片
    115, // 图片表情
    125, // 频道素材
  };

  /// 覆盖图标文件名（写入 exe 旁的 data/flutter_assets，包约束要求 .ico）。
  static const String _badgeAssetName = 'notify_badge.ico';

  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  bool _initialized = false;

  /// 上次同步到任务栏的未读总数（避免重复写文件/调接口）。
  int _lastBadge = -1;

  /// 角标图标缓存：总数对应的 ICO 文件已生成过（写文件是异步防抖）。
  bool _badgeWriting = false;

  /// 初始化：仅桌面平台生效；幂等。
  void init() {
    if (_initialized) {
      return;
    }
    if (!Platform.isWindows && !Platform.isMacOS) {
      return;
    }
    _initialized = true;
    WidgetsBinding.instance.addObserver(this);
    ImWebSocket.instance.notificationStream.listen(_onWsNotification);
    ConversationStore.instance.addListener(_onStoreChanged);
    if (Platform.isWindows || Platform.isMacOS) {
      unawaited(_setupLocalNotifier());
    }
    debugPrint('[DesktopNotify] 已初始化 (platform=${Platform.operatingSystem})');
  }

  Future<void> _setupLocalNotifier() async {
    try {
      // Toast 的应用标识：Windows 需要开始菜单快捷方式作为 AUMID 宿主，
      // 首次 setup 会静默创建（要求系统 Win10+；失败则后续 show 静默跳过）
      await localNotifier.setup(appName: 'IM');
    } catch (e) {
      debugPrint('[DesktopNotify] 本地通知初始化失败（Toast 将不可用）: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
  }

  bool get _isForeground => _lifecycle == AppLifecycleState.resumed;

  // ---------------------------------------------------------------------
  // WebSocket 新消息 → 提示音 / Toast
  // ---------------------------------------------------------------------

  void _onWsNotification(ImWsNotification n) {
    // 桌面端只在登录后处理（WS 也仅在登录态连接，双保险）
    final int? me = AuthManager.instance.userId;
    if (me == null || !AuthManager.instance.isLoggedIn) {
      return;
    }
    if (!_chatContentTypes.contains(n.contentType)) {
      return;
    }
    // 消息删除回执（payload.status=3）复用文本类型：不响铃
    if (asInt(n.payload['status']) == 3) {
      return;
    }
    // 自己发的消息（多端同步回显）不提醒
    if (asInt(n.payload['senderId']) == me) {
      return;
    }
    final int? targetId = _resolveTargetId(n, me);
    if (targetId == null) {
      return;
    }
    // 前台 + 正在看的会话：消息直接可见，不提醒（与移动端抑制规则一致）
    final String? active = ChatPushService.instance.activeTargetId;
    final bool isActiveConversation =
        _isForeground && active != null && active == '$targetId';
    if (isActiveConversation) {
      return;
    }

    // 走到这里说明这条消息必然产生未读：立即乐观 +1 更新任务栏角标，
    // 不等会话列表刷新（800ms 防抖 + 拉取往返）；稍后 ConversationStore
    // 重算会以真实总数自动校准
    _syncBadge((_lastBadge <= 0 ? 0 : _lastBadge) + 1);

    // 提示音：前台非当前会话、或后台收到消息，都要响
    _playSound();
    // Toast：仅后台（最小化/失焦）弹出
    if (!_isForeground) {
      _showToast(n, targetId, me);
    }
  }

  /// 会话对端 id：私聊=对方（sender/receiver 中非本人一侧）、
  /// 群聊=groupId、频道=channelId。
  int? _resolveTargetId(ImWsNotification n, int me) {
    switch (n.conversationType) {
      case 1:
        final int sender = asInt(n.payload['senderId']);
        if (sender > 0 && sender != me) return sender;
        final int receiver = asInt(n.payload['receiverId']);
        if (receiver > 0 && receiver != me) return receiver;
        return null;
      case 2:
        final int group = asInt(n.payload['groupId']);
        return group > 0 ? group : null;
      case 3:
        final int channel = asInt(n.payload['channelId']);
        return channel > 0 ? channel : null;
      default:
        return null;
    }
  }

  void _playSound() {
    // im/desktop_notify 通道：Windows 用 PlaySound，macOS 用 NSSound
    try {
      unawaited(_channel.invokeMethod<void>('playSound'));
    } catch (e) {
      debugPrint('[DesktopNotify] 播放提示音失败: $e');
    }
  }

  void _showToast(ImWsNotification n, int targetId, int me) {
    if (!Platform.isWindows && !Platform.isMacOS) {
      return;
    }
    try {
      final String title = _resolveToastTitle(n, targetId);
      final String body = _resolveToastBody(n);
      final LocalNotification toast =
          LocalNotification(title: title, body: body, silent: true);
      toast.onClick = () {
        // 系统只负责激活，窗口还原置前走原生通道（含最小化恢复）
        unawaited(_channel.invokeMethod<void>('bringToFront'));
      };
      unawaited(toast.show());
    } catch (e) {
      debugPrint('[DesktopNotify] 弹出系统通知失败: $e');
    }
  }

  /// Toast 标题：私聊=发送者昵称、群聊=群名、频道=频道名；取不到回退 App 名。
  String _resolveToastTitle(ImWsNotification n, int targetId) {
    final store = ConversationStore.instance;
    switch (n.conversationType) {
      case 1:
        final sender = asInt(n.payload['senderId']);
        return store.friends[sender]?.displayName ?? '新消息';
      case 2:
        return store.groups[targetId]?.name ?? '新消息';
      case 3:
        return store.channels[targetId]?.name ?? '新消息';
      default:
        return '新消息';
    }
  }

  /// Toast 正文：文本直接展示，其余类型按 Telegram 风格给类型占位。
  String _resolveToastBody(ImWsNotification n) {
    switch (n.contentType) {
      case 101:
        return _extractText(n.payload['content']);
      case 102:
        return '[图片]';
      case 103:
        return '[语音消息]';
      case 104:
        return '[视频]';
      case 105:
        return '[文件]';
      case 108:
        return '[名片]';
      case 115:
        return '[表情]';
      case 125:
        return '[频道素材]';
      default:
        return '你收到一条新消息';
    }
  }

  /// 文本消息 content 兼容解析：可能是纯文本、JSON 字符串或内层 map
  /// （后端把 {content: "..."} 整体放进 payload.content）。
  String _extractText(dynamic raw) {
    String text = '';
    if (raw is Map) {
      for (final String key in <String>['content', 'text', 'message']) {
        final dynamic v = raw[key];
        if (v != null && v.toString().isNotEmpty) {
          text = v.toString();
          break;
        }
      }
    } else if (raw != null) {
      text = raw.toString();
      // JSON 字符串：解析后取内层文本字段
      if (text.startsWith('{') && text.endsWith('}')) {
        try {
          final dynamic decoded =
              const JsonDecoder().convert(text) as dynamic;
          if (decoded is Map) {
            for (final String key in <String>['content', 'text', 'message']) {
              final dynamic v = decoded[key];
              if (v != null && v.toString().isNotEmpty) {
                text = v.toString();
                break;
              }
            }
          }
        } catch (_) {
          // 非 JSON 保持原文
        }
      }
    }
    return text.isEmpty ? '你收到一条新消息' : text;
  }

  // ---------------------------------------------------------------------
  // 任务栏未读角标
  // ---------------------------------------------------------------------

  void _onStoreChanged() {
    int total = 0;
    for (final c in ConversationStore.instance.conversations) {
      total += c.unreadCount;
    }
    _syncBadge(total);
  }

  void _syncBadge(int total) {
    if (total == _lastBadge) {
      return;
    }
    _lastBadge = total;
    if (total <= 0) {
      _resetBadge();
      return;
    }
    if (Platform.isMacOS) {
      // macOS：Dock 图标原生角标（红底白字数字，同 Telegram Mac 版）
      _invokeChannel('setDockBadge', total);
      return;
    }
    unawaited(_writeBadgeIco(total));
  }

  void _resetBadge() {
    if (Platform.isMacOS) {
      _invokeChannel('setDockBadge', 0);
      return;
    }
    if (!Platform.isWindows) {
      return;
    }
    try {
      unawaited(WindowsTaskbar.resetOverlayIcon());
    } catch (e) {
      debugPrint('[DesktopNotify] 清除任务栏角标失败: $e');
    }
  }

  void _invokeChannel(String method, dynamic arguments) {
    try {
      unawaited(_channel.invokeMethod<void>(method, arguments));
    } catch (e) {
      debugPrint('[DesktopNotify] $method 调用失败: $e');
    }
  }

  /// 生成红底白字数字角标 ICO，写入 exe 旁 data/flutter_assets 后设置覆盖图标。
  Future<void> _writeBadgeIco(int total) async {
    if (!Platform.isWindows || _badgeWriting) {
      return;
    }
    _badgeWriting = true;
    try {
      final String label = total > 99 ? '99+' : '$total';
      final Uint8List ico = await _renderBadgeIco(label);
      final String dir =
          '${File(Platform.resolvedExecutable).parent.path}\\data\\flutter_assets';
      final String file = '$dir\\$_badgeAssetName';
      await Directory(dir).create(recursive: true);
      await File(file).writeAsBytes(ico, flush: true);
      // 包要求图标位于 data/flutter_assets 且为 .ico，路径由其内部拼接
      final icon = ThumbnailToolbarAssetIcon(_badgeAssetName);
      await WindowsTaskbar.setOverlayIcon(icon, tooltip: '$total 条未读消息');
    } catch (e) {
      debugPrint('[DesktopNotify] 更新任务栏角标失败: $e');
    } finally {
      _badgeWriting = false;
    }
  }

  /// 画 16/24/32 三个尺寸的红圈白字角标，打包成多尺寸 ICO 字节。
  Future<Uint8List> _renderBadgeIco(String label) async {
    const List<int> sizes = <int>[16, 24, 32];
    final List<Uint8List> raws = <Uint8List>[];
    for (final int size in sizes) {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      final double r = size / 2.0;
      // 红底圆（Telegram 红）
      final Paint circle = Paint()..color = const Color(0xFFE43E3C);
      canvas.drawCircle(Offset(r, r), r, circle);
      // 白字
      final double fontSize =
          label.length >= 3 ? size * 0.34 : (label.length == 2 ? size * 0.44 : size * 0.55);
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: Colors.white,
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            height: 1.0,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(r - tp.width / 2, r - tp.height / 2));
      final ui.Picture picture = recorder.endRecording();
      final ui.Image image = await picture.toImage(size, size);
      final ByteData? data =
          await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) {
        continue;
      }
      raws.add(data.buffer.asUint8List());
    }
    if (raws.isEmpty) {
      throw StateError('角标渲染失败');
    }
    return _packIco(sizes, raws);
  }

  /// 组装 ICO：小尺寸用 32bpp BMP 条目（顶行在下），兼容 Win32 LoadImage。
  Uint8List _packIco(List<int> sizes, List<Uint8List> raws) {
    final List<Uint8List> entries = <Uint8List>[];
    for (int i = 0; i < raws.length; i++) {
      entries.add(_bmpEntry(sizes[i], raws[i]));
    }
    final int count = entries.length;
    final BytesBuilder out = BytesBuilder(copy: true);
    // ICONDIR 固定 6 字节：reserved(2) + type(2) + count(2)
    final ByteData header = ByteData(6);
    header.setUint16(0, 0, Endian.little); // reserved
    header.setUint16(2, 1, Endian.little); // ICO
    header.setUint16(4, count, Endian.little);
    out.add(header.buffer.asUint8List());
    int offset = 6 + 16 * count;
    final ByteData dir = ByteData(16);
    for (int i = 0; i < count; i++) {
      final int size = sizes[i];
      dir.setUint8(0, size >= 256 ? 0 : size); // width
      dir.setUint8(1, size >= 256 ? 0 : size); // height
      dir.setUint8(2, 0); // colors
      dir.setUint8(3, 0); // reserved
      dir.setUint16(4, 1, Endian.little); // planes
      dir.setUint16(6, 32, Endian.little); // bpp
      dir.setUint32(8, entries[i].length, Endian.little);
      dir.setUint32(12, offset, Endian.little);
      out.add(dir.buffer.asUint8List());
      offset += entries[i].length;
    }
    for (final Uint8List entry in entries) {
      out.add(entry);
    }
    return out.toBytes();
  }

  /// 单个 BMP 图标条目：BITMAPINFOHEADER + 32bpp BGRA（上下翻转）+ 全零 AND 掩码。
  Uint8List _bmpEntry(int size, Uint8List rgba) {
    final int xorBytes = size * size * 4;
    final int maskRowBytes = ((size + 31) ~/ 32) * 4;
    final int andBytes = maskRowBytes * size;
    final ByteData out = ByteData(40 + xorBytes + andBytes);
    // BITMAPINFOHEADER（biHeight = 2×高：XOR + AND 两张位图）
    out.setUint32(0, 40, Endian.little);
    out.setInt32(4, size, Endian.little);
    out.setInt32(8, size * 2, Endian.little);
    out.setUint16(12, 1, Endian.little);
    out.setUint16(14, 32, Endian.little);
    out.setUint32(16, 0, Endian.little); // BI_RGB
    out.setUint32(20, xorBytes + andBytes, Endian.little);
    // XOR：BGRA、自底向上
    for (int row = 0; row < size; row++) {
      final int srcRow = (size - 1 - row) * size * 4;
      final int dstRow = 40 + row * size * 4;
      for (int col = 0; col < size; col++) {
        final int src = srcRow + col * 4;
        final int dst = dstRow + col * 4;
        out.setUint8(dst, rgba[src + 2]); // B
        out.setUint8(dst + 1, rgba[src + 1]); // G
        out.setUint8(dst + 2, rgba[src]); // R
        out.setUint8(dst + 3, rgba[src + 3]); // A
      }
    }
    // AND 掩码全 0：透明度交给 Alpha 通道
    return out.buffer.asUint8List();
  }
}
