import 'package:flutter/material.dart';

import 'deepseek_account.dart';
import 'deepseek_recognition.dart';

Future<bool> confirmDeepSeekUpload(
  BuildContext context,
  int count, {
  bool saveResults = true,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('发送照片到 DeepSeek？'),
      content: SingleChildScrollView(
        child: Text(
          '将从这台设备把 $count 张照片逐张发送到 DeepSeek 进行识别。'
          '请求会消耗你自己的 DeepSeek API 账户额度，可能产生费用。'
          '如果结果都在垃圾桶，或者没有符合英语等级且收录于本地词频表的词，可能自动重试。'
          '每张照片最多发送 3 次，本次合计最多 ${count * 3} 次，每次都可能计费。'
          '重试会发送同一张照片、此前识别的候选词及其本地词频排名。'
          '${saveResults ? '识别结果会保存在本机。' : '识别结果会显示在当前页面。'}'
          '请确认照片内容可以分享给 DeepSeek。',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('确认发送'),
        ),
      ],
    ),
  );
  return result == true;
}

class DeepSeekSettingsPage extends StatefulWidget {
  const DeepSeekSettingsPage({
    super.key,
    required this.scope,
    this.storeOverride,
    this.accountApiOverride,
  });
  final String scope;
  final DeepSeekKeyStore? storeOverride;
  final DeepSeekAccountApi? accountApiOverride;

  @override
  State<DeepSeekSettingsPage> createState() => _DeepSeekSettingsPageState();
}

class _DeepSeekSettingsPageState extends State<DeepSeekSettingsPage> {
  late final DeepSeekKeyStore store =
      widget.storeOverride ?? DeepSeekKeyStore(widget.scope);
  late final DeepSeekAccountApi accountApi =
      widget.accountApiOverride ?? DeepSeekAccountApi();
  late final DeepSeekUsageStore usageStore = DeepSeekUsageStore(widget.scope);
  final controller = TextEditingController();
  bool configured = false, loading = true, saving = false, visible = true;
  bool balanceLoading = false;
  DeepSeekBalance? currentBalance;
  LocalTokenUsage usage = const LocalTokenUsage();
  String? balanceError;
  int balanceRequest = 0;
  String? error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final key = await store.read();
      final localUsage = await usageStore.read();
      if (mounted) {
        controller.text = key ?? '';
        setState(() {
          configured = key?.isNotEmpty ?? false;
          usage = localUsage;
          loading = false;
          error = null;
        });
        if (configured) refreshBalance();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '无法读取设备安全存储，请检查设备设置后重试。';
        });
      }
    }
  }

  @override
  void dispose() {
    balanceRequest++;
    if (widget.accountApiOverride == null) accountApi.close();
    controller.dispose();
    super.dispose();
  }

  Future<void> refreshBalance() async {
    final requestId = ++balanceRequest;
    try {
      final key = await store.read();
      if (!mounted ||
          requestId != balanceRequest ||
          key == null ||
          key.isEmpty) {
        return;
      }
      setState(() {
        balanceLoading = true;
        balanceError = null;
      });
      final value = await accountApi.balance(key);
      if (!mounted || requestId != balanceRequest) return;
      setState(() {
        currentBalance = value;
        balanceLoading = false;
      });
    } on DeepSeekAccountException catch (e) {
      if (mounted && requestId == balanceRequest) {
        setState(() {
          currentBalance = null;
          balanceLoading = false;
          balanceError = e.message;
        });
      }
    } catch (_) {
      if (mounted && requestId == balanceRequest) {
        setState(() {
          currentBalance = null;
          balanceLoading = false;
          balanceError = '无法读取本机设置。';
        });
      }
    }
  }

  Future<void> refreshUsage() async {
    try {
      final latest = await usageStore.read();
      if (mounted) setState(() => usage = latest);
    } catch (_) {
      if (mounted) setState(() => error = '无法读取本机用量。');
    }
  }

  Future<void> save() async {
    if (saving) return;
    final candidate = controller.text.trim();
    if (candidate.isEmpty ||
        candidate.length > 512 ||
        RegExp(r'\s').hasMatch(candidate)) {
      setState(() => error = '请输入完整的 API Key，不能包含空格或换行。');
      return;
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await store.save(candidate);
      if (await store.read() != candidate) {
        throw StateError('Secure storage write failed');
      }
      if (!mounted) return;
      controller.text = candidate;
      setState(() {
        configured = true;
        saving = false;
        visible = true;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('密钥已保存到本机，正在查询账户余额。')));
      refreshBalance();
      refreshUsage();
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '保存失败，请检查设备安全存储后重试。';
        });
      }
    }
  }

  Future<void> remove() async {
    if (saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除本机密钥？'),
        content: const Text('删除后需要重新输入才能使用识图；DeepSeek 账户上的密钥不会被注销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    balanceRequest++;
    setState(() {
      saving = true;
      balanceLoading = false;
      error = null;
    });
    try {
      await store.delete();
      if (!mounted) return;
      controller.clear();
      setState(() {
        configured = false;
        saving = false;
        currentBalance = null;
        balanceError = null;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '删除失败，请重试。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('DeepSeek 识图设置')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            loading
                ? '正在读取设置…'
                : configured
                ? '已在本机保存 API Key'
                : '尚未设置 API Key',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          const Text(
            '使用你自己 DeepSeek API 账户的密钥。密钥保存在此设备的安全存储中，不会上传到 Chenbot 服务器；识图请求会直接发送给 DeepSeek，并可能产生费用。',
          ),
          const SizedBox(height: 12),
          const Text('密钥按本机当前用户分别保存，换设备需重新输入。此页会显示完整密钥，请勿公开截图。'),
          const SizedBox(height: 24),
          const Text(
            'DeepSeek API Key',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: TextField(
              controller: controller,
              obscureText: !visible,
              autocorrect: false,
              enableSuggestions: false,
              autofillHints: const [],
              keyboardType: TextInputType.visiblePassword,
              maxLines: 1,
              enabled: !saving && !loading,
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xffd9d9d9),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 20,
                ),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => visible = !visible),
                  tooltip: visible ? '隐藏密钥' : '显示输入的密钥',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 64,
                    height: 64,
                  ),
                  icon: ClipRect(
                    child: Transform.scale(
                      // The bananas occupy slightly different proportions in
                      // the two source images; compensate so they appear equal.
                      scale: visible ? 1.45 : 1.52,
                      child: Image.asset(
                        visible
                            ? 'assets/branding/banana_visible.png'
                            : 'assets/branding/banana_hidden.png',
                        width: 64,
                        height: 64,
                        cacheWidth: 400,
                        fit: BoxFit.cover,
                        excludeFromSemantics: true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '请从 DeepSeek API 平台获取密钥；保存后会查询账户余额。',
            style: TextStyle(color: Colors.blueGrey),
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error!, style: const TextStyle(color: Colors.red)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: saving || loading ? null : save,
            child: Text(saving ? '正在保存…' : '保存到本机'),
          ),
          if (configured)
            TextButton(
              onPressed: saving ? null : remove,
              child: const Text('删除本机密钥'),
            ),
          const SizedBox(height: 24),
          Text('DeepSeek 账户余额', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (!configured)
            const Text('保存密钥后可以查询余额。')
          else if (balanceLoading)
            const Text('正在查询余额…')
          else if (balanceError != null)
            Text(balanceError!, style: const TextStyle(color: Colors.red))
          else if (currentBalance != null) ...[
            if (currentBalance!.entries.isEmpty)
              const Text('DeepSeek 未返回余额明细。'),
            for (final entry in currentBalance!.entries)
              Text(
                '${entry.currency} ${entry.total}（赠金 ${entry.granted}，充值余额 ${entry.toppedUp}）',
              ),
            if (!currentBalance!.available) const Text('账户当前余额不足以调用 API。'),
          ],
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: configured && !balanceLoading ? refreshBalance : null,
              icon: const Icon(Icons.refresh),
              label: const Text('刷新余额'),
            ),
          ),
          const SizedBox(height: 16),
          Text('本机已记录的用量', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            '请求 ${usage.requests} 次 · 输入 ${usage.input} tokens · 输出 ${usage.output} tokens',
          ),
          const SizedBox(height: 8),
          const Text(
            '仅统计此功能启用后，本机当前用户收到用量信息的请求；包含更换密钥后的调用，不包含其他设备或未返回用量的请求。账户累计消费金额请以 DeepSeek 控制台为准。',
            style: TextStyle(color: Colors.blueGrey, height: 1.5),
          ),
          const SizedBox(height: 6),
          const SelectableText('platform.deepseek.com/usage'),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: refreshUsage,
              child: const Text('刷新本机用量'),
            ),
          ),
        ],
      ),
    ),
  );
}
