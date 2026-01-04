import 'dart:async';
import 'dart:isolate';
import 'llama_service.dart';

/// Structured event emitted by the worker isolate whenever a token chunk,
/// completion, or error occurs.
class LlamaStreamResponse {
  final String? token;
  final bool isDone;
  final String? error;
  final double? tokensPerSecond;
  final bool wasCancelled;
  final bool isWarmup;
  final String? requestId;

  LlamaStreamResponse({
    this.token,
    this.isDone = false,
    this.error,
    this.tokensPerSecond,
    this.wasCancelled = false,
    this.isWarmup = false,
    this.requestId,
  });
}

class LlamaRequest {
  final String modelPath;
  final String? prompt;
  final List<Map<String, dynamic>>? messages;
  final String? systemPrompt;
  final int maxTokens;
  final double temperature;
  final double topP;
  final String requestId;

  LlamaRequest({
    required this.modelPath,
    required this.requestId,
    this.prompt,
    this.messages,
    this.systemPrompt,
    this.maxTokens = 200,
    this.temperature = 0.2,
    this.topP = 0.9,
  }) : assert(prompt != null || messages != null, 'Either prompt or messages must be provided');
}

class _LlamaLoadRequest {
  final String modelPath;
  _LlamaLoadRequest(this.modelPath);
}

/// Lightweight actor that spins up an isolate dedicated to llama.cpp work.
///
/// The UI sends [`LlamaRequest`] objects via `generate`, and the worker replies
/// with streamed [`LlamaStreamResponse`] events. Stateful concerns such as
/// model hot-swapping, prompt budgeting, and cancellation are handled entirely
/// inside the isolate so the UI thread never blocks on native calls.
class LlamaWorker {
  SendPort? _sendPort;
  Isolate? _isolate;
  final _responseController = StreamController<LlamaStreamResponse>.broadcast();
  static const String _cancelMessage = '__llama_cancel__';

  Stream<LlamaStreamResponse> get responses => _responseController.stream;

  /// Starts the worker isolate and waits until it sends back the control port.
  Future<void> start() async {
    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(_workerEntry, receivePort.sendPort);

    final completer = Completer<void>();
    receivePort.listen((message) {
      if (message is SendPort) {
        _sendPort = message;
        completer.complete();
      } else if (message is LlamaStreamResponse) {
        _responseController.add(message);
      }
    });

    return completer.future;
  }

  /// Sends a new inference request to the isolate.
  void generate(LlamaRequest request) {
    _sendPort?.send(request);
  }

  /// Signals the isolate to abandon the current request (if any).
  void cancelCurrentGeneration() {
    _sendPort?.send(_cancelMessage);
  }

  /// Proactively loads a model path so the first chat message doesn't pay the
  /// full initialization cost.
  void preloadModel(String modelPath) {
    _sendPort?.send(_LlamaLoadRequest(modelPath));
  }

  void stop() {
    _isolate?.kill();
    _responseController.close();
  }

  static void _workerEntry(SendPort mainSendPort) {
    final workerReceivePort = ReceivePort();
    mainSendPort.send(workerReceivePort.sendPort);
    print('[LlamaWorker] Isolate started');

    final service = LlamaService();
    String? currentModelPath;
    bool isGenerating = false;
    bool cancelRequested = false;
    LlamaRequest? pendingRequest;

    late Future<void> Function(LlamaRequest message) processRequest;

    void scheduleNext() {
      if (pendingRequest != null) {
        final next = pendingRequest!;
        pendingRequest = null;
        Future.microtask(() => processRequest(next));
      }
    }

    processRequest = (LlamaRequest message) async {
      if (isGenerating) {
        pendingRequest = message;
        cancelRequested = true;
        return;
      }

      isGenerating = true;
      cancelRequested = false;

        try {
          print('[LlamaWorker] Received request for: ${message.modelPath}');
          if (currentModelPath != message.modelPath) {
            print('[LlamaWorker] Initializing model...');
            service.dispose();
            service.init(modelPath: message.modelPath);
            currentModelPath = message.modelPath;
            print('[LlamaWorker] Model initialized');
          }

          String finalPrompt;
          if (message.messages != null) {
            finalPrompt = _buildBudgetedPrompt(service, message.messages!, message.systemPrompt);
            print('[LlamaWorker] Built budgeted prompt: ${finalPrompt.length} chars');
          } else {
            finalPrompt = message.prompt!;
          }

          if (!service.preparePrompt(finalPrompt)) {
            print('[LlamaWorker] Failed to prepare prompt');
            mainSendPort.send(LlamaStreamResponse(
              error: 'Failed to prepare prompt',
              isDone: true,
              requestId: message.requestId,
            ));
            isGenerating = false;
            scheduleNext();
            return;
          }
          print('[LlamaWorker] Prompt prepared. Starting generation...');

          final stopwatch = Stopwatch()..start();
          int tokenCount = 0;

          final generatedBuffer = StringBuffer();
          int sentCount = 0;
          final stopWords = ['<|user|>', '<|im_start|>', '<|im_end|>'];

          for (int i = 0; i < message.maxTokens; i++) {
            if (cancelRequested) {
              print('[LlamaWorker] Generation cancelled');
              mainSendPort.send(LlamaStreamResponse(
                isDone: true,
                wasCancelled: true,
                requestId: message.requestId,
              ));
              break;
            }

            final token = await Future<String?>(
              () => service.getNextToken(
                temperature: message.temperature,
                topP: message.topP,
              ),
            );

            if (token == null) {
              print('[LlamaWorker] Generation reached EOS');
              break;
            }
            
            generatedBuffer.write(token);
            final currentGen = generatedBuffer.toString();
            
            // 1. Check for full stop words
            bool shouldStop = false;
            for (final sw in stopWords) {
              if (currentGen.contains(sw)) {
                shouldStop = true;
                break;
              }
            }
            if (shouldStop) {
               print('[LlamaWorker] Stop sequence detected. Stopping.');
               break; 
            }

            // 2. Safe-to-send logic (Buffering)
            // We only need to hold back if the new content *might* be a prefix of a stop word.
            // All our stop words start with '<'.
            
            final freshContent = currentGen.substring(sentCount);
            final relativeIndex = freshContent.lastIndexOf('<');
            
            if (relativeIndex == -1) {
              // No new '<', safe to send everything
              if (freshContent.isNotEmpty) {
                 mainSendPort.send(LlamaStreamResponse(token: freshContent, requestId: message.requestId));
                 sentCount = currentGen.length;
              }
            } else {
              // We have a '<', check if it's a prefix of a stop word
              final absIndex = sentCount + relativeIndex;
              final tail = currentGen.substring(absIndex);
              
              bool isPotentialStop = false;
              for (final sw in stopWords) {
                if (sw.startsWith(tail)) {
                  isPotentialStop = true;
                  break;
                }
              }
              
              if (isPotentialStop) {
                 // Needs buffering. Send only up to the suspicious '<'.
                 if (absIndex > sentCount) {
                   final safeChunk = currentGen.substring(sentCount, absIndex);
                   mainSendPort.send(LlamaStreamResponse(token: safeChunk, requestId: message.requestId));
                   sentCount = absIndex;
                 }
                 // Tail is implicitly buffered
              } else {
                 // The '<' matches nothing dangerous (e.g. "<3"). Send all.
                 mainSendPort.send(LlamaStreamResponse(token: freshContent, requestId: message.requestId));
                 sentCount = currentGen.length;
              }
            }

            tokenCount++;
          }

          stopwatch.stop();
          final tps = tokenCount / (stopwatch.elapsedMilliseconds / 1000.0);
          print('[LlamaWorker] Generation done. TPS: $tps');
          if (!cancelRequested) {
            mainSendPort.send(LlamaStreamResponse(
              isDone: true,
              tokensPerSecond: tps,
              requestId: message.requestId,
            ));
          }
        } catch (e) {
          print('[LlamaWorker] Error in isolate: $e');
          mainSendPort.send(LlamaStreamResponse(
            error: e.toString(),
            isDone: true,
            requestId: message.requestId,
          ));
        } finally {
          isGenerating = false;
          cancelRequested = false;
          scheduleNext();
        }
    };

    workerReceivePort.listen((message) {
      if (message is LlamaRequest) {
        if (isGenerating) {
          pendingRequest = message;
          cancelRequested = true;
        } else {
          processRequest(message);
        }
      } else if (message is _LlamaLoadRequest) {
        try {
          if (currentModelPath != message.modelPath) {
            service.dispose();
            service.init(modelPath: message.modelPath);
            currentModelPath = message.modelPath;
          }
          mainSendPort.send(LlamaStreamResponse(isDone: true, isWarmup: true));
        } catch (e) {
          mainSendPort.send(LlamaStreamResponse(error: e.toString(), isDone: true, isWarmup: true));
        }
      } else if (message == _cancelMessage) {
        cancelRequested = true;
        pendingRequest = null;
      }
    });
  }

  static String _buildBudgetedPrompt(LlamaService service, List<Map<String, dynamic>> messages, String? systemPrompt) {
    if (messages.isEmpty) return '';

    const int ctx = 1024;
    const int reserve = 200; // For generation + safety
    final int budget = ctx - reserve;

    final sb = StringBuffer();
    if (systemPrompt != null) {
      sb.write(systemPrompt);
    }

    // We strictly budget tokens.
    // 1. Always include system prompt (if any)
    int usedTokens = service.countTokens(sb.toString());

    // 2. Add as many messages from the end as possible
    final reversedMessages = messages.reversed.toList();
    final chosenMessages = <Map<String, dynamic>>[];

    for (final m in reversedMessages) {
      final role = m['role'] == 'user' ? 'user' : 'assistant';
      final text = m['text'] as String;
      final chunk = '<|im_start|>$role\n$text\n<|im_end|>\n';

      final t = service.countTokens(chunk);
      if (usedTokens + t > budget) {
        break; // Stop if adding this message exceeds budget
      }

      chosenMessages.add(m);
      usedTokens += t;
    }

    // 3. Reconstruct prompt in correct order
    // (System prompt already in sb)
    for (final m in chosenMessages.reversed) {
      final role = m['role'] == 'user' ? 'user' : 'assistant';
      final text = m['text'] as String;
      sb.write('<|im_start|>$role\n$text\n<|im_end|>\n');
    }

    sb.write('<|im_start|>assistant\n');
    return sb.toString();
  }
}
