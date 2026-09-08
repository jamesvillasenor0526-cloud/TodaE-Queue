/// The app's Google map, with one place to set the style and defaults.
///
/// Google's own live traffic is drawn by the SDK itself ([showTraffic]) and
/// covers general congestion across the city. The TODA reports layered on
/// top carry what Google cannot see — accidents, flooding, closures and
/// breakdowns that drivers tag as they meet them.
///
/// The base map is deliberately muted so the traffic ribbons and report pins
/// are the brightest things on screen.
library;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:latlong2/latlong.dart' as ll;

/// Converts between the map plugin's LatLng and the one the domain models
/// use. Keeping the models on latlong2 leaves them free of any plugin
/// dependency, so the geo logic stays unit testable.
extension LatLngToMaps on ll.LatLng {
  LatLng get toMaps => LatLng(latitude, longitude);
}

extension LatLngFromMaps on LatLng {
  ll.LatLng get toLatLng => ll.LatLng(latitude, longitude);
}

/// Camera helpers on the nullable controller.
///
/// The controller only exists once the platform view is created, so every
/// call site would otherwise need its own null check. Moving the camera
/// before the map is ready is a no-op rather than a crash.
extension MapCameraMoves on GoogleMapController? {
  Future<void> moveTo(ll.LatLng point, double zoom) async {
    await this?.animateCamera(
      CameraUpdate.newLatLngZoom(point.toMaps, zoom),
    );
  }

  Future<void> zoomBy(double amount) async {
    await this?.animateCamera(CameraUpdate.zoomBy(amount));
  }

  /// Frames both points with room to spare, for showing a driver and a
  /// pickup at once.
  Future<void> fitBounds(ll.LatLng a, ll.LatLng b, {double padding = 80}) async {
    final controller = this;
    if (controller == null) return;
    final bounds = LatLngBounds(
      southwest: LatLng(
        a.latitude < b.latitude ? a.latitude : b.latitude,
        a.longitude < b.longitude ? a.longitude : b.longitude,
      ),
      northeast: LatLng(
        a.latitude > b.latitude ? a.latitude : b.latitude,
        a.longitude > b.longitude ? a.longitude : b.longitude,
      ),
    );
    await controller.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, padding),
    );
  }
}

/// Muted light style, close to Google's "silver": pale fills, white roads,
/// grey labels, POI icons suppressed.
const String _lightStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#f5f5f5"}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#f5f5f5"}]},
  {"featureType":"administrative.land_parcel","elementType":"labels.text.fill","stylers":[{"color":"#bdbdbd"}]},
  {"featureType":"poi","elementType":"geometry","stylers":[{"color":"#eeeeee"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#e5e5e5"}]},
  {"featureType":"poi.park","elementType":"labels.text.fill","stylers":[{"color":"#9e9e9e"}]},
  {"featureType":"road","elementType":"geometry","stylers":[{"color":"#ffffff"}]},
  {"featureType":"road.arterial","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#dadada"}]},
  {"featureType":"road.highway","elementType":"labels.text.fill","stylers":[{"color":"#616161"}]},
  {"featureType":"road.local","elementType":"labels.text.fill","stylers":[{"color":"#9e9e9e"}]},
  {"featureType":"transit.line","elementType":"geometry","stylers":[{"color":"#e5e5e5"}]},
  {"featureType":"transit.station","elementType":"geometry","stylers":[{"color":"#eeeeee"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#c9c9c9"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#9e9e9e"}]}
]
''';

/// Matching dark style, so the map follows the app's theme.
const String _darkStyle = '''
[
  {"elementType":"geometry","stylers":[{"color":"#212121"}]},
  {"elementType":"labels.icon","stylers":[{"visibility":"off"}]},
  {"elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
  {"elementType":"labels.text.stroke","stylers":[{"color":"#212121"}]},
  {"featureType":"administrative","elementType":"geometry","stylers":[{"color":"#757575"}]},
  {"featureType":"poi","elementType":"labels.text.fill","stylers":[{"color":"#757575"}]},
  {"featureType":"poi.park","elementType":"geometry","stylers":[{"color":"#181818"}]},
  {"featureType":"road","elementType":"geometry.fill","stylers":[{"color":"#2c2c2c"}]},
  {"featureType":"road","elementType":"labels.text.fill","stylers":[{"color":"#8a8a8a"}]},
  {"featureType":"road.highway","elementType":"geometry","stylers":[{"color":"#3c3c3c"}]},
  {"featureType":"water","elementType":"geometry","stylers":[{"color":"#000000"}]},
  {"featureType":"water","elementType":"labels.text.fill","stylers":[{"color":"#3d3d3d"}]}
]
''';

String mapStyleFor(Brightness brightness) =>
    brightness == Brightness.dark ? _darkStyle : _lightStyle;

class AppGoogleMap extends StatelessWidget {
  const AppGoogleMap({
    super.key,
    required this.initialCenter,
    this.initialZoom = 15,
    this.markers = const <Marker>{},
    this.polylines = const <Polyline>{},
    this.circles = const <Circle>{},
    this.showTraffic = false,
    this.showMyLocation = false,
    this.zoomControls = false,
    this.padding = EdgeInsets.zero,
    this.onMapCreated,
    this.onTap,
    this.onLongPress,
  });

  final ll.LatLng initialCenter;
  final double initialZoom;
  final Set<Marker> markers;
  final Set<Polyline> polylines;
  final Set<Circle> circles;

  /// Google's live traffic. Free on the Android SDK, and the reason the
  /// app no longer derives congestion itself.
  final bool showTraffic;

  final bool showMyLocation;
  final bool zoomControls;
  final EdgeInsets padding;
  final void Function(GoogleMapController)? onMapCreated;
  final void Function(ll.LatLng)? onTap;
  final void Function(ll.LatLng)? onLongPress;

  @override
  Widget build(BuildContext context) {
    return GoogleMap(
      initialCameraPosition: CameraPosition(
        target: initialCenter.toMaps,
        zoom: initialZoom,
      ),
      style: mapStyleFor(Theme.of(context).brightness),
      markers: markers,
      polylines: polylines,
      circles: circles,
      trafficEnabled: showTraffic,
      myLocationEnabled: showMyLocation,
      myLocationButtonEnabled: false,
      zoomControlsEnabled: zoomControls,
      mapToolbarEnabled: false,
      padding: padding,
      onMapCreated: onMapCreated,
      onTap: onTap == null ? null : (p) => onTap!(p.toLatLng),
      onLongPress: onLongPress == null ? null : (p) => onLongPress!(p.toLatLng),
    );
  }
}
