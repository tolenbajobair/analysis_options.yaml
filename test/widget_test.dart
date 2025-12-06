import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:project_sync/main.dart'; // ✅ your new package name

void main() {
  testWidgets('smoke test: Project Sync boots', (WidgetTester tester) async {
    await tester.pumpWidget(const ProjectSyncApp()); // ✅ not Root

    // App shows the welcome title in either language
    expect(find.text('Welcome'), findsOneWidget);
    // If the device default is Arabic, the fallback check:
    // expect(find.text('أهلًا'), findsWidgets);

    // Make sure the role buttons are there
    expect(find.byIcon(Icons.apartment), findsOneWidget);
    expect(find.byIcon(Icons.lightbulb), findsOneWidget);
  });
}
