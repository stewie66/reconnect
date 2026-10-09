#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct PsionCommandSession PsionCommandSession;
PsionCommandSession *psion_session_open(const char *host, int32_t port);
void psion_session_close(PsionCommandSession *session);
int32_t psion_file_owner(PsionCommandSession *session, const char *path, char *owner, size_t capacity);
int32_t psion_program_running(PsionCommandSession *session, const char *process);
int32_t psion_stop_program(PsionCommandSession *session, const char *process);
int32_t psion_program_details(PsionCommandSession *session, const char *process, char *executable, size_t capacity);
#ifdef __cplusplus
}
#endif
