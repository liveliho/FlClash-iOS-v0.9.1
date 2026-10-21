package core

import "testing"

func TestFilterTunnelDns(t *testing.T) {
	got := filterTunnelDns("198.18.0.2, 192.168.1.1,fdfe:dcba:9876::2,2001:4860:4860::8888,bogus")
	want := "192.168.1.1:53,[2001:4860:4860::8888]:53"
	if got != want {
		t.Fatalf("filterTunnelDns = %q, want %q", got, want)
	}
}
