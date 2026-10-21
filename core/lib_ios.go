//go:build ios

package core

import (
	"encoding/json"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"

	"core/remote"

	"golang.org/x/sys/unix"
)

var (
	appHost      atomic.Bool
	tunnelClient atomic.Pointer[remote.Client]

	tunnelServerMu sync.Mutex
	tunnelServer   *remote.Server
)

// These read or transform files and hold no runtime state, so the app answers
// them itself and keeps their memory out of the extension's hard ceiling.
var appLocalMethods = map[CoreMethod]bool{
	initClashMethod:           true,
	getIsInitMethod:           true,
	forceGcMethod:             true,
	shutdownMethod:            true,
	validateConfigMethod:      true,
	decryptConfigMethod:       true,
	validateProxiesMethod:     true,
	validateFiltersMethod:     true,
	convertProxiesMethod:      true,
	encodeShareLinksMethod:    true,
	decodeShareLinksMethod:    true,
	updateDnsMethod:           true,
	crashMethod:               true,
	getConfigMethod:           true,
	getProfileBaseMethod:      true,
	getProfileOutboundsMethod: true,
	buildProfileMethod:        true,
	dumpRuleSetMethod:         true,
	compileRuleSetMethod:      true,
}

func forwardMethodCall(call *MethodCall, reply func([]byte)) bool {
	if !appHost.Load() {
		return false
	}
	switch call.Method {
	// Only the extension listens: the app is suspended in the background and
	// would hold the mixed port the tunnel's Core needs.
	case startListenerMethod, stopListenerMethod:
		reply(encodeResponse(MethodResponse{ID: call.ID, Result: true}))
		return true
	}
	if appLocalMethods[call.Method] {
		return false
	}
	client := tunnelClient.Load()
	if client == nil {
		return false
	}
	data, err := json.Marshal(call)
	if err != nil {
		return false
	}
	return client.Call(data, reply, func(err error) {
		reply(encodeResponse(MethodResponse{ID: call.ID, Error: &MethodError{
			Code:    "tunnel_unavailable",
			Message: err.Error(),
		}}))
	})
}

// AttachTunnel marks this process as the app and routes runtime calls to the
// tunnel's Core whenever its socket accepts a connection.
func AttachTunnel(socketPath string) {
	defer recoverExport("attachTunnel")
	appHost.Store(true)
	next := remote.Dial(socketPath, deliverEvent, nil)
	if previous := tunnelClient.Swap(next); previous != nil {
		previous.Close()
	}
}

func WakeTunnel() {
	if client := tunnelClient.Load(); client != nil {
		client.Wake()
	}
}

func IsTunnelAttached() bool {
	client := tunnelClient.Load()
	return client != nil && client.Connected()
}

func ServeTunnel(socketPath string) error {
	defer recoverExport("serveTunnel")
	tunnelServerMu.Lock()
	defer tunnelServerMu.Unlock()
	if tunnelServer != nil {
		tunnelServer.Close()
		tunnelServer = nil
	}
	server, err := remote.Listen(socketPath, func(request []byte, reply func([]byte)) {
		call := &MethodCall{}
		if err := json.Unmarshal(request, call); err != nil {
			reply(encodeResponse(MethodResponse{Error: &MethodError{
				Code:    "invalid_method_call",
				Message: err.Error(),
			}}))
			return
		}
		dispatchMethodCall(call, reply)
	}, func(send func([]byte)) {
		SetEventListener(send)
	})
	if err != nil {
		return err
	}
	tunnelServer = server
	return nil
}

func StopServingTunnel() {
	defer recoverExport("stopServingTunnel")
	tunnelServerMu.Lock()
	defer tunnelServerMu.Unlock()
	if tunnelServer != nil {
		tunnelServer.Close()
		tunnelServer = nil
	}
}

// x/sys/unix leaves out the kernel control constants on iOS; the values are
// from <sys/kern_control.h> and <net/if_utun.h>.
const (
	sysprotoControl = 2
	utunOptIfname   = 2
)

// NEPacketTunnelFlow keeps its utun socket private; the descriptor is found the
// way WireGuard and sing-box find it, by asking each one for its utun name.
func FindTunFd() int {
	for fd := 0; fd < 1024; fd++ {
		name, err := unix.GetsockoptString(fd, sysprotoControl, utunOptIfname)
		if err == nil && strings.HasPrefix(name, "utun") {
			return fd
		}
	}
	return -1
}

func SetMemoryLimit(limit int64) {
	debug.SetMemoryLimit(limit)
}

func SystemDns() string {
	defer recoverExport("systemDns")
	return filterTunnelDns(readSystemDns())
}

type noopTunCallbacks struct{}

// The extension's own sockets bypass its tunnel, and iOS exposes no socket
// owners to resolve.
func (noopTunCallbacks) Protect(int) bool { return true }

func (noopTunCallbacks) ResolveUid(int, string, string) int { return -1 }

func (noopTunCallbacks) ResolvePackage(int) string { return "" }

func StartTunnel(fd int, stack, address, dns, options string) bool {
	return StartTun(noopTunCallbacks{}, fd, stack, address, dns, options)
}
