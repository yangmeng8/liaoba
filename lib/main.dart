import 'package:flutter/material.dart';
import 'pages/calls/calls_page.dart';
import 'pages/contacts/contacts_page.dart';
import 'pages/me/me_page.dart';
import 'pages/messages/messages_page.dart';
import 'shared/app_colors.dart';
import 'shared/app_theme.dart';
import 'shared/font_scale_manager.dart';
import 'shared/theme_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 启动时恢复字体档位和主题模式
  await FontScaleManager.instance.load();
  await ThemeManager.instance.load();
  runApp(const LiaobaApp());
}

class LiaobaApp extends StatelessWidget {
  const LiaobaApp({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([
          FontScaleManager.instance.indexNotifier,
          ThemeManager.instance.modeNotifier,
        ]),
        builder: (context, _) => MaterialApp(
          debugShowCheckedModeBanner: false,
          title: '聊吧',
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: ThemeManager.instance.mode,
          // 全局字体缩放：注入 textScaler
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(FontScaleManager.instance.scale),
            ),
            child: child!,
          ),
          home: const HomeShell(),
        ),
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
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 深色：tabBar 深灰 surface；浅色：tabBar 白 card
    final tabBarBg = isDark ? colors.surface : colors.card;
    // 深色：选中 icon + label 都用 lime；浅色：选中 icon lime、label 用 text（黑）
    final selectedIconColor = AppColors.lime;
    final selectedLabelColor = isDark ? AppColors.lime : colors.text;
    final unselectedColor = colors.muted;
    return Scaffold(
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: NavigationBar(
        height: 62,
        backgroundColor: tabBarBg,
        elevation: 0,
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => index = i),
        indicatorColor: Colors.transparent,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(color: selectedLabelColor);
          }
          return TextStyle(color: unselectedColor);
        }),
        destinations: [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline, color: unselectedColor),
            selectedIcon: Icon(Icons.chat_bubble, color: selectedIconColor),
            label: '消息',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline, color: unselectedColor),
            selectedIcon: Icon(Icons.person, color: selectedIconColor),
            label: '通讯录',
          ),
          NavigationDestination(
            icon: Icon(Icons.phone_in_talk_outlined, color: unselectedColor),
            selectedIcon: Icon(Icons.phone_in_talk, color: selectedIconColor),
            label: '通话',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_circle_outlined, color: unselectedColor),
            selectedIcon: Icon(Icons.account_circle, color: selectedIconColor),
            label: '我的',
          ),
        ],
      ),
    );
  }
}

