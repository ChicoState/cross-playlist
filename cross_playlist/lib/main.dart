import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:html' as html;
import 'firebase_options.dart';
import 'login_page.dart';
import 'services/playlist_service.dart';
import 'services/spotify_auth.dart';
import 'services/spotify_api.dart';
import 'services/spotify_player.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  // Handle Spotify OAuth redirect (needs Firebase for Firestore token save)
  await SpotifyAuth.handleRedirect();

  runApp(const MyApp());
}

// Handles the login page from Firebase to get into the homepage
// of the app
class MyApp extends StatefulWidget {
  const MyApp({super.key});

  static _MyAppState? of(BuildContext context) =>
      context.findAncestorStateOfType<_MyAppState>();

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.light;

  bool get isDark => _themeMode == ThemeMode.dark;

  void toggleTheme(bool dark) {
    setState(() => _themeMode = dark ? ThemeMode.dark : ThemeMode.light);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cross-Playlist',
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.light,
        appBarTheme: const AppBarTheme(
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.dark,
        appBarTheme: const AppBarTheme(
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
      ),
      themeMode: _themeMode,
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (snapshot.hasData) {
            return const MyHomePage();
          }
          return const LoginPage();
        },
      ),
    );
  }
}

// Displays the playlist on the homepage after successful login
class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  bool _spotifyConnected = false;
  bool _playerInitialized = false;
  List<PlaylistMeta> _playlists = [];
  String? _selectedPlaylistId;
  String _selectedPlaylistName = 'My Playlist';
  bool _loadingPlaylists = true;
  final Set<int> _selectedSongIndices = {};
  final GlobalKey<_PlaylistState> _playlistKey = GlobalKey<_PlaylistState>();

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    // Load Spotify tokens now that the user is authenticated
    await SpotifyAuth.loadTokens();
    _spotifyConnected = SpotifyAuth.isConnected;
    if (_spotifyConnected) {
      _initializePlayer();
    }
    await _loadPlaylists();
    if (mounted) setState(() {});
  }

  Future<void> _initializePlayer() async {
    await SpotifyPlayer.instance.initialize();
    if (mounted) {
      setState(() => _playerInitialized = true);
    }
  }

  Future<void> _loadPlaylists() async {
    try {
      _playlists = await PlaylistService.getPlaylists();
      if (_playlists.isEmpty) {
        final p = await PlaylistService.createPlaylist('My Playlist');
        _playlists = [p];
      }
      _selectedPlaylistId ??= _playlists.first.id;
      _selectedPlaylistName =
          _playlists.firstWhere((p) => p.id == _selectedPlaylistId).name;
    } catch (e) {
      debugPrint('Error loading playlists: $e');
    }
    _loadingPlaylists = false;
  }

  void _connectSpotify() {
    SpotifyAuth.login();
  }

  Future<void> _disconnectSpotify() async {
    await SpotifyAuth.logout();
    setState(() => _spotifyConnected = false);
  }

  Future<void> _createPlaylist() async {
    final name = await _showTextDialog('New Playlist', 'Enter playlist name');
    if (name == null || name.trim().isEmpty) return;
    final p = await PlaylistService.createPlaylist(name.trim());
    setState(() {
      _playlists.add(p);
      _selectedPlaylistId = p.id;
      _selectedPlaylistName = p.name;
    });
  }

  Future<void> _renamePlaylist(PlaylistMeta playlist) async {
    final name = await _showTextDialog('Rename Playlist', 'Enter new name',
        initialValue: playlist.name);
    if (name == null || name.trim().isEmpty) return;
    await PlaylistService.renamePlaylist(playlist.id, name.trim());
    setState(() {
      final idx = _playlists.indexWhere((p) => p.id == playlist.id);
      if (idx >= 0) {
        _playlists[idx] = PlaylistMeta(id: playlist.id, name: name.trim());
        if (_selectedPlaylistId == playlist.id) {
          _selectedPlaylistName = name.trim();
        }
      }
    });
  }

  Future<void> _deletePlaylist(PlaylistMeta playlist) async {
    if (_playlists.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot delete the last playlist')),
      );
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Playlist'),
        content: Text('Delete "${playlist.name}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('Delete', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (confirm != true) return;
    await PlaylistService.deletePlaylist(playlist.id);
    setState(() {
      _playlists.removeWhere((p) => p.id == playlist.id);
      if (_selectedPlaylistId == playlist.id) {
        _selectedPlaylistId = _playlists.first.id;
        _selectedPlaylistName = _playlists.first.name;
      }
    });
  }

  Future<String?> _showTextDialog(String title, String hint,
      {String? initialValue}) {
    final controller = TextEditingController(text: initialValue);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
              hintText: hint, border: const OutlineInputBorder()),
          autofocus: true,
          onSubmitted: (_) => Navigator.pop(ctx, controller.text),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('OK')),
        ],
      ),
    );
  }

  void _clearSelection() {
    setState(() => _selectedSongIndices.clear());
  }

  Future<void> _deleteSelectedSongs() async {
    final ps = _playlistKey.currentState;
    if (ps == null) return;
    final sorted = _selectedSongIndices.toList()..sort((a, b) => b.compareTo(a));
    for (final i in sorted) {
      ps.songList.removeAt(i);
    }
    _clearSelection();
    ps.setState(() {});
    ps.saveSongs();
  }

  Future<void> _moveOrCopySelected({required bool copy}) async {
    final others = _playlists.where((p) => p.id != _selectedPlaylistId).toList();
    if (others.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other playlists to choose from')),
      );
      return;
    }
    final target = await showDialog<PlaylistMeta>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(copy ? 'Copy to playlist' : 'Move to playlist'),
        children: others
            .map((p) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, p),
                  child: Text(p.name),
                ))
            .toList(),
      ),
    );
    if (target == null) return;
    final ps = _playlistKey.currentState;
    if (ps == null) return;
    final songs = _selectedSongIndices.toList()
      ..sort();
    final selectedSongs = songs.map((i) => ps.songList[i]).toList();
    // Add to target playlist
    try {
      final existing = await PlaylistService.getSongs(target.id);
      final merged = [...existing, ...selectedSongs.map((s) => s.toMap())];
      await PlaylistService.saveSongs(target.id, merged);
    } catch (e) {
      debugPrint('Error copying songs: $e');
    }
    if (!copy) {
      final sorted = _selectedSongIndices.toList()..sort((a, b) => b.compareTo(a));
      for (final i in sorted) {
        ps.songList.removeAt(i);
      }
      ps.setState(() {});
      ps.saveSongs();
    }
    _clearSelection();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${copy ? "Copied" : "Moved"} ${selectedSongs.length} song(s) to ${target.name}')),
      );
    }
  }

  Future<void> _importSpotifyPlaylist() async {
    final spotifyPlaylists = await SpotifyApi.getUserPlaylists();
    if (spotifyPlaylists.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No Spotify playlists found')),
        );
      }
      return;
    }
    if (!mounted) return;
    final picked = await showDialog<SpotifyPlaylistMeta>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Import from Spotify'),
        children: spotifyPlaylists
            .map((sp) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, sp),
                  child: ListTile(
                    leading: sp.imageUrl != null
                        ? Image.network(sp.imageUrl!, width: 40, height: 40, fit: BoxFit.cover)
                        : const Icon(Icons.music_note),
                    title: Text(sp.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    contentPadding: EdgeInsets.zero,
                  ),
                ))
            .toList(),
      ),
    );
    if (picked == null) return;

    if (!mounted) return;
    // Show loading indicator
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Importing playlist...'), duration: Duration(seconds: 30)),
    );

    final tracks = await SpotifyApi.getPlaylistTracks(picked.id);

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();

    if (tracks.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tracks found — try disconnecting and reconnecting Spotify')),
      );
      return;
    }

    final newPlaylist = await PlaylistService.createPlaylist(picked.name);
    final songMaps = tracks
        .map((t) => Song(
              t.artist,
              t.album,
              '',
              'Spotify',
              name: t.name,
              url: t.spotifyUrl,
              imageUrl: t.imageUrl,
              previewUrl: t.previewUrl,
            ).toMap())
        .toList();
    await PlaylistService.saveSongs(newPlaylist.id, songMaps);

    setState(() {
      _playlists.add(newPlaylist);
      _selectedPlaylistId = newPlaylist.id;
      _selectedPlaylistName = newPlaylist.name;
      _selectedSongIndices.clear();
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported "${picked.name}" with ${tracks.length} tracks')),
      );
    }
  }
  @override
  Widget build(BuildContext context) {
    final appState = MyApp.of(context);
    final hasSelection = _selectedSongIndices.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        scrolledUnderElevation: 0,
        title: hasSelection
            ? Text('${_selectedSongIndices.length} selected')
            : const Text('Cross-Playlist', style: TextStyle(fontSize: 36)),
        automaticallyImplyLeading: false,
        actions: [
          if (hasSelection) ...[
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete selected',
              onPressed: _deleteSelectedSongs,
            ),
            IconButton(
              icon: const Icon(Icons.drive_file_move_outline),
              tooltip: 'Move to playlist',
              onPressed: () => _moveOrCopySelected(copy: false),
            ),
            IconButton(
              icon: const Icon(Icons.copy),
              tooltip: 'Copy to playlist',
              onPressed: () => _moveOrCopySelected(copy: true),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Clear selection',
              onPressed: _clearSelection,
            ),
            const SizedBox(width: 8),
          ] else ...[
            if (_spotifyConnected)
              TextButton.icon(
                onPressed: _disconnectSpotify,
                icon: const Icon(Icons.check_circle, color: Color(0xFF1DB954)),
                label: const Text('Spotify Connected',
                    style: TextStyle(color: Color(0xFF1DB954))),
              )
            else
              TextButton.icon(
                onPressed: _connectSpotify,
                icon: const Icon(Icons.link, color: Colors.white),
                label: const Text('Connect Spotify',
                    style: TextStyle(color: Colors.white)),
                style: TextButton.styleFrom(
                  backgroundColor: const Color(0xFF1DB954),
                ),
              ),
            const SizedBox(width: 8),
            Row(
              children: [
                Icon(appState!.isDark ? Icons.dark_mode : Icons.light_mode, size: 18),
                Switch(
                  value: appState.isDark,
                  onChanged: appState.toggleTheme,
                ),
              ],
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
      body: Row(
        children: [
          SizedBox(
            width: 250,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Playlists',
                          style: Theme.of(context).textTheme.titleMedium),
                      IconButton(
                        icon: const Icon(Icons.add, size: 22),
                        tooltip: 'New Playlist',
                        onPressed: _createPlaylist,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    children: [
                      if (_spotifyConnected)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: ElevatedButton.icon(
                            onPressed: _importSpotifyPlaylist,
                            icon: const Icon(Icons.download, color: Colors.white),
                            label: const Text(
                              'Import from Spotify',
                              style: TextStyle(color: Colors.white),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1DB954),
                              foregroundColor: Colors.white,
                              minimumSize: const Size.fromHeight(42),
                            ),
                          ),
                        ),
                      for (final p in _playlists)
                        ListTile(
                          title: Text(p.name),
                          selected: p.id == _selectedPlaylistId,
                          onTap: () {
                            setState(() {
                              _selectedPlaylistId = p.id;
                              _selectedPlaylistName = p.name;
                              _selectedSongIndices.clear();
                            });
                          },
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'rename') _renamePlaylist(p);
                              if (value == 'delete') _deletePlaylist(p);
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                  value: 'rename', child: Text('Rename')),
                              const PopupMenuItem(
                                  value: 'delete', child: Text('Delete')),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: _loadingPlaylists
                ? const Center(child: CircularProgressIndicator())
                : _selectedPlaylistId != null
                    ? Playlist(
                        key: _playlistKey,
                        spotifyConnected: _spotifyConnected,
                        playlistId: _selectedPlaylistId!,
                        playlistName: _selectedPlaylistName,
                        selectedIndices: _selectedSongIndices,
                        onSelectionChanged: (indices) {
                          setState(() {
                            _selectedSongIndices.clear();
                            _selectedSongIndices.addAll(indices);
                          });
                        },
                      )
                    : const Center(child: Text('No playlist selected')),
          ),
        ],
      ),
    );
  }
}

// Song class that will handle the playing of music
class Song {
  const Song(this.artist, this.album, this.genre, this.streamingPlatform,
      {required this.name, required this.url, this.imageUrl, this.previewUrl});

  final String name, url, artist, album, genre, streamingPlatform;
  final String? imageUrl;
  final String? previewUrl; // 30-second preview MP3

  Map<String, dynamic> toMap() => {
        'name': name,
        'artist': artist,
        'album': album,
        'genre': genre,
        'streamingPlatform': streamingPlatform,
        'url': url,
        'imageUrl': imageUrl,
        'previewUrl': previewUrl,
      };

  factory Song.fromMap(Map<String, dynamic> map) => Song(
        map['artist'] as String? ?? '',
        map['album'] as String? ?? '',
        map['genre'] as String? ?? '',
        map['streamingPlatform'] as String? ?? '',
        name: map['name'] as String? ?? '',
        url: map['url'] as String? ?? '',
        imageUrl: map['imageUrl'] as String?,
        previewUrl: map['previewUrl'] as String?,
      );
}

// Refreshes Playlist state on adding a song to the playlist
class Playlist extends StatefulWidget {
  const Playlist(
      {super.key,
      required this.spotifyConnected,
      required this.playlistId,
      required this.playlistName,
      required this.selectedIndices,
      required this.onSelectionChanged});

  final bool spotifyConnected;
  final String playlistId;
  final String playlistName;
  final Set<int> selectedIndices;
  final ValueChanged<Set<int>> onSelectionChanged;

  @override
  State<Playlist> createState() => _PlaylistState();
}

class _PlaylistState extends State<Playlist> {
  final List<Song> songList = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSongs();
  }

  @override
  void didUpdateWidget(covariant Playlist oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlistId != widget.playlistId) {
      _loading = true;
      songList.clear();
      _loadSongs();
    }
  }

  // Expose saveSongs so parent can call it after bulk operations
  void saveSongs() => _saveSongs();

  Future<void> _loadSongs() async {
    try {
      final maps = await PlaylistService.getSongs(widget.playlistId);
      songList.clear();
      for (final m in maps) {
        songList.add(Song.fromMap(m));
      }
    } catch (e) {
      debugPrint('Error loading songs: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _saveSongs() async {
    try {
      await PlaylistService.saveSongs(
        widget.playlistId,
        songList.map((s) => s.toMap()).toList(),
      );
    } catch (e) {
      debugPrint('Error saving songs: $e');
    }
  }

  void _addSong(Song song) {
    setState(() {
      songList.add(song);
    });
    _saveSongs();
  }

  void _deleteSong(int index) {
    setState(() {
      songList.removeAt(index);
    });
    _saveSongs();
  }

  /// Opens a search dialog to find songs on Spotify and add them.
  Future<void> _showSpotifySearchDialog() async {
    final song = await showDialog<Song>(
      context: context,
      builder: (context) => const SpotifySearchDialog(),
    );
    if (song != null) {
      _addSong(song);
    }
  }

  /// Fallback: add a song manually (for when Spotify is not connected).
  void _addManualSong() {
    setState(() {
      songList.add(const Song('Unknown Artist', 'Unknown Album', '', 'Manual',
          name: 'New Song', url: '', previewUrl: null));
    });
  }

  void _toggleSelection(int index) {
    final updated = Set<int>.from(widget.selectedIndices);
    if (updated.contains(index)) {
      updated.remove(index);
    } else {
      updated.add(index);
    }
    widget.onSelectionChanged(updated);
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: ReorderableListView(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          onReorder: (int oldIndex, int newIndex) {
            setState(() {
              if (oldIndex < newIndex) newIndex -= 1;
              final switchedSong = songList.removeAt(oldIndex);
              songList.insert(newIndex, switchedSong);
            });
            _saveSongs();
          },
          header: Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Center(
              child: FloatingActionButton.extended(
                onPressed: widget.spotifyConnected
                    ? _showSpotifySearchDialog
                    : _addManualSong,
                tooltip: widget.spotifyConnected
                    ? 'Search Spotify for a song'
                    : 'Add a song (connect Spotify to search)',
                icon: Icon(widget.spotifyConnected ? Icons.search : Icons.add),
                label: Text(widget.spotifyConnected ? 'Search Spotify' : 'Add Song'),
                backgroundColor:
                    widget.spotifyConnected ? const Color(0xFF1DB954) : null,
              ),
            ),
          ),
          children: <Widget>[
            for (int index = 0; index < songList.length; index += 1)
              SongTile(
                key: Key('$index'),
                song: songList[index],
                index: index,
                selected: widget.selectedIndices.contains(index),
                onSelected: () => _toggleSelection(index),
                onLongPress: () => _deleteSong(index),
              ),
          ],
        ),
      ),
    );
  }
}
// ---------------------------------------------------------------------------
// Spotify Search Dialog
// ---------------------------------------------------------------------------

class SpotifySearchDialog extends StatefulWidget {
  const SpotifySearchDialog({super.key});

  @override
  State<SpotifySearchDialog> createState() => _SpotifySearchDialogState();
}

class _SpotifySearchDialogState extends State<SpotifySearchDialog> {
  final _searchController = TextEditingController();
  List<SpotifyTrack> _results = [];
  bool _loading = false;
  String? _error;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _search();
    });
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _results = [];
        _error = null;
        _loading = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final results = await SpotifyApi.searchTracks(query);

    if (mounted && _searchController.text.trim() == query) {
      setState(() {
        _results = results;
        _loading = false;
        if (results.isEmpty) _error = 'No results found for "$query"';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Search Spotify',
                  style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Song name, artist...',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 12),
              if (_loading) const CircularProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final track = _results[index];
                    return ListTile(
                      leading: track.imageUrl != null
                          ? Image.network(track.imageUrl!,
                              width: 48, height: 48, fit: BoxFit.cover)
                          : const Icon(Icons.music_note, size: 48),
                      title: Text(track.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${track.artist} • ${track.album}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () {
                        final song = Song(
                          track.artist,
                          track.album,
                          '', // genre (Spotify search doesn't return genre)
                          'Spotify',
                          name: track.name,
                          url: track.spotifyUrl,
                          imageUrl: track.imageUrl,
                          previewUrl: track.previewUrl,
                        );
                        Navigator.of(context).pop(song);
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),    );
  }
}
// ---------------------------------------------------------------------------
// Song Tile with Audio Playback
// ---------------------------------------------------------------------------

class SongTile extends StatefulWidget {
  const SongTile({
    super.key,
    required this.song,
    required this.index,
    required this.selected,
    required this.onSelected,
    this.onLongPress,
  });
  final VoidCallback? onLongPress;
  final VoidCallback onSelected;
  final bool selected;
  final Song song;
  final int index;


  @override
  State<SongTile> createState() => _SongTileState();
}

class _SongTileState extends State<SongTile> with SingleTickerProviderStateMixin {
  html.AudioElement? _audioElement;
  bool _isPlaying = false;
  bool _isCurrentTrack = false;
  bool _isHovered = false;
  late AnimationController _longPressController;
  bool _longPressing = false;

  @override
  void initState() {
    super.initState();
    _longPressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _longPressController.addStatusListener((status) {
      if (status == AnimationStatus.completed && _longPressing) {
        _longPressing = false;
        widget.onLongPress?.call();
        _longPressController.reset();
      }
    });
    // Set up preview player as fallback
    if (widget.song.previewUrl != null) {
      _audioElement = html.AudioElement(widget.song.previewUrl!);
      _audioElement!.onEnded.listen((_) {
        if (mounted) {
          setState(() => _isPlaying = false);
        }
      });
    }

    // Listen to SDK playback state
    SpotifyPlayer.instance.playbackState.listen((state) {
      if (!mounted) return;
      final currentUri = SpotifyPlayer.instance.currentTrackUri;
      final thisTrackUri = _getTrackUri();
      
      setState(() {
        _isCurrentTrack = currentUri == thisTrackUri;
        if (_isCurrentTrack) {
          _isPlaying = state == PlaybackState.playing;
        } else if (_isPlaying && !_isCurrentTrack) {
          _isPlaying = false;
        }
      });
    });
  }

  @override
  void dispose() {
    _longPressController.dispose();
    _audioElement?.pause();
    _audioElement = null;
    super.dispose();
  }

  /// Extract Spotify track URI from URL (e.g., spotify:track:xxx).
  String? _getTrackUri() {
    final url = widget.song.url;
    if (url.isEmpty) return null;
    
    // URL format: https://open.spotify.com/track/TRACK_ID
    final match = RegExp(r'track/([a-zA-Z0-9]+)').firstMatch(url);
    if (match != null) {
      return 'spotify:track:${match.group(1)}';
    }
    return null;
  }

  Future<void> _togglePlayback() async {
    final player = SpotifyPlayer.instance;
    final trackUri = _getTrackUri();

    // Use SDK if available and song is from Spotify
    if (player.isReady && trackUri != null) {
      if (_isCurrentTrack && _isPlaying) {
        // Pause current track
        player.pause();
      } else if (_isCurrentTrack && !_isPlaying) {
        // Resume current track
        player.resume();
      } else {
        // Play new track
        await player.playTrack(trackUri);
      }
      return;
    }

    // Fallback to preview
    if (_audioElement != null) {
      setState(() {
        if (_isPlaying) {
          _audioElement!.pause();
          _isPlaying = false;
        } else {
          _audioElement!.play();
          _isPlaying = true;
        }
      });
    } else {
      // No preview or SDK, open in Spotify
      _openInSpotify();
    }
  }

  void _openInSpotify() {
    if (widget.song.url.isNotEmpty) {
      html.window.open(widget.song.url, '_blank');
    }
  }


  @override
  Widget build(BuildContext context) {
    final hasFullPlayback = SpotifyPlayer.instance.isReady && _getTrackUri() != null;
    
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onLongPressStart: (_) {
          _longPressing = true;
          _longPressController.forward(from: 0);
        },
        onLongPressEnd: (_) {
          _longPressing = false;
          _longPressController.reset();
        },
        onLongPressCancel: () {
          _longPressing = false;
          _longPressController.reset();
        },
        child: AnimatedBuilder(
          animation: _longPressController,
          builder: (context, child) {
            final progress = _longPressController.value;
            return Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: progress > 0
                    ? Colors.red.withValues(alpha: progress * 0.3)
                    : null,
              ),
              child: child,
            );
          },
          child: ListTile(
          shape: RoundedRectangleBorder(
            side: _isHovered
                ? const BorderSide(width: 1.5, color: Colors.grey)
                : BorderSide.none,
            borderRadius: BorderRadius.circular(12),
          ),
          key: Key('${widget.index}'),
          tileColor: widget.selected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.12)
              : Theme.of(context).scaffoldBackgroundColor,
          contentPadding: const EdgeInsets.symmetric(vertical: 1, horizontal: 16),
          title: SizedBox(
            height: 70,
            width: 500,
            child: Row(
              spacing: 5,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 40,
                  child: _isHovered || widget.selected
                      ? Checkbox(
                          value: widget.selected,
                          onChanged: (_) => widget.onSelected(),
                        )
                      : Center(
                          child: Text(
                            '${widget.index + 1}',
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ),
                ),
              Container(
                width: 70,
                height: 70,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black, width: 2),
                  shape: BoxShape.rectangle,
                ),
                child: widget.song.imageUrl != null
                    ? Image.network(widget.song.imageUrl!, fit: BoxFit.cover)
                    : const Center(child: Text("Album\nCover")),
              ),
              Flexible(
                child: Container(
                  width: 450,
                  height: 70,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${widget.song.name}\n${widget.song.artist}\n${widget.song.album}',
                      textAlign: TextAlign.justify,
                      style: const TextStyle(fontSize: 14),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed: _togglePlayback,
                iconSize: 36,
                tooltip: hasFullPlayback
                    ? _isPlaying
                        ? "Pause"
                        : "Play full song"
                    : widget.song.previewUrl != null
                        ? _isPlaying
                            ? "Pause preview"
                            : "Play 30s preview"
                        : "Open in Spotify",
                icon: Icon(
                  _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                  color: _isCurrentTrack ? const Color(0xFF1DB954) : Colors.green,
                ),
              ),
            ],
          ),
        ),
        ),
      ),
      ),
    );
  }
}
