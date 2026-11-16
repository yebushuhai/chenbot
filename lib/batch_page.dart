import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'batch_store.dart';
import 'deepseek_recognition.dart';
import 'deepseek_account.dart';
import 'english_level.dart';
import 'english_level_colors.dart';
import 'english_level_page.dart';
import 'deepseek_settings.dart';
import 'recognition_pipeline.dart';
import 'vocabulary.dart';
import 'vocabulary_widgets.dart';

class BatchPage extends StatefulWidget {
  const BatchPage({
    super.key,
    required this.japanese,
    this.storeOverride,
    this.serviceFactory,
    this.storageScope = 'guest',
  });
  final bool japanese;
  final BatchStore? storeOverride;
  final DeepSeekRecognition Function()? serviceFactory;
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
  int refreshVersion = 0;
  bool busy = false, stop = false, deepSeekConfigured = false;
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
      await refreshDeepSeekSettings();
    } catch (_) {
      if (mounted) setState(() => problem = '无法读取本机数据，请检查设备存储空间。');
    }
  }

  Future<void> refreshDeepSeekSettings() async {
    try {
      final present = await DeepSeekKeyStore(widget.storageScope).hasKey();
      if (mounted) setState(() => deepSeekConfigured = present);
    } catch (_) {
      if (mounted) setState(() => deepSeekConfigured = false);
    }
  }

  Future<void> openDeepSeekSettings() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => DeepSeekSettingsPage(scope: widget.storageScope),
      ),
    );
    if (mounted) await refreshDeepSeekSettings();
  }

  Future<void> refresh() async {
    final s = store;
    if (s == null) return;
    final version = ++refreshVersion;
    final p = await s.photos(),
        c = await s.visibleCards(),
        f = await s.visibleFavorites();
    final profile = widget.japanese
        ? null
        : await EnglishLevelProfile.load(widget.storageScope);
    if (!mounted || version != refreshVersion) return;
    setState(() {
      final language = widget.japanese ? 'ja' : 'en';
      photos = p.where((x) => x['language'] == language).toList();
      cards = c
          .where(
            (x) =>
                x['discarded'] != true &&
                x['language'] == language &&
                englishCardMatchesBand(x, profile?.band),
          )
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
    if (mounted && !cancelled && added.isNotEmpty && deepSeekConfigured) {
      await process(added);
    }
  }

  Future<void> process([List<Map<String, dynamic>>? selected]) async {
    final s = store;
    if (busy || s == null) return;
    final pending =
        selected ??
        photos
            .where(
              (p) =>
                  p['status'] == 'queued' ||
                  p['status'] == 'failed' ||
                  p['status'] == 'no_match',
            )
            .toList();
    if (pending.isEmpty) {
      message('没有待处理的照片。');
      return;
    }
    String? key;
    try {
      key = await DeepSeekKeyStore(widget.storageScope).read();
    } catch (_) {
      message('无法读取本机密钥，请检查 DeepSeek 识图设置。');
      return;
    }
    if (!mounted) return;
    if (key == null || key.isEmpty) {
      message('请先设置 DeepSeek API Key，照片保留在本机。');
      await openDeepSeekSettings();
      return;
    }
    EnglishLevelProfile? profile;
    Map<String, bool> practice = {};
    try {
      profile = await EnglishLevelProfile.load(widget.storageScope);
      practice = await VocabularyPractice.load(widget.storageScope);
    } catch (_) {
      // Do not upload English images without a valid difficulty preference.
    }
    if (!mounted) return;
    if (pending.any((photo) => photo['language'] == 'en') && profile == null) {
      message('请先选择英语识图等级。');
      return;
    }
    final approved = await confirmDeepSeekUpload(context, pending.length);
    if (!approved || !mounted) return;
    setState(() {
      busy = true;
      completed = 0;
      total = pending.length;
      stop = false;
    });
    String? failure;
    var exhausted = 0;
    var noMatchingWords = 0;
    late final DeepSeekRecognition service;
    if (widget.serviceFactory != null) {
      service = widget.serviceFactory!();
    } else {
      service = DeepSeekRecognition(
        onUsage: DeepSeekUsageStore(widget.storageScope).record,
        englishLevel: profile?.band.difficulty,
      );
    }
    try {
      for (final photo in pending) {
        if (stop || !mounted) break;
        try {
          final result = await recognizeForLearner(
            image: await s.readPhoto(photo),
            language: photo['language'] as String,
            key: key,
            service: service,
            store: s,
            englishLevel: profile?.band.difficulty,
            practice: practice,
          );
          await s.saveResults(photo, result.words);
          if (result.noMatchingWords) {
            noMatchingWords++;
          } else if (result.exhausted) {
            exhausted++;
          }
        } catch (error) {
          failure = error is DeepSeekException
              ? error.message
              : '无法处理照片或保存结果，请检查设备存储后重试。';
          try {
            await s.setStatus(photo['id'] as String, 'failed');
          } catch (_) {
            message('无法保存处理状态，请检查存储空间。');
          }
          if (mounted) setState(() => completed++);
          break;
        }
        if (mounted) setState(() => completed++);
      }
      await refresh();
      if (failure != null) {
        message('处理已暂停：$failure 照片保留在本机，可重试。');
      } else if (stop) {
        message('已停止处理，剩余照片保留待重试。');
      } else {
        message(
          noMatchingWords > 0
              ? '处理完成，$noMatchingWords 张照片重新识别后仍没有符合等级且在词频表中的物品词。'
              : exhausted > 0
              ? '处理完成，$exhausted 张照片没有可显示的新物品，可查看垃圾桶或换张照片。'
              : '照片处理完成。',
        );
      }
    } catch (_) {
      message('无法保存处理结果，请检查设备存储空间。');
    } finally {
      service.close();
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

  Future<void> favoriteCard(Map<String, dynamic> card) async {
    try {
      await store!.favorite(card);
      await refresh();
      message('已收藏 ${card['word']}。');
    } catch (_) {
      message('收藏失败，请检查本机存储。');
    }
  }

  Future<void> moveCard(Map<String, dynamic> card, Offset position) async {
    try {
      await store!.moveLabel(card['id'] as String, position.dx, position.dy);
      if (mounted) {
        setState(() {
          card['labelX'] = position.dx;
          card['labelY'] = position.dy;
        });
      }
    } catch (_) {
      message('无法保存单词位置，请检查本机存储。');
    }
  }

  Future<void> discardCard(Map<String, dynamic> card) async {
    try {
      await store!.discard(card['id'] as String);
      await refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已将 ${card['word']} 和已识别的词形放入垃圾桶。'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              try {
                await store!.restoreMatching(card);
                await refresh();
              } catch (_) {
                message('恢复失败，请检查本机存储。');
              }
            },
          ),
        ),
      );
    } catch (_) {
      message('操作失败，请重试。');
    }
  }

  Future<void> openTrash() async {
    if (store == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => LocalTrashPage(store: store!)),
    );
    await refresh();
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
                await favoriteCard(card);
              },
            ),
            ListTile(
              leading: const Icon(Icons.hide_source),
              title: const Text('Discard · 移出卡片流'),
              subtitle: const Text('放入垃圾桶，之后过滤这个词及已识别的词形'),
              onTap: () async {
                Navigator.pop(ctx);
                await discardCard(card);
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
    floatingActionButton: cards.isNotEmpty && !busy
        ? Material(
            elevation: 5,
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            child: TrashDropTarget(onDiscard: discardCard),
          )
        : null,
    appBar: AppBar(
      title: const Text('批量识词'),
      actions: [
        IconButton(
          onPressed: busy ? null : openDeepSeekSettings,
          icon: const Icon(Icons.key_outlined),
          tooltip: 'DeepSeek 识图设置',
        ),
        IconButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => LocalFavorites(store: store)),
          ),
          icon: const Icon(Icons.bookmark_outline),
          tooltip: '本机收藏',
        ),
        IconButton(
          onPressed: openTrash,
          icon: const Icon(Icons.delete_outline),
          tooltip: '单词垃圾桶',
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
                if (!widget.japanese)
                  IgnorePointer(
                    ignoring: busy,
                    child: EnglishDifficultySelector(
                      scope: widget.storageScope,
                      onChanged: (_) => refresh(),
                    ),
                  ),
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
                      onPressed: busy
                          ? null
                          : deepSeekConfigured
                          ? () => process()
                          : openDeepSeekSettings,
                      child: Text(
                        deepSeekConfigured ? '处理待识别照片' : '设置 API Key',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  deepSeekConfigured
                      ? '确认后逐张发送到 DeepSeek，使用你自己的 API 额度。'
                      : '请先设置自己的 DeepSeek API Key；未确认发送前照片保存在本机。',
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
                        child: const Text('本张完成后停止'),
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
                            : '已保存 ${photos.length} 张照片。当前等级没有可显示的词时，可调整等级或选择其他照片。',
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
          onFavorite: () => favoriteCard(card),
          onPositionChanged: (position) => moveCard(card, position),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (card['kind'] == 'adjective')
                VocabularyTag(card: card, onFavorite: () => favoriteCard(card)),
              IconButton(
                onPressed: () => discardCard(card),
                icon: const Icon(Icons.delete_outline),
                tooltip: '放入垃圾桶',
              ),
            ],
          ),
        ),
        Container(
          color: englishWordColor(card),
          padding: const EdgeInsets.all(20),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: wordTextColor(englishWordColor(card))),
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
                    style: TextStyle(
                      color: wordTextColor(englishWordColor(card))
                          .withValues(alpha: .7),
                    ),
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
                  style: TextStyle(
                    color: wordTextColor(englishWordColor(card))
                        .withValues(alpha: .7),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('AI 生成内容，仅供学习参考', style: TextStyle(fontSize: 12)),
              ],
            ),
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
      future: widget.store?.visibleFavorites() ?? Future.value([]),
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
  const LabeledPhoto({
    super.key,
    required this.file,
    required this.card,
    required this.onFavorite,
    this.onPositionChanged,
  });
  final File file;
  final Map<String, dynamic> card;
  final VoidCallback onFavorite;
  final ValueChanged<Offset>? onPositionChanged;
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
        return VocabularyPhotoCanvas(
          image: Image.file(widget.file, fit: BoxFit.fill),
          aspectRatio: ratio,
          minHeight: 260,
          maxHeight: 260,
          cards: [widget.card],
          onFavorite: (_) => widget.onFavorite(),
          onPositionChanged: (_, position) =>
              widget.onPositionChanged?.call(position),
        );
      },
    ),
  );
}
