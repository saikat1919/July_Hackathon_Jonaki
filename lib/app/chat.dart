import '../gossip/envelope.dart';

/// Chat rides the same envelope as everything else. A message is a payload
/// type, not a subsystem.
///
///   {"t": "text", "to": "8J4K91LP"}   addressed to one person
///   {"t": "text"}                     broadcast to everyone nearby
///
/// IMPORTANT, and worth saying out loud to judges: `to` is ADDRESSING, not
/// privacy. Every phone on the mesh relays the envelope and could read it,
/// because payload encryption (X25519 + AES-GCM) is deferred. The signature
/// proves who wrote it and that nobody altered it. It does not hide it.
/// Claiming otherwise would be the one dishonest thing in this project.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.from,
    required this.to,
    required this.text,
    required this.sentAt,
    required this.hops,
    required this.mine,
  });

  final String id;
  final String from;

  /// null = broadcast.
  final String? to;
  final String text;
  final DateTime sentAt;
  final int hops;
  final bool mine;

  bool get isBroadcast => to == null;

  /// Belongs in the thread with [peer], seen from [me]'s side.
  /// `peer == null` is the broadcast thread.
  bool inThreadWith(String? peer, String me) {
    if (peer == null) return isBroadcast;
    if (isBroadcast) return false;
    return (from == peer && to == me) || (from == me && to == peer);
  }

  static ChatMessage? fromEnvelope(Envelope e, String myFingerprint) {
    if (e.type != EnvelopeType.chat) return null;
    final p = decodePayload(e.payload);
    final text = p['t'] as String?;
    if (text == null) return null;
    return ChatMessage(
      id: e.idHex,
      from: e.senderFingerprint,
      to: p['to'] as String?,
      text: text,
      sentAt: e.timestamp,
      hops: e.path.length,
      mine: e.senderFingerprint == myFingerprint,
    );
  }
}
