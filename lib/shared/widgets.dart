import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_theme.dart';

class AppHeader extends StatelessWidget {
  final String title;
  final List<Widget> actions;
  final bool showSearch;
  const AppHeader({
    super.key,
    required this.title,
    this.actions = const [],
    this.showSearch = false,
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
                        fontWeight: FontWeight.w800,
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
              if (showSearch) const SearchBox(inHeader: true),
            ],
          ),
        ),
      ),
    );
  }
}

class SearchBox extends StatelessWidget {
  final bool inHeader;
  const SearchBox({super.key, this.inHeader = false});
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: inHeader ? 36 : 42,
      margin: inHeader
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
          Text('搜索', style: TextStyle(fontSize: 16, color: colors.muted)),
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
