import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_page.dart';
import 'dev_recognition.dart';
import 'assessment_preview.dart';
import 'batch_page.dart';

import 'package:image_picker/image_picker.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import 'batch_store.dart';
import 'image_prepare.dart';

bool authConfigured = false;
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const url = String.fromEnvironment('SUPABASE_URL');
  const key = String.fromEnvironment('SUPABASE_ANON_KEY');
  if (url.isNotEmpty && key.isNotEmpty) {
    try {
      await Supabase.initialize(url: url, publishableKey: key);
      authConfigured = true;
    } catch (_) {
      authConfigured = false;
    }
  }
  runApp(const Chenbot());
}

const ink = Color(0xff192921);
const moss = Color(0xff285643);
const paper = Color(0xfff6f6ef);

class Chenbot extends StatelessWidget {
  const Chenbot({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Chenbot',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: moss, surface: paper),
      scaffoldBackgroundColor: paper,
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: ink),
        titleLarge: TextStyle(color: ink, fontWeight: FontWeight.w700),
      ),
    ),
    home: const Home(),
  );
}

class Word {
  const Word(
    this.english,
    this.japanese,
    this.reading,
    this.chinese,
    this.definition,
    this.enExample,
    this.jaExample,
    this.translation,
    this.icon,
  );
  final String english,
      japanese,
      reading,
      chinese,
      definition,
      enExample,
      jaExample,
      translation;
  final IconData icon;
}

const words = [
  Word(
    'coffee',
    'コーヒー',
    'コーヒー',
    '咖啡',
    'A drink made from roasted coffee beans.',
    'I drink coffee in the morning.',
    '朝、コーヒーを飲みます。',
    '我早上喝咖啡。',
    Icons.local_cafe_outlined,
  ),
  Word(
    'book',
    '本',
    'ほん',
    '书',
    'A set of written or printed pages bound together.',
    'This book is interesting.',
    'この本は面白いです。',
    '这本书很有趣。',
    Icons.menu_book_rounded,
  ),
  Word(
    'plant',
    '植物',
    'しょくぶつ',
    '植物',
    'A living thing that grows in soil, water, or air.',
    'The plant needs water.',
    '植物には水が必要です。',
    '植物需要水。',
    Icons.spa_outlined,
  ),
];

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final _picker = ImagePicker();
  final _speech = FlutterTts();
  Uint8List? _imageBytes;
  double _imageRatio = 1;
  bool _recognizing = false;
  List<DetectedWord> _detected = [];
  Future<void> recognize() async {
    final image = _imageBytes;
    if (image == null || _recognizing) return;
    final requestedJapanese = japanese;
    setState(() {
      _recognizing = true;
      _detected = [];
    });
    try {
      final items = await DevRecognition.recognize(
        image,
        requestedJapanese ? 'ja' : 'en',
      );
      if (mounted &&
          identical(image, _imageBytes) &&
          requestedJapanese == japanese) {
        setState(() => _detected = items);
      }
    } catch (_) {
      if (mounted) unavailable('识别失败，请检查开发服务、网络和图片格式后重试。');
    } finally {
      if (mounted) setState(() => _recognizing = false);
    }
  }

  Word detectedAsWord(DetectedWord w) => Word(
    w.word,
    w.word,
    w.reading,
    w.zh,
    w.definition,
    w.example,
    w.example,
    w.exampleZh,
    Icons.label_outline,
  );
  Future<void> pick(ImageSource source) async {
    try {
      final image = await _picker.pickImage(
        source: source,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      if (!mounted || image == null) return;
      final bytes = await preparePhoto(await image.readAsBytes());
      if (bytes.length > 8 * 1024 * 1024) throw StateError('image too large');
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final ratio = frame.image.width / frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (!mounted) return;
      setState(() {
        _imageBytes = bytes;
        _imageRatio = ratio;
        _detected = [];
      });
    } catch (_) {
      if (mounted) unavailable('无法打开相机或相册，请检查设备权限后重试。');
    }
  }

  Future<void> speak(Word word) async {
    try {
      await _speech.setLanguage(japanese ? 'ja-JP' : 'en-US');
      await _speech.setSpeechRate(0.45);
      await _speech.speak(japanese ? word.japanese : word.english);
    } catch (_) {
      if (mounted) unavailable('无法播放发音，请检查设备的语音设置。');
    }
  }

  void chooseImage() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('拍照'),
            onTap: () {
              Navigator.pop(ctx);
              pick(ImageSource.camera);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('从相册选择'),
            onTap: () {
              Navigator.pop(ctx);
              pick(ImageSource.gallery);
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    ),
  );
  @override
  void dispose() {
    _speech.stop();
    super.dispose();
  }

  int tab = 0;
  bool japanese = false;
  bool _languageSelectedThisSession = false;
  final saved = <String>{};
  SharedPreferences? _prefs;
  Future<void> _writeQueue = Future.value();
  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _prefs = prefs;
        saved.addAll(prefs.getStringList('saved_examples') ?? []);
        if (!_languageSelectedThisSession) {
          japanese = prefs.getString('learning_language') == 'ja';
        }
      });
    } catch (_) {
      if (mounted) unavailable('无法读取本机收藏，请检查设备存储设置。');
    }
  }

  void selectLanguage(bool value) {
    _languageSelectedThisSession = true;
    setState(() {
      japanese = value;
      _detected = [];
    });
    _writeQueue = _writeQueue
        .then((_) async {
          final prefs = _prefs ?? await SharedPreferences.getInstance();
          if (!await prefs.setString(
            'learning_language',
            value ? 'ja' : 'en',
          )) {
            throw StateError('save failed');
          }
        })
        .catchError((_) {
          if (mounted) unavailable('学习语言保存失败，请检查本机存储设置。');
        });
  }

  void toggleSaved(Word w) {
    if (_prefs == null) {
      unavailable('收藏正在准备中，请稍后重试。');
      return;
    }
    setState(() {
      if (!saved.add(w.english)) saved.remove(w.english);
    });
    final snapshot = saved.toList();
    _writeQueue = _writeQueue
        .then((_) async {
          if (!await _prefs!.setStringList('saved_examples', snapshot)) {
            throw StateError('save failed');
          }
        })
        .catchError((_) {
          if (mounted) unavailable('收藏保存失败，请检查设备存储设置。');
        });
  }

  String get localScope => localScopeForUser(
    authConfigured ? Supabase.instance.client.auth.currentUser?.id : null,
  );
  Future<void> openBatchFavorites() async {
    try {
      final root = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => LocalFavorites(
            store: BatchStore(
              Directory('${root.path}/chenbot_batch/$localScope'),
            ),
          ),
        ),
      );
    } catch (_) {
      if (mounted) unavailable('无法读取本机收藏。');
    }
  }

  Future<void> login() async {
    if (!authConfigured) {
      unavailable('邮箱登录服务尚未配置，请稍后再试。');
      return;
    }
    await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const AuthPage()));
    if (mounted) setState(() {});
  }

  Future<void> signOut() async {
    try {
      await Supabase.instance.client.auth.signOut();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) unavailable('退出登录失败，请稍后重试。');
    }
  }

  void unavailable(String text) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('功能准备中', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(text, style: const TextStyle(height: 1.6)),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ),
        ],
      ),
    ),
  );
  void detail(Word w, {bool canSave = true}) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          japanese ? w.japanese : w.english,
                          style: const TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          japanese ? w.reading : '英语 · 示例单词',
                          style: const TextStyle(color: Color(0xff768479)),
                        ),
                      ],
                    ),
                  ),
                  IconButton.filledTonal(
                    onPressed: () => speak(w),
                    icon: const Icon(Icons.volume_up_outlined),
                    tooltip: '播放发音',
                  ),
                  if (canSave)
                    IconButton(
                      onPressed: () {
                        toggleSaved(w);
                        update(() {});
                      },
                      icon: Icon(
                        saved.contains(w.english)
                            ? Icons.bookmark
                            : Icons.bookmark_border,
                      ),
                      tooltip: '收藏',
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                w.chinese,
                style: const TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                w.definition,
                style: const TextStyle(fontSize: 15, height: 1.5),
              ),
              const Divider(height: 36),
              const Text('例句', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              Text(
                japanese ? w.jaExample : w.enExample,
                style: const TextStyle(fontSize: 17),
              ),
              const SizedBox(height: 5),
              Text(
                w.translation,
                style: const TextStyle(color: Color(0xff718176)),
              ),
              const SizedBox(height: 16),
              const Text(
                '示例内容，仅用于展示界面',
                style: TextStyle(fontSize: 12, color: Color(0xff849086)),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: IndexedStack(index: tab, children: [home(), library(), account()]),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (i) => setState(() => tab = i),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.center_focus_weak_outlined),
          selectedIcon: Icon(Icons.center_focus_strong),
          label: '识词',
        ),
        NavigationDestination(
          icon: Icon(Icons.bookmark_border),
          selectedIcon: Icon(Icons.bookmark),
          label: '生词本',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: '我的',
        ),
      ],
    ),
  );
  Widget home() => ListView(
    padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
    children: [
      Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: moss,
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(
              Icons.auto_awesome,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'chenbot',
            style: TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.w800,
              letterSpacing: -.8,
            ),
          ),
          const Spacer(),
          const Text('学习语言', style: TextStyle(color: Color(0xff718176))),
          const SizedBox(width: 8),
          PopupMenuButton<bool>(
            initialValue: japanese,
            onSelected: selectLanguage,
            itemBuilder: (_) => const [
              PopupMenuItem(value: false, child: Text('英语')),
              PopupMenuItem(value: true, child: Text('日语')),
            ],
            child: Chip(
              label: Text(japanese ? '日语  ▾' : '英语  ▾'),
              side: BorderSide.none,
              backgroundColor: const Color(0xffe6eee6),
            ),
          ),
        ],
      ),
      const SizedBox(height: 36),
      const Text(
        '看见世界，\n认识新单词。',
        style: TextStyle(
          fontSize: 34,
          height: 1.22,
          fontWeight: FontWeight.w800,
          letterSpacing: -1,
        ),
      ),
      const SizedBox(height: 24),
      Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: const Color(0xffdfece0),
          borderRadius: BorderRadius.circular(26),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: .75),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(
                    Icons.add_a_photo_outlined,
                    color: moss,
                    size: 26,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.auto_awesome, color: moss),
              ],
            ),
            const SizedBox(height: 23),
            const Text(
              '从一张照片开始',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            const Text(
              '上传照片，探索画面里的单词。',
              style: TextStyle(color: Color(0xff587263)),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: chooseImage,
                icon: const Icon(Icons.add),
                label: const Text('添加照片'),
                style: FilledButton.styleFrom(
                  backgroundColor: moss,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
      ),
      if (_imageBytes != null) ...[
        const SizedBox(height: 18),
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: AspectRatio(
            aspectRatio: _imageRatio,
            child: LayoutBuilder(
              builder: (context, constraints) => Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(_imageBytes!, fit: BoxFit.fill),
                  for (final item in _detected.where(
                    (item) => item.box != null,
                  ))
                    Positioned(
                      left: (item.box![0] * constraints.maxWidth).clamp(
                        0.0,
                        (constraints.maxWidth - 120).clamp(
                          0.0,
                          constraints.maxWidth,
                        ),
                      ),
                      top: (item.box![1] * constraints.maxHeight).clamp(
                        0.0,
                        (constraints.maxHeight - 40).clamp(
                          0.0,
                          constraints.maxHeight,
                        ),
                      ),
                      child: ActionChip(
                        label: Text(item.word, overflow: TextOverflow.ellipsis),
                        onPressed: () =>
                            detail(detectedAsWord(item), canSave: false),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        if (DevRecognition.enabled) ...[
          const Text(
            '开发测试：识别会把照片发送至 DeepSeek，标签位置可能不准确。',
            style: TextStyle(color: Color(0xff738279)),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: _recognizing ? null : recognize,
            child: Text(_recognizing ? '识别中…' : '开发测试：识别照片'),
          ),
          for (final item in _detected.where(
            (item) => item.kind == 'adjective',
          ))
            ActionChip(
              label: Text(item.word),
              onPressed: () => detail(detectedAsWord(item), canSave: false),
            ),
        ] else
          const Text(
            '照片仅在本机预览，AI 识别服务尚未接入。',
            style: TextStyle(color: Color(0xff738279)),
          ),
      ],
      const SizedBox(height: 16),
      Card(
        child: ListTile(
          leading: const Icon(Icons.collections_outlined),
          title: const Text('批量照片识词'),
          subtitle: const Text('多张照片 · 本机卡片与收藏'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  BatchPage(japanese: japanese, storageScope: localScope),
            ),
          ),
        ),
      ),
      const SizedBox(height: 24),
      Card(
        child: ListTile(
          leading: const Icon(Icons.quiz_outlined),
          title: const Text('体验水平测试'),
          subtitle: const Text('示例题 · 暂不估算词汇量'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AssessmentPreview(japanese: japanese),
            ),
          ),
        ),
      ),
      const SizedBox(height: 30),
      const Row(
        children: [
          Expanded(
            child: Text(
              '先看看如何学习',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
            ),
          ),
          Text('示例', style: TextStyle(color: Color(0xff809085))),
        ],
      ),
      const SizedBox(height: 12),
      const Text(
        '点击下面的示例单词，看看释义和例句。',
        style: TextStyle(color: Color(0xff738279)),
      ),
      const SizedBox(height: 14),
      ...words.map((w) => wordTile(w)),
    ],
  );
  Widget wordTile(Word w) => Padding(
    padding: const EdgeInsets.only(bottom: 9),
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      child: ListTile(
        onTap: () => detail(w),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: const Color(0xfff0f4ec),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(w.icon, color: moss),
        ),
        title: Text(
          japanese ? w.japanese : w.english,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(japanese ? '${w.reading} · ${w.chinese}' : w.chinese),
        trailing: const Icon(
          Icons.arrow_forward_ios_rounded,
          size: 15,
          color: Color(0xffa0aaa2),
        ),
      ),
    ),
  );
  Widget library() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const SizedBox(height: 12),
      const Text(
        '生词本',
        style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 8),
      const Text('把想记住的词留在这里。', style: TextStyle(color: Color(0xff738279))),
      const SizedBox(height: 20),
      Card(
        child: ListTile(
          leading: const Icon(Icons.bookmark_outline),
          title: const Text('批量识词收藏'),
          subtitle: const Text('查看单独保存的词条'),
          trailing: const Icon(Icons.chevron_right),
          onTap: openBatchFavorites,
        ),
      ),
      const SizedBox(height: 16),
      const Text('示例收藏', style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      if (saved.isEmpty)
        const Card(
          child: Padding(
            padding: EdgeInsets.all(25),
            child: Text(
              '还没有收藏单词。\n试着打开首页的示例并点击书签。',
              style: TextStyle(height: 1.7),
            ),
          ),
        )
      else
        ...words.where((w) => saved.contains(w.english)).map(wordTile),
      const SizedBox(height: 12),
      const Text(
        '示例收藏保存在本机，账号同步尚未接入。',
        style: TextStyle(color: Color(0xff829087), fontSize: 12),
      ),
    ],
  );
  Widget account() => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const SizedBox(height: 12),
      const Text(
        '我的',
        style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 24),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '你的学习空间',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                '登录后同步单词与识图额度。',
                style: TextStyle(color: Color(0xff738279)),
              ),
              const SizedBox(height: 14),
              FilledButton.tonal(
                onPressed:
                    authConfigured &&
                        Supabase.instance.client.auth.currentUser != null
                    ? signOut
                    : login,
                child: Text(
                  authConfigured &&
                          Supabase.instance.client.auth.currentUser != null
                      ? '退出登录'
                      : '邮箱登录',
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 16),
      Card(
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.toll_outlined),
              title: const Text('识图额度'),
              subtitle: const Text('额度服务尚未接入'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => unavailable('免费额度和充值尚未开放，当前不会产生收费。'),
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('隐私与数据'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => unavailable('正式版本将说明照片处理、保存期限和账号删除方式。'),
            ),
          ],
        ),
      ),
    ],
  );
}
