#include "SocketWriteTestSupport.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

static int read_byte_with_timeout(int fd, int timeout_ms) {
  struct pollfd descriptor = {.fd = fd, .events = POLLIN, .revents = 0};
  if (poll(&descriptor, 1, timeout_ms) <= 0) {
    return -1;
  }
  uint8_t byte = 0;
  return read(fd, &byte, 1) == 1 ? byte : -1;
}

GaovmSigpipeResult gaovm_run_sigpipe_regression(int writer_fd, int peer_fd) {
  GaovmSigpipeResult result = {
      .setup_error = 0,
      .observed_blocked_write = 0,
      .child_result = -1,
      .child_status = -1,
  };
  int ready_pipe[2] = {-1, -1};
  int result_pipe[2] = {-1, -1};
  if (pipe(ready_pipe) != 0 || pipe(result_pipe) != 0) {
    result.setup_error = errno;
    goto cleanup;
  }

  pid_t child = fork();
  if (child < 0) {
    result.setup_error = errno;
    goto cleanup;
  }
  if (child == 0) {
    close(peer_fd);
    close(ready_pipe[0]);
    close(result_pipe[0]);
    signal(SIGPIPE, SIG_DFL);

    uint8_t bytes[4096];
    memset(bytes, 0, sizeof(bytes));
    int flags = fcntl(writer_fd, F_GETFL, 0);
    (void)fcntl(writer_fd, F_SETFL, flags | O_NONBLOCK);
    while (write(writer_fd, bytes, sizeof(bytes)) >= 0) {
    }
    (void)fcntl(writer_fd, F_SETFL, flags);

    uint8_t ready = 1;
    (void)write(ready_pipe[1], &ready, 1);
    ssize_t write_result = write(writer_fd, bytes, sizeof(bytes));
    uint8_t child_result = write_result < 0 ? 'E' : 'S';
    (void)write(result_pipe[1], &child_result, 1);
    close(writer_fd);
    close(ready_pipe[1]);
    close(result_pipe[1]);
    _exit(0);
  }

  close(ready_pipe[1]);
  ready_pipe[1] = -1;
  close(result_pipe[1]);
  result_pipe[1] = -1;
  if (read_byte_with_timeout(ready_pipe[0], 1000) != 1) {
    result.setup_error = ETIMEDOUT;
  } else {
    result.observed_blocked_write = 1;
  }

  (void)sched_yield();
  (void)shutdown(writer_fd, SHUT_RDWR);
  close(peer_fd);
  peer_fd = -1;
  result.child_result = read_byte_with_timeout(result_pipe[0], 2000);
  (void)waitpid(child, &result.child_status, 0);

cleanup:
  if (peer_fd >= 0) {
    close(peer_fd);
  }
  if (ready_pipe[0] >= 0) {
    close(ready_pipe[0]);
  }
  if (ready_pipe[1] >= 0) {
    close(ready_pipe[1]);
  }
  if (result_pipe[0] >= 0) {
    close(result_pipe[0]);
  }
  if (result_pipe[1] >= 0) {
    close(result_pipe[1]);
  }
  return result;
}
