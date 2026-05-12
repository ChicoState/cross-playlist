import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'spotify_auth.dart';

/// A simple result from a Spotify track search.
class SpotifyTrack {
  final String id;
  final String name;
  final String artist;
  final String album;
  final String? imageUrl;
  final String spotifyUrl;
  final String? previewUrl; // 30-second MP3 preview

  const SpotifyTrack({
    required this.id,
    required this.name,
    required this.artist,
    required this.album,
    this.imageUrl,
    required this.spotifyUrl,
    this.previewUrl,
  });

  factory SpotifyTrack.fromJson(Map<String, dynamic> json) {
    final artists = json['artists'] as List<dynamic>;
    final artistName =
        artists.isNotEmpty ? artists[0]['name'] as String : 'Unknown Artist';

    final albumJson = json['album'] as Map<String, dynamic>;
    final albumName = albumJson['name'] as String? ?? 'Unknown Album';

    final images = albumJson['images'] as List<dynamic>?;
    String? imageUrl;
    if (images != null && images.isNotEmpty) {
      // Pick the smallest image (last in the list) for thumbnails
      imageUrl = images.last['url'] as String;
    }

    final externalUrls = json['external_urls'] as Map<String, dynamic>?;
    final spotifyUrl = externalUrls?['spotify'] as String? ?? '';
    final previewUrl = json['preview_url'] as String?;

    return SpotifyTrack(
      id: json['id'] as String,
      name: json['name'] as String,
      artist: artistName,
      album: albumName,
      imageUrl: imageUrl,
      spotifyUrl: spotifyUrl,
      previewUrl: previewUrl,
    );
  }
}

/// Search Spotify for tracks using the Web API.
class SpotifyApi {
  static const String _baseUrl = 'https://api.spotify.com/v1';

  static int _parseInt(dynamic value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  static Map<String, dynamic>? _extractTrackJson(dynamic playlistItem) {
    if (playlistItem is! Map<String, dynamic>) return null;

    final track = playlistItem['track'];
    if (track is Map<String, dynamic> && track['id'] != null) {
      return track;
    }

    // Newer endpoint shape may use `item` instead of `track`.
    final item = playlistItem['item'];
    if (item is Map<String, dynamic> &&
        item['id'] != null &&
        (item['type'] == null || item['type'] == 'track')) {
      return item;
    }

    return null;
  }

  /// Search for tracks matching [query].
  /// Returns an empty list if not connected or the request fails.
  static Future<List<SpotifyTrack>> searchTracks(String query,
      {int limit = 10}) async {
    final token = await SpotifyAuth.accessToken;
    if (token == null) {
      debugPrint('SpotifyApi: Not connected – cannot search');
      return [];
    }

    try {
      final url = Uri.parse('$_baseUrl/search').replace(queryParameters: {
        'q': query,
        'type': 'track',
        'limit': limit.toString(),
      });

      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final tracks = body['tracks'] as Map<String, dynamic>;
        final items = tracks['items'] as List<dynamic>;
        return items
            .map((item) =>
                SpotifyTrack.fromJson(item as Map<String, dynamic>))
            .toList();
      } else {
        debugPrint(
            'SpotifyApi: Search failed (${response.statusCode}): '
            '${response.body}');
        return [];
      }
    } catch (e) {
      debugPrint('SpotifyApi: Search error: $e');
      return [];
    }
  }

  /// Fetch the current user's Spotify playlists.
  static Future<List<SpotifyPlaylistMeta>> getUserPlaylists() async {
    final token = await SpotifyAuth.accessToken;
    if (token == null) return [];

    try {
      final url = Uri.parse('$_baseUrl/me/playlists').replace(queryParameters: {
        'limit': '50',
      });
      final response = await http.get(
        url,
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final items = body['items'] as List<dynamic>;
        return items
            .map((item) =>
                SpotifyPlaylistMeta.fromJson(item as Map<String, dynamic>))
            .toList();
      } else {
        debugPrint('SpotifyApi: getUserPlaylists failed '
            '(${response.statusCode}): ${response.body}');
        return [];
      }
    } catch (e) {
      debugPrint('SpotifyApi: getUserPlaylists error: $e');
      return [];
    }
  }

  /// Fetch all tracks from a Spotify playlist by [playlistId].
  static Future<List<SpotifyTrack>> getPlaylistTracks(String playlistId) async {
    final token = await SpotifyAuth.accessToken;
    if (token == null) return [];

    final List<SpotifyTrack> allTracks = [];

    // First try the modern playlist items endpoint.
    String? nextUrl = Uri.parse('$_baseUrl/playlists/$playlistId/items')
        .replace(queryParameters: {
      'limit': '50',
      'market': 'from_token',
    }).toString();

    try {
      while (nextUrl != null) {
        // Re-fetch token each iteration in case it was refreshed
        final currentToken = await SpotifyAuth.accessToken;
        if (currentToken == null) break;

        final response = await http.get(
          Uri.parse(nextUrl),
          headers: {'Authorization': 'Bearer $currentToken'},
        );

        if (response.statusCode == 403) {
          final authHeader = response.headers['www-authenticate'];
          debugPrint('SpotifyApi: getPlaylistTracks 403 on items endpoint, '
              'trying full playlist endpoint... body=${response.body} '
              'www-authenticate=$authHeader');
          // Fallback: fetch the full playlist object
          return _getPlaylistTracksFallback(playlistId);
        }

        if (response.statusCode != 200) {
          debugPrint('SpotifyApi: getPlaylistTracks failed '
              '(${response.statusCode}): ${response.body}');
          break;
        }

        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final items = body['items'] as List<dynamic>? ?? const [];
        for (final item in items) {
          final trackJson = _extractTrackJson(item);
          if (trackJson != null) {
            allTracks.add(SpotifyTrack.fromJson(trackJson));
          }
        }
        nextUrl = body['next'] as String?;
      }
    } catch (e) {
      debugPrint('SpotifyApi: getPlaylistTracks error: $e');
    }

    return allTracks;
  }

  /// Fallback: fetch tracks via GET /playlists/{id} which returns the
  /// first page of tracks embedded in the response.
  static Future<List<SpotifyTrack>> _getPlaylistTracksFallback(
      String playlistId) async {
    final List<SpotifyTrack> allTracks = [];
    try {
      final token = await SpotifyAuth.accessToken;
      if (token == null) return [];

      final fallbackUrl = Uri.parse('$_baseUrl/playlists/$playlistId').replace(
        queryParameters: {
          // Keep payload small while still including first page of tracks.
          'fields':
              'id,name,tracks(items(track(id,name,artists(name),album(name,images),external_urls,preview_url),item(id,type,name,artists(name),album(name,images),external_urls,preview_url)),next)',
          'market': 'from_token',
        },
      );

      final response = await http.get(
        fallbackUrl,
        headers: {'Authorization': 'Bearer $token'},
      );

      if (response.statusCode != 200) {
        final authHeader = response.headers['www-authenticate'];
        debugPrint('SpotifyApi: playlist fallback failed '
            '(${response.statusCode}): ${response.body} '
            'www-authenticate=$authHeader');
        return [];
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final tracksObj = body['tracks'] as Map<String, dynamic>?;
      if (tracksObj == null) return [];

      final items = tracksObj['items'] as List<dynamic>? ?? const [];
      for (final item in items) {
        final trackJson = _extractTrackJson(item);
        if (trackJson != null) {
          allTracks.add(SpotifyTrack.fromJson(trackJson));
        }
      }

      // Handle pagination via the tracks.next URL
      String? nextUrl = tracksObj['next'] as String?;
      while (nextUrl != null) {
        final t = await SpotifyAuth.accessToken;
        if (t == null) break;
        final resp = await http.get(
          Uri.parse(nextUrl),
          headers: {'Authorization': 'Bearer $t'},
        );
        if (resp.statusCode != 200) {
          debugPrint('SpotifyApi: playlist fallback pagination failed '
              '(${resp.statusCode}): ${resp.body}');
          break;
        }
        final b = jsonDecode(resp.body) as Map<String, dynamic>;
        final its = b['items'] as List<dynamic>? ?? const [];
        for (final item in its) {
          final trackJson = _extractTrackJson(item);
          if (trackJson != null) {
            allTracks.add(SpotifyTrack.fromJson(trackJson));
          }
        }
        nextUrl = b['next'] as String?;
      }
    } catch (e) {
      debugPrint('SpotifyApi: playlist fallback error: $e');
    }
    return allTracks;
  }
}

/// Lightweight metadata for a Spotify playlist.
class SpotifyPlaylistMeta {
  final String id;
  final String name;
  final int trackCount;
  final String? imageUrl;

  const SpotifyPlaylistMeta({
    required this.id,
    required this.name,
    required this.trackCount,
    this.imageUrl,
  });

  factory SpotifyPlaylistMeta.fromJson(Map<String, dynamic> json) {
    final images = json['images'] as List<dynamic>?;
    String? imageUrl;
    if (images != null && images.isNotEmpty) {
      imageUrl = images.first['url'] as String?;
    }
    final tracks = json['tracks'] as Map<String, dynamic>?;
    return SpotifyPlaylistMeta(
      id: json['id'] as String,
      name: json['name'] as String? ?? 'Untitled',
      trackCount: SpotifyApi._parseInt(tracks?['total']),
      imageUrl: imageUrl,
    );
  }
}
