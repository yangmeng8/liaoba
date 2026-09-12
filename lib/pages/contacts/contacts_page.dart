import 'package:flutter/material.dart';

import '../../models/im_conversation.dart';
import '../../services/im_api.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/im_avatar.dart';
import '../../shared/widgets.dart';
import 'create_group_page.dart';
import 'friend_apply_page.dart';
import 'friend_buckets.dart';
import 'group_list_page.dart';
import 'request_center_page.dart';
import 'user_profile_page.dart';

/// 通讯录主页（对应 H5 /contact/index）：
/// 搜索（六路拼音命中）+ 新的朋友/群聊入口 + 好友字母分桶列表 + 右侧索引条；
/// 搜索态隐藏入口和索引条，平铺匹配结果。
class ContactsPage extends StatefulWidget {
  const ContactsPage({super.key});

  @override
  State<ContactsPage> createState() => _ContactsPageState();
}

class _ContactsPageState extends State<ContactsPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  /// 好友全量（页面本地拉取，无分页）。
  List<ImFriend> _friends = [];
  bool _loading = true;

  /// 分组头锚点（索引条点击滚动定位用）。
  final Map<String, BuildContext> _bucketContexts = {};

  String get _keyword => _searchCtrl.text;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final friends = await ImApi.getFriendList();
      if (!mounted) return;
      setState(() => _friends = friends);
    } catch (_) {
      // 失败保留旧数据；空数据时展示空态
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 搜索结果（平铺，不分桶）。
  List<ImFriend> get _matched =>
      activeFriends(_friends.where((f) => friendMatch(f, _keyword)).toList());

  /// 字母分桶（非搜索态）。
  List<FriendBucket> get _buckets => buildFriendBuckets(activeFriends(_friends));

  /// 右上角「+」：action sheet（添加好友 / 创建群聊，对齐 H5）。
  Future<void> _showAddSheet() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: context.colors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person_add_alt_1_outlined, size: 26),
              title: const Text('添加好友', style: TextStyle(fontSize: 16)),
              onTap: () => Navigator.of(ctx).pop('friend'),
            ),
            ListTile(
              leading: const Icon(Icons.group_add_outlined, size: 26),
              title: const Text('创建群聊', style: TextStyle(fontSize: 16)),
              onTap: () => Navigator.of(ctx).pop('group'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'friend') {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const FriendApplyPage()),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const CreateGroupPage()),
      );
    }
  }

  /// 索引条点击 → 滚动到对应分组头。
  void _scrollToBucket(String letter) {
    final ctx = _bucketContexts[letter];
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 200));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final searching = _keyword.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppHeader(
          title: '通讯录',
          actions: [
            IconButton(
              onPressed: _showAddSheet,
              icon: const Icon(Icons.add_circle_outline, size: 25),
            ),
          ],
        ),
        _buildSearchBox(colors),
        Expanded(
          child: searching
              ? _buildFlatList(colors)
              : Stack(
                  children: [
                    _buildBucketList(colors),
                    _buildIndexBar(colors),
                  ],
                ),
        ),
      ],
    );
  }

  /// 可输入搜索框（样式对齐 SearchBox；拼音六路命中在 friend_buckets）。
  Widget _buildSearchBox(ThemeColors colors) {
    return Container(
      height: 36,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 8),
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
              controller: _searchCtrl,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '搜索',
                isCollapsed: true,
                border: InputBorder.none,
                hintStyle: TextStyle(fontSize: 16, color: colors.muted),
              ),
              style: TextStyle(fontSize: 16, color: colors.text),
            ),
          ),
          if (_keyword.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchCtrl.clear();
                setState(() {});
              },
              child: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Icon(Icons.cancel, size: 18, color: colors.muted),
              ),
            ),
        ],
      ),
    );
  }

  /// 搜索态：平铺匹配结果（不分桶、无入口、无索引条）。
  Widget _buildFlatList(ThemeColors colors) {
    final list = _matched;
    if (list.isEmpty && !_loading) {
      return const EmptyState(label: '没有匹配的好友');
    }
    return RefreshIndicator(
      color: AppColors.lime,
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: list.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, indent: 78, color: colors.divider),
        itemBuilder: (context, i) => _FriendTile(friend: list[i]),
      ),
    );
  }

  /// 非搜索态：入口卡 + 字母分桶列表。
  Widget _buildBucketList(ThemeColors colors) {
    final buckets = _buckets;
    return RefreshIndicator(
      color: AppColors.lime,
      onRefresh: _load,
      child: ListView.builder(
        controller: _scrollCtrl,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        // +1：入口卡区；无好友时再 +1 展示加载/空态
        itemCount: buckets.length + 1 + (buckets.isEmpty ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == 0) {
            return Container(
              decoration: BoxDecoration(
                color: colors.card,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  _EntryTile(
                    icon: Icons.person_add_alt_1_outlined,
                    title: '新的朋友',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const RequestCenterPage()),
                    ),
                  ),
                  Divider(height: 1, indent: 78, color: colors.divider),
                  _EntryTile(
                    icon: Icons.groups_outlined,
                    title: '群聊',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const GroupListPage()),
                    ),
                  ),
                ],
              ),
            );
          }
          // 无好友：loading / 空态（对齐 H5「暂无好友」）
          if (buckets.isEmpty) {
            if (_loading) {
              return const Padding(
                padding: EdgeInsets.all(40),
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.lime),
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.all(40),
              child: Center(
                child: Text('暂无好友',
                    style: TextStyle(color: colors.muted, fontSize: 15)),
              ),
            );
          }
          final bucket = buckets[index - 1];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 分组头（索引条锚点）
              Builder(
                builder: (ctx) {
                  _bucketContexts[bucket.letter] = ctx;
                  return Container(
                    width: double.infinity,
                    color: colors.bg,
                    padding:
                        const EdgeInsets.fromLTRB(20, 6, 20, 6),
                    child: Text(
                      bucket.letter,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colors.muted,
                      ),
                    ),
                  );
                },
              ),
              Container(
                color: colors.card,
                child: Column(
                  children: [
                    for (var i = 0; i < bucket.friends.length; i++) ...[
                      if (i > 0)
                        Divider(
                            height: 1, indent: 78, color: colors.divider),
                      _FriendTile(friend: bucket.friends[i]),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 右侧字母索引条：点击滚动到对应分组头（对齐 H5 AZIndexBar）。
  Widget _buildIndexBar(ThemeColors colors) {
    final buckets = _buckets;
    if (buckets.isEmpty) return const SizedBox.shrink();
    return Positioned(
      right: 2,
      top: 0,
      bottom: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final bucket in buckets)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _scrollToBucket(bucket.letter),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
                    child: Text(
                      bucket.letter,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: colors.muted,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 入口行（新的朋友/群聊）：lime 圆形图标 + 标题。
class _EntryTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;

  const _EntryTile({required this.icon, required this.title, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: 60,
        child: Row(
          children: [
            const SizedBox(width: 18),
            Container(
              width: 45,
              height: 45,
              decoration: const BoxDecoration(
                color: AppColors.lime,
                shape: BoxShape.circle,
              ),
              // lime 底为亮色，图标固定深色，不随主题切换
              child: Icon(icon, size: 25, color: const Color(0xFF1A1A1A)),
            ),
            const SizedBox(width: 22),
            Text(
              title,
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w500, color: colors.text),
            ),
            const Spacer(),
            Icon(Icons.chevron_right, size: 22, color: colors.muted),
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }
}

/// 好友行：头像 + 展示名；点击进好友资料页（三态复用页）。
class _FriendTile extends StatelessWidget {
  final ImFriend friend;

  const _FriendTile({required this.friend});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => UserProfilePage(userId: friend.friendUserId),
        ),
      ),
      child: SizedBox(
        height: 58,
        child: Row(
          children: [
            const SizedBox(width: 18),
            ImAvatar(src: friend.avatar, name: friend.shownName, size: 44),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                friend.shownName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 16, color: colors.text),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
