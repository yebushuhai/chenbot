import 'dart:math';

import 'package:flutter/material.dart';

import 'english_level.dart';
import 'vocabulary.dart';

class EnglishLevelPage extends StatelessWidget {
  const EnglishLevelPage({super.key, required this.scope});
  final String scope;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('英语水平测试')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text('共12道自适应难度选择题'),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => AdaptiveEnglishTestPage(scope: scope),
              ),
            ),
            icon: const Icon(Icons.quiz_outlined),
            label: const Text('开始测试'),
          ),
        ],
      ),
    ),
  );
}

class AdaptiveEnglishTestPage extends StatefulWidget {
  const AdaptiveEnglishTestPage({super.key, this.scope = 'guest'});
  final String scope;
  @override
  State<AdaptiveEnglishTestPage> createState() =>
      _AdaptiveEnglishTestPageState();
}

class _AdaptiveEnglishTestPageState extends State<AdaptiveEnglishTestPage> {
  late AdaptiveEnglishSession session;
  late List<String> options;
  final random = Random();
  EnglishQuestion? answeredQuestion;
  String? selectedAnswer;
  String? saveProblem;

  @override
  void initState() {
    super.initState();
    restart();
  }

  void restart() {
    session = AdaptiveEnglishSession();
    answeredQuestion = null;
    selectedAnswer = null;
    saveProblem = null;
    prepare();
  }

  void prepare() {
    final question = session.next();
    options = [question.meaning, ...question.distractors]..shuffle(random);
  }

  void answer(String? choice) {
    if (answeredQuestion != null) return;
    final question = session.current!;
    setState(() {
      answeredQuestion = question;
      selectedAnswer = choice;
      session.answer(choice == question.meaning, unsure: choice == null);
    });
  }

  Future<void> nextQuestion() async {
    if (answeredQuestion == null) return;
    if (session.finished) {
      try {
        await VocabularyPractice.record(widget.scope, {
          for (final answer in session.answers)
            answer.question.word: answer.correct,
        });
      } catch (_) {
        saveProblem = '练习记录未能保存；可检查本机存储后重试。';
      }
      final recommended = session.result.recommended;
      if (recommended != null) {
        try {
          await EnglishLevelProfile(recommended).save(widget.scope);
        } catch (_) {
          saveProblem = '等级未能保存；可在识图按钮旁重新选择。';
        }
      }
      if (!mounted) return;
    }
    setState(() {
      answeredQuestion = null;
      selectedAnswer = null;
      if (!session.finished) prepare();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('英语水平测试')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (session.finished && answeredQuestion == null) ...[
            const SizedBox(height: 20),
            const Icon(Icons.auto_awesome, size: 52),
            const SizedBox(height: 16),
            Text('测试完成', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 12),
            Text(
              '答对 ${session.correct} / ${AdaptiveEnglishSession.questionCount} 题',
            ),
            if (saveProblem != null) Text(saveProblem!),
            const SizedBox(height: 16),
            Text(
              session.result.recommended == null
                  ? '暂不能确定单一等级'
                  : '初步推荐：${session.result.recommended!.label}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              '参考范围（未标定）：${session.result.lower.label}–${session.result.upper.label}',
            ),
            if (session.result.frequencyMismatch) ...[
              const SizedBox(height: 8),
              const Text('部分回答与字幕词频排序差异较大，暂无法缩小范围。'),
            ],
            const SizedBox(height: 12),
            for (final band in chenbotBands.reversed)
              Card(
                color:
                    !session.result.frequencyMismatch &&
                        chenbotBands.indexOf(band) >=
                            chenbotBands.indexOf(session.result.lower) &&
                        chenbotBands.indexOf(band) <=
                            chenbotBands.indexOf(session.result.upper)
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
                child: ListTile(
                  leading: band.id == session.result.recommended?.id
                      ? const Icon(Icons.star)
                      : const SizedBox(width: 24),
                  title: Text(band.label),
                  subtitle: Text(band.reference),
                  trailing: band.id == session.result.recommended?.id
                      ? const Text('当前推荐')
                      : null,
                ),
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('返回'),
            ),
            TextButton(
              onPressed: () => setState(restart),
              child: const Text('重新测试'),
            ),
          ] else if (answeredQuestion != null) ...[
            Text(
              '第 ${session.asked.length} / ${AdaptiveEnglishSession.questionCount} 题',
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value:
                  session.asked.length / AdaptiveEnglishSession.questionCount,
            ),
            const SizedBox(height: 28),
            Text(
              answeredQuestion!.word,
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 20),
            Text(
              selectedAnswer == null
                  ? '已选择不认识'
                  : selectedAnswer == answeredQuestion!.meaning
                  ? '回答正确'
                  : '回答错误',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: selectedAnswer == answeredQuestion!.meaning
                    ? Colors.green.shade700
                    : Colors.red.shade700,
              ),
            ),
            const SizedBox(height: 12),
            if (selectedAnswer != null &&
                selectedAnswer != answeredQuestion!.meaning)
              Text('你的选择：$selectedAnswer'),
            const SizedBox(height: 8),
            Text(
              '正确答案：${answeredQuestion!.meaning}',
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: nextQuestion,
              child: Text(session.finished ? '查看结果' : '下一题'),
            ),
          ] else ...[
            Text(
              '第 ${session.asked.length + 1} / ${AdaptiveEnglishSession.questionCount} 题',
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value:
                  session.asked.length / AdaptiveEnglishSession.questionCount,
            ),
            const SizedBox(height: 32),
            const Text('这个词是什么意思？'),
            const SizedBox(height: 12),
            Text(
              session.current!.word,
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 24),
            for (final option in options)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: OutlinedButton(
                  onPressed: () => answer(option),
                  style: OutlinedButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.all(16),
                  ),
                  child: Text(option),
                ),
              ),
            TextButton(onPressed: () => answer(null), child: const Text('不认识')),
          ],
        ],
      ),
    ),
  );
}

/// The selected level is a local preference used by the next recognition request.
class EnglishDifficultySelector extends StatefulWidget {
  const EnglishDifficultySelector({
    super.key,
    required this.scope,
    this.onChanged,
  });
  final String scope;
  final ValueChanged<EnglishBand>? onChanged;
  @override
  State<EnglishDifficultySelector> createState() =>
      _EnglishDifficultySelectorState();
}

class _EnglishDifficultySelectorState extends State<EnglishDifficultySelector> {
  EnglishBand? selected;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant EnglishDifficultySelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) load();
  }

  Future<void> load() async {
    try {
      final profile = await EnglishLevelProfile.load(widget.scope);
      if (mounted) {
        setState(() {
          selected = profile?.band;
          loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> save(EnglishBand? band) async {
    if (band == null) return;
    try {
      await EnglishLevelProfile(band).save(widget.scope);
      if (mounted) {
        setState(() => selected = band);
        widget.onChanged?.call(band);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('保存识图等级失败，请重试。')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        '英语识图等级',
        style: TextStyle(fontSize: 12, color: Colors.blueGrey),
      ),
      Row(
        children: [
          Expanded(
            child: DropdownButton<EnglishBand>(
              isExpanded: true,
              value: selected,
              hint: Text(loading ? '读取中…' : '选择等级'),
              items: [
                for (final band in chenbotBands.reversed)
                  DropdownMenuItem(value: band, child: Text(band.label)),
              ],
              onChanged: loading ? null : save,
            ),
          ),
        ],
      ),
    ],
  );
}
