import 'package:flutter/material.dart';

import '../../models/im_conversation.dart';
import '../../services/auth_manager.dart';
import '../../services/im_api.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/im_avatar.dart';
import '../../shared/widgets.dart';
import 'friend_apply_page.dart';
import 'user_profile_page.dart';

/// 新的朋友（申请中心，对应 H5 /contact/request/index 双 tab）：
/// 好友申请（我相关的双向列表，收到的可同意/拒绝）+ 加群申请（我管理的群）。
class RequestCenterPage extends StatefulWidget {
  const RequestCenterPage({super.key});

  @override
  State<RequestCenterPage> createState() => _RequestCenterPageState();
}

class _RequestCenterPageState extends State<RequestCenterPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      body: Column(
        children: [
          _buildHeader(colors),
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: const [
                _FriendRequestTab(),
                _GroupRequestTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeColors colors) {
    return Container(
      color: colors.surface,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SizedBox(
              height: 64,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new, size: 22),
                    color: colors.surfaceText,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Text(
                      '新的朋友',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: colors.surfaceText,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.person_add_alt_1_outlined,
                        size: 24),
                    color: colors.surfaceText,
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const FriendApplyPage()),
                    ),
                  ),
                ],
              ),
            ),
            // 浅色：TabBar 白底（头部保持 lime）；深色：跟随 surface 深灰
            Container(
              color: Theme.of(context).brightness == Brightness.dark
                  ? colors.surface
                  : Colors.white,
              child: TabBar(
                controller: _tabCtrl,
                dividerColor: Colors.transparent, // 去掉自动生成的底部分割线
                labelColor: colors.text,
                unselectedLabelColor: colors.muted,
                indicatorColor: AppColors.lime,
                indicatorSize: TabBarIndicatorSize.label,
                tabs: const [
                  Tab(text: '好友申请'),
                  Tab(text: '加群申请'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 好友申请 tab：游标分页（maxId）+ 收到的申请可同意/拒绝（乐观更新）。
class _FriendRequestTab extends StatefulWidget {
  const _FriendRequestTab();

  @override
  State<_FriendRequestTab> createState() => _FriendRequestTabState();
}

class _FriendRequestTabState extends State<_FriendRequestTab>
    with AutomaticKeepAliveClientMixin {
  static const int _pageSize = 50;

  List<ImFriendRequest> _list = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int? _actingId;

  final ScrollController _scrollCtrl = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    if (_scrollCtrl.position.extentAfter < 120 &&
        _hasMore &&
        !_loadingMore) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await ImApi.getFriendRequestList(limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _list = list;
        _hasMore = list.length >= _pageSize;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('加载失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _list.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final oldest = _list.map((e) => e.id).reduce((a, b) => a < b ? a : b);
      final more =
          await ImApi.getFriendRequestList(maxId: oldest, limit: _pageSize);
      if (!mounted) return;
      setState(() {
        _list.addAll(more);
        _hasMore = more.length >= _pageSize;
      });
    } catch (_) {
      // 翻页失败静默，下拉刷新可恢复
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// 同意：乐观更新（成功本地改写状态，失败回滚重拉）。
  Future<void> _agree(ImFriendRequest req) async {
    if (_actingId != null || !req.pending) return;
    setState(() => _actingId = req.id);
    try {
      await ImApi.agreeFriendRequest(id: req.id);
      if (!mounted) return;
      _markHandled(req.id, 1);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已同意')));
    } catch (_) {
      if (mounted) _load(); // 失败回滚：重拉列表
    } finally {
      if (mounted) setState(() => _actingId = null);
    }
  }

  /// 拒绝：先弹理由输入（选填），再乐观更新。
  Future<void> _refuse(ImFriendRequest req) async {
    if (_actingId != null || !req.pending) return;
    final reason = await _promptRefuseReason();
    if (reason == null || !mounted) return; // 取消
    setState(() => _actingId = req.id);
    try {
      await ImApi.refuseFriendRequest(id: req.id, handleContent: reason);
      if (!mounted) return;
      _markHandled(req.id, 2);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已拒绝')));
    } catch (_) {
      if (mounted) _load();
    } finally {
      if (mounted) setState(() => _actingId = null);
    }
  }

  /// 拒绝理由弹窗（null=取消；''=不填）。
  Future<String?> _promptRefuseReason() {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('拒绝好友申请', style: TextStyle(fontSize: 17)),
        content: TextField(
          controller: ctrl,
          maxLength: 255,
          decoration: const InputDecoration(
            hintText: '可填写拒绝理由（选填）',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  /// 本地改写处理状态（不重拉列表，对齐 H5 乐观更新）。
  void _markHandled(int id, int result) {
    final i = _list.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final old = _list[i];
    _list[i] = ImFriendRequest(
      id: old.id,
      fromUserId: old.fromUserId,
      toUserId: old.toUserId,
      handleResult: result,
      applyContent: old.applyContent,
      handleContent: old.handleContent,
      addSource: old.addSource,
      handleTime: DateTime.now(),
      createTime: old.createTime,
      fromNickname: old.fromNickname,
      fromAvatar: old.fromAvatar,
      toNickname: old.toNickname,
      toAvatar: old.toAvatar,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = context.colors;
    if (_loading && _list.isEmpty) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.lime));
    }
    if (_list.isEmpty) {
      return const EmptyState(label: '暂无好友申请');
    }
    return RefreshIndicator(
      color: AppColors.lime,
      onRefresh: _load,
      child: ListView.separated(
        controller: _scrollCtrl,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: _list.length + (_loadingMore ? 1 : 0),
        separatorBuilder: (_, _) =>
            Divider(height: 1, indent: 82, color: colors.divider),
        itemBuilder: (context, i) {
          if (i == _list.length) {
            return const Padding(
              padding: EdgeInsets.all(14),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          return _FriendRequestCard(
            request: _list[i],
            acting: _actingId == _list[i].id,
            onAgree: () => _agree(_list[i]),
            onRefuse: () => _refuse(_list[i]),
          );
        },
      ),
    );
  }
}

/// 好友申请卡片：头像 + 昵称 + 申请理由 + 时间 + 操作按钮/状态。
class _FriendRequestCard extends StatelessWidget {
  final ImFriendRequest request;
  final bool acting;
  final VoidCallback onAgree;
  final VoidCallback onRefuse;

  const _FriendRequestCard({
    required this.request,
    required this.acting,
    required this.onAgree,
    required this.onRefuse,
  });

  String _formatTime(DateTime? time) {
    if (time == null) return '';
    final local = time.toLocal();
    final now = DateTime.now();
    if (local.year == now.year) {
      return '${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    }
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final myUserId = AuthManager.instance.userId ?? 0;
    final incoming = request.toUserId == myUserId; // 收到的（可操作）
    final name = incoming ? request.fromNickname : request.toNickname;
    final avatar = incoming ? request.fromAvatar : request.toAvatar;
    final targetId = incoming ? request.fromUserId : request.toUserId;

    return Container(
      color: colors.card,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => UserProfilePage(userId: targetId),
              ),
            ),
            child: ImAvatar(src: avatar, name: name, size: 46),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name.isEmpty ? '用户$targetId' : name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: colors.text,
                        ),
                      ),
                    ),
                    Text(
                      _formatTime(request.createTime),
                      style: TextStyle(fontSize: 12, color: colors.muted),
                    ),
                  ],
                ),
                if (request.applyContent.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    '申请理由：${request.applyContent}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: colors.muted),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: [
                    // 发出的申请：只显示状态文案
                    if (!incoming)
                      Expanded(
                        child: Text(
                          '等待对方处理',
                          style:
                              TextStyle(fontSize: 13, color: colors.muted),
                        ),
                      )
                    // 收到的待处理：同意/拒绝按钮（乐观更新，acting 转圈）
                    else if (request.pending) ...[
                      Expanded(
                        child: acting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : Row(
                                children: [
                                  _ActionButton(
                                    label: '拒绝',
                                    outlined: true,
                                    onTap: onRefuse,
                                  ),
                                  const SizedBox(width: 10),
                                  _ActionButton(
                                    label: '同意',
                                    outlined: false,
                                    onTap: onAgree,
                                  ),
                                ],
                              ),
                      ),
                    ]
                    // 已处理：状态标签
                    else
                      Expanded(
                        child: Text(
                          request.handleResultLabel,
                          style: TextStyle(
                            fontSize: 13,
                            color: request.handleResult == 1
                                ? const Color(0xFF07C160)
                                : colors.muted,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 加群申请 tab：我管理的群的所有待处理申请（unhandled-list）。
class _GroupRequestTab extends StatefulWidget {
  const _GroupRequestTab();

  @override
  State<_GroupRequestTab> createState() => _GroupRequestTabState();
}

class _GroupRequestTabState extends State<_GroupRequestTab>
    with AutomaticKeepAliveClientMixin {
  List<ImGroupRequest> _list = [];
  bool _loading = true;
  int? _actingId;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await ImApi.getUnhandledGroupRequestList();
      if (!mounted) return;
      setState(() => _list = list);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('加载失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _agree(ImGroupRequest req) async {
    if (_actingId != null || !req.pending) return;
    setState(() => _actingId = req.id);
    try {
      await ImApi.agreeGroupRequest(id: req.id);
      if (!mounted) return;
      _markHandled(req.id, 1);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已同意')));
    } catch (_) {
      if (mounted) _load();
    } finally {
      if (mounted) setState(() => _actingId = null);
    }
  }

  Future<void> _refuse(ImGroupRequest req) async {
    if (_actingId != null || !req.pending) return;
    final ctrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('拒绝加群申请', style: TextStyle(fontSize: 17)),
        content: TextField(
          controller: ctrl,
          maxLength: 255,
          decoration: const InputDecoration(
            hintText: '可填写拒绝理由（选填）',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    if (reason == null || !mounted) return;
    setState(() => _actingId = req.id);
    try {
      await ImApi.refuseGroupRequest(id: req.id, handleContent: reason);
      if (!mounted) return;
      _markHandled(req.id, 2);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已拒绝')));
    } catch (_) {
      if (mounted) _load();
    } finally {
      if (mounted) setState(() => _actingId = null);
    }
  }

  void _markHandled(int id, int result) {
    final i = _list.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final old = _list[i];
    _list[i] = ImGroupRequest(
      id: old.id,
      groupId: old.groupId,
      userId: old.userId,
      inviterUserId: old.inviterUserId,
      handleResult: result,
      applyContent: old.applyContent,
      handleContent: old.handleContent,
      handleTime: DateTime.now(),
      createTime: old.createTime,
      userNickname: old.userNickname,
      userAvatar: old.userAvatar,
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = context.colors;
    if (_loading && _list.isEmpty) {
      return const Center(
          child: CircularProgressIndicator(color: AppColors.lime));
    }
    if (_list.isEmpty) {
      return const EmptyState(label: '暂无加群申请');
    }
    return RefreshIndicator(
      color: AppColors.lime,
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        separatorBuilder: (_, _) =>
            Divider(height: 1, indent: 82, color: colors.divider),
        itemCount: _list.length,
        itemBuilder: (context, i) {
          final req = _list[i];
          final acting = _actingId == req.id;
          return Container(
            color: colors.card,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ImAvatar(src: req.userAvatar, name: req.shownName, size: 46),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              req.shownName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                                color: colors.text,
                              ),
                            ),
                          ),
                          Text(
                            '申请进群',
                            style:
                                TextStyle(fontSize: 12, color: colors.muted),
                          ),
                        ],
                      ),
                      if (req.applyContent.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          '申请理由：${req.applyContent}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: colors.muted),
                        ),
                      ],
                      const SizedBox(height: 8),
                      if (req.pending)
                        acting
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : Row(
                                children: [
                                  _ActionButton(
                                    label: '拒绝',
                                    outlined: true,
                                    onTap: () => _refuse(req),
                                  ),
                                  const SizedBox(width: 10),
                                  _ActionButton(
                                    label: '同意',
                                    outlined: false,
                                    onTap: () => _agree(req),
                                  ),
                                ],
                              )
                      else
                        Text(
                          req.handleResultLabel,
                          style: TextStyle(
                            fontSize: 13,
                            color: req.handleResult == 1
                                ? const Color(0xFF07C160)
                                : colors.muted,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// 操作小按钮（同意=lime 实底；拒绝=描边）。
class _ActionButton extends StatelessWidget {
  final String label;
  final bool outlined;
  final VoidCallback onTap;

  const _ActionButton({
    required this.label,
    required this.outlined,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: outlined
          ? OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                side: BorderSide(color: context.colors.divider),
              ),
              onPressed: onTap,
              child: Text(label, style: const TextStyle(fontSize: 13)),
            )
          : FilledButton(
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                backgroundColor: AppColors.lime,
                foregroundColor: Colors.black,
              ),
              onPressed: onTap,
              child: Text(label, style: const TextStyle(fontSize: 13)),
            ),
    );
  }
}
