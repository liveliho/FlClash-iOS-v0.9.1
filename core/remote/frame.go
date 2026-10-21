// Package remote carries Core method calls between the iOS app and the Core
// running inside its packet tunnel extension. iOS gives the two processes no
// shared address space, only the App Group container, so they speak over a
// Unix socket placed there.
package remote

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

type frameKind byte

const (
	kindRequest frameKind = iota + 1
	kindResponse
	kindEvent
)

const (
	headerSize = 9
	// A response over 1 MiB is spilled to a file by the Core, so a frame this
	// large is a corrupt stream rather than a payload.
	maxPayload = 32 << 20
)

var errFrameTooLarge = errors.New("remote: frame too large")

type frame struct {
	kind    frameKind
	id      uint32
	payload []byte
}

func writeFrame(w io.Writer, f frame) error {
	var header [headerSize]byte
	header[0] = byte(f.kind)
	binary.BigEndian.PutUint32(header[1:5], f.id)
	binary.BigEndian.PutUint32(header[5:9], uint32(len(f.payload)))
	if _, err := w.Write(header[:]); err != nil {
		return err
	}
	_, err := w.Write(f.payload)
	return err
}

func readFrame(r *bufio.Reader) (frame, error) {
	var header [headerSize]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return frame{}, err
	}
	size := binary.BigEndian.Uint32(header[5:9])
	if size > maxPayload {
		return frame{}, fmt.Errorf("%w: %d bytes", errFrameTooLarge, size)
	}
	payload := make([]byte, size)
	if _, err := io.ReadFull(r, payload); err != nil {
		return frame{}, err
	}
	return frame{
		kind:    frameKind(header[0]),
		id:      binary.BigEndian.Uint32(header[1:5]),
		payload: payload,
	}, nil
}
