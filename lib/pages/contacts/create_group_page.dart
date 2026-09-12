import 'package:flutter/material.dart';

import '../../models/im_conversation.dart';
import '../../services/api_client.dart';
import '../../services/im_api.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/im_avatar.dart';
import '../../pages/chat/chat_page.dart';

/// 创建群聊页：群名 + 好友多选（字母分桶）→ create 接口 → 直接进聊天室。
class CreateGroupPage extends StatefulWidget {
  const CreateGroupPage({super.key});

  @override
  State<CreateGroupPage> createState() => _CreateGroupPageState();
}

class _CreateGroupPageState extends State<CreateGroupPage> {
  final _nameCtrl = TextEditingController();
  List<ImFriend> _friends = [];
  final Set<int> _selected = {};
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadFriends();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadFriends() async {
    try {
      final friends = await ImApi.getFriendList();
      if (!mounted) return;
      setState(() => _friends = friends
          .where((f) => f.status == ImCommonStatus.enable && !f.blocked)
          .toList());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('好友加载失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 创建群聊：选中的好友作为初始成员 → 直接进聊天室。
  Future<void> _submit() async {
    if (_submitting) return;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('请填写群聊名称')));
      return;
    }
    if (_selected.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('请至少选择一位好友')));
      return;
    }
    setState(() => _submitting = true);
    try {
      final group = await ImApi.createGroup(
        name: name,
        memberUserIds: _selected.toList(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('创建成功')));
      // 清栈回聊天室（替换当前页，返回时回通讯录）
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatPage(
            type: ImConversationType.group,
            targetId: group.id,
            title: group.name,
            avatar: group.avatar,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(ApiClient.errorMessage(e))));
    }
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
                    padding: EdgeInsets.zero, // 去掉自动附加的顶部安全区空白
                    children: [
                      _buildNameField(colors),
                      const SizedBox(height: 10),
                      _buildSelectedBar(colors),
                      _buildFriendList(colors),
                    ],
                  ),
          ),
          _buildSubmitBar(colors),
        ],
      ),
    );
  }

  /// 底部固定操作条：创建群聊主按钮（显示已选人数）。
  Widget _buildSubmitBar(ThemeColors colors) {
    final enabled = !_submitting;
    return SafeArea(
      top: false,
      child: Container(
        color: colors.bg,
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
        child: SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.lime,
              disabledBackgroundColor: colors.divider,
              foregroundColor: Colors.black,
              disabledForegroundColor: colors.muted,
            ),
            onPressed: enabled ? _submit : null,
            child: Text(
              _submitting
                  ? '创建中…'
                  : _selected.isEmpty
                      ? '创建群聊'
                      : '创建群聊（已选 ${_selected.length} 人）',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
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
                  '创建群聊',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: colors.surfaceText,
                  ),
                ),
              ),
              // TextButton(
              //   onPressed: _submitting ? null : _submit,
              //   child: Text(
              //     _submitting ? '创建中…' : '创建',
              //     // surfaceText：浅色 lime 头配黑字，深色灰头配白字（避免 lime 叠 lime 不可见）
              //     style: TextStyle(
              //         fontSize: 15,
              //         fontWeight: FontWeight.w600,
              //         color: colors.surfaceText),
              //   ),
              // ),
            ],
          ),
        ),
      ),
    );
  }

  /// 群名输入（默认「xxx的群聊」，xxx=我的昵称——对齐常见 IM 习惯）。
  Widget _buildNameField(ThemeColors colors) {
    return Container(
      color: colors.card,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: TextField(
        controller: _nameCtrl,
        maxLength: 30,
        decoration: InputDecoration(
          labelText: '群聊名称',
          hintText: '请输入群聊名称',
          counterText: '',
          border: InputBorder.none,
        ),
      ),
    );
  }

  /// 已选成员横滑条（头像 + 移除）。
  Widget _buildSelectedBar(ThemeColors colors) {
    if (_selected.isEmpty) return const SizedBox.shrink();
    final selected = _friends.where((f) => _selected.contains(f.friendUserId));
    return Container(
      color: colors.card,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.symmetric(vertical: 10),
      // 高度随内容自适应（不固定 60，避免字体缩放下行高溢出）
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final f in selected)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GestureDetector(
                  onTap: () =>
                      setState(() => _selected.remove(f.friendUserId)),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          ImAvatar(
                              src: f.avatar, name: f.shownName, size: 44),
                          Positioned(
                            right: -4,
                            top: -4,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: colors.surface,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(Icons.cancel,
                                  size: 14, color: colors.muted),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        f.shownName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, color: colors.muted),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 好友多选列表（点击切换选中）。
  Widget _buildFriendList(ThemeColors colors) {
    if (_friends.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Center(
          child: Text('暂无好友可邀请',
              style: TextStyle(color: colors.muted, fontSize: 15)),
        ),
      );
    }
    return Container(
      color: colors.card,
      margin: const EdgeInsets.only(top: 10),
      child: Column(
        children: [
          for (var i = 0; i < _friends.length; i++) ...[
            if (i > 0) Divider(height: 1, indent: 82, color: colors.divider),
            _buildFriendRow(colors, _friends[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildFriendRow(ThemeColors colors, ImFriend f) {
    final selected = _selected.contains(f.friendUserId);
    return InkWell(
      onTap: () => setState(() {
        if (!_selected.add(f.friendUserId)) {
          _selected.remove(f.friendUserId);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            ImAvatar(src: f.avatar, name: f.shownName, size: 44),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                f.shownName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 16, color: colors.text),
              ),
            ),
            // 选中态勾选框（lime 主题色）
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? AppColors.lime : null,
                border: Border.all(
                  color: selected ? AppColors.lime : colors.muted,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 16, color: Colors.black)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
