//go:build ios

package core

/*
#cgo LDFLAGS: -lresolv
#include <arpa/inet.h>
#include <resolv.h>
#include <stdio.h>
#include <string.h>

static int flclash_system_dns(char *out, int out_len) {
	struct __res_state state;
	memset(&state, 0, sizeof(state));
	out[0] = 0;
	if (res_ninit(&state) != 0) {
		return -1;
	}
	union res_sockaddr_union servers[8];
	int count = res_getservers(&state, servers, 8);
	int written = 0;
	for (int i = 0; i < count; i++) {
		char address[INET6_ADDRSTRLEN] = {0};
		if (servers[i].sin.sin_family == AF_INET) {
			inet_ntop(AF_INET, &servers[i].sin.sin_addr, address, sizeof(address));
		} else if (servers[i].sin6.sin6_family == AF_INET6) {
			inet_ntop(AF_INET6, &servers[i].sin6.sin6_addr, address, sizeof(address));
		} else {
			continue;
		}
		int n = snprintf(out + written, out_len - written, "%s%s", written ? "," : "", address);
		if (n < 0 || n >= out_len - written) {
			break;
		}
		written += n;
	}
	res_ndestroy(&state);
	return written;
}
*/
import "C"

import "unsafe"

func readSystemDns() string {
	buffer := make([]byte, 1024)
	n := C.flclash_system_dns((*C.char)(unsafe.Pointer(&buffer[0])), C.int(len(buffer)))
	if n <= 0 {
		return ""
	}
	return string(buffer[:n])
}
