//go:build android

package core

func forwardMethodCall(*MethodCall, func([]byte)) bool {
	return false
}
