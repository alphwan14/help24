// One-off: give every existing post photo the feed thumbnail that uploads
// from 1.0.10 Patch 3 on make themselves (lib/utils/thumbnail_codec.dart).
//
//   SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… dart run tool/backfill_post_thumbnails.dart          # dry run
//   SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… dart run tool/backfill_post_thumbnails.dart --apply  # write
//
// The dry run writes nothing: it lists the photos without a thumbnail and
// makes each thumbnail in memory to report its size. --apply uploads only the
// missing ones (posts/<id>.thumb.jpg) and never overwrites an existing file,
// so a re-run is safe. Photos themselves are never modified or deleted.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:help24/utils/thumbnail_codec.dart';

const _bucket = 'post-images';

Future<void> main(List<String> args) async {
  final apply = args.contains('--apply');
  final base = Platform.environment['SUPABASE_URL']?.trim();
  final key = Platform.environment['SUPABASE_SERVICE_ROLE_KEY']?.trim();
  if (base == null || base.isEmpty || key == null || key.isEmpty) {
    stderr.writeln('Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.');
    exit(2);
  }
  // Checked here so a malformed key is refused WITHOUT being printed: an
  // invalid header value would otherwise be echoed by dart:io's exception.
  if (!RegExp(r'^[A-Za-z0-9._\-]+$').hasMatch(key)) {
    stderr.writeln('SUPABASE_SERVICE_ROLE_KEY has unexpected characters (an inline comment or quotes?). Not printed.');
    exit(2);
  }
  final client = HttpClient();
  final auth = {'Authorization': 'Bearer $key', 'apikey': key};

  // Every object under posts/, in pages.
  final names = <String>[];
  for (var offset = 0;; offset += 1000) {
    final page = await _json(client, 'POST', '$base/storage/v1/object/list/$_bucket', auth,
        body: {'prefix': 'posts/', 'limit': 1000, 'offset': offset, 'sortBy': {'column': 'name', 'order': 'asc'}});
    final batch = (page as List).map((o) => (o as Map)['name'] as String).toList();
    names.addAll(batch);
    if (batch.length < 1000) break;
  }
  final photo = RegExp(r'^(.+)\.(jpe?g|png|gif|webp)$', caseSensitive: false);
  final existing = names.where((n) => n.endsWith('.thumb.jpg')).toSet();
  final todo = <String>[
    for (final n in names)
      if (!n.endsWith('.thumb.jpg') && photo.hasMatch(n) && !existing.contains('${photo.firstMatch(n)!.group(1)}.thumb.jpg')) n
  ];
  stdout.writeln('${apply ? 'APPLY' : 'DRY RUN'}: ${names.length} objects in posts/, '
      '${existing.length} thumbnails already, ${todo.length} to make');

  var made = 0, failed = 0, photoBytes = 0, thumbBytes = 0;
  for (final name in todo) {
    final stem = photo.firstMatch(name)!.group(1)!;
    final thumbPath = 'posts/$stem.thumb.jpg';
    try {
      final bytes = await _bytes(client, '$base/storage/v1/object/public/$_bucket/posts/$name');
      final thumb = makeThumbnailSync(bytes);
      if (thumb == null) {
        failed++;
        stdout.writeln('  skip  $name (not a decodable image)');
        continue;
      }
      photoBytes += bytes.length;
      thumbBytes += thumb.length;
      if (apply) {
        await _upload(client, '$base/storage/v1/object/$_bucket/$thumbPath', auth, thumb);
      }
      made++;
      stdout.writeln('  ${apply ? 'wrote' : 'would'} $thumbPath  ${bytes.length} -> ${thumb.length} bytes');
    } catch (e) {
      failed++;
      stdout.writeln('  FAIL  $name: $e');
    }
  }
  client.close();
  stdout.writeln('${apply ? 'wrote' : 'would write'} $made thumbnails, $failed failed; '
      'photos ${photoBytes ~/ 1024} KB -> thumbnails ${thumbBytes ~/ 1024} KB');
  if (failed > 0) exit(1);
}

Future<Object?> _json(HttpClient c, String method, String url, Map<String, String> headers, {Object? body}) async {
  final req = await c.openUrl(method, Uri.parse(url));
  headers.forEach(req.headers.set);
  req.headers.contentType = ContentType.json;
  if (body != null) req.write(jsonEncode(body));
  final res = await req.close();
  final text = await res.transform(utf8.decoder).join();
  if (res.statusCode >= 300) throw HttpException('$method $url -> ${res.statusCode} $text');
  return jsonDecode(text);
}

Future<Uint8List> _bytes(HttpClient c, String url) async {
  final res = await (await c.getUrl(Uri.parse(url))).close();
  if (res.statusCode != 200) throw HttpException('GET -> ${res.statusCode}');
  final b = BytesBuilder(copy: false);
  await for (final chunk in res) {
    b.add(chunk);
  }
  return b.takeBytes();
}

Future<void> _upload(HttpClient c, String url, Map<String, String> headers, Uint8List jpeg) async {
  final req = await c.postUrl(Uri.parse(url));
  headers.forEach(req.headers.set);
  req.headers.set('Content-Type', 'image/jpeg');
  req.headers.set('Cache-Control', 'max-age=31536000');
  req.headers.set('x-upsert', 'false');
  req.add(jpeg);
  final res = await req.close();
  final text = await res.transform(utf8.decoder).join();
  if (res.statusCode >= 300) throw HttpException('upload -> ${res.statusCode} $text');
}
