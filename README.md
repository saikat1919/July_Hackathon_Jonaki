# Jonaki · জোনাকি

**Messaging, SOS and disaster mapping that work when the network is gone.**

Built for the Crisis Tech track of a hackathon honouring the July 2024 revolution
in Bangladesh — when the internet was shut off and people could not reach each
other.

Jonaki means firefly. One light is almost nothing; a field of them lights the way.
That is the whole idea: a phone alone is useless in a blackout, but phones
together carry each other's messages.

## What it does

**No internet. No SIM. No tower. No servers.** Phones talk to each other directly
over Bluetooth and Wi-Fi, and every phone relays for every other phone.

- **Global chat** — reaches everyone the mesh can reach, including people several
  hops away that you were never near.
- **Personal chat** — end-to-end encrypted. Relays carry the message but cannot
  read it.
- **SOS** — one button. Sends emergency type, your location, a note and your
  battery level, relayed **ahead of all other traffic**. Full-screen alert on
  every phone that receives it, plus an "I'm safe" cancel.
- **Offline map** — real street tiles bundled in the app, with community reports:
  road blocked, fire, shelter, medical camp, food, water, charging, danger.
  Reports gain confidence as other people confirm them.
- **Store and forward** — a message with nowhere to go waits. When you walk
  within range of someone, it goes. Someone travelling between two cut-off areas
  carries messages between them without doing anything.

## How the mesh works

Everything is the same envelope wearing a different costume: chat, SOS, map
reports and confirmations all ride one store-and-forward pipeline.

```
   compose ──► sign (Ed25519) ──► store ──► offer to peers ──► relay
                                    │
                    dedup by id ────┤
                    ttl bounds hops ┤   SOS outlives its hop budget
                    expiry deletes ─┘   until it expires
```

When two phones meet they exchange lists of message IDs, then send only what the
other is missing, highest priority first — SOS before map reports before chat.

Multi-hop is real: a message from A reaches D by being carried through B and C,
and the app shows the hop count so you can see it happened.

## Security, stated honestly

- Every message is **signed** (Ed25519). Forged or altered messages are dropped
  and never relayed.
- Personal messages are **end-to-end encrypted** (X25519 + AES-GCM). Keys are
  exchanged automatically when phones meet, then **pinned** — a later key
  claiming the same identity is refused and the conflict is shown to the user.
- **A valid signature earns a relay whether or not the sender is known.** Phones
  must forward for strangers or there is no mesh.

What encryption does **not** hide: that a message exists, who sent it, or who it
is addressed to. Store-and-forward requires every relay to carry it. There is no
forward secrecy — keys are long-term. SOS is plaintext **by design**, because a
distress call only one person can read is worse than useless.

## Build

```bash
flutter build apk --release --split-per-abi                          # public
flutter build apk --release --split-per-abi --dart-define=DEMO_BUILD=true
```

The two builds use different mesh service IDs and cannot see each other, so
phones running the demo build stay out of the public network.

The offline basemap is generated, not committed. See [docs/TILES.md](docs/TILES.md).
Release and signing procedure: [docs/RELEASE.md](docs/RELEASE.md).

## Installing

Android only. Allow installation from unknown sources, then **grant every
permission on first launch** — Bluetooth, nearby devices and location are all
required to find other phones. Location is never sent anywhere; Android simply
refuses to let apps discover nearby devices without it.

## Tests

```bash
flutter test
```

156 tests. The interesting ones are the failure paths: a relay cannot decrypt a
personal message, tampered ciphertext is rejected, a forged SOS cancel is
ignored, an expired message does not come back after a restart, and a four-node
simulation proves a message crosses a chain where the ends never meet.

## Attribution

Map tiles © Stadia Maps, © OpenMapTiles, © OpenStreetMap contributors.
