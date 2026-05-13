import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';

/// Wraps the YouTube IFrame Player API for Flutter Web.
///
/// `youtube_player_iframe` relies on JavaScript channels and
/// `runJavaScript`, which are not implemented by `webview_flutter_web`,
/// so the iframe never loads when targeting web. Instead we mount a raw
/// `<div>` via [HtmlElementView] and let the official YT IFrame API
/// (loaded in `web/index.html`) build its own iframe inside it.
///
/// The service exposes a small surface tailored to this app:
///   * [load] – swap the currently-playing video
///   * [play] / [pause] / [seek] / [setVolume]
///   * [stateStream] – `playing` / `paused` / `ended` etc.
///   * [duration] / [currentTime] – polled from the JS player
class YoutubeWebPlayer {
  YoutubeWebPlayer._();

  static final YoutubeWebPlayer instance = YoutubeWebPlayer._();

  /// The platform-view type the [HtmlElementView] should reference.
  static const String viewType = 'cross-playlist-yt-web-player';

  static bool _viewFactoryRegistered = false;

  /// The single `<div>` the JS YT.Player is bound to. Created lazily the
  /// first time the platform view factory is invoked.
  html.DivElement? _hostDiv;

  /// The JS `YT.Player` instance once it has been constructed.
  js.JsObject? _ytPlayer;

  /// Resolves once the underlying YT.Player has fired its `onReady` event.
  Completer<void>? _readyCompleter;

  /// Resolves once the `YT` namespace is available on `window`.
  Completer<void>? _apiReadyCompleter;

  /// The most recent state pushed from the iframe.
  final StreamController<YoutubeWebPlayerState> _stateController =
      StreamController<YoutubeWebPlayerState>.broadcast();

  Stream<YoutubeWebPlayerState> get stateStream => _stateController.stream;

  /// Raw YT IFrame API error codes (2, 5, 100, 101, 150).
  ///
  /// * 2   – invalid parameter (typically a bad video id)
  /// * 5   – HTML5 player issue
  /// * 100 – video not found / made private
  /// * 101 – owner disallows embedded playback
  /// * 150 – same as 101 (older alias)
  final StreamController<int> _errorController =
      StreamController<int>.broadcast();

  Stream<int> get errorStream => _errorController.stream;

  YoutubeWebPlayerState _lastState = YoutubeWebPlayerState.unstarted;
  YoutubeWebPlayerState get lastState => _lastState;

  /// The video the JS player is currently bound to (may differ briefly
  /// from the one we just asked it to load).
  String? _currentVideoId;
  String? get currentVideoId => _currentVideoId;

  /// Registers the [HtmlElementView] factory the first time it's needed.
  /// Safe to call multiple times.
  void registerViewFactory() {
    if (_viewFactoryRegistered) return;
    _viewFactoryRegistered = true;
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      // Reuse the same div across rebuilds so the YT.Player stays alive
      // when the HtmlElementView is re-mounted (e.g. theme switch).
      final div = _hostDiv ??= (html.DivElement()
        ..id = 'cross-playlist-yt-host'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.background = 'transparent');
      return div;
    });
  }

  /// Wait for `window.YT` to exist (set by the iframe_api.js script in
  /// index.html). The API can take a moment after page load.
  Future<void> _waitForYouTubeApi() {
    if (js.context['YT'] != null && js.context['YT']['Player'] != null) {
      return Future.value();
    }
    if (_apiReadyCompleter != null) {
      return _apiReadyCompleter!.future;
    }
    final completer = Completer<void>();
    _apiReadyCompleter = completer;

    const tickMs = 100;
    const maxMs = 15000;
    var elapsed = 0;
    Timer.periodic(const Duration(milliseconds: tickMs), (t) {
      elapsed += tickMs;
      final ytReady = js.context['__ytIframeApiReady'] == true ||
          (js.context['YT'] != null && js.context['YT']['Player'] != null);
      if (ytReady) {
        t.cancel();
        if (!completer.isCompleted) completer.complete();
      } else if (elapsed >= maxMs) {
        t.cancel();
        if (!completer.isCompleted) {
          completer.completeError(
            'YouTube IFrame API failed to load within ${maxMs}ms',
          );
        }
      }
    });
    return completer.future;
  }

  /// Construct the JS YT.Player on top of [_hostDiv], if it hasn't been
  /// created yet. Resolves when the player fires `onReady`.
  Future<void> _ensurePlayerCreated() async {
    if (_ytPlayer != null) {
      // Already created; wait for ready if still pending.
      if (_readyCompleter?.isCompleted == false) {
        await _readyCompleter!.future;
      }
      return;
    }

    await _waitForYouTubeApi();

    // The host div is created lazily by the view factory the first time
    // HtmlElementView mounts it. Wait briefly for that to happen.
    var waited = 0;
    while (_hostDiv == null && waited < 5000) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      waited += 50;
    }
    if (_hostDiv == null) {
      throw StateError(
        'YoutubeWebPlayer: host div was never created – is HtmlElementView mounted?',
      );
    }

    _readyCompleter = Completer<void>();

    final playerVars = js.JsObject.jsify({
      'autoplay': 0,
      'controls': 0,
      'disablekb': 1,
      'fs': 0,
      'modestbranding': 1,
      'playsinline': 1,
      'rel': 0,
      'iv_load_policy': 3,
      'origin': html.window.location.origin,
    });

    final events = js.JsObject.jsify({});
    events['onReady'] = js.allowInterop((_) {
      debugPrint('YoutubeWebPlayer: onReady');
      if (_readyCompleter?.isCompleted == false) {
        _readyCompleter!.complete();
      }
    });
    events['onStateChange'] = js.allowInterop((dynamic event) {
      try {
        final int code = (event as js.JsObject)['data'] as int;
        _lastState = _decodeState(code);
        _stateController.add(_lastState);
      } catch (e) {
        debugPrint('YoutubeWebPlayer: state decode error: $e');
      }
    });
    events['onError'] = js.allowInterop((dynamic event) {
      int code = -1;
      try {
        final raw = (event as js.JsObject)['data'];
        if (raw is num) code = raw.toInt();
      } catch (_) {}
      debugPrint('YoutubeWebPlayer: onError $code');
      _lastState = YoutubeWebPlayerState.error;
      _stateController.add(_lastState);
      _errorController.add(code);
    });

    final options = js.JsObject.jsify({
      'height': '100%',
      'width': '100%',
      'playerVars': null,
      'events': null,
    });
    // Re-attach to preserve JsFunction values (jsify drops them).
    options['playerVars'] = playerVars;
    options['events'] = events;

    final YT = js.context['YT'] as js.JsObject;
    final playerCtor = YT['Player'] as js.JsFunction;
    _ytPlayer = js.JsObject(playerCtor, [_hostDiv!.id, options]);

    await _readyCompleter!.future;
  }

  /// Load and start playing [videoId]. Safe to call repeatedly.
  Future<void> load(String videoId) async {
    try {
      await _ensurePlayerCreated();
      _currentVideoId = videoId;
      // loadVideoById auto-plays; cueVideoById does not.
      _ytPlayer!.callMethod('loadVideoById', [videoId]);
    } catch (e) {
      debugPrint('YoutubeWebPlayer: load($videoId) failed: $e');
      rethrow;
    }
  }

  Future<void> play() async {
    try {
      _ytPlayer?.callMethod('playVideo', const []);
    } catch (e) {
      debugPrint('YoutubeWebPlayer: play failed: $e');
    }
  }

  Future<void> pause() async {
    try {
      _ytPlayer?.callMethod('pauseVideo', const []);
    } catch (e) {
      debugPrint('YoutubeWebPlayer: pause failed: $e');
    }
  }

  Future<void> seek(double seconds) async {
    try {
      _ytPlayer?.callMethod('seekTo', [seconds, true]);
    } catch (e) {
      debugPrint('YoutubeWebPlayer: seek failed: $e');
    }
  }

  Future<void> setVolume(int volume) async {
    try {
      _ytPlayer?.callMethod('setVolume', [volume.clamp(0, 100)]);
      _ytPlayer?.callMethod('unMute', const []);
    } catch (e) {
      debugPrint('YoutubeWebPlayer: setVolume failed: $e');
    }
  }

  Future<void> stop() async {
    try {
      _ytPlayer?.callMethod('stopVideo', const []);
    } catch (e) {
      debugPrint('YoutubeWebPlayer: stop failed: $e');
    }
  }

  /// Current playback position in seconds. Returns 0 if unavailable.
  double get currentTime {
    try {
      final v = _ytPlayer?.callMethod('getCurrentTime', const []);
      if (v is num) return v.toDouble();
    } catch (_) {}
    return 0.0;
  }

  /// Video duration in seconds. Returns 0 until metadata is loaded.
  double get duration {
    try {
      final v = _ytPlayer?.callMethod('getDuration', const []);
      if (v is num) return v.toDouble();
    } catch (_) {}
    return 0.0;
  }

  static YoutubeWebPlayerState _decodeState(int code) {
    // YT.PlayerState constants: -1 unstarted, 0 ended, 1 playing,
    // 2 paused, 3 buffering, 5 video cued.
    switch (code) {
      case -1:
        return YoutubeWebPlayerState.unstarted;
      case 0:
        return YoutubeWebPlayerState.ended;
      case 1:
        return YoutubeWebPlayerState.playing;
      case 2:
        return YoutubeWebPlayerState.paused;
      case 3:
        return YoutubeWebPlayerState.buffering;
      case 5:
        return YoutubeWebPlayerState.cued;
      default:
        return YoutubeWebPlayerState.unstarted;
    }
  }
}

enum YoutubeWebPlayerState {
  unstarted,
  ended,
  playing,
  paused,
  buffering,
  cued,
  error,
}
