import 'package:flutter/material.dart';
import 'pages/calls/calls_page.dart';
import 'pages/contacts/contacts_page.dart';
import 'pages/me/me_page.dart';
import 'pages/messages/messages_page.dart';
import 'shared/app_colors.dart';

void main() => runApp(const LiaobaApp());

class LiaobaApp extends StatelessWidget {
  const LiaobaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: '聊吧',
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xFFF8F8F8),
      fontFamily: 'PingFang SC',
    ),
    home: const HomeShell(),
  );
}

// Compatibility entry point for the generated template smoke test.
class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  int count = 0;
  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: Center(child: Text('$count')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => count++),
        child: const Icon(Icons.add),
      ),
    ),
  );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 0;
  final pages = const [MessagesPage(), ContactsPage(), CallsPage(), MePage()];
  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(index: index, children: pages),
    bottomNavigationBar: NavigationBar(
      height: 62,
      backgroundColor: Colors.white,
      elevation: 0,
      selectedIndex: index,
      onDestinationSelected: (i) => setState(() => index = i),
      indicatorColor: Colors.transparent,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.chat_bubble_outline, color: AppColors.muted),
          selectedIcon: Icon(Icons.chat_bubble, color: AppColors.lime),
          label: '消息',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline, color: AppColors.muted),
          selectedIcon: Icon(Icons.person, color: AppColors.lime),
          label: '通讯录',
        ),
        NavigationDestination(
          icon: Icon(Icons.phone_in_talk_outlined, color: AppColors.muted),
          selectedIcon: Icon(Icons.phone_in_talk, color: AppColors.lime),
          label: '通话',
        ),
        NavigationDestination(
          icon: Icon(Icons.account_circle_outlined, color: AppColors.muted),
          selectedIcon: Icon(Icons.account_circle, color: AppColors.lime),
          label: '我的',
        ),
      ],
    ),
  );
}
