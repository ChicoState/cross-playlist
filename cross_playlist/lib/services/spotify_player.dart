import 'dart:async';
import 'dart:js' as js;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'spotify_auth.dart';

/// Manages Spotify Web Playback SDK for full song playback (Premium only).
class SpotifyPlayer {
  static SpotifyPlayer? _instance;
  static SpotifyPlayer get instance => _instance ??= SpotifyPlayer._();

  SpotifyPlayer._();

  js.JsObject? _player;
  String? _deviceId;
  bool _isReady = false;
  bool _isPlaying = false;
  String? _currentTrackUri;

  // 🔥 ADD THESE (needed for scrubber)
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  final _playbackStateController = StreamController<PlaybackState>.broadcast();
  Stream<PlaybackState> get playbackState => _playbackStateController.stream;

  bool get isReady => _isReady;
  bool get isPlaying => _isPlaying;
  String? get currentTrackUri => _currentTrackUri;
  String? get deviceId => _deviceId;

  // 🔥 ADD THESE GETTERS
  Duration get position => _position;
  Duration get duration => _duration;

  /// Initialize the Spotify Web Playback SDK.
  Future<void> initialize() async {
    if (_isReady) {
      debugPrint('SpotifyPlayer: Already initialized');
      return;
    }

    final token = await SpotifyAuth.accessToken;
    if (token == null) {
      debugPrint('SpotifyPlayer: No access token');
      return;
    }

    try {
      debugPrint('SpotifyPlayer: Initializing...');

      int attempts = 0;
      while (js.context['Spotify'] == null && attempts < 20) {
        await Future.delayed(const Duration(milliseconds: 500));
        attempts++;
      }

      if (js.context['Spotify'] == null) {
        debugPrint('SpotifyPlayer: Spotify SDK not available after 10s');
        return;
      }

      final playerOptions = js.JsObject.jsify({
        'name': 'Cross-Playlist Web Player',
        'volume': 0.5,
      });

      playerOptions['getOAuthToken'] = js.allowInterop((
        dynamic cb,
        dynamic _,
      ) async {
        final t = await SpotifyAuth.accessToken;
        (cb as js.JsFunction).apply([t]);
      });

      final spotifyPlayer = js.context['Spotify']['Player'] as js.JsFunction;
      _player = js.JsObject(spotifyPlayer, [playerOptions]);

      _setupEventListeners();

      _player!.callMethod('connect', []);
      debugPrint('SpotifyPlayer: SDK connecting...');
    } catch (e) {
      debugPrint('SpotifyPlayer: Initialization error: $e');
    }
  }

  void _setupEventListeners() {
    final p = _player!;

    // READY
    p.callMethod('addListener', [
      'ready',
      js.allowInterop((js.JsObject data) {
        _deviceId = data['device_id'] as String;
        _isReady = true;
        debugPrint('SpotifyPlayer: Ready! Device ID: $_deviceId');
        _playbackStateController.add(PlaybackState.ready);
      }),
    ]);

    // NOT READY
    p.callMethod('addListener', [
      'not_ready',
      js.allowInterop((_) {
        _isReady = false;
        debugPrint('SpotifyPlayer: Device went offline');
        _playbackStateController.add(PlaybackState.notReady);
      }),
    ]);

    // 🔥 STATE CHANGED (THIS POWERS SCRUBBER)
    p.callMethod('addListener', [
      'player_state_changed',
      js.allowInterop((state) {
        if (state == null) return;
        final s = state as js.JsObject;

        _isPlaying = !(s['paused'] as bool);

        // 🔥 ADD THIS (position + duration)
        final positionMs = s['position'] as num? ?? 0;
        final durationMs = s['duration'] as num? ?? 0;

        _position = Duration(milliseconds: positionMs.toInt());
        _duration = Duration(milliseconds: durationMs.toInt());

        final trackWindow = s['track_window'] as js.JsObject?;
        final currentTrack = trackWindow?['current_track'] as js.JsObject?;
        if (currentTrack != null) {
          _currentTrackUri = currentTrack['uri'] as String?;
        }

        _playbackStateController.add(
          _isPlaying ? PlaybackState.playing : PlaybackState.paused,
        );
      }),
    ]);

    // ERRORS
    for (final event in [
      'initialization_error',
      'authentication_error',
      'account_error',
      'playback_error',
    ]) {
      p.callMethod('addListener', [
        event,
        js.allowInterop((js.JsObject err) {
          debugPrint('SpotifyPlayer [$event]: ${err['message']}');
        }),
      ]);
    }
  }

  /// Play a track
  Future<void> playTrack(String trackUri) async {
    if (!_isReady || _deviceId == null) {
      debugPrint('SpotifyPlayer: Not ready to play');
      return;
    }

    final token = await SpotifyAuth.accessToken;
    if (token == null) return;

    try {
      debugPrint('SpotifyPlayer: Playing $trackUri');

      final response = await http.put(
        Uri.parse(
          'https://api.spotify.com/v1/me/player/play?device_id=$_deviceId',
        ),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: '{"uris":["$trackUri"]}',
      );

      if (response.statusCode == 204 || response.statusCode == 202) {
        _currentTrackUri = trackUri;
        debugPrint('SpotifyPlayer: Playback started');
      } else {
        debugPrint('SpotifyPlayer: Play failed ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('SpotifyPlayer: Play error: $e');
    }
  }

  // 🔥 THIS IS THE MISSING PIECE FOR SCRUBBING
  Future<void> seek(int positionMs) async {
    if (_player == null || !_isReady) return;

    try {
      _player!.callMethod('seek', [positionMs]);
      _position = Duration(milliseconds: positionMs);
      debugPrint('SpotifyPlayer: Seek -> $positionMs ms');
    } catch (e) {
      debugPrint('SpotifyPlayer: Seek error: $e');
    }
  }

  void resume() {
    if (_player == null || !_isReady) return;
    _player!.callMethod('resume', []);
  }

  void pause() {
    if (_player == null || !_isReady) return;
    _player!.callMethod('pause', []);
  }

  void dispose() {
    _player?.callMethod('disconnect', []);
    _playbackStateController.close();
    _isReady = false;
    _deviceId = null;
    _player = null;
    _position = Duration.zero;
    _duration = Duration.zero;
  }
}

enum PlaybackState { notReady, ready, playing, paused }
