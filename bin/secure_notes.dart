import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'package:secure_notepad/store.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show help')
    ..addOption('dir', help: 'Data directory (default: ~/.secure_notes)')
    ..addOption('password-env', help: 'Environment variable name containing the master password', defaultsTo: '')
    ..addOption('command', help: 'Command to run (init, add, list, show, edit, delete, search, change-password)');

  // Subcommand-like options
  final addParser = ArgParser()
    ..addOption('title', help: 'Note title')
    ..addOption('body', help: 'Note body (if omitted, read from stdin)')
    ..addOption('file', help: 'Path to a file to read the body from');

  final showParser = ArgParser()..addOption('id', help: 'Note id', mandatory: true);

  final editParser = ArgParser()
    ..addOption('id', help: 'Note id', mandatory: true)
    ..addOption('title', help: 'New title')
    ..addOption('body', help: 'New body (if omitted and no file, read from stdin)')
    ..addOption('file', help: 'Path to a file to read the new body from');

  final deleteParser = ArgParser()..addOption('id', help: 'Note id', mandatory: true);

  final searchParser = ArgParser()..addOption('query', help: 'Search query', mandatory: true);

  // Pre-scan for global flags anywhere
  final scannedDir = _scanLongOption(arguments, 'dir');
  final scannedPwdEnv = _scanLongOption(arguments, 'password-env');

  // Split args so top-level parser doesn't see subcommand flags
  final idxCmd = arguments.indexWhere((a) => a == '--command');
  final topArgs = idxCmd == -1 ? arguments : arguments.sublist(0, (idxCmd + 2).clamp(0, arguments.length));

  final topResult = parser.parse(topArgs);
  if (topResult['help'] == true) {
    _printUsage(parser);
    _printCommandsUsage(addParser, showParser, editParser, deleteParser, searchParser);
    return;
  }

  final baseDir = _resolveBaseDir(scannedDir ?? topResult['dir'] as String?);
  final password = _resolvePassword(scannedPwdEnv ?? topResult['password-env'] as String?);
  final command = topResult['command'] as String?;

  switch (command) {
    case 'init':
      await _cmdInit(baseDir);
      break;
    case 'add':
      final sub = addParser.parse(_rest(arguments));
      await _requireUnlocked(baseDir, password, (store) async {
        final title = (sub['title'] as String?) ?? await _prompt('Title: ');
        final body = await _getBodyFromOptions(sub['body'] as String?, sub['file'] as String?);
        final note = await store.addNote(title: title.trim(), body: body);
        stdout.writeln('Created note: ${note.id}');
      });
      break;
    case 'list':
      await _requireUnlocked(baseDir, password, (store) async {
        final notes = await store.listNotes();
        for (final n in notes) {
          stdout.writeln('${n.id}\t${n.title}\t${n.updatedAt.toIso8601String()}');
        }
      });
      break;
    case 'show':
      {
        final sub = showParser.parse(_rest(arguments));
        final id = sub['id'] as String;
        await _requireUnlocked(baseDir, password, (store) async {
          final note = await store.getNoteById(id);
          if (note == null) {
            stderr.writeln('Not found: $id');
            exitCode = 2;
            return;
          }
          stdout.writeln('Title: ${note.title}');
          stdout.writeln('Updated: ${note.updatedAt.toIso8601String()}');
          stdout.writeln('');
          stdout.writeln(note.body);
        });
      }
      break;
    case 'edit':
      {
        final sub = editParser.parse(_rest(arguments));
        final id = sub['id'] as String;
        await _requireUnlocked(baseDir, password, (store) async {
          final existing = await store.getNoteById(id);
          if (existing == null) {
            stderr.writeln('Not found: $id');
            exitCode = 2;
            return;
          }
          final newTitle = (sub['title'] as String?) ?? existing.title;
          String newBody = await _getBodyFromOptions(
            sub['body'] as String?,
            sub['file'] as String?,
            fallbackFromStdin: false,
          );
          if (newBody.isEmpty) {
            newBody = await _readFromStdinWithPrompt('Enter new body (Ctrl-D to finish). Leave empty to keep current:\n');
          }
          final bodyToSave = newBody.isEmpty ? existing.body : newBody;
          await store.updateNote(id: id, title: newTitle, body: bodyToSave);
          stdout.writeln('Updated note: $id');
        });
      }
      break;
    case 'delete':
      {
        final sub = deleteParser.parse(_rest(arguments));
        final id = sub['id'] as String;
        await _requireUnlocked(baseDir, password, (store) async {
          final deleted = await store.deleteNoteById(id);
          if (!deleted) {
            stderr.writeln('Not found: $id');
            exitCode = 2;
          } else {
            stdout.writeln('Deleted note: $id');
          }
        });
      }
      break;
    case 'search':
      {
        final sub = searchParser.parse(_rest(arguments));
        final query = (sub['query'] as String).toLowerCase();
        await _requireUnlocked(baseDir, password, (store) async {
          final matches = await store.searchNotes(query);
          for (final n in matches) {
            stdout.writeln('${n.id}\t${n.title}\t${n.updatedAt.toIso8601String()}');
          }
        });
      }
      break;
    case 'change-password':
      await _requireUnlocked(baseDir, password, (store) async {
        final newPassword = await _promptPasswordConfirmed();
        await store.changePassword(newPassword);
        stdout.writeln('Password changed.');
      });
      break;
    default:
      _printUsage(parser);
      _printCommandsUsage(addParser, showParser, editParser, deleteParser, searchParser);
      exitCode = 64; // usage
  }
}

String? _scanLongOption(List<String> args, String name) {
  final flag = '--$name';
  for (int i = 0; i < args.length - 1; i++) {
    if (args[i] == flag) return args[i + 1];
  }
  return null;
}

List<String> _rest(List<String> args) {
  if (args.isEmpty) return const [];
  final idx = args.indexWhere((a) => a == '--command');
  if (idx == -1 || idx + 1 >= args.length) return const [];
  final rest = <String>[];
  final globals = {'--dir', '--password-env', '--help', '-h', '--command'};
  // Start scanning after the command value
  for (int i = idx + 2; i < args.length; i++) {
    final token = args[i];
    if (globals.contains(token)) {
      // Skip this global and its value if present
      if (token == '--dir' || token == '--password-env' || token == '--command') {
        i++; // skip value
      }
      continue;
    }
    rest.add(token);
  }
  return rest;
}

Future<void> _cmdInit(String baseDir) async {
  if (await SecureStore.exists(baseDir)) {
    stderr.writeln('Already initialized at: $baseDir');
    exitCode = 1;
    return;
  }
  final password = await _promptPasswordConfirmed();
  await SecureStore.initialize(baseDir: baseDir, password: password);
  stdout.writeln('Initialized secure store at: $baseDir');
}

String _resolveBaseDir(String? flagDir) {
  if (flagDir != null && flagDir.trim().isNotEmpty) {
    return p.normalize(flagDir);
  }
  final home = Platform.environment['HOME'] ?? '.';
  return p.join(home, '.secure_notes');
}

String? _resolvePassword(String? passwordEnvName) {
  final name = (passwordEnvName ?? '').trim();
  if (name.isEmpty) return null;
  return Platform.environment[name];
}

Future<void> _requireUnlocked(String baseDir, String? existingPassword, Future<void> Function(SecureStore) action) async {
  if (!await SecureStore.exists(baseDir)) {
    stderr.writeln('Store not initialized at: $baseDir. Run with --command init');
    exitCode = 1;
    return;
  }
  final password = existingPassword ?? await _promptPassword('Master password: ', confirm: false);
  final store = await SecureStore.unlock(baseDir: baseDir, password: password);
  await action(store);
}

void _printUsage(ArgParser parser) {
  stdout.writeln('Secure Notepad (encrypted)');
  stdout.writeln('Usage: dart run bin/secure_notes.dart --command <cmd> [options]');
  stdout.writeln(parser.usage);
}

void _printCommandsUsage(ArgParser add, ArgParser show, ArgParser edit, ArgParser del, ArgParser search) {
  stdout.writeln('\nCommands:');
  stdout.writeln('  init                       Initialize a secure store');
  stdout.writeln('  add [--title] [--body|--file]            Add a note');
  stdout.writeln('  list                      List notes');
  stdout.writeln('  show --id <id>            Show a note');
  stdout.writeln('  edit --id <id> [--title] [--body|--file]  Edit a note');
  stdout.writeln('  delete --id <id>          Delete a note');
  stdout.writeln('  search --query <text>     Full-text search');
  stdout.writeln('  change-password           Rotate master password');
}

Future<String> _getBodyFromOptions(String? body, String? filePath, {bool fallbackFromStdin = true}) async {
  if (filePath != null && filePath.trim().isNotEmpty) {
    return File(filePath).readAsString();
  }
  if (body != null) return body;
  if (fallbackFromStdin) {
    return _readFromStdinWithPrompt('Enter body (Ctrl-D to finish):\n');
  }
  return '';
}

Future<String> _readFromStdinWithPrompt(String prompt) async {
  stdout.write(prompt);
  final buffer = StringBuffer();
  try {
    while (true) {
      final line = stdin.readLineSync(encoding: utf8);
      if (line == null) break;
      buffer.writeln(line);
    }
  } catch (_) {}
  return buffer.toString().trimRight();
}

Future<String> _prompt(String prompt) async {
  stdout.write(prompt);
  return stdin.readLineSync(encoding: utf8) ?? '';
}

Future<String> _promptPasswordConfirmed() async {
  final first = await _promptPassword('Create master password: ');
  final second = await _promptPassword('Confirm master password: ');
  if (first != second) {
    stderr.writeln('Passwords do not match.');
    exit(1);
  }
  if (first.trim().isEmpty) {
    stderr.writeln('Password cannot be empty.');
    exit(1);
  }
  return first;
}

Future<String> _promptPassword(String prompt, {bool confirm = true}) async {
  stdout.write(prompt);
  bool changedEcho = false;
  bool prevEcho = true;
  try {
    prevEcho = stdin.echoMode;
    stdin.echoMode = false;
    changedEcho = true;
  } catch (_) {}
  final pwd = stdin.readLineSync(encoding: utf8) ?? '';
  if (changedEcho) {
    try {
      stdin.echoMode = prevEcho;
    } catch (_) {}
  }
  stdout.writeln('');
  return pwd;
}