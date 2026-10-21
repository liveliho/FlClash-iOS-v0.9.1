//go:build ios

package mobile

import "core"

func AttachTunnel(socketPath string) {
	core.AttachTunnel(socketPath)
}

func WakeTunnel() {
	core.WakeTunnel()
}

func IsTunnelAttached() bool {
	return core.IsTunnelAttached()
}

func ServeTunnel(socketPath string) error {
	return core.ServeTunnel(socketPath)
}

func StopServingTunnel() {
	core.StopServingTunnel()
}

func FindTunFd() int32 {
	return int32(core.FindTunFd())
}

func StartTunnel(fd int32, stack, address, dns, options string) bool {
	return core.StartTunnel(int(fd), stack, address, dns, options)
}

func SetMemoryLimit(limit int64) {
	core.SetMemoryLimit(limit)
}

func SystemDns() string {
	return core.SystemDns()
}
