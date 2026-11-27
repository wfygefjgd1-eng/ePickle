import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:epickle/models/video_item.dart';
import 'package:epickle/services/generic_site_api.dart';
import 'package:epickle/services/source_catalog.dart';
import 'package:epickle/utils/http_client.dart';
import 'package:epickle/utils/http_headers.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  final enabled = Platform.environment['LIVE_SOURCE_TEST'] == '1';

  test(
    'live source diagnostic reaches final media playlists',
    () async {
      final requested =
          (Platform.environment['LIVE_SITE_IDS'] ?? 'chaturbate,stripchat')
              .split(',')
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty);
      final api = GenericSiteApi();
      final failures = <String>[];
      for (final id in requested) {
        try {
          final site = SourceCatalog.byId(id);
          if (site == null) throw StateError('unknown source');
          final feed = await api.fetchFeed(site, limit: 3);
          if (feed.isEmpty) throw StateError('empty feed');
          // ignore: avoid_print
          print('$id feed OK: ${feed.first.url}');
          final detail = await api.getVideoDetail(site, feed.first.url);
          if (detail.streams.isEmpty) throw StateError('no media address');
          // ignore: avoid_print
          print('$id media candidate: ${detail.streams.first.url}');
          await _probeMedia(detail.streams.first, detail.url);
          // Useful when this opt-in test is run manually during source repairs.
          // ignore: avoid_print
          print('$id OK: ${feed.first.url} -> ${detail.streams.first.url}');
        } catch (error) {
          failures.add('$id: $error');
          // ignore: avoid_print
          print('$id FAILED: $error');
        }
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    },
    skip: enabled ? false : 'set LIVE_SOURCE_TEST=1 to probe external sites',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

Future<void> _probeMedia(StreamQuality stream, String pageUrl) async {
  final dio = AppHttpClient.create(
    headers: {
      ...AppHttpHeaders.forMediaUrl(
        stream.url,
        pageUrl: stream.referer ?? pageUrl,
      ),
      ...stream.headers,
    },
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 15),
  );
  final uri = Uri.parse(stream.url);
  if (!uri.path.toLowerCase().contains('.m3u8')) {
    final response = await dio.get<List<int>>(
      stream.url,
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Range': 'bytes=0-2047'},
      ),
    );
    expect(response.statusCode, anyOf(200, 206));
    expect(response.data, isNotEmpty);
    return;
  }

  final response = await dio.get<String>(stream.url);
  expect(response.statusCode, 200);
  final body = response.data ?? '';
  expect(body, contains('#EXTM3U'));
  final variant =
      body.split(RegExp(r'\r?\n')).map((line) => line.trim()).firstWhere(
            (line) => line.isNotEmpty && !line.startsWith('#'),
            orElse: () => '',
          );
  if (variant.isEmpty || body.contains('#EXTINF')) return;
  final variantUrl = uri.resolve(variant).toString();
  final variantResponse = await dio.get<String>(variantUrl);
  expect(variantResponse.statusCode, 200);
  expect(variantResponse.data, contains('#EXTM3U'));
}
