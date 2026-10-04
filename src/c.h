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

// Disk usage. Linux-only, like system_ops.zig, the one module that reads it;
// the tests, which also build on macOS, reach only the parts above.
#ifdef __linux__
#include <sys/vfs.h>
#endif
