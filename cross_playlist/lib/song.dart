class Song {
  const Song(
    this.artist,
    this.album,
    this.genre,
    this.streamingPlatform, {
    required this.name,
    required this.url,
    this.imageUrl,
    this.previewUrl,
    this.youtubeVideoId,
  });

  final String name, url, artist, album, genre, streamingPlatform;
  final String? imageUrl;
  final String? previewUrl;

  /// Set for YouTube entries so playback does not rely on parsing [url].
  final String? youtubeVideoId;

  Map<String, dynamic> toMap() => {
    'name': name,
    'artist': artist,
    'album': album,
    'genre': genre,
    'streamingPlatform': streamingPlatform,
    'url': url,
    'imageUrl': imageUrl,
    'previewUrl': previewUrl,
    if (youtubeVideoId != null) 'youtubeVideoId': youtubeVideoId,
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
    youtubeVideoId: map['youtubeVideoId'] as String?,
  );
}
