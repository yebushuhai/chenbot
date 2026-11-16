import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

const _ink = Color(0xff192921);
const _moss = Color(0xff285643);

class ReadingArticle {
  const ReadingArticle({
    required this.id,
    required this.title,
    required this.englishTitle,
    required this.period,
    required this.description,
    required this.textAsset,
    required this.imageAsset,
    required this.imageCaption,
    required this.textSource,
    required this.imageSource,
  });

  final String id, title, englishTitle, period, description;
  final String textAsset, imageAsset, imageCaption, textSource, imageSource;
}

const readingArticles = <ReadingArticle>[
  ReadingArticle(
    id: 'nanking',
    title: '南京条约',
    englishTitle: 'Treaty of Nanking',
    period: '1842 · 历史条约',
    description: '第一次鸦片战争后签订的不平等条约。收录英文条约、十三条条款及英国批准文书；此版本第十条的税率留空。',
    textAsset: 'assets/reader/nanking.json',
    imageAsset: 'assets/reader/nanking.jpg',
    imageCaption: '《南京条约》签署场景，John Platt 绘、John Burnet 刻，1846 年出版。',
    textSource: 'https://en.wikisource.org/wiki/Treaty_of_Nanking',
    imageSource: 'https://commons.wikimedia.org/wiki/File:The_Signing_of_the_Treaty_of_Nanking.jpg',
  ),
  ReadingArticle(
    id: 'moon_disaster',
    title: '假如登月失败',
    englishTitle: 'In Event of Moon Disaster',
    period: '1969 · 预备讲话',
    description: '白宫为阿波罗 11 号可能发生的事故准备的讲话稿。任务最终成功，讲话从未发表。',
    textAsset: 'assets/reader/moon_disaster.json',
    imageAsset: 'assets/reader/apollo11.jpg',
    imageCaption: '奥尔德林在月球表面，阿姆斯特朗摄，NASA，1969 年。',
    textSource: 'https://www.archives.gov/files/presidential-libraries/events/centennials/nixon/images/exhibit/rn100-6-1.pdf',
    imageSource: 'https://www.archives.gov/research/still-pictures/highlights/apollo-11-mission-image',
  ),
];

class ReaderShelf extends StatelessWidget {
  const ReaderShelf({super.key});

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(22, 24, 22, 30),
    children: [
      Text(
        '英文阅读',
        style: Theme.of(context).textTheme.headlineMedium
            ?.copyWith(fontWeight: FontWeight.w800, color: _ink),
      ),
      const SizedBox(height: 8),
      const Text(
        '长按原文中的英文单词，查看词义和原文例句。',
        style: TextStyle(color: Color(0xff64776b), height: 1.5),
      ),
      const SizedBox(height: 22),
      for (final article in readingArticles) ...[
        Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          child: InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ArticleReaderPage(article: article),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 2.05,
                  child: Image.asset(
                    article.imageAsset,
                    fit: BoxFit.cover,
                    alignment: article.id == 'moon_disaster'
                        ? Alignment.topCenter
                        : Alignment.center,
                    semanticLabel: article.imageCaption,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 15, 18, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        article.period,
                        style: const TextStyle(
                          fontSize: 12,
                          color: _moss,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              article.title,
                              style: const TextStyle(
                                fontSize: 21,
                                color: _ink,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const Icon(Icons.arrow_forward_rounded, color: _moss),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        article.englishTitle,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xff64776b),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    ],
  );
}

Future<List<String>> loadReadingArticle(ReadingArticle article) async {
  final data = jsonDecode(await rootBundle.loadString(article.textAsset));
  if (data is! Map || data['paragraphs'] is! List) {
    throw const FormatException('Invalid article');
  }
  final paragraphs = (data['paragraphs'] as List).whereType<String>().toList();
  if (paragraphs.isEmpty) throw const FormatException('Empty article');
  return paragraphs;
}

class ArticleReaderPage extends StatefulWidget {
  const ArticleReaderPage({super.key, required this.article});
  final ReadingArticle article;

  @override
  State<ArticleReaderPage> createState() => _ArticleReaderPageState();
}

class _ArticleReaderPageState extends State<ArticleReaderPage> {
  late final Future<List<String>> _paragraphs = loadReadingArticle(
    widget.article,
  );

  void _showWord(String word, String example) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ReaderWordSheet(word: word, example: example),
    );
  }

  @override
  Widget build(BuildContext context) {
    final article = widget.article;
    return Scaffold(
      appBar: AppBar(title: Text(article.title)),
      body: FutureBuilder<List<String>>(
        future: _paragraphs,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('文章载入失败，请重试。'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 36),
            children: [
              Text(
                article.period,
                style: const TextStyle(
                  color: _moss,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 9),
              ReaderParagraph(
                text: article.englishTitle,
                isTitle: true,
                onWord: (word, example) => _showWord(
                  word,
                  readingExampleForWord(word, example, snapshot.data!),
                ),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Image.asset(
                  article.imageAsset,
                  fit: BoxFit.contain,
                  semanticLabel: article.imageCaption,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                article.imageCaption,
                style: const TextStyle(
                  color: Color(0xff738279),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: const Color(0xffe7efe7),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Text(
                  article.description,
                  style: const TextStyle(color: Color(0xff42614e), height: 1.5),
                ),
              ),
              const SizedBox(height: 18),
              const Row(
                children: [
                  Icon(Icons.touch_app_outlined, size: 17, color: _moss),
                  SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      '长按英文单词查看解释和例句',
                      style: TextStyle(color: _moss, fontSize: 13),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              for (final paragraph in snapshot.data!) ...[
                ReaderParagraph(
                  text: paragraph,
                  onWord: (word, example) => _showWord(
                    word,
                    readingExampleForWord(word, example, snapshot.data!),
                  ),
                ),
                const SizedBox(height: 19),
              ],
              const Divider(height: 32),
              const Text(
                '资料来源',
                style: TextStyle(color: _ink, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              SelectableText(
                '英文原文：${article.textSource}\n图片：${article.imageSource}\n词义：ECDICT 与本项目补充的历史专名释义。',
                style: const TextStyle(
                  color: Color(0xff738279),
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

final RegExp readingWordPattern = RegExp(
  r"\b\d+(?:st|nd|rd|th)\b|[A-Za-z]+(?:['’][A-Za-z]+)*",
);

String _sentenceForWord(String text, int start, int end) {
  bool boundaryAt(int index) {
    if (!'.!?'.contains(text[index])) return false;
    if (index + 1 < text.length && !RegExp(r'\s').hasMatch(text[index + 1])) {
      return false;
    }
    if (text[index] == '.') {
      final before = text.substring(0, index).toLowerCase();
      final token = RegExp(r'(&c|[a-z]+)$').firstMatch(before)?.group(0);
      if (const {
        'mr',
        'mrs',
        'ms',
        'dr',
        'st',
        'no',
        'bart',
        'gen',
        'etc',
        '&c',
      }.contains(token)) {
        return false;
      }
    }
    return true;
  }

  var left = 0;
  for (var i = 0; i < start; i++) {
    if (boundaryAt(i)) left = i + 1;
  }
  var right = text.length;
  for (var i = end; i < text.length; i++) {
    if (boundaryAt(i)) {
      right = i + 1;
      break;
    }
  }
  return text.substring(left, right).trim();
}

bool isReadingSentence(String text) =>
    readingWordPattern.allMatches(text).length >= 3 &&
    RegExp(r'''[.!?][”’"']?$''').hasMatch(text.trim());

String readingExampleForWord(
  String word,
  String original,
  List<String> paragraphs,
) {
  if (isReadingSentence(original)) return original;
  final normalized = word.toLowerCase().replaceAll('’', "'");
  for (var i = 0; i < paragraphs.length; i++) {
    final paragraph = paragraphs[i];
    for (final match in readingWordPattern.allMatches(paragraph)) {
      if (match.group(0)!.toLowerCase().replaceAll('’', "'") != normalized) {
        continue;
      }
      final candidate = _sentenceForWord(paragraph, match.start, match.end);
      if (isReadingSentence(candidate)) return candidate;
      if (candidate.endsWith(':') && i + 1 < paragraphs.length) {
        final combined = '$candidate ${paragraphs[i + 1]}';
        if (isReadingSentence(combined)) return combined;
      }
    }
  }
  // A few historical initials appear only in a signature, not a full sentence.
  return original;
}

class ReaderParagraph extends StatefulWidget {
  const ReaderParagraph({
    super.key,
    required this.text,
    required this.onWord,
    this.isTitle = false,
  });
  final String text;
  final void Function(String word, String example) onWord;
  final bool isTitle;

  @override
  State<ReaderParagraph> createState() => _ReaderParagraphState();
}

class _ReaderParagraphState extends State<ReaderParagraph> {
  final _recognizers = <LongPressGestureRecognizer>[];
  late List<InlineSpan> _spans;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(covariant ReaderParagraph oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      for (final recognizer in _recognizers) {
        recognizer.dispose();
      }
      _recognizers.clear();
      _prepare();
    }
  }

  void _prepare() {
    _spans = [];
    var cursor = 0;
    for (final match in readingWordPattern.allMatches(widget.text)) {
      if (match.start > cursor) {
        _spans.add(TextSpan(text: widget.text.substring(cursor, match.start)));
      }
      final word = match.group(0)!;
      final recognizer = LongPressGestureRecognizer()
        ..onLongPress = () => widget.onWord(
          word,
          _sentenceForWord(widget.text, match.start, match.end),
        );
      _recognizers.add(recognizer);
      _spans.add(TextSpan(text: word, recognizer: recognizer));
      cursor = match.end;
    }
    if (cursor < widget.text.length) {
      _spans.add(TextSpan(text: widget.text.substring(cursor)));
    }
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isHeading =
        RegExp(r'^Article \d+\.$').hasMatch(widget.text) ||
        widget.text == 'Treaty.';
    return Text.rich(
      TextSpan(children: _spans),
      style: TextStyle(
        color: _ink,
        fontSize: widget.isTitle
            ? 30
            : isHeading
            ? 19
            : 17,
        height: widget.isTitle ? 1.12 : 1.75,
        fontWeight: widget.isTitle
            ? FontWeight.w800
            : isHeading
            ? FontWeight.w700
            : FontWeight.w400,
      ),
    );
  }
}

class ReadingDefinition {
  const ReadingDefinition(
    this.chinese,
    this.english,
    this.phonetic,
    this.base,
    this.example,
  );
  final String chinese, english, phonetic, base, example;
}

class ReadingDictionary {
  static Future<Map<String, dynamic>>? _cache;

  static Future<Map<String, dynamic>> _load() async {
    final future = _cache ??= rootBundle
        .loadString('assets/reader/dictionary.json')
        .then((value) => Map<String, dynamic>.from(jsonDecode(value) as Map));
    try {
      return await future;
    } catch (_) {
      if (identical(_cache, future)) _cache = null;
      rethrow;
    }
  }

  static Future<ReadingDefinition?> lookup(String word) async {
    final data = await _load();
    final key = word.toLowerCase().replaceAll('’', "'");
    final raw = data[key];
    if (raw is! Map) return null;
    return ReadingDefinition(
      (raw['zh'] as String?) ?? '',
      (raw['en'] as String?) ?? '',
      (raw['phonetic'] as String?) ?? '',
      (raw['base'] as String?) ?? '',
      (raw['example'] as String?) ?? '',
    );
  }
}

class ReaderWordSheet extends StatefulWidget {
  const ReaderWordSheet({super.key, required this.word, required this.example});
  final String word, example;

  @override
  State<ReaderWordSheet> createState() => _ReaderWordSheetState();
}

class _ReaderWordSheetState extends State<ReaderWordSheet> {
  late final Future<ReadingDefinition?> _entry = ReadingDictionary.lookup(
    widget.word,
  );
  final FlutterTts _speech = FlutterTts();

  Future<void> _speak() async {
    try {
      await _speech.setLanguage('en-US');
      await _speech.speak(widget.word);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法播放发音，请检查系统语音设置。')));
      }
    }
  }

  @override
  void dispose() {
    _speech.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .76,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 30),
        child: FutureBuilder<ReadingDefinition?>(
          future: _entry,
          builder: (context, snapshot) {
            final entry = snapshot.data;
            final useSupplement =
                !isReadingSentence(widget.example) &&
                entry != null &&
                entry.example.isNotEmpty;
            final example = useSupplement ? entry.example : widget.example;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.word,
                        style: const TextStyle(
                          fontSize: 30,
                          color: _ink,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    IconButton.filledTonal(
                      onPressed: _speak,
                      icon: const Icon(Icons.volume_up_outlined),
                      tooltip: '播放发音',
                    ),
                  ],
                ),
                if (entry != null && entry.phonetic.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '/${entry.phonetic}/',
                    style: const TextStyle(color: Color(0xff718176)),
                  ),
                ],
                if (entry != null &&
                    entry.base.isNotEmpty &&
                    entry.base != widget.word.toLowerCase()) ...[
                  const SizedBox(height: 4),
                  Text(
                    '原形：${entry.base}',
                    style: const TextStyle(color: Color(0xff718176)),
                  ),
                ],
                const SizedBox(height: 18),
                const Text(
                  '词义',
                  style: TextStyle(
                    fontSize: 14,
                    color: _moss,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 7),
                if (snapshot.connectionState != ConnectionState.done)
                  const Text('正在查词…')
                else if (snapshot.hasError)
                  const Text('本地词典载入失败，请稍后再试。', style: TextStyle(height: 1.5))
                else if (entry == null)
                  const Text(
                    '本地词典暂未收录该词，请结合原文理解。',
                    style: TextStyle(height: 1.5),
                  )
                else ...[
                  if (entry.chinese.isNotEmpty)
                    Text(
                      entry.chinese,
                      style: const TextStyle(
                        fontSize: 17,
                        height: 1.55,
                        color: _ink,
                      ),
                    ),
                  if (entry.english.isNotEmpty) ...[
                    const SizedBox(height: 9),
                    Text(
                      entry.english,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.5,
                        color: Color(0xff607267),
                      ),
                    ),
                  ],
                ],
                const SizedBox(height: 20),
                Text(
                  useSupplement ? '补充例句' : '原文例句',
                  style: const TextStyle(
                    fontSize: 14,
                    color: _moss,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 7),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xffedf3ec),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Text(
                    example,
                    style: const TextStyle(
                      fontSize: 16,
                      height: 1.6,
                      color: _ink,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  '词典释义仅供参考，具体意思请结合上下文。',
                  style: TextStyle(color: Color(0xff849086), fontSize: 12),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}
