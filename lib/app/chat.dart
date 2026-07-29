import '../gossip/envelope.dart';

/// Chat rides the same envelope as everything else. A message is a payload
/// type, not a subsystem.
///
///   GLOBAL   {"t": "text", "ek": "`my x25519 pub`"}
///            Readable by everyone the mesh reaches. Deliberately plaintext.
///
///   PERSONAL {"to": "8J4K91LP", "enc": "`sealed`", "ek": "`my x25519 pub`"}
///            Only the addressed phone can read the text. Relays carry an
///            opaque blob.
///
/// `ek` rides on every message so that hearing ONE global message from someone
/// is enough to message them privately afterwards. It sits inside the payload,
/// which is covered by the envelope signature, so a relay cannot swap it.
///
/// What encryption does NOT hide, and must never be claimed: that a message
/// exists, who sent it, or who it is for. Store-and-forward means every relay
/// carries it, and routing needs the recipient in the clear. Only the text is
/// protected.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.from,
    required this.to,
    required this.text,
    required this.sentAt,
    required this.hops,
    required this.mine,
    this.encrypted = false,
    this.decryptFailed = false,
  });

  final String id;
  final String from;

  /// null = global.
  final String? to;

  /// Decrypted text, or null when this phone is only a relay and cannot read
  /// it. A relay stores and forwards the message regardless; it just has
  /// nothing to display.
  final String? text;
  final DateTime sentAt;
  final int hops;
  final bool mine;

  /// True when the payload arrived sealed, whether or not we could open it.
  final bool encrypted;

  /// Sealed, addressed to us, and did not open. Either tampering or a key that
  /// no longer matches. Shown as a failure rather than hidden, because a
  /// silently missing message is worse than a visibly broken one.
  final bool decryptFailed;

  bool get isBroadcast => to == null;
  bool get readable => text != null;

  /// Belongs in the thread with [peer], seen from [me]'s side.
  /// `peer == null` is the broadcast thread.
  bool inThreadWith(String? peer, String me) {
    if (peer == null) return isBroadcast;
    if (isBroadcast) return false;
    return (from == peer && to == me) || (from == me && to == peer);
  }

  /// Builds the display model. [decrypt] is called only for a sealed message
  /// addressed to (or sent by) this phone; it returns null when the text cannot
  /// be recovered, which is the normal case for a relay.
  static Future<ChatMessage?> fromEnvelope(
    Envelope e,
    String myFingerprint, {
    Future<String?> Function(
            String sealed, String senderFp, String recipientFp)?
        decrypt,
  }) async {
    if (e.type != EnvelopeType.chat) return null;

    final Map<String, Object?> p;
    try {
      p = decodePayload(e.payload);
    } catch (_) {
      return null; // not a chat payload we understand
    }

    final to = p['to'] as String?;
    final sealed = p['enc'] as String?;
    final plain = p['t'] as String?;
    final mine = e.senderFingerprint == myFingerprint;

    // Plaintext: only legitimate for a global message. A "personal" message
    // arriving unsealed is NOT quietly displayed as private — it is shown for
    // what it is, so a downgrade can never masquerade as encryption.
    if (sealed == null) {
      if (plain == null) return null;
      return ChatMessage(
        id: e.idHex,
        from: e.senderFingerprint,
        to: to,
        text: plain,
        sentAt: e.timestamp,
        hops: e.path.length,
        mine: mine,
      );
    }

    // Sealed. Readable only by the addressed phone, or by the sender opening
    // their own copy.
    final forMe = to != null && to.toUpperCase() == myFingerprint.toUpperCase();
    String? text;
    var failed = false;
    if ((forMe || mine) && decrypt != null && to != null) {
      // The AAD is built as sender>recipient, so both sides must agree on the
      // direction. Passing the pair explicitly stops that being re-derived
      // (and eventually re-derived wrongly) at each call site.
      text = await decrypt(sealed, e.senderFingerprint, to);
      failed = text == null;
    }

    return ChatMessage(
      id: e.idHex,
      from: e.senderFingerprint,
      to: to,
      text: text,
      sentAt: e.timestamp,
      hops: e.path.length,
      mine: mine,
      encrypted: true,
      decryptFailed: failed,
    );
  }
}
