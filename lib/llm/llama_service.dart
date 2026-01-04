import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';
import 'llama_ffi.dart';

/// High-level Dart facade over the raw FFI bindings.
///
/// `LlamaService` keeps track of the native llama handle and offers safe
/// methods for initializing, tokenizing, and sampling without exposing FFI
/// plumbing to the rest of the app. It mirrors the lifecycle of the C++
/// wrapper: `init` => `preparePrompt`/`getNextToken` => `dispose`.
class LlamaService {
  static final Logger _log = Logger('LlamaService');
  final LlamaFfi _ffi = LlamaFfi();
  Pointer<Void>? _handle;

  bool get isInitialized => _handle != null;

  void init({
    required String modelPath,
    int contextLen = 1024,
    int nThreads = 4,
    bool useMmap = true,
  }) {
    if (_handle != null) {
      dispose();
    }

    final pathPtr = modelPath.toNativeUtf8();
    try {
      _handle = _ffi.llamaInit(pathPtr, contextLen, nThreads, useMmap);
      if (_handle == null || _handle!.address == 0) {
        throw Exception('Failed to initialize llama model at $modelPath');
      }
      _log.info('Llama model initialized successfully');
    } finally {
      malloc.free(pathPtr);
    }
  }

  bool preparePrompt(String prompt) {
    if (_handle == null) throw Exception('LlamaService not initialized');
    final promptPtr = prompt.toNativeUtf8();
    try {
      return _ffi.llamaPreparePrompt(_handle!, promptPtr);
    } finally {
      malloc.free(promptPtr);
    }
  }

  /// Uses the native tokenizer to count how many tokens a chunk of text would
  /// consume. The worker relies on this to budget prompts before generation.
  int countTokens(String text) {
    if (_handle == null) throw Exception('LlamaService not initialized');
    final textPtr = text.toNativeUtf8();
    try {
        final count = _ffi.llamaTokenize(_handle!, textPtr);
        if (count < 0) return 0; // Error or empty
        return count;
    } finally {
        malloc.free(textPtr);
    }
  }

  String? getNextToken({double temperature = 0.2, double topP = 0.9}) {
    if (_handle == null) throw Exception('LlamaService not initialized');
    
    final outBufSize = 256;
    final outBufPtr = malloc.allocate<Utf8>(outBufSize);
    try {
      final res = _ffi.llamaGetNextToken(_handle!, temperature, topP, outBufPtr, outBufSize);
      if (res == 0) return null; // EOS
      if (res < 0) throw Exception('Token generation failed: $res');
      
      return outBufPtr.toDartString();
    } finally {
      malloc.free(outBufPtr);
    }
  }

  void dispose() {
    if (_handle != null) {
      _ffi.llamaFree(_handle!);
      _handle = null;
      _log.info('Llama model freed');
    }
  }
}
