#pragma once
#include <stddef.h>
int tefter_fetch(const char *url, int image, char **body, size_t *length, char **effective);
int tefter_send_mail(const char *server, const char *user, const char *password,
                     const char *sender, const char *recipient, const char *message);
int tefter_rename_exclusive(int from, const char *name, int to, const char *destination);
