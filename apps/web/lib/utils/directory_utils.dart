import 'dart:js_interop';
import 'dart:js_interop_unsafe';
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
  Future<void> Function(String path, web.FileSystemHandle handle, String kind) onEntry,
) async {
  final entries = await getDirectoryEntries(dirHandle);
  for (final entry in entries) {
    if (shouldIgnore(entry.name)) continue;

    final path = currentPath.isEmpty ? entry.name : '$currentPath/${entry.name}';
    
    if (entry.kind == 'directory') {
      await onEntry(path, entry, 'directory');
      await scanDirectory(entry as web.FileSystemDirectoryHandle, path, onEntry);
    } else if (entry.kind == 'file') {
      await onEntry(path, entry, 'file');
    }
  }
}

Future<web.FileSystemFileHandle> getFileHandleByPath(
  web.FileSystemDirectoryHandle root,
  String path,
) async {
  final parts = path.split('/');
  var current = root;
  for (var i = 0; i < parts.length - 1; i++) {
    final name = parts[i];
    final optionsAny = JSObject();
    optionsAny['create'] = true.toJS;
    final promise = current.callMethod('getDirectoryHandle'.toJS, name.toJS, optionsAny) as JSPromise;
    current = await promise.toDart as web.FileSystemDirectoryHandle;
  }
  final options = web.FileSystemGetFileOptions(create: true);
  final fileHandle = await current.getFileHandle(parts.last, options).toDart;
  return fileHandle as web.FileSystemFileHandle;
}

Future<web.FileSystemDirectoryHandle> createDirectoryByPath(
  web.FileSystemDirectoryHandle root,
  String path,
) async {
  final parts = path.split('/');
  var current = root;
  for (var i = 0; i < parts.length; i++) {
    final name = parts[i];
    final optionsAny = JSObject();
    optionsAny['create'] = true.toJS;
    final promise = current.callMethod('getDirectoryHandle'.toJS, name.toJS, optionsAny) as JSPromise;
    current = await promise.toDart as web.FileSystemDirectoryHandle;
  }
  return current;
}

Future<void> deleteEntryByPath(
  web.FileSystemDirectoryHandle root,
  String path,
  {bool isDirectory = false}
) async {
  final parts = path.split('/');
  var current = root;
  for (var i = 0; i < parts.length - 1; i++) {
    final name = parts[i];
    final optionsAny = JSObject();
    optionsAny['create'] = false.toJS;
    final promise = current.callMethod('getDirectoryHandle'.toJS, name.toJS, optionsAny) as JSPromise;
    current = await promise.toDart as web.FileSystemDirectoryHandle;
  }
  
  final optionsAny = JSObject();
  optionsAny['recursive'] = isDirectory.toJS;
  final promise = current.callMethod('removeEntry'.toJS, parts.last.toJS, optionsAny) as JSPromise;
  await promise.toDart;
}
