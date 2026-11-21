#pragma once
#include <stddef.h>
int tefter_fetch(const char *url, int image, char **body, size_t *length, char **effective);
int tefter_send_mail(const char *server, const char *ca_file, const char *user, const char *password,
                     const char *sender, const char *recipient, const char *message);
int tefter_rename_exclusive(int from, const char *name, int to, const char *destination);
int tefter_subprocess(const char *exe, char *const argv[], char *const env[],
                     const char *cwd, const void *input, size_t input_size,
                     int timeout_ms, size_t maximum, char **output, size_t *length,
                     int *exit_code);
