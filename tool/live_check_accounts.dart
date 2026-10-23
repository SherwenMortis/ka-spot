// Creates the throwaway accounts the live private-channel check needs, through
// the supported Auth Admin API (POST /auth/v1/admin/users with email_confirm),
// so no auth.users row is ever edited by hand and no e-mail has to be delivered.
//
//   LIVECHECK_SERVICE_KEY=<service_role key> dart run tool/live_check_accounts.dart
//
// The key is only read from the environment and is never printed. The script
// writes tool/live_realtime_private_check.accounts (emailA emailB emailC
// password) and supabase/tmp_live_connect.sql, which links the first two
// accounts as an accepted connection.
//
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math';

Future<void> main() async {
  final env = <String, String>{};
  for (final line in File('.env').readAsLinesSync()) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final i = t.indexOf('=');
    if (i > 0) env[t.substring(0, i)] = t.substring(i + 1).trim();
  }
  final url = env['SUPABASE_URL']!;
  final service = Platform.environment['LIVECHECK_SERVICE_KEY'];
  if (service == null || service.isEmpty) {
    throw StateError('LIVECHECK_SERVICE_KEY is not set');
  }

  final rnd = Random.secure();
  // Throwaway credential: random, never reused, destroyed with the accounts.
  const alphabet = 'abcdefghijkmnpqrstuvwxyz23456789';
  const suffix = 'Aa1!';
  final password = List.generate(16 + suffix.length, (i) =>
          i < 16 ? alphabet[rnd.nextInt(alphabet.length)] : suffix[i - 16])
      .join();

  final client = HttpClient();
  Future<dynamic> call(String method, String path, Map<String, dynamic>? body) async {
    final req = await client.openUrl(method, Uri.parse('$url$path'));
    req.headers
      ..add('apikey', service)
      ..add('Authorization', 'Bearer $service')
      ..contentType = ContentType.json;
    if (body != null) req.write(jsonEncode(body));
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode >= 400) {
      throw StateError('$method $path -> HTTP ${res.statusCode} $text');
    }
    return text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
  }

  // Remove accounts left over from an earlier run so the check is repeatable.
  final listed = await call('GET', '/auth/v1/admin/users?page=1&per_page=500', null);
  final users = listed is List
      ? listed
      : (listed as Map)['users'] as List? ?? const [];
  for (final u in users) {
    final email = (u as Map)['email'] as String?;
    if (email != null && email.startsWith('kaspot.livecheck.')) {
      await call('DELETE', '/auth/v1/admin/users/${u['id']}', null);
      print('removed stale $email');
    }
  }

  final emails = <String>[];
  final ids = <String>[];
  for (final tag in ['a', 'b', 'c']) {
    final email = 'kaspot.livecheck.$tag.20261023@gmail.com';
    final created = await call('POST', '/auth/v1/admin/users', {
      'email': email,
      'password': password,
      'email_confirm': true,
      'app_metadata': {'provider': 'email'},
    });
    final id = created['id'] as String?;
    if (id == null) throw StateError('no id returned for $email: $created');
    emails.add(email);
    ids.add(id);
    print('$email -> $id');
  }
  client.close(force: true);

  File('tool/live_realtime_private_check.accounts')
      .writeAsStringSync('${emails.join(' ')} $password\n');
  File('supabase/tmp_live_connect.sql').writeAsStringSync('''
-- Links the first two throwaway live-check accounts exactly the way the app
-- would: one accepted connection row, stored in the canonical id order.
insert into public.connections (user_a_id, user_b_id)
values (least('${ids[0]}'::uuid, '${ids[1]}'::uuid),
        greatest('${ids[0]}'::uuid, '${ids[1]}'::uuid))
on conflict (user_a_id, user_b_id) do nothing;
''');
  print('wrote accounts file and tmp_live_connect.sql');
}
