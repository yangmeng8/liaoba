import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

// show 限制：避免 image_edit_utils 再导出的 pro_image_editor 符号
// 遮蔽 material 的 Image widget
import '../../shared/image_edit_utils.dart'
    show pushImageEditor, saveEditedImage;

/// 相册多图预览 + 编辑页（迁移自 app_im，入参从 AssetEntity 改为文件路径）：
/// PageView 左右翻页预览 → 点编辑按钮编辑当前图（编辑后即时替换预览）→
/// 点「完成」把"编辑过的用新图、没编辑的用原图"合并成路径列表返回。
class ImagePreviewWithEditPage extends StatefulWidget {
  /// 待预览图片的本地路径列表。
  final List<String> paths;

  /// 初始显示第几张。
  final int initialIndex;

  const ImagePreviewWithEditPage({
    super.key,
    required this.paths,
    this.initialIndex = 0,
  });

  @override
  State<ImagePreviewWithEditPage> createState() =>
      _ImagePreviewWithEditPageState();
}

class _ImagePreviewWithEditPageState extends State<ImagePreviewWithEditPage> {
  late PageController _pageController;
  late int _currentIndex;

  /// 索引 → 编辑后的图片路径。
  final Map<int, String> _editedPaths = {};

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// 编辑当前图片（完成后替换当前页预览）。
  Future<void> _editCurrentImage() async {
    try {
      final Uint8List? editedBytes =
          await pushImageEditor(context, widget.paths[_currentIndex]);
      if (editedBytes == null || editedBytes.isEmpty) return;
      final editedPath = await saveEditedImage(editedBytes);
      if (!mounted) return;
      setState(() => _editedPaths[_currentIndex] = editedPath);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text('编辑失败: $e')));
      }
    }
  }

  /// 完成：编辑过的用新图、没编辑的用原图，返回路径列表。
  void _completeSelection() {
    final resultPaths = <String>[];
    for (var i = 0; i < widget.paths.length; i++) {
      resultPaths.add(_editedPaths[i] ?? widget.paths[i]);
    }
    Navigator.of(context).pop(resultPaths);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit, color: Colors.white),
            onPressed: _editCurrentImage,
            tooltip: '编辑',
          ),
          TextButton(
            onPressed: _completeSelection,
            child: const Text(
              '完成',
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.paths.length,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        itemBuilder: (context, index) => Center(
          child: Image.file(
            File(_editedPaths[index] ?? widget.paths[index]),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => const Text(
              '加载失败',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
      bottomNavigationBar: widget.paths.length > 1
          ? Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              color: Colors.black87,
              child: Text(
                '${_currentIndex + 1} / ${widget.paths.length}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            )
          : null,
    );
  }
}
