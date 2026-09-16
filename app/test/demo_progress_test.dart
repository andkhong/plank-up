import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/main.dart';

/// The harness drives the real evaluator and the real session machine, so if
/// it stops advancing the cause is usually the wiring between them rather than
/// either piece. Worth pinning, because a browser suspends animation frames in
/// a hidden tab and the resulting stall looks exactly like a logic bug.
void main() {
  testWidgets('advances past the countdown and accrues credit', (tester) async {
    await tester.pumpWidget(const PlankUpApp());

    for (var i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }

    expect(find.text('GET SET'), findsNothing,
        reason: 'still counting down after five seconds of frames');
    expect(find.text('HOLD'), findsOneWidget);
  });

  testWidgets('a clean hold reaches the target and completes', (tester) async {
    await tester.pumpWidget(const PlankUpApp());

    // 30s target plus the countdown, with a level body throughout.
    for (var i = 0; i < 1100; i++) {
      await tester.pump(const Duration(milliseconds: 33));
    }

    expect(find.text('DONE'), findsOneWidget);
    expect(find.textContaining('earned'), findsOneWidget);
  });
}
