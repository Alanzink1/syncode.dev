import 'dart:js_interop';
import 'package:web/web.dart' as web;

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
