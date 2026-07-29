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

  /// null = the broadcast thread ("Everyone nearby").
  String? _peer;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    await widget.mesh.sendChat(text, to: _peer);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final mesh = widget.mesh;
    final messages = mesh.messagesWith(_peer);
    final known = mesh.knownFingerprints.toList()..sort();

    return Column(
      children: [
        _ThreadPicker(
          peers: known,
          selected: _peer,
          contacts: widget.contacts,
          onChanged: (p) => setState(() => _peer = p),
          onRename: _renameDialog,
        ),
        if (_peer != null)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              'Addressed, not encrypted — relays can read this.',
              style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
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
                              ? 'Message everyone nearby'
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
              label: const Text('Everyone nearby'),
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
            Text(message.text),
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
