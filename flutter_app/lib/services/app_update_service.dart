import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AppRelease {
  const AppRelease({
    required this.versionCode,
    required this.versionName,
    required this.apkUrl,
    required this.sha256,
    this.notes,
  });

  final int versionCode;
  final String versionName;
  final String apkUrl;
  final String sha256;
  final String? notes;

  factory AppRelease.fromRow(Map<String, dynamic> row) => AppRelease(
    versionCode: row['version_code'] as int,
    versionName: row['version_name'] as String,
    apkUrl: row['apk_url'] as String,
    sha256: (row['sha256'] as String).toLowerCase(),
    notes: row['release_notes'] as String?,
  );
}

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

class AppUpdateService {
  AppUpdateService._();

  /// Newest active release whose version_code is above the installed build, or null.
  static Future<AppRelease?> fetchNewerRelease() async {
    final info = await PackageInfo.fromPlatform();
    final current = int.tryParse(info.buildNumber) ?? 0;
    final rows = await Supabase.instance.client
        .from('app_releases')
        .select()
        .eq('is_active', true)
        .order('version_code', ascending: false)
        .limit(1);
    if (rows.isEmpty) return null;
    final latest = AppRelease.fromRow(rows.first);
    return latest.versionCode > current ? latest : null;
  }

  /// Downloads the APK (reusing a previous verified download), checks its
  /// SHA-256 and opens the system installer.
  static Future<void> downloadAndInstall(
    AppRelease release, {
    required void Function(double? progress) onProgress,
  }) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/update_${release.versionCode}.apk');

    if (!await _hashMatches(file, release.sha256)) {
      await _download(release.apkUrl, file, onProgress);
      if (!await _hashMatches(file, release.sha256)) {
        if (await file.exists()) await file.delete();
        throw const UpdateException(
          'File tải về không toàn vẹn. Vui lòng thử lại.',
        );
      }
    }

    final result = await OpenFilex.open(
      file.path,
      type: 'application/vnd.android.package-archive',
    );
    switch (result.type) {
      case ResultType.done:
        return;
      case ResultType.permissionDenied:
        throw const UpdateException(
          'Hãy cho phép ứng dụng cài đặt từ nguồn này trong Cài đặt, rồi bấm Cài đặt lại.',
        );
      default:
        throw UpdateException('Không mở được trình cài đặt: ${result.message}');
    }
  }

  static Future<bool> _hashMatches(File file, String expected) async {
    if (!await file.exists()) return false;
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == expected;
  }

  static Future<void> _download(
    String shareUrl,
    File target,
    void Function(double? progress) onProgress,
  ) async {
    final id = _driveFileId(shareUrl);
    if (id == null) {
      throw const UpdateException('Liên kết tải bản cập nhật không hợp lệ.');
    }
    // confirm=t skips Drive's "can't scan for viruses" interstitial page.
    final uri = Uri.parse(
      'https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t',
    );

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(uri);
      final response = await request.close();
      if (response.statusCode != 200) {
        throw UpdateException('Tải thất bại (HTTP ${response.statusCode}).');
      }
      final contentType = response.headers.contentType?.mimeType ?? '';
      if (contentType == 'text/html') {
        throw const UpdateException(
          'Google Drive không cho tải file. Kiểm tra quyền chia sẻ của file.',
        );
      }

      final total = response.contentLength;
      var received = 0;
      onProgress(total > 0 ? 0 : null);
      final sink = target.openWrite();
      try {
        await for (final chunk in response) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0) onProgress(received / total);
        }
      } finally {
        await sink.close();
      }
    } on SocketException catch (e) {
      debugPrint('[Update] Download error: $e');
      throw const UpdateException('Không có kết nối mạng để tải bản cập nhật.');
    } finally {
      client.close();
    }
  }

  static String? _driveFileId(String url) {
    final match =
        RegExp(r'/d/([A-Za-z0-9_-]+)').firstMatch(url) ??
        RegExp(r'[?&]id=([A-Za-z0-9_-]+)').firstMatch(url);
    return match?.group(1);
  }
}
