import 'dart:async';

import 'package:chenbot/matching/discovery_page.dart';
import 'package:chenbot/matching/secret_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> mount(WidgetTester t, MatchRpc rpc, {String user = 'a'}) async {
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MatchingWorkspace(key: ValueKey(user), rpc: rpc),
      ),
    ),
  );
  await t.pumpAndSettle();
}

Future<void> tap(WidgetTester t, String label) async {
  final finder = find.text(label).last;
  await t.ensureVisible(finder);
  await t.tap(finder);
  await t.pumpAndSettle();
}

void main() {
  testWidgets('adult opt-in and service-returned enrollment gate matching', (
    t,
  ) async {
    bool enrolled = false;
    await mount(t, (method, params) async {
      if (method == 'matching_me') {
        return {'enrolled': enrolled, 'name': 'chen'};
      }
      expect(method, 'matching_enroll');
      expect(params, {'p_adult': true});
      enrolled = true;
      return {'name': 'chen'};
    });
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '开启发现'))
          .onPressed,
      isNull,
    );
    await tap(t, '我已年满 18 岁，自愿参加匿名匹配');
    await tap(t, '开启发现');
    expect(find.textContaining('仅自己可见'), findsOneWidget);
    expect(find.text('匿名连接'), findsOneWidget);
  });
  testWidgets(
    'raw code stays on device; lost response retains nonce on retry',
    (t) async {
      final requests = <Map<String, dynamic>>[];
      String status = 'idle';
      await mount(t, (method, params) async {
        if (method == 'matching_me') return {'enrolled': true};
        if (method == 'secret_state') {
          return {'id': 'my-request', 'status': status};
        }
        expect(method, 'secret_join');
        requests.add({...params});
        if (requests.length == 1) throw TimeoutException('test timeout');
        status = 'waiting';
        return {'id': 'my-request', 'status': 'waiting'};
      });
      await tap(t, 'Secret Match');
      await tap(t, '生成随机口令');
      final code = t.widget<TextField>(find.byType(TextField)).controller!.text;
      await tap(t, '同意建立连接并匹配');
      expect(find.text('等待持有相同口令的人'), findsNothing);
      await t.tap(find.byTooltip('刷新状态'));
      await t.pumpAndSettle();
      await tap(t, '同意建立连接并匹配');
      expect(requests.length, 2);
      expect(requests[0], requests[1]);
      expect(requests[0].keys, unorderedEquals(['p_token', 'p_nonce']));
      expect(requests[0]['p_token'], SecretCode.token(code));
      expect(requests[0].values, isNot(contains(code)));
      expect(find.text('等待持有相同口令的人'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    },
  );
  testWidgets(
    'proposal conceals venue; meeting completion follows server time',
    (t) async {
      Map<String, dynamic> state = {
        'id': 'only-own-id', 'status': 'proposed', 'venue_demo': true,
        // A proposal must not render location even if a malformed response includes it.
        'venue_address': '测试公共空间', 'mine_confirmed': false,
      };
      final actions = <String>[];
      await mount(t, (method, params) async {
        if (method == 'matching_me') return {'enrolled': true};
        if (method == 'blind_state') return state;
        expect(method, 'blind_act');
        expect(params['p_id'], 'only-own-id');
        actions.add(params['p_action'] as String);
        if (params['p_action'] == 'confirm') {
          state = {...state, 'status': 'confirmed', 'mine_confirmed': true};
        }
        return state;
      });
      await tap(t, 'Blind Encounter');
      expect(find.text('测试公共空间'), findsNothing);
      await tap(t, '接受见面提议');
      expect(find.text('测试公共空间'), findsOneWidget);
      expect(
        t
            .widget<FilledButton>(find.widgetWithText(FilledButton, '我已完成见面'))
            .onPressed,
        isNull,
      );
      state = {
        'id': 'only-own-id',
        'status': 'confirmed',
        'can_complete': true,
      };
      await t.tap(find.byTooltip('刷新状态'));
      await t.pumpAndSettle();
      expect(find.text('测试公共空间'), findsNothing);
      await tap(t, '我已完成见面');
      expect(actions, ['confirm', 'complete']);
    },
  );

  testWidgets(
    'ended encounter history loads on demand and reports without peer details',
    (t) async {
      var historyReads = 0;
      Map<String, dynamic>? reported;
      await mount(t, (method, params) async {
        if (method == 'matching_me') return {'enrolled': true};
        if (method == 'matching_connections') return [];
        if (method == 'matching_safety_history') {
          historyReads++;
          return [
            {
              'id': 'own-ended-encounter',
              'kind': 'blind',
              'source': 'blind',
              'created_at': '2026-11-18T01:30:00Z',
              'email': 'private@example.test',
            },
          ];
        }
        expect(method, 'matching_safety');
        reported = params;
        return true;
      });
      await tap(t, '匿名连接');
      expect(historyReads, 0);
      expect(find.text('暂无匿名连接。'), findsOneWidget);
      await tap(t, '近期安全记录');
      expect(historyReads, 1);
      expect(find.text('匿名见面'), findsOneWidget);
      expect(find.textContaining('2026-11-18 09:30'), findsOneWidget);
      expect(find.textContaining('private@example.test'), findsNothing);
      expect(find.textContaining('own-ended-encounter'), findsNothing);
      await tap(t, '安全举报');
      await tap(t, '线下安全问题');
      expect(reported, {
        'p_kind': 'blind',
        'p_id': 'own-ended-encounter',
        'p_action': 'report',
        'p_reason': 'unsafe',
      });
      await t.tap(find.byTooltip('返回匿名连接'));
      await t.pumpAndSettle();
      expect(find.text('暂无匿名连接。'), findsOneWidget);
    },
  );

  testWidgets(
    'late response from former account cannot restore its conversations',
    (t) async {
      final messages = Completer<List<Map<String, dynamic>>>();
      await mount(t, (method, _) async {
        if (method == 'matching_me') return {'enrolled': true};
        if (method == 'matching_connections') {
          return [
            {'id': 'first-connection', 'source': 'secret'},
          ];
        }
        if (method == 'matching_messages') return messages.future;
        throw StateError('unexpected method');
      });
      await tap(t, '匿名连接');
      await t.tap(find.text('匿名连接 · first'));
      await t.pump();
      await mount(t, (method, _) async => {'enrolled': false}, user: 'b');
      messages.complete([
        {'mine': true, 'body': 'A private message'},
      ]);
      await t.pumpAndSettle();
      expect(find.text('A private message'), findsNothing);
      expect(find.text('开启发现'), findsOneWidget);
    },
  );
}
