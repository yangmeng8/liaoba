import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../../models/chat_message.dart';
import '../../models/im_conversation.dart';
import '../../models/im_face.dart';
import '../../models/im_ws_frame.dart';
import '../../services/api_client.dart';
import '../../services/im_api.dart';
import '../../services/im_websocket.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/chat_background.dart';
import '../../shared/json_utils.dart';
import '../../stores/conversation_store.dart';
import 'face_picker_sheet.dart';
import 'hold_to_talk_button.dart';

/// 聊天页（对应 H5 MessagePanel）：
/// - 首屏 maxId=null 拉最新一页；reverse ListView 向上滚动 maxId 游标翻页
/// - 发送：clientMessageId 幂等 + 占位气泡乐观更新（sending→sent/failed 可重试）
/// - 实时：WebSocket 通知匹配当前会话 → 防抖刷新最新页合并（撤回/回执/新消息统一覆盖）
/// - 已读：仅当最新 id 超过已上报位置才调接口（去重标记）
class ChatPage extends StatefulWidget {
  final ImConversationType type;

  /// 私聊对方 userId / 群 groupId / 频道 channelId。
  final int targetId;
  final String title;
  final String avatar;

  const ChatPage({
    super.key,
    required this.type,
    required this.targetId,
    required this.title,
    this.avatar = '',
  });

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  static const int _pageSize = 20;
  static const Duration _wsRefreshDebounce = Duration(milliseconds: 300);

  /// 媒体文件大小上限（16MB，与 H5 MESSAGE_MEDIA_MAX_BYTES 一致）。
  static const int _mediaMaxBytes = 16 * 1024 * 1024;

  /// 危险文件扩展名黑名单（对齐 H5 DANGEROUS_FILE_EXTENSIONS）。
  static const Set<String> _dangerousExtensions = {
    'exe', 'bat', 'cmd', 'com', 'cpl', 'dll', 'inf', 'ins', 'inx', 'isu',
    'job', 'js', 'jse', 'jar', 'lnk', 'msi', 'msp', 'mst', 'paf', 'pif',
    'ps1', 'reg', 'rgs', 'scr', 'sct', 'shb', 'shs', 'sh', 'vb', 'vbe',
    'vbs', 'ws', 'wsc', 'wsf', 'wsh', 'html', 'htm',
  };

  /// index 0 = 最新（配合 reverse ListView：index 0 渲染在底部）。
  List<ChatMessage> _messages = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _noMore = false;
  bool _sending = false;
  String? _error;

  /// 已读上报去重标记：最新 id 只有超过该位置才重复上报。
  int _lastReportedReadId = 0;

  /// 对方已读位置（私聊「已读/未读」小字）。
  int _peerMaxReadId = 0;

  /// 输入模式：false=键盘（文本框），true=语音（按住说话）。
  bool _voiceMode = false;

  /// 表情面板展开状态（展开在输入栏下方，输入框保持可见）。
  bool _facePanelOpen = false;

  /// 更多（+）面板展开状态：与表情面板、键盘三者互斥。
  bool _morePanelOpen = false;

  /// 语音播放器（会话内单实例，单条播放）。
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _playingVoiceKey;

  /// 频道消息全量缓存（频道无 list 接口，读 pull 结果内存分页）。
  List<ChatMessage>? _channelAll;

  final _scrollCtrl = ScrollController();
  final _inputCtrl = TextEditingController();
  final _inputFocus = FocusNode();
  StreamSubscription? _wsSub;
  Timer? _wsRefreshTimer;

  bool get _isPrivate => widget.type == ImConversationType.private;
  bool get _isGroup => widget.type == ImConversationType.group;
  bool get _isChannel => widget.type == ImConversationType.channel;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    // 点输入框弹键盘时自动收起表情面板和更多面板（否则键盘+面板同屏会溢出）
    _inputFocus.addListener(() {
      if (_inputFocus.hasFocus && (_facePanelOpen || _morePanelOpen)) {
        setState(() {
          _facePanelOpen = false;
          _morePanelOpen = false;
        });
      }
    });
    _wsSub = ImWebSocket.instance.notificationStream.listen((n) {
      if (_matchesCurrentConversation(n)) {
        // 防抖合并：短时间多条通知只刷新一次
        _wsRefreshTimer?.cancel();
        _wsRefreshTimer = Timer(_wsRefreshDebounce, _refreshLatest);
      }
    });
    _loadFirstPage();
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _wsRefreshTimer?.cancel();
    _scrollCtrl.dispose();
    _inputCtrl.dispose();
    _inputFocus.dispose();
    _audioPlayer.dispose();
    // 已读上报后让会话列表未读数归零（静默，失败忽略）
    if (_lastReportedReadId > 0) {
      ConversationStore.instance.load().catchError((Object _) {});
    }
    super.dispose();
  }

  /// reverse 列表：offset 0=底部，maxScrollExtent=顶部（最旧）。
  /// 接近顶部触发历史翻页；接近底部触发已读上报（回到底部场景）。
  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final pos = _scrollCtrl.position;
    if (pos.maxScrollExtent - pos.pixels < 200) {
      _loadOlder();
    }
    if (pos.pixels < 80) {
      _maybeMarkRead();
    }
  }

  // ==================== 数据加载 ====================

  Future<void> _loadFirstPage() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _query(maxId: null);
      if (!mounted) return;
      setState(() => _messages = list);
      if (list.length < _pageSize) _noMore = true;
      _maybeMarkRead();
      if (_isPrivate) _loadPeerRead();
    } catch (e) {
      if (mounted) {
        setState(() => _error = ApiClient.errorMessage(e));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 按会话类型分流查询（对应 H5 queryMessages）。
  Future<List<ChatMessage>> _query({int? maxId}) async {
    if (_isPrivate) {
      final list = await ImApi.getPrivateMessageList(
        receiverId: widget.targetId,
        limit: _pageSize,
        maxId: maxId,
      );
      return list.map(ChatMessage.fromPrivate).toList();
    }
    if (_isGroup) {
      final list = await ImApi.getGroupMessageList(
        groupId: widget.targetId,
        limit: _pageSize,
        maxId: maxId,
      );
      return list.map(ChatMessage.fromGroup).toList();
    }
    // 频道：无服务端 list 接口，读 pull 全量缓存后内存分页
    final all = await _ensureChannelAll();
    final filtered = maxId == null
        ? all
        : all.where((m) => (m.id ?? 0) < maxId).toList();
    return filtered.take(_pageSize).toList();
  }

  /// 频道消息全量缓存：循环 pull 拉全（上限 10 页，测试环境频道消息量少）。
  Future<List<ChatMessage>> _ensureChannelAll() async {
    if (_channelAll != null) return _channelAll!;
    final result = <ChatMessage>[];
    var minId = 0;
    for (var i = 0; i < 10; i++) {
      final page = await ImApi.pullChannelMessages(minId: minId, size: 100);
      if (page.isEmpty) break;
      result.addAll(page.map(ChatMessage.fromChannel));
      if (page.length < 100) break;
      minId = page.map((m) => m.id).reduce((a, b) => a < b ? a : b);
    }
    // id 倒序（最新在前）
    result.sort((a, b) => (b.id ?? 0).compareTo(a.id ?? 0));
    _channelAll = result;
    return result;
  }

  /// 历史翻页：maxId=已加载最早消息 id（不含），结果追加到列表尾部（更旧方向）。
  Future<void> _loadOlder() async {
    if (_loadingMore || _noMore || _loading) return;
    int? oldestId;
    for (final m in _messages) {
      if (m.id != null) {
        oldestId = m.id;
        break;
      }
    }
    if (oldestId == null) return; // 全是本地占位，无服务端游标
    setState(() => _loadingMore = true);
    try {
      final older = await _query(maxId: oldestId);
      if (!mounted) return;
      setState(() {
        _messages.addAll(older);
        if (older.length < _pageSize) _noMore = true;
      });
    } catch (_) {
      // 翻页失败静默：用户可继续滚动重试
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// WebSocket 触发的最新页刷新：拉最新一页与现有列表合并去重
  /// （新消息插入、撤回/回执覆盖更新；本地 sending/failed 占位保留）。
  Future<void> _refreshLatest() async {
    if (_loading) return;
    final nearBottom = !_scrollCtrl.hasClients || _scrollCtrl.offset < 80;
    try {
      final latest = await _query(maxId: null);
      if (!mounted) return;
      final map = <String, ChatMessage>{};
      for (final m in _messages) {
        map[m.key] = m;
      }
      for (final m in latest) {
        final exist = map[m.key];
        // 服务端消息覆盖同 id 旧值（撤回/回执变化）；本地占位（c$cmid）不被覆盖
        if (m.id != null || exist == null) {
          map[m.key] = m;
        }
      }
      final merged = map.values.toList()
        ..sort((a, b) {
          final ka = a.id ?? (1 << 62);
          final kb = b.id ?? (1 << 62);
          return kb.compareTo(ka); // id 倒序，本地占位视为最新
        });
      setState(() => _messages = merged);
      if (nearBottom) {
        _scrollToBottom();
        _maybeMarkRead();
      }
      if (_isPrivate) _loadPeerRead();
    } catch (_) {
      // 刷新失败静默：保持现有列表，等待下次通知或 resync
    }
  }

  /// 通知是否属于当前会话：类型匹配 + payload 任一目标字段命中 targetId
  /// （对方发消息时 senderId=targetId；我方消息 receiverId=targetId；已读事件含 peerId 等）。
  bool _matchesCurrentConversation(ImWsNotification n) {
    final expected = switch (widget.type) {
      ImConversationType.private => 1,
      ImConversationType.group => 2,
      ImConversationType.channel => 3,
    };
    if (n.conversationType != expected) return false;
    final p = n.payload;
    for (final key in [
      'receiverId',
      'groupId',
      'channelId',
      'senderId',
      'targetId',
      'peerId',
    ]) {
      if (p.containsKey(key) && asInt(p[key]) == widget.targetId) return true;
    }
    return false;
  }

  // ==================== 发送（乐观更新 + 幂等重试） ====================

  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    _inputCtrl.clear();
    final local = ChatMessage.localText(
      clientMessageId: generateClientMessageId(),
      text: text,
    );
    setState(() {
      _messages.insert(0, local);
      _noMore = _messages.length < _pageSize ? _noMore : _noMore;
    });
    _scrollToBottom();
    await _performSend(local);
  }

  /// 录音完成（HoldToTalkButton 回调）：上传 → 发送 VOICE 消息。
  Future<void> _onVoiceRecorded(
    String filePath,
    int durationSec,
    int sizeBytes,
  ) async {
    // 上传中先插本地占位（转圈）
    final clientMessageId = generateClientMessageId();
    final placeholder = ChatMessage.localVoice(
      clientMessageId: clientMessageId,
      payload: VoicePayload(url: '', duration: durationSec),
    );
    setState(() => _messages.insert(0, placeholder));
    _scrollToBottom();
    String url;
    try {
      url = await ImApi.uploadFile(filePath: filePath, directory: 'im/voice');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere(
          (m) => m.clientMessageId == clientMessageId,
        );
        if (i >= 0) {
          _messages[i] = placeholder.withStatus(ChatMessageStatus.failed);
        }
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(ApiClient.errorMessage(e))));
      return;
    }
    if (!mounted) return;
    // 上传成功：替换为带 url 的消息再走发送
    final local = ChatMessage.localVoice(
      clientMessageId: clientMessageId,
      payload: VoicePayload(url: url, duration: durationSec),
    );
    final i = _messages.indexWhere((m) => m.clientMessageId == clientMessageId);
    if (i >= 0) setState(() => _messages[i] = local);
    await _performSend(local);
  }

  /// 发送图片表情（表情面板点击 → 立即发送独立 FACE 消息）。
  Future<void> _sendFace(ImFaceItem item) async {
    final local = ChatMessage.localFace(
      clientMessageId: generateClientMessageId(),
      payload: FacePayload(
        url: item.url,
        name: item.name,
        width: item.width,
        height: item.height,
      ),
    );
    setState(() => _messages.insert(0, local));
    _scrollToBottom();
    await _performSend(local);
  }

  // ==================== 更多（+）面板：图片/视频/文件发送 ====================

  /// 切换更多（+）面板（与表情面板、键盘互斥）。
  void _toggleMorePanel() {
    FocusScope.of(context).unfocus();
    setState(() {
      _facePanelOpen = false;
      _morePanelOpen = !_morePanelOpen;
    });
  }

  /// 照片 / 拍摄：source 区分相册或相机。
  Future<void> _handleSendImage(ImageSource source) async {
    setState(() => _morePanelOpen = false);
    final picker = ImagePicker();
    final XFile? file;
    try {
      file = await picker.pickImage(source: source, imageQuality: 100);
    } catch (e) {
      if (mounted) _showSnack(ApiClient.errorMessage(e));
      return;
    }
    if (file == null) return;

    // 校验大小 ≤ 16MB
    final length = await file.length();
    if (length > _mediaMaxBytes) {
      if (mounted) _showSnack('图片大小不能超过 16MB');
      return;
    }

    // 获取本地图片宽高
    final bytes = await file.readAsBytes();
    final decoded = await decodeImageFromList(bytes);
    final width = decoded.width;
    final height = decoded.height;

    // 占位：url 先放本地路径，气泡直接预览本地图
    final clientMessageId = generateClientMessageId();
    final placeholder = ChatMessage.localImage(
      clientMessageId: clientMessageId,
      payload: ImagePayload(
        url: file.path,
        width: width,
        height: height,
        size: length,
      ),
    );
    setState(() => _messages.insert(0, placeholder));
    _scrollToBottom();

    String url;
    try {
      url = await ImApi.uploadFile(
        filePath: file.path,
        directory: 'im/message',
        onSendProgress: (sent, total) =>
            _updateProgress(clientMessageId, sent / total),
      );
    } catch (e) {
      _markFailed(clientMessageId, e);
      return;
    }
    if (!mounted) return;

    // 上传成功：替换内容为远程 URL，再走发送
    final local = ChatMessage.localImage(
      clientMessageId: clientMessageId,
      payload: ImagePayload(
        url: url,
        width: width,
        height: height,
        size: length,
      ),
    );
    _replaceMessage(local);
    await _performSend(local);
  }

  /// 视频：相册+相机，强制压缩；双文件上传（视频 90% + 封面 10%）。
  Future<void> _handleSendVideo() async {
    setState(() => _morePanelOpen = false);
    final picker = ImagePicker();
    final XFile? file;
    try {
      file = await picker.pickVideo(
        source: ImageSource.gallery,
        maxDuration: const Duration(minutes: 5),
      );
    } catch (e) {
      if (mounted) _showSnack(ApiClient.errorMessage(e));
      return;
    }
    if (file == null) return;

    final length = await file.length();
    if (length > _mediaMaxBytes) {
      if (mounted) _showSnack('视频大小不能超过 16MB');
      return;
    }

    // 读取视频元信息（时长/宽高）并提取封面图
    int duration = 0;
    int width = 0;
    int height = 0;
    String? coverPath;
    try {
      final controller = VideoPlayerController.file(File(file.path));
      await controller.initialize();
      duration = controller.value.duration.inSeconds;
      width = controller.value.size.width.toInt();
      height = controller.value.size.height.toInt();
      await controller.dispose();
      coverPath = await VideoThumbnail.thumbnailFile(
        video: file.path,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 320,
        quality: 75,
      );
    } catch (_) {
      // 元信息/封面提取失败不阻断发送
    }

    final clientMessageId = generateClientMessageId();
    final placeholder = ChatMessage.localVideo(
      clientMessageId: clientMessageId,
      payload: VideoPayload(
        url: file.path,
        coverUrl: coverPath ?? '',
        duration: duration,
        width: width,
        height: height,
        size: length,
      ),
    );
    setState(() => _messages.insert(0, placeholder));
    _scrollToBottom();

    // 上传视频（占 90% 进度）
    String url;
    try {
      url = await ImApi.uploadFile(
        filePath: file.path,
        directory: 'im/message',
        onSendProgress: (sent, total) =>
            _updateProgress(clientMessageId, (sent / total) * 0.9),
      );
    } catch (e) {
      _markFailed(clientMessageId, e);
      return;
    }
    if (!mounted) return;

    // 上传封面（占 10% 进度）；封面失败不阻断
    String coverUrl = '';
    if (coverPath != null) {
      try {
        coverUrl = await ImApi.uploadFile(
          filePath: coverPath,
          directory: 'im/message',
          onSendProgress: (sent, total) =>
              _updateProgress(clientMessageId, 0.9 + (sent / total) * 0.1),
        );
      } catch (_) {
        // 封面上传失败降级：coverUrl 为空，接收端显示首帧
      }
    }
    if (!mounted) return;

    final local = ChatMessage.localVideo(
      clientMessageId: clientMessageId,
      payload: VideoPayload(
        url: url,
        coverUrl: coverUrl,
        duration: duration,
        width: width,
        height: height,
        size: length,
      ),
    );
    _replaceMessage(local);
    await _performSend(local);
  }

  /// 文件：扩展名黑名单校验 + 16MB 上限。
  Future<void> _handleSendFile() async {
    setState(() => _morePanelOpen = false);
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles();
    } catch (e) {
      if (mounted) _showSnack(ApiClient.errorMessage(e));
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final f = result.files.first;
    final path = f.path;
    if (path == null) return;

    // 危险扩展名黑名单
    final ext = (f.extension ?? '').toLowerCase();
    if (_dangerousExtensions.contains(ext)) {
      if (mounted) _showSnack('该类型文件不支持发送');
      return;
    }

    final size = f.size;
    if (size > _mediaMaxBytes) {
      if (mounted) _showSnack('文件大小不能超过 16MB');
      return;
    }

    final clientMessageId = generateClientMessageId();
    final placeholder = ChatMessage.localFile(
      clientMessageId: clientMessageId,
      payload: FilePayload(
        url: path,
        name: f.name,
        size: size,
        type: ext,
      ),
    );
    setState(() => _messages.insert(0, placeholder));
    _scrollToBottom();

    String url;
    try {
      url = await ImApi.uploadFile(
        filePath: path,
        directory: 'im/file',
        fileName: f.name,
        onSendProgress: (sent, total) =>
            _updateProgress(clientMessageId, sent / total),
      );
    } catch (e) {
      _markFailed(clientMessageId, e);
      return;
    }
    if (!mounted) return;

    final local = ChatMessage.localFile(
      clientMessageId: clientMessageId,
      payload: FilePayload(
        url: url,
        name: f.name,
        size: size,
        type: ext,
      ),
    );
    _replaceMessage(local);
    await _performSend(local);
  }

  /// 更新指定消息的上传进度。
  void _updateProgress(String clientMessageId, double progress) {
    if (!mounted) return;
    final p = progress.clamp(0.0, 1.0);
    setState(() {
      final i = _messages.indexWhere(
        (m) => m.clientMessageId == clientMessageId,
      );
      if (i >= 0) {
        _messages[i] = _messages[i].withProgress(p);
      }
    });
  }

  /// 将占位消息替换为上传后的正式消息（保留位置）。
  void _replaceMessage(ChatMessage local) {
    if (!mounted) return;
    setState(() {
      final i = _messages.indexWhere(
        (m) => m.clientMessageId == local.clientMessageId,
      );
      if (i >= 0) _messages[i] = local.withProgress(null);
    });
  }

  /// 上传失败：标记为 failed + 提示。
  void _markFailed(String clientMessageId, Object e) {
    if (!mounted) return;
    setState(() {
      final i = _messages.indexWhere(
        (m) => m.clientMessageId == clientMessageId,
      );
      if (i >= 0) {
        _messages[i] = _messages[i]
            .withStatus(ChatMessageStatus.failed)
            .withProgress(null);
      }
    });
    _showSnack(ApiClient.errorMessage(e));
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 表情面板选中的 emoji：插入输入框光标处（随文本消息一起发送）。
  void _insertEmoji(String emoji) {
    final sel = _inputCtrl.selection;
    final text = _inputCtrl.text;
    if (text.length + emoji.length > 1000) return; // 与 H5 上限一致
    if (sel.isValid && !sel.isCollapsed) {
      // 有选区：替换选区
      final newText = text.replaceRange(sel.start, sel.end, emoji);
      _inputCtrl.text = newText;
      _inputCtrl.selection = TextSelection.collapsed(
        offset: sel.start + emoji.length,
      );
    } else if (sel.isValid) {
      final newText = text.replaceRange(sel.baseOffset, sel.baseOffset, emoji);
      _inputCtrl.text = newText;
      _inputCtrl.selection = TextSelection.collapsed(
        offset: sel.baseOffset + emoji.length,
      );
    } else {
      _inputCtrl.text = text + emoji;
    }
    setState(() {}); // 刷新输入栏状态（输入框在面板上方，插入内容直接可见）
  }

  /// 播放/停止语音（单实例播放器：再点同一条或切换均先停）。
  Future<void> _togglePlayVoice(ChatMessage message, String url) async {
    final key = message.key;
    if (_playingVoiceKey == key) {
      await _audioPlayer.stop();
      if (mounted) setState(() => _playingVoiceKey = null);
      return;
    }
    try {
      await _audioPlayer.stop();
      await _audioPlayer.setUrl(url);
      _audioPlayer.playerStateStream.listen((state) {
        if ((state.processingState == ProcessingState.completed) && mounted) {
          setState(() => _playingVoiceKey = null);
        }
      });
      if (mounted) setState(() => _playingVoiceKey = key);
      await _audioPlayer.play();
    } catch (_) {
      if (mounted) {
        setState(() => _playingVoiceKey = null);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('语音播放失败')));
      }
    }
  }

  /// 执行发送：成功用服务端消息替换占位；失败置 failed（点击气泡可重试，
  /// 复用同一 clientMessageId，服务端幂等保证不重复）。
  Future<void> _performSend(ChatMessage local) async {
    setState(() => _sending = true);
    try {
      ChatMessage? server;
      if (_isPrivate) {
        final m = await ImApi.sendPrivateMessage(
          clientMessageId: local.clientMessageId,
          receiverId: widget.targetId,
          type: local.type,
          content: local.content,
        );
        server = m != null ? ChatMessage.fromPrivate(m) : null;
      } else if (_isGroup) {
        final m = await ImApi.sendGroupMessage(
          clientMessageId: local.clientMessageId,
          groupId: widget.targetId,
          type: local.type,
          content: local.content,
        );
        server = m != null ? ChatMessage.fromGroup(m) : null;
      }
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere(
          (m) =>
              m.key == local.key || m.clientMessageId == local.clientMessageId,
        );
        if (i >= 0) {
          _messages[i] = server ?? local.withStatus(ChatMessageStatus.sent);
        }
      });
      _maybeMarkRead();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final i = _messages.indexWhere(
          (m) => m.clientMessageId == local.clientMessageId,
        );
        if (i >= 0) _messages[i] = local.withStatus(ChatMessageStatus.failed);
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(ApiClient.errorMessage(e))));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 重试失败消息：媒体消息若上传失败（url 仍为本地路径），提示重新选择；
  /// 其余情况（上传成功但发送失败）直接重走发送接口。
  void _retryMessage(ChatMessage message) {
    if (message.status != ChatMessageStatus.failed) return;
    final isMedia = message.type == ChatMsgType.image ||
        message.type == ChatMsgType.video ||
        message.type == ChatMsgType.file;
    if (isMedia) {
      final url = message.contentMap['url']?.toString() ?? '';
      final isLocal = url.startsWith('/') ||
          url.startsWith('file://') ||
          !url.startsWith('http');
      if (isLocal) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('文件已失效，请重新选择发送')));
        return;
      }
    }
    _performSend(message);
  }

  // ==================== 已读 ====================

  /// 已读上报（去重）：最新服务端消息 id 超过上次上报位置才调接口。
  void _maybeMarkRead() {
    int? latestId;
    for (final m in _messages) {
      if (m.id != null) {
        latestId = m.id;
        break;
      }
    }
    if (latestId == null || latestId <= _lastReportedReadId) return;
    _lastReportedReadId = latestId;
    final targetId = widget.targetId;
    Future<void> req;
    if (_isPrivate) {
      req = ImApi.markPrivateRead(receiverId: targetId, messageId: latestId);
    } else if (_isGroup) {
      req = ImApi.markGroupRead(groupId: targetId, messageId: latestId);
    } else {
      req = ImApi.markChannelRead(channelId: targetId, messageId: latestId);
    }
    req.catchError((Object _) {}); // 上报失败静默，下次触发会重试
  }

  /// 拉取对方已读位置（私聊「已读/未读」小字）。
  Future<void> _loadPeerRead() async {
    if (!_isPrivate) return;
    try {
      final v = await ImApi.getPrivateMaxReadMessageId(peerId: widget.targetId);
      if (mounted && v != _peerMaxReadId) {
        setState(() => _peerMaxReadId = v);
      }
    } catch (_) {
      // 静默：已读小字非关键功能
    }
  }

  // ==================== 撤回 ====================

  Future<void> _recall(ChatMessage m) async {
    final id = m.id;
    if (id == null) return;
    try {
      if (_isGroup) {
        await ImApi.recallGroupMessage(id: id);
      } else {
        await ImApi.recallPrivateMessage(id: id);
      }
      // 服务端会向会话推 RECALL 通知 → _refreshLatest 会把该消息
      // 更新为撤回信号消息；这里先本地立即刷新一次，体验更即时
      await _refreshLatest();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(ApiClient.errorMessage(e))));
      }
    }
  }

  // ==================== UI ====================

  void _scrollToBottom() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      0,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      // 点击空白收起键盘与表情面板
      behavior: HitTestBehavior.translucent,
      onTap: () {
        FocusScope.of(context).unfocus();
        if (_facePanelOpen || _morePanelOpen) {
          setState(() {
            _facePanelOpen = false;
            _morePanelOpen = false;
          });
        }
      },
      child: Scaffold(
        backgroundColor: colors.bg,
        // 关闭 Scaffold 自动缩放，改用手动 viewInsets padding：
        // 键盘与表情面板严格互斥（面板打开时 padding 恒为 0），
        // 避免键盘收起动画与面板展开叠加导致 Column 溢出
        resizeToAvoidBottomInset: false,
        // 浅色模式用外观设置的默认聊天背景（渐变+点阵）；深色模式保持纯色
        body: Stack(
          children: [
            if (Theme.of(context).brightness == Brightness.light)
              Positioned.fill(
                child: ChatBackgroundLayer(bg: defaultChatBackground),
              ),
            Column(
              children: [
                _buildHeader(colors),
                Expanded(child: _buildMessageList(colors)),
                // 输入栏保持在表情面板头顶（微信布局）；键盘弹出时悬于键盘上方
                Padding(
                  padding: EdgeInsets.only(
                    bottom: (_facePanelOpen || _morePanelOpen)
                        ? 0
                        : MediaQuery.of(context).viewInsets.bottom,
                  ),
                  child: _buildInputBar(colors),
                ),
                // 内嵌表情面板：展开时显示在输入栏下方
                if (_facePanelOpen)
                  FacePickerSheet(
                    onEmojiSelected: (emoji) => _insertEmoji(emoji),
                    onFaceSelected: (item) {
                      _sendFace(item);
                      setState(() => _facePanelOpen = false);
                    },
                  ),
                // 内嵌更多（+）面板：与表情面板互斥
                if (_morePanelOpen) _buildMorePanel(colors),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 自定义头部：返回 + 居中标题 + 更多（占位）。surface 底色对齐项目导航。
  Widget _buildHeader(ThemeColors colors) {
    return Container(
      color: colors.surface,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 48,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, size: 20),
                color: colors.surfaceText,
                onPressed: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: colors.surfaceText,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.more_horiz, size: 24),
                color: colors.surfaceText,
                onPressed: () {}, // TODO: 会话设置/群信息
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageList(ThemeColors colors) {
    if (_loading && _messages.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.lime),
      );
    }
    if (_error != null && _messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, style: TextStyle(fontSize: 14, color: colors.muted)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _loadFirstPage,
              child: const Text(
                '点击重试',
                style: TextStyle(color: AppColors.lime),
              ),
            ),
          ],
        ),
      );
    }
    if (_messages.isEmpty) {
      return Center(
        child: Text(
          '暂无消息，发送第一条吧',
          style: TextStyle(fontSize: 14, color: colors.muted),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollCtrl,
      reverse: true, // index 0 渲染在底部：新消息 insert(0) 即"滚到底"
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      itemCount: _messages.length + (_loadingMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _messages.length) {
          // reverse 列表尾部（顶部）的加载指示
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.lime,
                ),
              ),
            ),
          );
        }
        final message = _messages[index];
        // 更旧方向的下一条（reverse：index+1 是更早消息），用于时间分隔判断
        final older = index + 1 < _messages.length
            ? _messages[index + 1]
            : null;
        return _MessageItem(
          message: message,
          older: older,
          showReadState: _isPrivate,
          peerMaxReadId: _peerMaxReadId,
          playingVoiceKey: _playingVoiceKey,
          onPlayVoice: (m) {
            final url = m.voicePayload?.url;
            if (url != null && url.isNotEmpty) {
              _togglePlayVoice(m, normalizeFaceUrl(url));
            }
          },
          onRetry: () => _retryMessage(message),
          onRecall: () => _recall(message),
        );
      },
    );
  }

  /// 底部输入区：频道为广播订阅，只读不显示输入框。
  Widget _buildInputBar(ThemeColors colors) {
    if (_isChannel) {
      return SafeArea(
        top: false,
        child: Container(
          color: colors.surface,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12),
          alignment: Alignment.center,
          child: Text(
            '频道消息仅推送，不支持回复',
            style: TextStyle(fontSize: 13, color: colors.muted),
          ),
        ),
      );
    }
    final isLight = Theme.of(context).brightness == Brightness.light;
    return SafeArea(
      top: false,
      // 面板展开时输入栏紧贴面板（去掉安全区空隙），底部安全区由面板自身处理
      bottom: !_facePanelOpen && !_morePanelOpen,
      child: Container(
        // 与聊天背景渐变底端色一致（无缝融入）；深色模式回纯色
        color: isLight ? const Color(0xFFEDE4D8) : colors.bg,
        // 底部 10 + SafeArea：保证 home indicator 区域不贴边
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: Row(
          children: [
            // 语音/键盘模式切换
            _buildModeToggle(colors),
            const SizedBox(width: 6),
            Expanded(
              child: _voiceMode
                  ? HoldToTalkButton(onDone: _onVoiceRecorded)
                  : TextField(
                      controller: _inputCtrl,
                      focusNode: _inputFocus,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      style: TextStyle(fontSize: 15, color: colors.text),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '输入消息...',
                        hintStyle: TextStyle(fontSize: 15, color: colors.muted),
                        filled: true,
                        // 比输入栏底色略深的灰米色，形成胶囊区分
                        fillColor: isLight
                            ? const Color(0xFFE4E0D8)
                            : colors.card,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 6),
            // 表情按钮：切换表情面板（emoji 插入输入框 / 图片表情直接发送）
            IconButton(
              onPressed: _toggleFacePanel,
              icon: Icon(
                Icons.emoji_emotions_outlined,
                size: 28,
                color: _facePanelOpen ? AppColors.lime : colors.text,
              ),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: 2),
            // 更多（+）：图片/视频/文件等扩展入口
            IconButton(
              onPressed: _toggleMorePanel,
              icon: Icon(
                Icons.add_circle_outline,
                size: 28,
                color: _morePanelOpen ? AppColors.lime : colors.text,
              ),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ),
    );
  }

  /// 语音/键盘切换按钮。
  Widget _buildModeToggle(ThemeColors colors) {
    return IconButton(
      onPressed: () {
        FocusScope.of(context).unfocus();
        setState(() => _voiceMode = !_voiceMode);
      },
      icon: Icon(
        _voiceMode ? Icons.keyboard_outlined : Icons.mic_none,
        size: 24,
        color: colors.muted,
      ),
      visualDensity: VisualDensity.compact,
    );
  }

  /// 切换表情面板展开/收起（展开时收起键盘，输入框保持在面板上方）。
  void _toggleFacePanel() {
    FocusScope.of(context).unfocus();
    setState(() {
      _morePanelOpen = false;
      _facePanelOpen = !_facePanelOpen;
    });
  }

  /// 更多（+）面板：照片/拍摄/视频/文件 四宫格。
  Widget _buildMorePanel(ThemeColors colors) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final panelColor =
        isLight ? const Color(0xFFEDE4D8) : colors.bg;
    final height = MediaQuery.of(context).size.height * 0.32;
    return Container(
      height: height,
      color: panelColor,
      child: SafeArea(
        top: false,
        child: GridView.count(
          crossAxisCount: 4,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 0.85,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _buildMoreItem(
              icon: Icons.photo_library_outlined,
              label: '照片',
              color: const Color(0xFFFF7A45),
              onTap: () => _handleSendImage(ImageSource.gallery),
            ),
            _buildMoreItem(
              icon: Icons.photo_camera_outlined,
              label: '拍摄',
              color: const Color(0xFF34C759),
              onTap: () => _handleSendImage(ImageSource.camera),
            ),
            _buildMoreItem(
              icon: Icons.videocam_outlined,
              label: '视频',
              color: const Color(0xFF5AC8FA),
              onTap: _handleSendVideo,
            ),
            _buildMoreItem(
              icon: Icons.insert_drive_file_outlined,
              label: '文件',
              color: const Color(0xFFAF52DE),
              onTap: _handleSendFile,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMoreItem({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, size: 28, color: color),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: context.colors.text),
          ),
        ],
      ),
    );
  }
}

/// 单条消息渲染：时间分隔 + 气泡（含状态角标/已读小字/长按菜单）。
class _MessageItem extends StatelessWidget {
  final ChatMessage message;
  final ChatMessage? older;

  /// 是否显示已读小字（私聊）。
  final bool showReadState;
  final int peerMaxReadId;

  /// 当前正在播放的语音消息 key（null=无播放）。
  final String? playingVoiceKey;

  /// 点击语音气泡（播放/停止）。
  final ValueChanged<ChatMessage> onPlayVoice;
  final VoidCallback onRetry;
  final VoidCallback onRecall;

  const _MessageItem({
    required this.message,
    required this.older,
    required this.showReadState,
    required this.peerMaxReadId,
    required this.playingVoiceKey,
    required this.onPlayVoice,
    required this.onRetry,
    required this.onRecall,
  });

  /// 与更旧一条间隔超过 5 分钟才显示时间分隔。
  bool get _showTimeDivider {
    final a = message.sendTime;
    final b = older?.sendTime;
    if (a == null || b == null) return true;
    return a.difference(b).inMinutes.abs() > 5;
  }

  String _formatTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final children = <Widget>[
      if (_showTimeDivider && message.sendTime != null)
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 6),
          child: Center(
            child: Text(
              _formatTime(message.sendTime!.toLocal()),
              style: TextStyle(fontSize: 11, color: colors.muted),
            ),
          ),
        ),
      if (message.isCenteredNotice)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Center(
            child: Text(
              message.displayText,
              style: TextStyle(fontSize: 12, color: colors.muted),
            ),
          ),
        )
      else
        _buildBubble(context, colors),
    ];
    return Column(children: children);
  }

  Widget _buildBubble(BuildContext context, ThemeColors colors) {
    final isSelf = message.isSelf;
    final sending = message.status == ChatMessageStatus.sending;
    final failed = message.status == ChatMessageStatus.failed;

    // 已读小字（仅私聊自己的已确认消息）
    Widget? readState;
    if (showReadState && isSelf && message.id != null) {
      final read = message.id! <= peerMaxReadId;
      readState = Padding(
        padding: const EdgeInsets.only(top: 2, right: 4),
        child: Text(
          read ? '已读' : '未读',
          style: TextStyle(fontSize: 10, color: colors.muted),
        ),
      );
    }

    // 气泡内容按消息类型分发：语音条 / 表情大图 / 图片 / 视频 / 文件 / 文本
    final Widget content;
    if (message.type == ChatMsgType.voice && message.voicePayload != null) {
      content = _VoiceBubbleBody(
        payload: message.voicePayload!,
        playing: playingVoiceKey == message.key,
        selfColor: isSelf,
        onTap: () => onPlayVoice(message),
      );
    } else if (message.type == ChatMsgType.face &&
        message.facePayload != null) {
      content = _FaceBubbleBody(
        payload: message.facePayload!,
        loading: sending,
      );
    } else if (message.type == ChatMsgType.image &&
        message.imagePayload != null) {
      content = _ImageBubbleBody(
        payload: message.imagePayload!,
        progress: message.progress,
      );
    } else if (message.type == ChatMsgType.video &&
        message.videoPayload != null) {
      content = _VideoBubbleBody(
        payload: message.videoPayload!,
        progress: message.progress,
      );
    } else if (message.type == ChatMsgType.file &&
        message.filePayload != null) {
      content = _FileBubbleBody(
        payload: message.filePayload!,
        progress: message.progress,
      );
    } else {
      content = Text(
        message.displayText,
        style: TextStyle(
          fontSize: 15,
          height: 1.35,
          color: isSelf ? Colors.black : colors.text,
        ),
      );
    }

    final bubble = GestureDetector(
      // 失败点击重试；正常消息长按弹菜单
      onTap: failed ? onRetry : null,
      onLongPress: message.operable ? () => _showActions(context) : null,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: (message.type == ChatMsgType.face ||
                message.type == ChatMsgType.image ||
                message.type == ChatMsgType.video)
            ? EdgeInsets
                  .zero // 表情/图片/视频大图不加内边距
            : const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: isSelf ? AppColors.lime : colors.card,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(isSelf ? 12 : 4),
            bottomRight: Radius.circular(isSelf ? 4 : 12),
          ),
        ),
        child: content,
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: isSelf
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (isSelf) ..._buildStateIcon(colors, sending, failed),
          Flexible(
            child: Column(
              crossAxisAlignment: isSelf
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [bubble, ?readState],
            ),
          ),
          if (!isSelf) ..._buildStateIcon(colors, sending, failed),
        ],
      ),
    );
  }

  /// 状态角标：sending 转圈；failed 红色感叹号（可点击重试）。
  List<Widget> _buildStateIcon(ThemeColors colors, bool sending, bool failed) {
    if (sending) {
      return const [
        Padding(
          padding: EdgeInsets.only(right: 6),
          child: SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
        ),
      ];
    }
    if (failed) {
      return [
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: GestureDetector(
            onTap: onRetry,
            child: Icon(
              Icons.error_outline,
              size: 16,
              color: Colors.red.shade600,
            ),
          ),
        ),
      ];
    }
    return const [];
  }

  void _showActions(BuildContext context) {
    HapticFeedback.lightImpact();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.colors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.content_copy, size: 22),
              title: const Text('复制', style: TextStyle(fontSize: 15)),
              onTap: () {
                Clipboard.setData(ClipboardData(text: message.displayText));
                Navigator.pop(sheetCtx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.undo, size: 22),
              title: const Text('撤回', style: TextStyle(fontSize: 15)),
              onTap: () {
                Navigator.pop(sheetCtx);
                onRecall();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 语音气泡体：宽度按时长线性映射（80 + duration×10，封顶 220），
/// 喇叭图标 + 时长文本；点击播放/停止（对应 H5 message-bubble 语音条）。
class _VoiceBubbleBody extends StatelessWidget {
  final VoicePayload payload;
  final bool playing;
  final bool selfColor;
  final VoidCallback onTap;

  const _VoiceBubbleBody({
    required this.payload,
    required this.playing,
    required this.selfColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final width = (80 + payload.duration * 10).clamp(80, 220).toDouble();
    final fg = selfColor ? Colors.black : context.colors.text;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: width,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // 左侧图标（对方消息）/右侧图标（自己消息，保持喇叭朝向聊天方）
            if (!selfColor)
              Icon(
                playing ? Icons.graphic_eq : Icons.play_arrow,
                size: 22,
                color: selfColor ? Colors.black : context.colors.muted,
              ),
            Text(
              '${payload.duration}"',
              style: TextStyle(fontSize: 14, color: fg),
            ),
            if (selfColor)
              Icon(
                playing ? Icons.graphic_eq : Icons.play_arrow,
                size: 22,
                color: Colors.black,
              ),
          ],
        ),
      ),
    );
  }
}

/// 表情气泡体：大图等比显示（约 120px），加载失败降级显示 [表情名] 文本。
class _FaceBubbleBody extends StatelessWidget {
  final FacePayload payload;
  final bool loading;

  const _FaceBubbleBody({required this.payload, required this.loading});

  @override
  Widget build(BuildContext context) {
    // 等比：限制最大边 120
    var w = payload.width.toDouble();
    var h = payload.height.toDouble();
    if (w <= 0 || h <= 0) {
      w = 120;
      h = 120;
    } else if (w > h) {
      h = h * 120 / w;
      w = 120;
    } else {
      w = w * 120 / h;
      h = 120;
    }
    final url = normalizeFaceUrl(payload.url);
    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              url,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => Container(
                alignment: Alignment.center,
                color: context.colors.divider,
                child: Text(
                  payload.name.isNotEmpty ? '[${payload.name}]' : '[表情]',
                  style: TextStyle(fontSize: 12, color: context.colors.muted),
                ),
              ),
            ),
          ),
          if (loading)
            Container(
              color: Colors.black26,
              child: const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 判断是否为本地文件路径（上传期间 url 为本地路径，用 Image.file 预览）。
bool _isLocalPath(String url) =>
    url.startsWith('/') ||
    url.startsWith('file://') ||
    !url.startsWith('http');

/// 图片气泡体：等比显示（最大边 ~200），本地路径用 Image.file，远程用 Image.network；
/// 上传中覆盖进度条。
class _ImageBubbleBody extends StatelessWidget {
  final ImagePayload payload;
  final double? progress;

  const _ImageBubbleBody({required this.payload, required this.progress});

  @override
  Widget build(BuildContext context) {
    var w = payload.width.toDouble();
    var h = payload.height.toDouble();
    if (w <= 0 || h <= 0) {
      w = 200;
      h = 200;
    } else if (w > h) {
      h = h * 200 / w;
      w = 200;
    } else {
      w = w * 200 / h;
      h = 200;
    }
    final url = normalizeFaceUrl(payload.url);
    final img = _isLocalPath(url)
        ? Image.file(File(url), fit: BoxFit.cover)
        : Image.network(url, fit: BoxFit.cover, errorBuilder: (_, _, _) {
            return Container(
              color: context.colors.divider,
              alignment: Alignment.center,
              child: Text('[图片]',
                  style: TextStyle(fontSize: 12, color: context.colors.muted)),
            );
          });
    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(12), child: img),
          if (progress != null) _buildProgressOverlay(progress!),
        ],
      ),
    );
  }
}

/// 视频气泡体：显示封面图（本地/远程）+ 播放按钮 + 时长；上传中覆盖进度条。
class _VideoBubbleBody extends StatelessWidget {
  final VideoPayload payload;
  final double? progress;

  const _VideoBubbleBody({required this.payload, required this.progress});

  @override
  Widget build(BuildContext context) {
    var w = payload.width.toDouble();
    var h = payload.height.toDouble();
    if (w <= 0 || h <= 0) {
      w = 200;
      h = 150;
    } else if (w > h) {
      h = h * 200 / w;
      w = 200;
    } else {
      w = w * 150 / h;
      h = 150;
    }
    final cover = payload.coverUrl;
    Widget coverImg;
    if (cover.isEmpty) {
      coverImg = Container(
        color: Colors.black87,
        alignment: Alignment.center,
        child: const Icon(Icons.play_circle_fill, size: 48, color: Colors.white70),
      );
    } else if (_isLocalPath(cover)) {
      coverImg = Image.file(File(cover), fit: BoxFit.cover);
    } else {
      coverImg = Image.network(normalizeFaceUrl(cover), fit: BoxFit.cover,
          errorBuilder: (_, _, _) {
        return Container(
          color: Colors.black87,
          alignment: Alignment.center,
          child: const Icon(Icons.play_circle_fill,
              size: 48, color: Colors.white70),
        );
      });
    }
    final dur = payload.duration;
    final durText = dur > 0
        ? '${dur ~/ 60}:${(dur % 60).toString().padLeft(2, '0')}'
        : '';
    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(12), child: coverImg),
          const Center(
            child: Icon(Icons.play_circle_fill, size: 44, color: Colors.white),
          ),
          if (durText.isNotEmpty)
            Positioned(
              right: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  durText,
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              ),
            ),
          if (progress != null) _buildProgressOverlay(progress!),
        ],
      ),
    );
  }
}

/// 文件气泡体：文件图标 + 文件名 + 大小；上传中底部进度条。
class _FileBubbleBody extends StatelessWidget {
  final FilePayload payload;
  final double? progress;

  const _FileBubbleBody({required this.payload, required this.progress});

  String get _sizeText {
    final s = payload.size;
    if (s <= 0) return '';
    if (s < 1024) return '${s}B';
    if (s < 1024 * 1024) return '${(s / 1024).toStringAsFixed(1)}KB';
    return '${(s / 1024 / 1024).toStringAsFixed(1)}MB';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      width: 240,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFFAF52DE).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.insert_drive_file,
                    size: 24, color: Color(0xFFAF52DE)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      payload.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          color: colors.text,
                          fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _sizeText,
                      style: TextStyle(fontSize: 11, color: colors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (progress != null) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: progress!.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: colors.divider,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(AppColors.lime),
            ),
          ],
        ],
      ),
    );
  }
}

/// 上传进度遮罩（图片/视频气泡覆盖在底部的进度条）。
Widget _buildProgressOverlay(double progress) {
  return Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: LinearProgressIndicator(
      value: progress.clamp(0.0, 1.0),
      minHeight: 3,
      backgroundColor: Colors.black26,
      valueColor: const AlwaysStoppedAnimation<Color>(AppColors.lime),
    ),
  );
}
