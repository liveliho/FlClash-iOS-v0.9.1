package core

import (
	"net/netip"
	"strings"
)

var tunnelDnsPrefixes = []netip.Prefix{
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("fdfe:dcba:9876::/48"),
}

// Once the tunnel is up the resolver lists the tunnel's own DNS address, which
// would send the Core's system queries back into itself.
func filterTunnelDns(servers string) string {
	var kept []string
	for _, server := range strings.Split(servers, ",") {
		addr, err := netip.ParseAddr(strings.TrimSpace(server))
		if err != nil {
			continue
		}
		inTunnel := false
		for _, prefix := range tunnelDnsPrefixes {
			if prefix.Contains(addr.Unmap()) {
				inTunnel = true
				break
			}
		}
		if !inTunnel {
			kept = append(kept, netip.AddrPortFrom(addr, 53).String())
		}
	}
	return strings.Join(kept, ",")
}
