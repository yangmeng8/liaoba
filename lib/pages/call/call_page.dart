import 'dart:async';

import 'package:flutter/material.dart';

import '../../rtc/livekit_room.dart';
import '../../rtc/rtc_controller.dart';
import '../../services/auth_api.dart';
import '../../services/auth_manager.dart';
import '../../shared/im_avatar.dart';

/// 通话页（等价 H5 rtc-call-container.vue）：
/// 全屏深色 + 三阶段状态机（INVITING 主叫 / INCOMING 被叫 / RUNNING 通话中）
/// + LiveKit 视频宫格 + 控制条；stage 回 idle 自动退出。
class RtcCallPage extends StatefulWidget {
  const RtcCallPage({super.key});

  @override
  State<RtcCallPage> createState() => _RtcCallPageState();
}

class _RtcCallPageState extends State<RtcCallPage> {
  // ===== 深色配色（通话页固定深色，不随系统主题） =====
  static const Color _bg = Color(0xFF141416);
  static const Color _panel = Color(0xFF1E1E22);
  static const Color _hangupRed = Color(0xFFF5484D);
  static const Color _acceptGreen = Color(0xFF07C160);
  static const Color _textPrimary = Color(0xFFFFFFFF);
  static const Color _textSecondary = Color(0xFF9EA0A4);

  RtcController get _ctrl => RtcController.instance;

  /// 每秒计时器（RUNNING 时长显示）。
  Timer? _ticker;

  /// 扬声器开关（语音通话听筒/外放；视频通话默认外放）。
  bool _speakerOn = false;

  /// RUNNING 音频路由初始化标记（语音→听筒，视频→扬声器）。
  bool _audioRouteReady = false;

  /// 挂断/接听防抖（连点）。
  bool _busy = false;

  /// 用户资料缓存：userId → SimpleUser（昵称/头像解析）。
  final Map<int, SimpleUser> _userCache = {};

  /// 资料解析防并发标记。
  bool _resolving = false;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_ctrl.stage == RtcStage.running && mounted) setState(() {});
    });
    // 帧布局后解析对端资料（INVITING/INCOMING 头像昵称展示）
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveProfiles());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  int get _myUserId => AuthManager.instance.userId ?? 0;

  /// 对端 userId（INVITING/INCOMING 私聊对方；群聊无对端概念返回 null）。
  int? get _peerUserId {
    if (_ctrl.stage == RtcStage.incoming) {
      final id = _ctrl.incomingSignal?.inviterUserId ?? 0;
      return id > 0 ? id : null;
    }
    final call = _ctrl.call;
    if (call?.conversationType != 1) return null;
    // 后端 inviteeIds 仅含 INVITING 状态参与者：接听后变 JOINED 即移出，
    // 故 accept 返回的快照里为空——需再从 joinedUserIds 取非本人兜底
    final ids = call?.inviteeIds ?? const <int>[];
    if (ids.isNotEmpty) return ids.first;
    final joined = (call?.joinedUserIds ?? const <int>[])
        .where((id) => id != _myUserId)
        .toList();
    return joined.isNotEmpty ? joined.first : null;
  }

  /// 对端显示名（INVITING/INCOMING 顶部标题）。
  String get _peerName {
    if (_ctrl.stage == RtcStage.incoming) {
      final sig = _ctrl.incomingSignal;
      if (sig != null && sig.inviterNickname.isNotEmpty) {
        return sig.inviterNickname;
      }
      final id = sig?.inviterUserId ?? 0;
      return id > 0 ? _cachedName(id) : '';
    }
    final peer = _peerUserId;
    if (peer != null && peer > 0) return _cachedName(peer);
    // 群通话主叫瞬间即 RUNNING 无对端概念；私聊对端尚未解析时短暂兜底
    return _ctrl.call?.conversationType == 1 ? '对方' : '群通话';
  }

  /// 对端头像（INVITING/INCOMING 大头像）。
  String get _peerAvatar {
    if (_ctrl.stage == RtcStage.incoming) {
      return _ctrl.incomingSignal?.inviterAvatar ?? '';
    }
    final peer = _peerUserId;
    if (peer != null && peer > 0) return _userCache[peer]?.avatar ?? '';
    return '';
  }

  String _cachedName(int userId) {
    if (userId == _myUserId) {
      return AuthManager.instance.nickname ?? '我';
    }
    final u = _userCache[userId];
    if (u != null && u.nickname.isNotEmpty) return u.nickname;
    return '用户$userId';
  }

  String _nameOf(RtcParticipant p) {
    if (p.userId == _myUserId) return _cachedName(_myUserId);
    if (p.name.isNotEmpty) return p.name;
    return _cachedName(p.userId);
  }

  String _avatarOf(RtcParticipant p) {
    if (p.userId == _myUserId) return AuthManager.instance.avatar ?? '';
    return _userCache[p.userId]?.avatar ?? '';
  }

  /// 解析对端/参与者资料（get-simple 免鉴权；缓存判重幂等）。
  Future<void> _resolveProfiles() async {
    if (_resolving) return;
    _resolving = true;
    try {
      final ids = <int>{};
      final peer = _peerUserId;
      if (peer != null && peer > 0) ids.add(peer);
      _ctrl.liveKit.participants.forEach((identity, p) {
        if (p.userId > 0 && p.userId != _myUserId) ids.add(p.userId);
      });
      for (final id in ids) {
        if (_userCache.containsKey(id)) continue;
        try {
          final u = await AuthApi.getSimpleUser(id);
          if (u != null) _userCache[id] = u;
        } catch (_) {
          // 静默：降级 '用户N'
        }
      }
      if (mounted) setState(() {});
    } finally {
      _resolving = false;
    }
  }

  // ===== 本地媒体状态（宫格/控制条渲染） =====

  bool get _micMuted {
    final me = _ctrl.liveKit.participants['$_myUserId'];
    return me?.micMuted ?? false;
  }

  bool get _camMuted {
    final me = _ctrl.liveKit.participants['$_myUserId'];
    return me?.cameraMuted ?? true;
  }

  // ===== 动作 =====

  Future<void> _hangup() async {
    if (_busy) return;
    _busy = true;
    try {
      await _ctrl.hangup();
    } finally {
      _busy = false;
    }
  }

  Future<void> _accept() async {
    if (_busy) return;
    _busy = true;
    try {
      await _ctrl.accept();
    } finally {
      _busy = false;
    }
  }

  Future<void> _toggleMic() =>
      _ctrl.liveKit.setMicEnabled(_micMuted);

  Future<void> _toggleCamera() =>
      _ctrl.liveKit.setCameraEnabled(_camMuted);

  Future<void> _switchCamera() => _ctrl.liveKit.switchCamera();

  Future<void> _toggleSpeaker() async {
    setState(() => _speakerOn = !_speakerOn);
    await _ctrl.liveKit.setSpeakerEnabled(_speakerOn);
  }

  /// 通话结束后退出（stage 回 idle 时 postFrame 调用）。
  void _exitOnIdle() {
    if (!mounted) return;
    final toast = _ctrl.endToast;
    if (toast.isNotEmpty) {
      _ctrl.endToast = '';
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(toast)));
    }
    final nav = Navigator.of(context);
    if (nav.canPop()) nav.pop();
  }

  // ===== 构建 =====

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _ctrl,
      builder: (context, _) {
        if (_ctrl.stage == RtcStage.idle) {
          // 结束：帧后退出（可能先弹结束原因 toast）
          WidgetsBinding.instance.addPostFrameCallback((_) => _exitOnIdle());
        }
        // RUNNING 进入时初始化音频路由（语音→听筒，视频→扬声器）
        _ensureAudioRoute();
        return PopScope(
          // 通话中禁直接返回：返回键等同挂断；idle 后由 _exitOnIdle 收尾退出
          canPop: _ctrl.stage == RtcStage.idle,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _hangup();
          },
          child: Scaffold(
            backgroundColor: _bg,
            body: SafeArea(
              child: Stack(
                children: [
                  Column(
                    children: [
                      _buildHeader(),
                      Expanded(child: _buildBody()),
                      _buildControls(),
                    ],
                  ),
                  // 网络重连提示横幅
                  if (_ctrl.liveKit.networkHint.isNotEmpty)
                    Positioned(
                      top: 8,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            _ctrl.liveKit.networkHint,
                            style: const TextStyle(
                              color: _textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// RUNNING 音频路由初始化（幂等，build 时触发）。
  void _ensureAudioRoute() {
    if (_audioRouteReady || _ctrl.stage != RtcStage.running) return;
    _audioRouteReady = true;
    _speakerOn = _ctrl.isVideo; // 视频默认扬声器，语音默认听筒
    _ctrl.liveKit.setSpeakerEnabled(_speakerOn);
  }

  /// 顶部信息：对端昵称 + 阶段状态文案。
  Widget _buildHeader() {
    final statusText = switch (_ctrl.stage) {
      RtcStage.inviting => '正在等待对方接听…',
      RtcStage.incoming => _ctrl.isVideo ? '邀请你视频通话' : '邀请你语音通话',
      RtcStage.running => _formatDuration(_ctrl.elapsedSeconds),
      RtcStage.idle => '',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _peerName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            statusText,
            style: const TextStyle(color: _textSecondary, fontSize: 14),
          ),
        ],
      ),
    );
  }

  /// 主区域（按阶段分流）。
  Widget _buildBody() {
    switch (_ctrl.stage) {
      case RtcStage.inviting:
      case RtcStage.incoming:
        return _buildWaitingBody();
      case RtcStage.running:
        return _buildRunningBody();
      case RtcStage.idle:
        return const SizedBox.shrink();
    }
  }

  /// INVITING/INCOMING：大头像等待区。
  Widget _buildWaitingBody() {
    final isIncoming = _ctrl.stage == RtcStage.incoming;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ImAvatar(
            src: _peerAvatar,
            name: _peerName,
            size: 110,
            borderRadius: BorderRadius.circular(55),
          ),
          const SizedBox(height: 28),
          // 拨号音动画：三个呼吸圆点
          _buildCallingDots(isIncoming),
        ],
      ),
    );
  }

  /// 呼叫状态动画（简易三点呼吸）。
  Widget _buildCallingDots(bool isIncoming) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: _BreathingDot(delay: i * 0.3),
          ),
      ],
    );
  }

  /// RUNNING：宫格布局（1 人全屏，多人 2 列 grid，对齐 H5）。
  Widget _buildRunningBody() {
    return StreamBuilder<void>(
      stream: _ctrl.liveKit.changes,
      builder: (context, _) {
        // 新参与者入房后解析资料（幂等）
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _ctrl.stage == RtcStage.running) _resolveProfiles();
        });
        final list = _ctrl.liveKit.participants.values.toList();
        if (list.isEmpty) {
          return const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _textSecondary,
              ),
            ),
          );
        }
        if (list.length == 1) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: _buildTile(list.first),
          );
        }
        return GridView.count(
          crossAxisCount: 2,
          padding: const EdgeInsets.all(10),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 0.92,
          children: [for (final p in list) _buildTile(p)],
        );
      },
    );
  }

  /// 单个参与者格子：视频轨在线 → VideoTrackRenderer；
  /// 否则头像兜底（语音通话/对方关摄像头）。角标：昵称 + 静音标记。
  Widget _buildTile(RtcParticipant p) {
    final hasVideo = _ctrl.isVideo && !p.cameraMuted && p.cameraRenderer != null;
    final name = _nameOf(p);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasVideo) p.cameraRenderer! else _buildTilePlaceholder(p),
          // 底部标签：静音图标 + 昵称
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              color: Colors.black38,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (p.micMuted)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(
                        Icons.mic_off,
                        size: 13,
                        color: _hangupRed,
                      ),
                    ),
                  Expanded(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _textPrimary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 无视频时的格子内容：深色底 + 居中头像。
  Widget _buildTilePlaceholder(RtcParticipant p) {
    return Container(
      color: _panel,
      alignment: Alignment.center,
      child: ImAvatar(
        src: _avatarOf(p),
        name: _nameOf(p),
        size: 64,
        borderRadius: BorderRadius.circular(32),
      ),
    );
  }

  /// 底部控制条（按阶段分流）。
  Widget _buildControls() {
    switch (_ctrl.stage) {
      case RtcStage.inviting:
        // 主叫等待：仅取消
        return _buildControlRow([
          _circleBtn(
            icon: Icons.call_end,
            bg: _hangupRed,
            label: '取消',
            onTap: _hangup,
          ),
        ]);
      case RtcStage.incoming:
        // 被叫：拒绝 + 接听
        return _buildControlRow([
          _circleBtn(
            icon: Icons.call_end,
            bg: _hangupRed,
            label: '拒绝',
            onTap: _hangup,
          ),
          const SizedBox(width: 56),
          _circleBtn(
            icon: Icons.call,
            bg: _acceptGreen,
            label: '接听',
            onTap: _accept,
          ),
        ]);
      case RtcStage.running:
        // 通话中：麦克风 + 摄像头/扬声器 + 挂断（+视频：翻转镜头）
        final buttons = <Widget>[
          _circleBtn(
            icon: _micMuted ? Icons.mic_off : Icons.mic,
            bg: _micMuted ? _textPrimary : _panel,
            iconColor: _micMuted ? _bg : _textPrimary,
            label: _micMuted ? '解除静音' : '静音',
            onTap: _toggleMic,
          ),
          const SizedBox(width: 20),
          if (_ctrl.isVideo) ...[
            _circleBtn(
              icon: _camMuted ? Icons.videocam_off : Icons.videocam,
              bg: _camMuted ? _textPrimary : _panel,
              iconColor: _camMuted ? _bg : _textPrimary,
              label: _camMuted ? '开摄像头' : '关摄像头',
              onTap: _toggleCamera,
            ),
            const SizedBox(width: 20),
          ],
          _circleBtn(
            icon: Icons.call_end,
            bg: _hangupRed,
            label: '挂断',
            onTap: _hangup,
          ),
          const SizedBox(width: 20),
          if (_ctrl.isVideo)
            _circleBtn(
              icon: Icons.cameraswitch,
              bg: _panel,
              label: '翻转',
              onTap: _switchCamera,
            )
          else
            _circleBtn(
              icon: _speakerOn ? Icons.volume_up : Icons.hearing,
              bg: _speakerOn ? _textPrimary : _panel,
              iconColor: _speakerOn ? _bg : _textPrimary,
              label: _speakerOn ? '扬声器' : '听筒',
              onTap: _toggleSpeaker,
            ),
        ];
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: buttons,
          ),
        );
      case RtcStage.idle:
        return const SizedBox.shrink();
    }
  }

  Widget _buildControlRow(List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: children),
    );
  }

  /// 圆形控制按钮（图标 + 下方小字）。
  Widget _circleBtn({
    required IconData icon,
    required Color bg,
    required String label,
    required VoidCallback onTap,
    Color? iconColor,
    double size = 60,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: bg,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, size: 28, color: iconColor ?? _textPrimary),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(color: _textSecondary, fontSize: 11),
        ),
      ],
    );
  }

  /// 时长格式化：mm:ss（超 1 小时 hh:mm:ss）。
  String _formatDuration(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}

/// 呼吸圆点（等待接听动画）。
class _BreathingDot extends StatefulWidget {
  final double delay;

  const _BreathingDot({required this.delay});

  @override
  State<_BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<_BreathingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: (widget.delay * 1000).round()), () {
      if (mounted) _ctrl.repeat();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.3, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
      ),
      child: Container(
        width: 10,
        height: 10,
        decoration: const BoxDecoration(
          color: Color(0xFF9EA0A4),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
