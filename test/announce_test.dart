import 'dart:convert';

import 'package:crisis_mesh/app/chat.dart';
import 'package:crisis_mesh/app/contacts.dart';
import 'package:crisis_mesh/app/key_directory.dart';
import 'package:crisis_mesh/gossip/envelope.dart';
import 'package:crisis_mesh/gossip/identity.dart';
import 'package:crisis_mesh/store/envelope_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// The announce exists so users never have to think about keys. If it stops
/// working, personal chat silently reverts to "no key from this person yet",
/// which is the exact confusion it was built to remove.
void main() {
  late Identity alice;
  setUpAll(() async => alice = await Identity.generate());

  Future<Envelope> announce({String? name}) => alice.compose(
        type: EnvelopeType.announce,
        payload: encodePayload({
          'ek': base64Encode(alice.encPublicKey),
          'name': ?name,
        }),
        ttl: announceTtl,
      );

  group('announce carries what personal chat needs', () {
    test('one announce is enough to encrypt to that peer', () async {
      final dir = KeyDirectory();
      expect(dir.canEncryptTo(alice.fingerprint), isFalse);

      await dir.learnFrom(await announce());

      expect(dir.canEncryptTo(alice.fingerprint), isTrue,
          reason: 'meeting someone should be enough; no ritual required');
    });

    test('it teaches the signing key too', () async {
      final dir = KeyDirectory();
      await dir.learnFrom(await announce());
      expect(dir[alice.fingerprint]!.signingKey, equals(alice.publicKey));
    });

    test('it is signed like everything else, so a relay cannot forge one',
        () async {
      final e = await announce(name: 'Niloy');
      expect(
        await Identity.verify(e.signingInput, e.signature, e.senderPubkey),
        isTrue,
      );
    });

    test('low ttl keeps it local without stopping distant key learning',
        () async {
      final e = await announce();
      expect(e.ttl, announceTtl);
      expect(e.ttl, lessThan(defaultTtl),
          reason: 'presence is a local fact; ordinary traffic carries keys far');
      expect(e.lifetime, const Duration(minutes: 10));
    });

    test('an announce is never rendered as a chat message', () async {
      expect(await ChatMessage.fromEnvelope(await announce(), 'ANYONE'), isNull,
          reason: 'plumbing must not appear in threads');
    });

    test('it still rides the normal store and priority rules', () async {
      final store = MemoryEnvelopeStore();
      await store.put(await announce());
      expect((await store.offerable()).length, 1);
    });
  });

  group('names', () {
    test('an announced name replaces the hex id', () async {
      final contacts = Contacts();
      expect(contacts.nameFor(alice.fingerprint), alice.fingerprint);

      contacts.learnAnnouncedName(alice.fingerprint, 'Niloy');

      expect(contacts.nameFor(alice.fingerprint), 'Niloy');
    });

    test('a nickname the user typed always beats an announced name', () async {
      // Otherwise a peer could rename themselves on your phone after you have
      // already labelled them, which is both confusing and abusable.
      final contacts = Contacts();
      await contacts.setName(alice.fingerprint, 'Niloy (cousin)');
      contacts.learnAnnouncedName(alice.fingerprint, 'Totally Not Niloy');

      expect(contacts.nameFor(alice.fingerprint), 'Niloy (cousin)');
    });

    test('an empty announced name does not blank out the id', () {
      final contacts = Contacts();
      contacts.learnAnnouncedName(alice.fingerprint, '   ');
      expect(contacts.nameFor(alice.fingerprint), alice.fingerprint);
    });

    test('an absurdly long name is truncated rather than breaking layout', () {
      final contacts = Contacts();
      contacts.learnAnnouncedName(alice.fingerprint, 'x' * 500);
      expect(contacts.nameFor(alice.fingerprint).length, 24);
    });

    test('an announce with no name is harmless', () async {
      final contacts = Contacts();
      final e = await announce();
      final payload = decodePayload(e.payload);
      expect(payload['name'], isNull);
      expect(contacts.nameFor(alice.fingerprint), alice.fingerprint);
    });
  });
}
