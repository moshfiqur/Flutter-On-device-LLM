#ifndef LLAMA_WRAPPER_H
#define LLAMA_WRAPPER_H

// Exposes a minimal C interface over the llama.cpp runtime so Flutter/Dart can
// drive inference through FFI. These declarations mirror the implementations in
// llama_wrapper.cpp.

#ifdef __cplusplus
extern "C" {
#endif

// Initializes the llama.cpp model/context and returns an opaque handle.
void *wrapper_init(const char *model_path, int ctx_size, int threads,
                   bool use_mmap);
// Tokenizes and preloads a prompt into the context cache.
bool wrapper_prepare_prompt(void *handle_ptr, const char *prompt);
// Utility for counting tokens without kicking off generation.
int wrapper_tokenize(void *handle_ptr, const char *text);
// Samples and decodes the next token into `out_buf`. Returns number of bytes or
// <= 0 on EOS/error.
int wrapper_get_next_token(void *handle_ptr, float temp, float top_p,
                           char *out_buf, int out_buf_size);
// Releases all native resources held by the handle.
void wrapper_free(void *handle_ptr);

#ifdef __cplusplus
}
#endif

#endif // LLAMA_WRAPPER_H
