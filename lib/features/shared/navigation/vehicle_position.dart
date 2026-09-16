/// Where a vehicle is *drawn* right now, shared between the marker and the
/// line so the two cannot disagree.
///
/// They used to be worked out separately: the marker from the carried
/// forward, eased position that moves every frame, and the route line from
/// the last raw GPS fix, which changes only when a new one arrives. Two
/// answers to the same question, updating at different rates — so the line
/// kept detaching from the tricycle and snapping back.
///
/// The marker layer writes here as it draws; the route layer listens. It is
/// a [ValueNotifier] rather than screen state on purpose: passing it through
/// setState would rebuild the whole map — every tile, every layer — sixty
/// times a second. This way only the polyline redraws.
library;

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

class VehiclePosition extends ValueNotifier<LatLng?> {
  VehiclePosition([super.value]);
}
