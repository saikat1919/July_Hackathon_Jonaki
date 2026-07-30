import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Nicknames, nothing more.
///
/// A contact grants no privilege: any envelope with a valid signature is stored
/// and relayed whether or not you know the sender, because Rakib has to forward
/// for people he has never met or there is no mesh. All a contact does is swap
/// a fingerprint for a name on screen, which is why a typed nickname replaced
/// QR exchange — same result on stage, a fraction of the work.
class Contacts extends ChangeNotifier {
  static const _prefix = 'nick.';

  final Map<String, String> _names = {};
  SharedPreferences? _prefs;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    for (final key in _prefs!.getKeys()) {
      if (key.startsWith(_prefix)) {
        final value = _prefs!.getString(key);
        if (value != null) _names[key.substring(_prefix.length)] = value;
      }
    }
    notifyListeners();
  }

  /// Names a peer told us about themselves. Kept apart from [_names] so a
  /// nickname the user typed always wins: someone else should not be able to
  /// rename themselves on your phone after you have labelled them.
  final Map<String, String> _announced = {};

  /// Falls back to the fingerprint so an unknown sender is still identifiable.
  /// Never silently blank: on an SOS screen "who sent this" always has an answer.
  String nameFor(String fingerprint) {
    final fp = fingerprint.toUpperCase();
    return _names[fp] ?? _announced[fp] ?? fp;
  }

  /// Records a self-declared name. Never persisted and never overrides a
  /// user-set nickname.
  void learnAnnouncedName(String fingerprint, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final fp = fingerprint.toUpperCase();
    if (_announced[fp] == trimmed) return;
    _announced[fp] = trimmed.length > 24 ? trimmed.substring(0, 24) : trimmed;
    notifyListeners();
  }

  bool isKnown(String fingerprint) =>
      _names.containsKey(fingerprint.toUpperCase());

  Future<void> setName(String fingerprint, String name) async {
    final fp = fingerprint.toUpperCase();
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      _names.remove(fp);
      await _prefs?.remove('$_prefix$fp');
    } else {
      _names[fp] = trimmed;
      await _prefs?.setString('$_prefix$fp', trimmed);
    }
    notifyListeners();
  }

  Map<String, String> get all => Map.unmodifiable(_names);
}
