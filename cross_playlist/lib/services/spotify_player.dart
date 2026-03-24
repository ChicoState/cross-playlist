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

  final _playbackStateController = StreamController<PlaybackState>.broadcast();
  Stream<PlaybackState> get playbackState => _playbackStateController.stream;

  bool get isReady => _isReady;
  bool get isPlaying => _isPlaying;
  String? get currentTrackUri => _currentTrackUri;
  String? get deviceId => _deviceId;

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

      // Poll until window.Spotify is set by onSpotifyWebPlaybackSDKReady
      int attempts = 0;
      while (js.context['Spotify'] == null && attempts < 20) {
        await Future.delayed(const Duration(milliseconds: 500));
        attempts++;
      }

      if (js.context['Spotify'] == null) {
        debugPrint('SpotifyPlayer: Spotify SDK not available after 10s');
        return;
      }

      // Build options as JsObject, jsify() silently drops Dart functions
      final playerOptions = js.JsObject.jsify({
        'name': 'Cross-Playlist Web Player',
        'volume': 0.5,
      });
      // Spotify SDK calls getOAuthToken(resolve, reject) with 2 args internally.
      // We accept both but only use the first (the cb we call with the token).
      playerOptions['getOAuthToken'] = js.allowInterop((dynamic cb, dynamic _) async {
        final t = await SpotifyAuth.accessToken;
        (cb as js.JsFunction).apply([t]);
      });

      // Construct new Spotify.Player(playerOptions)
      final spotifyPlayer = js.context['Spotify']['Player'] as js.JsFunction;
      _player = js.JsObject(spotifyPlayer, [playerOptions]);

      _setupEventListeners();

      // connect() fires and the 'ready' listener handles the result don't await the promise
      _player!.callMethod('connect', []);
      debugPrint('SpotifyPlayer: SDK connecting, waiting for ready event...');
    } catch (e) {
      debugPrint('SpotifyPlayer: Initialization error: $e');
    }
  }

  void _setupEventListeners() {
    final p = _player!;

    p.callMethod('addListener', [
      'ready',
      js.allowInterop((js.JsObject data) {
        _deviceId = data['device_id'] as String;
        _isReady = true;
        debugPrint('SpotifyPlayer: Ready! Device ID: $_deviceId');
        _playbackStateController.add(PlaybackState.ready);
      }),
    ]);

    p.callMethod('addListener', [
      'not_ready',
      js.allowInterop((js.JsObject data) {
        _isReady = false;
        debugPrint('SpotifyPlayer: Device went offline');
        _playbackStateController.add(PlaybackState.notReady);
      }),
    ]);

    p.callMethod('addListener', [
      'player_state_changed',
      js.allowInterop((state) {
        if (state == null) return;
        final s = state as js.JsObject;

        _isPlaying = !(s['paused'] as bool);

        final trackWindow = s['track_window'] as js.JsObject?;
        final currentTrack = trackWindow?['current_track'] as js.JsObject?;
        if (currentTrack != null) {
          _currentTrackUri = currentTrack['uri'] as String?;
        }

        _playbackStateController
            .add(_isPlaying ? PlaybackState.playing : PlaybackState.paused);
      }),
    ]);

    for (final event in [
      'initialization_error',
      'authentication_error',
      'account_error',
      'playback_error',
    ]) {
      p.callMethod('addListener', [
        event,
        js.allowInterop((js.JsObject err) {
          final message = err['message'];
          debugPrint('SpotifyPlayer [$event]: $message');
        }),
      ]);
    }
  }

  /// Play a track by Spotify URI (e.g., 'spotify:track:xxxx').
  Future<void> playTrack(String trackUri) async {
    if (!_isReady || _deviceId == null) {
      debugPrint('SpotifyPlayer: Not ready to play');
      return;
    }

    final token = await SpotifyAuth.accessToken;
    if (token == null) return;

    try {
      debugPrint('SpotifyPlayer: Playing $trackUri on device $_deviceId');

      final response = await http.put(
        Uri.parse(
            'https://api.spotify.com/v1/me/player/play?device_id=$_deviceId'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: '{"uris":["$trackUri"]}',
      );

      if (response.statusCode == 204 || response.statusCode == 202) {
        debugPrint('SpotifyPlayer: Started playback');
        _currentTrackUri = trackUri;
      } else {
        debugPrint(
            'SpotifyPlayer: Play failed (${response.statusCode}): ${response.body}');
      }
    } catch (e) {
      debugPrint('SpotifyPlayer: Play error: $e');
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
  }
}

enum PlaybackState { notReady, ready, playing, paused }
