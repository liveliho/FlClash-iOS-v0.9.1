package remote

import (
	"bufio"
	"errors"
	"net"
	"os"
	"sync"
)

// Events are dropped rather than queued without bound: while iOS suspends the
// app nothing drains the socket, and the extension has a hard memory ceiling.
const eventBacklog = 256

// Handler answers one request. reply must be called exactly once, from any
// goroutine.
type Handler func(request []byte, reply func([]byte))

// EventSink receives the function that delivers events to the connected app,
// or nil once no app is connected.
type EventSink func(send func([]byte))

type Server struct {
	listener net.Listener
	handle   Handler
	sink     EventSink

	mu      sync.Mutex
	current *serverConn
	closed  bool
	done    chan struct{}
}

// Listen serves one app connection at a time; a newer connection replaces the
// older one, which is what a relaunched app looks like from here.
func Listen(path string, handle Handler, sink EventSink) (*Server, error) {
	_ = os.Remove(path)
	listener, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	s := &Server{
		listener: listener,
		handle:   handle,
		sink:     sink,
		done:     make(chan struct{}),
	}
	go s.accept()
	return s, nil
}

func (s *Server) accept() {
	defer close(s.done)
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			continue
		}
		s.attach(newServerConn(conn))
	}
}

func (s *Server) attach(c *serverConn) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		c.close()
		return
	}
	previous := s.current
	s.current = c
	s.mu.Unlock()
	if previous != nil {
		previous.close()
	}
	if s.sink != nil {
		s.sink(c.sendEvent)
	}
	go func() {
		c.serve(s.handle)
		s.detach(c)
	}()
}

func (s *Server) detach(c *serverConn) {
	s.mu.Lock()
	if s.current != c {
		s.mu.Unlock()
		return
	}
	s.current = nil
	s.mu.Unlock()
	if s.sink != nil {
		s.sink(nil)
	}
}

func (s *Server) Close() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	current := s.current
	s.current = nil
	s.mu.Unlock()
	_ = s.listener.Close()
	<-s.done
	if current != nil {
		current.close()
		if s.sink != nil {
			s.sink(nil)
		}
	}
}

type serverConn struct {
	conn      net.Conn
	responses chan frame
	events    chan frame
	closing   chan struct{}
	closeOnce sync.Once
}

func newServerConn(conn net.Conn) *serverConn {
	return &serverConn{
		conn:      conn,
		responses: make(chan frame, 16),
		events:    make(chan frame, eventBacklog),
		closing:   make(chan struct{}),
	}
}

func (c *serverConn) close() {
	c.closeOnce.Do(func() {
		close(c.closing)
		_ = c.conn.Close()
	})
}

func (c *serverConn) sendEvent(data []byte) {
	select {
	case <-c.closing:
	case c.events <- frame{kind: kindEvent, payload: data}:
	default:
	}
}

func (c *serverConn) sendResponse(id uint32, data []byte) {
	select {
	case <-c.closing:
	case c.responses <- frame{kind: kindResponse, id: id, payload: data}:
	}
}

func (c *serverConn) serve(handle Handler) {
	defer c.close()
	go c.write()
	reader := bufio.NewReader(c.conn)
	for {
		f, err := readFrame(reader)
		if err != nil {
			return
		}
		if f.kind != kindRequest {
			continue
		}
		id := f.id
		var once sync.Once
		handle(f.payload, func(data []byte) {
			once.Do(func() { c.sendResponse(id, data) })
		})
	}
}

// Responses go first: a caller is waiting on each, while an event that waits
// only grows staler.
func (c *serverConn) write() {
	writer := bufio.NewWriter(c.conn)
	for {
		var f frame
		select {
		case <-c.closing:
			return
		case f = <-c.responses:
		default:
			select {
			case <-c.closing:
				return
			case f = <-c.responses:
			case f = <-c.events:
			}
		}
		if err := writeFrame(writer, f); err != nil {
			c.close()
			return
		}
		if len(c.responses) == 0 && len(c.events) == 0 {
			if err := writer.Flush(); err != nil {
				c.close()
				return
			}
		}
	}
}
