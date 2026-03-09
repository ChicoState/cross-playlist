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

  const SpotifyTrack({
    required this.id,
    required this.name,
    required this.artist,
    required this.album,
    this.imageUrl,
    required this.spotifyUrl,
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

    return SpotifyTrack(
      id: json['id'] as String,
      name: json['name'] as String,
      artist: artistName,
      album: albumName,
      imageUrl: imageUrl,
      spotifyUrl: spotifyUrl,
    );
  }
}

/// Search Spotify for tracks using the Web API.
class SpotifyApi {
  static const String _baseUrl = 'https://api.spotify.com/v1';

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
}
