import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main() async {
  try {
    final yt = YoutubeExplode();
    final videoId = 'dQw4w9WgXcQ';
    final video = await yt.videos.get('https://www.youtube.com/watch?v=$videoId');
    final manifest = await yt.videos.streamsClient.getManifest(video.id);
    final stream = manifest.audioOnly.withHighestBitrate();
    print('video title: ${video.title}');
    print('audio stream url: ${stream?.url}');
    yt.close();
  } catch (e, st) {
    print('error: $e');
    print(st);
  }
}
