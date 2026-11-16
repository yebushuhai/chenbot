import 'package:flutter/material.dart';

class _Question {
  const _Question(this.word, this.options, this.answer);
  final String word;
  final List<String> options;
  final int answer;
}

const _english = [
  _Question('cat', ['猫', '狗', '鸟', '鱼'], 0),
  _Question('borrow', ['借入', '归还', '出售', '选择'], 0),
  _Question('hesitate', ['犹豫', '庆祝', '隐藏', '加速'], 0),
  _Question('mitigate', ['缓解', '重复', '观察', '预订'], 0),
  _Question('ephemeral', ['短暂的', '可靠的', '昂贵的', '安静的'], 0),
];
const _japanese = [
  _Question('猫（ねこ）', ['猫', '狗', '鸟', '鱼'], 0),
  _Question('借りる（かりる）', ['借入', '归还', '出售', '选择'], 0),
  _Question('迷う（まよう）', ['犹豫、迷路', '庆祝', '隐藏', '加速'], 0),
  _Question('和らげる（やわらげる）', ['缓和', '重复', '观察', '预订'], 0),
  _Question('儚い（はかない）', ['短暂的、虚幻的', '可靠的', '昂贵的', '安静的'], 0),
];

/// Interaction prototype only. Items have not been calibrated and cannot
/// determine an actual vocabulary range or JLPT proficiency.
class AssessmentPreview extends StatefulWidget {
  const AssessmentPreview({super.key, required this.japanese});
  final bool japanese;
  @override
  State<AssessmentPreview> createState() => _AssessmentPreviewState();
}

class _AssessmentPreviewState extends State<AssessmentPreview> {
  late final List<_Question> questions;
  late List<int> options;
  int index = 0, correct = 0;
  bool done = false;
  @override
  void initState() {
    super.initState();
    questions = widget.japanese ? _japanese : _english;
    _shuffle();
  }

  void _shuffle() {
    options = [0, 1, 2, 3]..shuffle();
  }

  void answer(int? selected) {
    if (selected == questions[index].answer) correct++;
    setState(() {
      if (index + 1 == questions.length) {
        done = true;
      } else {
        index++;
        _shuffle();
      }
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('水平测试体验')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (done) ...[
            const SizedBox(height: 24),
            const Icon(Icons.auto_awesome, size: 56),
            const SizedBox(height: 20),
            Text('体验完成', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 12),
            Text('示例答对 $correct / ${questions.length} 题。'),
            const SizedBox(height: 16),
            const Text(
              '这几道示例题尚未经过标定，不能测算词汇量、分级或 JLPT 水平。正式评测需要更完整的题库。',
              style: TextStyle(height: 1.6),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ] else ...[
            Text(
              '体验题 ${index + 1} / ${questions.length}',
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: index / questions.length),
            const SizedBox(height: 24),
            const Text(
              '仅为交互演示，不会给出真实水平或词汇量。',
              style: TextStyle(color: Colors.blueGrey, height: 1.5),
            ),
            const SizedBox(height: 36),
            const Text('这个词是什么意思？'),
            const SizedBox(height: 12),
            Text(
              questions[index].word,
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
                  child: Text(questions[index].options[option]),
                ),
              ),
            TextButton(onPressed: () => answer(null), child: const Text('不认识')),
          ],
        ],
      ),
    ),
  );
}
