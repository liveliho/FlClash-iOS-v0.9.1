//go:build !android

package platform

func ShouldBlockConnection() bool {
	return false
}
