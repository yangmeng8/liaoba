import 'package:flutter/material.dart';
import 'app_colors.dart';

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
  Widget build(BuildContext context) => Container(
    color: AppColors.lime,
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
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                ...actions,
              ],
            ),
            if (showSearch) const SearchBox(inHeader: true),
          ],
        ),
      ),
    ),
  );
}

class SearchBox extends StatelessWidget {
  final bool inHeader;
  const SearchBox({super.key, this.inHeader = false});
  @override
  Widget build(BuildContext context) => Container(
    height: inHeader ? 36 : 42,
    margin: inHeader
        ? const EdgeInsets.only(top: 12)
        : const EdgeInsets.fromLTRB(18, 0, 18, 12),
    decoration: BoxDecoration(
      color: const Color(0xFFF5FFD8),
      borderRadius: BorderRadius.circular(14),
    ),
    child: const Row(
      children: [
        SizedBox(width: 13),
        Icon(Icons.search, size: 22, color: AppColors.muted),
        SizedBox(width: 8),
        Text('搜索', style: TextStyle(fontSize: 16, color: AppColors.muted)),
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  final String label;
  const EmptyState({super.key, required this.label});
  @override
  Widget build(BuildContext context) => LayoutBuilder(
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
              child: Icon(Icons.inbox_outlined, size: compact ? 58 : 78),
            ),
            SizedBox(height: compact ? 14 : 22),
            Text(
              label,
              style: TextStyle(
                fontSize: compact ? 16 : 18,
                color: AppColors.muted,
              ),
            ),
          ],
        ),
      );
    },
  );
}
