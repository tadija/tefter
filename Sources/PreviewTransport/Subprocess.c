#include "PreviewTransport.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static long long milliseconds(void) {
  struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
  return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* Trusted executable, isolated process group, explicit environment, bounded I/O.
   No shell interpolation; descendants are terminated even after leader exit. */
int tefter_subprocess(const char *exe, char *const argv[], char *const env[],
                     const char *cwd, const void *input, size_t input_size,
                     int timeout_ms, size_t maximum, char **output, size_t *length,
                     int *exit_code) {
  int in[2], out[2];
  *output = NULL; *length = 0; *exit_code = -1;
  if (pipe(in)) return -1;
  if (pipe(out)) { close(in[0]); close(in[1]); return -1; }
  pid_t child = fork();
  if (child == 0) {
    if (setsid() < 0 || chdir(cwd)) _exit(126);
    dup2(in[0], STDIN_FILENO); dup2(out[1], STDOUT_FILENO);
    int null = open("/dev/null", O_WRONLY);
    dup2(null, STDERR_FILENO);
    close(in[0]); close(in[1]); close(out[0]); close(out[1]); close(null);
    execve(exe, argv, env); _exit(127);
  }
  close(in[0]); close(out[1]);
  if (child < 0) { close(in[1]); close(out[0]); return -1; }
  fcntl(in[1], F_SETFL, O_NONBLOCK); fcntl(out[0], F_SETFL, O_NONBLOCK);
  char *buffer = malloc(maximum + 1);
  if (!buffer) { kill(child, SIGKILL); close(in[1]); close(out[0]); waitpid(child,NULL,0); return -1; }
  size_t written = 0, used = 0;
  int status = 0, done = 0, eof = 0, reason = 0;
  long long deadline = milliseconds() + timeout_ms;
  while (!done || !eof) {
    if (milliseconds() >= deadline) { reason = 1; break; }
    struct pollfd fds[2] = {{out[0], POLLIN, 0}, {in[1], POLLOUT, 0}};
    poll(fds, 2, 10);
    if (in[1] >= 0 && written < input_size) {
      ssize_t n = write(in[1], (const char *)input + written, input_size - written);
      if (n > 0) written += n;
      else if (n < 0 && errno != EAGAIN && errno != EINTR) { close(in[1]); in[1] = -1; }
    }
    if (in[1] >= 0 && written == input_size) { close(in[1]); in[1] = -1; }
    ssize_t n = read(out[0], buffer + used, maximum + 1 - used);
    if (n > 0) used += n;
    else if (n == 0) eof = 1;
    else if (errno != EAGAIN && errno != EINTR) { reason = -1; break; }
    if (used > maximum) { reason = 2; break; }
    if (!done) {
      pid_t result = waitpid(child, &status, WNOHANG);
      if (result == child) done = 1;
      else if (result < 0 && errno != EINTR) { reason = -1; break; }
    }
  }
  kill(-child, SIGKILL);
  if (!done) { kill(child, SIGKILL); while (waitpid(child,&status,0) < 0 && errno == EINTR) {} }
  if (in[1] >= 0) close(in[1]); close(out[0]);
  *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
  if (reason) { free(buffer); return reason; }
  *output = buffer; *length = used; return 0;
}
