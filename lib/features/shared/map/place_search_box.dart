/// A search box over a map, for finding a place by name.
///
/// Used by the pick-up and destination pickers, which until now only took a
/// tap: a passenger had to know where the market or the terminal was on the
/// map and find it by panning.
///
/// Typing does not search on every letter. It waits until the passenger
/// pauses, and needs at least a few letters, because OpenStreetMap's search
/// allows roughly one request a second and asks not to be used for
/// letter-by-letter autocomplete.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../config/theme.dart';
import '../../../core/models/place_search.dart';
import '../../../core/services/geocoding_service.dart';
import '../../../core/services/service_area_service.dart';

/// How long after the last keystroke the search runs.
const Duration kSearchPause = Duration(milliseconds: 600);

class PlaceSearchBox extends StatefulWidget {
  const PlaceSearchBox({
    super.key,
    required this.near,
    required this.onPicked,
    this.hint = 'Search for a place',
    this.search,
  });

  /// Where the map is looking, used to offer the nearest places first.
  final LatLng near;
  final void Function(PlaceHit place) onPicked;
  final String hint;

  /// How places are looked up. Only given in tests; otherwise the map's
  /// own search is used.
  final Future<List<PlaceHit>> Function(String query, LatLng near)? search;

  @override
  State<PlaceSearchBox> createState() => _PlaceSearchBoxState();
}

class _PlaceSearchBoxState extends State<PlaceSearchBox> {
  final _field = TextEditingController();
  Timer? _pause;
  List<PlaceHit> _results = const [];
  bool _searching = false;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    // So results can be marked as outside the town. Reading the bundled
    // outline happens once for the whole app; if it fails, results are just
    // unmarked.
    ServiceAreaService.instance.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _pause?.cancel();
    _field.dispose();
    super.dispose();
  }

  void _onTyped(String value) {
    _pause?.cancel();
    if (!worthSearching(value)) {
      setState(() {
        _results = const [];
        _searched = false;
        _searching = false;
      });
      return;
    }
    _pause = Timer(kSearchPause, () => _search(value));
  }

  Future<void> _search(String query) async {
    setState(() => _searching = true);
    final look =
        widget.search ??
        (String q, LatLng near) =>
            GeocodingService.instance.searchPlaces(q, near: near);
    final found = await look(query, widget.near);
    if (!mounted) return;
    // A slower earlier search must not overwrite what is in the box now.
    if (_field.text.trim().toLowerCase() != query.trim().toLowerCase()) return;
    setState(() {
      _results = found;
      _searching = false;
      _searched = true;
    });
  }

  void _clear() {
    _pause?.cancel();
    _field.clear();
    setState(() {
      _results = const [];
      _searched = false;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          elevation: 3,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: TextField(
            controller: _field,
            onChanged: _onTyped,
            onSubmitted: (v) {
              _pause?.cancel();
              if (worthSearching(v)) _search(v);
            },
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: widget.hint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : _field.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Clear',
                      onPressed: _clear,
                    ),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        if (_results.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Material(
            elevation: 3,
            borderRadius: BorderRadius.circular(AppRadius.md),
            color: Colors.white,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: _results.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final place = _results[i];
                  // Places beyond the town are still offered, but said to be
                  // beyond it: the fare may include the driver's return.
                  final area = ServiceAreaService.instance.area;
                  final outside = area.isUsable && !area.contains(place.at);
                  return ListTile(
                    dense: true,
                    leading: Icon(
                      outside ? Icons.south_east : Icons.place_outlined,
                      color: outside ? AppTheme.warning : AppTheme.primaryGreen,
                    ),
                    title: Text(
                      place.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: outside
                        ? Text(
                            place.where.isEmpty
                                ? 'Outside ${area.name}'
                                : '${place.where} · outside ${area.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: AppTheme.warning),
                          )
                        : place.where.isEmpty
                        ? null
                        : Text(
                            place.where,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    onTap: () {
                      FocusScope.of(context).unfocus();
                      _clear();
                      widget.onPicked(place);
                    },
                  );
                },
              ),
            ),
          ),
        ],
        if (_searched && _results.isEmpty && !_searching) ...[
          const SizedBox(height: AppSpacing.xs),
          Material(
            elevation: 3,
            borderRadius: BorderRadius.circular(AppRadius.md),
            color: Colors.white,
            child: const Padding(
              padding: EdgeInsets.all(AppSpacing.md),
              child: Text(
                'No places found. Try another name, or tap the map.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
