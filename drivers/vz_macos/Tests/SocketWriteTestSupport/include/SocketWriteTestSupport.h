#ifndef SOCKET_WRITE_TEST_SUPPORT_H
#define SOCKET_WRITE_TEST_SUPPORT_H

#include <stdint.h>

typedef struct {
  int32_t setup_error;
  int32_t observed_blocked_write;
  int32_t child_result;
  int32_t child_status;
} GaovmSigpipeResult;

GaovmSigpipeResult gaovm_run_sigpipe_regression(int writer_fd, int peer_fd);

#endif
