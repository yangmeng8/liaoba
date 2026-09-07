import '../shared/json_utils.dart';

/// 用户端表情包项（对应 ImFacePackUserItemVO）。
class ImFaceItem {
  final int id;
  final String url;
  final String name;
  final int width;
  final int height;

  const ImFaceItem({
    required this.id,
    required this.url,
    this.name = '',
    this.width = 200,
    this.height = 200,
  });

  factory ImFaceItem.fromJson(Map<String, dynamic> json) => ImFaceItem(
    id: asInt(json['id']),
    url: asString(json['url']),
    name: asString(json['name']),
    width: asInt(json['width'], 200),
    height: asInt(json['height'], 200),
  );
}

/// 用户端表情包（对应 ImFacePackUserVO）。
class ImFacePack {
  final int id;
  final String name;
  final String icon;
  final List<ImFaceItem> items;

  const ImFacePack({
    required this.id,
    required this.name,
    this.icon = '',
    this.items = const [],
  });

  factory ImFacePack.fromJson(Map<String, dynamic> json) => ImFacePack(
    id: asInt(json['id']),
    name: asString(json['name']),
    icon: asString(json['icon']),
    items: json['items'] is List
        ? (json['items'] as List)
              .whereType<Map>()
              .map(
                (e) => ImFaceItem.fromJson(
                  e.map((k, v) => MapEntry(k.toString(), v)),
                ),
              )
              .toList()
        : const [],
  );
}
