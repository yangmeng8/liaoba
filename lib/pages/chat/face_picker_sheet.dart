import 'package:flutter/material.dart';

import '../../models/im_face.dart';
import '../../services/im_api.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/im_emoji.dart';

/// 表情选择面板（对应 H5 face-picker）：
/// 内嵌于聊天页输入栏下方（非 modal 弹层），输入框始终保持在面板头顶可见。
/// - emoji 页签：插入输入框文本（随 TEXT 消息发送，不独立成消息）
/// - 收藏 / 表情包页签：点击立即发送 FACE 消息 {url,width,height}
///   长按收藏表情可删除。
/// 数据懒加载：首次挂载时拉取，成功后缓存（CACHE_SUCCESS 模式）。
class FacePickerSheet extends StatefulWidget {
  /// 选择 emoji（插入输入框）。
  final ValueChanged<String> onEmojiSelected;

  /// 选择图片表情（立即发送 FACE 消息）。
  final ValueChanged<ImFaceItem> onFaceSelected;

  const FacePickerSheet({
    super.key,
    required this.onEmojiSelected,
    required this.onFaceSelected,
  });

  @override
  State<FacePickerSheet> createState() => _FacePickerSheetState();
}

class _FacePickerSheetState extends State<FacePickerSheet>
    with TickerProviderStateMixin {
  /// 先建 2 个页签（表情/收藏），数据加载成功后按表情包数量重建。
  late TabController _tabCtrl = TabController(length: 2, vsync: this);

  List<ImFaceItem> _userItems = [];
  List<ImFacePack> _packs = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  /// 懒加载：首次打开拉取表情包 + 个人收藏，成功后缓存不再重复请求。
  Future<void> _load() async {
    try {
      final results = await Future.wait([
        ImApi.getFacePackList(),
        ImApi.getFaceUserItemList(),
      ]);
      if (!mounted) return;
      final packs = results[0] as List<ImFacePack>;
      final userItems = results[1] as List<ImFaceItem>;
      // 重建页签：表情 + 收藏 + 各表情包（先释放旧 controller 再替换）
      final newCtrl = TabController(length: 2 + packs.length, vsync: this);
      _tabCtrl.dispose();
      setState(() {
        _packs = packs;
        _userItems = userItems;
        _loaded = true;
        _tabCtrl = newCtrl;
      });
    } catch (_) {
      // 失败仍提供 emoji 页签（本地数据）
      if (!mounted) return;
      final newCtrl = TabController(length: 2, vsync: this);
      _tabCtrl.dispose();
      setState(() {
        _loaded = true;
        _tabCtrl = newCtrl;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final height = MediaQuery.of(context).size.height * 0.45;

    final isLight = Theme.of(context).brightness == Brightness.light;
    final panelColor =
        isLight ? const Color(0xFFEDE4D8) : context.colors.bg; // 与输入栏一致

    // _load 完成前先渲染 emoji（TabController 异步创建）
    final ctrl = _tabCtrl;
    if (!_loaded) {
      return Container(
        height: height,
        color: panelColor,
        child: const Center(
          child: CircularProgressIndicator(color: AppColors.lime),
        ),
      );
    }

    return Container(
      height: height,
      color: panelColor,
      // 底部安全区由面板处理（输入栏展开面板时已去掉自身 SafeArea bottom）
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // 页签
            Material(
              color: panelColor,
              child: TabBar(
                controller: ctrl,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelColor: colors.text,
                unselectedLabelColor: colors.muted,
                indicatorColor: AppColors.lime,
                dividerColor: colors.divider,
                tabs: [
                  const Tab(text: '表情'),
                  const Tab(text: '收藏'),
                  for (final p in _packs) Tab(text: p.name),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                controller: ctrl,
                children: [
                  _buildEmojiGrid(colors),
                  _buildFaceGrid(colors, _userItems, deletable: true),
                  for (final p in _packs)
                    _buildFaceGrid(colors, p.items, deletable: false),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// emoji 网格：点击插入输入框。
  Widget _buildEmojiGrid(ThemeColors colors) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 8,
        childAspectRatio: 1,
      ),
      itemCount: kImEmojiList.length,
      itemBuilder: (context, i) {
        final emoji = kImEmojiList[i];
        return InkWell(
          onTap: () => widget.onEmojiSelected(emoji),
          borderRadius: BorderRadius.circular(6),
          child: Center(
            child: Text(emoji, style: const TextStyle(fontSize: 24)),
          ),
        );
      },
    );
  }

  /// 图片表情网格：点击发送 FACE 消息；[deletable] 时长按删除（个人收藏）。
  Widget _buildFaceGrid(
    ThemeColors colors,
    List<ImFaceItem> items, {
    required bool deletable,
  }) {
    if (items.isEmpty) {
      return Center(
        child: Text(
          '暂无表情',
          style: TextStyle(fontSize: 13, color: colors.muted),
        ),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 1,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        final url = _normalizeUrl(item.url);
        return GestureDetector(
          onTap: () => widget.onFaceSelected(item),
          onLongPress: deletable ? () => _confirmDelete(context, item) : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              url,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                color: colors.divider,
                alignment: Alignment.center,
                child: Text(
                  item.name,
                  maxLines: 1,
                  style: TextStyle(fontSize: 11, color: colors.muted),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// 删除确认（个人收藏表情）。
  Future<void> _confirmDelete(BuildContext context, ImFaceItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除表情', style: TextStyle(fontSize: 16)),
        content: const Text('确定删除该收藏表情吗？', style: TextStyle(fontSize: 14)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFFA5151))),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ImApi.deleteFaceUserItem(id: item.id);
      if (mounted) {
        setState(() => _userItems.removeWhere((e) => e.id == item.id));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          this.context,
        ).showSnackBar(const SnackBar(content: Text('删除失败，请重试')));
      }
    }
  }
}

/// 后端测试数据 URL 可能被反引号包裹（`http://...`），加载前剥掉。
String _normalizeUrl(String url) {
  var u = url.trim();
  while (u.startsWith('`') || u.endsWith('`')) {
    u = u.replaceAll('`', '');
  }
  return u;
}

/// 供外部复用的 URL 清洗（语音/表情图片统一走这里）。
String normalizeFaceUrl(String url) => _normalizeUrl(url);
