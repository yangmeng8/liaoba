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
