import 'package:flutter/material.dart';

/// 桌面三栏布局（微信 PC 风格）宽度断点：
/// 窗口宽度 >= 该值时启用 左导航栏 + 中列表面板 + 右内容区 三栏布局，
/// 否则保持移动端（底部 Tab + 整页路由）布局，保证手机端零回归。
const double kDesktopBreakpoint = 900;

/// 当前窗口是否使用桌面三栏布局。
bool isDesktopLayout(BuildContext context) =>
    MediaQuery.of(context).size.width >= kDesktopBreakpoint;
