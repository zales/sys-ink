// The libc declarations the daemon uses, translated into the Zig module "c" by
// the translate-c package (see build.zig) for whichever target is being built.
// Layouts come from that target's own headers rather than hand-written structs.

// MQTT: name resolution, and the socket options on the broker connection.
#include <netdb.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

// Network readings: the interfaces' addresses.
#include <ifaddrs.h>

// Disk usage: statfs. On Linux, where the daemon runs, it is declared in
// <sys/vfs.h>; on macOS, where only the tests do, in <sys/mount.h>.
#ifdef __linux__
#include <sys/vfs.h>
#endif
#ifdef __APPLE__
#include <sys/mount.h>
#endif
