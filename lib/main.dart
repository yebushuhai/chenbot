import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseRegistry, LicenseEntryWithLineBreaks, defaultTargetPlatform;
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_page.dart';
import 'deepseek_recognition.dart';
import 'deepseek_account.dart';
import 'deepseek_settings.dart';
import 'english_level.dart';
import 'english_level_page.dart';
import 'assessment_preview.dart';
import 'batch_page.dart';
import 'recognition_pipeline.dart';
import 'reader_page.dart';
import 'vocabulary.dart';
import 'vocabulary_widgets.dart';

import 'package:image_picker/image_picker.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';

import 'batch_store.dart';
import 'image_prepare.dart';

bool authConfigured = false;
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['LemmInflect / SPECIALIST Lexicon'],
      await rootBundle.loadString('assets/vocabulary/LEMMinflect_LICENSE.txt'),
    );
    yield LicenseEntryWithLineBreaks(
      ['FrequencyWords — OpenSubtitles 2018'],
      'Word-form ranks adapted from FrequencyWords by hermitdave and contributors. '
      'First 500,000 English forms, counts removed; CC BY-SA 4.0. '
      'Source: https://github.com/hermitdave/FrequencyWords\n\n'
      '${await rootBundle.loadString('assets/vocabulary/CC_BY_SA_4.0.txt')}',
    );
    yield LicenseEntryWithLineBreaks(
      ['ECDICT — English–Chinese dictionary'],
      'Reading dictionary entries adapted from ECDICT. '
      'Source: https://github.com/skywind3000/ECDICT\n\n'
      '${await rootBundle.loadString('assets/reader/ECDICT_LICENSE.txt')}',
    );
    yield LicenseEntryWithLineBreaks([
      'Gelasio',
    ], await rootBundle.loadString('assets/fonts/Gelasio-OFL.txt'));
  });
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
      // Georgia is built into iOS; Gelasio is an open-licensed substitute for
      // Android, where Georgia is generally not supplied by the device.
      fontFamily:
          defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.macOS
          ? 'Georgia'
          : 'Gelasio',
      fontFamilyFallback: const ['Gelasio'],
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
  int _levelVersion = 0;
  bool _deepSeekConfigured = false;
  List<Map<String, dynamic>> _detected = [];
  BatchStore? _singleStore;
  String? _singlePhotoId;
  Future<void> recognize() async {
    final image = _imageBytes;
    if (image == null || _recognizing) return;
    final requestedJapanese = japanese;
    String? key;
    try {
      key = await DeepSeekKeyStore(localScope).read();
    } catch (_) {
      if (mounted) unavailable('无法读取本机密钥，请检查 DeepSeek 识图设置。', title: '识别未完成');
      return;
    }
    if (!mounted) return;
    if (key == null || key.isEmpty) {
      await openDeepSeekSettings();
      return;
    }
    final scope = localScope;
    EnglishLevelProfile? profile;
    Map<String, bool> practice = {};
    try {
      profile = await EnglishLevelProfile.load(scope);
      practice = await VocabularyPractice.load(scope);
    } catch (_) {
      // Do not upload English images without a valid difficulty preference.
    }
    if (!mounted) return;
    if (!requestedJapanese && profile == null) {
      unavailable('请先在识图按钮旁选择英语识图等级。', title: '请选择等级');
      return;
    }
    final approved = await confirmDeepSeekUpload(context, 1, saveResults: true);
    if (!approved || !mounted) return;
    setState(() {
      _recognizing = true;
      _detected = [];
      _singleStore = null;
      _singlePhotoId = null;
    });
    final service = DeepSeekRecognition(
      onUsage: DeepSeekUsageStore(scope).record,
      englishLevel: profile?.band.difficulty,
    );
    try {
      final root = await getApplicationDocumentsDirectory();
      final store = BatchStore(Directory('${root.path}/chenbot_batch/$scope'));
      final language = requestedJapanese ? 'ja' : 'en';
      final result = await recognizeForLearner(
        image: image,
        language: language,
        key: key,
        service: service,
        store: store,
        englishLevel: profile?.band.difficulty,
        practice: practice,
      );
      final photo = await store.addPhoto(image, language);
      await store.saveResults(photo, result.words);
      final items = (await store.visibleCards())
          .where((card) => card['photoId'] == photo['id'])
          .toList();
      if (mounted &&
          identical(image, _imageBytes) &&
          requestedJapanese == japanese &&
          localScope == scope) {
        setState(() {
          _singleStore = store;
          _singlePhotoId = photo['id'] as String;
          _detected = items;
        });
        if (result.exhausted) {
          unavailable(
            result.noMatchingWords
                ? '重新识别后，仍未找到词频表中符合当前等级或高一级的物品词。可以换张照片或调整等级。'
                : result.noVisibleObject
                ? '没有识别到清晰可命名的物品，请换一张照片或调整拍摄角度。'
                : '这张照片的物品都在垃圾桶里，重试后没有新词。可以恢复垃圾桶里的词，或换一张照片。',
            title: '暂时没有新词',
          );
        }
      }
    } on DeepSeekException catch (error) {
      if (mounted) unavailable(error.message, title: '识别未完成');
    } catch (_) {
      if (mounted) unavailable('识别失败，请检查网络和图片格式后重试。', title: '识别未完成');
    } finally {
      service.close();
      if (mounted) setState(() => _recognizing = false);
    }
  }

  Word detectedAsWord(Map<String, dynamic> w) => Word(
    w['word'] as String,
    w['word'] as String,
    w['reading'] as String,
    w['zh'] as String,
    w['en_definition'] as String,
    w['example'] as String,
    w['example'] as String,
    w['example_zh'] as String,
    Icons.label_outline,
  );

  Future<void> favoriteDetected(Map<String, dynamic> card) async {
    try {
      await _singleStore!.favorite(card);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('已收藏 ${card['word']}。')));
      }
    } catch (_) {
      if (mounted) unavailable('收藏失败，请检查本机存储。');
    }
  }

  Future<void> moveDetected(Map<String, dynamic> card, Offset position) async {
    final store = _singleStore;
    if (store == null) return;
    try {
      await store.moveLabel(card['id'] as String, position.dx, position.dy);
      if (mounted && identical(store, _singleStore)) {
        setState(() {
          card['labelX'] = position.dx;
          card['labelY'] = position.dy;
        });
      }
    } catch (_) {
      if (mounted) unavailable('无法保存单词位置，请检查本机存储。');
    }
  }

  Future<void> refreshDetected() async {
    final store = _singleStore;
    final photoId = _singlePhotoId;
    final scope = localScope;
    if (store == null) return;
    final visible = await store.visibleCards();
    EnglishLevelProfile? profile;
    try {
      profile = await EnglishLevelProfile.load(scope);
    } catch (_) {
      // Without a valid selection no English cards can be shown.
    }
    if (mounted &&
        identical(store, _singleStore) &&
        photoId == _singlePhotoId &&
        localScope == scope) {
      setState(
        () => _detected = visible
            .where(
              (card) =>
                  card['photoId'] == photoId &&
                  englishCardMatchesBand(card, profile?.band),
            )
            .toList(),
      );
    }
  }

  Future<void> discardDetected(Map<String, dynamic> card) async {
    final store = _singleStore;
    if (store == null) return;
    try {
      await store.discard(card['id'] as String);
      await refreshDetected();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已将 ${card['word']} 和已识别的词形放入垃圾桶。'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () async {
              try {
                await store.restoreMatching(card);
                await refreshDetected();
              } catch (_) {
                if (mounted) unavailable('恢复失败，请检查本机存储。');
              }
            },
          ),
        ),
      );
    } catch (_) {
      if (mounted) unavailable('放入垃圾桶失败，请检查本机存储。');
    }
  }

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
        _singleStore = null;
        _singlePhotoId = null;
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
    refreshDeepSeekSettings();
  }

  Future<void> refreshDeepSeekSettings() async {
    try {
      final present = await DeepSeekKeyStore(localScope).hasKey();
      if (mounted) setState(() => _deepSeekConfigured = present);
    } catch (_) {
      if (mounted) setState(() => _deepSeekConfigured = false);
    }
  }

  Future<void> openDeepSeekSettings() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => DeepSeekSettingsPage(scope: localScope),
      ),
    );
    if (mounted) await refreshDeepSeekSettings();
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
      _singleStore = null;
      _singlePhotoId = null;
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

  Future<void> openTrash() async {
    try {
      final root = await getApplicationDocumentsDirectory();
      if (!mounted) return;
      final store = BatchStore(
        Directory('${root.path}/chenbot_batch/$localScope'),
      );
      await Navigator.push<void>(
        context,
        MaterialPageRoute(builder: (_) => LocalTrashPage(store: store)),
      );
      await refreshDetected();
    } catch (_) {
      if (mounted) unavailable('无法读取单词垃圾桶。');
    }
  }

  Future<void> openAssessment({bool forJapanese = false}) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => forJapanese
            ? const AssessmentPreview(japanese: true)
            : EnglishLevelPage(scope: localScope),
      ),
    );
    if (mounted) setState(() => _levelVersion++);
  }

  Future<void> login() async {
    if (!authConfigured) {
      unavailable('邮箱登录服务尚未配置，请稍后再试。');
      return;
    }
    await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => const AuthPage()));
    if (mounted) {
      setState(() {
        _detected = [];
        _singleStore = null;
        _singlePhotoId = null;
        _levelVersion++;
      });
      await refreshDeepSeekSettings();
    }
  }

  Future<void> signOut() async {
    try {
      await Supabase.instance.client.auth.signOut();
      if (mounted) {
        setState(() {
          _detected = [];
          _singleStore = null;
          _singlePhotoId = null;
          _levelVersion++;
        });
        await refreshDeepSeekSettings();
      }
    } catch (_) {
      if (mounted) unavailable('退出登录失败，请稍后重试。');
    }
  }

  void unavailable(String text, {String title = '功能准备中'}) =>
      showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
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
  void detail(
    Word w, {
    bool canSave = true,
    bool isSample = true,
  }) => showModalBottomSheet<void>(
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
                          japanese
                              ? w.reading
                              : isSample
                              ? '英语 · 示例单词'
                              : '英语 · AI 识图',
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
              Text(
                isSample ? '示例内容，仅用于展示界面' : 'AI 生成内容，仅供学习参考',
                style: const TextStyle(fontSize: 12, color: Color(0xff849086)),
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
      child: IndexedStack(
        index: tab,
        children: [home(), library(), const ReaderShelf(), account()],
      ),
    ),
    floatingActionButton: tab == 0 && _detected.isNotEmpty
        ? Material(
            elevation: 5,
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            child: TrashDropTarget(onDiscard: discardDetected),
          )
        : null,
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
          icon: Icon(Icons.menu_book_outlined),
          selectedIcon: Icon(Icons.menu_book),
          label: '阅读',
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
          ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: Image.asset(
              'assets/branding/home_icon.png',
              width: 42,
              height: 42,
              cacheWidth: 180,
              fit: BoxFit.cover,
              excludeFromSemantics: true,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'chenbot',
            style: TextStyle(
              fontFamily: Theme.of(context).platform == TargetPlatform.android
                  ? 'sans-serif'
                  : Typography.material2021(
                      platform: Theme.of(context).platform,
                    ).black.bodyMedium?.fontFamily,
              fontFamilyFallback: const [],
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
        VocabularyPhotoCanvas(
          image: Image.memory(_imageBytes!, fit: BoxFit.fill),
          aspectRatio: _imageRatio,
          cards: _detected,
          onFavorite: favoriteDetected,
          onPositionChanged: moveDetected,
        ),
        const SizedBox(height: 10),
        Text(
          _deepSeekConfigured
              ? '识别前会确认发送照片至 DeepSeek，调用可能产生费用。'
              : '照片仅在本机预览；设置自己的 DeepSeek API Key 后可识图。',
          style: const TextStyle(color: Color(0xff738279)),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            if (!japanese) ...[
              Expanded(
                child: IgnorePointer(
                  ignoring: _recognizing,
                  child: EnglishDifficultySelector(
                    key: ValueKey('single-$localScope-$_levelVersion'),
                    scope: localScope,
                    onChanged: (_) => refreshDetected(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            FilledButton.tonal(
              onPressed: _recognizing
                  ? null
                  : (_deepSeekConfigured ? recognize : openDeepSeekSettings),
              child: Text(
                _recognizing
                    ? '识别中…'
                    : _deepSeekConfigured
                    ? '识别照片'
                    : '设置 API Key',
              ),
            ),
          ],
        ),
        if (_detected.isNotEmpty) ...[
          const SizedBox(height: 8),
          const Text(
            '点图片上的词收藏，拖动可调整位置或放入垃圾桶。',
            style: TextStyle(color: Color(0xff738279)),
          ),
          const SizedBox(height: 8),
          for (final item in _detected)
            ListTile(
              title: Align(
                alignment: Alignment.centerLeft,
                child: VocabularyTag(
                  card: item,
                  onFavorite: () => favoriteDetected(item),
                ),
              ),
              subtitle: Text(item['zh'] as String),
              onTap: () =>
                  detail(detectedAsWord(item), canSave: false, isSample: false),
              trailing: Wrap(
                spacing: 0,
                children: [
                  IconButton(
                    onPressed: () => favoriteDetected(item),
                    icon: const Icon(Icons.bookmark_add_outlined),
                    tooltip: '收藏单词',
                  ),
                  IconButton(
                    onPressed: () => discardDetected(item),
                    icon: const Icon(Icons.delete_outline),
                    tooltip: '放入垃圾桶',
                  ),
                ],
              ),
            ),
        ],
      ],
      const SizedBox(height: 16),
      Card(
        child: ListTile(
          leading: const Icon(Icons.collections_outlined),
          title: const Text('批量照片识词'),
          subtitle: const Text('多张照片 · 本机卡片与收藏'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    BatchPage(japanese: japanese, storageScope: localScope),
              ),
            );
            await refreshDetected();
            if (mounted) setState(() => _levelVersion++);
          },
        ),
      ),
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
      const SizedBox(height: 20),
      Card(
        child: ListTile(
          leading: const Icon(Icons.bookmark_outline),
          title: const Text('识词收藏'),
          subtitle: const Text('查看单独保存的词条'),
          trailing: const Icon(Icons.chevron_right),
          onTap: openBatchFavorites,
        ),
      ),
      Card(
        child: ListTile(
          leading: const Icon(Icons.delete_outline),
          title: const Text('单词垃圾桶'),
          subtitle: const Text('查看已过滤词形，恢复误丢的单词'),
          trailing: const Icon(Icons.chevron_right),
          onTap: openTrash,
        ),
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
                '账号登录和同步服务尚未接入。',
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
        child: ListTile(
          leading: const Icon(Icons.key_outlined),
          title: const Text('DeepSeek 识图设置'),
          subtitle: Text(
            _deepSeekConfigured ? '已在本机保存 API Key' : '使用自己的 API Key 识图',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: openDeepSeekSettings,
        ),
      ),
      const SizedBox(height: 16),
      Card(
        child: ListTile(
          leading: const Icon(Icons.school_outlined),
          title: const Text('英语水平测试'),
          trailing: const Icon(Icons.chevron_right),
          onTap: openAssessment,
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
              onTap: () => unavailable(
                'Chenbot 额度和充值尚未开放；使用自己的 API Key 识图可能产生 DeepSeek 费用。',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('隐私与数据'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => unavailable('正式版本将说明照片处理、保存期限和账号删除方式。'),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('词频数据与开源许可'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () =>
                  showLicensePage(context: context, applicationName: 'Chenbot'),
            ),
          ],
        ),
      ),
    ],
  );
}
