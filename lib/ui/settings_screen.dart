import 'package:flutter/material.dart';
import '../model/model_manager.dart';
import '../model/model_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback onChanged;

  const SettingsScreen({super.key, required this.onChanged});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ModelManager _modelManager = ModelManager();
  List<ModelOption> _installedModels = [];
  String? _selectedModelId;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  Future<void> _loadModels() async {
    setState(() => _isLoading = true);
    final installedIds = await _modelManager.listInstalledModelIds();
    
    final List<ModelOption> installed = [];
    for (var id in installedIds) {
      // Find in registry or create a generic option
      final registryIdx = modelOptions.indexWhere((opt) => opt.id == id);
      if (registryIdx != -1) {
        installed.add(modelOptions[registryIdx]);
      } else {
        installed.add(ModelOption(
          id: id,
          name: 'Unknown Model ($id)',
          size: 'Unknown size',
          url: '',
        ));
      }
    }

    final prefs = await SharedPreferences.getInstance();
    _selectedModelId = prefs.getString('selected_model_id');

    setState(() {
      _installedModels = installed;
      _isLoading = false;
    });
  }

  Future<void> _deleteModel(ModelOption model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Model'),
        content: Text('Are you sure you want to delete ${model.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _modelManager.deleteModel(model.id);
      widget.onChanged();
      _loadModels();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _installedModels.isEmpty
              ? const Center(child: Text('No models installed.'))
              : ListView.builder(
                  itemCount: _installedModels.length,
                  itemBuilder: (context, index) {
                    final model = _installedModels[index];
                    final isSelected = model.id == _selectedModelId;
                    return ListTile(
                      title: Text(model.name),
                      subtitle: Text(isSelected ? '${model.size} (Currently Active)' : model.size),
                      leading: Icon(isSelected ? Icons.check_circle : Icons.insert_drive_file),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, color: Colors.red),
                        onPressed: () => _deleteModel(model),
                      ),
                    );
                  },
                ),
    );
  }
}
