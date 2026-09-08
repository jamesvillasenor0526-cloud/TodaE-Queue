/// The base map, styled to recede behind what is drawn on top of it.
///
/// A navigation map is quiet: muted greys under strong route and traffic
/// colour. Standard OpenStreetMap tiles are the opposite — brightly coloured
/// roads, green parks, blue water — which fights the traffic overlay for
/// attention exactly where it matters.
///
/// The obvious answer would be a ready-made muted basemap like CARTO
/// Positron, but those now serve keyless requests with an "API KEY REQUIRED"
/// watermark stamped across the tile. Positron is itself little more than
/// desaturated OpenStreetMap, so the same look is produced here by filtering
/// the tiles the app already loads: no key, no new provider, no extra
/// attribution obligations, and one place to tune it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:url_launcher/url_launcher.dart';

/// Luminance weights (Rec. 709), used to desaturate towards perceived
/// brightness rather than a flat channel average.
const double _lumR = 0.2126;
const double _lumG = 0.7152;
const double _lumB = 0.0722;

/// Composes two colour matrices: the result applies [first], then [second].
///
/// Each matrix is the 20-value row-major form [ColorFilter.matrix] takes —
/// four rows of five, with an implied fifth row of `[0, 0, 0, 0, 1]`.
List<double> composeColorMatrices(List<double> second, List<double> first) {
  assert(second.length == 20 && first.length == 20);
  final out = List<double>.filled(20, 0);
  for (var row = 0; row < 4; row++) {
    for (var col = 0; col < 5; col++) {
      var sum = 0.0;
      for (var k = 0; k < 4; k++) {
        sum += second[row * 5 + k] * first[k * 5 + col];
      }
      // The translation column also picks up this row's own offset.
      if (col == 4) sum += second[row * 5 + 4];
      out[row * 5 + col] = sum;
    }
  }
  return out;
}

/// Pulls colour towards grey. [amount] of 1 leaves the image untouched, 0
/// makes it fully greyscale.
List<double> saturationMatrix(double amount) {
  final s = amount.clamp(0.0, 1.0);
  final r = (1 - s) * _lumR;
  final g = (1 - s) * _lumG;
  final b = (1 - s) * _lumB;
  return [
    r + s, g, b, 0, 0, //
    r, g + s, b, 0, 0, //
    r, g, b + s, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

/// Scales and shifts every channel — used to lift the map towards a pale
/// grey, or push it down towards black.
List<double> levelsMatrix({double scale = 1, double offset = 0}) => [
  scale, 0, 0, 0, offset, //
  0, scale, 0, 0, offset, //
  0, 0, scale, 0, offset, //
  0, 0, 0, 1, 0, //
];

/// Flips light and dark, the basis of the dark-mode base map.
List<double> invertMatrix() => const [
  -1, 0, 0, 0, 255, //
  0, -1, 0, 0, 255, //
  0, 0, -1, 0, 255, //
  0, 0, 0, 1, 0, //
];

/// The filter applied to raw OpenStreetMap tiles for a given theme.
///
/// Light: mostly desaturated and lifted, so roads read as pale grey ribbons.
/// Dark: inverted first, then desaturated and dropped, which turns the same
/// tiles into a dark navigation map without needing a second tile source.
List<double> baseMapMatrix(Brightness brightness) => brightness ==
        Brightness.dark
    ? composeColorMatrices(
        levelsMatrix(scale: 0.88, offset: 8),
        composeColorMatrices(saturationMatrix(0.22), invertMatrix()),
      )
    : composeColorMatrices(
        // Strong lift with reduced contrast: fills and roads rise towards
        // white while black label text only reaches a mid grey, which is
        // what gives the map its pale, recessive look.
        levelsMatrix(scale: 0.82, offset: 46),
        saturationMatrix(0.10),
      );

/// The app's base map tiles, muted to sit behind the traffic overlay.
///
/// Set [muted] to false where the map itself is the subject rather than a
/// backdrop — picking a location, say — and full colour helps orientation.
class AppTileLayer extends StatelessWidget {
  const AppTileLayer({super.key, this.muted = true});

  final bool muted;

  static const String _urlTemplate =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String _package = 'com.example.toda_equeue_plus';

  @override
  Widget build(BuildContext context) {
    final tiles = TileLayer(
      urlTemplate: _urlTemplate,
      userAgentPackageName: _package,
    );
    if (!muted) return tiles;

    return ColorFiltered(
      colorFilter: ColorFilter.matrix(
        baseMapMatrix(Theme.of(context).brightness),
      ),
      child: tiles,
    );
  }
}

/// OpenStreetMap's attribution, which its tile usage policy requires.
///
/// Collapsed to a small marker that expands on tap, so it meets the
/// requirement without taking space from the map.
class AppMapAttribution extends StatelessWidget {
  const AppMapAttribution({super.key});

  @override
  Widget build(BuildContext context) {
    return RichAttributionWidget(
      alignment: AttributionAlignment.bottomLeft,
      showFlutterMapAttribution: false,
      attributions: [
        TextSourceAttribution(
          'OpenStreetMap contributors',
          onTap: () => launchUrl(
            Uri.parse('https://www.openstreetmap.org/copyright'),
            mode: LaunchMode.externalApplication,
          ),
        ),
      ],
    );
  }
}
