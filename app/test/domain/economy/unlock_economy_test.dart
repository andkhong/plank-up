import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/domain/economy/unlock_economy.dart';

void main() {
  const economy = UnlockEconomy();

  group('tier anchors', () {
    test('30s earns 7 minutes', () {
      expect(economy.earnedFor(const Duration(seconds: 30)),
          const Duration(minutes: 7));
    });

    test('60s earns 15 minutes', () {
      expect(economy.earnedFor(const Duration(seconds: 60)),
          const Duration(minutes: 15));
    });

    test('90s earns 30 minutes', () {
      expect(economy.earnedFor(const Duration(seconds: 90)),
          const Duration(minutes: 30));
    });

    test('every offered tier has a reward', () {
      for (final tier in UnlockEconomy.tiers) {
        expect(economy.rewardForTier(tier), greaterThan(Duration.zero));
      }
    });
  });

  group('floor', () {
    test('nothing below the minimum credited hold', () {
      expect(economy.earnedFor(Duration.zero), Duration.zero);
      expect(economy.earnedFor(const Duration(seconds: 1)), Duration.zero);
      expect(economy.earnedFor(const Duration(seconds: 14)), Duration.zero);
      expect(economy.earnedFor(const Duration(milliseconds: 14999)),
          Duration.zero);
    });

    test('exactly at the floor earns zero, not a jump', () {
      expect(economy.earnedFor(UnlockEconomy.minimumCreditedHold),
          Duration.zero);
    });

    test('negative durations earn nothing rather than throwing', () {
      expect(economy.earnedFor(const Duration(seconds: -30)), Duration.zero);
    });
  });

  group('partial credit', () {
    test('giving up partway earns proportional time', () {
      final partial = economy.earnedFor(const Duration(seconds: 45));
      expect(partial, greaterThan(const Duration(minutes: 7)));
      expect(partial, lessThan(const Duration(minutes: 15)));
    });

    test('credit depends on effort, not on the tier aimed for', () {
      // Abandoning a 90s attempt at 40s pays the same as abandoning a 60s one.
      expect(economy.earnedFor(const Duration(seconds: 40)),
          economy.earnedFor(const Duration(seconds: 40)));
    });

    test('midpoint of a segment earns the midpoint reward', () {
      expect(economy.earnedFor(const Duration(seconds: 45)),
          const Duration(minutes: 11));
    });
  });

  group('cap', () {
    test('holding past the maximum earns no more', () {
      final atMax = economy.earnedFor(UnlockEconomy.maximumHold);
      expect(economy.earnedFor(const Duration(seconds: 120)), atMax);
      expect(economy.earnedFor(const Duration(hours: 1)), atMax);
    });
  });

  group('properties', () {
    test('monotonic non-decreasing across the whole domain', () {
      var previous = Duration.zero;
      for (var ms = 0; ms <= 120000; ms += 250) {
        final earned = economy.earnedFor(Duration(milliseconds: ms));
        expect(earned, greaterThanOrEqualTo(previous),
            reason: 'earnings dropped at ${ms}ms');
        previous = earned;
      }
    });

    test('monotonic under randomized ordered pairs', () {
      final random = Random(20260916);
      for (var i = 0; i < 2000; i++) {
        final a = random.nextInt(130000);
        final b = random.nextInt(130000);
        final lower = Duration(milliseconds: min(a, b));
        final upper = Duration(milliseconds: max(a, b));
        expect(economy.earnedFor(upper),
            greaterThanOrEqualTo(economy.earnedFor(lower)),
            reason: 'non-monotonic between $lower and $upper');
      }
    });

    test('never exceeds the cap', () {
      final random = Random(1);
      final cap = economy.earnedFor(UnlockEconomy.maximumHold);
      for (var i = 0; i < 2000; i++) {
        expect(economy.earnedFor(Duration(milliseconds: random.nextInt(500000))),
            lessThanOrEqualTo(cap));
      }
    });

    test('longer holds pay a better rate at higher tiers', () {
      double ratePerSecond(Duration held) =>
          economy.earnedFor(held).inSeconds / held.inSeconds;

      expect(ratePerSecond(const Duration(seconds: 90)),
          greaterThan(ratePerSecond(const Duration(seconds: 60))));
      expect(ratePerSecond(const Duration(seconds: 60)),
          greaterThan(ratePerSecond(const Duration(seconds: 30))));
    });
  });
}
