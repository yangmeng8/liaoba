import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;

import '../models/im_ws_frame.dart';
import '../pages/call/call_page.dart';
import '../services/api_client.dart';
import '../services/auth_manager.dart';
import '../services/im_websocket.dart';
import '../services/rtc_api.dart';
import '../shared/json_utils.dart';
import 'livekit_room.dart';

/// 通话阶段状态机（等价 H5 rtcStore.stage）。
enum RtcStage {
  /// 空闲。
  idle,

  /// 主叫：已发起，等待对方接听。
  inviting,

  /// 被叫：来电振铃，等待接听/拒绝。
  incoming,

  /// 通话进行中。
  running,
}

/// RTC 信令 contentType（对应后端 ImContentTypeEnum）。
class RtcSignalType {
  /// 通话信令（INVITING/REJECTED/NO_ANSWER；NONE 会话帧，仅推参与方）。
  static const int call = 1601;

  /// 参与者进房（LiveKit webhook participant_joined 触发；NONE 帧）。
  static const int participantConnected = 1602;

  /// 参与者离房（LiveKit webhook participant_left 触发；NONE 帧）。
  static const int participantDisconnected = 1603;

  /// 通话开始消息（入会话消息流；仅聊天记录展示用）。
  static const int callStart = 1610;

  /// 通话结束消息（入会话消息流：挂断/取消/拒接/超时统一走 endSession
  /// 落消息并推送——这是私聊通话结束的权威信号，1601 无 LEFT/REJECTED）。
  static const int callEnd = 1611;
}

/// 信令/参与者状态（对应后端 ImRtcParticipantStatusEnum）。
class RtcParticipantStatus {
  static const int inviting = 10;
  static const int joined = 20;
  static const int rejected = 30;
  static const int noAnswer = 40;
  static const int left = 50;
}

/// RTC 通话总控（等价 H5 rtcStore + useImRtc）：
/// - 三阶段状态机（INVITING 主叫 / INCOMING 被叫 / RUNNING）
/// - single-flight：防双击重复 create
/// - createCall 返回后二次校验（防期间来电插入的竞态）
/// - finishCall 幂等（收尾只跑一次，本地挂断 vs 远端结束区分）
/// - WebSocket 信令驱动被叫与状态流转。
class RtcController extends ChangeNotifier with WidgetsBindingObserver {
  RtcController._() {
    // 全局信令监听：RTC 帧到达即分发（登录后 WS 建立即可收来电）
    _wsSub = ImWebSocket.instance.notificationStream.listen(_onNotification);
    // 前后台监听：后台收到来电信令时发 fullScreenIntent 通知拉起
    WidgetsBinding.instance.addObserver(this);
    // iOS CallKit 事件桥（VoIP 推送来电/系统界面接听拒接）
    _callkitChannel.setMethodCallHandler(_onCallkitEvent);
    // LiveKit 远端断开 → 通话收尾（主动挂断时回调已被清空，不误触）
    liveKit.onDisconnected = () {
      if (_stage == RtcStage.running) {
        finishCall(localEnd: false, toast: '通话已结束');
      }
    };
    // LiveKit 对方进房 → 主叫 INVITING 接通（预连房间场景的本地事件，
    // 不依赖服务端 webhook；与 1602 信令双通道，先到先得）
    liveKit.onParticipantConnected = _onPeerConnected;
  }

  static final RtcController instance = RtcController._();

  StreamSubscription<ImWsNotification>? _wsSub;

  RtcStage _stage = RtcStage.idle;

  /// 当前通话数据（含 room/livekitUrl/token）。
  RtcCallData? call;

  /// 来电信息（INCOMING 阶段：通知里的 inviter 信息 + 本人 token）。
  RtcSignalPayload? incomingSignal;

  /// LiveKit 房间封装。
  final RtcLiveKitRoom liveKit = RtcLiveKitRoom();

  /// 主叫 INVITING 阶段的振铃超时轮询（60s，对齐 H5）。
  Timer? _noAnswerTimer;

  /// 通话计时起点（RUNNING 起算）。
  DateTime? _runningSince;

  /// single-flight：正在进行的 start 任务标识。
  int _startFlightId = 0;

  /// 收尾幂等标记。
  bool _finishing = false;

  /// App 是否在前台（后台收到来电信令时发 fullScreenIntent 全屏通知）。
  bool _isAppForeground = true;

  /// 通话结束原因文案（退出前展示）。
  String endToast = '';

  /// 全局导航 Key（main 注入；来电拉起通话页用）。
  GlobalKey<NavigatorState>? navigatorKey;

  RtcStage get stage => _stage;

  /// 是否处于通话中（inviting/incoming/running 任一阶段）。
  bool get isActive =>
      _stage == RtcStage.inviting ||
      _stage == RtcStage.incoming ||
      _stage == RtcStage.running;

  /// 是否视频通话。
  bool get isVideo {
    final media = call?.mediaType ??
        incomingSignal?.mediaType ??
        incomingSignal?.payloadMediaType ??
        0;
    return media == 2;
  }

  /// 已接通秒数（RUNNING 起算）。
  int get elapsedSeconds {
    final since = _runningSince;
    if (since == null) return 0;
    return DateTime.now().difference(since).inSeconds;
  }

  /// ==================== 发起（主叫） ====================

  /// 发起通话（对齐 H5 start）：
  /// single-flight 防双击；create 返回后校验期间没被来电插入；
  /// ENDED → 对方忙线提示。
  Future<void> start({
    required int conversationType,
    required int mediaType,
    int? groupId,
    required List<int> inviteeIds,
  }) async {
    if (isActive) return; // 已在通话中
    final flightId = ++_startFlightId;
    try {
      final data = await RtcApi.createCall(
        conversationType: conversationType,
        mediaType: mediaType,
        groupId: groupId,
        inviteeIds: inviteeIds,
      );
      // 竞态校验：期间被来电插入或已有通话 → 放弃本次结果
      if (flightId != _startFlightId || isActive) return;
      if (data.status == 30) {
        // ENDED：对方忙线，服务端直接终结
        _startFlightId++;
        _notifyToast('对方当前无法接听');
        return;
      }
      call = data;
      _stage = RtcStage.inviting;
      notifyListeners();
      _openCallPage();
      // 群通话创建即进房（成员陆续加入）
      if (conversationType == 2) {
        await _enterRunning(autoConnect: true);
      } else if (data.status == 20) {
        // 私聊对方已在线即刻接听（多端场景）
        await _enterRunning(autoConnect: true);
      } else {
        _startRingback(); // 私聊等待接听：回铃音（嘟—嘟—）
        // 私聊：INVITING 即预连 LiveKit 房间（对齐 H5 connectRoom 行为），
        // 对方接听进房时靠 LiveKit ParticipantConnected 本地事件感知接通
        // ——不依赖服务端 webhook；1602 信令到达时双保险重连
        await _preConnectRoom();
        _startNoAnswerPolling();
      }
    } catch (e) {
      if (flightId != _startFlightId) return;
      _startFlightId++;
      _notifyToast(ApiClient.errorMessage(e));
    }
  }

  /// 主叫 INVITING 预连房间（连上即开麦；失败不阻断等待流程，
  /// 后续 1602 信令到达时 _enterRunning 会重试连接）。
  Future<void> _preConnectRoom() async {
    final data = call;
    if (data == null || liveKit.connected) return;
    try {
      await liveKit.connect(
        url: data.livekitUrl,
        token: data.token,
        enableCamera: data.isVideo,
        myName: AuthManager.instance.nickname ?? '',
      );
    } catch (e) {
      debugPrint('[RTC] LiveKit 预连失败：$e');
    }
  }

  /// LiveKit 对方进房（预连场景接通感知，等价 H5 ParticipantConnected →
  /// syncParticipant(joined) → INVITING 时 enterRunning）：
  /// 房间必然已连接（预连成功才会有事件），仅切状态起计时。
  void _onPeerConnected(int userId) {
    final myUserId = AuthManager.instance.userId ?? 0;
    if (userId == myUserId || userId <= 0) return;
    if (_stage == RtcStage.inviting && call != null) {
      _enterRunning(autoConnect: false);
    }
  }

  /// ==================== 被叫（信令驱动） ====================

  /// WS 通知分发（对齐 H5 dispatchNoConversationFrame + handleRtcCallEnd）：
  /// - RTC_CALL_END(1611) 走会话消息流（私聊/群聊帧）：通话结束的权威信号
  /// - NONE 帧的 1601 信令 / 1602 / 1603 参与者进出房事件
  void _onNotification(ImWsNotification n) {
    if (n.contentType == RtcSignalType.callEnd) {
      _handleCallEndMessage(n.payload);
      return;
    }
    if (n.conversationType != 0) return;
    switch (n.contentType) {
      case RtcSignalType.call:
        _receiveSignal(RtcSignalPayload.fromPayload(n.payload));
        break;
      case RtcSignalType.participantConnected:
        _handleParticipantConnected(n.payload);
        break;
      case RtcSignalType.participantDisconnected:
        _handleParticipantDisconnected(n.payload);
        break;
    }
  }

  /// 参与者进房（LiveKit webhook participant_joined 触发，私聊推双方多端）：
  /// 主叫 INVITING 阶段收到对方进房 → 接通进 RUNNING。
  /// 注意：主叫 INVITING 时尚未连 LiveKit 房间，收不到 LiveKit 的
  /// participantConnected 事件——此信令是主叫感知「对方已接听」的唯一渠道。
  void _handleParticipantConnected(Map<String, dynamic> payload) {
    final myUserId = AuthManager.instance.userId ?? 0;
    final room = asString(payload['room']);
    final userId = asInt(payload['userId']);
    if (room.isEmpty || userId == myUserId || userId <= 0) return;
    if (_stage == RtcStage.inviting && call?.room == room) {
      _stopRingback(); // 对方接听：停回铃音
      _enterRunning(autoConnect: true);
    }
  }

  /// 参与者离房（LiveKit webhook participant_left 触发）：
  /// 私聊 RUNNING 时对方离房 → 通话结束（对方挂断后 endSession 的
  /// RTC_CALL_END 消息与本信令双保险，finishCall 幂等只生效一次）。
  /// 群聊不终结（其他成员可能仍在房）。
  void _handleParticipantDisconnected(Map<String, dynamic> payload) {
    final myUserId = AuthManager.instance.userId ?? 0;
    final room = asString(payload['room']);
    final userId = asInt(payload['userId']);
    if (room.isEmpty || userId == myUserId || userId <= 0) return;
    final conv = call?.conversationType ?? 0;
    if (conv == 1 && _stage == RtcStage.running && call?.room == room) {
      finishCall(localEnd: false, toast: '通话已结束');
    }
  }

  /// RTC_CALL_END(1611) 消息帧（入会话消息流；挂断/取消/拒接/超时统一走它）：
  /// content 为 ImRtcCallEndNotification 的 JSON 字符串，room 匹配当前
  /// 通话（主叫 call / 被叫 incomingSignal）即收尾。
  void _handleCallEndMessage(Map<String, dynamic> payload) {
    final raw = payload['content'];
    Map<String, dynamic> parsed = const {};
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) parsed = decoded;
      } catch (_) {
        // 非 JSON：忽略
      }
    } else if (raw is Map) {
      parsed = Map<String, dynamic>.from(raw);
    }
    final room = asString(parsed['room']);
    if (room.isEmpty) return;
    if (call?.room == room || incomingSignal?.room == room) {
      finishCall(localEnd: false, toast: '通话已结束');
    }
  }

  /// 推送点击路径的来电补入（好友不在 App 前台/被杀时 WS 信令丢失，
  /// 点击极光「来电通知」后由此补入信令直接弹来电页）。
  ///
  /// [raw] 为推送 extras 里后端约定的 RTC 信令字段（msgType=rtc_call）：
  /// room/mediaType/inviterUserId/inviterNickname/inviterAvatar/inviteeIds 等。
  /// 接听/拒绝走 HTTP API（RtcApi），不依赖 WS；主叫取消仍由 WS 消息兜底。
  void handleIncomingFromPush(Map<String, dynamic> raw) {
    final normalized = Map<String, dynamic>.from(raw);
    // 后端实际字段适配：roomId → room（extras 顶层两种命名都兼容）
    final dynamic roomValue =
        normalized['room'] ?? normalized['roomId'] ?? normalized['roomIdStr'];
    normalized['room'] = roomValue?.toString() ?? '';
    // 推送 extras 的值可能是字符串：inviteeIds 可能是 "[123]"，status 可能是 "0"
    final dynamic inviteeIds = normalized['inviteeIds'];
    if (inviteeIds is String && inviteeIds.isNotEmpty) {
      try {
        final decoded = jsonDecode(inviteeIds);
        if (decoded is List) normalized['inviteeIds'] = decoded;
      } catch (_) {
        // 非 JSON：忽略
      }
    }
    // 后端推送未带 inviteeIds（按 registration_id 定向发给被叫）：
    // 填充本人 id 通过 _receiveSignal 的被叫身份校验
    if (normalized['inviteeIds'] == null) {
      normalized['inviteeIds'] = <int>[AuthManager.instance.userId ?? 0];
    }
    // 昵称缺失：来电页兜底显示「对方」
    if ((normalized['inviterNickname'] ?? '').toString().trim().isEmpty) {
      normalized['inviterNickname'] = '对方';
    }
    // 推送 extras 不带 status：补 INVITING(10) 走来电分支
    if (int.tryParse('${normalized['status'] ?? ''}') == null) {
      normalized['status'] = RtcParticipantStatus.inviting;
    }
    final RtcSignalPayload signal;
    try {
      signal = RtcSignalPayload.fromPayload(normalized);
    } catch (e) {
      debugPrint('[RTC] 推送来电信令解析失败：$e（raw=$raw）');
      return;
    }
    if (signal.room.isEmpty) {
      debugPrint('[RTC] 推送来电缺少房间号，忽略');
      return;
    }
    debugPrint('[RTC] 推送来电补入: room=${signal.room}, '
        'inviter=${signal.inviterNickname}(${signal.inviterUserId}), '
        'mediaType=${signal.mediaType}');
    _receiveSignal(signal);
  }

  /// 信令处理（对齐 H5 receiveSignal；后端 1601 仅推 INVITING/REJECTED/NO_ANSWER：
  /// 私聊拒绝/超时不走此信令，由 RTC_CALL_END 消息兜底；接通感知靠 1602）。
  void _receiveSignal(RtcSignalPayload signal) {
    final myUserId = AuthManager.instance.userId ?? 0;
    final isEcho = signal.inviterUserId == myUserId; // 自己发起的回声
    switch (signal.status) {
      case RtcParticipantStatus.inviting:
        // 来电：本人是被叫且未在通话中
        if (isEcho || !signal.inviteeIds.contains(myUserId)) return;
        if (isActive) {
          // 正在通话 → 自动回拒帮主叫挂断
          if (signal.room.isNotEmpty) {
            RtcApi.rejectCall(room: signal.room).catchError((Object _) {});
          }
          return;
        }
        incomingSignal = signal;
        _stage = RtcStage.incoming;
        _startRingtone(); // 被叫：来电页弹出即振铃（前台无通知声，App 内补）
        notifyListeners();
        _openCallPage();
        break;
      case RtcParticipantStatus.rejected:
      case RtcParticipantStatus.noAnswer:
        // 仅群通话场景推送（成员拒接/超时）：主叫侧移除该成员即可，
        // 群通话不因此终结（其他成员可能陆续加入）
        break;
      default:
        break;
    }
  }

  /// 接听（被叫 INCOMING → RUNNING）。
  Future<void> accept() async {
    final signal = incomingSignal;
    if (signal == null || _stage != RtcStage.incoming) return;
    try {
      final data = await RtcApi.acceptCall(room: signal.room);
      call = data;
      await _enterRunning(autoConnect: true);
    } catch (e) {
      _notifyToast(ApiClient.errorMessage(e));
      finishCall(localEnd: true);
    }
  }

  /// 进入 RUNNING：连接 LiveKit 房间 + 起计时。
  Future<void> _enterRunning({required bool autoConnect}) async {
    final data = call;
    if (data == null) return;
    _stopRingback(); // 接通：停主叫回铃音
    _stopRingtone(); // 接通：停被叫振铃音
    _noAnswerTimer?.cancel();
    _noAnswerTimer = null;
    // 幂等：LiveKit 事件与 1602 信令双通道可能都触发，只在首次切换起计时
    if (_stage != RtcStage.running) {
      _stage = RtcStage.running;
      _runningSince = DateTime.now();
      notifyListeners();
    }
    if (autoConnect && !liveKit.connected) {
      try {
        await liveKit.connect(
          url: data.livekitUrl,
          token: data.token,
          enableCamera: data.isVideo,
          myName: AuthManager.instance.nickname ?? '',
        );
      } catch (e) {
        debugPrint('[RTC] LiveKit 连接失败：$e');
        _notifyToast('媒体连接失败');
        finishCall(localEnd: true);
        return;
      }
      notifyListeners();
    }
  }

  /// ==================== 挂断（按阶段分流，对齐 H5 hangup） ====================

  /// 挂断/取消/拒绝统一入口。
  Future<void> hangup() async {
    final room = call?.room ?? incomingSignal?.room;
    switch (_stage) {
      case RtcStage.inviting:
        if (room != null) {
          await RtcApi.cancelCall(room: room).catchError((Object _) {});
        }
        finishCall(localEnd: true);
        break;
      case RtcStage.incoming:
        if (room != null) {
          await RtcApi.rejectCall(room: room).catchError((Object _) {});
        }
        finishCall(localEnd: true);
        break;
      case RtcStage.running:
        if (room != null) {
          await RtcApi.leaveCall(room: room).catchError((Object _) {});
        }
        finishCall(localEnd: true);
        break;
      case RtcStage.idle:
        break;
    }
  }

  /// 收尾（幂等；对齐 H5 finishCall + localEndContext 防回声二次收尾）。
  Future<void> finishCall({bool localEnd = false, String? toast}) async {
    if (_finishing) return;
    _finishing = true;
    _noAnswerTimer?.cancel();
    _noAnswerTimer = null;
    // 清掉 Android 来电全屏通知（拒接/取消/对方挂断时）
    _cancelFullScreenIncomingCall();
    _stopRingback(); // 结束通话：停回铃音（幂等）
    _stopRingtone(); // 结束通话：停振铃音（拒接/超时/取消，幂等）
    // iOS：同步结束 CallKit 系统来电界面（对方挂断/超时/取消）
    if (Platform.isIOS) {
      unawaited(_callkitChannel.invokeMethod('endCall').catchError((Object _) {}));
    }
    if (toast != null && toast.isNotEmpty) {
      endToast = toast;
    } else if (localEnd) {
      endToast = '';
    }
    await liveKit.disconnect();
    _stage = RtcStage.idle;
    call = null;
    incomingSignal = null;
    _runningSince = null;
    notifyListeners();
    _finishing = false;
  }

  /// ==================== 内部工具 ====================

  /// 主叫振铃超时轮询（60s 一次，服务端扫描后经信令回 NO_ANSWER）。
  void _startNoAnswerPolling() {
    _noAnswerTimer?.cancel();
    _noAnswerTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      final room = call?.room;
      if (room == null || _stage != RtcStage.inviting) return;
      RtcApi.noAnswerCallCheck(room: room).catchError((Object _) {});
    });
  }

  /// 通话页路由名（防重复 push 检测用）。
  static const String callPageRouteName = '/rtc-call';

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppForeground = state == AppLifecycleState.resumed;
  }

  /// Android fullScreenIntent 来电全屏通知 channel（MainActivity 实现）。
  static const MethodChannel _incomingCallChannel =
      MethodChannel('im/incoming_call');

  /// iOS CallKit 事件桥（AppDelegate 实现）。
  static const MethodChannel _callkitChannel = MethodChannel('im/callkit');

  /// 回铃音：主叫等待接听时播放（iOS 走 callkit channel / Android 走 incoming_call channel）
  void _startRingback() {
    if (Platform.isIOS) {
      unawaited(
          _callkitChannel.invokeMethod('startRingback').catchError((_) {}));
    } else if (Platform.isAndroid) {
      unawaited(
          _incomingCallChannel.invokeMethod('startRingback').catchError((_) {}));
    }
  }

  void _stopRingback() {
    if (Platform.isIOS) {
      unawaited(
          _callkitChannel.invokeMethod('stopRingback').catchError((_) {}));
    } else if (Platform.isAndroid) {
      unawaited(
          _incomingCallChannel.invokeMethod('stopRingback').catchError((_) {}));
    }
  }

  /// 振铃音：被叫来电页弹出时循环播放（App 在前台时 WS 直接弹页无通知声）。
  void _startRingtone() {
    if (Platform.isIOS) {
      unawaited(
          _callkitChannel.invokeMethod('startRingtone').catchError((_) {}));
    } else if (Platform.isAndroid) {
      unawaited(
          _incomingCallChannel.invokeMethod('startRingtone').catchError((_) {}));
    }
  }

  void _stopRingtone() {
    if (Platform.isIOS) {
      unawaited(
          _callkitChannel.invokeMethod('stopRingtone').catchError((_) {}));
    } else if (Platform.isAndroid) {
      unawaited(
          _incomingCallChannel.invokeMethod('stopRingtone').catchError((_) {}));
    }
  }

  /// 上报 iOS VoIP Token 给后端（同 token 只报一次；接口未上线时静默容错）。
  static const String _voipTokenReportPath =
      '/app-api/member/user/updateVoipToken';
  static String? _lastReportedVoipToken;

  Future<void> _reportVoipToken(String token) async {
    if (token == _lastReportedVoipToken) return; // 同 token 不重复上报
    _lastReportedVoipToken = token;
    debugPrint('[RTC] iOS VoIP Token(${token.length}字符): $token');
    try {
      final resp = await ApiClient.dio.put<Object>(
        '$_voipTokenReportPath?voipToken=$token',
      );
      debugPrint('[RTC] VoIP Token 上报返回: ${resp.data}');
    } catch (e) {
      // 接口未上线（404 等）不重试不刷屏；后端就绪后下次启动会重新上报
      debugPrint('[RTC] VoIP Token 上报失败（接口待后端上线）: $e');
    }
  }

  /// iOS CallKit 事件：VoIP token / 来电 / 系统界面接听 / 拒接。
  Future<dynamic> _onCallkitEvent(MethodCall call) async {
    if (call.method != 'onCallkitEvent') return null;
    final args = Map<String, dynamic>.from(call.arguments as Map? ?? {});
    final event = args['event'] as String? ?? '';
    final payload =
        Map<String, dynamic>.from(args['payload'] as Map? ?? <String, dynamic>{});
    switch (event) {
      case 'voipToken':
        // VoIP deviceToken 上报后端（后端用 VoIP 证书直连 APNs 发起来电推送；
        // 接口路径待后端确认，404/未实现时静默容错）
        final token = args['token'] as String? ?? '';
        if (token.isNotEmpty) {
          unawaited(_reportVoipToken(token));
        }
        break;
      case 'incoming':
        // VoIP 推送到达：系统 CallKit 界面已弹，同步补入 App 内来电页
        handleIncomingFromPush(payload);
        break;
      case 'answer':
        // 用户在系统来电界面点「接听」（App 已被带回前台）
        if (_stage == RtcStage.incoming) {
          await accept();
        } else {
          // 冷启动竞态：来电页尚未建立 → 先补入再接听
          handleIncomingFromPush(payload);
          if (_stage == RtcStage.incoming) await accept();
        }
        break;
      case 'reject':
        // 用户在系统来电界面点「拒接」
        if (_stage == RtcStage.incoming) {
          await hangup();
        }
        break;
    }
    return null;
  }

  /// 后台收到来电信令：发 fullScreenIntent 通知（锁屏直接全屏弹来电界面）。
  /// extras 与后端极光推送约定同构（messageType=call_invite），
  /// 全屏拉起后走 push_open 冷启动消费链路识别进来电页。
  void _showFullScreenIncomingCall() {
    final signal = incomingSignal;
    if (signal == null) return;
    final callType = signal.mediaType == 2 ? '视频' : '语音';
    unawaited(
      _incomingCallChannel.invokeMethod<void>('showIncomingCall', <String, dynamic>{
        'title': 'IM',
        'content': '$signal.inviterNickname 邀请你$callType通话',
        'extrasJson': jsonEncode(<String, dynamic>{
          'messageType': 'call_invite',
          'roomId': signal.room,
          'conversationType': signal.conversationType,
          'mediaType': signal.mediaType,
          'inviterUserId': signal.inviterUserId,
          'inviterNickname': signal.inviterNickname,
          'inviterAvatar': signal.inviterAvatar,
          'needNotify': true,
          '_j_msgid': 'call_${signal.room}',
        }),
      }).catchError((Object e) {
        debugPrint('[RTC] 发送来电全屏通知失败: $e');
      }),
    );
  }

  /// 清掉来电全屏通知（通话结束/拒接/取消时）。
  void _cancelFullScreenIncomingCall() {
    if (Platform.isIOS) return;
    unawaited(
      _incomingCallChannel.invokeMethod<void>('cancelIncomingCall')
          .catchError((Object _) {}),
    );
  }

  void _openCallPage() {
    final key = navigatorKey;
    if (key == null) return;
    final nav = key.currentState;
    if (nav == null) return;
    // App 在后台（WS 还存活的时间窗内收到来电信令）：
    // Android 发 fullScreenIntent 通知——锁屏直接全屏弹来电界面，
    // 亮屏显示 heads-up；点击/全屏拉起后复用 push_open 链路进来电页
    if (!_isAppForeground && !Platform.isIOS) {
      _showFullScreenIncomingCall();
    }
    // 已有通话页在栈中则不重复 push（重建由 ListenableBuilder 响应）
    var exists = false;
    nav.popUntil((route) {
      if (route.settings.name == callPageRouteName) exists = true;
      return true; // 恒 true：仅遍历检测，不真正 pop
    });
    if (exists) return;
    nav.push(
      PageRouteBuilder(
        opaque: false,
        transitionDuration: Duration.zero,
        settings: const RouteSettings(name: callPageRouteName),
        pageBuilder: (_, __, ___) => const RtcCallPage(),
      ),
    );
  }

  /// 轻提示（通过 ScaffoldMessenger 弹出，页面未挂载时静默）。
  void _notifyToast(String msg) {
    final nav = navigatorKey?.currentState;
    if (nav == null) return;
    final ctx = nav.context;
    ScaffoldMessenger.maybeOf(ctx)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _noAnswerTimer?.cancel();
    super.dispose();
  }
}

/// RTC_CALL 信令 payload（对应后端 ImRtcCallNotification）。
class RtcSignalPayload {
  /// 参与者状态（INVITING/JOINED/REJECTED/NO_ANSWER/LEFT）。
  final int status;

  final String room;
  final int conversationType;

  /// 媒体类型（1=语音 2=视频；部分信令缺省时回退 payload 外层）。
  final int mediaType;
  final int groupId;
  final String livekitUrl;
  final String token;
  final int inviterUserId;
  final String inviterNickname;
  final String inviterAvatar;
  final List<int> inviteeIds;
  final int operatorUserId;
  final String operatorNickname;

  const RtcSignalPayload({
    required this.status,
    required this.room,
    required this.conversationType,
    required this.mediaType,
    required this.groupId,
    required this.livekitUrl,
    required this.token,
    required this.inviterUserId,
    required this.inviterNickname,
    required this.inviterAvatar,
    required this.inviteeIds,
    required this.operatorUserId,
    required this.operatorNickname,
  });

  factory RtcSignalPayload.fromPayload(Map<String, dynamic> json) =>
      RtcSignalPayload(
        status: asInt(json['status']),
        room: asString(json['room']),
        conversationType: asInt(json['conversationType']),
        mediaType: asInt(json['mediaType']),
        groupId: asInt(json['groupId']),
        livekitUrl: asString(json['livekitUrl']),
        token: asString(json['token']),
        inviterUserId: asInt(json['inviterUserId']),
        inviterNickname: asString(json['inviterNickname']),
        inviterAvatar: asString(json['inviterAvatar']),
        inviteeIds: (json['inviteeIds'] is List)
            ? (json['inviteeIds'] as List)
                .map((e) => asInt(e))
                .where((e) => e > 0)
                .toList()
            : const [],
        operatorUserId: asInt(json['operatorUserId']),
        operatorNickname: asString(json['operatorNickname']),
      );

  /// 兼容字段（旧结构 payload.mediaType 缺省时）。
  int? get payloadMediaType => null;
}
