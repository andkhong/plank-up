/// Converts effort actually expended into earned access time.
///
/// Credit follows what the user *did*, not what they aimed for. Picking a 90s
/// target and stopping at 40s earns the same as picking 60s and stopping at 40s.
library;

class UnlockEconomy {
  const UnlockEconomy();

  /// Below this, a hold earns nothing. Without a floor, and with no cooldown to
  /// slow anyone down, repeated two-second holds would be the cheapest path to
  /// unlimited access.
  static const Duration minimumCreditedHold = Duration(seconds: 15);

  static const Duration maximumHold = Duration(seconds: 90);

  static const List<({Duration held, Duration earned})> _curve = [
    (held: Duration(seconds: 15), earned: Duration.zero),
    (held: Duration(seconds: 30), earned: Duration(minutes: 7)),
    (held: Duration(seconds: 60), earned: Duration(minutes: 15)),
    (held: Duration(seconds: 90), earned: Duration(minutes: 30)),
  ];

  /// The three targets offered at session start.
  static const List<Duration> tiers = [
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 90),
  ];

  /// Reward for a completed tier, used to label the picker before any effort.
  Duration rewardForTier(Duration tier) => earnedFor(tier);

  /// Monotonic non-decreasing in [held]. Piecewise-linear between curve points,
  /// zero below the floor, capped at the top.
  Duration earnedFor(Duration held) {
    if (held < minimumCreditedHold) return Duration.zero;
    if (held >= maximumHold) return _curve.last.earned;

    for (var i = 0; i < _curve.length - 1; i++) {
      final lower = _curve[i];
      final upper = _curve[i + 1];
      if (held >= lower.held && held < upper.held) {
        final span = upper.held.inMilliseconds - lower.held.inMilliseconds;
        final into = held.inMilliseconds - lower.held.inMilliseconds;
        final gain = upper.earned.inMilliseconds - lower.earned.inMilliseconds;
        return Duration(
          milliseconds: lower.earned.inMilliseconds + (gain * into / span).round(),
        );
      }
    }

    return _curve.last.earned;
  }
}
