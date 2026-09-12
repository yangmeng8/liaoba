/// 好友字母分桶纯逻辑（对应 H5 useFriendBuckets，全部客户端计算零接口）：
/// 拼音由后端预计算下发（displayNamePinyin/nicknamePinyin），
/// Flutter 不做汉字转拼音，保证两端排序一致。
library;

import '../../models/im_conversation.dart';

/// 有效好友（排除已删除/拉黑）。
List<ImFriend> activeFriends(List<ImFriend> all) =>
    all.where((f) => f.status == ImCommonStatus.enable && !f.blocked).toList();

/// 排序键 = 备注拼音 || 昵称拼音 || 展示名小写。
String friendSortKey(ImFriend f) {
  final pinyin = f.displayNamePinyin.isNotEmpty
      ? f.displayNamePinyin
      : f.nicknamePinyin;
  if (pinyin.isNotEmpty) return pinyin.toLowerCase();
  return f.shownName.toLowerCase();
}

/// 桶字母：排序键首字符是字母 → 大写 A-Z；否则（数字/符号/中文）→ '#'。
String bucketLetter(String sortKey) {
  if (sortKey.isEmpty) return '#';
  final first = sortKey.substring(0, 1);
  final code = first.codeUnitAt(0);
  if (code >= 65 && code <= 90) return first; // A-Z
  if (code >= 97 && code <= 122) return first.toUpperCase(); // a-z
  return '#';
}

/// 拼音首字母缩写（'lao zhang' → 'lz'）。
String pinyinInitials(String pinyin) => pinyin
    .split(RegExp(r'\s+'))
    .where((seg) => seg.isNotEmpty)
    .map((seg) => seg.substring(0, 1))
    .join();

/// 搜索匹配（六路命中，对齐 H5）：
/// 备注名/昵称（小写 includes）、备注/昵称全拼（去空格）、备注/昵称首字母。
bool friendMatch(ImFriend f, String keyword) {
  final kw = keyword.trim().toLowerCase();
  if (kw.isEmpty) return true;
  if (f.displayName.toLowerCase().contains(kw)) return true;
  if (f.nickname.toLowerCase().contains(kw)) return true;
  if (f.displayNamePinyin.toLowerCase().replaceAll(' ', '').contains(kw)) {
    return true;
  }
  if (f.nicknamePinyin.toLowerCase().replaceAll(' ', '').contains(kw)) {
    return true;
  }
  if (pinyinInitials(f.displayNamePinyin.toLowerCase()).contains(kw)) {
    return true;
  }
  if (pinyinInitials(f.nicknamePinyin.toLowerCase()).contains(kw)) {
    return true;
  }
  return false;
}

/// 字母分桶结果。
class FriendBucket {
  /// 桶字母（A-Z 或 '#'）。
  final String letter;

  /// 桶内好友（按排序键升序）。
  final List<ImFriend> friends;

  const FriendBucket({required this.letter, required this.friends});
}

/// 分桶：A-Z 按字母序，'#' 永远垫底；桶内按排序键自然序。
List<FriendBucket> buildFriendBuckets(List<ImFriend> friends) {
  final map = <String, List<ImFriend>>{};
  for (final f in friends) {
    final key = friendSortKey(f);
    final letter = bucketLetter(key);
    (map[letter] ??= []).add(f);
  }
  final letters = map.keys.toList()
    ..sort((a, b) {
      if (a == '#') return 1; // '#' 垫底
      if (b == '#') return -1;
      return a.compareTo(b);
    });
  return [
    for (final letter in letters)
      FriendBucket(
        letter: letter,
        friends: map[letter]!..sort((a, b) => friendSortKey(a).compareTo(friendSortKey(b))),
      ),
  ];
}
