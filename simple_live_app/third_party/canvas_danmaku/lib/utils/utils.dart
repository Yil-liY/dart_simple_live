import 'dart:math';
import 'dart:ui' as ui;

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:flutter/material.dart';

abstract final class DmUtils {
  static final Random random = Random();

  static const maxRasterizeSize = 8192.0;

  static String generateRandomString(int length) {
    const characters = '0123456789abcdefghijklmnopqrstuvwxyz';

    return String.fromCharCodes(
      Iterable.generate(
        length,
        (_) => characters.codeUnitAt(random.nextInt(characters.length)),
      ),
    );
  }

  static final Paint _selfSendPaint = Paint()
    ..style = PaintingStyle.stroke
    ..color = Colors.green;

  static void updateSelfSendPaint(double strokeWidth) {
    _selfSendPaint.strokeWidth = strokeWidth;
  }

  /// 弹幕文本中的表情占位符，如 `[戴口罩]`（中文 display_name）
  static final RegExp _emojiPhRe = RegExp(r'\[[^\[\]]{1,20}\]');

  /// 返回可用的表情列表（按需使用）。
  /// 不再要求占位符数量与 emojis 严格相等：能否解析出几个就嵌入几个，
  /// 无法解析的占位符由 [_appendSegments] 按普通文本保留，避免显示 `[xx]`。
  static List<DanmakuEmojiPlaceholder> _effectiveEmojis(
      DanmakuContentItem content) {
    final emojis = content.emojis;
    if (emojis == null || emojis.isEmpty) return const [];
    return emojis;
  }

  /// 把 [text] 逐段写入 [builder]，将 `[XX]` 替换为表情占位矩形。
  /// [textStyle] 应用于普通文本；[emojiStyle] 包裹占位矩形（通常不带描边/颜色）。
  /// [emojiSize] 为表情期望显示高度（逻辑像素），宽度按图片原始宽高比等比缩放。
  /// 返回实际写入的占位符数量。
  static int _appendSegments(
    ui.ParagraphBuilder builder,
    String text,
    List<DanmakuEmojiPlaceholder> emojis,
    ui.TextStyle textStyle,
    ui.TextStyle emojiStyle, {
    required double emojiSize,
  }) {
    if (emojis.isEmpty) {
      builder..pushStyle(textStyle)..addText(text);
      return 0;
    }
    // 按占位符在文本中的位置匹配表情：能匹配到就嵌入，匹配不到的保留为普通文本
    builder.pushStyle(textStyle);
    // 建立 位置->表情 索引（优先精确位置，回退到顺序匹配）
    final byPos = <int, DanmakuEmojiPlaceholder>{};
    for (final e in emojis) {
      if (e.start >= 0 && !byPos.containsKey(e.start)) byPos[e.start] = e;
    }
    var last = 0;
    var count = 0;
    var orderIdx = 0;
    for (final m in _emojiPhRe.allMatches(text)) {
      if (m.start > last) {
        builder.addText(text.substring(last, m.start));
      }
      DanmakuEmojiPlaceholder? emoji = byPos[m.start];
      if (emoji == null) {
        // 位置未命中时顺序回退到下一个未使用的表情（兼容旧的按序数据）
        while (orderIdx < emojis.length) {
          final cand = emojis[orderIdx++];
          if (!byPos.containsKey(cand.start) || byPos[cand.start] == cand) {
            emoji = cand;
            break;
          }
        }
      }
      if (emoji != null) {
        final srcW = emoji.image.width.toDouble();
        final srcH = emoji.image.height.toDouble();
        final aspect = (srcH <= 0) ? 1.0 : srcW / srcH;
        builder
          ..pushStyle(emojiStyle)
          ..addPlaceholder(
            emojiSize * aspect,
            emojiSize,
            ui.PlaceholderAlignment.middle,
          )
          ..pop();
        count++;
      } else {
        // 无法解析：占位符整体按普通文本保留，避免显示 `[]`
        builder.addText(text.substring(m.start, m.end));
      }
      last = m.end;
    }
    if (last < text.length) {
      builder.addText(text.substring(last));
    }
    return count;
  }

  static ui.Paragraph generateParagraph({
    required DanmakuContentItem content,
    required double fontSize,
    required int fontWeight,
    String? fontFamily,
  }) {
    final emojis = _effectiveEmojis(content);
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      textAlign: TextAlign.left,
      fontWeight: FontWeight.values[fontWeight],
      textDirection: TextDirection.ltr,
      maxLines: 1,
      fontFamily: fontFamily,
    ));

    if (content.count case final count?) {
      builder
        ..pushStyle(ui.TextStyle(
          color: content.color,
          fontSize: fontSize * 0.6,
          fontFamily: fontFamily,
        ))
        ..addText('($count)')
        ..pop();
    }

    _appendSegments(
      builder,
      content.text,
      emojis,
      ui.TextStyle(
          color: content.color, fontSize: fontSize, fontFamily: fontFamily),
      ui.TextStyle(),
      emojiSize: fontSize,
    );

    return builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));
  }

  static ui.Image recordDanmakuImage({
    required ui.Paragraph contentParagraph,
    required DanmakuContentItem content,
    required double fontSize,
    required int fontWeight,
    required double strokeWidth,
    required double devicePixelRatio,
    String? fontFamily,
  }) {
    double w = contentParagraph.maxIntrinsicWidth + strokeWidth;
    double h = contentParagraph.height + strokeWidth;

    final offset = Offset(
      (strokeWidth / 2.0) + (content.selfSend ? 2.0 : 0.0),
      strokeWidth / 2.0,
    );

    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec)..scale(devicePixelRatio);
    final emojis = _effectiveEmojis(content);

    if (strokeWidth != 0) {
      final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
        textAlign: TextAlign.left,
        fontWeight: FontWeight.values[fontWeight],
        textDirection: TextDirection.ltr,
        maxLines: 1,
        fontFamily: fontFamily,
      ));
      final Paint strokePaint = Paint()
        ..shader = content.isColorful
            ? const LinearGradient(
                    colors: [Color(0xFFF2509E), Color(0xFF308BCD)])
                .createShader(Rect.fromLTWH(0, 0, w, h))
            : null
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth;

      if (!content.isColorful) {
        strokePaint.color = Colors.black;
      }

      if (content.count case final count?) {
        builder
          ..pushStyle(ui.TextStyle(
            fontSize: fontSize * 0.6,
            foreground: strokePaint,
            fontFamily: fontFamily,
          ))
          ..addText('($count)')
          ..pop();
      }

      // 文本 + 表情占位（表情区用透明 style，保证宽度对齐但描边不画出方框）
      _appendSegments(
        builder,
        content.text,
        emojis,
        ui.TextStyle(
            fontSize: fontSize,
            foreground: strokePaint,
            fontFamily: fontFamily),
        ui.TextStyle(fontSize: fontSize, color: Colors.transparent),
        emojiSize: fontSize,
      );

      final strokeParagraph = builder.build()
        ..layout(const ui.ParagraphConstraints(width: double.infinity));

      canvas.drawParagraph(strokeParagraph, offset);
      strokeParagraph.dispose();
    }

    canvas.drawParagraph(contentParagraph, offset);

    // 按占位矩形嵌入表情图
    if (emojis.isNotEmpty) {
      final boxes = contentParagraph.getBoxesForPlaceholders();
      final emojiPaint = (Paint()..filterQuality = FilterQuality.medium);
      for (var i = 0; i < boxes.length && i < emojis.length; i++) {
        final dst = boxes[i].toRect().shift(offset);
        final emoji = emojis[i];
        final src = Rect.fromLTWH(
          0,
          0,
          emoji.image.width.toDouble(),
          emoji.image.height.toDouble(),
        );
        canvas.drawImageRect(emoji.image, src, dst, emojiPaint);
      }
    }

    if (content.selfSend) {
      w += 4;
      canvas.drawRect(Rect.fromLTRB(0, 0, w, h), _selfSendPaint);
    }

    final pic = rec.endRecording();
    final img = pic.toImageSync(
      (w * devicePixelRatio).ceil(),
      (h * devicePixelRatio).ceil(),
    );
    pic.dispose();
    return img;
  }

  static ui.Image recordSpecialDanmakuImg({
    required SpecialDanmakuContentItem content,
    required int fontWeight,
    required double strokeWidth,
    required double devicePixelRatio,
    String? fontFamily,
  }) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      textAlign: TextAlign.left,
      fontWeight: FontWeight.values[fontWeight],
      textDirection: TextDirection.ltr,
      fontSize: content.fontSize,
      fontFamily: fontFamily,
    ))
      ..pushStyle(ui.TextStyle(
        color: content.color,
        fontSize: content.fontSize,
        fontFamily: fontFamily,
        shadows: content.hasStroke
            ? [Shadow(color: Colors.black, blurRadius: strokeWidth)]
            : null,
      ))
      ..addText(content.text);

    final paragraph = builder.build()
      ..layout(const ui.ParagraphConstraints(width: double.infinity));

    final strokeOffset = strokeWidth / 2;
    final totalWidth = paragraph.maxIntrinsicWidth + strokeWidth;
    final totalHeight = paragraph.height + strokeWidth;

    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);

    final Rect rect;
    double adjustDevicePixelRatio = devicePixelRatio;

    if (content.rotateZ != 0 || content.matrix != null) {
      rect = _calculateRotatedBounds(
        totalWidth,
        totalHeight,
        content.rotateZ,
        content.matrix,
      );

      final imgLongestSide = rect.size.longestSide * devicePixelRatio;
      if (imgLongestSide > maxRasterizeSize) {
        // force resize
        adjustDevicePixelRatio = maxRasterizeSize / imgLongestSide;
      }
      canvas
        ..scale(adjustDevicePixelRatio)
        ..translate(strokeOffset - rect.left, strokeOffset - rect.top);

      if (content.matrix case final matrix?) {
        canvas.transform(matrix.storage);
      } else {
        canvas.rotate(content.rotateZ);
      }
      canvas.drawParagraph(paragraph, Offset.zero);
    } else {
      rect = Rect.fromLTRB(0, 0, totalWidth, totalHeight);

      final imgLongestSide = max(totalWidth, totalHeight) * devicePixelRatio;
      if (imgLongestSide > maxRasterizeSize) {
        final scale = maxRasterizeSize / imgLongestSide;
        adjustDevicePixelRatio = scale;
      }
      canvas
        ..scale(adjustDevicePixelRatio)
        ..drawParagraph(paragraph, Offset(strokeOffset, strokeOffset));
    }

    content.rect = rect;

    final imgSize = rect.size * adjustDevicePixelRatio;
    final pic = rec.endRecording();
    final img = pic.toImageSync(imgSize.width.ceil(), imgSize.height.ceil());
    pic.dispose();
    paragraph.dispose();

    return img;
  }

  static Rect _calculateRotatedBounds(
    double w,
    double h,
    double rotateZ,
    Matrix4? matrix,
  ) {
    final double cosZ;
    final double cosY;
    final double sinZ;
    if (matrix == null) {
      cosZ = cos(rotateZ);
      sinZ = sin(rotateZ);
      cosY = 1;
    } else {
      cosZ = matrix[5];
      sinZ = matrix[1];
      cosY = matrix[10];
    }

    final wx = w * cosZ * cosY;
    final wy = w * sinZ;
    final hx = -h * sinZ * cosY;
    final hy = h * cosZ;

    final minX = _min4(0.0, wx, hx, wx + hx);
    final maxX = _max4(0.0, wx, hx, wx + hx);
    final minY = _min4(0.0, wy, hy, wy + hy);
    final maxY = _max4(0.0, wy, hy, wy + hy);

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  @pragma("vm:prefer-inline")
  static double _min4(double a, double b, double c, double d) {
    final ab = a < b ? a : b;
    final cd = c < d ? c : d;
    return ab < cd ? ab : cd;
  }

  @pragma("vm:prefer-inline")
  static double _max4(double a, double b, double c, double d) {
    final ab = a > b ? a : b;
    final cd = c > d ? c : d;
    return ab > cd ? ab : cd;
  }
}
