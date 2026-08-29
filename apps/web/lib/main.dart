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
  final Map<String, int> _lastModifiedMap = {};
  WebSocketChannel? _channel;
  final Map<String, String> _remoteWrites = {};
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
        try {
          final data = jsonDecode(message.toString());
          if (data['type'] == 'FILE_UPDATE') {
            final path = data['path'] as String;
            final payload = data['payload'] as String;
            final hash = hashFileContent(payload);
            
            _remoteWrites[path] = hash;
            
            final fileHandle = await getFileHandleByPath(_directoryHandle!, path);
            final writable = await fileHandle.createWritable().toDart;
            await writable.write(payload.toJS).toDart;
            await writable.close().toDart;
            
            _projectManifest[path] = hash;
            setState(() {
              _statusMessage = 'Arquivo [$path] atualizado remotamente via WS!';
            });
          } else if (data['type'] == 'FILE_DELETE') {
            final path = data['path'] as String;
            _remoteWrites[path] = 'DELETED';
            
            try {
              await deleteEntryByPath(_directoryHandle!, path);
            } catch (_) {}
            
            _projectManifest.remove(path);
            _lastModifiedMap.remove(path);
            
            setState(() {
              _statusMessage = 'Arquivo [$path] deletado remotamente via WS!';
            });
          } else if (data['type'] == 'DIR_CREATE') {
            final path = data['path'] as String;
            _remoteWrites[path] = 'DIR_CREATED';
            
            await createDirectoryByPath(_directoryHandle!, path);
            _projectManifest[path] = 'DIRECTORY';
            
            setState(() {
              _statusMessage = 'Pasta [$path] criada remotamente via WS!';
            });
          } else if (data['type'] == 'DIR_DELETE') {
            final path = data['path'] as String;
            _remoteWrites[path] = 'DELETED';
            
            try {
              await deleteEntryByPath(_directoryHandle!, path, isDirectory: true);
            } catch (_) {}
            
            _projectManifest.remove(path);
            _lastModifiedMap.remove(path);
            
            setState(() {
              _statusMessage = 'Pasta [$path] deletada remotamente via WS!';
            });
          } else if (data['type'] == 'REQUEST_FULL_SYNC') {
            if (_projectManifest.isNotEmpty && _directoryHandle != null) {
              setState(() {
                _statusMessage = 'Enviando projeto completo para a rede...';
              });
              
              int sent = 0;
              for (final entry in _projectManifest.entries) {
                final path = entry.key;
                final isDirectory = entry.value == 'DIRECTORY';
                
                if (isDirectory) {
                  final message = jsonEncode({
                    'type': 'DIR_CREATE',
                    'path': path,
                  });
                  _channel?.sink.add(message);
                } else {
                  try {
                    final fileHandle = await getFileHandleByPath(_directoryHandle!, path);
                    final content = await _readFileHandleContent(fileHandle);
                    if (content != null) {
                      final message = jsonEncode({
                        'type': 'FILE_UPDATE',
                        'path': path,
                        'payload': content,
                        'hash': entry.value,
                      });
                      _channel?.sink.add(message);
                    }
                  } catch (_) {}
                }
                
                sent++;
                // Throttle: pausa 50ms a cada 5 itens para evitar estouro de buffer no WS / CPU
                if (sent % 5 == 0) {
                  await Future.delayed(const Duration(milliseconds: 50));
                }
              }
              
              setState(() {
                _statusMessage = 'Sincronização completa despachada ($sent itens)!';
              });
            }
          }
        } catch (e) {
          debugPrint(e.toString());
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
    _pollingTimer = Timer.periodic(const Duration(milliseconds: 2000), (timer) async {
      await _scanForChanges();
    });
  }

  Future<void> _scanForChanges() async {
    if (_directoryHandle == null) return;
    
    final currentScanPaths = <String>{};
    
    await scanDirectory(_directoryHandle!, '', (path, handle, kind) async {
      currentScanPaths.add(path);
      try {
        if (kind == 'file') {
          final fileHandle = handle as web.FileSystemFileHandle;
          final file = await fileHandle.getFile().toDart;
          final currentModified = file.lastModified;
          final lastModified = _lastModifiedMap[path] ?? 0;
          
          if (currentModified > lastModified) {
            _lastModifiedMap[path] = currentModified;
            
            final content = await _readFileHandleContent(fileHandle);
            if (content != null) {
              final hash = hashFileContent(content);
              
              if (_remoteWrites[path] == hash) {
                _projectManifest[path] = hash;
                _remoteWrites.remove(path);
                return;
              }
              
              if (_projectManifest[path] != hash) {
                _projectManifest[path] = hash;
                final message = jsonEncode({
                  'type': 'FILE_UPDATE',
                  'path': path,
                  'payload': content,
                  'hash': hash,
                });
                _channel?.sink.add(message);
                setState(() {
                  _statusMessage = 'Alteração em [$path] despachada via WS!';
                });
              }
            }
          }
        } else if (kind == 'directory') {
          if (_remoteWrites[path] == 'DIR_CREATED') {
            _projectManifest[path] = 'DIRECTORY';
            _remoteWrites.remove(path);
            return;
          }
          if (_projectManifest[path] != 'DIRECTORY') {
            _projectManifest[path] = 'DIRECTORY';
            final message = jsonEncode({
              'type': 'DIR_CREATE',
              'path': path,
            });
            _channel?.sink.add(message);
            setState(() {
              _statusMessage = 'Criação de pasta [$path] despachada!';
            });
          }
        }
      } catch (e) {
        debugPrint(e.toString());
      }
    });

    final deletedPaths = _projectManifest.keys.where((p) => !currentScanPaths.contains(p)).toList();
    deletedPaths.sort((a, b) => b.length.compareTo(a.length));

    for (final path in deletedPaths) {
      final isDirectory = _projectManifest[path] == 'DIRECTORY';
      
      if (_remoteWrites[path] == 'DELETED') {
        _projectManifest.remove(path);
        _lastModifiedMap.remove(path);
        _remoteWrites.remove(path);
        continue;
      }

      _projectManifest.remove(path);
      _lastModifiedMap.remove(path);
      
      final message = jsonEncode({
        'type': isDirectory ? 'DIR_DELETE' : 'FILE_DELETE',
        'path': path,
      });
      _channel?.sink.add(message);
      
      setState(() {
        _statusMessage = 'Deleção de [$path] despachada via WS!';
      });
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

  void _requestFullSync() {
    if (_channel != null) {
      final message = jsonEncode({'type': 'REQUEST_FULL_SYNC'});
      _channel!.sink.add(message);
      setState(() {
        _statusMessage = 'Solicitação de sincronização enviada!';
      });
    }
  }

  Future<void> _buildManifest() async {
    if (_directoryHandle == null) return;
    setState(() {
      _statusMessage = 'Construindo manifest...';
    });
    
    final newManifest = <String, String>{};
    await scanDirectory(_directoryHandle!, '', (path, handle, kind) async {
      if (kind == 'file') {
        final content = await _readFileHandleContent(handle as web.FileSystemFileHandle);
        if (content != null) {
          newManifest[path] = hashFileContent(content);
        }
      } else if (kind == 'directory') {
        newManifest[path] = 'DIRECTORY';
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
        title: const Text('Syncode.dev - v0.3'),
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
              label: const Text('Selecionar Pasta Local'),
            ),
            if (_directoryHandle != null) ...[
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _requestFullSync,
                icon: const Icon(Icons.download),
                label: const Text('Baixar Projeto da Rede'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
