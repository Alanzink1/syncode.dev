import 'dart:convert';
import 'package:crypto/crypto.dart';

String hashFileContent(String content) {
  final bytes = utf8.encode(content);
  final digest = sha256.convert(bytes);
  return digest.toString();
}
