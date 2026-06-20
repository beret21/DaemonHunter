#include <libproc.h>
#include <sys/sysctl.h>

// PROC_PIDPATHINFO_MAXSIZE is a complex macro (4*MAXPATHLEN) that Swift cannot import directly
#define PROC_PIDPATHINFO_MAXSIZE_SWIFT 4096
