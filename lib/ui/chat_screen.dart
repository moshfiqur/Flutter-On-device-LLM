import 'package:flutter/material.dart';
import '../llm/llm_worker.dart';
import 'dart:async';
import 'settings_screen.dart';

class ChatMessage {
  String text;
  final bool isUser;
  double? tps;

  ChatMessage({required this.text, required this.isUser, this.tps});
}

class ChatScreen extends StatefulWidget {
  final String modelPath;
  final VoidCallback? onSettingsChanged;

  const ChatScreen({super.key, required this.modelPath, this.onSettingsChanged});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<ChatMessage> _messages = [];
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final LlamaWorker _worker = LlamaWorker();
  StreamSubscription? _workerSubscription;
  bool _isLoading = false;
  ChatMessage? _streamingMessage;
  Timer? _timeoutTimer;
  String? _activeRequestId;
  bool _isModelReady = false;

  @override
  void initState() {
    super.initState();
    _initWorker();
  }

  @override
  void didUpdateWidget(covariant ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.modelPath != widget.modelPath) {
      setState(() {
        _isModelReady = false;
      });
      _worker.preloadModel(widget.modelPath);
    }
  }

  Future<void> _initWorker() async {
    await _worker.start();
    _workerSubscription = _worker.responses.listen(_onWorkerResponse);
    setState(() {
      _isModelReady = false;
    });
    _worker.preloadModel(widget.modelPath);
  }

  void _onWorkerResponse(LlamaStreamResponse response) {
    if (response.isWarmup) {
      if (response.error != null) {
        _finalizeMessage('Error loading model: ${response.error}');
      } else {
        setState(() {
          _isModelReady = true;
        });
      }
      return;
    }

    if (response.requestId != null && response.requestId != _activeRequestId) {
      return; // Stale response
    }

    if (response.wasCancelled) {
      _timeoutTimer?.cancel();
      setState(() {
        if (_streamingMessage != null) {
          _messages.remove(_streamingMessage);
        }
        _streamingMessage = null;
        _isLoading = false;
        _activeRequestId = null;
      });
      return;
    }

    if (response.error != null) {
      _finalizeMessage('Error: ${response.error}');
      return;
    }

    if (response.token != null) {
      _resetTimeout();
      setState(() {
        if (_streamingMessage == null) {
          // If the model starts with rubbish, it might not start with '{'
          // but our prompt injected '{' so we should handle that
          String token = response.token!;
          _streamingMessage = ChatMessage(text: token, isUser: false);
          _messages.add(_streamingMessage!);
        } else {
          _streamingMessage!.text += response.token!;
        }
      });
      _scrollToBottom();
    }

    if (response.isDone) {
      _timeoutTimer?.cancel();
      if (_streamingMessage == null) {
        _finalizeMessage('Error: Model returned empty response');
      } else {
        _finalizeMessage(null, tps: response.tokensPerSecond);
      }
    }
  }

  void _resetTimeout() {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(const Duration(seconds: 120), () {
      if (_isLoading) {
        _worker.cancelCurrentGeneration();
        _finalizeMessage('Error: Generation timed out (no activity for 120s)');
      }
    });
  }

  void _finalizeMessage(String? errorText, {double? tps}) {
    setState(() {
      _isLoading = false;
      if (errorText != null) {
        if (_streamingMessage != null) {
          _streamingMessage!.text = errorText;
        } else {
          _messages.add(ChatMessage(text: errorText, isUser: false));
        }
      } else if (_streamingMessage != null) {
        // Just keep the text as is, no parsing
        _streamingMessage!.tps = tps;
      }
      _streamingMessage = null;
      _activeRequestId = null;
    });
    _scrollToBottom();
  }

  void _addMessage(String text, bool isUser) {
    setState(() {
      _messages.add(ChatMessage(text: text, isUser: isUser));
    });
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _handleSend() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isLoading || !_isModelReady) return;

    _controller.clear();
    setState(() => _isLoading = true);
    _addMessage(text, true);

    // Build messages list for the worker (who will handle token budgeting)
    final messages = _messages.map((m) => {
      'role': m.isUser ? 'user' : 'assistant',
      'text': m.text,
    }).toList();

    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    _activeRequestId = requestId;
    _resetTimeout();
    _worker.generate(LlamaRequest(
      modelPath: widget.modelPath,
      requestId: requestId,
      messages: messages,
      systemPrompt: null,
      maxTokens: 128, // Reduced for mobile stability
      temperature: 0.2,
      topP: 0.9,
    ));
  }

  @override
  void dispose() {
    _workerSubscription?.cancel();
    _worker.stop();
    _timeoutTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat with LLM'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => SettingsScreen(
                    onChanged: () {
                      widget.onSettingsChanged?.call();
                    },
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              showAboutDialog(
                context: context,
                children: [Text('Model Path: ${widget.modelPath}')],
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (!_isModelReady)
            const LinearProgressIndicator(minHeight: 3),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: message.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                    children: [
                      Align(
                        alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: message.isUser 
                                ? Theme.of(context).colorScheme.primaryContainer 
                                : Theme.of(context).colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(message.text),
                        ),
                      ),
                      if (!message.isUser && message.tps != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 4, left: 4),
                          child: Text(
                            '${message.tps!.toStringAsFixed(1)} tokens/sec',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
          if (_isLoading && _streamingMessage == null)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: CircularProgressIndicator(),
            ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _handleSend(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _isLoading ? null : _handleSend,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
