import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_code/main.dart';
import 'package:muse_code/src/engine.dart';
import 'package:muse_code/src/host/host_io.dart';

import 'fake_llm.dart';

void main() {
  testWidgets('a message to Main starts a worker that shows in the thread list', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final tmp = Directory.systemTemp.createTempSync('muse_app');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final llm = FakeLlm((system, messages) {
      final last = lastUserText(messages);
      if (!system.contains('You are the orchestrator')) return text('All done.');
      if (last.contains('<worker_report worker_id')) return text('Your worker finished.');
      if (last.startsWith('RESULT:')) return text('On it.');
      return toolCall('spawn_worker', {'title': 'Tour the code', 'instructions': 'Describe the layout.'});
    });
    final c = MuseController(host: IoHost(statePath: '${tmp.path}/s.json'), clientFactory: (_) => llm)
      ..loaded = true
      ..settings.apiKey = 'sk-ant-test'
      ..settings.theme = 'light';

    await tester.pumpWidget(MuseApp(controller: c));
    expect(find.text('Start a project'), findsOneWidget);

    await tester.runAsync(() async => c.createProject('Demo', ''));
    await tester.pump();
    expect(find.text('What should we work on?'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'Give me a tour');
    await tester.pump();
    await tester.tap(find.text('Send'));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('Your worker finished.'), findsOneWidget);
    expect(find.text('Report from Tour the code'), findsOneWidget);
    // In the thread list and on the spawn row.
    expect(find.text('Tour the code'), findsNWidgets(2));

    await tester.tap(find.text('Open thread'));
    await tester.pump();
    expect(find.text('Task from the orchestrator'), findsOneWidget);
    expect(find.text('All done.'), findsOneWidget);
    await tester.runAsync(() => c.saveNow());
  });
}
