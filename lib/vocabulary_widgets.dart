import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'batch_store.dart';
import 'english_level_colors.dart';

/// Tap to save, or drag directly to move the label or discard it.
class VocabularyTag extends StatelessWidget {
  const VocabularyTag({
    super.key,
    required this.card,
    required this.onFavorite,
    this.onDragStarted,
    this.onDragUpdate,
    this.onDragEnd,
    this.onPointerDown,
    this.onPointerMove,
    this.canDrag = true,
  });
  final Map<String, dynamic> card;
  final VoidCallback onFavorite;
  final VoidCallback? onDragStarted;
  final ValueChanged<DragUpdateDetails>? onDragUpdate;
  final ValueChanged<DraggableDetails>? onDragEnd;
  final ValueChanged<PointerDownEvent>? onPointerDown;
  final ValueChanged<PointerMoveEvent>? onPointerMove;
  final bool canDrag;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: onPointerDown,
    onPointerMove: onPointerMove,
    child: Draggable<Map<String, dynamic>>(
      data: card,
      maxSimultaneousDrags: canDrag ? 1 : 0,
      onDragStarted: onDragStarted,
      onDragUpdate: onDragUpdate,
      onDragEnd: onDragEnd,
      feedback: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: math.min(280, MediaQuery.sizeOf(context).width - 24),
          ),
          child: Chip(
            backgroundColor: englishWordColor(card),
            label: Text(
              card['word'] as String,
              softWrap: true,
              maxLines: 100,
              style: TextStyle(color: wordTextColor(englishWordColor(card))),
            ),
            avatar: Icon(
              Icons.drag_indicator,
              color: wordTextColor(englishWordColor(card)),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: .35, child: _chip()),
      child: _chip(),
    ),
  );

  Widget _chip() => ActionChip(
    backgroundColor: englishWordColor(card),
    avatar: Icon(
      Icons.bookmark_add_outlined,
      size: 18,
      color: wordTextColor(englishWordColor(card)),
    ),
    label: Text(
      card['word'] as String,
      softWrap: true,
      maxLines: 100,
      style: TextStyle(color: wordTextColor(englishWordColor(card))),
    ),
    onPressed: onFavorite,
  );
}

/// Place a wrapping label fully inside the photo whenever the photo permits it.
class PositionedVocabularyTag extends StatelessWidget {
  const PositionedVocabularyTag({
    super.key,
    required this.card,
    required this.box,
    required this.photoSize,
    required this.onFavorite,
    this.position,
    this.onDragStarted,
    this.onDragUpdate,
    this.onDragEnd,
    this.onPointerDown,
    this.onPointerMove,
    this.canDrag = true,
  });
  final Map<String, dynamic> card;
  final List box;
  final Size photoSize;
  final VoidCallback onFavorite;
  final Offset? position;
  final VoidCallback? onDragStarted;
  final ValueChanged<DragUpdateDetails>? onDragUpdate;
  final ValueChanged<DraggableDetails>? onDragEnd;
  final ValueChanged<PointerDownEvent>? onPointerDown;
  final ValueChanged<PointerMoveEvent>? onPointerMove;
  final bool canDrag;

  static Rect geometry(
    BuildContext context,
    Map<String, dynamic> card,
    List box,
    Size photoSize,
    Offset? position,
  ) {
    final maxWidth = math.min(280.0, photoSize.width);
    final painter = TextPainter(
      text: TextSpan(
        text: card['word'] as String,
        style:
            Theme.of(context).chipTheme.labelStyle ??
            const TextStyle(fontSize: 14),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: math.max(1, maxWidth - 72));
    final height = math.max(48.0, painter.height + 32);
    final width = math.min(maxWidth, painter.width + 72);
    painter.dispose();
    final left = (position?.dx ?? (box[0] as num).toDouble() * photoSize.width)
        .clamp(0.0, math.max(0.0, photoSize.width - width));
    final top = (position?.dy ?? (box[1] as num).toDouble() * photoSize.height)
        .clamp(0.0, math.max(0.0, photoSize.height - height));
    return Rect.fromLTWH(left.toDouble(), top.toDouble(), width, height);
  }

  @override
  Widget build(BuildContext context) {
    final rect = geometry(context, card, box, photoSize, position);
    return Positioned(
      left: rect.left,
      top: rect.top,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: math.min(280, photoSize.width)),
        child: VocabularyTag(
          card: card,
          onFavorite: onFavorite,
          onDragStarted: onDragStarted,
          onDragUpdate: onDragUpdate,
          onDragEnd: onDragEnd,
          onPointerDown: onPointerDown,
          onPointerMove: onPointerMove,
          canDrag: canDrag,
        ),
      ),
    );
  }
}

/// Fits the complete photo and keeps labels hit-testable even for panoramas.
class VocabularyPhotoCanvas extends StatefulWidget {
  const VocabularyPhotoCanvas({
    super.key,
    required this.image,
    required this.aspectRatio,
    required this.cards,
    required this.onFavorite,
    this.onPositionChanged,
    this.minHeight = 160,
    this.maxHeight = 640,
  });
  final Widget image;
  final double aspectRatio, minHeight, maxHeight;
  final List<Map<String, dynamic>> cards;
  final ValueChanged<Map<String, dynamic>> onFavorite;
  final void Function(Map<String, dynamic>, Offset)? onPositionChanged;

  @override
  State<VocabularyPhotoCanvas> createState() => _VocabularyPhotoCanvasState();
}

class _VocabularyPhotoCanvasState extends State<VocabularyPhotoCanvas> {
  final canvasKey = GlobalKey();
  final Map<String, Offset> positions = {};
  OverlayEntry? lineOverlay;
  RenderBox? overlayBox;
  Offset? lineStart, lineEnd, dragPosition, lastPointer;
  Offset? pendingPointer;
  Offset? touchOffset;
  Size? feedbackSize;
  String? activeKey;

  String cardKey(Map<String, dynamic> card) =>
      '${card['id'] ?? card['word']}-${card['box']}';

  @override
  void dispose() {
    lineOverlay?.remove();
    lineOverlay?.dispose();
    super.dispose();
  }

  void startDrag(String key, Rect label, Offset anchor) {
    final render = canvasKey.currentContext?.findRenderObject();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (render is! RenderBox || overlay == null) return;
    final overlayRender = overlay.context.findRenderObject();
    if (overlayRender is! RenderBox) return;
    lineOverlay?.remove();
    lineOverlay?.dispose();
    overlayBox = overlayRender;
    lineStart = overlayRender.globalToLocal(render.localToGlobal(anchor));
    lineEnd = overlayRender.globalToLocal(
      pendingPointer ?? render.localToGlobal(label.center),
    );
    dragPosition = label.topLeft;
    feedbackSize = label.size;
    touchOffset ??= Offset(label.width / 2, label.height / 2);
    lastPointer = pendingPointer == null
        ? null
        : render.globalToLocal(pendingPointer!);
    lineOverlay = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(
            painter: _WordLinesPainter(
              [(lineStart!, lineEnd!)],
              cutout: Rect.fromLTWH(
                lineEnd!.dx - touchOffset!.dx,
                lineEnd!.dy - touchOffset!.dy,
                feedbackSize!.width,
                feedbackSize!.height,
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(lineOverlay!);
    setState(() => activeKey = key);
  }

  void pointerMove(String key, PointerMoveEvent event) {
    pendingPointer = event.position;
    if (activeKey != key || overlayBox == null) return;
    final render = canvasKey.currentContext?.findRenderObject();
    if (render is! RenderBox) return;
    lastPointer = render.globalToLocal(event.position);
    lineEnd = overlayBox!.globalToLocal(event.position);
    lineOverlay?.markNeedsBuild();
  }

  void updateDrag(DragUpdateDetails details) {
    final render = canvasKey.currentContext?.findRenderObject();
    if (render is! RenderBox || overlayBox == null) return;
    dragPosition = (dragPosition ?? Offset.zero) + details.delta;
    // The recognizer's first update can report the original touch position;
    // the raw pointer event already contains the actual moved position.
    final pointer = pendingPointer ?? details.globalPosition;
    lastPointer = render.globalToLocal(pointer);
    lineEnd = overlayBox!.globalToLocal(pointer);
    lineOverlay?.markNeedsBuild();
  }

  void endDrag(
    Map<String, dynamic> card,
    String key,
    Rect label,
    Size size,
    DraggableDetails details,
  ) {
    Offset? normalized;
    if (!details.wasAccepted &&
        lastPointer != null &&
        dragPosition != null &&
        (Offset.zero & size).contains(lastPointer!)) {
      final x = dragPosition!.dx.clamp(
        0.0,
        math.max(0.0, size.width - label.width),
      );
      final y = dragPosition!.dy.clamp(
        0.0,
        math.max(0.0, size.height - label.height),
      );
      normalized = Offset(x / size.width, y / size.height);
      positions[key] = normalized;
    }
    lineOverlay?.remove();
    lineOverlay?.dispose();
    lineOverlay = null;
    overlayBox = null;
    lineStart = lineEnd = dragPosition = lastPointer = null;
    pendingPointer = null;
    touchOffset = null;
    feedbackSize = null;
    if (mounted) setState(() => activeKey = null);
    if (normalized != null) widget.onPositionChanged?.call(card, normalized);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final height = (width / widget.aspectRatio)
          .clamp(widget.minHeight, widget.maxHeight)
          .toDouble();
      final imageWidth = math.min(width, height * widget.aspectRatio);
      final imageHeight = imageWidth / widget.aspectRatio;
      final dx = (width - imageWidth) / 2;
      final dy = (height - imageHeight) / 2;
      bool validBox(Map<String, dynamic> card) {
        final box = card['box'];
        return box is List &&
            box.length == 4 &&
            box.every((v) => v is num && v.isFinite && v >= 0 && v <= 1);
      }

      return SizedBox(
        key: canvasKey,
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xffe8ede6),
                borderRadius: BorderRadius.circular(20),
              ),
            ),
            Positioned(
              left: dx,
              top: dy,
              width: imageWidth,
              height: imageHeight,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: widget.image,
              ),
            ),
            ..._buildLabels(
              context,
              width,
              height,
              dx,
              dy,
              imageWidth,
              imageHeight,
              widget.cards.where(validBox).toList(),
            ),
          ],
        ),
      );
    },
  );

  List<Widget> _buildLabels(
    BuildContext context,
    double width,
    double height,
    double dx,
    double dy,
    double imageWidth,
    double imageHeight,
    List<Map<String, dynamic>> cards,
  ) {
    final size = Size(width, height);
    final lines = <(Offset, Offset)>[];
    final labels = <Widget>[];
    final placed = <Rect>[];
    for (final card in cards) {
      final box = card['box'] as List;
      final key = cardKey(card);
      final anchor = Offset(
        dx + ((box[0] as num) + (box[2] as num)) / 2 * imageWidth,
        dy + ((box[1] as num) + (box[3] as num)) / 2 * imageHeight,
      );
      final x = card['labelX'], y = card['labelY'];
      final saved =
          positions[key] ??
          (x is num &&
                  y is num &&
                  x.isFinite &&
                  y.isFinite &&
                  x >= 0 &&
                  x <= 1 &&
                  y >= 0 &&
                  y <= 1
              ? Offset(x.toDouble(), y.toDouble())
              : null);
      var position = saved == null
          ? null
          : Offset(saved.dx * width, saved.dy * height);
      final normalizedBox = [
        (dx + (box[0] as num) * imageWidth) / width,
        (dy + (box[1] as num) * imageHeight) / height,
      ];
      var rect = PositionedVocabularyTag.geometry(
        context,
        card,
        normalizedBox,
        size,
        position,
      );
      if (saved == null &&
          placed.any((other) => other.inflate(4).overlaps(rect))) {
        rect = _placeWithoutOverlap(rect, placed, size);
        position = rect.topLeft;
      }
      placed.add(rect);
      if (activeKey != key) lines.add((anchor, rect.center));
      labels.add(
        PositionedVocabularyTag(
          key: ValueKey(key),
          card: card,
          box: normalizedBox,
          photoSize: size,
          position: position,
          onFavorite: () => widget.onFavorite(card),
          onDragStarted: () => startDrag(key, rect, anchor),
          onDragUpdate: updateDrag,
          onDragEnd: (details) => endDrag(card, key, rect, size, details),
          onPointerDown: (event) {
            pendingPointer = null;
            touchOffset = event.localPosition;
          },
          onPointerMove: (event) => pointerMove(key, event),
          canDrag: activeKey == null || activeKey == key,
        ),
      );
    }
    return [
      Positioned.fill(
        child: IgnorePointer(
          child: CustomPaint(painter: _WordLinesPainter(lines)),
        ),
      ),
      ...labels,
    ];
  }

  /// Keep related words readable when several labels share one object box.
  /// If the photo has insufficient room, retain all labels and minimize overlap.
  Rect _placeWithoutOverlap(Rect initial, List<Rect> occupied, Size size) {
    final maxX = math.max(0.0, size.width - initial.width);
    final maxY = math.max(0.0, size.height - initial.height);
    final xs = <double>{0, maxX, initial.left};
    final ys = <double>{0, maxY, initial.top};
    for (var x = 0.0; x < maxX; x += initial.width + 8) {
      xs.add(x);
    }
    for (var y = 0.0; y < maxY; y += initial.height + 8) {
      ys.add(y);
    }
    final options = <Rect>[
      for (final x in xs)
        for (final y in ys) Rect.fromLTWH(x, y, initial.width, initial.height),
    ];
    double overlap(Rect candidate) {
      var total = 0.0;
      for (final other in occupied) {
        final a = candidate.intersect(other.inflate(4));
        if (!a.isEmpty) total += a.width * a.height;
      }
      return total;
    }

    options.sort((a, b) {
      final byOverlap = overlap(a).compareTo(overlap(b));
      if (byOverlap != 0) return byOverlap;
      return (a.topLeft - initial.topLeft).distanceSquared.compareTo(
        (b.topLeft - initial.topLeft).distanceSquared,
      );
    });
    return options.first;
  }
}

class _WordLinesPainter extends CustomPainter {
  const _WordLinesPainter(this.lines, {this.cutout});
  final List<(Offset, Offset)> lines;
  final Rect? cutout;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    if (cutout != null) {
      final path = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addRect(cutout!.deflate(6));
      canvas.clipPath(path);
    }
    final shadow = Paint()
      ..color = Colors.black.withValues(alpha: .25)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: .68)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (final line in lines) {
      canvas.drawLine(line.$1, line.$2, shadow);
      canvas.drawLine(line.$1, line.$2, paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WordLinesPainter oldDelegate) => true;
}

class TrashDropTarget extends StatelessWidget {
  const TrashDropTarget({super.key, required this.onDiscard});
  final ValueChanged<Map<String, dynamic>> onDiscard;

  @override
  Widget build(BuildContext context) => DragTarget<Map<String, dynamic>>(
    onAcceptWithDetails: (details) => onDiscard(details.data),
    builder: (context, candidates, rejected) => AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: candidates.isEmpty
            ? Colors.black.withValues(alpha: .05)
            : Colors.red.shade100,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.delete_outline),
          const SizedBox(width: 6),
          Text(candidates.isEmpty ? '拖动单词到这里' : '松开放入垃圾桶'),
        ],
      ),
    ),
  );
}

class LocalTrashPage extends StatefulWidget {
  const LocalTrashPage({super.key, required this.store});
  final BatchStore store;
  @override
  State<LocalTrashPage> createState() => _LocalTrashPageState();
}

class _LocalTrashPageState extends State<LocalTrashPage> {
  late Future<List<Map<String, dynamic>>> items = widget.store.trash();
  bool busy = false;

  Future<void> restore(Map<String, dynamic> entry) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.store.restore(entry['id'] as String);
      if (mounted) setState(() => items = widget.store.trash());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('恢复失败，请检查本机存储。')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> addAlias(Map<String, dynamic> entry) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加其他词形'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 60,
          decoration: const InputDecoration(hintText: '输入同一个词的其他写法或变化'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    try {
      await widget.store.addTrashAlias(entry['id'] as String, value);
      if (mounted) setState(() => items = widget.store.trash());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('添加失败，请检查词形和本机存储。')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('单词垃圾桶')),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: items,
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Center(child: Text('无法读取垃圾桶。'));
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final rows = snapshot.data!;
        if (rows.isEmpty) return const Center(child: Text('垃圾桶是空的。'));
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              '这些词及已识别的词形会在以后被过滤。误丢的词可以恢复；数据保存在本机。',
              style: TextStyle(color: Colors.blueGrey, height: 1.5),
            ),
            const SizedBox(height: 12),
            for (final row in rows)
              Card(
                child: ExpansionTile(
                  title: Text(row['word'] as String),
                  subtitle: Text(
                    '${row['language'] == 'ja' ? '日语' : '英语'} · ${row['zh'] ?? ''}',
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '已记录的词形：${(row['aliases'] as List? ?? const []).join('、')}',
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: busy ? null : () => addAlias(row),
                        icon: const Icon(Icons.add),
                        label: const Text('添加词形'),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: busy ? null : () => restore(row),
                        icon: const Icon(Icons.restore_from_trash_outlined),
                        label: const Text('恢复'),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    ),
  );
}
