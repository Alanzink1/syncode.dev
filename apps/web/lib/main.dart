import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter/material.dart';
import 'package:syncode_web/utils/crypto_utils.dart';
import 'package:syncode_web/utils/directory_utils.dart';
import 'package:web/web.dart' as web;
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  runApp(const SyncodeApp());
}

class SyncodeApp extends StatelessWidget {
  const SyncodeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Syncode.dev',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const SyncodeHome(),
    );
  }
}

class SyncodeHome extends StatefulWidget {
  const SyncodeHome({super.key});

  @override
  State<SyncodeHome> createState() => _SyncodeHomeState();
}

class _SyncodeHomeState extends State<SyncodeHome> {
  web.FileSystemDirectoryHandle? _directoryHandle;
  String _statusMessage = 'Aguardando seleção da pasta local...';
  Timer? _pollingTimer;
  int _lastModified = 0;
  WebSocketChannel? _channel;
  String _lastWrittenContent = '';
  Map<String, String> _projectManifest = {};

  @override
  void initState() {
    super.initState();
    _connectWebSocket();
  }

  void _connectWebSocket() {
    try {
      _channel = WebSocketChannel.connect(Uri.parse('ws://localhost:8080'));
      _channel!.stream.listen((message) async {
        final content = message.toString();
        _lastWrittenContent = content;
        final success = await _writeFileContent('demo.txt', content);
        if (success) {
          setState(() {
            _statusMessage = 'Arquivo atualizado remotamente via WS!';
          });
        }
      });
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _channel?.sink.close();
    super.dispose();
  }

  void _startPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 1000), (timer) async {
      await _checkFileChanges('demo.txt');
    });
  }

  Future<void> _checkFileChanges(String filename) async {
    if (_directoryHandle == null) return;
    try {
      final options = web.FileSystemGetFileOptions(create: false);
      final fileHandle = await _directoryHandle!.getFileHandle(filename, options).toDart;
      final file = await fileHandle.getFile().toDart;
      final currentModified = file.lastModified;
      if (currentModified > _lastModified) {
        _lastModified = currentModified;
        final content = await _readFileContent(filename);
        if (content != null && content != _lastWrittenContent) {
          _lastWrittenContent = content;
          _channel?.sink.add(content);
          setState(() {
            _statusMessage = 'Arquivo alterado e enviado via WS! (Tamanho: ${content.length})';
          });
        }
      }
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  Future<String?> _readFileContent(String filename) async {
    if (_directoryHandle == null) return null;
    try {
      final options = web.FileSystemGetFileOptions(create: true);
      final fileHandle = await _directoryHandle!.getFileHandle(filename, options).toDart;
      final file = await fileHandle.getFile().toDart;
      final dynamic textAny = await file.text().toDart;
      return textAny.toString();
    } catch (e) {
      debugPrint(e.toString());
      return null;
    }
  }

  Future<String?> _readFileHandleContent(web.FileSystemFileHandle fileHandle) async {
    try {
      final file = await fileHandle.getFile().toDart;
      final dynamic textAny = await file.text().toDart;
      return textAny.toString();
    } catch (e) {
      debugPrint(e.toString());
      return null;
    }
  }

  Future<bool> _writeFileContent(String filename, String content) async {
    if (_directoryHandle == null) return false;
    try {
      final options = web.FileSystemGetFileOptions(create: true);
      final fileHandle = await _directoryHandle!.getFileHandle(filename, options).toDart;
      final writable = await fileHandle.createWritable().toDart;
      await writable.write(content.toJS).toDart;
      await writable.close().toDart;
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> _onSelectFolder() async {
    try {
      final jsOptions = JSObject();
      jsOptions['mode'] = 'readwrite'.toJS;
      final promise = globalContext.callMethod('showDirectoryPicker'.toJS, jsOptions) as JSPromise;
      final handle = await promise.toDart as web.FileSystemDirectoryHandle;
      
      setState(() {
        _directoryHandle = handle;
        _statusMessage = 'Pasta selecionada: ${handle.name}';
      });
      await _buildManifest();
      _startPolling();
    } catch (e) {
      setState(() {
        _statusMessage = 'Seleção cancelada ou erro: $e';
      });
    }
  }

  Future<void> _buildManifest() async {
    if (_directoryHandle == null) return;
    setState(() {
      _statusMessage = 'Construindo manifest...';
    });
    
    final newManifest = <String, String>{};
    await scanDirectory(_directoryHandle!, '', (path, fileHandle) async {
      final content = await _readFileHandleContent(fileHandle);
      if (content != null) {
        newManifest[path] = hashFileContent(content);
      }
    });

    _projectManifest = newManifest;
    setState(() {
      _statusMessage = 'Manifest gerado! (${newManifest.length} arquivos mapeados)';
    });
    
    debugPrint(jsonEncode(newManifest));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Syncode.dev - v0.1'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              _statusMessage,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _onSelectFolder,
              icon: const Icon(Icons.folder_open),
              label: const Text('Selecionar Pasta'),
            ),
          ],
        ),
      ),
    );
  }
}
