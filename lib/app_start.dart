import 'package:flutter/material.dart';
import 'model/model_manager.dart';
import 'ui/model_setup_screen.dart';
import 'ui/chat_screen.dart';

class AppStart extends StatefulWidget {
  const AppStart({super.key});

  @override
  State<AppStart> createState() => _AppStartState();
}

class _AppStartState extends State<AppStart> {
  final ModelManager _modelManager = ModelManager();
  bool _isLoading = true;
  String? _installedPath;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    setState(() => _isLoading = true);
    final path = await _modelManager.getInstalledModelPath();
    if (mounted) {
      setState(() {
        _installedPath = path;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (_installedPath == null) {
      return ModelSetupScreen(onComplete: _checkStatus);
    }

    return ChatScreen(
      modelPath: _installedPath!,
      onSettingsChanged: _checkStatus,
    );
  }
}
