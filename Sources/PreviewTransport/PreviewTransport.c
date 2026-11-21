#include "PreviewTransport.h"
#include <arpa/inet.h>
#include <curl/curl.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static int public_ipv4(uint32_t ip) {
    unsigned a = ip >> 24, b = (ip >> 16) & 255, c = (ip >> 8) & 255;
    return !(a == 0 || a == 10 || a == 127 || a >= 224 ||
             (a == 100 && b >= 64 && b <= 127) || (a == 169 && b == 254) ||
             (a == 172 && b >= 16 && b <= 31) || (a == 192 && (b == 168 || b == 0 || (b == 88 && c == 99))) ||
             (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) ||
             (a == 203 && b == 0 && c == 113) || ip == 0xa83f8110);
}

// curl invokes this with the concrete destination for every connection, including redirects.
static curl_socket_t open_public(void *context, curlsocktype purpose, struct curl_sockaddr *address) {
    (void)context;
    if (purpose != CURLSOCKTYPE_IPCXN) return CURL_SOCKET_BAD;
    if (address->family == AF_INET) {
        const struct sockaddr_in *v4 = (const void *)&address->addr;
        if (!public_ipv4(ntohl(v4->sin_addr.s_addr))) return CURL_SOCKET_BAD;
    } else if (address->family == AF_INET6) {
        const struct sockaddr_in6 *v6 = (const void *)&address->addr;
        const unsigned char *b = v6->sin6_addr.s6_addr;
        if ((b[0] & 0xe0) != 0x20 || (b[0] == 0x20 && b[1] == 2) ||
            (b[0] == 0x20 && b[1] == 1 && (b[2] < 2 || (b[2] == 0x0d && b[3] == 0xb8))) ||
            (b[0] == 0x3f && (b[1] & 0xf0) == 0xf0)) return CURL_SOCKET_BAD;
    } else return CURL_SOCKET_BAD;
    return socket(address->family,address->socktype,address->protocol);
}

struct buffer { char *bytes; size_t length; };
static size_t receive(char *bytes, size_t size, size_t count, void *context) {
    struct buffer *buffer = context;
    size_t n = size * count;
    if (n > 524288 - buffer->length) return 0;
    char *next = realloc(buffer->bytes,buffer->length+n+1);
    if (!next) return 0;
    buffer->bytes = next;
    memcpy(next+buffer->length,bytes,n);
    buffer->length += n;
    next[buffer->length] = 0;
    return n;
}

int tefter_fetch(const char *url, int image, char **body, size_t *length, char **effective) {
    CURL *curl = curl_easy_init();
    if (!curl) return 0;
    struct buffer buffer = {NULL,0};
    curl_easy_setopt(curl,CURLOPT_URL,url);
    curl_easy_setopt(curl,CURLOPT_PROXY,"");
    curl_easy_setopt(curl,CURLOPT_NOSIGNAL,1L);
    if (curl_easy_setopt(curl,CURLOPT_PROTOCOLS_STR,"http,https") != CURLE_OK ||
        curl_easy_setopt(curl,CURLOPT_REDIR_PROTOCOLS_STR,"http,https") != CURLE_OK) {
        curl_easy_cleanup(curl);
        return 0;
    }
    curl_easy_setopt(curl,CURLOPT_DISALLOW_USERNAME_IN_URL,1L);
    curl_easy_setopt(curl,CURLOPT_FOLLOWLOCATION,1L);
    curl_easy_setopt(curl,CURLOPT_MAXREDIRS,3L);
    curl_easy_setopt(curl,CURLOPT_TIMEOUT_MS,5000L);
    curl_easy_setopt(curl,CURLOPT_CONNECTTIMEOUT_MS,2500L);
    curl_easy_setopt(curl,CURLOPT_MAXFILESIZE_LARGE,(curl_off_t)524288);
    curl_easy_setopt(curl,CURLOPT_OPENSOCKETFUNCTION,open_public);
    curl_easy_setopt(curl,CURLOPT_WRITEFUNCTION,receive);
    curl_easy_setopt(curl,CURLOPT_WRITEDATA,&buffer);
    CURLcode result = curl_easy_perform(curl);
    long status = 0;
    char *type = NULL;
    curl_easy_getinfo(curl,CURLINFO_RESPONSE_CODE,&status);
    curl_easy_getinfo(curl,CURLINFO_CONTENT_TYPE,&type);
    int ok = result == CURLE_OK && status >= 200 && status < 300 &&
        type && (image ? strncasecmp(type,"image/",6)==0 : strncasecmp(type,"text/html",9)==0) && buffer.bytes;
    char *final_url = NULL;
    curl_easy_getinfo(curl,CURLINFO_EFFECTIVE_URL,&final_url);
    if (ok && final_url) *effective = strdup(final_url);
    curl_easy_cleanup(curl);
    if (!ok) { free(buffer.bytes); return 0; }
    *body = buffer.bytes;
    *length = buffer.length;
    return 1;
}

struct mail_payload { const char *message; size_t left; };
static size_t read_mail(char *buffer, size_t size, size_t count, void *context) {
    struct mail_payload *mail = context;
    size_t amount = size * count;
    if (amount > mail->left) amount = mail->left;
    memcpy(buffer,mail->message,amount);
    mail->message += amount;
    mail->left -= amount;
    return amount;
}

int tefter_send_mail(const char *server, const char *user, const char *password,
                     const char *sender, const char *recipient, const char *message) {
    CURL *curl = curl_easy_init();
    if (!curl) return 0;
    struct curl_slist *recipients = curl_slist_append(NULL,recipient);
    if (!recipients) { curl_easy_cleanup(curl); return 0; }
    struct mail_payload payload = {message,strlen(message)};
    curl_easy_setopt(curl,CURLOPT_URL,server);
    if (curl_easy_setopt(curl,CURLOPT_PROTOCOLS_STR,"smtp,smtps") != CURLE_OK) {
        curl_slist_free_all(recipients);
        curl_easy_cleanup(curl);
        return 0;
    }
    curl_easy_setopt(curl,CURLOPT_USE_SSL,(long)CURLUSESSL_ALL);
    curl_easy_setopt(curl,CURLOPT_PROXY,"");
    curl_easy_setopt(curl,CURLOPT_NOSIGNAL,1L);
    curl_easy_setopt(curl,CURLOPT_TIMEOUT,10L);
    if (*user) {
        curl_easy_setopt(curl,CURLOPT_USERNAME,user);
        curl_easy_setopt(curl,CURLOPT_PASSWORD,password);
    }
    curl_easy_setopt(curl,CURLOPT_MAIL_FROM,sender);
    curl_easy_setopt(curl,CURLOPT_MAIL_RCPT,recipients);
    curl_easy_setopt(curl,CURLOPT_READFUNCTION,read_mail);
    curl_easy_setopt(curl,CURLOPT_READDATA,&payload);
    curl_easy_setopt(curl,CURLOPT_UPLOAD,1L);
    CURLcode result = curl_easy_perform(curl);
    curl_slist_free_all(recipients);
    curl_easy_cleanup(curl);
    return result == CURLE_OK;
}
