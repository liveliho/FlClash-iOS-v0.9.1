package remote

import (
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatal("condition not met in time")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func socketPath(t *testing.T) string {
	return filepath.Join(t.TempDir(), "core.sock")
}

func TestCallRoundTripAndEvents(t *testing.T) {
	path := socketPath(t)
	var sinkMu sync.Mutex
	var send func([]byte)
	server, err := Listen(path, func(request []byte, reply func([]byte)) {
		go reply(append([]byte("echo:"), request...))
	}, func(s func([]byte)) {
		sinkMu.Lock()
		send = s
		sinkMu.Unlock()
	})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	events := make(chan string, 4)
	client := Dial(path, func(data []byte) { events <- string(data) }, nil)
	defer client.Close()
	waitFor(t, client.Connected)

	results := make(chan string, 8)
	for _, request := range []string{"a", "b", "c"} {
		if !client.Call([]byte(request), func(data []byte) { results <- string(data) }, func(err error) { t.Error(err) }) {
			t.Fatal("call refused while connected")
		}
	}
	got := map[string]bool{}
	for range 3 {
		select {
		case r := <-results:
			got[r] = true
		case <-time.After(5 * time.Second):
			t.Fatal("no response")
		}
	}
	for _, want := range []string{"echo:a", "echo:b", "echo:c"} {
		if !got[want] {
			t.Fatalf("missing %s in %v", want, got)
		}
	}

	waitFor(t, func() bool { sinkMu.Lock(); defer sinkMu.Unlock(); return send != nil })
	sinkMu.Lock()
	send([]byte("event"))
	sinkMu.Unlock()
	select {
	case e := <-events:
		if e != "event" {
			t.Fatalf("event = %q", e)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no event")
	}
}

func TestCallRefusedWithoutServer(t *testing.T) {
	client := Dial(socketPath(t), nil, nil)
	defer client.Close()
	if client.Call([]byte("x"), func([]byte) {}, func(error) {}) {
		t.Fatal("call accepted with no tunnel core")
	}
}

func TestPendingCallsFailOnDisconnectAndClientRedials(t *testing.T) {
	path := socketPath(t)
	server, err := Listen(path, func([]byte, func([]byte)) {}, nil)
	if err != nil {
		t.Fatal(err)
	}
	states := make(chan bool, 8)
	client := Dial(path, nil, func(connected bool) { states <- connected })
	defer client.Close()
	waitFor(t, client.Connected)

	failed := make(chan error, 1)
	client.Call([]byte("never answered"), func([]byte) { t.Error("unexpected reply") }, func(err error) { failed <- err })
	server.Close()
	select {
	case err := <-failed:
		if !errors.Is(err, ErrDisconnected) {
			t.Fatalf("err = %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("pending call never failed")
	}
	waitFor(t, func() bool { return !client.Connected() })

	server, err = Listen(path, func(request []byte, reply func([]byte)) { reply(request) }, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	waitFor(t, client.Connected)
}

func TestNewerConnectionReplacesOlder(t *testing.T) {
	path := socketPath(t)
	var sinks []bool
	var mu sync.Mutex
	server, err := Listen(path, func(request []byte, reply func([]byte)) { reply(request) }, func(s func([]byte)) {
		mu.Lock()
		sinks = append(sinks, s != nil)
		mu.Unlock()
	})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	first := Dial(path, nil, nil)
	waitFor(t, first.Connected)
	first.Close()
	second := Dial(path, nil, nil)
	defer second.Close()
	waitFor(t, second.Connected)
	reply := make(chan []byte, 1)
	waitFor(t, func() bool {
		return second.Call([]byte("ok"), func(data []byte) { reply <- data }, func(error) {})
	})
	select {
	case data := <-reply:
		if string(data) != "ok" {
			t.Fatalf("reply = %q", data)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("no reply on the newer connection")
	}
}
