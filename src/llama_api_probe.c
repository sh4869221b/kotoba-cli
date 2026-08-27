#include "llama.h"

/* Keep these independent signatures aligned with every call in llama.zig. */
#define CHECK_API(name, result, ...) \
    result (*check_##name)(__VA_ARGS__) = name; \
    (void) check_##name
#define CHECK_FIELD(value, field, type) \
    type *check_##field = &(value).field; \
    (void) check_##field

static bool progress_callback(float progress, void *data) {
    (void) progress;
    (void) data;
    return true;
}

static bool abort_callback(void *data) {
    (void) data;
    return false;
}

static void log_callback(enum ggml_log_level level, const char *text, void *data) {
    (void) level;
    (void) text;
    (void) data;
}

void kotoba_llama_api_probe(void) {
    CHECK_API(llama_backend_init, void, void);
    CHECK_API(llama_backend_free, void, void);
    CHECK_API(llama_model_default_params, struct llama_model_params, void);
    CHECK_API(llama_context_default_params, struct llama_context_params, void);
    CHECK_API(llama_sampler_chain_default_params, struct llama_sampler_chain_params, void);
    CHECK_API(llama_model_load_from_file, struct llama_model *, const char *, struct llama_model_params);
    CHECK_API(llama_init_from_model, struct llama_context *, struct llama_model *, struct llama_context_params);
    CHECK_API(llama_model_get_vocab, const struct llama_vocab *, const struct llama_model *);
    CHECK_API(llama_get_memory, llama_memory_t, const struct llama_context *);
    CHECK_API(llama_memory_clear, void, llama_memory_t, bool);
    CHECK_API(llama_tokenize, int32_t, const struct llama_vocab *, const char *, int32_t, llama_token *, int32_t, bool, bool);
    CHECK_API(llama_batch_get_one, struct llama_batch, llama_token *, int32_t);
    CHECK_API(llama_decode, int32_t, struct llama_context *, struct llama_batch);
    CHECK_API(llama_sampler_chain_init, struct llama_sampler *, struct llama_sampler_chain_params);
    CHECK_API(llama_sampler_chain_add, void, struct llama_sampler *, struct llama_sampler *);
    CHECK_API(llama_sampler_init_temp, struct llama_sampler *, float);
    CHECK_API(llama_sampler_init_top_p, struct llama_sampler *, float, size_t);
    CHECK_API(llama_sampler_init_greedy, struct llama_sampler *, void);
    CHECK_API(llama_sampler_init_dist, struct llama_sampler *, uint32_t);
    CHECK_API(llama_sampler_sample, llama_token, struct llama_sampler *, struct llama_context *, int32_t);
    CHECK_API(llama_sampler_accept, void, struct llama_sampler *, llama_token);
    CHECK_API(llama_sampler_reset, void, struct llama_sampler *);
    CHECK_API(llama_token_to_piece, int32_t, const struct llama_vocab *, llama_token, char *, int32_t, int32_t, bool);
    CHECK_API(llama_vocab_is_eog, bool, const struct llama_vocab *, llama_token);
    CHECK_API(llama_sampler_free, void, struct llama_sampler *);
    CHECK_API(llama_free, void, struct llama_context *);
    CHECK_API(llama_model_free, void, struct llama_model *);
    CHECK_API(llama_log_set, void, void (*)(enum ggml_log_level, const char *, void *), void *);

    struct llama_model_params model = {0};
    CHECK_FIELD(model, n_gpu_layers, int32_t);
    CHECK_FIELD(model, progress_callback_user_data, void *);
    model.progress_callback = progress_callback;
    struct llama_context_params context = {0};
    CHECK_FIELD(context, n_ctx, uint32_t);
    CHECK_FIELD(context, n_batch, uint32_t);
    CHECK_FIELD(context, n_threads, int32_t);
    CHECK_FIELD(context, n_threads_batch, int32_t);
    CHECK_FIELD(context, abort_callback_data, void *);
    context.abort_callback = abort_callback;
    ggml_log_callback log = log_callback;
    (void) log;
}
