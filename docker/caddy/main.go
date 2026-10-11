// Caddy build entry point, identical to the official cmd/caddy with the
// standard module set. It is built here (instead of copying the official
// binary) so that the Go toolchain and vulnerable dependencies can be updated
// independently of Caddy releases.
package main

import (
	caddycmd "github.com/caddyserver/caddy/v2/cmd"

	_ "github.com/caddyserver/caddy/v2/modules/standard"
)

func main() {
	caddycmd.Main()
}
