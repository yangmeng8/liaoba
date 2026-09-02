import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../shared/app_colors.dart';

/// 意见反馈页面。
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _contentController = TextEditingController();
  final _contactController = TextEditingController();

  static const int _maxContentLength = 60;
  static const int _maxImageCount = 3;

  /// 已选择的图片文件。
  final List<XFile> _images = [];

  final ImagePicker _picker = ImagePicker();

  @override
  void dispose() {
    _contentController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  Future<void> _addImage() async {
    if (_images.length >= _maxImageCount) return;

    final remaining = _maxImageCount - _images.length;
    try {
      final picked = await _picker.pickMultiImage(
        imageQuality: 85,
        limit: remaining,
      );
      if (picked.isNotEmpty) {
        setState(() => _images.addAll(picked));
      }
    } catch (e) {
      _showToast('无法打开相册：$e');
    }
  }

  void _removeImageAt(int index) {
    setState(() => _images.removeAt(index));
  }

  bool get _isPhoneValid {
    final contact = _contactController.text.trim();
    if (contact.isEmpty) return true; // 选填
    return RegExp(r'^1[3-9]\d{9}$').hasMatch(contact);
  }

  void _submit() {
    final content = _contentController.text.trim();

    if (content.isEmpty) {
      _showToast('请填写反馈内容');
      return;
    }
    if (!_isPhoneValid) {
      _showToast('请输入正确的手机号码');
      return;
    }
    // TODO: 调用反馈提交接口（含图片 multipart 上传）
    _showToast('感谢您的反馈');
    Navigator.of(context).pop();
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.pageBg,
        body: Column(
          children: [
            // 顶部导航栏
            Container(
              color: AppColors.lime,
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
                          icon: const Icon(Icons.chevron_left, size: 34),
                        ),
                      ),
                      const Text(
                        '意见反馈',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 可滚动区域
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // 反馈内容标签
                            Row(
                              children: const [
                                Text(
                                  '反馈内容',
                                  style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600),
                                ),
                                Text(
                                  '*',
                                  style: TextStyle(
                                      fontSize: 16,
                                      color: Colors.redAccent),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),

                            // 反馈内容输入框
                            Container(
                              constraints: const BoxConstraints(
                                minHeight: 140,
                              ),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Stack(
                                children: [
                                  TextField(
                                    controller: _contentController,
                                    maxLength: _maxContentLength,
                                    maxLines: null,
                                    style: const TextStyle(fontSize: 15),
                                    decoration: const InputDecoration(
                                      hintText: '您的反馈将帮助我们成长',
                                      hintStyle: TextStyle(
                                          color: AppColors.muted,
                                          fontSize: 15),
                                      border: InputBorder.none,
                                      counterText: '',
                                    ),
                                    onChanged: (_) => setState(() {}),
                                  ),
                                  // 字数计数
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: Text(
                                      '${_contentController.text.length}/$_maxContentLength',
                                      style: const TextStyle(
                                          fontSize: 13,
                                          color: AppColors.muted),
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 20),

                            // 添加图片标签
                            RichText(
                              text: const TextSpan(
                                children: [
                                  TextSpan(
                                    text: '添加图片',
                                    style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.black),
                                  ),
                                  TextSpan(
                                    text: '(最多添加3张)',
                                    style: TextStyle(
                                        fontSize: 14, color: AppColors.muted),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),

                            // 图片区域
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  ..._images.asMap().entries.map((entry) {
                                    final index = entry.key;
                                    return _ImageThumb(
                                      file: File(entry.value.path),
                                      onRemove: () => _removeImageAt(index),
                                    );
                                  }),
                                  if (_images.length < _maxImageCount)
                                    GestureDetector(
                                      onTap: _addImage,
                                      child: Container(
                                        width: 76,
                                        height: 76,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF5F5F5),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                        child: const Icon(Icons.add,
                                            size: 32,
                                            color: Color(0xFFC9C9C9)),
                                      ),
                                    ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 20),

                            // 联系方式标签
                            const Text(
                              '联系方式',
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 8),

                            // 联系方式输入框
                            Container(
                              height: 56,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: TextField(
                                controller: _contactController,
                                keyboardType: TextInputType.phone,
                                maxLength: 11,
                                style: const TextStyle(fontSize: 15),
                                decoration: const InputDecoration(
                                  counterText: '',
                                  hintText: '请输入手机号码',
                                  hintStyle: TextStyle(
                                      color: AppColors.muted, fontSize: 15),
                                  border: InputBorder.none,
                                ),
                              ),
                            ),

                            const SizedBox(height: 48),

                            // 提交按钮
                            SizedBox(
                              width: double.infinity,
                              height: 52,
                              child: ElevatedButton(
                                onPressed: _submit,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.lime,
                                  foregroundColor: const Color(0xFF9EA0A4),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(26),
                                  ),
                                ),
                                child: const Text(
                                  '提交',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),

                            const SizedBox(height: 48),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
}

/// 图片缩略图 + 删除按钮。
class _ImageThumb extends StatelessWidget {
  final File file;
  final VoidCallback onRemove;

  const _ImageThumb({required this.file, required this.onRemove});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 76,
        height: 76,
        child: Stack(
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                image: DecorationImage(
                  image: FileImage(file),
                  fit: BoxFit.cover,
                ),
              ),
            ),
            Positioned(
              top: -6,
              right: -6,
              child: GestureDetector(
                onTap: onRemove,
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: const BoxDecoration(
                    color: Color(0xFFFF3B5C),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      );
}
