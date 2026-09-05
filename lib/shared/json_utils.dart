/// 宽松 JSON 字段解析工具。
/// 后端（yudao）会把 int64 序列化为字符串（避免 JS 精度丢失），
/// 如 "userId": "1"，因此数值字段需兼容 num 与 String 两种形式。
library;

/// 解析 int：兼容 num / String / null。
int asInt(dynamic value, [int defaultValue = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? defaultValue;
  return defaultValue;
}

/// 解析 bool：兼容 bool / num / String / null。
bool asBool(dynamic value, [bool defaultValue = false]) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value == 'true' || value == '1';
  return defaultValue;
}

/// 解析 String：兼容任意非空值。
String asString(dynamic value, [String defaultValue = '']) {
  if (value == null) return defaultValue;
  return value.toString();
}
