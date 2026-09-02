import 'dart:io';

import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

import '../models/table_config.dart';

/// "Geo Location" is not a real stored field format -- adding it (via
/// [AddFieldScreen]'s "Add Geo Location fields" button) creates four
/// genuinely ordinary `real` fields with these exact display names, per
/// Mike's own framing: "when you add that field to a record, what it
/// really does is add 4 decimal types." Nothing in the schema marks them
/// as a group afterward -- [geoLocationFieldsOf] re-derives the group
/// purely by matching these labels (case-insensitively), the same
/// "detect by name, not by a stored flag" heuristic this app already uses
/// elsewhere (e.g. `shipment`'s displayColumn/orderBy sentinels).
const List<String> geoLocationFieldLabels = ['Latitude', 'Longitude', 'Altitude', 'Accuracy'];

/// The optional field a "Capture location" button also fills, via reverse
/// geocoding, if present on the same table -- a plain multi-line `text`
/// field, matched the same way, not a new format either.
const String mapLocationFieldLabel = 'Map Location';

/// The four [FieldConfig]s making up a table's Geo Location group, if all
/// four are present -- see [geoLocationFieldsOf].
class GeoLocationFields {
  const GeoLocationFields({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.accuracy,
  });

  final FieldConfig latitude;
  final FieldConfig longitude;
  final FieldConfig altitude;
  final FieldConfig accuracy;

  /// Position in [fields] -- used to place the "Capture location" button
  /// right after whichever of the four sorts last in the form's own field
  /// order, so it still lands sensibly even if Mike reorders these fields
  /// individually later.
  int lastPosition(List<FieldConfig> fields) {
    var last = -1;
    for (final f in [latitude, longitude, altitude, accuracy]) {
      final index = fields.indexOf(f);
      if (index > last) last = index;
    }
    return last;
  }
}

/// Finds this table's Geo Location group, if it has all four fields --
/// `null` if any are missing (a table that only has some of the four, e.g.
/// one was renamed or deleted, just doesn't get the button; no error).
GeoLocationFields? geoLocationFieldsOf(List<FieldConfig> fields) {
  FieldConfig? find(String label) {
    for (final f in fields) {
      if (f.label.trim().toLowerCase() == label.toLowerCase()) return f;
    }
    return null;
  }

  final latitude = find('Latitude');
  final longitude = find('Longitude');
  final altitude = find('Altitude');
  final accuracy = find('Accuracy');
  if (latitude == null || longitude == null || altitude == null || accuracy == null) return null;
  return GeoLocationFields(
    latitude: latitude,
    longitude: longitude,
    altitude: altitude,
    accuracy: accuracy,
  );
}

/// The optional "Map Location" field, if present -- `null` otherwise, in
/// which case the capture button just skips reverse geocoding entirely
/// (per Mike's explicit ask), not an error.
FieldConfig? mapLocationFieldOf(List<FieldConfig> fields) {
  for (final f in fields) {
    if (f.label.trim().toLowerCase() == mapLocationFieldLabel.toLowerCase()) return f;
  }
  return null;
}

/// Android only -- there's no GPS hardware on the Windows desktop this app
/// also targets, so the "Capture location" button renders visible but
/// disabled everywhere else (Mike's explicit ask: don't hide it, show why
/// it's off), rather than only appearing on the one platform it works on.
bool get geoLocationCaptureSupported => Platform.isAndroid;

/// Thrown for any capture failure the button's own caller should show to
/// the user as a plain message (permission refused, location services off,
/// or the platform call itself failing) -- deliberately not a raw
/// exception string, so the caller doesn't need to know geolocator's own
/// exception types.
class GeoLocationCaptureException implements Exception {
  GeoLocationCaptureException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Requests permission (if not already granted) and takes one live GPS
/// reading. Never called on a non-Android platform -- see
/// [geoLocationCaptureSupported].
Future<Position> captureCurrentPosition() async {
  if (!await Geolocator.isLocationServiceEnabled()) {
    throw GeoLocationCaptureException('Location services are turned off on this device.');
  }
  var permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
  }
  if (permission == LocationPermission.denied) {
    throw GeoLocationCaptureException('Location permission was denied.');
  }
  if (permission == LocationPermission.deniedForever) {
    throw GeoLocationCaptureException(
      'Location permission is permanently denied -- allow it from this app\'s system settings.',
    );
  }
  return Geolocator.getCurrentPosition();
}

/// Reverse-geocodes into a short multi-line "street / city, state zip"
/// block for the Map Location field -- `null` if geocoding finds nothing
/// (a location with no known address, e.g. open ocean/wilderness), left to
/// the caller to treat as "nothing to fill," not an error.
Future<String?> reverseGeocodeToText(double latitude, double longitude) async {
  final placemarks = await placemarkFromCoordinates(latitude, longitude);
  if (placemarks.isEmpty) return null;
  final place = placemarks.first;

  String? clean(String? value) => (value != null && value.trim().isNotEmpty) ? value.trim() : null;

  // Android's on-device Geocoder (checked directly against
  // geocoding_android's own AddressMapper.java, which maps `locality` from
  // Address.getLocality() and `administrativeArea` from Address
  // .getAdminArea() 1:1, no extra parsing) doesn't always populate every
  // component for every location -- data completeness genuinely varies by
  // device/region/provider, not something this package or this app
  // controls. `subLocality`/`subAdministrativeArea` are tried as a city
  // fallback since they're commonly populated even when `locality` isn't;
  // there's no equivalent fallback for state/zip specifically -- if
  // `administrativeArea`/`postalCode` are genuinely absent from the
  // platform's own response, they just don't appear.
  final city = clean(place.locality) ?? clean(place.subLocality) ?? clean(place.subAdministrativeArea);
  final state = clean(place.administrativeArea);
  final zip = clean(place.postalCode);

  final stateZip = [state, zip].nonNulls.join(' ');
  final cityStateZip = [city, stateZip.isEmpty ? null : stateZip].nonNulls.join(', ');

  final lines = [
    if (clean(place.street) != null) place.street!.trim(),
    if (cityStateZip.isNotEmpty) cityStateZip,
  ];
  return lines.isEmpty ? null : lines.join('\n');
}
