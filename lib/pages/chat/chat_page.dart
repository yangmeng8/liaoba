import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_view/photo_view.dart';
import 'package:video_compress/video_compress.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

import '../../models/chat_message.dart';
import '../../models/im_conversation.dart';
import '../../models/im_face.dart';
import '../../models/im_ws_frame.dart';
import '../../services/api_client.dart';
import '../../services/auth_api.dart';
import '../../services/auth_manager.dart';
import '../../services/im_api.dart';
import '../../services/im_websocket.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/chat_background.dart';
import '../../shared/im_avatar.dart';
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

  /// 服务器 nginx client_max_body_size 实测约 10MB（9MB 通过 / 10MB 413），
  /// 客户端按 9MB 拦截留余量（multipart 还有少量协议开销）。
  static const int _serverMaxBytes = 9 * 1024 * 1024;

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
  String? _loadingVoiceKey; // 语音下载/加载中的消息（气泡显示转圈）

  /// 语音本地缓存：远程 url → 本地文件路径（.webm 等需下载重命名的场景）。
  /// 语音气泡渲染时后台预热，点击时命中缓存即秒播。
  final Map<String, String> _voiceLocalCache = {};
  final Map<String, Future<String>> _voiceResolving = {}; // 并发下载去重
  HttpClient? _voiceDlClient; // 复用连接池：同域名 TLS 握手只做一次

  /// 文件消息下载进度：消息 key → 0~1（卡片内实时进度条）。
  final Map<String, double> _fileDownloadProgress = {};

  /// 频道消息全量缓存（频道无 list 接口，读 pull 结果内存分页）。
  List<ChatMessage>? _channelAll;

  /// 好友索引：friendUserId → ImFriend（群聊消息发送者头像/昵称解析用）。
  /// 拉取失败时静默降级为字母色卡兜底。
  final Map<int, ImFriend> _friends = {};

  /// 群成员索引：userId → ImGroupMember（群聊发送者头像/昵称解析，
  /// 优先于好友表，对齐 H5 getSenderAvatar 的降级顺序）。
  final Map<int, ImGroupMember> _groupMembers = {};

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
    // 群聊/频道：拉好友表建发送者头像/昵称索引（私聊直接用会话传入的头像）
    if (!_isPrivate) _loadFriends();
    // 群聊：拉群成员表（头像解析优先于好友表，对齐 H5 降级顺序）
    if (_isGroup) _loadGroupMembers();
    // 自己的头像/昵称（登录用户资料，null=尚未拉取过）
    _loadSelfProfile();
    _loadFirstPage();
  }

  /// 拉取好友列表建索引（对齐 H5 getSenderAvatar 降级链的「好友表」层）。
  Future<void> _loadFriends() async {
    try {
      final friends = await ImApi.getFriendList();
      if (!mounted) return;
      setState(() {
        for (final f in friends) {
          _friends[f.friendUserId] = f;
        }
      });
    } catch (_) {
      // 静默：降级为字母色卡兜底
    }
  }

  /// 拉取群成员表建索引（降级链的「群成员表」层，优先于好友表）。
  Future<void> _loadGroupMembers() async {
    try {
      final members = await ImApi.getGroupMemberList(
        groupId: widget.targetId,
      );
      if (!mounted) return;
      setState(() {
        for (final m in members) {
          _groupMembers[m.userId] = m;
        }
      });
    } catch (_) {
      // 静默：降级为好友表 / 字母色卡
    }
  }

  /// 拉取登录用户资料（自己的头像/昵称，来自权限信息接口）。
  Future<void> _loadSelfProfile() async {
    if (AuthManager.instance.avatar != null) return; // 已缓存
    try {
      await AuthApi.loadUserProfile();
      if (mounted) setState(() {}); // 头像从色卡刷新为真实头像
    } catch (_) {
      // 静默：保持色卡兜底
    }
  }

  /// 发送人头像 URL（对齐 H5 senderAvatar 解析链）：
  /// 自己 → 权限信息接口缓存的头像；私聊 → 会话聚合传入的对方头像；
  /// 群聊 → 群成员表 → 好友表 → 空串（色卡兜底）。
  String _avatarUrlFor(ChatMessage m) {
    if (m.isSelf) return AuthManager.instance.avatar ?? '';
    if (_isPrivate) return widget.avatar;
    return _groupMembers[m.senderId]?.avatar ??
        _friends[m.senderId]?.avatar ??
        '';
  }

  /// 发送人名字（色卡取字/配色的稳定 key，用真实昵称而非备注）：
  /// 自己 → 登录用户昵称；私聊 → 会话标题；
  /// 群聊 → 群成员昵称 → 好友昵称 → '用户{senderId}'。
  String _avatarNameFor(ChatMessage m) {
    if (m.isSelf) {
      final n = AuthManager.instance.nickname;
      return (n != null && n.isNotEmpty) ? n : '我';
    }
    if (_isPrivate) return widget.title;
    final gm = _groupMembers[m.senderId];
    if (gm != null && gm.nickname.isNotEmpty) return gm.nickname;
    final f = _friends[m.senderId];
    if (f != null && f.nickname.isNotEmpty) return f.nickname;
    return '用户${m.senderId}';
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    _wsRefreshTimer?.cancel();
    _scrollCtrl.dispose();
    _inputCtrl.dispose();
    _inputFocus.dispose();
    _audioPlayer.dispose();
    _voiceDlClient?.close(force: true);
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
      // 选图即压缩（对齐 H5 compressed 语义）：最长边 2560 + 质量 80，
      // 相机原图可达 8~12MB，超过服务器 nginx ~10MB 限制会 413
      file = await picker.pickImage(
        source: source,
        maxWidth: 2560,
        maxHeight: 2560,
        imageQuality: 80,
      );
    } catch (e) {
      if (mounted) _showSnack(ApiClient.errorMessage(e));
      return;
    }
    if (file == null) return;

    // 校验大小（压缩后仍超服务器限制才拦截）
    final length = await file.length();
    if (length > _serverMaxBytes) {
      if (mounted) {
        _showSnack('图片过大（服务器限制约 10MB），请换一张试试');
      }
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
      if (mounted) _showSnack(_uploadErrorMessage(e));
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

    // 压缩视频再上传（对齐 H5 uni.chooseVideo compressed: true）：
    // 原始相机视频可达数十 MB，超过服务器 nginx ~10MB 限制会 413。
    // 压缩失败/取消则回退原文件。
    String videoPath = file.path;
    var size = length;
    if (mounted) _showSnack('视频处理中…');
    try {
      final info = await VideoCompress.compressVideo(
        file.path,
        quality: VideoQuality.MediumQuality,
        deleteOrigin: false,
      );
      final compressedPath = info?.path;
      final compressedSize = info?.filesize;
      if (compressedPath != null &&
          compressedSize != null &&
          compressedSize > 0 &&
          compressedSize < size) {
        videoPath = compressedPath;
        size = compressedSize;
      }
    } catch (_) {
      // 压缩失败：用原文件继续（下面的大小校验兜底）
    }
    if (size > _serverMaxBytes) {
      if (mounted) {
        _showSnack('视频过大（压缩后 ${_formatFileSize(size)}），请选择较短的视频');
      }
      return;
    }

    // 读取视频元信息（时长/宽高）并提取封面图（用压缩后的文件）
    int duration = 0;
    int width = 0;
    int height = 0;
    String? coverPath;
    try {
      final controller = VideoPlayerController.file(File(videoPath));
      await controller.initialize();
      duration = controller.value.duration.inSeconds;
      width = controller.value.size.width.toInt();
      height = controller.value.size.height.toInt();
      await controller.dispose();
      coverPath = await VideoThumbnail.thumbnailFile(
        video: videoPath,
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
        url: videoPath,
        coverUrl: coverPath ?? '',
        duration: duration,
        width: width,
        height: height,
        size: size,
      ),
    );
    setState(() => _messages.insert(0, placeholder));
    _scrollToBottom();

    // 上传视频（占 90% 进度）
    String url;
    try {
      url = await ImApi.uploadFile(
        filePath: videoPath,
        directory: 'im/video',
        onSendProgress: (sent, total) =>
            _updateProgress(clientMessageId, (sent / total) * 0.9),
      );
    } catch (e) {
      _markFailed(clientMessageId, e);
      if (mounted) _showSnack(_uploadErrorMessage(e));
      return;
    }
    if (!mounted) return;

    // 上传封面（占 10% 进度）；封面失败不阻断
    String coverUrl = '';
    if (coverPath != null) {
      try {
        coverUrl = await ImApi.uploadFile(
          filePath: coverPath,
          directory: 'im/video-cover',
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
        size: size,
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
    // 文件不压缩，直接按服务器实际上限拦截（nginx ~10MB，留余量取 9MB）
    if (size > _serverMaxBytes) {
      if (mounted) _showSnack('文件过大：服务器限制约 10MB');
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
      if (mounted) _showSnack(_uploadErrorMessage(e));
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

  /// 上传失败的错误文案：413（nginx 体积超限）给出明确指引。
  String _uploadErrorMessage(Object e) {
    if (e is DioException) {
      final code = e.response?.statusCode;
      if (code == 413) return '上传失败：文件超过服务器限制（约 10MB）';
    }
    return ApiClient.errorMessage(e);
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
    if (_loadingVoiceKey == key) return; // 下载/加载中，忽略重复点击
    try {
      if (mounted) setState(() => _loadingVoiceKey = key);
      await _audioPlayer.stop();
      // iOS AVPlayer 按 URL 扩展名识别格式：H5 上传的语音扩展名可能为 .webm
      // 但内容实为 MP4/AAC，直接 setUrl 会被拒 → 下载嗅探魔数重命名后再播
      final playUrl = await _resolvePlayableUrl(url);
      if (playUrl.startsWith('http')) {
        await _audioPlayer.setUrl(playUrl);
      } else {
        await _audioPlayer.setFilePath(playUrl);
      }
      _audioPlayer.playerStateStream.listen((state) {
        if ((state.processingState == ProcessingState.completed) && mounted) {
          setState(() => _playingVoiceKey = null);
        }
      });
      if (mounted) {
        setState(() {
          _loadingVoiceKey = null;
          _playingVoiceKey = key;
        });
      }
      await _audioPlayer.play();
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingVoiceKey = null;
          _playingVoiceKey = null;
        });
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('语音播放失败')));
      }
    }
  }

  /// 预热语音缓存：语音气泡渲染时后台调用（去重），用户点击时即取即用。
  void _prefetchVoice(String url) {
    _resolvePlayableUrl(url).then((_) {}, onError: (_) {});
  }

  /// 全屏预览图片（对齐 H5 uni.previewImage：缩放/双击）。
  void _previewImage(String url) {
    final full = _staticUrl(url);
    if (full.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _ImageViewerPage(url: full),
      ),
    );
  }

  /// 全屏播放视频（对齐 H5 <video> controls 体验）。
  void _playVideo(String url, String coverUrl) {
    final full = _staticUrl(url);
    if (full.isEmpty || _isLocalPath(full)) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _VideoPlayerPage(url: full, coverUrl: coverUrl),
      ),
    );
  }

  /// 打开文件消息（对齐 H5 openAttachment）：
  /// - URL 为图片扩展名 → 全屏预览（与图片消息同体验）
  /// - 其他 → 下载到临时目录（卡片内进度条）→ 系统查看器打开
  Future<void> _openFileMessage(ChatMessage message) async {
    final payload = message.filePayload;
    if (payload == null) return;
    final url = _staticUrl(payload.url);
    if (url.isEmpty || _isLocalPath(url)) return;

    if (_isImageFileUrl(url)) {
      _previewImage(url);
      return;
    }

    final key = message.key;
    if (_fileDownloadProgress.containsKey(key)) return; // 下载中，忽略重复点击
    setState(() => _fileDownloadProgress[key] = 0.0);
    try {
      // 文件名按消息 key 存放，避免不同消息同名文件互相覆盖
      final safeName = payload.name.replaceAll(
        RegExp(r'[/\\:*?"<>|]'),
        '_',
      );
      final dir =
          '${(await getTemporaryDirectory()).path}/files/$key';
      await Directory(dir).create(recursive: true);
      final savePath = '$dir/$safeName';
      await ApiClient.dio.download(
        url,
        savePath,
        options: Options(
          // 覆盖全局 15s 接收超时（大文件慢网）
          receiveTimeout: const Duration(minutes: 5),
          responseType: ResponseType.bytes,
        ),
        onReceiveProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _fileDownloadProgress[key] = received / total);
          }
        },
      );
      if (mounted) setState(() => _fileDownloadProgress.remove(key));
      final result = await OpenFilex.open(savePath);
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('附件打开失败')));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _fileDownloadProgress.remove(key));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('附件下载失败')));
      }
    }
  }

  /// 解析出可直接交给播放器的地址（带缓存/去重）：
  /// - 已知可播扩展（m4a/aac/mp3/wav/mp4/flac）→ 原样返回（流式播放）
  /// - 可疑扩展（H5 上传的 .webm 等，内容实为 MP4/AAC）→ 下载到本地，
  ///   嗅探 ftyp 魔数后重命名为 .m4a 再播（iOS AVPlayer 按 URL 扩展名识别格式，
  ///   不认 .webm）。
  /// 命中 [_voiceLocalCache] 直接返回；并发请求同一 URL 共享同一个 Future；
  /// 共享 HttpClient 连接池，同域名后续下载免 TLS 握手。
  Future<String> _resolvePlayableUrl(String url) {
    final cached = _voiceLocalCache[url];
    if (cached != null) return Future.value(cached);
    // 整体超时：OSS 偶发挂起时不让用户无限等待（超时走播放失败提示）
    return _voiceResolving[url] ??= _downloadVoiceToLocal(url)
        .timeout(const Duration(seconds: 15));
  }

  Future<String> _downloadVoiceToLocal(String url) async {
    try {
      final pathOnly = url.toLowerCase().split('#').first.split('?').first;
      const supportedExts = ['.m4a', '.aac', '.mp3', '.wav', '.mp4', '.flac'];
      if (supportedExts.any(pathOnly.endsWith)) return url;

      final client = _voiceDlClient ??= HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      final req = await client.getUrl(Uri.parse(url));
      final resp = await req.close();
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        builder.add(chunk);
      }
      final bytes = builder.toBytes();

      // ftyp box（偏移 4~7 = 'f','t','y','p'）→ ISO-BMFF 容器，重命名为 .m4a
      final isMp4 = bytes.length >= 8 &&
          bytes[4] == 0x66 &&
          bytes[5] == 0x74 &&
          bytes[6] == 0x79 &&
          bytes[7] == 0x70;
      final ext = isMp4 ? '.m4a' : '.webm';

      final tmpDir = await getTemporaryDirectory();
      final cacheName = url.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
      final file = File('${tmpDir.path}/voiceplay_$cacheName$ext');
      if (!await file.exists()) {
        await file.writeAsBytes(bytes);
      }
      _voiceLocalCache[url] = file.path;
      return file.path;
    } finally {
      _voiceResolving.remove(url); // 失败允许下次重试
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
          avatarUrl: _avatarUrlFor(message),
          avatarName: _avatarNameFor(message),
          playingVoiceKey: _playingVoiceKey,
          loadingVoiceKey: _loadingVoiceKey,
          onPlayVoice: (m) {
            final url = m.voicePayload?.url;
            if (url != null && url.isNotEmpty) {
              _togglePlayVoice(m, normalizeFaceUrl(url));
            }
          },
          onPrefetchVoice: _prefetchVoice,
          fileDownloadProgress: _fileDownloadProgress,
          onPreviewImage: _previewImage,
          onPlayVideo: _playVideo,
          onOpenFile: _openFileMessage,
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

  /// 发送人头像地址（空串时 ImAvatar 走字母色卡兜底）。
  final String avatarUrl;

  /// 发送人名字（色卡取字/配色的稳定 key）。
  final String avatarName;

  /// 是否显示已读小字（私聊）。
  final bool showReadState;
  final int peerMaxReadId;

  /// 当前正在播放的语音消息 key（null=无播放）。
  final String? playingVoiceKey;

  /// 正在下载/加载中的语音消息 key（气泡显示转圈）。
  final String? loadingVoiceKey;

  /// 点击语音气泡（播放/停止）。
  final ValueChanged<ChatMessage> onPlayVoice;

  /// 预热语音缓存（气泡渲染时后台调用，内部去重）。
  final ValueChanged<String> onPrefetchVoice;

  /// 文件消息下载进度：消息 key → 0~1（卡片内进度条）。
  final Map<String, double> fileDownloadProgress;

  /// 点击图片气泡（全屏预览原图）。
  final ValueChanged<String> onPreviewImage;

  /// 点击视频气泡（全屏播放）。
  final void Function(String url, String coverUrl) onPlayVideo;

  /// 点击文件气泡（图片扩展名走预览，否则下载打开）。
  final ValueChanged<ChatMessage> onOpenFile;
  final VoidCallback onRetry;
  final VoidCallback onRecall;

  const _MessageItem({
    required this.message,
    required this.older,
    required this.avatarUrl,
    required this.avatarName,
    required this.showReadState,
    required this.peerMaxReadId,
    required this.playingVoiceKey,
    required this.loadingVoiceKey,
    required this.onPlayVoice,
    required this.onPrefetchVoice,
    required this.fileDownloadProgress,
    required this.onPreviewImage,
    required this.onPlayVideo,
    required this.onOpenFile,
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
      // 渲染即后台预热缓存（内部去重），点击时命中即秒播
      final vUrl = normalizeFaceUrl(message.voicePayload!.url);
      if (vUrl.isNotEmpty) onPrefetchVoice(vUrl);
      content = _VoiceBubbleBody(
        payload: message.voicePayload!,
        playing: playingVoiceKey == message.key,
        loading: loadingVoiceKey == message.key,
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
      // 上传中（progress != null）禁止预览；failed 时让外层气泡的
      // 重试逻辑接手（内层手势会赢得竞争，必须置 null）
      final imgPayload = message.imagePayload!;
      content = GestureDetector(
        onTap: (message.progress == null && !failed)
            ? () => onPreviewImage(imgPayload.url)
            : null,
        child: _ImageBubbleBody(
          payload: imgPayload,
          progress: message.progress,
        ),
      );
    } else if (message.type == ChatMsgType.video &&
        message.videoPayload != null) {
      final videoPayload = message.videoPayload!;
      content = GestureDetector(
        onTap: (message.progress == null && !failed)
            ? () => onPlayVideo(videoPayload.url, videoPayload.coverUrl)
            : null,
        child: _VideoBubbleBody(
          payload: videoPayload,
          progress: message.progress,
        ),
      );
    } else if (message.type == ChatMsgType.file &&
        message.filePayload != null) {
      // 上传中禁止点击；下载中由 _openFileMessage 内部去重
      content = GestureDetector(
        onTap: (message.progress == null && !failed)
            ? () => onOpenFile(message)
            : null,
        child: _FileBubbleBody(
          payload: message.filePayload!,
          progress: message.progress,
          downloadProgress: fileDownloadProgress[message.key],
        ),
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

    final isVoice = message.type == ChatMsgType.voice;
    // 表情/图片/视频为 plain 气泡（对齐 H5）：不加背景色，直接透出会话背景
    final isPlainMedia = message.type == ChatMsgType.face ||
        message.type == ChatMsgType.image ||
        message.type == ChatMsgType.video;
    final bubble = GestureDetector(
      // 失败点击重试；语音消息整条气泡点击播放；正常消息长按弹菜单
      onTap: failed
          ? onRetry
          : (isVoice ? () => onPlayVoice(message) : null),
      onLongPress: message.operable ? () => _showActions(context) : null,
      // 语音条整条气泡（含内边距空白）都要可点；其余类型保持默认，
      // 避免吞掉页面级点击（点空白收键盘）
      behavior: isVoice ? HitTestBehavior.opaque : HitTestBehavior.deferToChild,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 260),
        padding: (message.type == ChatMsgType.face ||
                message.type == ChatMsgType.image ||
                message.type == ChatMsgType.video)
            ? EdgeInsets
                  .zero // 表情/图片/视频大图不加内边距
            : const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: isPlainMedia
              ? null
              : (isSelf ? AppColors.lime : colors.card),
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

    // 头像贴行两侧（微信风格：自己头像在右、对方在左，与气泡顶部对齐）
    final avatar = ImAvatar(src: avatarUrl, name: avatarName, size: 40);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: isSelf
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isSelf) avatar,
          if (isSelf) ..._buildStateIcon(colors, sending, failed),
          Flexible(
            child: Padding(
              // 头像与气泡的间距（两侧对称 8）
              padding: EdgeInsets.only(
                left: isSelf ? 0 : 8,
                right: isSelf ? 8 : 0,
              ),
              child: Column(
                crossAxisAlignment: isSelf
                    ? CrossAxisAlignment.end
                    : CrossAxisAlignment.start,
                children: [bubble, ?readState],
              ),
            ),
          ),
          if (isSelf) avatar,
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
/// [loading]：语音下载/加载中，图标位显示转圈。
class _VoiceBubbleBody extends StatelessWidget {
  final VoicePayload payload;
  final bool playing;
  final bool loading;
  final bool selfColor;
  final VoidCallback onTap;

  const _VoiceBubbleBody({
    required this.payload,
    required this.playing,
    required this.loading,
    required this.selfColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final width = (80 + payload.duration * 10).clamp(80, 220).toDouble();
    final fg = selfColor ? Colors.black : context.colors.text;
    // 图标位：加载中转圈 > 播放中波形 > 默认播放三角
    Widget iconOf(Color color) => loading
        ? SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        : Icon(playing ? Icons.graphic_eq : Icons.play_arrow, color: color);
    return GestureDetector(
      onTap: onTap,
      // 整条语音条（图标/文字/之间空白）均可点，而非只有图标处响应
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        height: 26,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // 左侧图标（对方消息）/右侧图标（自己消息，保持喇叭朝向聊天方）
            if (!selfColor) iconOf(context.colors.muted),
            Text(
              '${payload.duration}"',
              style: TextStyle(fontSize: 14, color: fg),
            ),
            if (selfColor) iconOf(Colors.black),
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

/// 图片扩展名（对齐 H5 IMAGE_FILE_EXTENSIONS）：文件消息 URL 命中则走全屏预览而非下载打开。
const List<String> _imageFileExtensions = [
  'bmp', 'gif', 'jpeg', 'jpg', 'png', 'webp',
];

/// URL 是否指向图片（按路径后缀判断，忽略 query/fragment）。
bool _isImageFileUrl(String url) {
  final path = url.toLowerCase().split('#').first.split('?').first;
  return _imageFileExtensions.any(path.endsWith);
}

/// 相对路径拼接 CDN 域名（对齐 H5 staticUrl；完整 URL 原样返回）。
String _staticUrl(String url) {
  var u = normalizeFaceUrl(url);
  if (u.isEmpty || u.startsWith('http')) return u;
  return '${ApiClient.baseUrl}${u.startsWith('/') ? '' : '/'}$u';
}

/// 文件大小格式化（对齐 H5 formatFileSize：/1024 进制 + 两位小数）。
String _formatFileSize(int size) {
  if (size <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  var s = size.toDouble();
  var i = 0;
  while (s >= 1024 && i < units.length - 1) {
    s /= 1024;
    i++;
  }
  return i == 0 ? '${size}B' : '${s.toStringAsFixed(2)}${units[i]}';
}

/// 图片气泡体：等比显示（最大边 ~200），本地路径用 Image.file，远程用 Image.network；
/// 上传中覆盖进度条。列表取图顺序 thumbnailUrl || url（缩略图优先省流量）。
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
    // 缩略图优先（对齐 H5 getImageUrl：thumbnailUrl || url）
    final url = normalizeFaceUrl(
      payload.thumbnailUrl.isNotEmpty ? payload.thumbnailUrl : payload.url,
    );
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

/// 文件气泡体：文件图标 + 文件名 + 大小 + 底部状态行（点击查看文件 /
/// 上传中 xx% / 下载中 xx%，对齐 H5 文件卡片）；进度条上传/下载复用。
class _FileBubbleBody extends StatelessWidget {
  final FilePayload payload;

  /// 上传进度（null=非上传中）。
  final double? progress;

  /// 下载进度（null=非下载中）。
  final double? downloadProgress;

  const _FileBubbleBody({
    required this.payload,
    required this.progress,
    required this.downloadProgress,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final uploading = progress != null;
    final downloading = downloadProgress != null;
    // 底部状态文案（对齐 H5：点击查看文件 / 上传中 xx%）
    final String statusText;
    if (uploading) {
      statusText = '上传中 ${(progress! * 100).round()}%';
    } else if (downloading) {
      statusText = '下载中 ${(downloadProgress! * 100).round()}%';
    } else {
      statusText = '点击查看文件';
    }
    final barValue = uploading
        ? progress!.clamp(0.0, 1.0)
        : downloading
            ? downloadProgress!.clamp(0.0, 1.0)
            : null;
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
                      _formatFileSize(payload.size),
                      style: TextStyle(fontSize: 11, color: colors.muted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 底部状态行：分隔线 + 文案（+进度条）
          Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: colors.divider, width: 0.5),
              ),
            ),
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  statusText,
                  style: TextStyle(fontSize: 11, color: colors.muted),
                ),
                if (barValue != null) ...[
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    value: barValue,
                    minHeight: 3,
                    backgroundColor: colors.divider,
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(AppColors.lime),
                  ),
                ],
              ],
            ),
          ),
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

/// 图片全屏预览页（对齐 H5 uni.previewImage：双指缩放/双击放大/拖动）。
class _ImageViewerPage extends StatelessWidget {
  final String url;

  const _ImageViewerPage({required this.url});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: PhotoView(
              imageProvider: NetworkImage(url),
              backgroundDecoration: const BoxDecoration(color: Colors.black),
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 4,
              loadingBuilder: (_, _) => const Center(
                child: CircularProgressIndicator(color: AppColors.lime),
              ),
              errorBuilder: (_, _, _) => const Center(
                child: Text('图片加载失败', style: TextStyle(color: Colors.white70)),
              ),
            ),
          ),
          // 顶部关闭按钮（状态栏安全区）
          Positioned(
            top: 0,
            right: 0,
            child: SafeArea(
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 26),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 视频全屏播放页（对齐 H5 <video controls> 体验：播放/暂停/进度条/时长）。
/// 点击画面切换控制层显隐；播放完成显示重播。
class _VideoPlayerPage extends StatefulWidget {
  final String url;
  final String coverUrl;

  const _VideoPlayerPage({required this.url, this.coverUrl = ''});

  @override
  State<_VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<_VideoPlayerPage> {
  VideoPlayerController? _ctrl;
  bool _initialized = false;
  bool _error = false;
  bool _controlsVisible = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _ctrl = ctrl;
    try {
      await ctrl.initialize();
      if (!mounted) return;
      setState(() => _initialized = true);
      ctrl.addListener(_onUpdate);
      // 等首帧布局完成后再播放：AVPlayer 层若以初始 0 尺寸布局，
      // 视频会先渲染在左上角一小块，直到下一次布局才恢复
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ctrl.play();
      });
      _scheduleHide();
    } catch (_) {
      if (mounted) setState(() => _error = true);
    }
  }

  void _onUpdate() {
    if (_ctrl == null || !mounted) return;
    setState(() {}); // 进度/播放状态变化刷新
    if (_ctrl!.value.position >= _ctrl!.value.duration) {
      _cancelHide();
    }
  }

  void _scheduleHide() {
    _cancelHide();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _cancelHide() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _togglePlay() {
    final ctrl = _ctrl;
    if (ctrl == null || !_initialized) return;
    if (ctrl.value.isPlaying) {
      ctrl.pause();
      _cancelHide();
    } else {
      // 播放结束后再点播放 → 从头重播
      if (ctrl.value.position >= ctrl.value.duration) {
        ctrl.seekTo(Duration.zero);
      }
      ctrl.play();
      _scheduleHide();
    }
    setState(() => _controlsVisible = true);
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _scheduleHide();
    } else {
      _cancelHide();
    }
  }

  String _fmt(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _cancelHide();
    _ctrl?.removeListener(_onUpdate);
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    final value = ctrl?.value;
    final isPlaying = value?.isPlaying ?? false;
    final pos = value?.position ?? Duration.zero;
    final dur = value?.duration ?? Duration.zero;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 画面：初始化前显示封面/加载中，完成后等比居中显示。
          // 视频本体只保留 Center→AspectRatio→VideoPlayer 标准结构，
          // 不包裹 GestureDetector/ClipRect（iOS 平台视图与裁剪/代理层
          // 组合会导致视频渲染在左上角小块）
          _initialized && ctrl != null
              ? Center(
                  child: AspectRatio(
                    aspectRatio: ctrl.value.aspectRatio,
                    child: VideoPlayer(ctrl),
                  ),
                )
              : _buildCoverOrLoading(),
          // 透明点击层：独立覆盖层切换控制层显隐
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
          ),
          if (!_error) ...[
            // 中央播放/暂停大按钮
            if (_controlsVisible)
              Center(
                child: GestureDetector(
                  onTap: _togglePlay,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 40,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            // 顶部关闭
            Positioned(
              top: 0,
              left: 0,
              child: SafeArea(
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 26),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
            // 底部进度条 + 时间
            if (_controlsVisible && _initialized)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _buildBottomBar(pos, dur),
              ),
          ],
          if (_error)
            const Center(
              child: Text('视频加载失败', style: TextStyle(color: Colors.white70)),
            ),
        ],
      ),
    );
  }

  /// 初始化前的封面/加载态。
  Widget _buildCoverOrLoading() {
    if (widget.coverUrl.isNotEmpty) {
      return Center(
        child: Image.network(
          normalizeFaceUrl(widget.coverUrl),
          fit: BoxFit.contain,
          // 封面加载失败时显示加载圈（视频本身仍在初始化）
          errorBuilder: (_, _, _) => const CircularProgressIndicator(
            color: AppColors.lime,
          ),
        ),
      );
    }
    return const Center(
      child: CircularProgressIndicator(color: AppColors.lime),
    );
  }

  Widget _buildBottomBar(Duration pos, Duration dur) {
    final ctrl = _ctrl!;
    // 不用 Row+Slider（M3 Slider 有最小宽度约束会溢出），
    // 改用 video_player 自带进度条：自带拖动 seek（allowScrubbing）
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.black45,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            VideoProgressIndicator(
              ctrl,
              allowScrubbing: true,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              colors: const VideoProgressColors(
                playedColor: AppColors.lime,
                bufferedColor: Colors.white24,
                backgroundColor: Colors.white12,
              ),
            ),
            Text(
              '${_fmt(pos)} / ${_fmt(dur)}',
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
