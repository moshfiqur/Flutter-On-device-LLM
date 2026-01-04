import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// Native function signatures
// These typedefs mirror the exported C symbols found in
// native/llama_cpp/llama_wrapper.[h|cpp]. Dart uses them to understand how to
// marshal data across the FFI boundary.
typedef LlamaInitNative = Pointer<Void> Function(
    Pointer<Utf8> modelPath, Int32 ctx, Int32 threads, Bool useMmap);
typedef LlamaInit = Pointer<Void> Function(
    Pointer<Utf8> modelPath, int ctx, int threads, bool useMmap);

typedef LlamaPreparePromptNative = Bool Function(
    Pointer<Void> handle, Pointer<Utf8> prompt);
typedef LlamaPreparePrompt = bool Function(
    Pointer<Void> handle, Pointer<Utf8> prompt);

typedef LlamaTokenizeNative = Int32 Function(
    Pointer<Void> handle, Pointer<Utf8> text);
typedef LlamaTokenize = int Function(
    Pointer<Void> handle, Pointer<Utf8> text);

typedef LlamaGetNextTokenNative = Int32 Function(
    Pointer<Void> handle, Float temp, Float topP, Pointer<Utf8> outBuf, Int32 outBufSize);
typedef LlamaGetNextToken = int Function(
    Pointer<Void> handle, double temp, double topP, Pointer<Utf8> outBuf, int outBufSize);

typedef LlamaFreeNative = Void Function(Pointer<Void> handle);
typedef LlamaFree = void Function(Pointer<Void> handle);

/// Thin binding around the `llama_wrapper` shared library.
///
/// This class is responsible for opening the correct native artifact
/// (`libllama_wrapper.so` on Android or the process image on iOS) and exposing
/// typed Dart callables that forward to the C++ wrapper. Higher-level Dart code
/// (see [LlamaService]) uses these function pointers to interact with
/// llama.cpp without needing to know anything about the native build.
class LlamaFfi {
  late DynamicLibrary _lib;

  late LlamaInit llamaInit;
  late LlamaPreparePrompt llamaPreparePrompt;
  late LlamaGetNextToken llamaGetNextToken;
  late LlamaTokenize llamaTokenize;
  late LlamaFree llamaFree;

  LlamaFfi() {
    _lib = _loadLibrary();
    
    llamaInit = _lib
        .lookup<NativeFunction<LlamaInitNative>>('wrapper_init')
        .asFunction<LlamaInit>();

    llamaPreparePrompt = _lib
        .lookup<NativeFunction<LlamaPreparePromptNative>>('wrapper_prepare_prompt')
        .asFunction<LlamaPreparePrompt>();

    llamaGetNextToken = _lib
        .lookup<NativeFunction<LlamaGetNextTokenNative>>('wrapper_get_next_token')
        .asFunction<LlamaGetNextToken>();

    llamaTokenize = _lib
        .lookup<NativeFunction<LlamaTokenizeNative>>('wrapper_tokenize')
        .asFunction<LlamaTokenize>();

    llamaFree = _lib
        .lookup<NativeFunction<LlamaFreeNative>>('wrapper_free')
        .asFunction<LlamaFree>();
  }

  /// Loads the platform-specific native library that houses the wrapper
  /// functions. The exact filename must match what the Android/iOS builds
  /// produce in native/llama_cpp.
  DynamicLibrary _loadLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libllama_wrapper.so');
    } else if (Platform.isIOS) {
      return DynamicLibrary.process();
    } else {
      throw UnsupportedError('Platform not supported');
    }
  }
}
