package remote

import (
	"bufio"
	"errors"
	"net"
	"sync"
	"time"
)

var ErrDisconnected = errors.New("remote: tunnel core disconnected")

const (
	minRedial = 200 * time.Millisecond
	maxRedial = 2 * time.Second
)

type pendingCall struct {
	reply func([]byte)
	fail  func(error)
}

// Client keeps dialing the extension's socket until Close, so a tunnel that
// starts or restarts later is picked up without the app asking again.
type Client struct {
	path    string
	onEvent func([]byte)
	onState func(connected bool)

	mu      sync.Mutex
	conn    net.Conn
	pending map[uint32]pendingCall
	nextID  uint32
	closed  bool

	writeMu sync.Mutex
	wake    chan struct{}
	stop    chan struct{}
	done    chan struct{}
}

func Dial(path string, onEvent func([]byte), onState func(bool)) *Client {
	c := &Client{
		path:    path,
		onEvent: onEvent,
		onState: onState,
		pending: map[uint32]pendingCall{},
		wake:    make(chan struct{}, 1),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
	}
	go c.run()
	return c
}

func (c *Client) Connected() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.conn != nil
}

// Wake redials at once instead of waiting out the backoff, for a host that
// knows the tunnel has just come up.
func (c *Client) Wake() {
	select {
	case c.wake <- struct{}{}:
	default:
	}
}

// Call returns false without calling either callback when no tunnel core is
// connected, so the caller can answer the call itself.
func (c *Client) Call(request []byte, reply func([]byte), fail func(error)) bool {
	c.mu.Lock()
	conn := c.conn
	if conn == nil {
		c.mu.Unlock()
		return false
	}
	c.nextID++
	id := c.nextID
	c.pending[id] = pendingCall{reply: reply, fail: fail}
	c.mu.Unlock()

	c.writeMu.Lock()
	err := writeFrame(conn, frame{kind: kindRequest, id: id, payload: request})
	c.writeMu.Unlock()
	if err != nil {
		_ = conn.Close()
		if call, ok := c.take(id); ok {
			call.fail(err)
		}
	}
	return true
}

func (c *Client) take(id uint32) (pendingCall, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	call, ok := c.pending[id]
	delete(c.pending, id)
	return call, ok
}

func (c *Client) Close() {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	conn := c.conn
	c.mu.Unlock()
	close(c.stop)
	if conn != nil {
		_ = conn.Close()
	}
	<-c.done
}

func (c *Client) run() {
	defer close(c.done)
	delay := minRedial
	for {
		conn, err := net.Dial("unix", c.path)
		if err == nil {
			delay = minRedial
			if !c.serve(conn) {
				return
			}
		}
		timer := time.NewTimer(delay)
		select {
		case <-c.stop:
			timer.Stop()
			return
		case <-c.wake:
			timer.Stop()
			delay = minRedial
			continue
		case <-timer.C:
		}
		delay = min(delay*2, maxRedial)
	}
}

// serve reports whether the client should keep dialing.
func (c *Client) serve(conn net.Conn) bool {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		_ = conn.Close()
		return false
	}
	c.conn = conn
	c.mu.Unlock()
	c.notify(true)

	reader := bufio.NewReader(conn)
	for {
		f, err := readFrame(reader)
		if err != nil {
			break
		}
		switch f.kind {
		case kindResponse:
			if call, ok := c.take(f.id); ok {
				call.reply(f.payload)
			}
		case kindEvent:
			if c.onEvent != nil {
				c.onEvent(f.payload)
			}
		}
	}

	_ = conn.Close()
	c.mu.Lock()
	c.conn = nil
	pending := c.pending
	c.pending = map[uint32]pendingCall{}
	closed := c.closed
	c.mu.Unlock()
	for _, call := range pending {
		call.fail(ErrDisconnected)
	}
	c.notify(false)
	return !closed
}

func (c *Client) notify(connected bool) {
	if c.onState != nil {
		c.onState(connected)
	}
}
