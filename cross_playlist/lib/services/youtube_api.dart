import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../song.dart';

const String _youtubeDataApiKey = String.fromEnvironment(
  'YOUTUBE_DATA_API_KEY',
);

/// One row from YouTube search.
class YoutubeSearchVideo {
  const YoutubeSearchVideo({
    required this.videoId,
    required this.title,
    required this.channelTitle,
    this.thumbnailUrl,
    required this.watchUrl,
  });

  final String videoId;
  final String title;
  final String channelTitle;
  final String? thumbnailUrl;
  final String watchUrl;

  Song toSong() => Song(
    channelTitle,
    'YouTube',
    '',
    'YouTube',
    name: title,
    url: watchUrl,
    imageUrl: thumbnailUrl,
    previewUrl: null,
    youtubeVideoId: videoId,
  );
}

class YoutubeApi {
  static bool get isConfigured => _youtubeDataApiKey.isNotEmpty;

  /// Extracts an 11-character video id from common YouTube URL shapes.
  static String? parseVideoIdFromUrl(String url) {
    if (url.isEmpty) return null;
    final u = Uri.tryParse(url);
    if (u == null) return null;
    if (u.host.contains('youtu.be') && u.pathSegments.isNotEmpty) {
      return _normalizeId(u.pathSegments.first);
    }
    final v = u.queryParameters['v'];
    if (v != null && v.isNotEmpty) return _normalizeId(v);
    final embed = RegExp(r'youtube\.com/embed/([^?/]+)').firstMatch(url);
    if (embed != null) return _normalizeId(embed.group(1)!);
    return null;
  }

  static String? _normalizeId(String raw) {
    final m = RegExp(r'^([\w-]{11})\b').firstMatch(raw.trim());
    return m?.group(1);
  }

  /// Video id for in-app playback / Firestore round-trip.
  static String? videoIdForSong(Song song) {
    if (song.youtubeVideoId != null && song.youtubeVideoId!.isNotEmpty) {
      return song.youtubeVideoId;
    }
    return parseVideoIdFromUrl(song.url);
  }

  /// Search YouTube for videos (music-oriented query).
  static Future<List<YoutubeSearchVideo>> searchVideos(
    String query, {
    int maxResults = 15,
  }) async {
    if (!isConfigured) {
      debugPrint('YoutubeApi: set _youtubeDataApiKey in lib/services/youtube_api.dart');
      return [];
    }
    final q = query.trim();
    if (q.isEmpty) return [];

    final uri = Uri.https('www.googleapis.com', '/youtube/v3/search', {
      'part': 'snippet',
      'type': 'video',
      'videoEmbeddable': 'true',
      'maxResults': '$maxResults',
      'q': q,
      'safeSearch': 'moderate',
      'key': _youtubeDataApiKey,
    });

    try {
      final res = await http.get(uri);
      if (res.statusCode != 200) {
        debugPrint('YoutubeApi: HTTP ${res.statusCode} ${res.body}');
        return [];
      }
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final items = body['items'] as List<dynamic>? ?? [];
      final candidates = <YoutubeSearchVideo>[];
      for (final raw in items) {
        final m = raw as Map<String, dynamic>;
        final id = m['id'] as Map<String, dynamic>?;
        final videoId = id?['videoId'] as String?;
        if (videoId == null || videoId.isEmpty) continue;
        final sn = m['snippet'] as Map<String, dynamic>?;
        if (sn == null) continue;
        final title = sn['title'] as String? ?? 'Untitled';
        final channel = sn['channelTitle'] as String? ?? 'Unknown channel';
        final thumbs = sn['thumbnails'] as Map<String, dynamic>?;
        String? thumbUrl;
        if (thumbs != null) {
          final def = thumbs['default'] as Map<String, dynamic>?;
          final medium = thumbs['medium'] as Map<String, dynamic>?;
          thumbUrl = (medium?['url'] ?? def?['url']) as String?;
        }
        candidates.add(
          YoutubeSearchVideo(
            videoId: videoId,
            title: title,
            channelTitle: channel,
            thumbnailUrl: thumbUrl,
            watchUrl: 'https://www.youtube.com/watch?v=$videoId',
          ),
        );
      }

      if (candidates.isEmpty) return candidates;

      // Confirm embeddability with a second call. If the call itself
      // fails (network error, quota, etc.) we fall back to the
      // unfiltered list as best-effort; but if it succeeds and reports
      // none are embeddable we trust that result and return [].
      try {
        final result = await _filterEmbeddable(
          candidates.map((c) => c.videoId).toList(),
        );
        if (result != null) {
          return candidates.where((c) => result.contains(c.videoId)).toList();
        }
      } catch (e) {
        debugPrint('YoutubeApi: embeddable filter failed: $e');
      }
      return candidates;
    } catch (e, st) {
      debugPrint('YoutubeApi: $e\n$st');
      return [];
    }
  }

  /// Returns the subset of [videoIds] whose `status.embeddable` is true,
  /// or `null` if the API call itself failed (so the caller can decide
  /// whether to fall back to unfiltered results).
  static Future<Set<String>?> _filterEmbeddable(List<String> videoIds) async {
    if (videoIds.isEmpty) return <String>{};
    final uri = Uri.https('www.googleapis.com', '/youtube/v3/videos', {
      'part': 'status',
      'id': videoIds.join(','),
      'key': _youtubeDataApiKey,
    });
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      debugPrint('YoutubeApi: videos.list HTTP ${res.statusCode} ${res.body}');
      return null;
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final items = body['items'] as List<dynamic>? ?? [];
    final out = <String>{};
    for (final raw in items) {
      final m = raw as Map<String, dynamic>;
      final id = m['id'] as String?;
      final status = m['status'] as Map<String, dynamic>?;
      if (id != null && status != null && status['embeddable'] == true) {
        out.add(id);
      }
    }
    return out;
  }
}
