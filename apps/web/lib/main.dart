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
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark),
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
  
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _roomController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _chatController = TextEditingController();
  
  bool _isConnected = false;
  List<dynamic> _participants = [];
  List<Map<String, dynamic>> _chatMessages = [];
  String _myUserId = '';
  bool _iAmHost = false;
  bool _canPairProgram = false;

  @override
  void initState() {
    super.initState();
  }

  void _connectToRoom(String action, String roomId, String password, String username) {
    if (username.isEmpty || roomId.isEmpty) {
      setState(() => _statusMessage = 'Preencha o Nickname e a Sala.');
      return;
    }
    try {
      _channel = WebSocketChannel.connect(Uri.parse('ws://localhost:8080'));
      
      _channel!.sink.add(jsonEncode({
        'type': action,
        'roomId': roomId,
        'password': password,
        'username': username,
      }));
      
      setState(() {
        _statusMessage = 'Conectando à sala...';
      });

      _channel!.stream.listen((message) async {
        try {
          final data = jsonDecode(message.toString());
          
          if (data['type'] == 'ROOM_JOINED') {
             setState(() {
               _isConnected = true;
               _participants = data['participants'];
               final me = _participants.firstWhere((p) => p['username'] == username);
               _myUserId = me['userId'];
               _iAmHost = me['isHost'];
               _canPairProgram = me['canPairProgram'];
               _statusMessage = 'Conectado! Você é ${_iAmHost ? "Host" : "Visitante"}.';
             });
          } else if (data['type'] == 'USER_JOINED') {
             setState(() {
               _participants.add(data['participant']);
             });
          } else if (data['type'] == 'USER_LEFT') {
             setState(() {
               _participants.removeWhere((p) => p['userId'] == data['userId']);
             });
          } else if (data['type'] == 'CHAT_MESSAGE') {
             setState(() {
               _chatMessages.add({
                 'sender': data['sender'],
                 'message': data['message'],
                 'timestamp': data['timestamp'],
               });
             });
          } else if (data['type'] == 'PERMISSION_UPDATED') {
             setState(() {
               for (var p in _participants) {
                 if (p['userId'] == data['userId']) {
                   p['canPairProgram'] = data['canPairProgram'];
                 }
               }
               if (data['userId'] == _myUserId) {
                 _canPairProgram = data['canPairProgram'];
               }
             });
          } else if (data['type'] == 'ERROR') {
             setState(() {
               _statusMessage = data['message'];
               if (!_isConnected) _channel?.sink.close();
             });
          } else if (data['type'] == 'FILE_UPDATE') {
            final path = data['path'] as String;
            final payload = data['payload'] as String;
            final hash = hashFileContent(payload);
            
            _remoteWrites[path] = hash;
            
            final fileHandle = await getFileHandleByPath(_directoryHandle!, path);
            final writable = await fileHandle.createWritable().toDart;
            
            final bytes = base64Decode(payload);
            await writable.write(bytes.toJS).toDart;
            await writable.close().toDart;
            
            _projectManifest[path] = hash;
            setState(() {
              _statusMessage = 'Arquivo [$path] atualizado remotamente!';
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
                _statusMessage = 'Calculando delta do projeto...';
              });
              
              final remoteManifest = Map<String, dynamic>.from(data['manifest'] ?? {});
              
              int sent = 0;
              for (final entry in _projectManifest.entries) {
                final path = entry.key;
                final isDirectory = entry.value == 'DIRECTORY';
                
                // Delta Sync: só envia se o peer não tiver ou o hash for diferente
                if (remoteManifest[path] == entry.value) {
                  continue;
                }
                
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
                _statusMessage = 'Sincronização delta despachada ($sent itens alterados)!';
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
    if (_directoryHandle == null || !_canPairProgram) return;
    
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
      
      // Ignora arquivos > 10MB por segurança na RAM/WebSocket
      if (file.size > 10 * 1024 * 1024) return null;
      
      final dynamic bufferAny = await file.arrayBuffer().toDart;
      final jsBuffer = bufferAny as JSArrayBuffer;
      final bytes = jsBuffer.toDart.asUint8List();
      return base64Encode(bytes);
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
      final message = jsonEncode({
        'type': 'REQUEST_FULL_SYNC',
        'manifest': _projectManifest,
      });
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
      body: !_isConnected ? _buildLoginScreen() : _buildDashboardScreen(),
    );
  }

  Widget _buildLoginScreen() {
    return Center(
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Syncode Workspace', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 24),
            TextField(
              controller: _usernameController,
              decoration: const InputDecoration(labelText: 'Seu Nickname', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _roomController,
              decoration: const InputDecoration(labelText: 'ID da Sala', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: 'Senha (opcional)', border: OutlineInputBorder()),
              obscureText: true,
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed: () => _connectToRoom('CREATE_ROOM', _roomController.text.trim(), _passwordController.text, _usernameController.text.trim()),
                  child: const Text('Criar Sala (Host)'),
                ),
                ElevatedButton(
                  onPressed: () => _connectToRoom('JOIN_ROOM', _roomController.text.trim(), _passwordController.text, _usernameController.text.trim()),
                  child: const Text('Entrar'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(_statusMessage, style: const TextStyle(color: Colors.red)),
          ],
        ),
      ),
    );
  }

  Widget _buildDashboardScreen() {
    return Row(
      children: [
        // Left Column: Participants
        Container(
          width: 250,
          color: const Color(0xFF121212),
          child: Column(
            children: [
              AppBar(title: const Text('Membros'), backgroundColor: Colors.transparent, elevation: 0),
              Expanded(
                child: ListView.builder(
                  itemCount: _participants.length,
                  itemBuilder: (context, index) {
                    final p = _participants[index];
                    return ListTile(
                      leading: Icon(Icons.person, color: p['canPairProgram'] ? Colors.green : Colors.grey),
                      title: Text('${p['username']} ${p['isHost'] ? "👑" : ""}'),
                      trailing: _iAmHost && !p['isHost']
                          ? IconButton(
                              icon: Icon(p['canPairProgram'] ? Icons.code_off : Icons.code),
                              onPressed: () {
                                _channel?.sink.add(jsonEncode({
                                  'type': 'SYNC_PERMISSION',
                                  'targetUserId': p['userId'],
                                  'canPairProgram': !p['canPairProgram'],
                                }));
                              },
                            )
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        // Center Column: Video & Sync
        Expanded(
          child: Column(
            children: [
              AppBar(
                title: Text('Sala: ${_roomController.text}'),
                backgroundColor: const Color(0xFF1A1A1A),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.exit_to_app, color: Colors.red),
                    onPressed: () {
                      _channel?.sink.close();
                      setState(() {
                        _isConnected = false;
                        _participants.clear();
                        _chatMessages.clear();
                        _directoryHandle = null;
                        _pollingTimer?.cancel();
                      });
                    },
                  ),
                ],
              ),
              Expanded(
                child: Center(
                  child: Text('Ninguém está transmitindo a tela ainda.', style: TextStyle(color: Colors.white54)),
                ),
              ),
              Container(
                height: 100,
                color: const Color(0xFF1A1A1A),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_statusMessage, style: const TextStyle(color: Colors.amber)),
                    const SizedBox(width: 24),
                    ElevatedButton.icon(
                      onPressed: _canPairProgram ? _onSelectFolder : null,
                      icon: const Icon(Icons.folder),
                      label: const Text('Selecionar Pasta Local'),
                    ),
                    if (_directoryHandle != null) ...[
                      const SizedBox(width: 16),
                      ElevatedButton.icon(
                        onPressed: _canPairProgram ? _requestFullSync : null,
                        icon: const Icon(Icons.download),
                        label: const Text('Sincronizar Tudo'),
                      ),
                    ]
                  ],
                ),
              )
            ],
          ),
        ),
        // Right Column: Chat
        Container(
          width: 300,
          color: const Color(0xFF121212),
          child: Column(
            children: [
              AppBar(title: const Text('Chat'), backgroundColor: Colors.transparent, elevation: 0),
              Expanded(
                child: ListView.builder(
                  itemCount: _chatMessages.length,
                  itemBuilder: (context, index) {
                    final msg = _chatMessages[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(msg['sender'], style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.teal)),
                          Text(msg['message']),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _chatController,
                        decoration: const InputDecoration(hintText: 'Digite...', border: OutlineInputBorder()),
                        onSubmitted: (text) {
                          if (text.isNotEmpty) {
                            _channel?.sink.add(jsonEncode({'type': 'CHAT_MESSAGE', 'message': text}));
                            _chatController.clear();
                          }
                        },
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.send),
                      onPressed: () {
                        if (_chatController.text.isNotEmpty) {
                          _channel?.sink.add(jsonEncode({'type': 'CHAT_MESSAGE', 'message': _chatController.text}));
                          _chatController.clear();
                        }
                      },
                    )
                  ],
                ),
              )
            ],
          ),
        ),
      ],
    );
  }
}
