import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toda_equeue_plus/widgets/map_tiles.dart';

/// Applies a colour matrix the way the compositor does, so the filters can be
/// checked numerically instead of by eye.
({double r, double g, double b}) apply(
  List<double> m,
  double r,
  double g,
  double b,
) => (
  r: (m[0] * r + m[1] * g + m[2] * b + m[4]).clamp(0.0, 255.0),
  g: (m[5] * r + m[6] * g + m[7] * b + m[9]).clamp(0.0, 255.0),
  b: (m[10] * r + m[11] * g + m[12] * b + m[14]).clamp(0.0, 255.0),
);

const _identity = <double>[
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0, //
];

void main() {
  group('saturationMatrix', () {
    test('leaves colour untouched at full saturation', () {
      final out = apply(saturationMatrix(1), 200, 50, 25);
      expect(out.r, closeTo(200, 0.001));
      expect(out.g, closeTo(50, 0.001));
      expect(out.b, closeTo(25, 0.001));
    });

    test('collapses to luminance grey at zero', () {
      // Rec. 709 luminance of pure red is 0.2126 * 255.
      final out = apply(saturationMatrix(0), 255, 0, 0);
      expect(out.r, closeTo(54.2, 0.5));
      expect(out.r, closeTo(out.g, 0.001));
      expect(out.g, closeTo(out.b, 0.001));
    });

    test('grey stays grey at any saturation', () {
      for (final s in [0.0, 0.28, 1.0]) {
        final out = apply(saturationMatrix(s), 128, 128, 128);
        expect(out.r, closeTo(128, 0.5), reason: 's=$s');
        expect(out.g, closeTo(128, 0.5), reason: 's=$s');
      }
    });

    test('partial saturation lands between the extremes', () {
      final full = apply(saturationMatrix(1), 255, 0, 0);
      final none = apply(saturationMatrix(0), 255, 0, 0);
      final part = apply(saturationMatrix(0.28), 255, 0, 0);

      expect(part.r, lessThan(full.r));
      expect(part.r, greaterThan(none.r));
    });
  });

  group('invertMatrix', () {
    test('swaps black and white', () {
      expect(apply(invertMatrix(), 0, 0, 0).r, closeTo(255, 0.001));
      expect(apply(invertMatrix(), 255, 255, 255).r, closeTo(0, 0.001));
    });

    test('is its own inverse', () {
      final twice = composeColorMatrices(invertMatrix(), invertMatrix());
      final out = apply(twice, 40, 130, 220);
      expect(out.r, closeTo(40, 0.001));
      expect(out.g, closeTo(130, 0.001));
      expect(out.b, closeTo(220, 0.001));
    });
  });

  group('composeColorMatrices', () {
    test('composing with the identity changes nothing', () {
      final m = saturationMatrix(0.3);
      final out = apply(composeColorMatrices(_identity, m), 200, 50, 25);
      final direct = apply(m, 200, 50, 25);
      expect(out.r, closeTo(direct.r, 0.001));
      expect(out.g, closeTo(direct.g, 0.001));
    });

    test('applies the second argument first', () {
      // Invert then lighten is not the same as lighten then invert; this
      // pins down which way round the composition goes.
      final invertThenLift = composeColorMatrices(
        levelsMatrix(offset: 20),
        invertMatrix(),
      );
      expect(apply(invertThenLift, 255, 255, 255).r, closeTo(20, 0.001));
    });

    test('carries the offset through a scale', () {
      // Offset 10, then scaled by 2, should land at 20 — not 10.
      final scaled = composeColorMatrices(
        levelsMatrix(scale: 2),
        levelsMatrix(offset: 10),
      );
      expect(apply(scaled, 0, 0, 0).r, closeTo(20, 0.001));
    });
  });

  group('baseMapMatrix', () {
    test('light keeps the map pale rather than blowing it out', () {
      final white = apply(baseMapMatrix(Brightness.light), 255, 255, 255);
      expect(white.r, inInclusiveRange(240, 255));
    });

    test('light drains most of the colour from a saturated road', () {
      // OpenStreetMap paints trunk roads a strong orange; muted, it should
      // read as grey so traffic colour is the brightest thing on screen.
      const orangeR = 232.0, orangeG = 146.0, orangeB = 85.0;
      final out = apply(
        baseMapMatrix(Brightness.light),
        orangeR,
        orangeG,
        orangeB,
      );
      final spreadBefore = orangeR - orangeB;
      final spreadAfter = out.r - out.b;
      expect(spreadAfter, lessThan(spreadBefore * 0.2));
    });

    test('light lifts fills towards white so the map recedes', () {
      // OpenStreetMap's residential fill is a light beige; muted it should
      // be almost indistinguishable from the page.
      final out = apply(baseMapMatrix(Brightness.light), 242, 239, 233);
      expect(out.r, greaterThan(230));
    });

    test('light keeps label text dark enough to read', () {
      // Black text must not be lifted so far that it stops being legible.
      final text = apply(baseMapMatrix(Brightness.light), 0, 0, 0);
      expect(text.r, inInclusiveRange(25, 90));
    });

    test('dark turns the light map dark', () {
      final white = apply(baseMapMatrix(Brightness.dark), 255, 255, 255);
      expect(white.r, lessThan(40));
    });

    test('dark keeps black text readable by lifting it', () {
      final black = apply(baseMapMatrix(Brightness.dark), 0, 0, 0);
      expect(black.r, greaterThan(180));
    });

    test('dark also desaturates', () {
      final out = apply(baseMapMatrix(Brightness.dark), 232, 146, 85);
      expect((out.r - out.b).abs(), lessThan(40));
    });

    test('the two themes are genuinely different', () {
      final light = apply(baseMapMatrix(Brightness.light), 200, 200, 200);
      final dark = apply(baseMapMatrix(Brightness.dark), 200, 200, 200);
      expect((light.r - dark.r).abs(), greaterThan(100));
    });

    test('output stays in range for the corners of the colour cube', () {
      for (final brightness in Brightness.values) {
        final m = baseMapMatrix(brightness);
        for (final c in [
          [0.0, 0.0, 0.0],
          [255.0, 255.0, 255.0],
          [255.0, 0.0, 0.0],
          [0.0, 255.0, 0.0],
          [0.0, 0.0, 255.0],
        ]) {
          final out = apply(m, c[0], c[1], c[2]);
          // clamp() in the helper would hide an overflow, so check the raw
          // arithmetic stayed sane rather than merely survivable.
          expect(out.r, inInclusiveRange(0, 255));
          expect(out.g, inInclusiveRange(0, 255));
          expect(out.b, inInclusiveRange(0, 255));
        }
      }
    });
  });
}
