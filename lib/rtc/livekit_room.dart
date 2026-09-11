import 'dart:async';

import 'package:livekit_client/livekit_client.dart';

/// 单个参与者的渲染数据（identity = userId 约定，服务端按此签 token）。
class RtcParticipant {
  /// LiveKit identity（= 业务 userId）。
  final String identity;

  /// 显示名（连接时由 Controller 注入解析结果）。
  final String name;

  /// 摄像头视频轨道渲染器（视频通话；语音通话为 null）。
  /// VideoTrackRenderer 本身是 Widget，无需手动 dispose。
  VideoTrackRenderer? cameraRenderer;

  /// 是否静音（远端 TrackMuted / 本地开关同步）。
  bool micMuted;

  /// 是否摄像头关闭（远端 TrackMuted / 本地开关同步）。
  bool cameraMuted;

  RtcParticipant({
    required this.identity,
    required this.name,
    this.cameraRenderer,
    this.micMuted = false,
    this.cameraMuted = false,
  });

  int get userId => int.tryParse(identity) ?? 0;
}

/// LiveKit 房间封装（等价 H5 useLiveKitRoom）：
/// - connect 即开麦；视频通话再开摄像头
/// - 事件驱动维护 participants（TrackSubscribed/Muted/Participant 进出）
/// - 渲染优先级：屏幕共享 > 摄像头
/// - onDisconnected 回调供 Controller 做远端断开收尾
class RtcLiveKitRoom {
  Room? _room;

  /// 本地摄像头轨道（切换前后镜头用）。
  LocalVideoTrack? _localCameraTrack;

  /// 事件监听取消函数集合。
  final List<CancelListenFunc> _cancels = [];

  final _participantsCtrl = StreamController<void>.broadcast();

  /// 已销毁标记（connect 竞态：断开时连接刚返回则丢弃）。
  bool _disposed = false;

  /// 参与者渲染数据（含本地；identity=userId）。
  final Map<String, RtcParticipant> participants = {};

  /// 网络重连中提示（Reconnecting/Reconnected 事件驱动）。
  String networkHint = '';

  /// 房间远端断开回调（Controller 挂断收尾用；
  /// 主动 disconnect 前会被清空，防本地挂断误触发）。
  void Function()? onDisconnected;

  /// 参与者/轨道变化流（UI 监听重建宫格）。
  Stream<void> get changes => _participantsCtrl.stream;

  Room? get room => _room;

  bool get connected =>
      _room != null && _room!.connectionState == ConnectionState.connected;

  /// 连接房间（对齐 H5：连上即开麦；视频通话默认开摄像头）。
  Future<void> connect({
    required String url,
    required String token,
    required bool enableCamera,
    required String myName,
  }) async {
    final room = Room(
      roomOptions: const RoomOptions(adaptiveStream: true, dynacast: true),
    );
    _room = room;
    _disposed = false;
    _listen(room);
    await room.connect(url, token);
    if (_disposed) return;
    final local = room.localParticipant;
    if (local == null) return;
    // 连上即开麦
    await local.setMicrophoneEnabled(true);
    // 本地参与者入表
    final localId = local.identity;
    participants[localId] = RtcParticipant(
      identity: localId,
      name: myName,
      micMuted: false,
      cameraMuted: !enableCamera,
    );
    if (enableCamera) {
      // 视频通话：连上即开摄像头，并为本地画面建渲染器
      final pub = await local.setCameraEnabled(true);
      final track = pub?.track;
      if (track is LocalVideoTrack) {
        _localCameraTrack = track;
        participants[localId]?.cameraRenderer = VideoTrackRenderer(
          track,
          fit: VideoViewFit.cover,
        );
      }
    }
    // 已在房远端（群通话 join 场景）同步入表
    _syncRemote(room);
    _emit();
  }

  void _listen(Room room) {
    final listener = room.createListener();
    _cancels.addAll([
      listener.on<TrackSubscribedEvent>(_onTrackSubscribed),
      listener.on<TrackUnsubscribedEvent>(_onTrackUnsubscribed),
      listener.on<TrackMutedEvent>(
        (e) => _applyMute(e.participant.identity, e.publication.source, true),
      ),
      listener.on<TrackUnmutedEvent>(
        (e) => _applyMute(e.participant.identity, e.publication.source, false),
      ),
      listener.on<ParticipantConnectedEvent>(_onParticipantConnected),
      listener.on<ParticipantDisconnectedEvent>(_onParticipantDisconnected),
      listener.on<RoomReconnectingEvent>((_) => _onNetworkChanged('网络重连中…')),
      listener.on<RoomReconnectedEvent>((_) => _onNetworkChanged('')),
      listener.on<RoomDisconnectedEvent>((_) {
        // 主动断开时 listener 已取消订阅，走到这里即远端/异常断开
        if (!_disposed) onDisconnected?.call();
      }),
    ]);
  }

  void _onTrackSubscribed(TrackSubscribedEvent e) {
    final identity = e.participant.identity;
    final p = participants.putIfAbsent(
      identity,
      () => RtcParticipant(identity: identity, name: e.participant.name),
    );
    if (e.track is RemoteVideoTrack) {
      final track = e.track as RemoteVideoTrack;
      // 渲染优先级：屏幕共享 > 摄像头
      final source = e.publication.source;
      if (source == TrackSource.screenShareVideo ||
          source == TrackSource.camera) {
        p.cameraRenderer = VideoTrackRenderer(track, fit: VideoViewFit.cover);
      }
    }
    _emit();
  }

  void _onTrackUnsubscribed(TrackUnsubscribedEvent e) {
    final p = participants[e.participant.identity];
    if (p == null) return;
    p.cameraRenderer = null;
    _emit();
  }

  /// 静音状态同步（本地开关与远端 TrackMuted 事件共用）。
  void _applyMute(String identity, TrackSource source, bool muted) {
    final p = participants[identity];
    if (p == null) return;
    if (source == TrackSource.microphone) {
      p.micMuted = muted;
    } else if (source == TrackSource.camera) {
      p.cameraMuted = muted;
    }
    _emit();
  }

  void _onParticipantConnected(ParticipantConnectedEvent e) {
    participants.putIfAbsent(
      e.participant.identity,
      () =>
          RtcParticipant(identity: e.participant.identity, name: e.participant.name),
    );
    _emit();
  }

  void _onParticipantDisconnected(ParticipantDisconnectedEvent e) {
    participants.remove(e.participant.identity);
    _emit();
  }

  void _onNetworkChanged(String hint) {
    networkHint = hint;
    _emit();
  }

  /// 同步远端参与者（join 场景：进房时其他人已在房）。
  void _syncRemote(Room room) {
    for (final remote in room.remoteParticipants.values) {
      final p = participants.putIfAbsent(
        remote.identity,
        () => RtcParticipant(identity: remote.identity, name: remote.name),
      );
      for (final pub in remote.trackPublications.values) {
        if (pub.source == TrackSource.microphone) {
          p.micMuted = pub.muted;
        }
        final track = pub.track;
        if (track is RemoteVideoTrack &&
            (pub.source == TrackSource.camera ||
                pub.source == TrackSource.screenShareVideo)) {
          p.cameraRenderer = VideoTrackRenderer(track, fit: VideoViewFit.cover);
          p.cameraMuted = pub.muted;
        }
      }
    }
  }

  /// 本地麦克风开关。
  Future<void> setMicEnabled(bool enabled) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    await local.setMicrophoneEnabled(enabled);
    final p = participants[local.identity];
    if (p != null) p.micMuted = !enabled;
    _emit();
  }

  /// 本地摄像头开关（仅视频通话）。
  Future<void> setCameraEnabled(bool enabled) async {
    final local = _room?.localParticipant;
    if (local == null) return;
    await local.setCameraEnabled(enabled);
    final p = participants[local.identity];
    if (p != null) p.cameraMuted = !enabled;
    _emit();
  }

  /// 切换前后摄像头（移动端必备）。
  Future<void> switchCamera() async {
    final track = _localCameraTrack;
    if (track == null) return;
    final opts = track.currentOptions;
    if (opts is! CameraCaptureOptions) return;
    await track.setCameraPosition(
      opts.cameraPosition == CameraPosition.front
          ? CameraPosition.back
          : CameraPosition.front,
    );
  }

  /// 扬声器开关（语音通话切听筒/扬声器；iOS/Android 生效）。
  Future<void> setSpeakerEnabled(bool enabled) async {
    await AudioManager.instance.setSpeakerOutputPreferred(enabled);
  }

  void _emit() {
    if (!_participantsCtrl.isClosed) _participantsCtrl.add(null);
  }

  /// 断开并释放资源。
  Future<void> disconnect() async {
    _disposed = true;
    onDisconnected = null; // 防本地主动挂断触发远端断开回调
    for (final cancel in _cancels) {
      try {
        cancel();
      } catch (_) {
        // 静默
      }
    }
    _cancels.clear();
    final room = _room;
    _room = null;
    _localCameraTrack = null;
    participants.clear();
    try {
      await room?.disconnect();
    } catch (_) {
      // 静默：断开失败不影响收尾
    }
    try {
      await room?.dispose();
    } catch (_) {
      // 静默
    }
  }
}
