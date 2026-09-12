import 'package:flutter/material.dart';

import '../../models/im_conversation.dart';
import '../../services/api_client.dart';
import '../../services/auth_api.dart';
import '../../services/auth_manager.dart';
import '../../services/im_api.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/im_avatar.dart';

/// 添加好友页（对应 H5 friend/apply）：
/// 选目标用户（simple-list 全量本地搜索 + 隐藏自己 + 已好友置灰）+
/// 好友备注（≤16，apply 的 displayName）+ 申请理由（≤255，自动填充「我是昵称」）。
class FriendApplyPage extends StatefulWidget {
  /// 预选目标用户（名片/资料页「添加朋友」带参进入）。
  final int? toUserId;

  /// 申请来源（1=搜索 2=群聊 3=扫码 4=名片）。
  final int addSource;

  /// 来源附加上下文（群聊入口=群名，用于申请理由预填）。
  final String sourceExtra;

  const FriendApplyPage({
    super.key,
    this.toUserId,
    this.addSource = 1,
    this.sourceExtra = '',
  });

  @override
  State<FriendApplyPage> createState() => _FriendApplyPageState();
}

class _FriendApplyPageState extends State<FriendApplyPage> {
  List<SimpleUser> _users = [];
  final Set<int> _friendIds = {};

  /// 选中的目标用户（null=未选）。
  SimpleUser? _target;

  final _remarkCtrl = TextEditingController();
  final _contentCtrl = TextEditingController();

  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _remarkCtrl.dispose();
    _contentCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final results = await Future.wait([
        AuthApi.getSimpleUserList(),
        ImApi.getFriendList(),
      ]);
      final users = results[0] as List<SimpleUser>;
      final friends = results[1] as List<ImFriend>;
      if (!mounted) return;
      setState(() {
        _users = users;
        _friendIds
          ..clear()
          ..addAll(friends
              .where((f) => f.status == ImCommonStatus.enable)
              .map((f) => f.friendUserId));
        // 带参进入：预选目标用户
        if (widget.toUserId != null && widget.toUserId! > 0) {
          final found = users.where((u) => u.id == widget.toUserId).toList();
          if (found.isNotEmpty) _target = found.first;
        }
        // 申请理由自动填充：群聊来源带群名，其余默认昵称（对齐 H5 模板）
        final myNickname = AuthManager.instance.nickname ?? '';
        _contentCtrl.text = widget.sourceExtra.isNotEmpty
            ? '我是"${widget.sourceExtra}"的$myNickname'
            : '我是$myNickname';
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

  /// 提交好友申请。
  Future<void> _submit() async {
    if (_submitting) return;
    final target = _target;
    if (target == null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('请先选择要添加的用户')));
      return;
    }
    final content = _contentCtrl.text.trim();
    if (content.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('请填写申请理由')));
      return;
    }
    setState(() => _submitting = true);
    try {
      await ImApi.applyFriendRequest(
        toUserId: target.id,
        applyContent: content,
        displayName: _remarkCtrl.text.trim(),
        addSource: widget.addSource,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('申请已发送，等待对方处理')));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(ApiClient.errorMessage(e))));
    }
  }

  /// 打开用户选择器（本地搜索 + 隐藏自己 + 已好友置灰）。
  Future<void> _pickUser() async {
    final picked = await Navigator.of(context).push<SimpleUser>(
      MaterialPageRoute(
        builder: (_) => _UserPickerPage(
          users: _users,
          friendIds: _friendIds,
          current: _target,
        ),
      ),
    );
    if (picked != null) setState(() => _target = picked);
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
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.lime))
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildCard(colors, [
                        _buildTargetPicker(colors),
                        _buildDivider(colors),
                        _buildField(
                          colors,
                          label: '好友备注',
                          hint: '请输入好友备注（选填，对方不可见）',
                          controller: _remarkCtrl,
                          maxLength: 16,
                        ),
                        _buildDivider(colors),
                        _buildField(
                          colors,
                          label: '申请理由',
                          hint: '请输入申请理由',
                          controller: _contentCtrl,
                          maxLength: 255,
                          multiline: true,
                        ),
                      ]),
                      const SizedBox(height: 22),
                      FilledButton(
                        onPressed: _submitting ? null : _submit,
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.lime,
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: Text(_submitting ? '提交中…' : '发送申请'),
                      ),
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
        child: SizedBox(
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
                  '添加好友',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: colors.surfaceText,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard(ThemeColors colors, List<Widget> children) {
    return Container(
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildDivider(ThemeColors colors) =>
      Divider(height: 1, indent: 16, endIndent: 16, color: colors.divider);

  /// 目标用户选择行：点击开选择器；已选显示头像昵称。
  Widget _buildTargetPicker(ThemeColors colors) {
    final t = _target;
    return InkWell(
      onTap: _pickUser,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Text('添加对象',
                style: TextStyle(fontSize: 15, color: colors.text)),
            const Spacer(),
            if (t != null) ...[
              ImAvatar(src: t.avatar, name: t.nickname, size: 30),
              const SizedBox(width: 8),
              Text(t.nickname,
                  style: TextStyle(fontSize: 15, color: colors.text)),
            ] else
              Text('请选择', style: TextStyle(fontSize: 15, color: colors.muted)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 20, color: colors.muted),
          ],
        ),
      ),
    );
  }

  Widget _buildField(
    ThemeColors colors, {
    required String label,
    required String hint,
    required TextEditingController controller,
    required int maxLength,
    bool multiline = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 15, color: colors.text)),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            maxLength: maxLength,
            maxLines: multiline ? 3 : 1,
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              counterText: '',
              border: OutlineInputBorder(
                borderSide: BorderSide(color: colors.divider),
                borderRadius: BorderRadius.circular(8),
              ),
              enabledBorder: OutlineInputBorder(
                borderSide: BorderSide(color: colors.divider),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 用户选择器页（对应 H5 UserFormPicker）：simple-list 全量本地搜索，
/// 隐藏自己、已是好友的置灰显示「已添加」。
class _UserPickerPage extends StatefulWidget {
  final List<SimpleUser> users;
  final Set<int> friendIds;
  final SimpleUser? current;

  const _UserPickerPage({
    required this.users,
    required this.friendIds,
    required this.current,
  });

  @override
  State<_UserPickerPage> createState() => _UserPickerPageState();
}

class _UserPickerPageState extends State<_UserPickerPage> {
  String _keyword = '';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final myUserId = AuthManager.instance.userId ?? 0;
    final kw = _keyword.trim().toLowerCase();
    final list = widget.users
        .where((u) => u.id != myUserId) // 隐藏自己
        .where((u) =>
            kw.isEmpty ||
            u.nickname.toLowerCase().contains(kw) ||
            u.id.toString().contains(kw))
        .toList();
    return Scaffold(
      backgroundColor: colors.bg,
      body: Column(
        children: [
          Container(
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
                            '选择用户',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              color: colors.surfaceText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 搜索框
                  Container(
                    height: 36,
                    margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                    decoration: BoxDecoration(
                      color: colors.card,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 13),
                        Icon(Icons.search, size: 22, color: colors.muted),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            onChanged: (v) => setState(() => _keyword = v),
                            decoration: InputDecoration(
                              hintText: '搜索昵称 / 用户编号',
                              isCollapsed: true,
                              border: InputBorder.none,
                              hintStyle:
                                  TextStyle(fontSize: 15, color: colors.muted),
                            ),
                            style: TextStyle(fontSize: 15, color: colors.text),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              itemCount: list.length,
              separatorBuilder: (_, _) =>
                  Divider(height: 1, indent: 82, color: colors.divider),
              itemBuilder: (context, i) {
                final u = list[i];
                final isFriend = widget.friendIds.contains(u.id);
                final selected = widget.current?.id == u.id;
                return InkWell(
                  // 已是好友不可选（置灰显示「已添加」）
                  onTap: isFriend
                      ? null
                      : () => Navigator.of(context).pop(u),
                  child: Container(
                    color: colors.card,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: Opacity(
                      opacity: isFriend ? 0.45 : 1,
                      child: Row(
                        children: [
                          ImAvatar(src: u.avatar, name: u.nickname, size: 46),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  u.nickname.isEmpty ? '用户${u.id}' : u.nickname,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 16, color: colors.text),
                                ),
                                if (u.deptName.isNotEmpty)
                                  Text(
                                    u.deptName,
                                    style: TextStyle(
                                        fontSize: 12, color: colors.muted),
                                  ),
                              ],
                            ),
                          ),
                          if (isFriend)
                            Text('已添加',
                                style: TextStyle(
                                    fontSize: 13, color: colors.muted))
                          else if (selected)
                            const Icon(Icons.check_circle,
                                size: 20, color: AppColors.lime),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
