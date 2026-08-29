import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter/material.dart';
import 'package:syncode_web/utils/crypto_utils.dart';
import 'package:syncode_web/utils/directory_utils.dart';
import 'package:web/web.dart' as web;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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

  // WebRTC P2P (Full Mesh Grid)
  MediaStream? _localStream;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  bool _isScreenSharing = false;
  
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, RTCVideoRenderer> _remoteRenderers = {};
  final Map<String, String> _remoteStreamUsernames = {};
  
  String? _fullscreenUserId;

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
  }

  Future<RTCPeerConnection> _createPeerConnection(String targetUserId) async {
    final configuration = {
      "iceServers": [
        {"url": "stun:stun.l.google.com:19302"},
      ]
    };
    
    final pc = await createPeerConnection(configuration);
    _peerConnections[targetUserId] = pc;
    
    pc.onIceCandidate = (candidate) {
      _channel?.sink.add(jsonEncode({
        'type': 'WEBRTC_ICE',
        'targetUserId': targetUserId,
        'candidate': candidate.toMap(),
      }));
    };
    
    pc.onTrack = (event) {
      if (event.track.kind == 'video') {
        setState(() {
          _remoteRenderers[targetUserId]?.srcObject = event.streams[0];
        });
      }
    };
    
    return pc;
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
               final targetUserId = data['userId'];
               _participants.removeWhere((p) => p['userId'] == targetUserId);
               
               // Limpa os dados P2P
               _peerConnections[targetUserId]?.close();
               _peerConnections.remove(targetUserId);
               
               _remoteRenderers[targetUserId]?.srcObject = null;
               _remoteRenderers[targetUserId]?.dispose();
               _remoteRenderers.remove(targetUserId);
               _remoteStreamUsernames.remove(targetUserId);
               
               if (_fullscreenUserId == targetUserId) {
                 _fullscreenUserId = null;
               }
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
          }
          // --- Sincronização de Arquivos ---
          else if (data['type'] == 'FILE_UPDATE') {
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
            try { await deleteEntryByPath(_directoryHandle!, path); } catch (_) {}
            _projectManifest.remove(path);
            _lastModifiedMap.remove(path);
            setState(() => _statusMessage = 'Arquivo [$path] deletado remotamente via WS!');
          } else if (data['type'] == 'DIR_CREATE') {
            final path = data['path'] as String;
            _remoteWrites[path] = 'DIR_CREATED';
            await createDirectoryByPath(_directoryHandle!, path);
            _projectManifest[path] = 'DIRECTORY';
            setState(() => _statusMessage = 'Pasta [$path] criada remotamente via WS!');
          } else if (data['type'] == 'DIR_DELETE') {
            final path = data['path'] as String;
            _remoteWrites[path] = 'DELETED';
            try { await deleteEntryByPath(_directoryHandle!, path, isDirectory: true); } catch (_) {}
            _projectManifest.remove(path);
            _lastModifiedMap.remove(path);
            setState(() => _statusMessage = 'Pasta [$path] deletada remotamente via WS!');
          } else if (data['type'] == 'REQUEST_FULL_SYNC') {
            if (_projectManifest.isNotEmpty && _directoryHandle != null) {
              setState(() => _statusMessage = 'Calculando delta do projeto...');
              final remoteManifest = Map<String, dynamic>.from(data['manifest'] ?? {});
              int sent = 0;
              for (final entry in _projectManifest.entries) {
                final path = entry.key;
                final isDirectory = entry.value == 'DIRECTORY';
                if (remoteManifest[path] == entry.value) continue;
                
                if (isDirectory) {
                  _channel?.sink.add(jsonEncode({'type': 'DIR_CREATE', 'path': path}));
                } else {
                  try {
                    final fileHandle = await getFileHandleByPath(_directoryHandle!, path);
                    final content = await _readFileHandleContent(fileHandle);
                    if (content != null) {
                      _channel?.sink.add(jsonEncode({
                        'type': 'FILE_UPDATE', 'path': path, 'payload': content, 'hash': entry.value,
                      }));
                    }
                  } catch (_) {}
                }
                sent++;
                if (sent % 5 == 0) await Future.delayed(const Duration(milliseconds: 50));
              }
              setState(() => _statusMessage = 'Sincronização delta despachada ($sent itens alterados)!');
            }
          }
          // --- WebRTC Signaling (Mesh) ---
          else if (data['type'] == 'WEBRTC_STREAM_AVAILABLE') {
            final senderId = data['senderId'];
            if (senderId == _myUserId) return;
            
            final senderName = _participants.firstWhere((p) => p['userId'] == senderId, orElse: () => {'username': 'Desconhecido'})['username'];
            
            final renderer = RTCVideoRenderer();
            await renderer.initialize();
            
            setState(() {
              _remoteRenderers[senderId] = renderer;
              _remoteStreamUsernames[senderId] = senderName;
            });
            
            final pc = await _createPeerConnection(senderId);
            pc.addTransceiver(kind: RTCRtpMediaType.RTCRtpMediaTypeVideo, init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly));
            final offer = await pc.createOffer();
            await pc.setLocalDescription(offer);
            
            _channel?.sink.add(jsonEncode({
              'type': 'WEBRTC_OFFER',
              'targetUserId': senderId,
              'offer': offer.toMap(),
            }));
            
          } else if (data['type'] == 'WEBRTC_STREAM_STOPPED') {
            final senderId = data['senderId'];
            setState(() {
              _peerConnections[senderId]?.close();
              _peerConnections.remove(senderId);
              
              _remoteRenderers[senderId]?.srcObject = null;
              _remoteRenderers[senderId]?.dispose();
              _remoteRenderers.remove(senderId);
              _remoteStreamUsernames.remove(senderId);
              
              if (_fullscreenUserId == senderId) {
                _fullscreenUserId = null;
              }
            });
          } else if (data['type'] == 'WEBRTC_OFFER') {
             // Outro nó está pedindo para assistir nossa transmissão
             final senderId = data['senderId'];
             final pc = await _createPeerConnection(senderId);
             
             if (_localStream != null) {
               _localStream!.getTracks().forEach((track) {
                 pc.addTrack(track, _localStream!);
               });
             }
             
             await pc.setRemoteDescription(RTCSessionDescription(data['offer']['sdp'], data['offer']['type']));
             final answer = await pc.createAnswer();
             await pc.setLocalDescription(answer);
             
             _channel?.sink.add(jsonEncode({
               'type': 'WEBRTC_ANSWER',
               'targetUserId': senderId,
               'answer': answer.toMap(),
             }));
          } else if (data['type'] == 'WEBRTC_ANSWER') {
             final senderId = data['senderId'];
             final pc = _peerConnections[senderId];
             if (pc != null) {
               await pc.setRemoteDescription(RTCSessionDescription(data['answer']['sdp'], data['answer']['type']));
             }
          } else if (data['type'] == 'WEBRTC_ICE') {
             final senderId = data['senderId'];
             final pc = _peerConnections[senderId];
             if (pc != null) {
               await pc.addCandidate(RTCIceCandidate(
                 data['candidate']['candidate'],
                 data['candidate']['sdpMid'],
                 data['candidate']['sdpMLineIndex'],
               ));
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
    _localRenderer.dispose();
    for (var renderer in _remoteRenderers.values) {
      renderer.dispose();
    }
    for (var pc in _peerConnections.values) {
      pc.close();
    }
    super.dispose();
  }

  Future<void> _startScreenShare() async {
    try {
      final mediaConstraints = <String, dynamic>{
        'audio': false,
        'video': true
      };
      _localStream = await navigator.mediaDevices.getDisplayMedia(mediaConstraints);
      _localRenderer.srcObject = _localStream;
      
      // Stop nativo pelo navegador
      _localStream!.getVideoTracks()[0].onEnded = () {
        _stopScreenShare();
      };
      
      setState(() {
        _isScreenSharing = true;
      });
      
      _channel?.sink.add(jsonEncode({
        'type': 'WEBRTC_STREAM_AVAILABLE',
      }));
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  void _stopScreenShare() {
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream = null;
    _localRenderer.srcObject = null;
    
    // Fechar apenas as conexões de espectadores (quem está recebendo nosso vídeo)
    // Para simplificar no modelo Star/Mesh mesclado, fechamos tudo e recriamos se precisarem ver outros
    // Como somos Full Mesh real, não podemos matar as _peerConnections das outras telas!
    // Solução: O backend envia WEBRTC_STREAM_STOPPED, os outros encerram a PC lá.
    // Aqui nós apenas enviamos o evento:
    setState(() {
      _isScreenSharing = false;
      if (_fullscreenUserId == _myUserId) {
        _fullscreenUserId = null;
      }
    });
    
    _channel?.sink.add(jsonEncode({
      'type': 'WEBRTC_STREAM_STOPPED',
    }));
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
                _channel?.sink.add(jsonEncode({
                  'type': 'FILE_UPDATE',
                  'path': path,
                  'payload': content,
                  'hash': hash,
                }));
                setState(() => _statusMessage = 'Alteração em [$path] despachada!');
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
            _channel?.sink.add(jsonEncode({'type': 'DIR_CREATE', 'path': path}));
            setState(() => _statusMessage = 'Criação de pasta [$path] despachada!');
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
      
      _channel?.sink.add(jsonEncode({
        'type': isDirectory ? 'DIR_DELETE' : 'FILE_DELETE',
        'path': path,
      }));
      setState(() => _statusMessage = 'Deleção de [$path] despachada!');
    }
  }

  Future<String?> _readFileHandleContent(web.FileSystemFileHandle fileHandle) async {
    try {
      final file = await fileHandle.getFile().toDart;
      if (file.size > 10 * 1024 * 1024) return null;
      final dynamic bufferAny = await file.arrayBuffer().toDart;
      final jsBuffer = bufferAny as JSArrayBuffer;
      final bytes = jsBuffer.toDart.asUint8List();
      return base64Encode(bytes);
    } catch (e) {
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
      setState(() => _statusMessage = 'Seleção cancelada ou erro: $e');
    }
  }

  void _requestFullSync() {
    if (_channel != null) {
      _channel!.sink.add(jsonEncode({
        'type': 'REQUEST_FULL_SYNC',
        'manifest': _projectManifest,
      }));
      setState(() => _statusMessage = 'Solicitação de sincronização enviada!');
    }
  }

  Future<void> _buildManifest() async {
    if (_directoryHandle == null) return;
    setState(() => _statusMessage = 'Construindo manifest...');
    
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
    setState(() => _statusMessage = 'Manifest gerado! (${newManifest.length} arquivos mapeados)');
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

  Widget _buildVideoTile(String id, RTCVideoRenderer renderer, String username, bool isLocal) {
    return MouseRegion(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            color: Colors.black,
            child: RTCVideoView(renderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
          ),
          
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      isLocal ? "Você" : username,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    )
                  ),
                  if (!isLocal)
                    IconButton(
                      icon: const Icon(Icons.volume_up, color: Colors.white, size: 20),
                      onPressed: () {},
                    ),
                  IconButton(
                    icon: Icon(_fullscreenUserId == id ? Icons.fullscreen_exit : Icons.fullscreen, color: Colors.white, size: 20),
                    onPressed: () {
                      setState(() {
                        if (_fullscreenUserId == id) {
                          _fullscreenUserId = null;
                        } else {
                          _fullscreenUserId = id;
                        }
                      });
                    },
                  )
                ],
              ),
            ),
          )
        ],
      )
    );
  }

  Widget _buildVideoGrid() {
    final activeStreams = <Map<String, dynamic>>[];
    
    if (_isScreenSharing) {
      activeStreams.add({'id': _myUserId, 'renderer': _localRenderer, 'username': 'Você', 'isLocal': true});
    }
    
    for (final entry in _remoteRenderers.entries) {
      activeStreams.add({'id': entry.key, 'renderer': entry.value, 'username': _remoteStreamUsernames[entry.key] ?? 'Desconhecido', 'isLocal': false});
    }
    
    if (activeStreams.isEmpty) {
      return const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.monitor, size: 64, color: Colors.white24),
          SizedBox(height: 16),
          Text('Ninguém está transmitindo ainda.', style: TextStyle(color: Colors.white54, fontSize: 18)),
        ]
      );
    }
    
    if (_fullscreenUserId != null) {
      final streamInfo = activeStreams.firstWhere((s) => s['id'] == _fullscreenUserId, orElse: () => activeStreams[0]);
      return _buildVideoTile(streamInfo['id'], streamInfo['renderer'], streamInfo['username'], streamInfo['isLocal']);
    }
    
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: activeStreams.length == 1 ? 1 : activeStreams.length <= 4 ? 2 : 3,
        childAspectRatio: 16 / 9,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: activeStreams.length,
      itemBuilder: (context, index) {
        final streamInfo = activeStreams[index];
        return _buildVideoTile(streamInfo['id'], streamInfo['renderer'], streamInfo['username'], streamInfo['isLocal']);
      },
    );
  }

  Widget _buildDashboardScreen() {
    return Row(
      children: [
        // Left Column
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
        // Center Column
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
                      _stopScreenShare();
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
                  child: _buildVideoGrid(),
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
                    
                    if (!_isScreenSharing)
                      ElevatedButton.icon(
                        onPressed: _startScreenShare,
                        icon: const Icon(Icons.screen_share),
                        label: const Text('Compartilhar tela'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
                      )
                    else
                      ElevatedButton.icon(
                        onPressed: _stopScreenShare,
                        icon: const Icon(Icons.stop_screen_share),
                        label: const Text('Parar Transmissão'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
                      ),
                      
                    const SizedBox(width: 24),
                    
                    if (!_iAmHost && !_canPairProgram)
                      ElevatedButton.icon(
                        onPressed: () {
                          _channel?.sink.add(jsonEncode({'type': 'REQUEST_PAIR_PROGRAM'}));
                          setState(() => _statusMessage = 'Solicitação enviada ao Host!');
                        },
                        icon: const Icon(Icons.front_hand),
                        label: const Text('Solicitar Acesso (Pair Programming)'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
                      )
                    else ...[
                      ElevatedButton.icon(
                        onPressed: _onSelectFolder,
                        icon: const Icon(Icons.folder),
                        label: const Text('Selecionar Pasta Local'),
                      ),
                      if (_directoryHandle != null) ...[
                        const SizedBox(width: 16),
                        ElevatedButton.icon(
                          onPressed: _requestFullSync,
                          icon: const Icon(Icons.download),
                          label: const Text('Sincronizar Tudo'),
                        ),
                      ]
                    ]
                  ],
                ),
              )
            ],
          ),
        ),
        // Right Column
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
