// Live, end-to-end check of the PRIVATE Circle-chat Realtime channel.
//
// This is not part of `flutter test`: it talks to the real Supabase project with
// real authenticated users, which is the only way to prove that private-channel
// authorization actually works over the wire. The whole flow — throwaway accounts,
// the accepted connection between two of them, this check and the teardown — is
// driven by:
//
//   powershell -ExecutionPolicy Bypass -File .\tool\live_check_run.ps1
//   powershell -ExecutionPolicy Bypass -File .\tool\live_check_teardown.ps1
//
// It reads the project url + anon key from .env, and the three throwaway emails
// plus their shared password from tool/live_realtime_private_check.accounts
// (one line: emailA emailB emailC password), which live_check_accounts.dart
// writes and which .gitignore keeps out of the repository.
//
// ignore_for_file: avoid_print, depend_on_referenced_packages
import 'dart:async';
import 'dart:io';

import 'package:kaspot/utils/chat_channel.dart';
import 'package:supabase/supabase.dart';

final List<String> _failed = <String>[];

void _check(String name, bool ok, [String detail = '']) {
  print('${ok ? 'PASS' : 'FAIL'}  $name${detail.isEmpty ? '' : '  ($detail)'}');
  if (!ok) _failed.add(name);
}

Future<bool> _waitFor(bool Function() done, Duration limit) async {
  final deadline = DateTime.now().add(limit);
  while (DateTime.now().isBefore(deadline)) {
    if (done()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  return done();
}

Map<String, String> _readEnv() {
  final out = <String, String>{};
  for (final line in File('.env').readAsLinesSync()) {
    final t = line.trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    final i = t.indexOf('=');
    if (i > 0) out[t.substring(0, i)] = t.substring(i + 1).trim();
  }
  return out;
}

Future<SupabaseClient> _login(
    String url, String key, String email, String password) async {
  final client = SupabaseClient(url, key);
  final res = await client.auth.signInWithPassword(email: email, password: password);
  final token = res.session?.accessToken;
  if (token == null) throw StateError('sign in returned no session for $email');
  // The client also does this through its auth listener; do it explicitly so the
  // socket is certainly carrying this user's JWT before the first join.
  await client.realtime.setAuth(token);
  return client;
}

/// Joins [channel] and reports the outcome as a short label.
Future<String> _join(RealtimeChannel channel,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final completer = Completer<String>();
  channel.subscribe((status, error) {
    if (completer.isCompleted) return;
    completer.complete(status == RealtimeSubscribeStatus.subscribed
        ? 'subscribed'
        : '${status.name}: $error');
  });
  return completer.future.timeout(timeout, onTimeout: () => 'timeout');
}

Future<void> main() async {
  final env = _readEnv();
  final url = env['SUPABASE_URL']!, key = env['SUPABASE_ANON_KEY']!;
  final accounts = File('tool/live_realtime_private_check.accounts')
      .readAsStringSync()
      .trim()
      .split(RegExp(r'\s+'));
  if (accounts.length < 4) {
    throw StateError('accounts file must hold emailA emailB emailC password');
  }
  final password = accounts[3];

  final a = await _login(url, key, accounts[0], password);
  final b = await _login(url, key, accounts[1], password);
  final c = await _login(url, key, accounts[2], password);
  final aId = a.auth.currentUser!.id;
  final bId = b.auth.currentUser!.id;
  final cId = c.auth.currentUser!.id;
  print('throwaway users: a=$aId b=$bId (connected) c=$cId (no connection)');

  final ab = chatChannelNameFor(aId, bId);
  final ac = chatChannelNameFor(aId, cId);
  _check('channel name is symmetric for both peers',
      ab == chatChannelNameFor(bId, aId), ab);

  final receivedByA = <Map<String, dynamic>>[];
  final messagesSeenByA = <String>[];
  final chanA = a.channel(ab, opts: const RealtimeChannelConfig(private: true))
    ..onBroadcast(event: 'typing', callback: (p) => receivedByA.add(p))
    // The chat screen mixes Broadcast and Postgres Changes on this one channel,
    // so both bindings must survive the channel becoming private.
    ..onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'circle_messages',
      callback: (p) =>
          messagesSeenByA.add(p.newRecord['sender_id'] as String? ?? 'none'),
    );
  final joinA = await _join(chanA);
  _check('participant A subscribes to the private conversation channel',
      joinA == 'subscribed', joinA);

  final chanB = b.channel(ab, opts: const RealtimeChannelConfig(private: true));
  final joinB = await _join(chanB);
  _check('participant B subscribes to the same private channel',
      joinB == 'subscribed', joinB);

  if (joinA == 'subscribed' && joinB == 'subscribed') {
    // ── Realtime Broadcast delivery between the two peers.
    unawaited(chanB.sendBroadcastMessage(
      event: 'typing',
      payload: {'sender_id': bId, 'state': 'start'},
    ));
    final arrived = await _waitFor(
        () => receivedByA.any((p) => p['sender_id'] == bId && p['state'] == 'start'),
        const Duration(seconds: 8));
    _check('A receives the peer typing broadcast over the private channel',
        arrived, '$receivedByA');

    // ── The sender never sees its own event, so the dots can only ever mean
    //    "the other person is typing".
    final beforeOwn = receivedByA.length;
    unawaited(chanA.sendBroadcastMessage(
      event: 'typing',
      payload: {'sender_id': aId, 'state': 'start'},
    ));
    await Future<void>.delayed(const Duration(seconds: 3));
    _check('A does not receive its own typing broadcast',
        receivedByA.length == beforeOwn &&
            !receivedByA.any((p) => p['sender_id'] == aId),
        '$receivedByA');

    // ── Postgres Changes still stream on a private channel (messages, read
    //    receipts and reactions all depend on it).
    await b.from('circle_messages').insert({
      'sender_id': bId,
      'recipient_id': aId,
      'content': 'live private channel probe ${DateTime.now().microsecondsSinceEpoch}',
    });
    final streamed =
        await _waitFor(() => messagesSeenByA.contains(bId), const Duration(seconds: 12));
    _check('postgres_changes still arrives on the private channel', streamed,
        '$messagesSeenByA');
  }

  // ── An unrelated authenticated user is refused, both on the A-B channel and on
  //    a conversation channel that names them but has no accepted connection.
  final outsiderOnAb = await _join(c.channel(ab,
      opts: const RealtimeChannelConfig(private: true)
    )..onBroadcast(event: 'typing', callback: (_) {}));
  _check('unrelated user C cannot join the A-B conversation channel',
      outsiderOnAb != 'subscribed', outsiderOnAb);

  final outsiderOnAc = await _join(c.channel(ac,
      opts: const RealtimeChannelConfig(private: true)
    )..onBroadcast(event: 'typing', callback: (_) {}));
  _check('user C cannot join chat(a_c) without an accepted connection',
      outsiderOnAc != 'subscribed', outsiderOnAc);

  // ── Public channels are untouched: the map and in-app-notification channels
  //    keep working with no policy at all.
  final publicJoin = await _join(a.channel('kaspot-inapp-$aId')
    ..onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: 'circle_messages',
      callback: (p) {},
    ));
  _check('public channels still subscribe (map / in-app alerts unaffected)',
      publicJoin == 'subscribed', publicJoin);

  await chanA.unsubscribe();
  await chanB.unsubscribe();
  await a.dispose();
  await b.dispose();
  await c.dispose();

  print(_failed.isEmpty
      ? '\nALL LIVE CHECKS PASSED'
      : '\nFAILED LIVE CHECKS: ${_failed.join(' | ')}');
  exit(_failed.isEmpty ? 0 : 1);
}
