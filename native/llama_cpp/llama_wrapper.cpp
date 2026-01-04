#include "llama_wrapper.h"
#include "src/include/llama.h"
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

#ifdef ANDROID
#include <android/log.h>
#define LOG_TAG "LlamaWrapper"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#else
#define LOGI(...) printf(__VA_ARGS__)
#define LOGE(...) fprintf(stderr, __VA_ARGS__)
#endif

// Central state bag shared between all wrapper_* functions.  It mirrors the
// llama.cpp structures but keeps everything opaque from the Dart side so only
// this translation layer has to reason about llama internals.
struct LlamaHandle {
  llama_model *model;
  llama_context *ctx;
  const llama_vocab *vocab;
  llama_batch batch;
  struct llama_sampler *smpl;
  int n_cur;
  bool is_prepared;
  int batch_size;

  float last_temp;
  float last_top_p;

  int n_prompt;
  int n_gen;
  int max_new_tokens;

  LlamaHandle()
      : model(nullptr), ctx(nullptr), vocab(nullptr), smpl(nullptr), n_cur(0),
        is_prepared(false), batch_size(128), last_temp(-1.0f),
        last_top_p(-1.0f), n_prompt(0), n_gen(0), max_new_tokens(128) {
    batch = {0, nullptr, nullptr, nullptr, nullptr, nullptr};
  }
};

static void reset_batch_positions(LlamaHandle *handle) {
  handle->batch.n_tokens = 0;
}

static bool ensure_sampler(LlamaHandle *handle, float temp, float top_p) {
  // Rebuild the sampler when parameters change to avoid stale sampling state
  // between requests.
  if (handle->smpl && temp == handle->last_temp && top_p == handle->last_top_p) {
    llama_sampler_reset(handle->smpl);
    return true;
  }

  if (handle->smpl) {
    llama_sampler_free(handle->smpl);
    handle->smpl = nullptr;
  }

  handle->smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
  if (!handle->smpl)
    return false;

  llama_sampler_chain_add(handle->smpl,
                          llama_sampler_init_penalties(64, 1.2f, 0.0f, 0.0f));
  llama_sampler_chain_add(handle->smpl, llama_sampler_init_temp(temp));
  llama_sampler_chain_add(handle->smpl, llama_sampler_init_top_k(40));
  llama_sampler_chain_add(handle->smpl, llama_sampler_init_top_p(top_p, 1));
  llama_sampler_chain_add(handle->smpl, llama_sampler_init_dist(1234));

  handle->last_temp = temp;
  handle->last_top_p = top_p;
  return true;
}

// Entry point invoked from Dart via FFI to bring up llama.cpp.  We clamp the
// context/window and thread parameters to sane mobile defaults, initialize the
// backend, and hydrate our LlamaHandle with the resulting pointers.
void *wrapper_init(const char *model_path, int ctx_size, int threads,
                   bool use_mmap) {
  const int requested_ctx = ctx_size > 0 ? ctx_size : 1024;
  const int requested_threads = threads > 0 ? threads : 4;

  LOGI("wrapper_init: model=%s, ctx=%d, threads=%d", model_path,
       requested_ctx, requested_threads);
  llama_backend_init();

  llama_model_params mparams = llama_model_default_params();
  mparams.use_mmap = use_mmap;

  llama_model *model = llama_model_load_from_file(model_path, mparams);
  if (!model) {
    LOGE("wrapper_init: failed to load model");
    return nullptr;
  }

  llama_context_params cparams = llama_context_default_params();
  cparams.n_ctx = requested_ctx;
  cparams.n_threads = requested_threads;
  cparams.n_threads_batch = requested_threads;
  cparams.n_batch = std::min<int>(128, requested_ctx);
  cparams.n_ubatch = std::min<int>(64, requested_ctx);
  cparams.offload_kqv = false; // CPU-only for stability
  cparams.no_perf = true;

  llama_context *ctx = llama_init_from_model(model, cparams);
  if (!ctx) {
    LOGE("wrapper_init: failed to init context");
    llama_model_free(model);
    return nullptr;
  }

  LlamaHandle *handle = new LlamaHandle();
  handle->model = model;
  handle->ctx = ctx;
  handle->vocab = llama_model_get_vocab(model);
  handle->batch_size = std::min<int>(128, static_cast<int>(cparams.n_batch));

  handle->batch = llama_batch_init(handle->batch_size, 0, 1);

  LOGI("wrapper_init: success");
  return handle;
}

int wrapper_tokenize(void *handle_ptr, const char *text) {
  if (!handle_ptr)
    return -1;
  LlamaHandle *handle = (LlamaHandle *)handle_ptr;

  std::vector<llama_token> tokens;
  tokens.resize(strlen(text) + 4);

  int n = llama_tokenize(handle->vocab, text, strlen(text), tokens.data(),
                         tokens.size(), false, false);
  if (n < 0) {
    tokens.resize(-n);
    n = llama_tokenize(handle->vocab, text, strlen(text), tokens.data(),
                       tokens.size(), false, false);
  }
  return n;
}

// Resets the kv cache, tokenizes the prompt, and feeds it through llama.cpp so
// the next token call can pick up where the prompt left off.  This function is
// intentionally defensive: it checks context limits, slices work into batches,
// and tears down any stale sampler state.
bool wrapper_prepare_prompt(void *handle_ptr, const char *prompt) {
  if (!handle_ptr)
    return false;
  LlamaHandle *handle = (LlamaHandle *)handle_ptr;

  handle->is_prepared = false;

  LOGI("wrapper_prepare_prompt: clearing kv cache...");
  llama_memory_clear(llama_get_memory(handle->ctx), true);

  LOGI("wrapper_prepare_prompt: tokenizing...");
  // Tokenize
  std::vector<llama_token> tokens;
  tokens.resize(strlen(prompt) + 1);
  int n_tokens = llama_tokenize(handle->vocab, prompt, strlen(prompt),
                                tokens.data(), tokens.size(), true, true);
  if (n_tokens < 0) {
    tokens.resize(-n_tokens);
    n_tokens = llama_tokenize(handle->vocab, prompt, strlen(prompt),
                              tokens.data(), tokens.size(), true, true);
  }
  tokens.resize(n_tokens);
  LOGI("wrapper_prepare_prompt: n_tokens=%d", n_tokens);

  // Prompt guard: fail fast if prompt exceeds context safety margin
  const int n_ctx = (int)llama_n_ctx(handle->ctx);
  const int safety = 128;
  if (n_tokens >= n_ctx - safety) {
    LOGE("wrapper_prepare_prompt: prompt too long (%d >= %d - %d)", n_tokens,
         n_ctx, safety);
    return false;
  }

  // Decode in chunks to avoid batch overflow
  handle->n_cur = 0;
  for (int i = 0; i < n_tokens; i += handle->batch_size) {
    int n_eval = (n_tokens - i) > handle->batch_size ? handle->batch_size
                                                     : (n_tokens - i);
    reset_batch_positions(handle);
    for (int j = 0; j < n_eval; j++) {
      const llama_pos pos = handle->n_cur + j;
      handle->batch.token[j] = tokens[i + j];
      handle->batch.pos[j] = pos;
      handle->batch.n_seq_id[j] = 1;
      handle->batch.seq_id[j][0] = 0;
      handle->batch.logits[j] = (j == n_eval - 1);
      handle->batch.n_tokens++;
    }

    LOGI("wrapper_prepare_prompt: decoding chunk %d/%d...", i, n_tokens);
    if (llama_decode(handle->ctx, handle->batch) != 0) {
      LOGE("wrapper_prepare_prompt: llama_decode failed at %d", i);
      return false;
    }

    handle->n_cur += n_eval;
  }

  handle->n_prompt = handle->n_cur;
  handle->n_gen = 0;
  handle->max_new_tokens = std::max(16, n_ctx - handle->n_prompt - safety);
  handle->is_prepared = true;

  if (handle->smpl) {
    llama_sampler_reset(handle->smpl);
  }
  LOGI("wrapper_prepare_prompt: success");
  return true;
}

// Samples a single token using llama.cpp's sampler chain, performs some extra
// guardrails (context exhaustion, explicit stop-sequence detection, etc.), and
// decodes the token into UTF-8 so Dart can render it.  Returns the number of
// bytes written, 0 for EOS, or <0 for a failure.
int wrapper_get_next_token(void *handle_ptr, float temp, float top_p,
                           char *out_buf, int out_buf_size) {
  if (!handle_ptr)
    return -1;
  LlamaHandle *handle = (LlamaHandle *)handle_ptr;
  if (!handle->is_prepared)
    return -2;

  if (!ensure_sampler(handle, temp, top_p)) {
    LOGE("wrapper_get_next_token: failed to configure sampler");
    return -3;
  }

  const int n_ctx = (int)llama_n_ctx(handle->ctx);

  // Context guard: prevent overflow/crash
  if (handle->n_cur >= n_ctx - 4) {
    LOGI("wrapper_get_next_token: context full (n_cur=%d n_ctx=%d), stopping",
         handle->n_cur, n_ctx);
    return 0;
  }

  // Max new tokens check
  if (handle->n_gen >= handle->max_new_tokens) {
    LOGI("wrapper_get_next_token: max_new_tokens reached");
    return 0;
  }

  llama_token id = llama_sampler_sample(handle->smpl, handle->ctx, -1);

  int n = llama_token_to_piece(handle->vocab, id, out_buf, out_buf_size - 1, 0,
                               true);
  if (n > 0) {
    out_buf[n] = '\0';
    // Removed per-token logging for performance

    // Explicit stop word check (helpful for models with custom EOT/IM_END)
    if (strstr(out_buf, "<|im_end|") != nullptr ||
        strstr(out_buf, "<|im_start|>") !=
            nullptr || // Stop if model hallucinates start of new turn
        strstr(out_buf, "<|user|>") != nullptr || // Stop on weird user tags
        strstr(out_buf, "user\n") != nullptr) {
      LOGI("wrapper_get_next_token: stop sequence detected in piece");
      return 0;
    }
  } else {
    LOGI("wrapper_get_next_token: sampled id=%d (empty piece)", id);
  }

  if (llama_vocab_is_eog(handle->vocab, id)) {
    LOGI("wrapper_get_next_token: EOS detected");
    return 0;
  }

  // Position fix: if prompt was 0..167 (n_tokens=168), first gen token is at
  // 168. handle->n_cur should be 168 here.
  // LOGI("wrapper_get_next_token: decoding token %d at pos %d", id,
  // handle->n_cur);

  reset_batch_positions(handle);
  handle->batch.token[0] = id;
  handle->batch.pos[0] = handle->n_cur;
  handle->batch.n_seq_id[0] = 1;
  handle->batch.seq_id[0][0] = 0;
  handle->batch.logits[0] = true;
  handle->batch.n_tokens = 1;

  int res = llama_decode(handle->ctx, handle->batch);
  if (res != 0) {
    LOGE("wrapper_get_next_token: llama_decode failed with code %d", res);
    return -4;
  }

  handle->n_cur++;
  handle->n_gen++;
  return n;
}

// Cleans up everything allocated during wrapper_init/prepare_prompt.  Dart is
// expected to call this when the isolate shuts down or swaps models so we don’t
// leak native memory.
void wrapper_free(void *handle_ptr) {
  if (!handle_ptr)
    return;
  LlamaHandle *handle = (LlamaHandle *)handle_ptr;
  LOGI("wrapper_free: freeing resources");
  if (handle->smpl)
    llama_sampler_free(handle->smpl);
  if (handle->batch.token)
    llama_batch_free(handle->batch);
  if (handle->ctx)
    llama_free(handle->ctx);
  if (handle->model)
    llama_model_free(handle->model);
  delete handle;
  llama_backend_free();
}
