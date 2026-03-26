import 'dart:convert';
import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

class ChatDocumentService {
  ChatDocumentService._();
  static final ChatDocumentService instance = ChatDocumentService._();

  Future<String> saveDocument(String fileName, String base64Content) async {
    final dir = await getTemporaryDirectory();
    final safeName = _safeFileName(fileName);
    final path = '${dir.path}/$safeName';
    final bytes = base64Decode(base64Content);
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  Future<void> openDocument({
    required String fileName,
    String? fileContent,
    String? localFilePath,
    String? fileUri,
  }) async {
    var path = localFilePath;
    if ((path == null || path.isEmpty) &&
        fileUri != null &&
        fileUri.startsWith('file://')) {
      path = fileUri.replaceFirst('file://', '');
    }
    if ((path == null || path.isEmpty) &&
        fileContent != null &&
        fileContent.isNotEmpty) {
      path = await saveDocument(fileName, fileContent);
    }
    if (path == null || path.isEmpty) {
      throw Exception('No file path available');
    }

    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done) {
      throw Exception(result.message);
    }
  }

  String _safeFileName(String input) {
    final sanitized = input.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (sanitized.isEmpty) return 'document.pdf';
    return sanitized;
  }
}
