import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'crypto.dart';

const _configFileName = 'config.json';
const _notesDirName = 'notes';
const _keyCheckMessage = 'secure_notes_key_check_v1';

class StoreConfig {
  final int version;
  final String kdf;
  final int iterations;
  final Uint8List salt;
  final Map<String, dynamic> keyCheck;

  StoreConfig({
    required this.version,
    required this.kdf,
    required this.iterations,
    required this.salt,
    required this.keyCheck,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'kdf': kdf,
        'iterations': iterations,
        'salt': base64Encode(salt),
        'keyCheck': keyCheck,
      };

  static StoreConfig fromJson(Map<String, dynamic> json) {
    return StoreConfig(
      version: json['version'] as int,
      kdf: json['kdf'] as String,
      iterations: json['iterations'] as int,
      salt: Uint8List.fromList(base64Decode(json['salt'] as String)),
      keyCheck: json['keyCheck'] as Map<String, dynamic>,
    );
  }
}

class NoteMeta {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  NoteMeta({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });
}

class Note extends NoteMeta {
  final String body;

  Note({
    required super.id,
    required super.title,
    required super.createdAt,
    required super.updatedAt,
    required this.body,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'body': body,
      };

  static Note fromJson(Map<String, dynamic> json) {
    return Note(
      id: json['id'] as String,
      title: json['title'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      body: json['body'] as String,
    );
  }
}

class SecureStore {
  final String baseDir;
  final StoreConfig config;
  final SecretKey _key;

  SecureStore._(this.baseDir, this.config, this._key);

  static Future<void> initialize({required String baseDir, required String password}) async {
    final dir = Directory(baseDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
      await _hardenPermissions(dir);
    }

    final cfgFile = File(p.join(baseDir, _configFileName));
    if (await cfgFile.exists()) {
      throw StateError('Store already initialized at $baseDir');
    }

    final salt = CryptoUtils.generateRandomBytes(CryptoUtils.saltLengthBytes);
    final key = await CryptoUtils.deriveKey(password: password, salt: salt);

    // key check box
    final keyCheckPayload = await CryptoUtils.encryptBytes(
      plaintext: utf8.encode(_keyCheckMessage),
      key: key,
    );

    final config = StoreConfig(
      version: 1,
      kdf: 'pbkdf2-hmac-sha256',
      iterations: CryptoUtils.pbkdf2Iterations,
      salt: salt,
      keyCheck: keyCheckPayload.toJson(),
    );

    await cfgFile.writeAsString(jsonEncode(config.toJson()));

    final notesDir = Directory(p.join(baseDir, _notesDirName));
    if (!await notesDir.exists()) {
      await notesDir.create(recursive: true);
      await _hardenPermissions(notesDir);
    }
  }

  static Future<bool> exists(String baseDir) async {
    return File(p.join(baseDir, _configFileName)).exists();
  }

  static Future<SecureStore> unlock({required String baseDir, required String password}) async {
    final cfgFile = File(p.join(baseDir, _configFileName));
    if (!await cfgFile.exists()) {
      throw StateError('Store not initialized at $baseDir');
    }
    final cfgJson = jsonDecode(await cfgFile.readAsString()) as Map<String, dynamic>;
    final config = StoreConfig.fromJson(cfgJson);

    final key = await CryptoUtils.deriveKey(
      password: password,
      salt: config.salt,
      iterations: config.iterations,
    );

    // validate key via keyCheck
    try {
      final payload = EncryptedPayload.fromJson(config.keyCheck);
      final clear = await CryptoUtils.decryptBytes(payload: payload, key: key);
      final check = utf8.decode(clear);
      if (check != _keyCheckMessage) {
        throw StateError('Invalid password');
      }
    } catch (_) {
      throw StateError('Invalid password');
    }

    return SecureStore._(baseDir, config, key);
  }

  Future<Note> addNote({required String title, required String body}) async {
    final id = const Uuid().v4();
    final now = DateTime.now().toUtc();
    final note = Note(id: id, title: title, createdAt: now, updatedAt: now, body: body);
    await _writeEncryptedNote(note);
    return note;
  }

  Future<void> updateNote({required String id, required String title, required String body}) async {
    final existing = await getNoteById(id);
    if (existing == null) {
      throw StateError('Note not found: $id');
    }
    final updated = Note(
      id: id,
      title: title,
      createdAt: existing.createdAt,
      updatedAt: DateTime.now().toUtc(),
      body: body,
    );
    await _writeEncryptedNote(updated);
  }

  Future<bool> deleteNoteById(String id) async {
    final file = File(_notePath(id));
    if (await file.exists()) {
      await file.delete();
      return true;
    }
    return false;
  }

  Future<Note?> getNoteById(String id) async {
    final file = File(_notePath(id));
    if (!await file.exists()) return null;
    try {
      final jsonPayload = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final payload = EncryptedPayload.fromJson(jsonPayload);
      final clear = await CryptoUtils.decryptBytes(payload: payload, key: _key);
      final map = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      return Note.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  Future<List<NoteMeta>> listNotes() async {
    final dir = Directory(p.join(baseDir, _notesDirName));
    if (!await dir.exists()) return [];
    final metas = <NoteMeta>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json.enc')) continue;
      final id = p.basename(entity.path).replaceAll('.json.enc', '');
      final note = await getNoteById(id);
      if (note != null) {
        metas.add(NoteMeta(
          id: note.id,
          title: note.title,
          createdAt: note.createdAt,
          updatedAt: note.updatedAt,
        ));
      }
    }
    metas.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return metas;
  }

  Future<List<NoteMeta>> searchNotes(String query) async {
    final dir = Directory(p.join(baseDir, _notesDirName));
    if (!await dir.exists()) return [];
    final metas = <NoteMeta>[];
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.json.enc')) continue;
      final id = p.basename(entity.path).replaceAll('.json.enc', '');
      final note = await getNoteById(id);
      if (note != null) {
        final haystack = (note.title + '\n' + note.body).toLowerCase();
        if (haystack.contains(query.toLowerCase())) {
          metas.add(NoteMeta(
            id: note.id,
            title: note.title,
            createdAt: note.createdAt,
            updatedAt: note.updatedAt,
          ));
        }
      }
    }
    metas.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return metas;
  }

  Future<void> changePassword(String newPassword) async {
    final newSalt = CryptoUtils.generateRandomBytes(CryptoUtils.saltLengthBytes);
    final newKey = await CryptoUtils.deriveKey(password: newPassword, salt: newSalt);

    // Re-encrypt keyCheck with new key
    final newKeyCheck = await CryptoUtils.encryptBytes(
      plaintext: utf8.encode(_keyCheckMessage),
      key: newKey,
    );

    // Rewrite all notes with new key
    final notes = await listNotes();
    for (final meta in notes) {
      final note = await getNoteById(meta.id);
      if (note != null) {
        await _writeEncryptedNote(note, keyOverride: newKey);
      }
    }

    final updatedCfg = StoreConfig(
      version: config.version,
      kdf: config.kdf,
      iterations: config.iterations,
      salt: newSalt,
      keyCheck: newKeyCheck.toJson(),
    );

    final cfgPath = p.join(baseDir, _configFileName);
    await File(cfgPath).writeAsString(jsonEncode(updatedCfg.toJson()));
  }

  Future<void> _writeEncryptedNote(Note note, {SecretKey? keyOverride}) async {
    final clearJson = jsonEncode(note.toJson());
    final payload = await CryptoUtils.encryptBytes(
      plaintext: utf8.encode(clearJson),
      key: keyOverride ?? _key,
    );
    final file = File(_notePath(note.id));
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
      await _hardenPermissions(file.parent);
    }
    await file.writeAsString(jsonEncode(payload.toJson()));
  }

  String _notePath(String id) => p.join(baseDir, _notesDirName, '$id.json.enc');
}

Future<void> _hardenPermissions(FileSystemEntity entity) async {
  // Best-effort hardening on Unix-like systems
  try {
    if (!Platform.isWindows) {
      await Process.run('chmod', ['700', entity.path]);
    }
  } catch (_) {
    // ignore
  }
}