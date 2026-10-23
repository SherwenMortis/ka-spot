/// Supabase Realtime channel naming for 1:1 Circle conversations.
///
/// A Realtime channel is addressed by its literal name, and Broadcast events
/// only reach clients subscribed to that exact name. Building the name as
/// `chat-<self>_<peer>` gives each participant a *different* channel for the
/// same conversation (A joins `chat-A_B`, B joins `chat-B_A`), so neither side
/// ever receives the other's events. Sorting the two user ids makes the name
/// order-independent, which is required for anything that travels over
/// Broadcast — presence and typing state in particular.
///
/// Postgres-change subscriptions are unaffected by the name, because they are
/// filtered by record (table + sender/recipient), not by channel.
library;

import 'package:supabase_flutter/supabase_flutter.dart';

/// The canonical channel name shared by both sides of a conversation.
///
/// [userA] and [userB] are the two participant ids in any order, so
/// `chatChannelNameFor(a, b) == chatChannelNameFor(b, a)` always holds.
String chatChannelNameFor(String userA, String userB) {
  final ids = <String>[userA, userB]..sort();
  return 'chat-${ids[0]}_${ids[1]}';
}

/// Options every conversation channel is created with: `private`.
///
/// A public channel is joined by anybody who can reach the Realtime endpoint and
/// knows the topic, so a conversation name alone would be a bearer secret. On a
/// private channel the server instead runs the `realtime.messages` policies for
/// every join (receive) and every publish, which admits only the two users that
/// still hold an accepted connection — see
/// `supabase/migrations/20261023_private_chat_channel_authorization.sql`.
///
/// Postgres-change bindings keep working on private channels; they remain
/// governed by the RLS of the tables they subscribe to.
const RealtimeChannelConfig chatChannelConfig =
    RealtimeChannelConfig(private: true);
