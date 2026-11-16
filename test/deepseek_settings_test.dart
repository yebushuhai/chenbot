import 'package:chenbot/deepseek_recognition.dart';
import 'package:chenbot/deepseek_account.dart';
import 'package:chenbot/deepseek_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeAccountApi extends DeepSeekAccountApi {
  @override
  Future<DeepSeekBalance> balance(String key) async {
    expect(key, 'test-only-key');
    return const DeepSeekBalance(true, [
      DeepSeekBalanceEntry('CNY', '12.50', '2.50', '10.00'),
    ]);
  }
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'shows the saved key on device, fetches balance, and deletes it',
    (tester) async {
      final store = DeepSeekKeyStore('guest');
      final api = FakeAccountApi();
      await tester.pumpWidget(
        MaterialApp(
          home: DeepSeekSettingsPage(
            scope: 'guest',
            storeOverride: store,
            accountApiOverride: api,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('尚未设置 API Key'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'test-only-key');
      await tester.tap(find.text('保存到本机'));
      await tester.pumpAndSettle();
      expect(await store.read(), 'test-only-key');
      expect(find.text('已在本机保存 API Key'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'test-only-key',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isFalse,
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.decoration!.labelText, isNull);
      expect(field.decoration!.filled, isTrue);
      expect(field.decoration!.fillColor, const Color(0xffd9d9d9));
      expect(
        tester.getTopLeft(find.text('DeepSeek API Key')).dy,
        lessThan(tester.getTopLeft(find.byType(TextField)).dy),
      );
      String bananaAsset(String tooltip) {
        final finder = find.descendant(
          of: find.byTooltip(tooltip),
          matching: find.byType(Image),
        );
        final image = tester.widget<Image>(finder);
        final resize = image.image as ResizeImage;
        return (resize.imageProvider as AssetImage).assetName;
      }

      expect(bananaAsset('隐藏密钥'), 'assets/branding/banana_visible.png');
      await tester.tap(find.byTooltip('隐藏密钥'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isTrue,
      );
      expect(bananaAsset('显示输入的密钥'), 'assets/branding/banana_hidden.png');
      expect(await store.read(), 'test-only-key');
      await tester.tap(find.byTooltip('显示输入的密钥'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isFalse,
      );
      await tester.drag(find.byType(ListView), const Offset(0, -700));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.scrollUntilVisible(
        find.textContaining('CNY 12.50'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('CNY 12.50'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('删除本机密钥'),
        -180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('删除本机密钥'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();
      expect(await store.hasKey(), isFalse);
      await tester.scrollUntilVisible(
        find.text('尚未设置 API Key'),
        -180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('尚未设置 API Key'), findsOneWidget);
      api.close();
    },
  );

  testWidgets('photo upload requires an explicit confirmation', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async =>
                  answer = await confirmDeepSeekUpload(context, 3),
              child: const Text('开始'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 张照片'), findsOneWidget);
    expect(find.textContaining('可能产生费用'), findsOneWidget);
    expect(find.textContaining('本次合计最多 9 次'), findsOneWidget);
    expect(find.textContaining('本地词频排名'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认发送'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });
}
