import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

/// 抖音弹幕表情解码缓存管理器。
///
/// 采用「预解码缓存 + 按需懒加载」策略：
/// - 一次性懒加载 assets 中的 `emoji_map.json`，建立 display_name → {uri,w,h} 映射；
/// - 对出现的表情按需解码 assets 里的静态 PNG 为 [ui.Image] 并缓存复用；
/// - 同步方法 [resolveSync] 仅在表情已全部解码时返回占位列表，否则返回 null
///   并后台触发缺失表情的预解码，供下一次命中。
///
/// 由于同一表情在直播弹幕中高频重复，首次出现后缓存即命中，渲染带表情的
/// 弹幕，性能开销很小。
class EmojiImageCache {
  EmojiImageCache._();
  static final EmojiImageCache instance = EmojiImageCache._();

  /// emoji_map.json 在 assets 中的路径
  static const String mapAsset = 'assets/douyin_emoji/emoji_map.json';

  /// 静态表情 PNG 所在目录
  static const String staticPrefix = 'assets/douyin_emoji/static/';

  /// 弹幕文本里的表情占位符，如 `[戴口罩]`（中文 display_name）
  static final RegExp _phRe = RegExp(r'\[[^\[\]]{1,20}\]');

  // display_name → (uri, w, h)
  Map<String, ({String uri, int w, int h})>? _meta;

  // uri → 已解码的 ui.Image（缓存复用）
  final Map<String, ui.Image> _pool = {};

  // uri → 正在解码中的 Future（防止并发重复解码同一图）
  final Map<String, Future<ui.Image?>> _inflight = {};

  /// 预热：仅加载 emoji_map.json 映射（不常驻消耗，仅为同步查询做准备）。
  /// 在进入直播间等时机调用一次即可。
  Future<void> init() async {
    await _ensureMeta();
  }

  /// 释放缓存（退出直播间时调用，避免内存占用）。返回被释放的图片总数。
  int disposeAll() {
    var n = 0;
    for (final img in _pool.values) {
      img.dispose();
      n++;
    }
    _pool.clear();
    _inflight.clear();
    return n;
  }

  /// 供聊天列表（非 canvas，纯 widget）使用的富文本 spans。
  ///
  /// 将 [text] 中的 `[表情名]` 占位符替换为行内图片（[WidgetSpan]），
  /// 其余文字普通 [TextSpan]。用于直播间右侧的聊天消息列表。
  /// [style] 应用于普通文本段落；[emojiHeight] 为表情显示高度（按比例缩放宽度）。
  ///
  /// 若映射尚未加载，暂以纯文本返回，并后台预热，供后续重建命中。
  List<InlineSpan> widgetSpans(
    String text,
    TextStyle style, {
    double emojiHeight = 18,
    double spacing = 1,
  }) {
    final metas = _meta;
    final names = placeholderNames(text);
    if (metas == null || names.isEmpty) {
      if (metas == null) unawaited(_warmUp(text));
      return [TextSpan(text: text, style: style)];
    }
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _phRe.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start), style: style));
      }
      final name = m.group(0)!;
      final meta = metas[name];
      if (meta == null) {
        // 未知占位符：按纯文本保留
        spans.add(TextSpan(text: name, style: style));
      } else {
        final aspect = (meta.h <= 0) ? 1.0 : meta.w / meta.h;
        final w = emojiHeight * aspect;
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: spacing / 2),
            child: Image.asset(
              '$staticPrefix${meta.uri}',
              width: w,
              height: emojiHeight,
              fit: BoxFit.contain,
            ),
          ),
        ));
      }
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: style));
    }
    return spans;
  }

  /// 扫描 [text]，返回其中的表情占位符 display_name 列表（含方括号，按出现顺序）。
  List<String> placeholderNames(String text) {
    return _phRe.allMatches(text).map((m) => m.group(0)!).toList();
  }

  /// 同步解析 [text] 中的表情。
  ///
  /// 返回与占位符严格一一对应的 [DanmakuEmojiPlaceholder] 列表；
  /// 若映射尚未加载、存在未知占位符，或存在尚未解码完成的图片，返回 null
  /// （此时建议按纯文本渲染），并后台触发预解码以便下次命中。
  List<DanmakuEmojiPlaceholder>? resolveSync(String text) {
    final names = placeholderNames(text);
    if (names.isEmpty) return null;

    final metas = _meta;
    if (metas == null) {
      unawaited(_warmUp(text));
      return null;
    }

    final result = <DanmakuEmojiPlaceholder>[];
    final missingUris = <String>{};
    for (final name in names) {
      final meta = metas[name];
      if (meta == null) continue; // 未知占位符，跳过
      final img = _pool[meta.uri];
      if (img == null) {
        missingUris.add(meta.uri);
      } else {
        result.add(DanmakuEmojiPlaceholder(
          name: name,
          uri: meta.uri,
          image: img,
          targetWidth: meta.w.toDouble(),
          targetHeight: meta.h.toDouble(),
        ));
      }
    }

    // 缺失的表情触发后台预解码（后续命中）
    if (missingUris.isNotEmpty) {
      unawaited(_preloadUris(missingUris));
    }

    // 只要有缺漏，就整体回退纯文本，避免与 text 中占位符数量错位导致渲染错乱
    if (result.length != names.length) return null;
    return result;
  }

  /// 异步预热：确保 [text] 中出现过的所有表情都完成解码（供后续同步命中）。
  Future<void> preload(String text) => _warmUp(text);

  Future<void> _warmUp(String text) async {
    final names = placeholderNames(text);
    if (names.isEmpty) return;
    final metas = await _ensureMeta();
    final uris = <String>{};
    for (final name in names) {
      final meta = metas[name];
      if (meta != null) uris.add(meta.uri);
    }
    await _preloadUris(uris);
  }

  Future<void> _preloadUris(Set<String> uris) async {
    for (final uri in uris) {
      if (_pool.containsKey(uri) || _inflight.containsKey(uri)) continue;
      final fut = _inflight[uri] ??= _decode(uri);
      try {
        final img = await fut;
        if (img != null) _pool[uri] = img;
      } finally {
        _inflight.remove(uri);
      }
    }
  }

  Future<ui.Image?> _decode(String uri) async {
    try {
      final data = await rootBundle.load('$staticPrefix$uri');
      final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } catch (_) {
      // 解码失败：静默回退，不阻断弹幕渲染
      return null;
    }
  }

  Future<Map<String, ({String uri, int w, int h})>> _ensureMeta() async {
    final cached = _meta;
    if (cached != null) return cached;
    final raw = await rootBundle.loadString(mapAsset);
    final json = jsonDecode(raw) as Map<String, dynamic>;
    final mapping = json['mapping'] as Map<String, dynamic>;
    final map = <String, ({String uri, int w, int h})>{};
    mapping.forEach((k, v) {
      final m = v as Map<String, dynamic>;
      map[k] = (
        uri: m['uri'] as String,
        w: (m['w'] as num).toInt(),
        h: (m['h'] as num).toInt(),
      );
    });
    _meta = map;
    return map;
  }
}
