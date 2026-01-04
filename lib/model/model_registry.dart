class ModelOption {
  final String id;
  final String name;
  final String size;
  final String url;
  final String? sha256;

  const ModelOption({
    required this.id,
    required this.name,
    required this.size,
    required this.url,
    this.sha256,
  });
}

const List<ModelOption> modelOptions = [
  ModelOption(
    id: 'smollm2-135m-instruct',
    name: 'SmolLM2 135M (Emulator-Ready)',
    size: '90 MB',
    url: 'https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/main/SmolLM2-135M-Instruct-Q4_K_M.gguf',
  ),
  ModelOption(
    id: 'tinyllama-1.1b-chat',
    name: 'TinyLlama 1.1B Chat',
    size: '669 MB',
    url: 'https://huggingface.co/TheBloke/TinyLlama-1.1B-Chat-v1.0-GGUF/resolve/main/tinyllama-1.1b-chat-v1.0.Q4_K_M.gguf',
  ),
  ModelOption(
    id: 'phi-2',
    name: 'Phi-2 (Small)',
    size: '1.6 GB',
    url: 'https://huggingface.co/TheBloke/phi-2-GGUF/resolve/main/phi-2.Q4_K_M.gguf',
  ),
];
