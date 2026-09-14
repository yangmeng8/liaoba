import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_theme.dart';

class AppHeader extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  final bool showSearch;

  /// 搜索框输入回调（showSearch 时生效）
  final ValueChanged<String>? onSearchChanged;
  const AppHeader({
    super.key,
    required this.title,
    this.actions = const [],
    this.showSearch = false,
    this.onSearchChanged,
  });
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      color: colors.surface,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 14, 10),
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w600,
                        color: colors.surfaceText,
                      ),
                    ),
                  ),
                  ...actions.map((a) => IconTheme(
                        data: IconThemeData(color: colors.surfaceText),
                        child: a,
                      )),
                ],
              ),
              if (showSearch) SearchBox(inHeader: true, onChanged: onSearchChanged),
            ],
          ),
        ),
      ),
    );
  }
}

/// 可输入搜索框：输入即回调（onChanged），有内容时显示清除按钮。
class SearchBox extends StatefulWidget {
  final bool inHeader;
  final ValueChanged<String>? onChanged;
  final String hintText;
  const SearchBox({
    super.key,
    this.inHeader = false,
    this.onChanged,
    this.hintText = '搜索',
  });
  @override
  State<SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<SearchBox> {
  final TextEditingController _ctrl = TextEditingController();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      final has = _ctrl.text.isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
      widget.onChanged?.call(_ctrl.text);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: widget.inHeader ? 36 : 42,
      margin: widget.inHeader
          ? const EdgeInsets.only(top: 12)
          : const EdgeInsets.fromLTRB(18, 0, 18, 12),
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
              controller: _ctrl,
              textInputAction: TextInputAction.search,
              // isCollapsed：去掉内边距，保证固定高度容器内不溢出
              decoration: InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: widget.hintText,
                hintStyle: TextStyle(fontSize: 16, color: colors.muted),
                contentPadding: EdgeInsets.zero,
              ),
              style: TextStyle(fontSize: 15, color: colors.text),
            ),
          ),
          if (_hasText) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: _ctrl.clear,
              child: Icon(Icons.cancel, size: 18, color: colors.muted),
            ),
          ],
          const SizedBox(width: 13),
        ],
      ),
    );
  }
}

/// 头部下拉菜单项（图标 + 文字）。
class HeaderMenuItem {
  final IconData icon;
  final String label;
  const HeaderMenuItem({required this.icon, required this.label});
}

/// 微信风格头部下拉菜单（按钮正下方弹出 + 小箭头 + 点外部关闭 + 入场动画）。
/// 便捷入口见 [showHeaderMenu]。
void showHeaderMenu({
  required BuildContext anchorContext,
  required List<HeaderMenuItem> items,
  required ValueChanged<int> onSelect,
}) {
  final render = anchorContext.findRenderObject();
  if (render is! RenderBox) return;
  // 按钮底部右角全局坐标 → 菜单锚点（右缘对齐按钮，顶部贴按钮下缘）
  final anchor = render.localToGlobal(render.size.bottomRight(Offset.zero));
  final overlay = Overlay.of(anchorContext);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => HeaderMenuOverlay(
      anchorTop: anchor.dy,
      anchorRight: MediaQuery.of(anchorContext).size.width - anchor.dx,
      items: items,
      onDismiss: () => entry.remove(),
      onSelect: (i) {
        entry.remove();
        onSelect(i);
      },
    ),
  );
  overlay.insert(entry);
}

/// 下拉菜单浮层本体（一般经 [showHeaderMenu] 使用）。
class HeaderMenuOverlay extends StatelessWidget {
  /// 菜单顶部锚点（全局 y 坐标）。
  final double anchorTop;

  /// 菜单右缘距屏幕右缘距离。
  final double anchorRight;

  final List<HeaderMenuItem> items;
  final VoidCallback onDismiss;
  final ValueChanged<int> onSelect;

  const HeaderMenuOverlay({
    super.key,
    required this.anchorTop,
    required this.anchorRight,
    required this.items,
    required this.onDismiss,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Stack(children: [
      // 全屏透明屏障：点击外部关闭
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onDismiss,
        ),
      ),
      Positioned(
        top: anchorTop,
        right: anchorRight,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 150),
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, -6 * (1 - t)),
              child: child,
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 160,
              decoration: BoxDecoration(
                color: colors.card,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 小箭头指向锚点按钮（右缩 15：箭头中心对准 48 宽按钮的中心）
                  Padding(
                    padding: const EdgeInsets.only(right: 15),
                    child: CustomPaint(
                      size: const Size(18, 7),
                      painter: _MenuArrowPainter(color: colors.card),
                    ),
                  ),
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0)
                      Divider(
                          height: 1, indent: 14, endIndent: 14, color: colors.divider),
                    InkWell(
                      onTap: () => onSelect(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 13),
                        child: Row(
                          children: [
                            Icon(items[i].icon, size: 21, color: colors.text),
                            const SizedBox(width: 10),
                            Text(
                              items[i].label,
                              style: TextStyle(fontSize: 15, color: colors.text),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// 菜单顶部小箭头（倒三角）。
class _MenuArrowPainter extends CustomPainter {
  final Color color;
  const _MenuArrowPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(0, size.height)
      ..lineTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _MenuArrowPainter old) => old.color != color;
}

class EmptyState extends StatelessWidget {
  final String label;
  const EmptyState({super.key, required this.label});
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 360;
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: compact ? 150 : 190,
                height: compact ? 105 : 140,
                decoration: BoxDecoration(
                  color: AppColors.lime,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.black, width: 2),
                ),
                child: Icon(Icons.inbox_outlined,
                    size: compact ? 58 : 78, color: const Color(0xFF1A1A1A)),
              ),
              SizedBox(height: compact ? 14 : 22),
              Text(
                label,
                style: TextStyle(
                  fontSize: compact ? 16 : 18,
                  color: colors.muted,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
