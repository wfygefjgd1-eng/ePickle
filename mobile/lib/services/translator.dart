import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/http_client.dart';

/// Free Google Translate endpoint + memory/disk cache.
class Translator {
  Translator({Dio? dio})
      : _dio = dio ??
            AppHttpClient.create(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
            );

  final Dio _dio;
  final Map<String, String> _cache = {};
  static const _diskKey = 'translator_disk_v1';
  // 200 keeps translation coverage for a long session while keeping the
  // per-flush SharedPreferences write small (the whole cache is re-encoded
  // as one string on every burst of title translations).
  static const _maxDiskEntries = 200;
  bool _diskLoaded = false;
  Timer? _persistTimer;
  bool _persisting = false;
  bool _persistQueued = false;

  static final _zhRe = RegExp(r'[\u4e00-\u9fff]');

  bool containsChinese(String text) => _zhRe.hasMatch(text);

  Future<void> _ensureDisk() async {
    if (_diskLoaded) return;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_diskKey);
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw);
        if (map is Map) {
          map.forEach((k, v) {
            if (k is String && v is String && k.isNotEmpty && v.isNotEmpty) {
              _cache.putIfAbsent(k, () => v);
            }
          });
        }
      }
      // Enforce the cap on load too: if the disk file somehow holds more than
      // max entries, keep only the newest tail so the 1-add/1-remove eviction
      // can never pin the cache above the cap for the whole session.
      if (_cache.length > _maxDiskEntries) {
        final keys = _cache.keys.toList();
        for (final k in keys.take(keys.length - _maxDiskEntries)) {
          _cache.remove(k);
        }
      }
      // Only a successful load arms the disk cache; a one-off transient
      // failure (plugin missing / store locked) must not disable it for the
      // entire session.
      _diskLoaded = true;
    } catch (_) {}
  }

  Future<void> _persistDisk() async {
    try {
      final p = await SharedPreferences.getInstance();
      final entries = _cache.entries.toList();
      // Keep newest-ish tail if oversized
      final slice = entries.length > _maxDiskEntries
          ? entries.sublist(entries.length - _maxDiskEntries)
          : entries;
      final map = <String, String>{for (final e in slice) e.key: e.value};
      await p.setString(_diskKey, jsonEncode(map));
    } catch (_) {}
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 750), () {
      unawaited(_flushPersist());
    });
  }

  Future<void> _flushPersist() async {
    if (_persisting) {
      _persistQueued = true;
      return;
    }
    _persisting = true;
    try {
      do {
        _persistQueued = false;
        await _persistDisk();
      } while (_persistQueued);
    } finally {
      _persisting = false;
    }
  }

  Future<String> enToZh(String text) async =>
      _translate(text, from: 'en', to: 'zh-CN');

  Future<String> zhToEn(String text) async =>
      _translate(text, from: 'zh-CN', to: 'en');

  Future<String> _translate(
    String text, {
    required String from,
    required String to,
  }) async {
    final raw = text.trim();
    if (raw.isEmpty) return text;
    if (from == 'en' && to.startsWith('zh') && containsChinese(raw)) {
      return text;
    }
    await _ensureDisk();
    final key = '${from}_$to:$raw';
    final hit = _cache[key];
    if (hit != null) return hit;
    try {
      final encoded = Uri.encodeQueryComponent(
        raw.length > 4500 ? raw.substring(0, 4500) : raw,
      );
      final url =
          'https://translate.googleapis.com/translate_a/single?client=gtx&sl=$from&tl=$to&dt=t&q=$encoded';
      // Must request JSON — AppHttpClient defaults to plain text.
      final res = await _dio.get(
        url,
        options: Options(responseType: ResponseType.json),
      );
      dynamic data = res.data;
      if (data is String) {
        try {
          data = jsonDecode(data);
        } catch (_) {
          return text;
        }
      }
      if (data is! List || data.isEmpty || data[0] is! List) return text;
      final buf = StringBuffer();
      for (final part in data[0] as List) {
        if (part is List && part.isNotEmpty && part[0] != null) {
          buf.write(part[0]);
        }
      }
      final out = buf.toString().trim();
      final result = out.isEmpty ? text : out;
      if (_looksLikeGarbageTitle(result) && !_looksLikeGarbageTitle(raw)) {
        return text;
      }
      _cache[key] = result;
      // Bound RAM the same way disk is bounded: evict the oldest entry once
      // the in-memory cache exceeds the disk cap on a long scrolling session.
      if (_cache.length > _maxDiskEntries) {
        _cache.remove(_cache.keys.first);
      }
      // Batch bursts of title translations into a single disk write.
      _schedulePersist();
      return result;
    } catch (_) {
      return text;
    }
  }

  Future<List<String>> batchEnToZh(List<String> texts) async {
    if (texts.isEmpty) return [];
    await _ensureDisk();
    final out = List<String>.filled(texts.length, '');
    const chunk = 5;
    for (var i = 0; i < texts.length; i += chunk) {
      final end = (i + chunk > texts.length) ? texts.length : i + chunk;
      final futures = <Future<String>>[];
      for (var j = i; j < end; j++) {
        futures.add(enToZh(texts[j]));
      }
      final parts = await Future.wait(futures);
      for (var k = 0; k < parts.length; k++) {
        out[i + k] = parts[k];
      }
    }
    return out;
  }

  static bool _looksLikeGarbageTitle(String t) {
    final s = t.toLowerCase();
    if (s.contains('奖得主') || s.contains('award') || s.contains('winner')) {
      if (s.length < 40) return true;
    }
    if (s.contains('点击') && s.contains('下载')) return true;
    if (s.contains('广告')) return true;
    return false;
  }
}
