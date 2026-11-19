import 'package:epickle/models/video_item.dart';
import 'package:epickle/utils/playback_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const mp4_480 = StreamQuality(
    width: 854,
    height: 480,
    url: 'https://cdn.test/480.mp4',
  );
  const hls_480 = StreamQuality(
    width: 854,
    height: 480,
    url: 'https://cdn.test/480.m3u8',
  );
  const mp4_720 = StreamQuality(
    width: 1280,
    height: 720,
    url: 'https://cdn.test/720.mp4',
  );
  const hls_720 = StreamQuality(
    width: 1280,
    height: 720,
    url: 'https://cdn.test/720.m3u8',
  );
  const mp4_1080 = StreamQuality(
    width: 1920,
    height: 1080,
    url: 'https://cdn.test/1080.mp4',
  );
  const detail = VideoDetail(
    url: 'https://site.test/watch/1',
    title: 'fixture',
    durationSec: 600,
    streams: [mp4_1080, hls_720, mp4_720, hls_480, mp4_480],
  );

  test('quality pickers prefer progressive MP4 on same resolution', () {
    expect(detail.preferredStream?.url, mp4_720.url);
    expect(detail.bestStream?.url, mp4_1080.url);
    expect(detail.streamForCap(1080)?.url, mp4_1080.url);
    expect(detail.streamForCap(480)?.url, mp4_480.url);
  });

  test('streamCandidates swaps transport before dropping resolution', () {
    final candidates = PlaybackHelpers.streamCandidates(detail, 0);
    expect(candidates.take(2).map((stream) => stream.url), [
      mp4_720.url,
      hls_720.url,
    ]);
  });

  test('1080p cap keeps the 720p HLS fallback as second candidate', () {
    final candidates = PlaybackHelpers.streamCandidates(detail, 1080);
    expect(candidates.first.url, mp4_1080.url);
    expect(candidates[1].url, hls_720.url);
  });
}
