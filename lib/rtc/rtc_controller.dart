import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:dio/dio.dart' show Options;

import '../models/im_ws_frame.dart';
import '../pages/call/call_page.dart';
import '../services/api_client.dart';
import '../services/auth_manager.dart';
import '../services/im_websocket.dart';
import '../services/rtc_api.dart';
import '../stores/conversation_store.dart';
import '../shared/diag_log.dart';
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
    // 冷启动（点接听/推送拉起）时进程可能还在后台：按真实生命周期状态初始化，
    // 否则会被当成前台直接连媒体，后台状态下摄像头/麦克风不可用 → 连接失败收尾
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null) {
      _isAppForeground = lifecycle == AppLifecycleState.resumed;
    }
    // 全局信令监听：RTC 帧到达即分发（登录后 WS 建立即可收来电）
    _wsSub = ImWebSocket.instance.notificationStream.listen(_onNotification);
    // 前后台监听：后台收到来电信令时发 fullScreenIntent 通知拉起
    WidgetsBinding.instance.addObserver(this);
    // iOS CallKit 事件桥（VoIP 推送来电/系统界面接听拒接）
    _callkitChannel.setMethodCallHandler(_onCallkitEvent);
    // 原生 PushKit 回调可能早于上面的 handler 注册（启动竞态），补一次主动拉取
    if (Platform.isIOS) {
      unawaited(_pullVoipTokenOnStart());
      // 冷启动点「接听」：事件早于 handler 注册，主动取原生缓存补处理
      unawaited(_consumePendingCallkitEvents());
    }
    // LiveKit 远端断开 → 通话收尾（主动挂断时回调已被清空，不误触）
    liveKit.onDisconnected = () {
      if (_stage == RtcStage.running) {
        DiagLog.log('[RTC] LiveKit 连接断开（本地感知）→ 收尾');
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

  /// 通话页是否已在导航栈上。
  /// push 返回的 Future 在页面退出时完成，据此复位——比遍历路由可靠，
  /// 也能让「通话中持续兜底」不会重复 push 出多张来电页。
  bool _callPageOpen = false;

  /// 通话页兜底定时器：冷启动（锁屏接听/杀进程后接听）时导航器可能迟迟没挂载，
  /// 一次性重试预算用光后页面就再也不会弹——表现就是「跳进 App 却没有通话页」。
  /// 改成只要通话还活着就每 300ms 兜底确认一次，直到页面真的 push 出去。
  Timer? _callPageGuard;

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
        // 兜底轮询：锁屏 CallKit 接听场景 1602 信令可能丢失，轮询感知接通
        _pollAnswerTimer?.cancel();
        _pollAnswerTimer = Timer.periodic(
            const Duration(seconds: 3), (_) => unawaited(_pollAnswerStatus()));
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
    // 预连只试一次，失败不阻断：真正接通时的 _enterRunning 会带重试再连
    await _connectMedia(data, attempts: 1);
  }

  /// 连接 LiveKit 媒体：先等 App 回到前台，再带重试地连接。
  ///
  /// 锁屏滑动接听、App 被杀后点接听这两条路径，Dart 拿到「接听」事件时
  /// 进程通常还在后台（系统刚把它拉起来），此时摄像头/麦克风与音频会话
  /// 都不可用，直接连必然失败；旧代码把这次失败当作「媒体连接失败」立即
  /// 收尾（服务端 leave + 通话页因 idle 自动 pop），用户看到的就是
  /// 「跳进 App 了，但没有通话页进行通话」。
  /// 返回 null 表示连接成功；失败返回最后一次的异常摘要（真机拿不到日志时，
  /// 这段摘要会显示在 toast 上，方便定位是 token/网络/权限哪一类问题）。
  Future<String?> _connectMedia(RtcCallData data, {int attempts = 3}) async {
    String? lastError;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      await _waitUntilForeground();
      try {
        await liveKit.connect(
          url: data.livekitUrl,
          token: data.token,
          enableCamera: data.isVideo,
          myName: AuthManager.instance.nickname ?? '',
        );
        if (attempt > 1) {
          DiagLog.log('[RTC] LiveKit 第 $attempt 次连接成功');
        }
        return null;
      } catch (e) {
        lastError = _briefError(e);
        DiagLog.log(
            '[RTC] LiveKit 连接失败(第 $attempt/$attempts 次)：$e（url=${data.livekitUrl}）');
        if (attempt < attempts) {
          await Future<void>.delayed(Duration(milliseconds: 500 * attempt));
        }
      }
    }
    return lastError ?? '未知错误';
  }

  /// 异常首行摘要（截断，避免 toast 过长）。
  String _briefError(Object e) {
    final text = e.toString().replaceAll('\n', ' ').trim();
    return text.length > 80 ? '${text.substring(0, 80)}…' : text;
  }

  /// 等 App 回到前台（最多 5 秒）：后台状态下媒体设备不可用。
  Future<void> _waitUntilForeground() async {
    if (_isAppForeground) return;
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!_isAppForeground && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
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
      DiagLog.log('[RTC] 收到 1603 对方离房信令 → 收尾: room=$room, userId=$userId');
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
      DiagLog.log('[RTC] 收到 1611 通话结束消息 → 收尾: room=$room');
      finishCall(localEnd: false, toast: '通话已结束');
    }
  }

  /// 推送点击路径的来电补入（好友不在 App 前台/被杀时 WS 信令丢失，
  /// 点击极光「来电通知」后由此补入信令直接弹来电页）。
  ///
  /// [raw] 为推送 extras 里后端约定的 RTC 信令字段（msgType=rtc_call）：
  /// room/mediaType/inviterUserId/inviterNickname/inviterAvatar/inviteeIds 等。
  /// 接听/拒绝走 HTTP API（RtcApi），不依赖 WS；主叫取消仍由 WS 消息兜底。
  /// 返回是否已经把来电信令落进状态机（true = 现在可以走接听/来电页）。
  bool handleIncomingFromPush(Map<String, dynamic> raw) {
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
    // 被叫身份校验用：推送是按本机 deviceToken 定向发的，本人必然在受邀名单里。
    // payload 没带 inviteeIds 时补本人 id；带了但名单里没有本人（字段语义差异/
    // 只带其他成员）时也补进来，否则 _receiveSignal 会静默丢弃这条来电。
    final myUserId = AuthManager.instance.userId ?? 0;
    final effectiveInviteeIds = <int>[];
    final rawInvitees = normalized['inviteeIds'];
    if (rawInvitees is List) {
      effectiveInviteeIds.addAll(rawInvitees.map((e) => asInt(e)).where((e) => e > 0));
    }
    if (myUserId > 0 && !effectiveInviteeIds.contains(myUserId)) {
      effectiveInviteeIds.add(myUserId);
    }
    normalized['inviteeIds'] = effectiveInviteeIds;
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
      DiagLog.log('[RTC] 推送来电信令解析失败：$e（raw=$raw）');
      return false;
    }
    if (signal.room.isEmpty) {
      DiagLog.log('[RTC] 推送来电缺少房间号，忽略');
      return false;
    }
    DiagLog.log('[RTC] 推送来电补入: room=${signal.room}, '
        'inviter=${signal.inviterNickname}(${signal.inviterUserId}), '
        'mediaType=${signal.mediaType}');
    if (myUserId > 0 && signal.inviterUserId == myUserId) {
      // 「inviterUserId == 本人」只有两种来源，日志里直接区分开：
      //   1) 本账号在别的端拨打（同号多端），推送同样会发到本机 → 属多端回声；
      //   2) 后端把 inviterUserId 误填成被叫本人 id（历史 bug）→ 正常来电会被
      //      回声判断丢掉（表现：点接听跳进 App 却没有通话页）。
      // 判据：本端此刻是否有同房间的呼叫。
      final sameRoomHere = call?.room == signal.room;
      DiagLog.log('[RTC] ⚠️ 推送来电的 inviterUserId 与本人 id 相同'
          '（${sameRoomHere ? '本端已有同房间通话 → 多端回声' : '本端无同房间通话 → 疑后端字段有误'}）: '
          'room=${signal.room}, inviterNickname=${signal.inviterNickname}');
    }
    _receiveSignal(signal, fromPush: true);
    if (!isActive) {
      // 静默失败排查用：身份校验不过 / 已在通话中 / 被去重，都会走到这里
      DiagLog.log('[RTC] 推送来电未能进入来电页（myUserId=$myUserId，'
          'inviteeIds=${signal.inviteeIds}，inviterUserId=${signal.inviterUserId}，'
          'room=${signal.room}，stage=$_stage）');
    }
    return isActive;
  }

  /// 信令处理（对齐 H5 receiveSignal；后端 1601 仅推 INVITING/REJECTED/NO_ANSWER：
  /// 私聊拒绝/超时不走此信令，由 RTC_CALL_END 消息兜底；接通感知靠 1602）。
  /// [fromPush]：信令来自推送补入（按本机 deviceToken 定向下发）。
  /// 推送链路上「本人是否在 inviteeIds 名单里」无需校验——payload 字段语义/命名
  /// 与 WS 信令可能不一致，硬校验会把正常来电静默丢掉（点了接听没反应）。
  void _receiveSignal(RtcSignalPayload signal, {bool fromPush = false}) {
    final myUserId = AuthManager.instance.userId ?? 0;
    // 「自己发起的回声」判定：inviterUserId 就是本人 → 这通电话是本人在别的端发起的
    // （WS 的 1601 会广播给所有参与方，包括主叫自己；同一账号多端登录时推送也会发到
    // 本人其他设备），不该在本端再弹一次来电页。
    //
    // 注意：这个判断依赖后端把 inviterUserId 填成「来电方 id」。历史上后端在 VoIP/
    // 通知推送里误填成被叫自己的 id，导致正常来电被静默丢掉（表现：锁屏/杀进程后点
    // 接听跳进 App 却没有通话页，日志里是「来电信令被判定为自家回声，忽略」）。
    // 后端已修正，这里恢复严格判断；一旦再出现误判，下面这行日志会直接暴露。
    final isEcho = myUserId > 0 && signal.inviterUserId == myUserId;
    switch (signal.status) {
      case RtcParticipantStatus.inviting:
        // 来电：本人是被叫且未在通话中
        if (isEcho) {
          DiagLog.log('[RTC] 来电信令被判定为自家回声，忽略（${fromPush ? '推送' : 'WS'}）: '
              'inviterUserId=${signal.inviterUserId}, myUserId=$myUserId');
          return;
        }
        if (!fromPush && !signal.inviteeIds.contains(myUserId)) {
          DiagLog.log('[RTC] 来电信令的受邀人不是本人，忽略: myUserId=$myUserId, '
              'inviteeIds=${signal.inviteeIds}');
          return;
        }
        // 同一通电话重复到达（WS 信令 + VoIP 推送补入 双通道）：
        // 必须幂等忽略，否则会被当成「已在通话中」自动回拒，把正常来电挂断
        if (signal.room.isNotEmpty &&
            (signal.room == incomingSignal?.room || signal.room == call?.room)) {
          DiagLog.log('[RTC] 重复来电信令已忽略: room=${signal.room}');
          return;
        }
        if (isActive) {
          // 正在通话 → 自动回拒帮主叫挂断
          DiagLog.log('[RTC] 已在通话中（stage=$_stage），自动回拒来电 room=${signal.room}');
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
  ///
  /// [attempts]：接听接口失败时的重试次数。锁屏/杀进程后点「接听」这条路径上，
  /// App 刚从后台冷启动，网络与登录态可能还没热起来，第一次请求容易直接失败；
  /// 旧行为是立刻 toast + hangup（服务端会话被释放）→ 用户看到「跳进 App 没反应」。
  Future<void> accept({int attempts = 1}) async {
    // 接听单飞：冷启动/回前台/事件桥/原生存档几条路径会同时触发接听，
    // 重复请求会被服务端拒绝，失败分支再 hangup 就把刚接通的会话又释放掉
    // ——表现正是「跳进 App 没弹通话页」。（在线时只有 WS 一条路径，所以不复现）
    if (_accepting) {
      DiagLog.log('[RTC] 接听已在进行中，忽略重复触发');
      return;
    }
    _accepting = true;
    try {
      await _accept(attempts: attempts);
    } finally {
      _accepting = false;
    }
  }

  /// 接听是否已在进行中（单飞标记）。
  bool _accepting = false;

  Future<void> _accept({required int attempts}) async {
    final signal = incomingSignal;
    if (signal == null || _stage != RtcStage.incoming) {
      DiagLog.log('[RTC] 接听被跳过：signal=${signal == null ? 'null' : signal.room}，'
          'stage=$_stage');
      return;
    }
    for (var attempt = 1; attempt <= attempts; attempt++) {
      DiagLog.log('[RTC] 开始接听 room=${signal.room}（stage=$_stage，'
          '第 $attempt/$attempts 次）');
      try {
        final data = await RtcApi.acceptCall(room: signal.room);
        call = data;
        DiagLog.log('[RTC] 接听接口成功 room=${data.room}，'
            'livekitUrl=${data.livekitUrl}，token长度=${data.token.length}，'
            'status=${data.status}');
        await _enterRunning(autoConnect: true);
        return;
      } catch (e) {
        DiagLog.log('[RTC] ❌ 接听接口失败（第 $attempt/$attempts 次）: $e');
        if (attempt < attempts && _stage == RtcStage.incoming) {
          await Future<void>.delayed(Duration(milliseconds: 700 * attempt));
          continue;
        }
        if (_stage != RtcStage.incoming) {
          // 期间已被另一条路径接通/结束：不能再 hangup，否则会把接通的通话挂掉
          DiagLog.log('[RTC] 接听失败，但阶段已变为 $_stage，放弃收尾');
          return;
        }
        _notifyToast(ApiClient.errorMessage(e));
        // 接听失败也要通知服务端释放会话（hangup 按阶段走 reject/leave），
        // 否则房间一直挂在通话中，双方后续呼叫都被判「正在通话中」
        await hangup();
        return;
      }
    }
  }

  /// 进入 RUNNING：连接 LiveKit 房间 + 起计时。
  Future<void> _enterRunning({required bool autoConnect}) async {
    final data = call;
    if (data == null) return;
    _stopRingback(); // 接通：停主叫回铃音
    _stopRingtone(); // 接通：停被叫振铃音
    _pollAnswerTimer?.cancel(); // 接通：停兜底轮询
    _pollAnswerTimer = null;
    _noAnswerTimer?.cancel();
    _noAnswerTimer = null;
    // 幂等：LiveKit 事件与 1602 信令双通道可能都触发，只在首次切换起计时
    if (_stage != RtcStage.running) {
      _stage = RtcStage.running;
      _runningSince = DateTime.now();
      notifyListeners();
    }
    if (autoConnect && !liveKit.connected) {
      if (data.livekitUrl.isEmpty || data.token.isEmpty) {
        DiagLog.log('[RTC] 入房信息缺失: url="${data.livekitUrl}", token 长度=${data.token.length}');
        _notifyToast('媒体连接失败（缺少入房信息）');
        await hangup();
        return;
      }
      final connectError = await _connectMedia(data);
      if (connectError != null) {
        _notifyToast('媒体连接失败：$connectError');
        // 媒体失败同样要通知服务端释放会话（hangup 在 running 阶段走 leave），
        // 否则房间一直挂在通话中，后续呼叫会被判「正在通话中」
        await hangup();
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
    _stopCallPageGuard(); // 通话结束：停通话页兜底重试
    DiagLog.log('[RTC] finishCall: stage=$_stage, localEnd=$localEnd, '
        'toast=${toast ?? ''}, room=${call?.room ?? incomingSignal?.room ?? ''}');
    _noAnswerTimer?.cancel();
    _noAnswerTimer = null;
    // 清掉 Android 来电全屏通知（拒接/取消/对方挂断时）
    _cancelFullScreenIncomingCall();
    _stopRingback(); // 结束通话：停回铃音（幂等）
    _stopRingtone(); // 结束通话：停振铃音（拒接/超时/取消，幂等）
    _pollAnswerTimer?.cancel(); // 结束通话：停兜底轮询
    _pollAnswerTimer = null;
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
    // 通话结束（含未接来电）后端会写通话记录消息：触发会话增量同步，
    // 恢复已删除会话的显示（userDeleted 重置）并刷新最后一条消息。
    // 服务端通话记录异步落库可能晚于本次同步：延迟 5s 补拉一次兜底
    unawaited(ConversationStore.instance.load().catchError((Object _) {}));
    Timer(const Duration(seconds: 5), () {
      if (_stage == RtcStage.idle) {
        unawaited(
            ConversationStore.instance.load().catchError((Object _) {}));
      }
    });
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
    if (!_isAppForeground) return;
    // 回到前台是「锁屏滑动接听 / App 被杀后点接听」链路统一的重试点：
    // 这两条路径上事件桥、导航器都可能当时还没就绪，除了补 push 通话页，
    // 还要重新取一次原生缓存的 CallKit 事件与持久化的来电存档。
    unawaited(_consumePendingCallkitEvents());
    unawaited(syncPendingCall());
    if (isActive) {
      _openCallPage();
    }
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

  /// 主叫接通感知兜底轮询：1602 信令丢失（如被叫锁屏 CallKit 接听场景）
  /// 时，每 3 秒查一次通话状态，发现已接听（status=20）直接进通话。
  Timer? _pollAnswerTimer;

  Future<void> _pollAnswerStatus() async {
    final room = call?.room;
    if (room == null || _stage != RtcStage.inviting) {
      _pollAnswerTimer?.cancel();
      _pollAnswerTimer = null;
      return;
    }
    try {
      final data = await RtcApi.joinCall(room: room);
      if (data.status == 20) {
        _pollAnswerTimer?.cancel();
        _pollAnswerTimer = null;
        _stopRingback();
        await _enterRunning(autoConnect: true);
      }
    } catch (_) {
      // 查询失败（网络抖动等）等下一轮
    }
  }

  /// 上报 iOS VoIP Token 给后端（同 token 只报一次；接口未上线时静默容错）。
  static const String _voipTokenReportPath =
      '/app-api/member/user/updateVoipToken';
  static String? _lastReportedVoipToken;

  /// 启动时主动向原生要一次 VoIP Token：原生 PushKit 回调通常早于
  /// 本页 handler 注册，事件桥会丢掉那一条；拉取可兜住这个竞态。
  Future<void> _pullVoipTokenOnStart() async {
    try {
      final token = await _callkitChannel.invokeMethod<String>('getVoipToken');
      if (token != null && token.isNotEmpty) {
        await _reportVoipToken(token);
      } else {
        DiagLog.log('[RTC] 启动时原生尚未持有 iOS VoIP Token（PushKit 未回调）');
      }
    } catch (e) {
      DiagLog.log('[RTC] 拉取 iOS VoIP Token 失败: $e');
    }
  }

  /// 消费原生缓存的来电事件（冷启动从通知点「接听」拉起时，
  /// 原生事件早于本 handler 注册，只能由 Dart 启动后主动取走）。
  Future<void> _consumePendingCallkitEvents() async {
    try {
      final pending = await _callkitChannel
          .invokeMethod<List<dynamic>>('consumePendingCallkitEvents');
      if (pending == null || pending.isEmpty) {
        return;
      }
      for (final item in pending) {
        final args = Map<String, dynamic>.from(item as Map? ?? {});
        DiagLog.log('[RTC] 消费原生缓存来电事件: ${args['event'] ?? ''}');
        await _handleCallkitEvent(args);
      }
    } catch (e) {
      DiagLog.log('[RTC] 消费原生缓存来电事件失败: $e');
    }
  }

  /// 供 main 在首帧后调用：冷启动点「接听」的事件在导航器挂载前就到达，
  /// 需要等首帧后重新取一次，来电页才 push 得出来。
  Future<void> syncPendingCallkitEvents() async {
    await _consumePendingCallkitEvents();
    // 冷启动点「接听/来电」：事件在导航器挂载前处理完，这里补弹一次通话页
    if (isActive) _openCallPage();
  }

  /// 原生持久化来电信息的最长有效时间（秒）：超过就当上一通旧来电丢掉。
  static const int _pendingCallMaxAgeSeconds = 90;

  /// iOS 兜底：读取原生持久化的待处理来电。
  ///
  /// 好友「离线」时（App 被杀、锁屏后进程被系统回收）只能走推送链路：
  /// 原生在收到 VoIP 推送 / 用户点通知「接听」时会把 roomId 等来电信令落盘，
  /// Dart 启动后（或回到前台时）用这份存档还原来电页 / 直接接听。
  /// 没有这道兜底就会出现「点了接听跳进 App 了，却没有通话页」。
  Future<void> syncPendingCall() async {
    if (!Platform.isIOS) return;
    try {
      final raw = await _callkitChannel
          .invokeMethod<Map<dynamic, dynamic>>('getPendingCall');
      if (raw == null) return;
      final wrapper = <String, dynamic>{
        for (final entry in raw.entries) entry.key.toString(): entry.value,
      };
      final payload = Map<String, dynamic>.from(
        wrapper['payload'] as Map? ?? const <String, dynamic>{},
      );
      if (payload.isEmpty) return;
      final at = wrapper['at'];
      final savedAt = at is num ? at.toDouble() : 0.0;
      final ageSeconds = savedAt > 0
          ? DateTime.now().millisecondsSinceEpoch / 1000 - savedAt
          : 0.0;
      if (ageSeconds > _pendingCallMaxAgeSeconds) {
        DiagLog.log(
            '[RTC] 原生待处理来电已过期(${ageSeconds.toStringAsFixed(0)}s)，清掉');
        await _clearPendingCall();
        return;
      }
      final room = (payload['room'] ?? payload['roomId'])?.toString() ?? '';
      if (room.isEmpty) return;
      final answered = wrapper['answered'] == true;
      DiagLog.log('[RTC] 原生待处理来电: room=$room, answered=$answered, '
          'age=${ageSeconds.toStringAsFixed(0)}s, stage=$_stage');
      if (call?.room != room && incomingSignal?.room != room) {
        if (isActive) return; // 正在处理别的通话，不打断
        if (!handleIncomingFromPush(payload)) return;
      }
      if (answered && _stage == RtcStage.incoming) {
        await accept(attempts: 3);
      }
      if (isActive) _openCallPage();
    } catch (e) {
      DiagLog.log('[RTC] 读取原生待处理来电失败: $e');
    }
  }

  /// 清掉原生的来电存档（过期来电 / 通话结束后）。
  Future<void> _clearPendingCall() async {
    try {
      await _callkitChannel.invokeMethod<void>('clearPendingCall');
    } catch (_) {
      // 原生未实现时忽略
    }
  }

  Future<void> _reportVoipToken(String token) async {
    if (token == _lastReportedVoipToken) return; // 同 token 不重复上报
    DiagLog.log('[RTC] iOS VoIP Token(${token.length}字符) 上报后端: $token');
    try {
      final resp = await ApiClient.dio.put<Object>(
        '$_voipTokenReportPath?voipToken=$token',
      );
      final data = resp.data;
      final code = data is Map ? data['code'] : null;
      if (code == null || code == 0 || code == 200) {
        _lastReportedVoipToken = token; // 只有成功才去重
        DiagLog.log('[RTC] ✅ VoIP Token 上报成功: $data');
      } else {
        // 未登录时后端返回 code=401「账号未登录」：不能记去重，否则本次会话
        // 登录后就不会再报了；交给 reportVoipTokenIfNeeded / 下次启动重试。
        DiagLog.log('[RTC] ❌ VoIP Token 上报被后端拒绝(code=$code)，登录后会重试: $data');
      }
    } catch (e) {
      // 接口未上线（404 等）不重试不刷屏；后端就绪后下次启动会重新上报
      DiagLog.log('[RTC] ❌ VoIP Token 上报失败: $e');
    }
  }

  /// 登录成功后补报 VoIP Token。
  ///
  /// App 冷启动时如果还没登录，上报会被后端以「账号未登录」拒绝；只靠启动那一次
  /// 上报就会漏传，后端没有这台设备的 VoIP Token 就发不出来电推送。
  Future<void> reportVoipTokenIfNeeded() async {
    if (!Platform.isIOS) return;
    try {
      final token = await _callkitChannel.invokeMethod<String>('getVoipToken');
      if (token != null && token.isNotEmpty) {
        await _reportVoipToken(token);
      } else {
        DiagLog.log('[RTC] 登录后补报：原生尚未持有 VoIP Token，等 PushKit 回调');
      }
    } catch (e) {
      DiagLog.log('[RTC] 登录后补报 VoIP Token 失败: $e');
    }
  }

  /// 退出登录：清掉后端保存的本机 VoIP Token，后端就不再往这台设备发 VoIP 推送
  /// （对齐普通推送退出登录时的 stopPush/deleteAlias）。
  ///
  /// 调用方 [JPushRegistrationUpload.stopPushOnLogout] 不 await 本方法，且随后就会
  /// 清本地登录态，所以这里把当前 token 显式塞进请求头，避免清除竞态导致 401。
  Future<void> unbindVoipToken() async {
    // 允许重新登录后再次上报同一个 Token（后端那条记录已被清空）
    _lastReportedVoipToken = null;
    final token = AuthManager.instance.accessToken;
    try {
      final resp = await ApiClient.dio
          .put<Object>(
            '$_voipTokenReportPath?voipToken=',
            options: Options(
              headers: <String, dynamic>{
                if (token != null && token.isNotEmpty)
                  'Authorization': 'Bearer $token',
              },
            ),
          )
          .timeout(const Duration(seconds: 5));
      DiagLog.log('[RTC] 退出登录已通知后端清空 VoIP Token: ${resp.data}');
    } catch (e) {
      // 后端未支持空 token（400/404）时静默：登出后原生侧也会忽略 VoIP 推送
      DiagLog.log('[RTC] 退出登录清空后端 VoIP Token 失败（接口待后端支持）: $e');
    }
  }

  /// iOS CallKit 事件：VoIP token / 来电 / 系统界面接听 / 拒接。
  Future<dynamic> _onCallkitEvent(MethodCall call) async {
    if (call.method != 'onCallkitEvent') return null;
    await _handleCallkitEvent(
      Map<String, dynamic>.from(call.arguments as Map? ?? {}),
    );
    return null;
  }

  /// 处理单个来电事件（原生事件桥与冷启动缓存消费共用）。
  Future<void> _handleCallkitEvent(Map<String, dynamic> args) async {
    final event = args['event'] as String? ?? '';
    final payload =
        Map<String, dynamic>.from(args['payload'] as Map? ?? <String, dynamic>{});
    // 关键排查日志：App 里点「接听/拒绝」后原生到底给了什么（payload 有没有房间号）
    DiagLog.log('[CallKit] 事件: $event, payload=$payload');
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
        if (payload.isEmpty) {
          // 事件桥没带 payload：读原生存档兜底
          await syncPendingCall();
        } else {
          handleIncomingFromPush(payload);
        }
        if (!isActive) {
          DiagLog.log('[RTC] ❌ 来电事件未能弹出来电页；payload=$payload');
        }
        break;
      case 'answer':
        // 用户在系统来电界面点「接听」（App 已被带回前台）
        if (_stage == RtcStage.incoming) {
          // 冷启动链路：接听接口可能因为网络/登录态未热而失败，多试两次
          await accept(attempts: 3);
          break;
        }
        // 冷启动竞态：来电页尚未建立 → 先补入再接听
        if (payload.isEmpty) {
          // 事件桥没带 payload（进程重启）：读原生存档还原（answered=true 时内部直接接听）
          await syncPendingCall();
        } else {
          handleIncomingFromPush(payload);
        }
        if (_stage == RtcStage.incoming) await accept(attempts: 3);
        if (_stage != RtcStage.incoming) {
          // 走到这里说明「点了接听但找不到这通电话」：要么原生没给房间号，
          // 要么身份校验没过。必须在界面上说出来，否则用户只看到「跳进 App 没反应」。
          DiagLog.log('[RTC] ❌ 接听事件未能建立来电上下文，无法接通；payload=$payload');
          _notifyToast('接听失败：未取到来电房间号，请把控制台日志发给开发排查');
        }
        break;
      case 'reject':
        // 用户在系统来电界面 / 来电通知按钮点「拒绝」
        if (_stage == RtcStage.incoming || _stage == RtcStage.running) {
          // 来电页已建立：走统一挂断入口（incoming→reject，running→leave）
          await hangup();
        } else {
          // 冷启动或后台直接拒接：来电页尚未建立，直接调接口，避免主叫一直响
          final room =
              (payload['room'] ?? payload['roomId'])?.toString() ?? '';
          if (room.isNotEmpty) {
            await RtcApi.rejectCall(room: room).catchError((Object _) {});
          }
        }
        break;
    }
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
        DiagLog.log('[RTC] 发送来电全屏通知失败: $e');
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
    if (_callPageOpen) return; // 已经在栈上（由 push 的 Future 复位）
    final key = navigatorKey;
    final nav = key?.currentState;
    if (nav == null) {
      // 冷启动（锁屏接听 / 杀进程后接听 / 点通知接听）时导航 Key 或导航器
      // 还没挂载：交给兜底定时器一直重试，直到页面真的 push 出去
      DiagLog.log('[RTC] 导航器未就绪（key=${key == null ? 'null' : 'ok'}），'
          '等待兜底重试弹通话页，stage=$_stage');
      _startCallPageGuard();
      return;
    }
    // App 在后台（WS 还存活的时间窗内收到来电信令）：
    // Android 发 fullScreenIntent 通知——锁屏直接全屏弹来电界面，
    // 亮屏显示 heads-up；点击/全屏拉起后复用 push_open 链路进来电页
    if (!_isAppForeground && !Platform.isIOS) {
      _showFullScreenIncomingCall();
    }
    _callPageOpen = true;
    DiagLog.log('[RTC] push 通话页: room=${call?.room ?? incomingSignal?.room ?? ''}, '
        'foreground=$_isAppForeground, stage=$_stage');
    nav
        .push(
          PageRouteBuilder(
            opaque: false,
            transitionDuration: Duration.zero,
            settings: const RouteSettings(name: callPageRouteName),
            pageBuilder: (_, __, ___) => const RtcCallPage(),
          ),
        )
        .then((_) {
      _callPageOpen = false;
      DiagLog.log('[RTC] 通话页已退出');
    });
    // iOS：通话页已经在屏幕上，可以收起系统来电界面了（CallKit 通话保持 active
    // 是把 App 带到前台的前提，之前 4 秒强制收起会在冷启动慢时打断这个过程）。
    if (Platform.isIOS) {
      unawaited(
          _callkitChannel.invokeMethod('callPageShown').catchError((Object _) {}));
    }
  }

  /// 通话中持续兜底：导航器就绪慢（冷启动）时每 300ms 尝试一次 push 通话页。
  void _startCallPageGuard() {
    if (_callPageGuard != null) return;
    _callPageGuard = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!isActive || _callPageOpen) {
        _stopCallPageGuard();
        return;
      }
      _openCallPage();
    });
  }

  void _stopCallPageGuard() {
    _callPageGuard?.cancel();
    _callPageGuard = null;
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
