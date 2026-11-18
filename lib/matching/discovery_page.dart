import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'encounter_form.dart';
import 'secret_code.dart';

typedef MatchRpc = Future<dynamic> Function(
  String method,
  Map<String, dynamic> params,
);
typedef Json = Map<String, dynamic>;

enum _View { discover, blind, secret, connections, chat, safetyHistory }

class DiscoveryPage extends StatelessWidget {
  const DiscoveryPage({super.key, required this.client, required this.login});

  final SupabaseClient? client;
  final Future<void> Function() login;

  @override
  Widget build(BuildContext context) {
    final service = client;
    if (service == null) return _GuestLanding(login: login, configured: false);
    return StreamBuilder<AuthState>(
      stream: service.auth.onAuthStateChange,
      builder: (context, _) {
        final user = service.auth.currentUser;
        if (user == null) return _GuestLanding(login: login, configured: true);
        return MatchingWorkspace(
          key: ValueKey(user.id),
          rpc: (method, params) async {
            if (service.auth.currentUser?.id != user.id) {
              throw const AuthException('Session changed');
            }
            return await service
                .rpc(method, params: params)
                .timeout(const Duration(seconds: 18));
          },
        );
      },
    );
  }
}

class _GuestLanding extends StatelessWidget {
  const _GuestLanding({required this.login, required this.configured});
  final Future<void> Function() login;
  final bool configured;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(22),
    children: [
      const _Title('发现'),
      _Door(
        icon: Icons.directions_walk,
        title: 'Blind Encounter',
        subtitle: '匿名随机见面',
        onTap: configured ? login : null,
      ),
      _Door(
        icon: Icons.key_outlined,
        title: 'Secret Match',
        subtitle: '花样年华 · 用共同口令相认',
        onTap: configured ? login : null,
      ),
      const SizedBox(height: 12),
      Text(configured ? '验证邮箱后即可加入。你的邮箱和账号名仅自己可见。' : '交友服务尚未连接。'),
      if (configured)
        FilledButton(onPressed: login, child: const Text('邮箱验证码登录')),
    ],
  );
}

class _Title extends StatelessWidget {
  const _Title(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 18),
    child: Text(
      text,
      style: Theme.of(context).textTheme.headlineMedium
          ?.copyWith(fontWeight: FontWeight.w700),
    ),
  );
}

class _Door extends StatelessWidget {
  const _Door({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: ListTile(
      enabled: onTap != null,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    ),
  );
}

String _uuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

class MatchingWorkspace extends StatefulWidget {
  const MatchingWorkspace({super.key, required this.rpc});
  final MatchRpc rpc;
  @override
  State<MatchingWorkspace> createState() => _MatchingWorkspaceState();
}

class _MatchingWorkspaceState extends State<MatchingWorkspace>
    with WidgetsBindingObserver {
  var view = _View.discover;
  Json state = {};
  List<Json> rows = [];
  String? chatId;
  bool busy = false, loaded = false, adult = false, foreground = true;
  String? error;
  bool another = false;
  String? lastPayload, nonce;
  final code = TextEditingController();
  final draft = TextEditingController();
  Timer? poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    loadView();
    poll = Timer.periodic(const Duration(seconds: 15), (_) {
      if (foreground &&
          !busy &&
          error == null &&
          view != _View.discover &&
          (ModalRoute.of(context)?.isCurrent ?? true)) {
        loadView(silent: true);
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    foreground = lifecycle == AppLifecycleState.resumed;
    if (foreground && !busy) loadView();
  }

  @override
  void dispose() {
    poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    code.dispose();
    draft.dispose();
    super.dispose();
  }

  Future<dynamic> call(String method, [Json params = const {}]) =>
      widget.rpc(method, params);

  Future<void> readView() async {
    final selected = view;
    final result = switch (selected) {
      _View.discover => await call('matching_me'),
      _View.blind => await call('blind_state'),
      _View.secret => await call('secret_state'),
      _View.connections => await call('matching_connections'),
      _View.chat => await call('matching_messages', {'p_id': chatId}),
      _View.safetyHistory => await call('matching_safety_history'),
    };
    if (!mounted || view != selected) return;
    setState(() {
      if (selected == _View.chat ||
          selected == _View.connections ||
          selected == _View.safetyHistory) {
        rows = (result as List).map((r) => Json.from(r as Map)).toList();
      } else {
        state = Json.from(result as Map);
      }
      loaded = true;
    });
  }

  String messageFor(Object e) {
    if (e is AuthException) return '登录已过期，请重新验证邮箱。';
    if (e is PostgrestException) {
      if (e.code == '42501') return '当前账号无法访问，请刷新或重新登录。';
      if (e.code == '22023') return '所填条件无效，请检查后重试。';
      if (e.code == 'P0001') return '当前操作受限，或匹配状态已更新。请刷新后重试。';
    }
    return '暂时无法读取最新状态，请检查网络后刷新。';
  }

  Future<void> run(
    Future<void> Function() operation, {
    bool silent = false,
  }) async {
    if (busy) return;
    if (silent) {
      busy = true;
    } else {
      setState(() {
        busy = true;
        error = null;
      });
    }
    try {
      await operation();
    } catch (e) {
      if (mounted) {
        setState(() {
          state = {};
          rows = [];
          loaded = false;
          error = messageFor(e);
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> loadView({bool silent = false}) => run(readView, silent: silent);

  void open(_View next, {String? connection}) {
    if (busy) return;
    setState(() {
      view = next;
      chatId = connection;
      state = {};
      rows = [];
      error = null;
      loaded = false;
      another = false;
      code.clear();
      draft.clear();
      lastPayload = null;
      nonce = null;
    });
    loadView();
  }

  void back() => open(
    view == _View.chat || view == _View.safetyHistory
        ? _View.connections
        : _View.discover,
  );

  Json paramsWithNonce(String method, Json params) {
    final payload = jsonEncode([method, params]);
    if (payload != lastPayload || nonce == null) {
      lastPayload = payload;
      nonce = _uuid();
    }
    return {...params, 'p_nonce': nonce};
  }

  Future<void> mutate(
    String method,
    Json params, {
    bool useNonce = false,
    VoidCallback? onSuccess,
  }) {
    return run(() async {
      await call(method, useNonce ? paramsWithNonce(method, params) : params);
      if (!mounted) return;
      if (useNonce) {
        lastPayload = null;
        nonce = null;
      }
      onSuccess?.call();
      await readView();
    });
  }

  Future<bool> confirm(String title, String description, String action) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(description),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return mounted && approved == true;
  }

  Future<void> safety(String kind, String id, bool report) async {
    String reason = '';
    if (report) {
      final chosen = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: const Text('举报并屏蔽对方'),
          children: [
            for (final entry in const {
              'unsafe': '线下安全问题',
              'harassment': '骚扰',
              'impersonation': '冒充身份',
              'other': '其他',
            }.entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, entry.key),
                child: Text(entry.value),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('返回'),
            ),
          ],
        ),
      );
      if (chosen == null || !mounted) return;
      reason = chosen;
    } else if (!await confirm('屏蔽对方？', '双方将无法继续联系，也不会再次配对。', '屏蔽')) {
      return;
    }
    if (!mounted) return;
    await run(() async {
      await call('matching_safety', {
        'p_kind': kind,
        'p_id': id,
        'p_action': report ? 'report' : 'block',
        'p_reason': reason,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(report ? '举报已提交，已屏蔽对方' : '已屏蔽')));
      if (view == _View.chat) {
        setState(() {
          view = _View.connections;
          chatId = null;
          rows = [];
          draft.clear();
        });
      }
      await readView();
    });
  }

  Widget safetyButtons(String kind, String id) => Wrap(
    spacing: 8,
    children: [
      TextButton(
        onPressed: busy ? null : () => safety(kind, id, false),
        child: const Text('屏蔽对方'),
      ),
      TextButton(
        onPressed: busy ? null : () => safety(kind, id, true),
        child: const Text('安全举报'),
      ),
    ],
  );

  Widget home() {
    final enrolled = state['enrolled'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Door(
          icon: Icons.directions_walk,
          title: 'Blind Encounter',
          subtitle: '匿名随机见面',
          onTap: enrolled && !busy ? () => open(_View.blind) : null,
        ),
        _Door(
          icon: Icons.key_outlined,
          title: 'Secret Match',
          subtitle: '花样年华 · 用共同口令相认',
          onTap: enrolled && !busy ? () => open(_View.secret) : null,
        ),
        if (!enrolled) ...[
          const Text('仅限年满 18 岁的用户参加。年龄由本人声明。'),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: adult,
            onChanged: busy ? null : (v) => setState(() => adult = v ?? false),
            title: const Text('我已年满 18 岁，自愿参加匿名匹配'),
          ),
          FilledButton(
            onPressed: adult && !busy
                ? () => mutate('matching_enroll', {'p_adult': true})
                : null,
            child: const Text('开启发现'),
          ),
        ] else ...[
          ListTile(
            leading: const Icon(Icons.forum_outlined),
            title: const Text('匿名连接'),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy ? null : () => open(_View.connections),
          ),
          if (state['name'] is String) Text('账号名（仅自己可见）  ${state['name']}'),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (await confirm(
                            '删除交友资料？',
                            '匹配、连接和聊天将被移除。安全举报、屏蔽与防重复记录按保留规则处理。邮箱账号和本机学习记录会保留。',
                            '确认删除',
                          ) &&
                          mounted) {
                        await mutate(
                          'matching_delete',
                          {},
                          onSuccess: () {
                            adult = false;
                          },
                        );
                      }
                    },
              child: const Text('删除交友资料'),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> blindAction(String id, String action) async {
    if (action == 'cancel' && !await confirm('取消本次见面？', '本次参与将结束。', '取消见面')) {
      return;
    }
    if (mounted) await mutate('blind_act', {'p_id': id, 'p_action': action});
  }

  Widget blind() {
    final status = state['status'], id = state['id'] as String?;
    final ended = ['cancelled', 'expired'].contains(status);
    final starts = DateTime.tryParse(state['starts_at']?.toString() ?? '');
    if (status == 'idle' || ended || (status == 'connected' && another)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ended) Text(status == 'expired' ? '上次参与已过期。' : '上次参与已取消。'),
          if (ended && id != null && state['had_peer'] == true)
            safetyButtons('blind', id),
          EncounterForm(
            busy: busy,
            onJoin: (params) => mutate(
              'blind_join',
              params,
              useNonce: true,
              onSuccess: () {
                another = false;
              },
            ),
          ),
        ],
      );
    }
    final revealed = ['confirmed', 'completed', 'connected'].contains(status);
    final mineConfirmed = state['mine_confirmed'] == true;
    final mineCompleted = state['mine_completed'] == true;
    final mineContinue = state['mine_continue'] == true;
    if (id == null) return const Text('暂时无法读取见面状态，请刷新。');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Title(switch (status) {
          'waiting' => '等待合适的人',
          'proposed' => mineConfirmed ? '已接受，等待对方' : '收到匿名见面提议',
          'confirmed' => '双方已确认见面',
          'completed' => '已记录见面完成',
          'connected' => '已建立匿名连接',
          _ => '请刷新见面状态',
        }),
        if (status == 'waiting') const Text('尚未匹配到双方条件都合适的人。你可以离开此页，之后再回来查看。'),
        if (state['venue_demo'] == true)
          const Text(
            '开发测试场景 · 虚构地点，请勿前往。',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        if (status == 'proposed') ...[
          const Text('这次提议符合你提交的时段与场所条件。双方确认后将显示详细安排。'),
          if (!mineConfirmed)
            FilledButton(
              onPressed: busy ? null : () => blindAction(id, 'confirm'),
              child: const Text('接受见面提议'),
            ),
        ],
        if (revealed) ...[
          if (starts != null) Text('上海时间  ${formatShanghai(starts)}'),
          if (state['venue_name'] != null)
            Text(
              state['venue_name'] as String,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          if (state['venue_address'] != null)
            Text(state['venue_address'] as String),
          const SizedBox(height: 12),
          if (!mineCompleted && status != 'connected') ...[
            const Text('见面时段结束后可确认完成。'),
            FilledButton(
              onPressed: busy || state['can_complete'] != true
                  ? null
                  : () => blindAction(id, 'complete'),
              child: const Text('我已完成见面'),
            ),
          ],
          if (mineCompleted && !mineContinue && status != 'connected')
            FilledButton(
              onPressed: busy ? null : () => blindAction(id, 'continue'),
              child: const Text('愿意继续匿名交流'),
            ),
          if (mineContinue && status != 'connected')
            const Text('已记录你的意愿。双方都愿意后开放聊天。'),
          if (status == 'connected')
            FilledButton(
              onPressed: busy ? null : () => open(_View.connections),
              child: const Text('打开匿名连接'),
            ),
        ],
        if (status != 'connected')
          TextButton(
            onPressed: busy ? null : () => blindAction(id, 'cancel'),
            child: Text(mineCompleted ? '结束本次相遇' : '取消参与'),
          ),
        if (status == 'connected')
          TextButton(
            onPressed: busy ? null : () => setState(() => another = true),
            child: const Text('再参加一次见面'),
          ),
        if (status != 'waiting') safetyButtons('blind', id),
      ],
    );
  }

  Widget secret() {
    final status = state['status'];
    final id = state['id'] as String?;
    if (status == 'waiting' || (status == 'connected' && !another)) {
      final expires = DateTime.tryParse(state['expires_at']?.toString() ?? '');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Title(status == 'waiting' ? '等待持有相同口令的人' : '已建立匿名连接'),
          if (status == 'waiting' && expires != null)
            Text('等待至 ${formatShanghai(expires)}（上海时间）。'),
          if (status == 'connected')
            FilledButton(
              onPressed: busy ? null : () => open(_View.connections),
              child: const Text('打开匿名连接'),
            ),
          if (id != null) ...[
            TextButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (await confirm(
                            '撤回口令匹配？',
                            status == 'waiting'
                                ? '本次请求将停止等待。'
                                : '双方的这次连接及聊天记录会一并移除。',
                            '撤回',
                          ) &&
                          mounted) {
                        await mutate('secret_act', {
                          'p_id': id,
                          'p_action': 'withdraw',
                        });
                      }
                    },
              child: const Text('撤回匹配'),
            ),
            if (status == 'connected') ...[
              TextButton(
                onPressed: busy ? null : () => setState(() => another = true),
                child: const Text('使用另一个口令'),
              ),
              safetyButtons('secret', id),
            ],
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (status == 'expired' || status == 'withdrawn')
          Text(status == 'expired' ? '上次口令已过期。' : '上次匹配已撤回。'),
        const Text('生成随机口令，通过你信任的渠道交给对方，或输入对方给你的口令。请在提交前保存需要分享的口令。'),
        const SizedBox(height: 12),
        TextField(
          controller: code,
          enabled: !busy,
          maxLength: 100,
          autocorrect: false,
          enableSuggestions: false,
          enableIMEPersonalizedLearning: false,
          keyboardType: TextInputType.visiblePassword,
          decoration: const InputDecoration(
            labelText: '共同口令',
            border: OutlineInputBorder(),
          ),
        ),
        OutlinedButton(
          onPressed: busy
              ? null
              : () {
                  code.text = SecretCode.generate();
                },
          child: const Text('生成随机口令'),
        ),
        const SizedBox(height: 12),
        const Text(
          '双方提交相同口令即同意建立匿名连接。设备只发送口令摘要，服务器能判断相同并知道参与账号和时间。持有口令的第三人也能参加。',
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: busy
              ? null
              : () {
                  try {
                    final token = SecretCode.token(code.text);
                    mutate(
                      'secret_join',
                      {'p_token': token},
                      useNonce: true,
                      onSuccess: () {
                        code.clear();
                        another = false;
                      },
                    );
                  } on FormatException {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请输入完整的应用生成口令。')),
                    );
                  }
                },
          child: const Text('同意建立连接并匹配'),
        ),
      ],
    );
  }

  Widget connections() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (rows.isEmpty) const Text('暂无匿名连接。'),
      for (final item in rows)
        _Door(
          icon: Icons.forum_outlined,
          title: '匿名连接 · ${(item['id'] as String).split('-').first}',
          subtitle: item['source'] == 'blind' ? '来自随机见面' : '来自共同口令',
          onTap: busy
              ? null
              : () => open(_View.chat, connection: item['id'] as String),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: busy ? null : () => open(_View.safetyHistory),
          icon: const Icon(Icons.shield_outlined),
          label: const Text('近期安全记录'),
        ),
      ),
    ],
  );

  Widget safetyHistory() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (rows.isEmpty) const Text('暂无可供举报的近期记录。'),
      for (final row in rows)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row['kind'] == 'blind'
                      ? '匿名见面'
                      : row['source'] == 'blind'
                      ? '匿名连接 · 随机见面'
                      : '匿名连接 · 共同口令',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  '记录时间  ${formatShanghai(DateTime.parse(row['created_at'] as String))}（上海时间）',
                ),
                safetyButtons(row['kind'] as String, row['id'] as String),
              ],
            ),
          ),
        ),
    ],
  );

  Widget chat() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('仅分享你愿意透露的内容。平台可读取聊天消息以提供服务。'),
      const SizedBox(height: 12),
      if (rows.isEmpty) const Text('还没有消息。'),
      for (final row in rows)
        Align(
          alignment: row['mine'] == true
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: Card(
            color: row['mine'] == true
                ? Theme.of(context).colorScheme.secondaryContainer
                : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(row['body'] as String),
            ),
          ),
        ),
      const SizedBox(height: 12),
      TextField(
        controller: draft,
        minLines: 1,
        maxLines: 4,
        maxLength: 500,
        enabled: !busy,
        decoration: const InputDecoration(
          labelText: '匿名消息',
          border: OutlineInputBorder(),
        ),
      ),
      FilledButton(
        onPressed: busy
            ? null
            : () {
                final text = draft.text.trim();
                if (text.isNotEmpty) {
                  mutate(
                    'matching_send',
                    {'p_id': chatId, 'p_body': text},
                    useNonce: true,
                    onSuccess: draft.clear,
                  );
                }
              },
        child: const Text('发送消息'),
      ),
      safetyButtons('connection', chatId!),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final title = switch (view) {
      _View.discover => '发现',
      _View.blind => 'Blind Encounter',
      _View.secret => 'Secret Match',
      _View.connections => '匿名连接',
      _View.chat => '匿名对话',
      _View.safetyHistory => '近期安全记录',
    };
    return PopScope(
      canPop: view == _View.discover,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && view != _View.discover && !busy) back();
      },
      child: ListView(
        key: PageStorageKey('matching-${view.name}'),
        padding: const EdgeInsets.all(22),
        children: [
          Row(
            children: [
              if (view != _View.discover)
                IconButton(
                  tooltip: view == _View.chat || view == _View.safetyHistory
                      ? '返回匿名连接'
                      : '返回发现',
                  onPressed: busy ? null : back,
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(child: _Title(title)),
              IconButton(
                tooltip: '刷新状态',
                onPressed: busy ? null : loadView,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (busy && !loaded) const LinearProgressIndicator(),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (loaded)
            switch (view) {
              _View.discover => home(),
              _View.blind => blind(),
              _View.secret => secret(),
              _View.connections => connections(),
              _View.chat => chat(),
              _View.safetyHistory => safetyHistory(),
            },
        ],
      ),
    );
  }
}
