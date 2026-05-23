#include "llama.h"

void kotoba_llama_api_probe(void) {
    llama_backend_init();
    (void) llama_model_default_params();
    (void) llama_context_default_params();
    (void) llama_sampler_chain_default_params();
    (void) llama_model_load_from_file;
    (void) llama_init_from_model;
    (void) llama_model_get_vocab;
    (void) llama_tokenize;
    (void) llama_batch_get_one;
    (void) llama_decode;
    (void) llama_sampler_sample;
    (void) llama_token_to_piece;
    (void) llama_vocab_is_eog;
    (void) llama_memory_clear;
    (void) llama_sampler_free;
    (void) llama_free;
    (void) llama_model_free;
    (void) llama_backend_free;
}
