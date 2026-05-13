import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class PlaylistMeta {
  final String id;
  final String name;

  PlaylistMeta({required this.id, required this.name});
}

class PlaylistService {
  static CollectionReference<Map<String, dynamic>> _ref() {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('playlists');
  }

  static Future<List<PlaylistMeta>> getPlaylists() async {
    final snap = await _ref().orderBy('createdAt').get();
    return snap.docs
        .map(
          (d) => PlaylistMeta(
            id: d.id,
            name: d.data()['name'] as String? ?? 'Untitled',
          ),
        )
        .toList();
  }

  static Future<PlaylistMeta> createPlaylist(String name) async {
    final doc = await _ref().add({
      'name': name,
      'songs': <Map<String, dynamic>>[],
      'createdAt': FieldValue.serverTimestamp(),
    });
    return PlaylistMeta(id: doc.id, name: name);
  }

  static Future<void> renamePlaylist(String id, String newName) async {
    await _ref().doc(id).update({'name': newName});
  }

  static Future<void> deletePlaylist(String id) async {
    await _ref().doc(id).delete();
  }

  static Future<List<Map<String, dynamic>>> getSongs(String playlistId) async {
    final doc = await _ref().doc(playlistId).get();
    if (!doc.exists) return [];
    final data = doc.data()!;
    final songs = data['songs'] as List<dynamic>? ?? [];
    return songs.map((s) => Map<String, dynamic>.from(s as Map)).toList();
  }

  static Future<void> saveSongs(
    String playlistId,
    List<Map<String, dynamic>> songs,
  ) async {
    await _ref().doc(playlistId).update({'songs': songs});
  }
}
