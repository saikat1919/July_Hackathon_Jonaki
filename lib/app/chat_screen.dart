import 'package:flutter/material.dart';

import 'chat.dart';
import 'contacts.dart';
import 'mesh_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.mesh, required this.contacts});

  final MeshService mesh;
  final Contacts contacts;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// null = the Global thread.
  String? _peer;

  List<ChatMessage> _messages = const [];

  @override
  void initState() {
    super.initState();
    widget.mesh.addListener(_reload);
    _reload();
  }

  /// Decryption is async, so the thread is materialised rather than computed
  /// inside build().
  Future<void> _reload() async {
    final m = await widget.mesh.messagesWith(_peer);
    if (mounted) setState(() => _messages = m);
  }

  @override
  void dispose() {
    widget.mesh.removeListener(_reload);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final error = await widget.mesh.sendChat(text, to: _peer);
    if (!mounted) return;
    if (error != null) {
      // Refusals are shown, never swallowed. A message the user believes was
      // sent privately but never left is the worst possible outcome.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), duration: const Duration(seconds: 5)),
      );
      return;
    }
    _input.clear();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final mesh = widget.mesh;
    final messages = _messages;
    final known = mesh.knownFingerprints.toList()..sort();

    return Column(
      children: [
        _ThreadPicker(
          peers: known,
          selected: _peer,
          contacts: widget.contacts,
          onChanged: (p) {
            setState(() => _peer = p);
            _reload();
          },
          onRename: _renameDialog,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: _peer == null
              ? Text(
                  known.isEmpty
                      // Without this line the feature is invisible: there is no
                      // way to tell "nobody to talk to yet" from "not built".
                      ? 'Global — everyone the mesh reaches, including through '
                          'hops. Not encrypted.\n'
                          'Personal chats appear as chips above once someone '
                          'is nearby or messages you.'
                      : 'Global — everyone the mesh reaches, including through '
                          'hops. Not encrypted.',
                  style: const TextStyle(fontSize: 11),
                )
              : Row(
                  children: [
                    Icon(
                      mesh.keys.canEncryptTo(_peer!)
                          ? Icons.lock
                          : Icons.lock_open,
                      size: 12,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        mesh.keys.canEncryptTo(_peer!)
                            ? 'Personal — end-to-end encrypted. Relays carry '
                                'it but cannot read it.'
                            : 'No key from this person yet. Ask them to send a '
                                'global message first.',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
        ),
        Expanded(
          child: messages.isEmpty
              ? const Center(child: Text('No messages yet.'))
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.all(8),
                  itemCount: messages.length,
                  itemBuilder: (_, i) => _Bubble(
                    message: messages[i],
                    contacts: widget.contacts,
                  ),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    enabled: mesh.running,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    maxLength: 1000,
                    decoration: InputDecoration(
                      hintText: mesh.running
                          ? (_peer == null
                              ? 'Message everyone'
                              : 'Message ${widget.contacts.nameFor(_peer!)}')
                          : 'Start the mesh first',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: mesh.running ? _send : null,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _renameDialog(String fingerprint) async {
    final controller = TextEditingController(
      text: widget.contacts.isKnown(fingerprint)
          ? widget.contacts.nameFor(fingerprint)
          : '',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Name for $fingerprint'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'e.g. Niloy'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null) {
      await widget.contacts.setName(fingerprint, name);
      if (mounted) setState(() {});
    }
  }
}

class _ThreadPicker extends StatelessWidget {
  const _ThreadPicker({
    required this.peers,
    required this.selected,
    required this.contacts,
    required this.onChanged,
    required this.onRename,
  });

  final List<String> peers;
  final String? selected;
  final Contacts contacts;
  final ValueChanged<String?> onChanged;
  final ValueChanged<String> onRename;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 56,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          children: [
            ChoiceChip(
              label: const Text('Global'),
              selected: selected == null,
              onSelected: (_) => onChanged(null),
            ),
            for (final p in peers) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onLongPress: () => onRename(p),
                child: ChoiceChip(
                  label: Text(contacts.nameFor(p)),
                  selected: selected == p,
                  onSelected: (_) => onChanged(p),
                ),
              ),
            ],
          ],
        ),
      );
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.contacts});

  final ChatMessage message;
  final Contacts contacts;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = message.mine;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
          color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!mine)
              Text(
                contacts.nameFor(message.from),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: scheme.primary,
                ),
              ),
            // A message this phone only relayed has no text to show, and a
            // sealed one that failed to open must look broken rather than
            // silently absent.
            if (message.readable)
              Text(message.text!)
            else if (message.decryptFailed)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline, size: 14, color: scheme.error),
                  const SizedBox(width: 4),
                  Text('Could not decrypt',
                      style: TextStyle(color: scheme.error)),
                ],
              )
            else
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.lock, size: 14, color: scheme.outline),
                  const SizedBox(width: 4),
                  Text('Encrypted — not for you',
                      style: TextStyle(
                          color: scheme.outline,
                          fontStyle: FontStyle.italic)),
                ],
              ),
            const SizedBox(height: 2),
            Text(
              // Hop count is the whole point of the product: it shows the
              // message physically travelled through other people's phones.
              message.hops == 0
                  ? 'direct'
                  : '${message.hops} hop${message.hops == 1 ? '' : 's'}',
              style: TextStyle(fontSize: 10, color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}
