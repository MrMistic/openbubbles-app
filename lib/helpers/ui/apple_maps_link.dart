import 'dart:io';

import 'package:bluebubbles/app/layouts/findmy/findmy_page.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

/// Helpers for handling `maps.apple.com` and `maps.apple` links received in chats.
///
/// Apple Maps deep-links are useless on Android (no Apple Maps app), so instead of launching
/// them externally we parse out the coordinates and open the in-app Find My map centered on
/// them with a dropped pin. When a link carries only a place name (no coordinates) and we
/// can't resolve it, the caller should fall back to opening it externally.
///
/// Two link formats exist:
///   - Full: `https://maps.apple.com/?ll=LAT,LON...` or `maps.apple.com/place?coordinate=LAT,LON...`
///   - Short: `https://maps.apple/p/<opaque-id>` (301-redirects to the full format)
class AppleMapsLink {
  /// Returns true if [url] is an Apple Maps link we know how to handle.
  static bool isAppleMapsLink(String url) {
    final uri = Uri.tryParse(_normalize(url));
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host == "maps.apple.com" || host == "maps.apple";
  }

  /// Resolves the link: for short `/p/...` links, follows the 301 redirect to obtain the
  /// full URL. For already-full links, returns the URL unchanged. Returns null on failure.
  /// This is the entry point the tap handler should call to get coordinates.
  static Future<ResolvedAppleMapsLink?> resolve(String url) async {
    url = _normalize(url);
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    String resolvedUrl = url;

    // Short-link format: maps.apple/p/<id> — follow the 301 to get the real URL.
    if (uri.host.toLowerCase() == "maps.apple" && uri.path.startsWith("/p/")) {
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 5);
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close();
        final location = response.headers.value(HttpHeaders.locationHeader);
        client.close(force: true);
        if (location != null && location.isNotEmpty) {
          resolvedUrl = location;
        } else {
          return null;
        }
      } catch (_) {
        return null;
      }
    }

    final resolvedUri = Uri.tryParse(resolvedUrl);
    if (resolvedUri == null) return null;

    final coords = _parseCoords(resolvedUri);
    if (coords == null) return null;

    return ResolvedAppleMapsLink(
      coords: coords,
      label: _parseLabel(resolvedUri),
    );
  }

  /// Opens the in-app Find My map at [coords]. Returns once navigation is pushed.
  static Future<void> openInFindMy(BuildContext context, LatLng coords, {String? label}) async {
    await Navigator.of(context).push(
      ThemeSwitcher.buildPageRoute(
        builder: (_) => FindMyPage(initialLocation: coords, initialLabel: label),
      ),
    );
  }

  // --- private helpers ---

  static String _normalize(String url) {
    if (!url.startsWith("http://") && !url.startsWith("https://")) {
      return "https://$url";
    }
    return url;
  }

  /// Parse coordinates from the resolved URL. Checks `coordinate`, `ll`, `q`, `sll`, `center`.
  static LatLng? _parseCoords(Uri uri) {
    for (final param in const ["coordinate", "ll", "q", "sll", "center"]) {
      final value = uri.queryParameters[param];
      final coord = _parseLatLon(value);
      if (coord != null) return coord;
    }
    return null;
  }

  /// Parse the human-readable label from `name`, `q` (non-coordinate), or `address`.
  static String? _parseLabel(Uri uri) {
    for (final param in const ["name", "q", "address"]) {
      final value = uri.queryParameters[param];
      if (value != null && value.isNotEmpty && _parseLatLon(value) == null) {
        return value;  // queryParameters already decodes percent-encoding
      }
    }
    return null;
  }

  static LatLng? _parseLatLon(String? value) {
    if (value == null) return null;
    final parts = value.split(",");
    if (parts.length != 2) return null;
    final lat = double.tryParse(parts[0].trim());
    final lon = double.tryParse(parts[1].trim());
    if (lat == null || lon == null) return null;
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return LatLng(lat, lon);
  }
}

class ResolvedAppleMapsLink {
  final LatLng coords;
  final String? label;
  ResolvedAppleMapsLink({required this.coords, this.label});
}
