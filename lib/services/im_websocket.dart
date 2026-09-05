import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/im_ws_frame.dart';
import 'api_client.dart';
import 'auth_manager.dart';

/// WebSocket 连接状态。
enum ImWsState { disconnected, connecting, connected }

/// IM WebSocket 长连接服务（对应 H5 websocketStore.ts）。
///
/// 设计要点：
/// - 单例跨页面复用一条连接（ensure 幂等启动）；
/// - 心跳：每 30s 发送文本 "ping" 穿透代理；
/// - 重连：指数退避 + 随机抖动（防重连风暴），封顶 30s，成功后清零；
/// - owner 隔离：epoch 代际计数，新连接建立后旧连接的迟到回调被丢弃；
/// - 帧串行：消息按到达顺序依次处理，防乱序；
/// - 断线补偿：断线重连成功后广播 resync 事件，由会话 Store 全量补拉，
///   「推送保实时、拉取保最终一致」。
class ImWebSocket {
  ImWebSocket._();

  static final ImWebSocket instance = ImWebSocket._();

  // ===== 配置（对齐 H5 常量） =====
  static const Duration _heartbeatInterval = Duration(seconds: 30);
  static const int _reconnectBaseMs = 1000;
  static const int _reconnectMaxMs = 30000;
  static const int _reconnectJitterMs = 3000;

  WebSocketChannel? _channel;
  StreamSubscription? _socketSub;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;

  /// 重连退避次数（成功后清零）。
  int _reconnectAttempts = 0;

  /// 手动断开标记（退出登录置位，阻止自动重连）。
  bool _manualClosed = false;

  /// 断线补偿标记：连接曾成功建立过，关闭后重连成功需全量补拉。
  bool _resyncOnReopen = false;

  /// 连接代际（owner 隔离）：每次连接尝试自增，
  /// 旧连接的迟到回调（onOpen/onMessage/onClose）通过闭包比对丢弃。
  int _epoch = 0;

  ImWsState _state = ImWsState.disconnected;

  final _stateCtrl = StreamController<ImWsState>.broadcast();
  final _notificationCtrl = StreamController<ImWsNotification>.broadcast();
  final _resyncCtrl = StreamController<void>.broadcast();

  /// 帧串行处理队列尾（保证到达顺序）。
  Future<void> _frameTail = Future.value();

  ImWsState get state => _state;

  /// 连接状态流（UI 可监听显示在线状态等）。
  Stream<ImWsState> get stateStream => _stateCtrl.stream;

  /// 通知流：所有解析成功的帧（消息/已读/回执/撤回/关系事件），
  /// 消费方按 conversationType/contentType 自行过滤。
  Stream<ImWsNotification> get notificationStream =>
      _notificationCtrl.stream;

  /// 断线补偿流：重连成功后触发一次，消费方应全量补拉数据。
  Stream<void> get resyncStream => _resyncCtrl.stream;

  /// 构建 WS 地址：http(s) → ws(s)，token 走 URL query。
  /// 双 token 时用 refreshToken（存活期长，对齐 H5），否则 accessToken。
  String _buildWsUrl() {
    final wsBase = ApiClient.baseUrl.replaceFirst(RegExp('^http'), 'ws');
    final auth = AuthManager.instance;
    final token = (auth.refreshToken?.isNotEmpty ?? false)
        ? auth.refreshToken
        : auth.accessToken;
    return '$wsBase/infra/ws?token=${Uri.encodeComponent(token ?? '')}';
  }

  /// 幂等启动连接（已连接/连接中直接返回）。
  /// 退出登录后可再次调用重新连接。
  Future<void> ensure() async {
    if (_state == ImWsState.connected || _state == ImWsState.connecting) return;
    _manualClosed = false;
    await _connect();
  }

  /// 手动断开（退出登录）：置 manualClosed 阻止自动重连。
  void disconnect() {
    debugPrint('[WS] 手动断开（退出登录），阻止自动重连');
    _manualClosed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _epoch++; // 使所有在途回调失效
    _socketSub?.cancel();
    _socketSub = null;
    _channel?.sink.close().catchError((Object _) {});
    _channel = null;
    _setState(ImWsState.disconnected);
  }

  Future<void> _connect() async {
    final epoch = ++_epoch;
    final url = _buildWsUrl();
    _setState(ImWsState.connecting);
    debugPrint('[WS] 开始连接 #$epoch：$url');
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      await channel.ready;
      // owner 隔离：等待期间连接已被替换/断开 → 丢弃本次
      if (_epoch != epoch) {
        debugPrint('[WS] 连接#$epoch 已被替换，丢弃（owner 隔离）');
        await channel.sink.close().catchError((Object _) {});
        return;
      }
      _channel = channel;
      _reconnectAttempts = 0;
      _startHeartbeat();
      _setState(ImWsState.connected);
      debugPrint('[WS] 连接成功 #$epoch');
      // 断线补偿：之前断开过 → 重连成功，广播全量补拉
      if (_resyncOnReopen) {
        _resyncOnReopen = false;
        debugPrint('[WS] 断线重连成功，触发全量补拉');
        _resyncCtrl.add(null);
      }
      _socketSub = channel.stream.listen(
        (data) => _onFrameArrived(epoch, data),
        onDone: () => _onClosed(epoch),
        onError: (Object e) {
          debugPrint('[WS] 流错误 #$epoch：$e');
          _onClosed(epoch);
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (_epoch != epoch) return;
      debugPrint('[WS] 连接失败 #$epoch：$e');
      _scheduleReconnect();
    }
  }

  /// 启动心跳：每 30s 发送文本 "ping"（发送失败由 onClose 兜底重连）。
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(_heartbeatInterval, (_) {
      final channel = _channel;
      if (channel == null || _state != ImWsState.connected) return;
      debugPrint('[WS] 心跳 ping');
      try {
        channel.sink.add('ping');
      } catch (e) {
        debugPrint('[WS] 心跳发送异常：$e');
        // 发送异常：交给 onClose 触发重连
      }
    });
  }

  /// 连接关闭（服务端断开/网络异常）：非手动关闭则指数退避重连。
  void _onClosed(int epoch) {
    if (_epoch != epoch) {
      debugPrint('[WS] 丢弃旧连接#$epoch 的迟到关闭回调（owner 隔离）');
      return;
    }
    debugPrint('[WS] 连接断开 #$epoch'
        '${_manualClosed ? '（手动关闭，不重连）' : ''}');
    if (_state == ImWsState.connected) {
      // 曾成功建立过 → 重连后需要断线补偿
      _resyncOnReopen = true;
    }
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _socketSub?.cancel();
    _socketSub = null;
    _channel = null;
    if (_manualClosed) {
      _setState(ImWsState.disconnected);
      return;
    }
    _scheduleReconnect();
  }

  /// 指数退避重连：delay = min(基数 × 2^次数, 30s) + 随机抖动。
  void _scheduleReconnect() {
    final backoffMs = min(
      _reconnectBaseMs * (1 << min(_reconnectAttempts, 10)),
      _reconnectMaxMs,
    );
    final jitterMs = Random().nextInt(_reconnectJitterMs);
    _reconnectAttempts++;
    _setState(ImWsState.disconnected);
    debugPrint(
        '[WS] ${Duration(milliseconds: backoffMs + jitterMs).inSeconds}s 后重连（第 $_reconnectAttempts 次）');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      Duration(milliseconds: backoffMs + jitterMs),
      _connect,
    );
  }

  /// 帧到达：入串行队列，按到达顺序依次处理（防乱序）。
  void _onFrameArrived(int epoch, Object data) {
    if (_epoch != epoch) return;
    _frameTail = _frameTail.then((_) {
      if (_epoch != epoch) return;
      _handleFrame(data is String ? data : data.toString());
    });
  }

  /// 解析并分发单帧：心跳文本直接吞掉，业务帧解析后广播。
  void _handleFrame(String raw) {
    final frame = ImWsFrame.tryParse(raw);
    if (frame == null) {
      debugPrint('[WS] 收到非 JSON 帧（心跳应答等）：${raw.length > 50 ? '${raw.substring(0, 50)}...' : raw}');
      return;
    }
    final notification = frame.notification;
    if (notification == null) {
      debugPrint('[WS] 帧缺少 notification 结构，type=${frame.type}');
      return;
    }
    debugPrint('[WS] 收到通知：'
        'conversationType=${notification.conversationType} '
        'contentType=${notification.contentType}');
    _notificationCtrl.add(notification);
  }

  void _setState(ImWsState s) {
    if (_state == s) return;
    _state = s;
    _stateCtrl.add(s);
  }
}
