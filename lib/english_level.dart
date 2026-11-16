import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'adaptive.dart';
import 'english_frequency_data.dart';

class EnglishBand {
  const EnglishBand(
    this.id,
    this.label,
    this.reference,
    this.difficulty,
    this.lowerBound,
  );
  final String id, label, reference;
  final Level difficulty;
  final int lowerBound;
}

/// Product-defined ranges, not calibrated vocabulary estimates.
const chenbotBands = <EnglishBand>[
  EnglishBand('h', '文盲', '0–1,999 词', Level.h, 0),
  EnglishBand('f', '菜鸡', '2,000–7,999 词', Level.f, 2000),
  EnglishBand('d', '青铜', '8,000–14,999 词', Level.d, 8000),
  EnglishBand('c', '白银', '15,000–19,999 词', Level.c, 15000),
  EnglishBand('b', '黄金', '20,000–29,999 词', Level.b, 20000),
  EnglishBand('a', '钻石', '30,000–49,999 词', Level.a, 30000),
  EnglishBand('s', '莎士比亚', '50,000 词及以上', Level.s, 50000),
];

/// A provisional user-requested mapping, not a validated measure of difficulty.
const englishFrequencyRankScale = 5;

EnglishBand? englishBandForSubtitleRank(int? rank) {
  if (rank == null || rank < 1) return null;
  var index = 0;
  for (var i = 1; i < chenbotBands.length; i++) {
    if (rank >= chenbotBands[i].lowerBound * englishFrequencyRankScale) {
      index = i;
    }
  }
  return chenbotBands[index];
}

EnglishBand? englishBandForDifficulty(Level? level) {
  if (level == null) return null;
  // Removed grades are merged into 菜鸡 for existing saved selections.
  final normalized = level == Level.g || level == Level.e ? Level.f : level;
  for (final band in chenbotBands) {
    if (band.difficulty == normalized) return band;
  }
  return null;
}

bool englishBandAllowed(EnglishBand wordBand, EnglishBand selected) {
  final wordIndex = chenbotBands.indexOf(wordBand);
  final selectedIndex = chenbotBands.indexOf(selected);
  return selectedIndex >= 0 &&
      wordIndex >= selectedIndex &&
      wordIndex <= min(selectedIndex + 1, chenbotBands.length - 1);
}

/// Used for previously saved visible cards; their underlying data is untouched.
bool englishCardMatchesBand(Map<String, dynamic> card, EnglishBand? selected) {
  if (card['language'] != 'en') return true;
  final rank = card['frequencyRank'];
  final band = englishBandForSubtitleRank(rank is int ? rank : null);
  return selected != null && band != null && englishBandAllowed(band, selected);
}

class EnglishLevelProfile {
  const EnglishLevelProfile(this.band);
  final EnglishBand band;

  static String _key(String scope) => 'english_level_v4_$scope';
  static String _v3Key(String scope) => 'english_level_v3_$scope';
  static String _previousKey(String scope) => 'english_level_v2_$scope';
  static String _legacyKey(String scope) => 'english_level_v1_$scope';

  static Future<EnglishLevelProfile?> load(String scope) async {
    final prefs = await SharedPreferences.getInstance();
    final current = prefs.getString(_key(scope));
    final v3 = current == null ? prefs.getString(_v3Key(scope)) : null;
    final previous = current == null && v3 == null
        ? prefs.getString(_previousKey(scope))
        : null;
    final saved =
        current ?? v3 ?? previous ?? prefs.getString(_legacyKey(scope));
    if (saved == null) return null;
    final parts = saved.split(':');
    if (parts.length != 2) return null;
    // The retired scale has no validated mapping to vocabulary size.
    // Keep the old preference intact, but ask the user to select a new band.
    if (parts[0] != 'chenbot') return null;
    const migratedIds = {
      'h': 'h',
      'g': 'h',
      'f': 'g',
      'e': 'g',
      'd': 'f',
      'c': 'f',
      'b': 'd',
      'a': 'c',
      's': 'b',
    };
    final oldId = current != null || v3 != null
        ? parts[1]
        : previous != null
        ? (parts[1] == 'e' ? 'f' : parts[1])
        : migratedIds[parts[1]];
    final id = oldId == 'g' || oldId == 'e' ? 'f' : oldId;
    final bands = chenbotBands.where((b) => b.id == id);
    if (bands.isEmpty) return null;
    final profile = EnglishLevelProfile(bands.first);
    if (current == null) await profile.save(scope);
    return profile;
  }

  Future<void> save(String scope) async {
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_key(scope), 'chenbot:${band.id}')) {
      throw StateError('Unable to save practice level');
    }
  }
}

/// Subtitle word-form rank ranges, unrelated to the user's vocabulary-size bands.
const subtitleRankBoundaries = <int>[
  1000,
  3000,
  6000,
  10000,
  20000,
  50000,
  100000,
  200000,
];
const subtitleRankLabels = <String>[
  '前 1,000',
  '1,001–3,000',
  '3,001–6,000',
  '6,001–10,000',
  '10,001–20,000',
  '20,001–50,000',
  '50,001–100,000',
  '100,001–200,000',
  '200,001 及以后',
];

Level subtitleLevelForRank(int rank) {
  if (rank < 1) throw ArgumentError('Invalid subtitle frequency rank');
  for (var i = 0; i < subtitleRankBoundaries.length; i++) {
    if (rank <= subtitleRankBoundaries[i]) return Level.values[i];
  }
  return Level.s;
}

class EnglishQuestion {
  const EnglishQuestion(this.word, this.meaning, this.distractors);
  final String word, meaning;
  final List<String> distractors;
  int get frequencyRank =>
      englishSubtitleRanks[word] ??
      (throw StateError('Practice word has no source frequency rank'));
  Level get level => subtitleLevelForRank(frequencyRank);
}

/// Hand-written practice items. Rank is derived from subtitle word forms.
const englishQuestions = <EnglishQuestion>[
  EnglishQuestion('cat', '猫', ['狗', '鸟', '鱼']),
  EnglishQuestion('book', '书', ['桌子', '门', '杯子']),
  EnglishQuestion('water', '水', ['火', '风', '米饭']),
  EnglishQuestion('apple', '苹果', ['香蕉', '橙子', '葡萄']),
  EnglishQuestion('chair', '椅子', ['窗户', '床', '灯']),
  EnglishQuestion('mother', '母亲', ['父亲', '姐姐', '老师']),
  EnglishQuestion('happy', '快乐的', ['伤心的', '寒冷的', '沉重的']),
  EnglishQuestion('school', '学校', ['商店', '医院', '公园']),
  EnglishQuestion('bread', '面包', ['牛奶', '鸡蛋', '鱼肉']),
  EnglishQuestion('sleep', '睡觉', ['跑步', '唱歌', '游泳']),
  EnglishQuestion('market', '市场', ['医院', '车站', '学校']),
  EnglishQuestion('travel', '旅行', ['画画', '睡觉', '等待']),
  EnglishQuestion('window', '窗户', ['墙壁', '楼梯', '地板']),
  EnglishQuestion('borrow', '借入', ['归还', '出售', '选择']),
  EnglishQuestion('kitchen', '厨房', ['卧室', '花园', '车库']),
  EnglishQuestion('thirsty', '口渴的', ['饥饿的', '生气的', '疲倦的']),
  EnglishQuestion('quiet', '安静的', ['嘈杂的', '昂贵的', '危险的']),
  EnglishQuestion('carry', '携带', ['丢弃', '忘记', '拆开']),
  EnglishQuestion('usually', '通常', ['从不', '突然', '附近']),
  EnglishQuestion('careful', '小心的', ['粗心的', '拥挤的', '甜美的']),
  EnglishQuestion('improve', '改善', ['损坏', '忽略', '隐藏']),
  EnglishQuestion('nervous', '紧张的', ['宽阔的', '便宜的', '空的']),
  EnglishQuestion('afford', '负担得起', ['拖延', '拒绝', '争论']),
  EnglishQuestion('rescue', '营救', ['攻击', '抛弃', '欺骗']),
  EnglishQuestion('polite', '有礼貌的', ['无礼的', '遥远的', '古老的']),
  EnglishQuestion('suggest', '建议', ['命令', '忘记', '惩罚']),
  EnglishQuestion('remind', '提醒', ['隐藏', '打断', '允许']),
  EnglishQuestion('luggage', '行李', ['药品', '家具', '餐具']),
  EnglishQuestion('medicine', '药物', ['音乐', '运动', '工具']),
  EnglishQuestion('neighbor', '邻居', ['乘客', '老板', '队长']),
  EnglishQuestion('hesitate', '犹豫', ['庆祝', '隐藏', '加速']),
  EnglishQuestion('require', '需要', ['拒绝', '提醒', '忘记']),
  EnglishQuestion('decline', '下降；拒绝', ['增长', '帮助', '提供']),
  EnglishQuestion('persuade', '说服', ['观察', '惩罚', '称重']),
  EnglishQuestion('essential', '必不可少的', ['无关紧要的', '嘈杂的', '狭窄的']),
  EnglishQuestion('generous', '慷慨的', ['吝啬的', '虚弱的', '潮湿的']),
  EnglishQuestion('consequence', '后果', ['原因', '工具', '颜色']),
  EnglishQuestion('circumstance', '情况；环境', ['速度', '价格', '距离']),
  EnglishQuestion('efficient', '高效的', ['脆弱的', '昂贵的', '潮湿的']),
  EnglishQuestion('persistent', '坚持不懈的', ['犹豫的', '短暂的', '整洁的']),
  EnglishQuestion('reluctant', '不情愿的', ['热情的', '干净的', '宽松的']),
  EnglishQuestion('maintain', '维持', ['抛弃', '打断', '猜测']),
  EnglishQuestion('demonstrate', '展示；证明', ['掩盖', '拖延', '购买']),
  EnglishQuestion('expand', '扩大', ['缩小', '隐藏', '停止']),
  EnglishQuestion('flexible', '灵活的', ['僵硬的', '危险的', '沉重的']),
  EnglishQuestion('preserve', '保护；保存', ['破坏', '浪费', '丢弃']),
  EnglishQuestion('scarce', '稀缺的', ['可替代的', '过时的', '昂贵的']),
  EnglishQuestion('anticipate', '预料', ['遗忘', '否认', '模仿']),
  EnglishQuestion('negotiate', '协商', ['逃避', '计数', '奔跑']),
  EnglishQuestion('withstand', '承受；抵挡', ['制造', '缩短', '庆祝']),
  EnglishQuestion('mitigate', '缓解', ['评估', '阻止', '预测']),
  EnglishQuestion('coherent', '连贯的', ['模糊的', '响亮的', '仓促的']),
  EnglishQuestion('susceptible', '易受影响的', ['安全的', '固执的', '吵闹的']),
  EnglishQuestion('cultivate', '培养；耕作', ['毁坏', '逃离', '抱怨']),
  EnglishQuestion('intricate', '错综复杂的', ['简单的', '临时的', '吵闹的']),
  EnglishQuestion('advocate', '提倡；拥护', ['反对', '遗忘', '拆除']),
  EnglishQuestion('obsolete', '过时的', ['崭新的', '宽敞的', '昂贵的']),
  EnglishQuestion('tangible', '有形的；可触及的', ['模糊的', '遥远的', '响亮的']),
  EnglishQuestion('scrutinize', '仔细检查', ['草率忽略', '迅速抛弃', '随意猜测']),
  EnglishQuestion('undermine', '削弱', ['加强', '庆祝', '测量']),
  EnglishQuestion('meticulous', '一丝不苟的', ['勇敢的', '节俭的', '灵活的']),
  EnglishQuestion('ambiguous', '含糊不清的', ['确定的', '轻便的', '谦逊的']),
  EnglishQuestion('resilient', '有复原力的', ['易碎的', '沉默的', '普通的']),
  EnglishQuestion('eloquent', '雄辩的', ['多疑的', '慷慨的', '和蔼的']),
  EnglishQuestion('detrimental', '有害的', ['有益的', '优雅的', '低廉的']),
  EnglishQuestion('relentless', '不懈的；无情的', ['温和的', '迟疑的', '无关的']),
  EnglishQuestion('pervasive', '普遍存在的', ['极为罕见的', '临时借用的', '容易破碎的']),
  EnglishQuestion('plausible', '看似合理的', ['荒谬的', '透明的', '迟到的']),
  EnglishQuestion('reconcile', '使和解；调和', ['激化冲突', '宣布结束', '刻意遗漏']),
  EnglishQuestion('alleviate', '减轻', ['加重', '模仿', '复制']),
  EnglishQuestion('ephemeral', '短暂的', ['偶然的', '古老的', '平凡的']),
  EnglishQuestion('pragmatic', '务实的', ['谨慎的', '慷慨的', '固执的']),
  EnglishQuestion('ubiquitous', '无处不在的', ['极其重要的', '显而易见的', '有争议的']),
  EnglishQuestion('equivocal', '模棱两可的', ['明确无疑的', '精力充沛的', '费用低廉的']),
  EnglishQuestion('taciturn', '沉默寡言的', ['健谈的', '热闹的', '透明的']),
  EnglishQuestion('fastidious', '挑剔的；一丝不苟的', ['马虎的', '明亮的', '暂时的']),
  EnglishQuestion('capricious', '反复无常的', ['始终如一的', '高大的', '令人信服的']),
  EnglishQuestion('sagacious', '睿智的', ['愚钝的', '破旧的', '匆忙的']),
  EnglishQuestion('immutable', '不可改变的', ['多变的', '嘈杂的', '脆弱的']),
  EnglishQuestion('assiduous', '勤勉的', ['懒惰的', '模糊的', '稀少的']),
  EnglishQuestion('obdurate', '顽固的', ['灵活的', '愉快的', '贫乏的']),
  EnglishQuestion('perspicacious', '有洞察力的', ['健忘的', '犹豫的', '无礼的']),
  EnglishQuestion('enervate', '使衰弱', ['使振奋', '使整洁', '使明亮']),
  EnglishQuestion('recondite', '深奥难懂的', ['通俗易懂的', '宽敞的', '短暂的']),
  EnglishQuestion('inchoate', '初期的；尚未完善的', ['成熟完备的', '清晰透明的', '持续不断的']),
  EnglishQuestion('sesquipedalian', '爱用长词的；冗长的', ['简洁的', '无声的', '节俭的']),
  EnglishQuestion('contumacious', '顽抗命令的', ['顺从的', '机敏的', '谦虚的']),
  EnglishQuestion('mendacious', '虚假的；说谎的', ['诚实的', '有条理的', '坚固的']),
  EnglishQuestion('prevaricate', '搪塞；支吾其词', ['坦率回答', '仔细观察', '公开庆祝']),
  EnglishQuestion('pulchritudinous', '美丽的', ['丑陋的', '饥饿的', '粗糙的']),
  EnglishQuestion('umbrella', '雨伞', ['钱包', '钥匙', '背包']),
  EnglishQuestion('blanket', '毯子', ['镜子', '枕头', '围巾']),
  EnglishQuestion('pillow', '枕头', ['毛巾', '地毯', '手套']),
  EnglishQuestion('bicycle', '自行车', ['轮船', '火车', '飞机']),
  EnglishQuestion('towel', '毛巾', ['肥皂', '刷子', '枕头']),
  EnglishQuestion('scissors', '剪刀', ['汤匙', '尺子', '锤子']),
  EnglishQuestion('suitcase', '手提箱', ['雨伞', '书架', '台灯']),
  EnglishQuestion('ladder', '梯子', ['镜子', '窗帘', '地毯']),
  EnglishQuestion('flashlight', '手电筒', ['放大镜', '望远镜', '温度计']),
  EnglishQuestion('thermometer', '温度计', ['湿度计', '指南针', '秒表']),
  EnglishQuestion('compass', '指南针', ['望远镜', '放大镜', '温度计']),
  EnglishQuestion('drawer', '抽屉', ['搁板', '衣架', '书架']),
  EnglishQuestion('broom', '扫帚', ['拖把', '抹布', '簸箕']),
  EnglishQuestion('socket', '插座', ['插头', '开关', '电池']),
  EnglishQuestion('sponge', '海绵', ['毛巾', '刷子', '抹布']),
  EnglishQuestion('funnel', '漏斗', ['滤网', '勺子', '量杯']),
  EnglishQuestion('pliers', '钳子', ['剪刀', '镊子', '扳手']),
  EnglishQuestion('stroller', '婴儿推车', ['购物车', '轮椅', '婴儿摇篮']),
  EnglishQuestion('sprinkler', '洒水器', ['喷壶', '水龙头', '排水管']),
  EnglishQuestion('thermostat', '温控器', ['温度计', '加湿器', '空气净化器']),
  EnglishQuestion('tripod', '三脚架', ['自拍杆', '摄影灯', '相机包']),
  EnglishQuestion('bucket', '水桶', ['水壶', '水盆', '水槽']),
  EnglishQuestion('binder', '活页夹', ['订书机', '书签', '文件袋']),
  EnglishQuestion('wheelbarrow', '独轮手推车', ['购物车', '婴儿车', '行李箱']),
  EnglishQuestion('stethoscope', '听诊器', ['血压计', '体温计', '拐杖']),
  EnglishQuestion('saucepan', '带柄深锅', ['煎锅', '蒸锅', '烤盘']),
  EnglishQuestion('bookshelf', '书架', ['书桌', '书签', '书皮']),
  EnglishQuestion('anchor', '船锚', ['船桨', '船帆', '桅杆']),
  EnglishQuestion('lighthouse', '灯塔', ['钟楼', '桥梁', '码头']),
  EnglishQuestion('refrigerator', '冰箱', ['洗衣机', '烤箱', '微波炉']),
  EnglishQuestion('chandelier', '枝形吊灯', ['台灯', '壁灯', '手电筒']),
  EnglishQuestion('apron', '围裙', ['围巾', '手套', '帽子']),
  EnglishQuestion('cork', '软木塞', ['瓶盖', '瓶身', '瓶底']),
  EnglishQuestion('jar', '罐子', ['茶壶', '饭盒', '水壶']),
  EnglishQuestion('toothbrush', '牙刷', ['牙膏', '牙线', '梳子']),
  EnglishQuestion('hammock', '吊床', ['睡袋', '帐篷', '地毯']),
  EnglishQuestion('binoculars', '双筒望远镜', ['放大镜', '显微镜', '照相机']),
  EnglishQuestion('beaker', '烧杯', ['量筒', '试管', '广口瓶']),
  EnglishQuestion('telescope', '望远镜', ['显微镜', '放大镜', '照相机']),
  EnglishQuestion('bargain', '便宜货；划算的交易', ['罚款', '困境', '延迟']),
  EnglishQuestion('abundant', '丰富的；充裕的', ['稀少的', '模糊的', '危险的']),
  EnglishQuestion('abrupt', '突然的；唐突的', ['缓慢的', '宽阔的', '透明的']),
  EnglishQuestion('accurate', '准确的', ['错误的', '古老的', '空虚的']),
  EnglishQuestion('adequate', '足够的', ['不足的', '隐秘的', '倾斜的']),
  EnglishQuestion('adjacent', '相邻的', ['遥远的', '松散的', '平滑的']),
  EnglishQuestion('amplify', '放大；增强', ['削弱', '隐藏', '购买']),
  EnglishQuestion('arid', '干旱的', ['潮湿的', '嘈杂的', '拥挤的']),
  EnglishQuestion('assess', '评估', ['忽略', '摧毁', '逃离']),
  EnglishQuestion('benign', '温和的；良性的', ['恶意的', '短暂的', '透明的']),
  EnglishQuestion('candid', '坦率的', ['含糊其辞的', '沉重的', '潮湿的']),
  EnglishQuestion('catalyst', '催化剂', ['粘合剂', '防腐剂', '消毒剂']),
  EnglishQuestion('cumbersome', '笨重的；麻烦的', ['轻便的', '甜美的', '廉价的']),
  EnglishQuestion('dormant', '休眠的；暂时不活跃的', ['活跃的', '透明的', '急促的']),
  EnglishQuestion('eclectic', '兼收并蓄的', ['独创的', '系统化的', '不断变化的']),
  EnglishQuestion('elusive', '难以捉摸的', ['容易理解的', '可以食用的', '已经过期的']),
  EnglishQuestion('empirical', '以观察或实验为依据的', ['纯粹臆测的', '完全安静的', '特别昂贵的']),
  EnglishQuestion('erratic', '不稳定的；变化无常的', ['稳定的', '空心的', '脆弱的']),
  EnglishQuestion('explicit', '明确的；直白的', ['含糊的', '冰冷的', '狭小的']),
  EnglishQuestion('feasible', '可行的', ['临时的', '必要的', '公认的']),
  EnglishQuestion('frugal', '节俭的', ['挥霍的', '嘈杂的', '破旧的']),
  EnglishQuestion('gradual', '逐渐的', ['突然的', '坚硬的', '私人的']),
  EnglishQuestion('hypothetical', '假设的', ['确凿的', '明亮的', '危险的']),
  EnglishQuestion('impartial', '公正的；不偏不倚的', ['偏袒的', '潮湿的', '易碎的']),
  EnglishQuestion('inadvertent', '无意的；非故意的', ['故意的', '昂贵的', '平坦的']),
  EnglishQuestion('inevitable', '不可避免的', ['可以避免的', '透明的', '暂借的']),
  EnglishQuestion('ingenuity', '独创性；巧思', ['笨拙', '饥饿', '疲惫']),
  EnglishQuestion('intermittent', '间歇性的', ['持续不断的', '完全透明的', '特别昂贵的']),
  EnglishQuestion('invoke', '援引；调用', ['废弃', '遗漏', '隐藏']),
  EnglishQuestion('jeopardize', '危及', ['保护', '修理', '称重']),
  EnglishQuestion('lethargic', '无精打采的', ['精力充沛的', '洁净的', '遥远的']),
  EnglishQuestion('lucid', '清晰易懂的', ['晦涩难懂的', '拥挤不堪的', '非常寒冷的']),
  EnglishQuestion('malleable', '可塑的；易受影响的', ['难以改变的', '嘈杂的', '易燃的']),
  EnglishQuestion('mundane', '平凡的；日常的', ['不同寻常的', '可食用的', '刚出生的']),
  EnglishQuestion('novice', '新手', ['专家', '顾客', '邻居']),
  EnglishQuestion('paradox', '悖论', ['承诺', '食谱', '边界']),
  EnglishQuestion('perpetuate', '使持续；使延续', ['终止', '称赞', '搬运']),
  EnglishQuestion('precedent', '先例', ['未来的计划', '隐藏的宝物', '自然的灾害']),
  EnglishQuestion('profound', '深刻的', ['肤浅的', '潮湿的', '空旷的']),
  EnglishQuestion('prominent', '突出的；著名的', ['不起眼的', '易碎的', '临时的']),
  EnglishQuestion('rectify', '纠正', ['歪曲', '忽略', '加热']),
  EnglishQuestion('redundant', '多余的', ['必需的', '遥远的', '潮湿的']),
  EnglishQuestion('replenish', '补充', ['耗尽', '丢弃', '折叠']),
  EnglishQuestion('rigorous', '严谨的；严格的', ['马虎的', '平滑的', '甜美的']),
  EnglishQuestion('rudimentary', '基础的；初步的', ['高级完善的', '五彩缤纷的', '极其安静的']),
  EnglishQuestion('skeptical', '怀疑的', ['轻信的', '饥饿的', '整洁的']),
  EnglishQuestion('sporadic', '零星的；偶发的', ['频繁持续的', '坚固的', '可见的']),
  EnglishQuestion('stringent', '严格的', ['合理的', '灵活的', '统一的']),
  EnglishQuestion('subtle', '微妙的；不易察觉的', ['简洁的', '精确的', '生动的']),
  EnglishQuestion('tentative', '暂定的；试探性的', ['确定不变的', '空荡荡的', '容易损坏的']),
  EnglishQuestion('tranquil', '宁静的', ['喧闹的', '便宜的', '饥饿的']),
  EnglishQuestion('unilateral', '单方面的', ['双方共同的', '不规则的', '暂时的']),
  EnglishQuestion('versatile', '多才多艺的；用途广泛的', ['用途单一的', '易碎的', '透明的']),
  EnglishQuestion('vigilant', '警惕的', ['疏忽的', '空闲的', '遥远的']),
  EnglishQuestion('whimsical', '异想天开的', ['墨守成规的', '非常沉重的', '特别便宜的']),
  EnglishQuestion('diligent', '勤奋的', ['懒惰的', '潮湿的', '喧闹的']),
  EnglishQuestion('eccentric', '古怪的；与众不同的', ['平常的', '寒冷的', '结实的']),
  EnglishQuestion('futile', '徒劳的', ['有效的', '甜美的', '整洁的']),
  EnglishQuestion('intrinsic', '固有的；内在的', ['持久的', '独特的', '复杂的']),
  EnglishQuestion('pristine', '原始纯净的；完好的', ['破损污浊的', '过分拥挤的', '非常喧闹的']),
  EnglishQuestion('ambivalent', '情感或态度矛盾的', ['情绪平静的', '感受强烈的', '意见一致的']),
  EnglishQuestion('surreptitious', '秘密进行的', ['公开的', '沉重的', '易碎的']),
  EnglishQuestion('parsimonious', '过于吝啬的', ['慷慨的', '整齐的', '急促的']),
  EnglishQuestion('magnanimous', '宽宏大量的', ['心胸狭窄的', '不透光的', '非常潮湿的']),
  EnglishQuestion('obfuscate', '使模糊难懂', ['阐明', '擦亮', '保存']),
  EnglishQuestion('laconic', '简洁寡言的', ['冗长啰唆的', '色彩鲜艳的', '价格低廉的']),
  EnglishQuestion('ubiquity', '无处不在；普遍存在', ['稀少', '安静', '饥饿']),
  EnglishQuestion('idiosyncratic', '具有个人独特特点的', ['完全相同的', '临时借用的', '未经煮熟的']),
  EnglishQuestion('juxtapose', '把事物并列放置', ['分别隐藏', '彻底摧毁', '反复加热']),
  EnglishQuestion('intransigent', '不妥协的；顽固的', ['愿意让步的', '精力充沛的', '特别廉价的']),
  EnglishQuestion('cogent', '有说服力的', ['毫无根据的', '潮湿的', '狭窄的']),
  EnglishQuestion('dogmatic', '教条的；武断的', ['思想开放的', '色彩鲜艳的', '刚刚烹制的']),
  EnglishQuestion('specious', '貌似有理实则错误的', ['合理可靠的', '异常寒冷的', '非常拥挤的']),
  EnglishQuestion('myopic', '近视的；目光短浅的', ['有远见的', '极其干燥的', '非常安静的']),
  EnglishQuestion('obviate', '消除；使不再需要', ['使更有必要', '把食物煮熟', '仔细地称重']),
  EnglishQuestion('obsequious', '谄媚奉承的', ['高傲无礼的', '特别寒冷的', '价格低廉的']),
  EnglishQuestion('equivocate', '含糊其辞；支吾', ['明确表态', '公开庆祝', '匆忙离开']),
  EnglishQuestion('quixotic', '不切实际的理想主义的', ['务实可行的', '阴暗潮湿的', '价格低廉的']),
  EnglishQuestion('circumspect', '谨慎周到的', ['鲁莽的', '饥饿的', '破损的']),
  EnglishQuestion('recalcitrant', '难以管束的；不服从的', ['顺从的', '明亮的', '可食用的']),
  EnglishQuestion('abstruse', '深奥难懂的', ['浅显易懂的', '色彩鲜艳的', '突然降临的']),
  EnglishQuestion('intractable', '难以处理的；难以控制的', ['容易处理的', '十分安静的', '刚刚出生的']),
  EnglishQuestion('conflagration', '大火灾', ['洪水', '干旱', '暴风雪']),
  EnglishQuestion('acquiesce', '默许；勉强同意', ['坚决反对', '仔细计算', '高声朗读']),
  EnglishQuestion('convivial', '欢乐友好的', ['不友好的', '异常寒冷的', '特别昂贵的']),
];

class EnglishResponse {
  const EnglishResponse(this.question, this.correct, this.unsure);
  final EnglishQuestion question;
  final bool correct, unsure;
}

/// Subtitle word-form rank -> distinct word-form/lemma candidates from the
/// bundled corpus and inflection data. Unknown tokens and names are included.
/// This is a corpus crosswalk, never a count of words a person knows.
const frequencyCrosswalk = <int, int>{
  1000: 886,
  3000: 2485,
  5000: 4010,
  10000: 7782,
  20000: 15322,
  30000: 23072,
  50000: 39317,
};

double candidateUnitsForRank(double rank) {
  final points = frequencyCrosswalk.entries.toList();
  if (rank <= points.first.key) {
    return rank * points.first.value / points.first.key;
  }
  for (var i = 1; i < points.length; i++) {
    final a = points[i - 1], b = points[i];
    if (rank <= b.key) {
      return a.value + (b.value - a.value) * (rank - a.key) / (b.key - a.key);
    }
  }
  return points.last.value.toDouble();
}

EnglishBand _bandForRank(double rank) {
  final units = candidateUnitsForRank(rank);
  var index = 0;
  for (var i = 1; i < chenbotBands.length; i++) {
    if (units >= chenbotBands[i].lowerBound) index = i;
  }
  return chenbotBands[index];
}

class EnglishAssessmentResult {
  const EnglishAssessmentResult({
    required this.lower,
    required this.upper,
    required this.recommended,
    required this.frequencyMismatch,
  });
  final EnglishBand lower, upper;

  /// Null means the available evidence does not identify a single band.
  final EnglishBand? recommended;

  /// A conservative warning flag, not a calibrated person-fit statistic.
  final bool frequencyMismatch;
}

class AdaptiveEnglishSession {
  AdaptiveEnglishSession({Random? random}) : _random = random ?? Random();
  static const questionCount = 12;
  static const minRank = 500.0;
  static const maxRank = 50000.0;
  static const _gridCount = 81;
  final Random _random;
  final List<EnglishQuestion> asked = [];
  final List<EnglishResponse> answers = [];
  final List<double> _belief = List.filled(_gridCount, 1 / _gridCount);
  final List<double> _grid = List.generate(
    _gridCount,
    (i) => exp(
      log(minRank) + i * (log(maxRank) - log(minRank)) / (_gridCount - 1),
    ),
  );
  int correct = 0;
  EnglishQuestion? current;

  // Model assumptions, not calibrated item parameters or a real confidence interval.
  // 25% permits four-option guessing, and the broad logistic slope prevents
  // treating frequency rank as a deterministic indicator of word knowledge.
  double _knows(double threshold, int rank) =>
      1 /
      (1 + exp(((log(rank.toDouble()) - log(threshold)) / .85).clamp(-40, 40)));
  double _correctProbability(double threshold, int rank) =>
      .25 + .70 * _knows(threshold, rank);
  double _entropy(List<double> values) =>
      values.fold<double>(0, (sum, p) => p > 0 ? sum - p * log(p) : sum);

  double _information(int rank) {
    final chances = [
      for (final threshold in _grid) _correctProbability(threshold, rank),
    ];
    var pCorrect = 0.0;
    for (var i = 0; i < _belief.length; i++) {
      pCorrect += _belief[i] * chances[i];
    }
    final yes = List.generate(
      _belief.length,
      (i) => _belief[i] * chances[i] / pCorrect,
    );
    final no = List.generate(
      _belief.length,
      (i) => _belief[i] * (1 - chances[i]) / (1 - pCorrect),
    );
    return _entropy(_belief) -
        pCorrect * _entropy(yes) -
        (1 - pCorrect) * _entropy(no);
  }

  double _quantile(double q) {
    var cumulative = 0.0;
    for (var i = 0; i < _belief.length; i++) {
      cumulative += _belief[i];
      if (cumulative >= q) return _grid[i];
    }
    return _grid.last;
  }

  bool get finished => asked.length >= questionCount;

  EnglishAssessmentResult get result {
    if (!finished) throw StateError('Assessment is not complete');
    final lowRank = _quantile(.10), highRank = _quantile(.90);
    final right = answers.where((a) => a.correct).toList();
    final wrong = answers.where((a) => !a.correct).toList();
    final rightRanks = right.map((a) => a.question.frequencyRank).toList()
      ..sort();
    final wrongRanks = wrong.map((a) => a.question.frequencyRank).toList()
      ..sort();
    // A user may know infrequent words and miss more frequent ones. When at
    // least two answers on each side differ by a wide factor, the simple rank
    // model is a poor basis for a precise grade. This is a heuristic guard,
    // not a validated person-fit test or an assumption about the learner.
    final frequencyMismatch =
        rightRanks.length >= 2 &&
        wrongRanks.length >= 2 &&
        rightRanks[rightRanks.length - 2] >= wrongRanks[1] * 2;
    final boundary =
        right.length >= 2 &&
        wrong.length >= 2 &&
        wrong.map((a) => a.question.frequencyRank).reduce(max) >
            right.map((a) => a.question.frequencyRank).reduce(min);
    final lower = lowRank <= minRank * 1.5
        ? chenbotBands.first
        : _bandForRank(lowRank);
    // Our curated bank and corpus cannot establish an upper vocabulary limit
    // above 50k-ranked word forms. Never mistake a ceiling for mastery.
    final upper = highRank >= maxRank * .75
        ? chenbotBands.last
        : _bandForRank(highRank);
    final lowIndex = chenbotBands.indexOf(lower),
        highIndex = chenbotBands.indexOf(upper);
    final stable = boundary && !frequencyMismatch && lowIndex == highIndex;
    return EnglishAssessmentResult(
      lower: frequencyMismatch ? chenbotBands.first : lower,
      upper: frequencyMismatch ? chenbotBands.last : upper,
      recommended: stable ? _bandForRank(_quantile(.5)) : null,
      frequencyMismatch: frequencyMismatch,
    );
  }

  EnglishQuestion next() {
    if (finished || current != null) throw StateError('Question unavailable');
    final unseen = englishQuestions
        .where((q) => !asked.contains(q) && q.frequencyRank <= maxRank)
        .toList();
    if (unseen.isEmpty) throw StateError('Question bank exhausted');
    final scores = <EnglishQuestion, double>{};
    var best = double.negativeInfinity;
    for (final question in unseen) {
      final score = _information(question.frequencyRank);
      scores[question] = score;
      if (score > best) best = score;
    }
    // Randomize among near-equivalent items to avoid the same 12 words.
    final candidates = unseen.where((q) => scores[q]! >= best * .97).toList();
    return current = candidates[_random.nextInt(candidates.length)];
  }

  void answer(bool known, {bool unsure = false}) {
    final question = current;
    if (question == null || finished) throw StateError('No question');
    if (known && unsure) {
      throw ArgumentError('An unsure answer cannot be correct');
    }
    asked.add(question);
    answers.add(EnglishResponse(question, known, unsure));
    if (known) correct++;
    var total = 0.0;
    for (var i = 0; i < _belief.length; i++) {
      final chance = _correctProbability(_grid[i], question.frequencyRank);
      // Until distinct answer behaviors are calibrated, treat both an incorrect
      // choice and "don't know" as the same single incorrect observation. The
      // separate unsure flag is retained for feedback, not an extra penalty.
      final likelihood = known ? chance : 1 - chance;
      _belief[i] *= likelihood;
      total += _belief[i];
    }
    for (var i = 0; i < _belief.length; i++) {
      _belief[i] /= total;
    }
    current = null;
  }
}
