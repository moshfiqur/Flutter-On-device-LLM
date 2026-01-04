import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';
import 'model_registry.dart';

class ModelManager {
  static final Logger _log = Logger('ModelManager');
  static const String _selectedModelKey = 'selected_model_id';
  
  final Dio _dio = Dio();

  Future<Directory> getModelsDir() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final modelsDir = Directory(p.join(appDocDir.path, 'models'));
    if (!await modelsDir.exists()) {
      await modelsDir.create(recursive: true);
    }
    return modelsDir;
  }

  Future<String?> getInstalledModelPath() async {
    final prefs = await SharedPreferences.getInstance();
    final selectedId = prefs.getString(_selectedModelKey);
    if (selectedId == null) return null;

    final modelsDir = await getModelsDir();
    final modelFile = File(p.join(modelsDir.path, '$selectedId.gguf'));
    
    if (await modelFile.exists()) {
      return modelFile.path;
    }
    return null;
  }

  Future<void> setSelectedModel(String modelId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedModelKey, modelId);
  }

  Future<void> clearSelectedModel() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_selectedModelKey);
  }

  Future<void> deleteModel(String modelId) async {
    final modelsDir = await getModelsDir();
    final modelFile = File(p.join(modelsDir.path, '$modelId.gguf'));
    if (await modelFile.exists()) {
      await modelFile.delete();
    }
    
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_selectedModelKey) == modelId) {
      await clearSelectedModel();
    }
  }

  Future<void> downloadModel(
    ModelOption option, {
    required Function(int count, int total) onProgress,
    required CancelToken cancelToken,
  }) async {
    final modelsDir = await getModelsDir();
    final targetPath = p.join(modelsDir.path, '${option.id}.gguf');
    final tempPath = '$targetPath.part';

    try {
      _log.info('Starting download for ${option.name} from ${option.url}');
      
      await _dio.download(
        option.url,
        tempPath,
        onReceiveProgress: onProgress,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
        ),
      );

      _log.info('Download completed. Renaming $tempPath to $targetPath');
      final tempFile = File(tempPath);
      await tempFile.rename(targetPath);
      
      await setSelectedModel(option.id);
    } catch (e) {
      _log.severe('Download failed: $e');
      final tempFile = File(tempPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      rethrow;
    }
  }

  Future<bool> isModelInstalled(String modelId) async {
    final modelsDir = await getModelsDir();
    final modelFile = File(p.join(modelsDir.path, '$modelId.gguf'));
    return await modelFile.exists();
  }

  Future<List<String>> listInstalledModelIds() async {
    final modelsDir = await getModelsDir();
    if (!await modelsDir.exists()) return [];
    
    final List<String> ids = [];
    await for (final entity in modelsDir.list()) {
      if (entity is File && entity.path.endsWith('.gguf')) {
        final filename = p.basename(entity.path);
        ids.add(filename.replaceAll('.gguf', ''));
      }
    }
    return ids;
  }
}
