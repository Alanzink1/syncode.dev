import 'package:flutter/material.dart';

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
  String _statusMessage = 'Aguardando seleção da pasta local...';

  void _onSelectFolder() {
    setState(() {
      _statusMessage = 'Botão pressionado. Funcionalidade na próxima etapa.';
    });
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
