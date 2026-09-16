import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/main.dart';

void main() {
  testWidgets('the demo harness boots and reaches a session state',
      (tester) async {
    await tester.pumpWidget(const PlankUpApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(Slider), findsOneWidget);
    expect(find.text('Restart'), findsOneWidget);

    // One of the session words must be on screen — which one depends on how
    // far the ticker has advanced, and pinning that would make this flaky.
    const words = [
      'GET SET',
      'HOLD',
      "CAN'T SEE YOU",
      'HIPS UP',
      'HIPS DOWN',
      'STRAIGHTEN',
      'FRAMING',
    ];
    expect(
      words.any((w) => find.text(w).evaluate().isNotEmpty),
      isTrue,
      reason: 'no session state word rendered',
    );
  });

  testWidgets('the tier chips offer the three targets', (tester) async {
    await tester.pumpWidget(const PlankUpApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('30s'), findsOneWidget);
    expect(find.text('60s'), findsOneWidget);
    expect(find.text('90s'), findsOneWidget);
  });
}
