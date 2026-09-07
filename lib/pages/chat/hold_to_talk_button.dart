import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';

/// 按住说话组件（对应 H5 voice-recorder）：
/// - 长按开始录音，上滑进入取消态（松手丢弃），松手正常发送
/// - 取消态迟滞：进入需滑够完整阈值，退出只需 0.7 倍距离（防手指抖动）
/// - 60s 上限自动停、<1s 丢弃、录音会话号防"授权期间松手"的幽灵录音
/// - 录音完成回调 (filePath, durationSeconds, sizeBytes)，上传与发送由父级处理
class HoldToTalkButton extends StatefulWidget {
  /// 录音完成（松手且校验通过）。duration 单位秒。
  final void Function(String filePath, int durationSeconds, int sizeBytes)
  onDone;

  const HoldToTalkButton({super.key, required this.onDone});

  @override
  State<HoldToTalkButton> createState() => _HoldToTalkButtonState();
}

class _HoldToTalkButtonState extends State<HoldToTalkButton> {
  static const int _maxDurationSec = 60;
  static const int _minDurationMs = 1000;

  final AudioRecorder _recorder = AudioRecorder();

  bool _pressing = false;
  bool _cancelPending = false;

  /// 录音会话号：每次按下自增；异步回调（权限/停止）只认当前会话，
  /// 防止授权弹窗期间松手后仍录出"幽灵语音"。
  int _sessionId = 0;

  double? _startY;
  Timer? _maxTimer;
  DateTime? _recordStart;

  /// 进入取消态的上滑距离（屏幕宽 16%）。
  final double _cancelEnterDistance = 60;
  // 退出距离 = 进入距离 × 0.7（迟滞）

  bool get _recording => _pressing;

  @override
  void dispose() {
    _maxTimer?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final session = ++_sessionId;
    setState(() {
      _pressing = true;
      _cancelPending = false;
    });
    HapticFeedback.lightImpact();
    try {
      // 权限申请是异步的：期间用户可能松手 → 会话号校验丢弃
      if (!await _recorder.hasPermission()) {
        if (_sessionId == session && mounted) {
          _toast('需要麦克风权限');
        }
        _resetInteraction();
        return;
      }
      if (_sessionId != session || !_pressing) {
        // 授权期间已松手：不开始录音
        return;
      }
      _recordStart = DateTime.now();
      // 绝对路径：iOS 不解析相对路径（会落到沙箱根导致写失败），必须用临时目录拼接
      final tmpDir = await getTemporaryDirectory();
      final path =
          '${tmpDir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc),
        path: path,
      );
      // 60s 上限自动停（走正常松手流程）
      _maxTimer?.cancel();
      _maxTimer = Timer(const Duration(seconds: _maxDurationSec), _stopAndSend);
    } catch (_) {
      if (_sessionId == session && mounted) {
        _toast('录音失败');
      }
      _resetInteraction();
    }
  }

  /// 手指移动：取消态判断（迟滞切换）。
  void _onMove(double globalY) {
    if (_startY == null) return;
    final distance = (_startY! - globalY).clamp(0.0, double.infinity);
    final enter = _cancelEnterDistance;
    final exit = enter * 0.7;
    final wasCancel = _cancelPending;
    // 已在取消态：滑回 0.7 倍距离内才退出；正常态：滑够完整距离才进入
    final nowCancel = wasCancel ? distance > exit : distance >= enter;
    if (nowCancel != wasCancel) {
      setState(() => _cancelPending = nowCancel);
      HapticFeedback.selectionClick();
    }
  }

  /// 松手：取消态丢弃，正常则校验并发送。
  Future<void> _stopAndSend() async {
    final session = _sessionId;
    _maxTimer?.cancel();
    _maxTimer = null;
    final cancelPending = _cancelPending;
    final recordStart = _recordStart;
    setState(() => _pressing = false);
    try {
      final path = await _recorder.stop();
      if (_sessionId != session) return; // 迟到回调丢弃
      if (cancelPending || path == null || recordStart == null) return;
      final durationMs = DateTime.now().difference(recordStart).inMilliseconds;
      if (durationMs < _minDurationMs) {
        if (mounted) _toast('说话时间太短');
        return;
      }
      final size = await _fileSize(path);
      widget.onDone(path, (durationMs / 1000).round(), size);
    } catch (_) {
      if (mounted) _toast('录音失败');
    } finally {
      _resetInteraction();
    }
  }

  /// 系统打断（来电等）：直接丢弃。
  Future<void> _cancel() async {
    _sessionId++; // 使在途回调失效
    _maxTimer?.cancel();
    _maxTimer = null;
    setState(() => _pressing = false);
    try {
      await _recorder.stop();
    } catch (_) {
      // 忽略
    }
    _resetInteraction();
  }

  void _resetInteraction() {
    _startY = null;
    _recordStart = null;
    if (mounted) {
      setState(() => _cancelPending = false);
    } else {
      _cancelPending = false;
    }
  }

  Future<int> _fileSize(String path) async {
    try {
      final file = File(path);
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 录音提示浮层（仅录音中显示）
        if (_recording)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: _cancelPending ? Colors.red : colors.card,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _cancelPending ? Icons.close : Icons.mic,
                  size: 20,
                  color: _cancelPending ? Colors.white : AppColors.lime,
                ),
                const SizedBox(width: 8),
                Text(
                  _cancelPending ? '松开手指，取消发送' : '上滑取消，松开发送',
                  style: TextStyle(
                    fontSize: 14,
                    color: _cancelPending ? Colors.white : colors.text,
                  ),
                ),
              ],
            ),
          ),
        // 按住说话按钮
        SizedBox(
          height: 40,
          width: double.infinity,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: (d) {
              _startY = d.globalPosition.dy;
              _start();
            },
            onLongPressMoveUpdate: (d) => _onMove(d.globalPosition.dy),
            onLongPressEnd: (_) => _stopAndSend(),
            onLongPressCancel: _cancel,
            child: Container(
              decoration: BoxDecoration(
                color: colors.card,
                borderRadius: BorderRadius.circular(20),
              ),
              alignment: Alignment.center,
              child: Text(
                _recording ? '松开 发送' : '按住 说话',
                style: TextStyle(
                  fontSize: 15,
                  color: _recording ? Colors.black : colors.text,
                  fontWeight: _recording ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
