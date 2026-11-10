import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});
  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final email = TextEditingController();
  final code = TextEditingController();
  bool sent = false, busy = false;
  String? error;
  @override
  void dispose() {
    email.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> send() async {
    final value = email.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)) {
      setState(() => error = '请输入有效的邮箱地址');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Supabase.instance.client.auth.signInWithOtp(email: value);
      if (mounted) setState(() => sent = true);
    } on AuthException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '发送失败，请检查网络后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> verify() async {
    if (code.text.trim().isEmpty) {
      setState(() => error = '请输入邮箱验证码');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Supabase.instance.client.auth.verifyOTP(
        email: email.text.trim(),
        token: code.text.trim(),
        type: OtpType.email,
      );
      if (mounted) Navigator.pop(context, true);
    } on AuthException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = '验证失败，请稍后重试。');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('邮箱登录')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 20),
          Text(
            sent ? '查收验证码' : '登录你的学习空间',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          Text(
            sent ? '验证码已发送至 ${email.text.trim()}。请查收邮件。' : '我们会向你的邮箱发送一次性验证码。',
          ),
          const SizedBox(height: 24),
          TextField(
            controller: email,
            enabled: !sent && !busy,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: '邮箱地址',
              border: OutlineInputBorder(),
            ),
          ),
          if (sent) ...[
            const SizedBox(height: 16),
            TextField(
              controller: code,
              enabled: !busy,
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
              decoration: const InputDecoration(
                labelText: '验证码',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy
                ? null
                : sent
                ? verify
                : send,
            child: Text(
              busy
                  ? '请稍候…'
                  : sent
                  ? '验证并登录'
                  : '发送验证码',
            ),
          ),
          if (sent)
            TextButton(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      sent = false;
                      code.clear();
                      error = null;
                    }),
              child: const Text('更换邮箱'),
            ),
        ],
      ),
    ),
  );
}
