import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/im_conversation.dart';
import '../../models/im_message.dart';
import '../../services/api_client.dart';
import '../../services/auth_manager.dart';
import '../../services/im_api.dart';
import '../../services/im_websocket.dart';
import '../../shared/app_theme.dart';
import '../../shared/im_avatar.dart';

/// 查找聊天内容页（对齐 H5 history 搜索页简化版）：
/// 全量分页拉取群历史消息 → 本地关键词过滤（文本/文件名/表情名等
/// displayText 口径），展示「发送人 + 时间 + 摘要」列表。
class ChatSearchPage extends StatefulWidget {
  final int groupId;

  const ChatSearchPage({super.key, required this.groupId});

  @override
  State<ChatSearchPage> createState() => _ChatSearchPageState();
}

class _ChatSearchPageState extends State<ChatSearchPage> {
  static const int _pageSize = 100;

  /// 全量已拉取消息（升序）。空关键词时提示输入，不渲染列表。
  List<ImGroupMessage> _all = [];
  final Map<int, ImGroupMember> _members = {};
  bool _loading = false;
  bool _loadedOnce = false;

  final _searchCtrl = TextEditingController();
  String _keyword = '';
  Timer? _debounce;
  StreamSubscription? _wsSub;

  int get _myUserId => AuthManager.instance.userId ?? 0;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(_onSearchChanged);
    // 群事件（改名/进出群等）到达时静默重拉，保持数据新鲜
    _wsSub = ImWebSocket.instance.notificationStream.listen((n) {
      if (n.conversationType == ImConversationType.group.value &&
          n.payload['groupId'] == widget.groupId) {
        _loadAll(silent: true);
      }
    });
    _loadAll();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _wsSub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) setState(() => _keyword = _searchCtrl.text.trim());
    });
  }

  Future<void> _loadAll({bool silent = false}) async {
    if (_loading) return;
    if (!silent) setState(() => _loading = true);
    try {
      final results = await Future.wait([
        _pullAllMessages(),
        ImApi.getGroupMemberList(groupId: widget.groupId),
      ]);
      if (!mounted) return;
      final messages = results[0] as List<ImGroupMessage>;
      final members = results[1] as List<ImGroupMember>;
      setState(() {
        _all = messages;
        _members
          ..clear()
          ..addEntries(members.map((m) => MapEntry(m.userId, m)));
        _loadedOnce = true;
      });
    } catch (e) {
      if (mounted && !silent) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(ApiClient.errorMessage(e))));
      }
    } finally {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  /// 循环分页拉取全部群消息（maxId 游标，结果升序）。
  Future<List<ImGroupMessage>> _pullAllMessages() async {
    final all = <ImGroupMessage>[];
    int? maxId;
    while (true) {
      final batch = await ImApi.getGroupMessageList(
        groupId: widget.groupId,
        limit: _pageSize,
        maxId: maxId,
      );
      if (batch.isEmpty) break;
      all.addAll(batch);
      if (batch.length < _pageSize) break;
      maxId = batch.last.id;
    }
    return all.reversed.toList(); // 接口返回倒序 → 转升序
  }

  String _memberName(int userId) {
    if (userId == _myUserId) return '我';
    final m = _members[userId];
    if (m != null && m.shownName.isNotEmpty) return m.shownName;
    return '用户$userId';
  }

  String _formatTime(DateTime t) =>
      '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      body: Column(
        children: [
          // 顶部：返回 + 搜索框
          Container(
            color: colors.surface,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 64,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '返回',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.chevron_left,
                          size: 34, color: colors.surfaceText),
                    ),
                    Expanded(
                      child: Container(
                        height: 38,
                        margin: const EdgeInsets.only(right: 14),
                        decoration: BoxDecoration(
                          color: colors.card,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            const SizedBox(width: 10),
                            Icon(Icons.search, size: 20, color: colors.muted),
                            const SizedBox(width: 6),
                            Expanded(
                              child: TextField(
                                controller: _searchCtrl,
                                style: TextStyle(
                                    fontSize: 14, color: colors.surfaceText),
                                decoration: const InputDecoration(
                                  hintText: '搜索聊天内容',
                                  border: InputBorder.none,
                                  isDense: true,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(child: _buildBody(colors)),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeColors colors) {
    if (_loading && !_loadedOnce) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_keyword.isEmpty) {
      return Center(
        child: Text(
          '输入关键词查找聊天内容',
          style: TextStyle(fontSize: 14, color: colors.muted),
        ),
      );
    }
    final keyword = _keyword.toLowerCase();
    final results = _all
        .where((m) =>
            !m.isRecalled &&
            m.textContent.toLowerCase().contains(keyword))
        .toList()
        .reversed
        .toList(); // 最新的在前

    if (results.isEmpty) {
      return Center(
        child: Text(
          '未找到“$_keyword”相关记录',
          style: TextStyle(fontSize: 14, color: colors.muted),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: results.length,
      separatorBuilder: (_, _) => Divider(height: 1, color: colors.divider),
      itemBuilder: (context, index) {
        final m = results[index];
        final member = _members[m.senderId];
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          leading: ImAvatar(
            src: member?.avatar ?? '',
            name: member?.nickname ?? '用户${m.senderId}',
            size: 40,
          ),
          title: Text(
            m.textContent,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: colors.text),
          ),
          subtitle: Text(
            '${_memberName(m.senderId)} · '
            '${m.sendTime != null ? _formatTime(m.sendTime!.toLocal()) : ''}',
            style: TextStyle(fontSize: 12, color: colors.muted),
          ),
        );
      },
    );
  }
}
