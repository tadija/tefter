#define _GNU_SOURCE
#include <stdio.h>
#ifdef __linux__
#include <linux/fs.h>
#endif
int tefter_rename_exclusive(int from, const char *name, int to, const char *destination) {
#ifdef __APPLE__
    return renameatx_np(from,name,to,destination,RENAME_EXCL);
#else
    return renameat2(from,name,to,destination,RENAME_NOREPLACE);
#endif
}
