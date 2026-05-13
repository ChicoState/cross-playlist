import 'dart:async';
import 'dart:html' as html;
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'song.dart';
import 'services/spotify_player.dart';
import 'services/youtube_api.dart';
import 'services/youtube_web_player.dart';

String? spotifyTrackUriFromUrl(String url) {
  if (url.isEmpty) return null;
  final match = RegExp(r'track/([a-zA-Z0-9]+)').firstMatch(url);
  if (match != null) return 'spotify:track:${match.group(1)}';
  return null;
}

/// Drives playlist playback (Spotify Web Playback or HTML audio),
/// queue, shuffle, and auto-advance. Use [attach] from the active [Playlist] state.
class PlaylistPlaybackController extends ChangeNotifier {
  List<Song> Function()? _songsProvider;
  String? _playlistId;
  StreamSubscription<PlaybackState>? _spotifySub;
  html.AudioElement? _previewAudio;
  StreamSubscription<html.Event>? _previewTimeSub;
  StreamSubscription<html.Event>? _previewEndedSub;
  StreamSubscription<html.Event>? _previewMetaSub;
  Timer? _endDebounce;

  List<int> _queue = [];
  int _cursor = 0;
  bool _shuffle = false;
  bool _isPlaying = false;
  bool _scrubbing = false;

  bool _usingSpotifyFull = false;
  bool _usingYoutube = false;
  bool _usingYoutubeWeb = false;
  StreamSubscription<YoutubeWebPlayerState>? _youtubeWebSub;
  StreamSubscription<int>? _youtubeWebErrSub;
  Timer? _youtubePositionTicker;

  /// Surface YouTube error codes (e.g. 150 = non-embeddable) to the UI.
  /// Cleared on the next successful track start.
  String? _youtubeError;
  String? get youtubeError => _youtubeError;

  Duration _previewPosition = Duration.zero;
  Duration _previewDuration = Duration.zero;

  bool get shuffleEnabled => _shuffle;
  bool get isPlaying => _isPlaying;
  bool get scrubbing => _scrubbing;
  bool get showMiniPlayer => _queue.isNotEmpty;
  bool get usingYoutubeWeb => _usingYoutubeWeb;

  int? get currentPlaylistIndex =>
      (_queue.isNotEmpty && _cursor >= 0 && _cursor < _queue.length)
      ? _queue[_cursor]
      : null;

  Song? get currentSong {
    final list = _songsProvider?.call();
    final pi = currentPlaylistIndex;
    if (list == null || pi == null || pi < 0 || pi >= list.length) return null;
    return list[pi];
  }

  Duration get position {
    if (_usingSpotifyFull && SpotifyPlayer.instance.isReady) {
      return SpotifyPlayer.instance.position;
    }
    return _previewPosition;
  }

  Duration get duration {
    if (_usingSpotifyFull && SpotifyPlayer.instance.isReady) {
      return SpotifyPlayer.instance.duration;
    }
    return _previewDuration;
  }

  bool isCurrentIndex(int playlistIndex) =>
      currentPlaylistIndex == playlistIndex;

  void attach(String playlistId, List<Song> Function() songsProvider) {
    if (_playlistId != null && _playlistId != playlistId) {
      stop();
    }
    _playlistId = playlistId;
    _songsProvider = songsProvider;
  }

  void detach() {
    _playlistId = null;
    _songsProvider = null;
  }

  void _listenSpotify() {
    _spotifySub?.cancel();
    _spotifySub = SpotifyPlayer.instance.playbackState.listen((state) {
      if (!_usingSpotifyFull) return;
      final nowPlaying = state == PlaybackState.playing;
      if (_isPlaying && !nowPlaying) {
        final dur = SpotifyPlayer.instance.duration;
        final pos = SpotifyPlayer.instance.position;
        if (dur.inMilliseconds > 0 &&
            pos >= dur - const Duration(milliseconds: 1200) &&
            pos <= dur + const Duration(seconds: 2)) {
          _onTrackEnded();
        }
      }
      _isPlaying = nowPlaying;
      notifyListeners();
    });
  }

  List<Song> get _songs => _songsProvider?.call() ?? [];

  Future<void> _disposeYoutube() async {
    _youtubeWebSub?.cancel();
    _youtubeWebSub = null;
    _youtubeWebErrSub?.cancel();
    _youtubeWebErrSub = null;
    _youtubePositionTicker?.cancel();
    _youtubePositionTicker = null;
    if (_usingYoutubeWeb) {
      try {
        await YoutubeWebPlayer.instance.stop();
      } catch (_) {
        // best-effort
      }
    }
    _usingYoutubeWeb = false;
    _usingYoutube = false;
  }

  Future<void> _setupYoutubeWeb(String videoId) async {
    debugPrint('Setting up YouTube web audio for video: $videoId');
    try {
      _tearDownPreview();
      // Don't fully dispose the underlying JS player: reusing the same
      // YT.Player across track changes is faster and avoids re-creating
      // the iframe (which costs ~1s and triggers an autoplay-policy
      // re-check). Just cancel our subscriptions/ticker.
      _youtubeWebSub?.cancel();
      _youtubeWebSub = null;
      _youtubeWebErrSub?.cancel();
      _youtubeWebErrSub = null;
      _youtubePositionTicker?.cancel();
      _youtubePositionTicker = null;

      final player = YoutubeWebPlayer.instance;

      _usingYoutube = true;
      _usingYoutubeWeb = true;
      _isPlaying = true;
      _youtubeError = null;
      _previewPosition = Duration.zero;
      _previewDuration = Duration.zero;

      _youtubeWebErrSub = player.errorStream.listen((code) {
        // 101 / 150 – owner disallows embedded playback.
        // 100        – video removed / made private.
        //   2 /   5 – generic; usually means we can't recover for this id.
        final message = switch (code) {
          101 || 150 => 'This video can\'t be played in embedded players. Skipping.',
          100 => 'Video unavailable. Skipping.',
          _ => 'YouTube playback error ($code). Skipping.',
        };
        debugPrint('PlaylistPlaybackController: YouTube error $code – $message');
        _youtubeError = message;
        notifyListeners();
        // Try the next track in the queue rather than getting stuck.
        _onTrackEnded();
      });

      _youtubeWebSub = player.stateStream.listen((state) {
        switch (state) {
          case YoutubeWebPlayerState.playing:
            if (!_isPlaying) {
              _isPlaying = true;
              notifyListeners();
            }
            // Make sure the iframe isn't muted by browser autoplay policy.
            unawaited(player.setVolume(100));
            break;
          case YoutubeWebPlayerState.paused:
          case YoutubeWebPlayerState.buffering:
          case YoutubeWebPlayerState.cued:
          case YoutubeWebPlayerState.unstarted:
            if (state == YoutubeWebPlayerState.paused && _isPlaying) {
              _isPlaying = false;
              notifyListeners();
            }
            break;
          case YoutubeWebPlayerState.ended:
            _isPlaying = false;
            _onTrackEnded();
            break;
          case YoutubeWebPlayerState.error:
            _isPlaying = false;
            notifyListeners();
            break;
        }
      });

      _youtubePositionTicker = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) {
          if (!_usingYoutubeWeb) return;
          final cur = player.currentTime;
          final dur = player.duration;
          var changed = false;
          if (dur > 0) {
            final newDur = Duration(milliseconds: (dur * 1000).round());
            if (newDur != _previewDuration) {
              _previewDuration = newDur;
              changed = true;
            }
          }
          if (!_scrubbing) {
            final newPos = Duration(milliseconds: (cur * 1000).round());
            if (newPos != _previewPosition) {
              _previewPosition = newPos;
              changed = true;
            }
          }
          if (changed) notifyListeners();
        },
      );

      // Surface the cover art / mini player immediately while the iframe
      // boots up; otherwise the user sees nothing happen for a moment.
      notifyListeners();

      await player.load(videoId);
      // Defensive: some browsers ignore the implicit autoplay from
      // loadVideoById when the iframe was just created. Calling play()
      // from the same user-gesture-derived async chain reliably starts.
      await player.play();
      await player.setVolume(100);
    } catch (e) {
      debugPrint('Error setting up YouTube web audio: $e');
      await _disposeYoutube();
      notifyListeners();
    }
  }

  void _buildQueueStartingAt(int startIndex) {
    final songs = _songs;
    final n = songs.length;
    if (n == 0 || startIndex < 0 || startIndex >= n) {
      _queue = [];
      return;
    }
    if (_shuffle) {
      final rest = List<int>.generate(n, (i) => i)..remove(startIndex);
      rest.shuffle(Random());
      _queue = [startIndex, ...rest];
    } else {
      _queue = List<int>.generate(n - startIndex, (i) => startIndex + i);
    }
  }

  Future<void> playFromPlaylistIndex(int index) async {
    final songs = _songs;
    if (index < 0 || index >= songs.length) return;
    _endDebounce?.cancel();
    _cursor = 0;
    _buildQueueStartingAt(index);
    if (_queue.isEmpty) return;
    await _playCurrent();
    notifyListeners();
  }

  Future<void> togglePlayPauseForIndex(int index) async {
    if (isCurrentIndex(index)) {
      await togglePlayPause();
      return;
    }
    await playFromPlaylistIndex(index);
  }

  Future<void> togglePlayPause() async {
    if (_queue.isEmpty) return;
    if (_usingSpotifyFull && SpotifyPlayer.instance.isReady) {
      if (_isPlaying) {
        SpotifyPlayer.instance.pause();
      } else {
        SpotifyPlayer.instance.resume();
      }
      return;
    }
    if (_usingYoutubeWeb) {
      if (_isPlaying) {
        await YoutubeWebPlayer.instance.pause();
      } else {
        await YoutubeWebPlayer.instance.play();
      }
      _isPlaying = !_isPlaying;
      notifyListeners();
      return;
    }
    if (_previewAudio != null) {
      if (_isPlaying) {
        _previewAudio!.pause();
      } else {
        await _previewAudio!.play();
      }
      _isPlaying = !_previewAudio!.paused;
      notifyListeners();
    }
  }

  Future<void> _setupYoutube(String videoId) async {
    debugPrint('Setting up YouTube audio for video: $videoId');
    if (kIsWeb) {
      await _setupYoutubeWeb(videoId);
      return;
    }
    try {
      final yt = YoutubeExplode();
      final video = await yt.videos.get('https://www.youtube.com/watch?v=$videoId');
      final manifest = await yt.videos.streamsClient.getManifest(video.id);
      
      // Get the best audio stream available
      final audioStream = manifest.audioOnly.withHighestBitrate();
      final audioUrl = audioStream.url.toString();
      debugPrint('Audio stream URL obtained, length: ${audioUrl.length}');
      
      // Play the audio using the preview audio element
      _spotifySub?.cancel();
      _spotifySub = null;
      _previewAudio = html.AudioElement(audioUrl);
      _previewPosition = Duration.zero;
      _previewDuration = Duration.zero;

      _previewMetaSub = _previewAudio!.onLoadedMetadata.listen((_) {
        _previewDuration = Duration(
          milliseconds: (_previewAudio!.duration * 1000).toInt(),
        );
        notifyListeners();
      });

      _previewTimeSub = _previewAudio!.onTimeUpdate.listen((_) {
        if (!_scrubbing) {
          _previewPosition = Duration(
            milliseconds: (_previewAudio!.currentTime * 1000).toInt(),
          );
          notifyListeners();
        }
      });

      _previewEndedSub = _previewAudio!.onEnded.listen((_) {
        _isPlaying = false;
        _onTrackEnded();
      });

      _usingYoutube = true;
      await _previewAudio!.play();
      _isPlaying = !_previewAudio!.paused;
      notifyListeners();
      
      yt.close();
    } catch (e) {
      debugPrint('Error setting up YouTube audio: $e');
      _usingYoutube = false;
      notifyListeners();
    }
  }

  Future<void> _playCurrent() async {
    _endDebounce?.cancel();
    await _disposeYoutube();

    final songs = _songs;
    if (_cursor < 0 || _cursor >= _queue.length) return;
    final si = _queue[_cursor];
    if (si < 0 || si >= songs.length) return;

    final song = songs[si];
    final uri = spotifyTrackUriFromUrl(song.url);
    final player = SpotifyPlayer.instance;

    _tearDownPreview();

    _usingSpotifyFull = false;

    if (player.isReady && uri != null) {
      _usingSpotifyFull = true;
      _previewPosition = Duration.zero;
      _previewDuration = Duration.zero;
      await player.playTrack(uri);
      _isPlaying = true;
      _listenSpotify();
      notifyListeners();
      return;
    }

    if (song.previewUrl != null && song.previewUrl!.isNotEmpty) {
      _spotifySub?.cancel();
      _spotifySub = null;
      _previewAudio = html.AudioElement(song.previewUrl);
      _previewPosition = Duration.zero;
      _previewDuration = Duration.zero;

      _previewMetaSub = _previewAudio!.onLoadedMetadata.listen((_) {
        _previewDuration = Duration(
          milliseconds: (_previewAudio!.duration * 1000).toInt(),
        );
        notifyListeners();
      });

      _previewTimeSub = _previewAudio!.onTimeUpdate.listen((_) {
        if (!_scrubbing) {
          _previewPosition = Duration(
            milliseconds: (_previewAudio!.currentTime * 1000).toInt(),
          );
          notifyListeners();
        }
      });

      _previewEndedSub = _previewAudio!.onEnded.listen((_) {
        _isPlaying = false;
        _onTrackEnded();
      });

      await _previewAudio!.play();
      _isPlaying = !_previewAudio!.paused;
      notifyListeners();
      return;
    }

    final ytId = YoutubeApi.videoIdForSong(song);
    if (ytId != null && ytId.isNotEmpty) {
      _spotifySub?.cancel();
      _spotifySub = null;
      if (SpotifyPlayer.instance.isReady && SpotifyPlayer.instance.currentTrackUri != null) {
        try {
          SpotifyPlayer.instance.pause();
        } catch (_) {
          // Ignore pause failures when Spotify has no active track loaded.
        }
      }
      await _setupYoutube(ytId);
      return;
    }

    _usingSpotifyFull = false;
    _isPlaying = false;
    notifyListeners();
  }

  void _tearDownPreview() {
    _previewTimeSub?.cancel();
    _previewEndedSub?.cancel();
    _previewMetaSub?.cancel();
    _previewTimeSub = null;
    _previewEndedSub = null;
    _previewMetaSub = null;
    _previewAudio?.pause();
    _previewAudio = null;
  }

  void _onTrackEnded() {
    _endDebounce?.cancel();
    _endDebounce = Timer(const Duration(milliseconds: 120), () {
      if (_cursor + 1 < _queue.length) {
        _cursor++;
        _playCurrent();
      } else {
        _isPlaying = false;
        if (!_usingSpotifyFull && !_usingYoutube) {
          _previewPosition = _previewDuration;
        }
        notifyListeners();
      }
    });
  }

  Future<void> seekToProgress(double v) async {
    final d = duration;
    if (d <= Duration.zero) return;
    final clamped = v.clamp(0.0, 1.0);
    final targetMs = (d.inMilliseconds * clamped).round();
    if (_usingSpotifyFull && SpotifyPlayer.instance.isReady) {
      await SpotifyPlayer.instance.seek(targetMs);
    } else if (_usingYoutubeWeb) {
      await YoutubeWebPlayer.instance.seek(targetMs / 1000.0);
      _previewPosition = Duration(milliseconds: targetMs);
    } else if (_previewAudio != null) {
      _previewAudio!.currentTime = targetMs / 1000.0;
      _previewPosition = Duration(milliseconds: targetMs);
    }
    notifyListeners();
  }

  void setScrubbing(bool val) {
    _scrubbing = val;
    notifyListeners();
  }

  Future<void> skipNext() async {
    if (_cursor + 1 < _queue.length) {
      _cursor++;
      await _playCurrent();
      notifyListeners();
    }
  }

  Future<void> skipPrevious() async {
    final pos = position;
    if (pos > const Duration(seconds: 3)) {
      if (_usingSpotifyFull && SpotifyPlayer.instance.isReady) {
        await SpotifyPlayer.instance.seek(0);
      } else if (_previewAudio != null) {
        _previewAudio!.currentTime = 0;
        _previewPosition = Duration.zero;
      }
      notifyListeners();
      return;
    }
    if (_cursor > 0) {
      _cursor--;
      await _playCurrent();
      notifyListeners();
    } else {
      if (_usingSpotifyFull && SpotifyPlayer.instance.isReady) {
        await SpotifyPlayer.instance.seek(0);
      } else if (_previewAudio != null) {
        _previewAudio!.currentTime = 0;
        _previewPosition = Duration.zero;
      }
      notifyListeners();
    }
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
    if (_queue.isEmpty) {
      notifyListeners();
      return;
    }
    if (_shuffle) {
      if (_cursor + 1 < _queue.length) {
        final tail = _queue.sublist(_cursor + 1)..shuffle(Random());
        _queue = [..._queue.sublist(0, _cursor + 1), ...tail];
      }
    } else {
      final cur = _queue[_cursor];
      final n = _songs.length;
      if (cur >= 0 && cur < n) {
        _queue = List<int>.generate(n - cur, (i) => cur + i);
        _cursor = 0;
      }
    }
    notifyListeners();
  }

  void stop() {
    _endDebounce?.cancel();
    _spotifySub?.cancel();
    _spotifySub = null;
    if (SpotifyPlayer.instance.isReady) {
      try {
        SpotifyPlayer.instance.pause();
      } catch (_) {
        // ignore when Spotify is not actively playing
      }
    }
    _tearDownPreview();
    unawaited(_disposeYoutube());
    _queue = [];
    _cursor = 0;
    _isPlaying = false;
    _usingSpotifyFull = false;
    _previewPosition = Duration.zero;
    _previewDuration = Duration.zero;
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    detach();
    super.dispose();
  }
}
