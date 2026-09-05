// Package main exposes the OpenMessage backend as a C-callable static archive
// so iOS/iPadOS can host it *in-process*.
//
// Why this exists: the macOS app spawns `openmessage serve` as a child process
// (see macos/OpenMessage/Sources/BackendManager.swift). iOS has no fork/exec —
// Foundation's `Process` is not even available in the SDK — so the same trick
// cannot work there. Instead the whole backend is linked into the app binary
// and `RunServe` is run on a goroutine, still serving the identical HTTP/web
// surface on loopback that the WKWebView already knows how to talk to.
//
// This compiles only for iOS. Everything the daemon needs is pure Go
// (modernc.org/sqlite, libgm, whatsmeow), so no C dependencies come along.
//
// Build via ios/build-framework.sh, which produces OpenMessageKit.xcframework.
//
//go:build ios

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"os"
	"sync"
	"syscall"

	"github.com/rs/zerolog"

	"github.com/maxghenis/openmessage/cmd"
)

var (
	mu      sync.Mutex
	running bool
	// serveErr records why the server goroutine exited, so Swift can surface a
	// real message instead of an indefinite "Starting…" spinner.
	serveErr string
)

//export OMStart
//
// OMStart boots the backend on a background goroutine and returns immediately.
// dataDir is the app's Application Support directory (iOS sandboxes this per
// app, so unlike macOS there is no shared-store ambiguity to guard against).
// Returns 0 if the server was started, 1 if it was already running.
//
// The caller should poll OMLastError and the HTTP health endpoint to learn when
// the server is actually listening — starting is asynchronous by design so the
// UI thread is never blocked behind SQLite migrations on a cold launch.
func OMStart(dataDir *C.char, port C.int) C.int {
	mu.Lock()
	defer mu.Unlock()
	if running {
		return 1
	}

	// RunServe reads its listen config from the environment rather than
	// arguments, so set it here to keep the call identical to the CLI's.
	os.Setenv("OPENMESSAGES_DATA_DIR", C.GoString(dataDir))
	os.Setenv("OPENMESSAGES_PORT", itoa(int(port)))
	os.Setenv("OPENMESSAGES_HOST", "127.0.0.1")

	logger := zerolog.New(os.Stderr).With().Timestamp().Logger().Level(cmd.LogLevel())
	running = true
	serveErr = ""

	go func() {
		// --web serves the embedded React UI the WKWebView loads. MCP-over-SSE
		// is left off: on iOS there is no second process to serve, and the
		// stdio/SSE shapes exist for desktop MCP hosts.
		err := cmd.RunServe(logger, "--web", "--no-mcp-sse")
		mu.Lock()
		running = false
		if err != nil {
			serveErr = err.Error()
		}
		mu.Unlock()
	}()

	return 0
}

//export OMStop
//
// OMStop asks the running server to shut down and returns once it has been
// signalled.
//
// RunServe blocks on a signal channel fed by signal.Notify(SIGINT, SIGTERM).
// Because Go has installed its own handler for SIGTERM, raising it here
// unblocks that wait *without* terminating the host app — the default
// "terminate the process" disposition is no longer in effect. That lets the
// backend shut down cleanly (closing SQLite and the transport supervisors)
// while the iOS app itself keeps running.
//
// In practice iOS apps rarely need this: the system suspends the whole process
// on background, freezing the goroutines in place. It exists for an explicit
// in-app "stop backend" and for teardown in tests.
func OMStop() {
	mu.Lock()
	active := running
	mu.Unlock()
	if !active {
		return
	}
	_ = syscall.Kill(os.Getpid(), syscall.SIGTERM)
}

//export OMIsRunning
//
// OMIsRunning reports whether the serve goroutine is still alive. Note this
// says nothing about whether any messaging platform is *connected* — ask
// /api/status for that.
func OMIsRunning() C.int {
	mu.Lock()
	defer mu.Unlock()
	if running {
		return 1
	}
	return 0
}

//export OMLastError
//
// OMLastError returns the error that ended the serve goroutine, or an empty
// string. The caller owns the returned buffer and must free() it.
func OMLastError() *C.char {
	mu.Lock()
	defer mu.Unlock()
	return C.CString(serveErr)
}

// itoa avoids pulling strconv in for one call site.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

func main() {}
