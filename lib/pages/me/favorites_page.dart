import 'dart:math';
import 'package:flutter/material.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';

/// 我的收藏页面：分类 Tab + 空状态插画。
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  static const _tabs = ['全部', '文字', '图片与视频', '语音', '文件'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    _tabController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    const accent = Color(0xFF4ECDC4); // 与登录页链接等强调色保持一致

    return Scaffold(
      backgroundColor: colors.bg,
      body: Column(
        children: [
          // 顶栏：返回、标题、搜索
          Container(
            color: colors.surface,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 64,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        tooltip: '返回',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(Icons.chevron_left,
                            size: 34, color: colors.surfaceText),
                      ),
                    ),
                    Text(
                      '我的收藏',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: colors.surfaceText,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        tooltip: '搜索',
                        onPressed: () {
                          // TODO: 跳转到收藏搜索页
                          _toast('搜索收藏');
                        },
                        icon: Icon(Icons.search,
                            size: 26, color: colors.surfaceText),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 分类 TabBar（无 indicator box，青色选中色 + 下划线）
          Container(
            height: 42,
            color: colors.bg,
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TabBar(
                controller: _tabController,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerColor: Colors.transparent,
                labelPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                labelColor: accent,
                unselectedLabelColor: colors.muted,
                labelStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                ),
                indicatorColor: accent,
                indicatorWeight: 3,
                indicatorSize: TabBarIndicatorSize.label,
                indicatorPadding: EdgeInsets.zero,
                tabs: [for (final t in _tabs) Tab(text: t)],
              ),
            ),
          ),
          // Tab 底部一条细分割线（可选）
       

          // Tab View：所有分类都是空状态
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                for (int i = 0; i < _tabs.length; i++)
                  _EmptyView(category: _tabs[i], colors: colors),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// 空状态：lime 插画框 + 文字提示。
class _EmptyView extends StatelessWidget {
  final String category;
  final ThemeColors colors;

  const _EmptyView({required this.category, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 插画占位：lime 圆角方形背景 + 图标组合（对应截图中的风格）
          Container(
            width: 180,
            height: 180,
            decoration: BoxDecoration(
              color: AppColors.lime,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: Colors.black, width: 1.5),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // 底部黑色半圆舞台
                  Positioned(
                    bottom: -24,
                    child: Container(
                      width: 200,
                      height: 80,
                      decoration: const BoxDecoration(
                        color: Colors.black,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  // 帐篷主体（白色梯形，用带倾斜的矩形模拟）
                  Positioned(
                    bottom: 10,
                    child: Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.skewY(0.0),
                      child: const _Tent(),
                    ),
                  ),
                  // 小人（蹲坐的人形，白色）
                  const Positioned(
                    bottom: 14,
                    child: Icon(Icons.person, color: Colors.white, size: 28),
                  ),
                  // 左上角飞出的礼物盒
                  Positioned(
                    top: 30,
                    left: 24,
                    child: RotationTransition(
                      turns: const AlwaysStoppedAnimation(-0.2),
                      child: _giftBox,
                    ),
                  ),
                  // 右上角叶片 + 虚线轨迹
                  const Positioned(
                    top: 28,
                    right: 26,
                    child: Icon(Icons.eco_rounded,
                        color: Colors.black, size: 26),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 36),
          Text(
            '收藏夹暂无内容',
            style: TextStyle(
              fontSize: 20,
              color: colors.muted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  /// 手绘礼物盒。
  static const _giftBox = SizedBox(
    width: 46,
    height: 46,
    child: Stack(
      alignment: Alignment.center,
      children: [
        // 盒子
        Icon(Icons.inbox_rounded, color: Colors.white, size: 40),
        // 盒盖弹出效果（小三角/虚线）
        Positioned(
          top: 0,
          right: 2,
          child: Icon(Icons.open_in_full,
              color: Colors.black, size: 16),
        ),
        // 高光
        Positioned(
          top: 6,
          left: 6,
          child: Icon(Icons.done, color: Colors.white, size: 18),
        ),
      ],
    ),
  );
}

/// 帐篷：用两个斜面 + 一个正面三角形模拟。
class _Tent extends StatelessWidget {
  const _Tent();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 130,
      height: 90,
      child: CustomPaint(
        painter: _TentPainter(),
      ),
    );
  }
}

class _TentPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // 主体三角形帐篷
    final tentPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(w * 0.15, h)
      ..lineTo(w * 0.5, 0)
      ..lineTo(w * 0.85, h)
      ..close();
    canvas.drawPath(path, tentPaint);

    // 分面分隔线（中间折痕）
    final line = Paint()
      ..color = Colors.black26
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(w * 0.5, 0),
      Offset(w * 0.5, h),
      line,
    );

    // 帐篷轮廓
    final outline = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    canvas.drawPath(path, outline);

    // 虚线轨迹从叶片指向帐篷出口
    final dash = Paint()
      ..color = Colors.black
      ..strokeWidth = 1.5;
    const dashWidth = 4.0;
    const dashSpace = 4.0;
    final from = Offset(w * 0.82, 12);
    final to = Offset(w * 0.62, h * 0.45);
    final dx = to.dx - from.dx;
    final dy = to.dy - from.dy;
    final dist = sqrt(dx * dx + dy * dy);
    final steps = (dist / (dashWidth + dashSpace)).round();
    final stepDx = dx / steps;
    final stepDy = dy / steps;
    for (var i = 0; i < steps; i += 2) {
      final x1 = from.dx + stepDx * i;
      final y1 = from.dy + stepDy * i;
      final x2 = x1 + stepDx;
      final y2 = y1 + stepDy;
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), dash);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
