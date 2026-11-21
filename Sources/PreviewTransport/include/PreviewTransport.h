#pragma once
#include <stddef.h>
int tefter_fetch_html(const char *url, char **body, size_t *length);
int tefter_send_mail(const char *server, const char *user, const char *password,
                     const char *sender, const char *recipient, const char *message);
