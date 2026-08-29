import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'ignore_utils.dart';

@JS('window.getDirectoryEntries')
external JSPromise _getDirectoryEntriesJS(web.FileSystemDirectoryHandle handle);

Future<List<web.FileSystemHandle>> getDirectoryEntries(web.FileSystemDirectoryHandle handle) async {
  final jsArrayAny = await _getDirectoryEntriesJS(handle).toDart;
  final jsArray = jsArrayAny as JSArray;
  final length = jsArray.length;
  final list = <web.FileSystemHandle>[];
  for (var i = 0; i < length; i++) {
    list.add(jsArray.getProperty(i.toString().toJS) as web.FileSystemHandle);
  }
  return list;
}

Future<void> scanDirectory(
  web.FileSystemDirectoryHandle dirHandle,
  String currentPath,
  void Function(String path, web.FileSystemFileHandle fileHandle) onFile,
) async {
  final entries = await getDirectoryEntries(dirHandle);
  for (final entry in entries) {
    if (shouldIgnore(entry.name)) continue;

    final path = currentPath.isEmpty ? entry.name : '$currentPath/${entry.name}';
    
    if (entry.kind == 'directory') {
      await scanDirectory(entry as web.FileSystemDirectoryHandle, path, onFile);
    } else if (entry.kind == 'file') {
      onFile(path, entry as web.FileSystemFileHandle);
    }
  }
}
