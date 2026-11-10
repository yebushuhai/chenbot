import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'batch_store.dart';
import 'dev_recognition.dart';

class BatchPage extends StatefulWidget {
  const BatchPage({
    super.key,
    required this.japanese,
    this.storeOverride,
    this.storageScope = 'guest',
  });
  final bool japanese;
  final BatchStore? storeOverride;
  final String storageScope;
  @override
  State<BatchPage> createState() => _BatchPageState();
}

class _BatchPageState extends State<BatchPage> {
  BatchStore? store;
  final picker = ImagePicker();
  final speech = FlutterTts();
  List<Map<String, dynamic>> photos = [], cards = [], favorites = [];
  int index = 0, completed = 0, total = 0;
  bool busy = false, stop = false;
  String? problem;
  @override
  void initState() {
    super.initState();
    init();
  }

  Future<void> init() async {
    try {
      if (widget.storeOverride != null) {
        store = widget.storeOverride;
      } else {
        final dir = await getApplicationDocumentsDirectory();
        final scope = widget.storageScope == 'guest'
            ? 'guest'
            : localScopeForUser(widget.storageScope);
        store = BatchStore(Directory('${dir.path}/chenbot_batch/$scope'));
      }
      await refresh();
    } catch (_) {
      if (mounted) setState(() => problem = '无法读取本机数据，请检查设备存储空间。');
    }
  }

  Future<void> refresh() async {
    final s = store;
    if (s == null) return;
    final p = await s.photos(), c = await s.cards(), f = await s.favorites();
    if (!mounted) return;
    setState(() {
      final language = widget.japanese ? 'ja' : 'en';
      photos = p.where((x) => x['language'] == language).toList();
      cards = c
          .where((x) => x['discarded'] != true && x['language'] == language)
          .toList();
      favorites = f;
      if (index >= cards.length) index = cards.isEmpty ? 0 : cards.length - 1;
    });
  }

  @override
  void dispose() {
    stop = true;
    speech.stop();
    super.dispose();
  }

  void message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<void> choose() async {
    if (busy || store == null) return;
    final added = <Map<String, dynamic>>[];
    var cancelled = false;
    try {
      final selected = await picker.pickMultiImage(
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      if (selected.isEmpty || !mounted) return;
      setState(() {
        busy = true;
        total = selected.length;
        completed = 0;
        stop = false;
      });
      var errors = 0;
      for (final image in selected) {
        if (stop || !mounted) break;
        try {
          added.add(
            await store!.addPhoto(
              await image.readAsBytes(),
              widget.japanese ? 'ja' : 'en',
            ),
          );
        } catch (_) {
          errors++;
        }
        if (mounted) setState(() => completed++);
      }
      cancelled = stop;
      await refresh();
      if (errors > 0) {
        message('$errors 张照片未能保存，请检查格式或存储空间。');
      } else {
        message('已保存 ${added.length} 张照片到本机。');
      }
    } catch (_) {
      message('无法选择照片，请检查相册权限。');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          stop = false;
        });
      }
    }
    if (mounted && !cancelled && added.isNotEmpty && DevRecognition.enabled) {
      await process(added);
    }
  }

  Future<void> process([List<Map<String, dynamic>>? selected]) async {
    final s = store;
    if (busy || s == null) return;
    if (!DevRecognition.enabled) {
      message('AI 服务尚未配置，照片保留在本机等待处理。');
      return;
    }
    final pending =
        selected ??
        photos
            .where((p) => p['status'] == 'queued' || p['status'] == 'failed')
            .toList();
    if (pending.isEmpty) {
      message('没有待处理的照片。');
      return;
    }
    setState(() {
      busy = true;
      completed = 0;
      total = pending.length;
      stop = false;
    });
    var failed = 0;
    try {
      for (final photo in pending) {
        if (stop || !mounted) break;
        try {
          final file = File('${s.root.path}/${photo['file']}');
          final words = await DevRecognition.recognize(
            await file.readAsBytes(),
            photo['language'] as String,
          );
          await s.saveResults(photo, words);
        } catch (_) {
          failed++;
          try {
            await s.setStatus(photo['id'] as String, 'failed');
          } catch (_) {
            message('无法保存处理状态，请检查存储空间。');
          }
        }
        if (mounted) setState(() => completed++);
      }
      await refresh();
      if (failed > 0) {
        message('$failed 张照片识别失败，仍保存在本机，可重试。');
      } else if (stop) {
        message('已停止处理，剩余照片保留待重试。');
      } else {
        message('照片处理完成。');
      }
    } catch (_) {
      message('无法保存处理结果，请检查设备存储空间。');
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          stop = false;
        });
      }
    }
  }

  Future<void> speak(Map<String, dynamic> card) async {
    try {
      await speech.setLanguage(card['language'] == 'ja' ? 'ja-JP' : 'en-US');
      await speech.setSpeechRate(.45);
      await speech.speak(card['word'] as String);
    } catch (_) {
      message('无法播放发音，请检查系统语音设置。');
    }
  }

  Future<void> actionSheet() async {
    if (cards.isEmpty || busy || store == null) return;
    final card = cards[index];
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.bookmark_add_outlined),
              title: const Text('收藏单词'),
              subtitle: const Text('单独保存到本机收藏'),
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  await store!.favorite(card);
                  await refresh();
                  message('已收藏单词。');
                } catch (_) {
                  message('收藏失败，请检查本机存储。');
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.hide_source),
              title: const Text('Discard · 移出卡片流'),
              subtitle: const Text('本机照片保留，其他词条不受影响'),
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  await store!.discard(card['id'] as String);
                  await refresh();
                  message('已移出卡片流。');
                } catch (_) {
                  message('操作失败，请重试。');
                }
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  double dragDistance = 0;
  void swipe(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (dragDistance < -70 || velocity < -250) {
      if (index + 1 < cards.length) {
        setState(() => index++);
      } else {
        message('已经是最后一张卡片。');
      }
    } else if (dragDistance > 70 || velocity > 250) {
      actionSheet();
    }
    dragDistance = 0;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('批量识词'),
      actions: [
        IconButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => LocalFavorites(store: store)),
          ),
          icon: const Icon(Icons.bookmark_outline),
          tooltip: '本机收藏',
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '照片和卡片保存在本机 · ${widget.japanese ? '日语' : '英语'}',
                  style: const TextStyle(color: Colors.blueGrey),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: busy ? null : choose,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('选择多张照片'),
                    ),
                    FilledButton(
                      onPressed: busy ? null : () => process(),
                      child: Text(
                        DevRecognition.enabled ? '开发测试：处理照片' : '等待识图服务',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  DevRecognition.enabled
                      ? '选择照片后会逐张发送至 DeepSeek，模型调用可能产生费用。'
                      : '识图服务未配置，选中的照片只保存在本机。',
                  style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
                ),
                if (busy) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: total == 0 ? null : completed / total,
                  ),
                  Row(
                    children: [
                      Text('$completed / $total'),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() => stop = true),
                        child: const Text('停止'),
                      ),
                    ],
                  ),
                ],
                if (problem != null)
                  Text(problem!, style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
          Expanded(
            child: cards.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        photos.isEmpty
                            ? '选择照片开始。'
                            : '已保存 ${photos.length} 张照片，等待识别。',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : GestureDetector(
                    onHorizontalDragStart: (_) => dragDistance = 0,
                    onHorizontalDragUpdate: (d) =>
                        dragDistance += d.primaryDelta ?? 0,
                    onHorizontalDragEnd: swipe,
                    child: SingleChildScrollView(
                      key: ValueKey(cards[index]['id']),
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                      child: cardView(cards[index]),
                    ),
                  ),
          ),
          if (cards.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                children: [
                  Text('${index + 1} / ${cards.length}'),
                  const Spacer(),
                  const Text(
                    '左滑下一条 · 右滑操作',
                    style: TextStyle(fontSize: 12, color: Colors.blueGrey),
                  ),
                  IconButton(
                    onPressed: actionSheet,
                    icon: const Icon(Icons.more_horiz),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
  Widget cardView(Map<String, dynamic> card) => Card(
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LabeledPhoto(
          file: File('${store!.root.path}/${card['file']}'),
          card: card,
        ),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      card['word'] as String,
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton.filledTonal(
                    onPressed: () => speak(card),
                    icon: const Icon(Icons.volume_up_outlined),
                    tooltip: '播放发音',
                  ),
                ],
              ),
              if ((card['reading'] as String).isNotEmpty)
                Text(
                  card['reading'] as String,
                  style: const TextStyle(color: Colors.blueGrey),
                ),
              const SizedBox(height: 14),
              Text(
                card['zh'] as String,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                card['en_definition'] as String,
                style: const TextStyle(height: 1.5),
              ),
              const Divider(height: 32),
              const Text('例句', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                card['example'] as String,
                style: const TextStyle(fontSize: 16, height: 1.5),
              ),
              const SizedBox(height: 6),
              Text(
                card['example_zh'] as String,
                style: const TextStyle(color: Colors.blueGrey),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class LocalFavorites extends StatefulWidget {
  const LocalFavorites({super.key, required this.store});
  final BatchStore? store;
  @override
  State<LocalFavorites> createState() => _LocalFavoritesState();
}

class _LocalFavoritesState extends State<LocalFavorites> {
  final speech = FlutterTts();
  @override
  void dispose() {
    speech.stop();
    super.dispose();
  }

  Future<void> speak(Map<String, dynamic> word) async {
    try {
      await speech.setLanguage(word['language'] == 'ja' ? 'ja-JP' : 'en-US');
      await speech.setSpeechRate(.45);
      await speech.speak(word['word'] as String);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法播放发音，请检查系统语音设置。')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('本机收藏')),
    body: FutureBuilder<List<Map<String, dynamic>>>(
      future: widget.store?.favorites() ?? Future.value([]),
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Center(child: Text('无法读取收藏。'));
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final items = snapshot.data!;
        if (items.isEmpty) return const Center(child: Text('还没有收藏的单词。'));
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            final w = items[i];
            return Card(
              child: ExpansionTile(
                title: Text(w['word'] as String),
                subtitle: Text(w['zh'] as String),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if ((w['reading'] as String).isNotEmpty)
                          Text(w['reading'] as String),
                        Text(w['en_definition'] as String),
                        const SizedBox(height: 12),
                        Text(w['example'] as String),
                        Text(w['example_zh'] as String),
                        Align(
                          alignment: Alignment.centerRight,
                          child: IconButton(
                            onPressed: () => speak(w),
                            icon: const Icon(Icons.volume_up_outlined),
                            tooltip: '播放发音',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ),
  );
}

class LabeledPhoto extends StatefulWidget {
  const LabeledPhoto({super.key, required this.file, required this.card});
  final File file;
  final Map<String, dynamic> card;
  @override
  State<LabeledPhoto> createState() => _LabeledPhotoState();
}

class _LabeledPhotoState extends State<LabeledPhoto> {
  late Future<Size> dimensions;
  @override
  void initState() {
    super.initState();
    dimensions = _readSize();
  }

  @override
  void didUpdateWidget(covariant LabeledPhoto old) {
    super.didUpdateWidget(old);
    if (old.file.path != widget.file.path) dimensions = _readSize();
  }

  Future<Size> _readSize() async {
    final codec = await ui.instantiateImageCodec(
      await widget.file.readAsBytes(),
    );
    final frame = await codec.getNextFrame();
    final size = Size(
      frame.image.width.toDouble(),
      frame.image.height.toDouble(),
    );
    frame.image.dispose();
    codec.dispose();
    return size;
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 260,
    child: FutureBuilder<Size>(
      future: dimensions,
      builder: (context, snapshot) {
        if (snapshot.hasError) return const Center(child: Text('照片无法读取'));
        if (!snapshot.hasData) {
          return const Center(child: Text('正在载入照片…'));
        }
        final ratio = snapshot.data!.width / snapshot.data!.height;
        return LayoutBuilder(
          builder: (context, bounds) {
            final width = bounds.maxWidth < 260 * ratio
                ? bounds.maxWidth
                : 260 * ratio;
            final height = width / ratio;
            final box = widget.card['box'];
            return Center(
              child: SizedBox(
                width: width,
                height: height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(widget.file, fit: BoxFit.fill),
                    if (box is List &&
                        box.length == 4 &&
                        box.every((v) => v is num && v >= 0 && v <= 1))
                      Positioned(
                        left: ((box[0] as num).toDouble() * width).clamp(
                          0.0,
                          (width - 120).clamp(0.0, width),
                        ),
                        top: ((box[1] as num).toDouble() * height).clamp(
                          0.0,
                          (height - 34).clamp(0.0, height),
                        ),
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 120),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: .94),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            widget.card['word'] as String,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    ),
  );
}
