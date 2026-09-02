import 'package:flutter/material.dart';

import '../../../../shared/app_colors.dart';
import 'change_bound_phone_page.dart';
import 'change_password_page.dart';

/// The account security settings shown from the general settings page.
class AccountSecurityPage extends StatelessWidget {
  const AccountSecurityPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.pageBg,
        body: Column(
          children: [
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
                        '账户安全',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(top: 12),
                children: [
                  Container(
                    color: Colors.white,
                    margin: const EdgeInsets.symmetric(horizontal: 12),
                    child: Column(
                      children: [
                        _SecurityRow(
                          title: '修改密码',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const ChangePasswordPage()),
                          ),
                        ),
                        _SecurityRow(
                          title: '修改绑定手机号',
                          trailing: '185****4829',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const ChangeBoundPhonePage()),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

class _SecurityRow extends StatelessWidget {
  final String title;
  final String? trailing;
  final VoidCallback? onTap;

  const _SecurityRow({required this.title, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          height: 60,
          margin: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: const Color(0xFFE7E7E7),
                width: title == '修改绑定手机号' ? 0 : 1,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                  child: Text(title,
                      style: const TextStyle(fontSize: 21))),
              if (trailing != null)
                Text(
                  trailing!,
                  style: const TextStyle(
                      fontSize: 20, color: AppColors.muted),
                ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right,
                  size: 30, color: Color(0xFFB6BBC2)),
            ],
          ),
        ),
      );
}
