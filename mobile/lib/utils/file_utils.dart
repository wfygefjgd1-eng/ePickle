import 'package:flutter/services.dart';

/// Native file helpers. The iOS implementation lives in AppDelegate.swift;
/// on other platforms the channel is absent and calls degrade to false.
class FileUtils {
  FileUtils._();

  static const _channel = MethodChannel('epickle/file_utils');

  /// Marks [path] excluded from iCloud/device backups
  /// (NSURLIsExcludedFromBackupKey). Returns false when unsupported.
  static Future<bool> excludeFromBackup(String path) async {
    try {
      final ok = await _channel.invokeMethod<bool>('excludeFromBackup', path);
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}