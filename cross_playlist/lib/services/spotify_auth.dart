import 'dart:convert';
import 'dart:html' as html;
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Simple Spotify OAuth using full-page redirect (no popup complexity).
class SpotifyAuth {
  static const String _clientId = 'e006b5f3fb0143ff9409c671771148af';
  static const String _redirectUri = 'http://127.0.0.1:8888/';

  static const List<String> _scopes = [
    'playlist-read-private',
    'playlist-read-collaborative',
    'playlist-modify-public',
    'playlist-modify-private',
    'user-read-email',
    'user-read-private',
  ];

  // In-memory cache
  static String? _accessToken;
  static String? _refreshToken;
  static DateTime? _expiresAt;

  static bool get isConnected => _accessToken != null;

  /// Get access token, automatically refreshing if expired.
  static Future<String?> get accessToken async {
    if (_accessToken == null) return null;
    
    // Check if token is expired or about to expire (within 5 minutes)
    if (_expiresAt != null && 
        DateTime.now().isAfter(_expiresAt!.subtract(const Duration(minutes: 5)))) {
      await _refreshAccessToken();
    }
    
    return _accessToken;
  }

  // PKCE helpers
  static String _codeVerifier() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rng = Random.secure();
    return List.generate(128, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  static String _codeChallenge(String verifier) {
    final hash = sha256.convert(utf8.encode(verifier)).bytes;
    return base64UrlEncode(hash).replaceAll('=', '');
  }

  /// Redirect to Spotify login (full page).
  static void login() {
    final verifier = _codeVerifier();
    final challenge = _codeChallenge(verifier);

    html.window.sessionStorage['spotify_verifier'] = verifier;

    final authUrl = Uri.https('accounts.spotify.com', '/authorize', {
      'client_id': _clientId,
      'response_type': 'code',
      'redirect_uri': _redirectUri,
      'scope': _scopes.join(' '),
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
      'show_dialog': 'true',
    });

    html.window.location.assign(authUrl.toString());
  }

  /// Call on app startup to check for ?code= in URL.
  static Future<bool> handleRedirect() async {
    try {
      final uri = Uri.parse(html.window.location.href);
      final code = uri.queryParameters['code'];

      if (code == null) return false;

      debugPrint('Spotify: Exchanging auth code...');

      final verifier = html.window.sessionStorage['spotify_verifier'];
      if (verifier == null) {
        debugPrint('Spotify: Verifier missing');
        _cleanUrl();
        return false;
      }

      final response = await http.post(
        Uri.parse('https://accounts.spotify.com/api/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': _redirectUri,
          'client_id': _clientId,
          'code_verifier': verifier,
        },
      );

      _cleanUrl();
      html.window.sessionStorage.remove('spotify_verifier');

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        _accessToken = body['access_token'] as String;
        _refreshToken = body['refresh_token'] as String?;
        final expiresIn = body['expires_in'] as int;
        _expiresAt = DateTime.now().add(Duration(seconds: expiresIn));

        // Save to Firestore
        await _saveTokensToFirestore();

        debugPrint('Spotify: Connected!');
        return true;
      } else {
        debugPrint('Spotify: Token failed (${response.statusCode}): ${response.body}');
        return false;
      }
    } catch (e) {
      debugPrint('Spotify: Error $e');
      _cleanUrl();
      return false;
    }
  }

  static void _cleanUrl() {
    html.window.history.replaceState(null, '', '/');
  }

  static Future<void> logout() async {
    _accessToken = null;
    _refreshToken = null;
    _expiresAt = null;
    await _deleteTokensFromFirestore();
  }

  /// Load tokens from Firestore on app startup.
  static Future<void> loadTokens() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;

    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('private')
          .doc('spotify')
          .get();

      if (!doc.exists) return;

      final data = doc.data()!;
      _accessToken = data['access_token'] as String?;
      _refreshToken = data['refresh_token'] as String?;
      
      final expiresAtMs = data['expires_at'] as int?;
      _expiresAt = expiresAtMs != null 
          ? DateTime.fromMillisecondsSinceEpoch(expiresAtMs)
          : null;

      debugPrint('Spotify: Loaded tokens from Firestore');
      
      // If token is expired, try to refresh immediately
      if (_expiresAt != null && DateTime.now().isAfter(_expiresAt!)) {
        await _refreshAccessToken();
      }
    } catch (e) {
      debugPrint('Spotify: Error loading tokens: $e');
    }
  }

  /// Save tokens to Firestore.
  static Future<void> _saveTokensToFirestore() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('private')
          .doc('spotify')
          .set({
        'access_token': _accessToken,
        'refresh_token': _refreshToken,
        'expires_at': _expiresAt?.millisecondsSinceEpoch,
        'updated_at': FieldValue.serverTimestamp(),
      });
      debugPrint('Spotify: Saved tokens to Firestore');
    } catch (e) {
      debugPrint('Spotify: Error saving tokens: $e');
    }
  }

  /// Delete tokens from Firestore.
  static Future<void> _deleteTokensFromFirestore() async {
    final userId = FirebaseAuth.instance.currentUser?.uid;
    if (userId == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .collection('private')
          .doc('spotify')
          .delete();
      debugPrint('Spotify: Deleted tokens from Firestore');
    } catch (e) {
      debugPrint('Spotify: Error deleting tokens: $e');
    }
  }

  /// Refresh the access token using the refresh token.
  static Future<bool> _refreshAccessToken() async {
    if (_refreshToken == null) {
      debugPrint('Spotify: No refresh token available');
      return false;
    }

    try {
      debugPrint('Spotify: Refreshing access token...');
      
      final response = await http.post(
        Uri.parse('https://accounts.spotify.com/api/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'grant_type': 'refresh_token',
          'refresh_token': _refreshToken!,
          'client_id': _clientId,
        },
      );

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        _accessToken = body['access_token'] as String;
        
        // Spotify may return a new refresh token
        if (body.containsKey('refresh_token')) {
          _refreshToken = body['refresh_token'] as String;
        }
        
        final expiresIn = body['expires_in'] as int;
        _expiresAt = DateTime.now().add(Duration(seconds: expiresIn));

        // Save updated tokens
        await _saveTokensToFirestore();

        debugPrint('Spotify: Token refreshed successfully');
        return true;
      } else {
        debugPrint('Spotify: Refresh failed (${response.statusCode}): ${response.body}');
        // If refresh fails, clear everything
        await logout();
        return false;
      }
    } catch (e) {
      debugPrint('Spotify: Refresh error: $e');
      return false;
    }
  }
}
