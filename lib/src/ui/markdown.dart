/// Just enough Markdown for chat replies: headings, lists, quotes, fenced
/// code, inline code, bold and italics.
library;

import 'package:flatkit/flatkit.dart';
import 'package:flutter/widgets.dart';

const monoFamily = 'monospace';
const monoFallback = ['DejaVu Sans Mono', 'Menlo', 'Consolas', 'Courier New'];

TextStyle monoStyle(BuildContext context, {double size = 12.5}) => TextStyle(
      fontFamily: monoFamily,
      fontFamilyFallback: monoFallback,
      fontSize: size,
      height: 1.45,
      color: KitText.body(context).color,
    );

class Markdown extends StatelessWidget {
  final String text;
  const Markdown(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final blocks = _parse(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, b) in blocks.indexed) ...[
          if (i > 0) SizedBox(height: b.kind == _Kind.listItem && blocks[i - 1].kind == _Kind.listItem ? 3 : 10),
          _buildBlock(context, b),
        ],
      ],
    );
  }

  Widget _buildBlock(BuildContext context, _Block b) {
    final c = KitTheme.of(context);
    final body = KitText.body(context).copyWith(height: 1.55);
    switch (b.kind) {
      case _Kind.code:
        return CodeBlock(b.text, language: b.extra);
      case _Kind.heading:
        final size = switch (b.level) { 1 => 18.0, 2 => 16.0, _ => 14.5 };
        return Text.rich(
          TextSpan(children: inlineSpans(context, b.text, body)),
          style: body.copyWith(fontSize: size, fontWeight: FontWeight.w600),
        );
      case _Kind.listItem:
        return Padding(
          padding: EdgeInsets.only(left: 4.0 + b.level * 16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 22,
              child: Text(b.extra ?? '•', style: body.copyWith(color: c.textDim)),
            ),
            Expanded(child: Text.rich(TextSpan(children: inlineSpans(context, b.text, body)), style: body)),
          ]),
        );
      case _Kind.quote:
        return Container(
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: c.borderStrong, width: 3))),
          child: Text.rich(TextSpan(children: inlineSpans(context, b.text, body)),
              style: body.copyWith(color: c.textDim)),
        );
      case _Kind.rule:
        return const KitDivider();
      case _Kind.paragraph:
        return Text.rich(TextSpan(children: inlineSpans(context, b.text, body)), style: body);
    }
  }
}

/// Inline code, **bold**, *italic* and _italic_.
List<InlineSpan> inlineSpans(BuildContext context, String text, TextStyle base) {
  final c = KitTheme.of(context);
  final spans = <InlineSpan>[];
  final re = RegExp(r'`([^`]+)`|\*\*(.+?)\*\*|(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?!\w)|(?<!\w)_(?!\s)(.+?)(?<!\s)_(?!\w)');
  var last = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
    if (m.group(1) != null) {
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
          decoration: BoxDecoration(color: c.hover, borderRadius: BorderRadius.circular(4)),
          child: Text(m.group(1)!, style: monoStyle(context, size: 12.5).copyWith(color: c.text)),
        ),
      ));
    } else if (m.group(2) != null) {
      spans.add(TextSpan(text: m.group(2), style: const TextStyle(fontWeight: FontWeight.w600)));
    } else {
      spans.add(TextSpan(text: m.group(3) ?? m.group(4), style: const TextStyle(fontStyle: FontStyle.italic)));
    }
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return spans;
}

class CodeBlock extends StatelessWidget {
  final String code;
  final String? language;
  final int? maxLines;
  const CodeBlock(this.code, {super.key, this.language, this.maxLines});

  @override
  Widget build(BuildContext context) {
    final c = KitTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.background,
        borderRadius: BorderRadius.circular(kitRadius),
        border: Border.all(color: c.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (language != null && language!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Text(language!, style: KitText.small(context, color: c.textDim)),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Text(code, style: monoStyle(context), maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.fade),
        ),
      ]),
    );
  }
}

enum _Kind { paragraph, heading, listItem, quote, code, rule }

class _Block {
  final _Kind kind;
  final String text;
  final int level;
  final String? extra;
  _Block(this.kind, this.text, {this.level = 0, this.extra});
}

List<_Block> _parse(String src) {
  final lines = src.replaceAll('\r\n', '\n').split('\n');
  final out = <_Block>[];
  final para = <String>[];
  void flush() {
    if (para.isNotEmpty) {
      out.add(_Block(_Kind.paragraph, para.join('\n')));
      para.clear();
    }
  }

  final bullet = RegExp(r'^(\s*)([-*+]|\d+[.)])\s+(.*)$');
  final heading = RegExp(r'^(#{1,6})\s+(.*)$');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```')) {
      flush();
      final lang = trimmed.substring(3).trim();
      final code = <String>[];
      i++;
      while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
        code.add(lines[i]);
        i++;
      }
      out.add(_Block(_Kind.code, code.join('\n'), extra: lang));
      continue;
    }
    if (trimmed.isEmpty) {
      flush();
      continue;
    }
    final h = heading.firstMatch(trimmed);
    if (h != null) {
      flush();
      out.add(_Block(_Kind.heading, h.group(2)!, level: h.group(1)!.length));
      continue;
    }
    if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
      flush();
      out.add(_Block(_Kind.rule, ''));
      continue;
    }
    final b = bullet.firstMatch(line);
    if (b != null) {
      flush();
      final marker = b.group(2)!;
      out.add(_Block(_Kind.listItem, b.group(3)!,
          level: (b.group(1)!.length / 2).floor().clamp(0, 4),
          extra: RegExp(r'^\d').hasMatch(marker) ? marker : null));
      continue;
    }
    if (trimmed.startsWith('>')) {
      flush();
      out.add(_Block(_Kind.quote, trimmed.substring(1).trimLeft()));
      continue;
    }
    // A continuation line of a list item.
    if (para.isEmpty && out.isNotEmpty && out.last.kind == _Kind.listItem && line.startsWith('  ')) {
      final prev = out.removeLast();
      out.add(_Block(_Kind.listItem, '${prev.text} $trimmed', level: prev.level, extra: prev.extra));
      continue;
    }
    para.add(line);
  }
  flush();
  return out;
}
