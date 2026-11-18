import 'package:flutter/material.dart';

/// All scheduling inputs are Shanghai wall-clock time, including for travellers.
DateTime shanghaiWallTime(DateTime instant) =>
    instant.toUtc().add(const Duration(hours: 8));

String formatShanghai(DateTime instant) {
  final local = shanghaiWallTime(instant);
  String pad(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${pad(local.month)}-${pad(local.day)} ${pad(local.hour)}:${pad(local.minute)}';
}

class EncounterForm extends StatefulWidget {
  const EncounterForm({super.key, required this.busy, required this.onJoin});

  final bool busy;
  final void Function(Map<String, dynamic>) onJoin;

  @override
  State<EncounterForm> createState() => _EncounterFormState();
}

class _EncounterFormState extends State<EncounterForm> {
  late DateTime day;
  var start = const TimeOfDay(hour: 14, minute: 0);
  var end = const TimeOfDay(hour: 16, minute: 0);
  var area = '静安';
  var distance = 5;
  var preference = 'any';
  String? error;
  @override
  void initState() {
    super.initState();
    final tomorrow = shanghaiWallTime(DateTime.now())
        .add(const Duration(days: 1));
    day = DateTime(tomorrow.year, tomorrow.month, tomorrow.day);
  }

  Future<void> selectDay() async {
    final today = shanghaiWallTime(DateTime.now());
    final first = DateTime(today.year, today.month, today.day);
    final selected = await showDatePicker(
      context: context,
      initialDate: day.isBefore(first) ? first : day,
      firstDate: first,
      lastDate: first.add(const Duration(days: 30)),
    );
    if (selected != null && mounted) setState(() => day = selected);
  }

  Future<void> selectTime(bool isStart) async {
    final selected = await showTimePicker(
      context: context,
      initialTime: isStart ? start : end,
    );
    if (selected != null && mounted) {
      setState(() {
        if (isStart) {
          start = selected;
        } else {
          end = selected;
        }
      });
    }
  }

  DateTime instant(TimeOfDay t) => DateTime.utc(
    day.year,
    day.month,
    day.day,
    t.hour,
    t.minute,
  ).subtract(const Duration(hours: 8));
  void submit() {
    final from = instant(start), to = instant(end);
    final now = DateTime.now().toUtc();
    final duration = to.difference(from);
    if (from.isBefore(now.add(const Duration(minutes: 20))) ||
        to.isAfter(now.add(const Duration(days: 30))) ||
        duration < const Duration(hours: 1) ||
        duration > const Duration(hours: 8)) {
      setState(() => error = '请选择未来 20 分钟至 30 天内、同一天里 1–8 小时的空闲时段。');
      return;
    }
    setState(() => error = null);
    widget.onJoin({
      'p_area': area,
      'p_start': from.toIso8601String(),
      'p_end': to.toIso8601String(),
      'p_distance': distance,
      'p_preference': preference,
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '上海 · 公共场所',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text('只提交大致区域。双方接受提议后，才能看到一小时见面的具体时间和地点。'),
        const SizedBox(height: 20),
        DropdownButtonFormField<String>(
          initialValue: area,
          decoration: const InputDecoration(labelText: '出发区域'),
          items: [
            '静安',
            '徐汇',
            '黄浦',
            '长宁',
            '浦东',
          ].map((a) => DropdownMenuItem(value: a, child: Text(a))).toList(),
          onChanged: widget.busy ? null : (v) => setState(() => area = v!),
        ),
        Text(
          '区域参考点 · ${const {'静安': '静安寺', '徐汇': '徐家汇', '黄浦': '人民广场', '长宁': '中山公园', '浦东': '世纪大道地铁站'}[area]}',
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('见面日期（上海时间）'),
          subtitle: Text('${day.year}-${day.month}-${day.day}'),
          trailing: const Icon(Icons.calendar_today_outlined),
          onTap: widget.busy ? null : selectDay,
        ),
        Wrap(
          spacing: 10,
          children: [
            OutlinedButton(
              onPressed: widget.busy ? null : () => selectTime(true),
              child: Text('从 ${start.format(context)}'),
            ),
            OutlinedButton(
              onPressed: widget.busy ? null : () => selectTime(false),
              child: Text('至 ${end.format(context)}'),
            ),
          ],
        ),
        DropdownButtonFormField<int>(
          initialValue: distance,
          decoration: const InputDecoration(labelText: '最大直线距离（从区域参考点出发）'),
          items: [1, 3, 5, 10, 20, 30, 50]
              .map((v) => DropdownMenuItem(value: v, child: Text('$v 公里')))
              .toList(),
          onChanged: widget.busy ? null : (v) => setState(() => distance = v!),
        ),
        DropdownButtonFormField<String>(
          initialValue: preference,
          decoration: const InputDecoration(labelText: '场所氛围偏好（仅用于匹配）'),
          items: const [
            DropdownMenuItem(value: 'any', child: Text('都可以')),
            DropdownMenuItem(value: 'quiet', child: Text('安静')),
            DropdownMenuItem(value: 'lively', child: Text('热闹')),
          ],
          onChanged: widget.busy
              ? null
              : (v) => setState(() => preference = v!),
        ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: widget.busy ? null : submit,
          icon: const Icon(Icons.shuffle),
          label: const Text('自愿参加随机见面'),
        ),
      ],
    );
  }
}
