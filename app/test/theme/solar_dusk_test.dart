import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plank_up/theme/solar_dusk.dart';

/// Hues the corgi and the brand occupy. Anything in this band is brand
/// furniture and must not carry a safety signal.
bool isWarmBrandHue(Color color) {
  final hsv = HSVColor.fromColor(color);
  if (hsv.saturation < 0.15) return false;
  return hsv.hue >= 15 && hsv.hue <= 70;
}

void main() {
  group('the mascot/warning collision stays resolved', () {
    const live = [
      SessionSurface.holding,
      SessionSurface.paused,
      SessionSurface.lost,
      SessionSurface.settling,
    ];

    test('no live session field uses a warm brand hue', () {
      for (final surface in live) {
        expect(isWarmBrandHue(SessionPalette.fieldFor(surface)), isFalse,
            reason: '$surface uses a hue the corgi occupies');
      }
    });

    test('brand orange is confirmed to be in the banned band', () {
      // Guards the guard: if this ever stops being true the test above is inert.
      expect(isWarmBrandHue(SolarDuskDark.primary), isTrue);
      expect(isWarmBrandHue(const Color(0xFFEAB308)), isTrue);
    });

    test('success is the one place warmth returns', () {
      expect(isWarmBrandHue(SessionPalette.fieldFor(SessionSurface.completed)),
          isTrue);
    });

    test('the skeleton is cool, not warm', () {
      expect(isWarmBrandHue(SessionPalette.skeleton), isFalse);
    });
  });

  group('the luminance ladder survives colourblindness', () {
    test('holding and paused are far apart in luminance', () {
      final holding =
          SessionPalette.fieldFor(SessionSurface.holding).computeLuminance();
      final paused =
          SessionPalette.fieldFor(SessionSurface.paused).computeLuminance();
      expect((paused - holding).abs(), greaterThan(0.6),
          reason: 'the warning must read as a luminance event, not a hue one');
    });

    test('paused and settling are distinguishable without hue', () {
      final paused =
          SessionPalette.fieldFor(SessionSurface.paused).computeLuminance();
      final settling =
          SessionPalette.fieldFor(SessionSurface.settling).computeLuminance();
      expect((paused - settling).abs(), greaterThan(0.25));
    });

    test('states distinguished by field alone have distinct greyscale values',
        () {
      // `lost` is excluded deliberately: it shares the paused field and is
      // distinguished by hatch and pulse rate instead. Both are "not
      // accumulating", so they are allowed to look alike at a glance.
      const distinctByField = [
        SessionSurface.holding,
        SessionSurface.paused,
        SessionSurface.settling,
        SessionSurface.completed,
      ];

      final seen = <SessionSurface, double>{};
      for (final surface in distinctByField) {
        final l = SessionPalette.fieldFor(surface).computeLuminance();
        for (final entry in seen.entries) {
          expect((l - entry.value).abs(), greaterThan(0.04),
              reason: '$surface collapses onto ${entry.key} in greyscale');
        }
        seen[surface] = l;
      }
    });

    test('lost shares the paused field but is separable another way', () {
      expect(SessionPalette.fieldFor(SessionSurface.lost),
          SessionPalette.fieldFor(SessionSurface.paused));
      expect(SessionPalette.pulseHzFor(SessionSurface.lost),
          isNot(SessionPalette.pulseHzFor(SessionSurface.paused)));
      expect(SessionPalette.lostHatch.a, greaterThan(0));
    });

    test('ink contrasts with its own field', () {
      for (final surface in SessionSurface.values) {
        final field = SessionPalette.fieldFor(surface).computeLuminance();
        final ink = SessionPalette.inkFor(surface).computeLuminance();
        expect((field - ink).abs(), greaterThan(0.3),
            reason: '$surface has low field/ink contrast');
      }
    });
  });

  group('redundant channels', () {
    test('border thickness alone distinguishes the three live states', () {
      expect(SessionPalette.borderFor(SessionSurface.holding), 0);
      expect(SessionPalette.borderFor(SessionSurface.paused), greaterThan(0));
      expect(SessionPalette.borderFor(SessionSurface.settling),
          greaterThan(SessionPalette.borderFor(SessionSurface.paused)));
    });

    test('nothing pulses faster than 2 Hz', () {
      for (final surface in SessionSurface.values) {
        expect(SessionPalette.pulseHzFor(surface), lessThanOrEqualTo(2.0),
            reason: '$surface exceeds the photosensitivity cap');
      }
    });

    test('a clean hold is completely still', () {
      // Motion is the warning channel here, so idle motion would poison it.
      expect(SessionPalette.pulseHzFor(SessionSurface.holding), 0);
    });
  });

  group('type scale', () {
    test('every size used on a session screen clears the floor', () {
      for (final size in [
        TypeScale.sessionCounter,
        TypeScale.sessionState,
        TypeScale.sessionCoach,
      ]) {
        expect(size, greaterThanOrEqualTo(TypeScale.sessionFloor));
      }
    });
  });

  group('charts', () {
    test('the primary categorical pair is orange against blue', () {
      expect(isWarmBrandHue(ChartPalette.clean), isTrue);
      expect(isWarmBrandHue(ChartPalette.recovered), isFalse);
    });

    test('clean and recovered are distinguishable in greyscale too', () {
      expect(
          (ChartPalette.clean.computeLuminance() -
                  ChartPalette.recovered.computeLuminance())
              .abs(),
          greaterThan(0.03));
    });
  });
}
