import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_code/main.dart';
import 'package:muse_code/src/engine.dart';
import 'package:muse_code/src/host/host_stub.dart';
import 'package:muse_code/src/model.dart';

import 'fake_muse.dart';

void main() {
  Future<MuseController> start(WidgetTester tester, String fixture, {List<Project> projects = const []}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final host = MemoryHost();
    await host.saveState(jsonEncode({
      'settings': {'relayUrl': 'https://relay.test', 'relayToken': 'token-0123456789abcdef', 'theme': 'light'},
      'projects': [for (final p in projects) p.toJson()],
    }));
    final transport = TranscriptTransport.fixture(fixture);
    final c = MuseController(host: host, transport: (_, __) async => transport, relayApi: (_, __) => FakeRelayApi());
    await tester.runAsync(() async {
      await c.load();
      await settle();
    });
    await tester.pumpWidget(MuseApp(controller: c));
    return c;
  }

  testWidgets('New project asks only for a name', (tester) async {
    final c = await start(tester, 'text-run-single-turn');
    expect(find.text('Start a project'), findsOneWidget);
    await tester.tap(find.text('New project'));
    await tester.pumpAndSettle();
    expect(find.text('Name'), findsOneWidget);
    expect(find.text('Folder'), findsNothing);
    await tester.enterText(find.byType(EditableText).first, 'Shop');
    await tester.tap(find.text('Create'));
    await tester.runAsync(settle);
    await tester.pumpAndSettle();
    expect(c.projects.single.name, 'Shop');
    expect(find.text('No repositories attached yet.'), findsOneWidget);
    expect(find.text('What should we work on?'), findsOneWidget);
    await tester.runAsync(c.saveNow);
  });

  testWidgets('subagents show as worker threads with their reports in Main', (tester) async {
    final c = await start(tester, 'subagent-nested-lifecycle', projects: [
      Project(name: 'Tests', root: '/home/me/src/proj', sessionId: '018f7294-0000-7000-8000-7fed06700000'),
    ]);
    await tester.pump();
    expect(c.online, isTrue);
    expect(find.text('Report from Survey the failing tests'), findsOneWidget);
    // In the thread list and on the start card in Main.
    expect(find.text('Survey the failing tests'), findsNWidgets(2));

    await tester.tap(find.text('Open thread').first);
    await tester.pump();
    expect(find.text('Objective from the orchestrator'), findsOneWidget);
    expect(find.text('Message this worker directly…'), findsOneWidget);
    await tester.runAsync(c.saveNow);
  });
}
