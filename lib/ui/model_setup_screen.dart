import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import '../model/model_registry.dart';
import '../model/model_manager.dart';

class ModelSetupScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const ModelSetupScreen({super.key, required this.onComplete});

  @override
  State<ModelSetupScreen> createState() => _ModelSetupScreenState();
}

class _ModelSetupScreenState extends State<ModelSetupScreen> {
  final ModelManager _modelManager = ModelManager();
  final TextEditingController _customUrlController = TextEditingController();
  
  bool _isDownloading = false;
  double _progress = 0;
  String? _error;
  CancelToken? _cancelToken;

  @override
  void dispose() {
    _customUrlController.dispose();
    _cancelToken?.cancel();
    super.dispose();
  }

  Future<void> _startDownload(ModelOption option) async {
    setState(() {
      _isDownloading = true;
      _progress = 0;
      _error = null;
      _cancelToken = CancelToken();
    });

    try {
      await _modelManager.downloadModel(
        option,
        onProgress: (count, total) {
          if (total > 0) {
            setState(() {
              _progress = count / total;
            });
          }
        },
        cancelToken: _cancelToken!,
      );
      widget.onComplete();
    } catch (e) {
      if (!mounted) return;
      if (e is DioException && e.type == DioExceptionType.cancel) {
        setState(() {
          _isDownloading = false;
          _progress = 0;
        });
      } else {
        setState(() {
          _isDownloading = false;
          _error = 'Download failed: $e';
        });
      }
    }
  }

  void _handleCustomUrl() {
    final url = _customUrlController.text.trim();
    if (url.isEmpty || !Uri.parse(url).isAbsolute) {
      setState(() {
        _error = 'Please enter a valid URL';
      });
      return;
    }

    final option = ModelOption(
      id: 'custom-${DateTime.now().millisecondsSinceEpoch}',
      name: 'Custom Model',
      size: 'Unknown',
      url: url,
    );
    _startDownload(option);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Model Setup'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Select an LLM model to download',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Expanded(
              child: ListView.builder(
                itemCount: modelOptions.length,
                itemBuilder: (context, index) {
                  final option = modelOptions[index];
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      title: Text(option.name),
                      subtitle: Text('Size: ${option.size}'),
                      trailing: IconButton(
                        icon: const Icon(Icons.download),
                        onPressed: _isDownloading ? null : () => _startDownload(option),
                      ),
                    ),
                  );
                },
              ),
            ),
            const Divider(),
            const Text(
              'Or use a custom GGUF URL',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _customUrlController,
              decoration: const InputDecoration(
                labelText: 'GGUF URL',
                border: OutlineInputBorder(),
                hintText: 'https://...',
              ),
              enabled: !_isDownloading,
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: _isDownloading ? null : _handleCustomUrl,
              child: const Text('Download from URL'),
            ),
            if (_isDownloading) ...[
              const SizedBox(height: 24),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text(
                'Downloading: ${(_progress * 100).toStringAsFixed(1)}%',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => _cancelToken?.cancel(),
                child: const Text('Cancel Download', style: TextStyle(color: Colors.red)),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: Colors.red),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
