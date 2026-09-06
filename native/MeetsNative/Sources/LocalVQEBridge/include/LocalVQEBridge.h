#ifndef MUESLI_LOCALVQE_BRIDGE_H
#define MUESLI_LOCALVQE_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MeetsLocalVQEContext MeetsLocalVQEContext;

MeetsLocalVQEContext *meets_localvqe_create(
    const char *model_path,
    const char *library_path,
    int threads,
    char *error_buffer,
    int error_buffer_length
);

void meets_localvqe_destroy(MeetsLocalVQEContext *context);
void meets_localvqe_reset(MeetsLocalVQEContext *context);

int meets_localvqe_process_frame_f32(
    MeetsLocalVQEContext *context,
    const float *mic,
    const float *reference,
    int hop_samples,
    float *output
);

int meets_localvqe_sample_rate(MeetsLocalVQEContext *context);
int meets_localvqe_hop_length(MeetsLocalVQEContext *context);
const char *meets_localvqe_last_error(MeetsLocalVQEContext *context);

#ifdef __cplusplus
}
#endif

#endif
