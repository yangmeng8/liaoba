import 'package:flutter/material.dart';
import '../../shared/widgets.dart';

class CallsPage extends StatelessWidget {
  const CallsPage({super.key});
  @override
  Widget build(BuildContext context) => Column(
    children: [
      AppHeader(
        title: '通话',
        showSearch: true,
        actions: [
          IconButton(
            onPressed: () {},
            icon: const Icon(Icons.playlist_add_check, size: 25),
          ),
          IconButton(
            onPressed: () {},
            icon: const Icon(Icons.add_call, size: 25),
          ),
        ],
      ),
      const Expanded(child: EmptyState(label: '暂无数据')),
    ],
  );
}
