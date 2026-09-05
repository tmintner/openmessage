// Google account pairing, driven in-process.
//
// On macOS the app shells out to `openmessage pair --google-stdin` and scrapes
// the child's stdout for the "EMOJI: X" line the user must confirm on their
// phone (see PairingView.swift). iOS cannot spawn that child, so this runs
// cmd.RunPair on a goroutine instead and captures the same stdout stream, which
// keeps the wire format — and therefore the UI's parsing — identical.
//
// Cookies arrive as a file path rather than stdin: --google-file is an existing
// supported flag, and writing to a file inside the app sandbox is far simpler
// than swapping os.Stdin underneath a running process.
//
//go:build ios

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"bufio"
	"encoding/json"
	"os"
	"strings"
	"sync"

	"github.com/rs/zerolog"

	"github.com/maxghenis/openmessage/cmd"
)

var (
	pairMu      sync.Mutex
	pairRunning bool
	pairDone    bool
	pairOutput  []string
	pairError   string
)

//export OMPairGoogle
//
// OMPairGoogle begins Google account pairing using cookies previously written
// to cookiePath (a JSON object or a copied cURL command — parseGoogleCookiesInput
// accepts both). Returns 0 if pairing started, 1 if it was already in flight.
//
// Progress is asynchronous; poll OMPairStatus for the emoji prompt and the
// final result.
func OMPairGoogle(cookiePath *C.char) C.int {
	pairMu.Lock()
	if pairRunning {
		pairMu.Unlock()
		return 1
	}
	pairRunning = true
	pairDone = false
	pairOutput = nil
	pairError = ""
	pairMu.Unlock()

	path := C.GoString(cookiePath)

	go func() {
		// RunPair reports the pairing emoji with fmt.Println, i.e. to os.Stdout.
		// Swap in a pipe so those lines can be relayed to the UI, then restore
		// the real stdout so later logging is not left writing into a closed
		// pipe. Safe here because pairing is a modal phase with no other
		// concurrent stdout writer (zerolog logs to stderr).
		realStdout := os.Stdout
		r, w, err := os.Pipe()
		if err != nil {
			finishPairing("capture pairing output: " + err.Error())
			return
		}
		os.Stdout = w

		var wg sync.WaitGroup
		wg.Add(1)
		go func() {
			defer wg.Done()
			scanner := bufio.NewScanner(r)
			for scanner.Scan() {
				line := strings.TrimSpace(scanner.Text())
				if line == "" {
					continue
				}
				pairMu.Lock()
				pairOutput = append(pairOutput, line)
				pairMu.Unlock()
			}
		}()

		logger := zerolog.New(os.Stderr).With().Timestamp().Logger().Level(cmd.LogLevel())
		runErr := cmd.RunPair(logger, "--google-file", path)

		os.Stdout = realStdout
		_ = w.Close()
		wg.Wait()
		_ = r.Close()

		// The cookie file holds live Google credentials — remove it as soon as
		// pairing is done rather than leaving it in the sandbox.
		_ = os.Remove(path)

		msg := ""
		if runErr != nil {
			msg = runErr.Error()
		}
		finishPairing(msg)
	}()

	return 0
}

func finishPairing(errMsg string) {
	pairMu.Lock()
	defer pairMu.Unlock()
	pairRunning = false
	pairDone = true
	pairError = errMsg
}

//export OMPairStatus
//
// OMPairStatus returns the pairing state as a JSON object:
//
//	{"running": bool, "done": bool, "error": string, "output": [string]}
//
// "output" is every line the pairing flow has printed so far, including the
// "EMOJI: X" line the user must tap in Google Messages on their phone.
// The caller owns the returned buffer and must free() it.
func OMPairStatus() *C.char {
	pairMu.Lock()
	payload := struct {
		Running bool     `json:"running"`
		Done    bool     `json:"done"`
		Error   string   `json:"error"`
		Output  []string `json:"output"`
	}{
		Running: pairRunning,
		Done:    pairDone,
		Error:   pairError,
		Output:  append([]string(nil), pairOutput...),
	}
	pairMu.Unlock()

	encoded, err := json.Marshal(payload)
	if err != nil {
		return C.CString(`{"running":false,"done":true,"error":"encode pair status","output":[]}`)
	}
	return C.CString(string(encoded))
}
