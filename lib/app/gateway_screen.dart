import 'package:flutter/material.dart';

import 'sms_bridge.dart';

/// Turns this phone into a bridge between feature phones and the mesh.
class GatewayScreen extends StatefulWidget {
  const GatewayScreen({super.key, required this.bridge});

  final SmsBridge bridge;

  @override
  State<GatewayScreen> createState() => _GatewayScreenState();
}

class _GatewayScreenState extends State<GatewayScreen> {
  final _number = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.bridge.addListener(_refresh);
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.bridge.removeListener(_refresh);
    _number.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final b = widget.bridge;
    return Scaffold(
      appBar: AppBar(title: const Text('SMS gateway')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Bridge feature phones into the mesh',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text(
                    'This phone needs a SIM with credit. Anyone can text it '
                    '"SOS" and their emergency reaches every Jonaki user '
                    'nearby, even without a smartphone.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 10),
                  // Says plainly which failure this covers and which it does
                  // not. SMS needs the cellular network; the mesh does not.
                  const Text(
                    'Works when the internet is cut but mobile service still '
                    'works — what happened in July 2024. If the towers are '
                    'down too, only the mesh keeps working.',
                    style: TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
          ),
          SwitchListTile(
            value: b.enabled,
            onChanged: b.setEnabled,
            title: const Text('Act as SMS gateway'),
            subtitle: Text(b.listening
                ? 'Listening. Sent ${b.sentThisSession}/'
                    '${SmsBridge.maxSendsPerSession} this session.'
                : 'Off'),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Feature phones to alert',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const Text(
            'These numbers get a text whenever an SOS reaches this phone.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _number,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    hintText: '01712345678',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: () async {
                  await b.addSubscriber(_number.text);
                  _number.clear();
                },
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          for (final n in b.subscribers)
            ListTile(
              dense: true,
              leading: const Icon(Icons.phone_android),
              title: Text(n),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => b.removeSubscriber(n),
              ),
            ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('What a feature phone can text',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'SOS fire building 3\n'
                'SOS medical grandmother collapsed\n'
                'SOS flood second floor water rising\n'
                'সাহায্য আগুন\n\n'
                'The message must start with SOS, HELP, সাহায্য or বিপদ. '
                'Whatever follows is passed on word for word.',
                style: TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Activity', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          if (b.log.isEmpty)
            const Text('Nothing yet.', style: TextStyle(fontSize: 12))
          else
            for (final line in b.log)
              Text('· $line',
                  style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
        ],
      ),
    );
  }
}
