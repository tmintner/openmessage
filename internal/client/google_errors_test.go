package client

import (
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"testing"

	"github.com/rs/zerolog"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
)

func refreshHTTPError(status int, path string) error {
	resp := &http.Response{
		StatusCode: status,
		Request:    &http.Request{URL: &url.URL{Scheme: "https", Host: "instantmessaging-pa.clients6.google.com", Path: path}},
	}
	httpErr := events.HTTPError{Resp: resp}
	reqErr := events.RequestError{
		HTTP: &httpErr,
		Data: &gmproto.ErrorResponse{Type: 5, Message: "Requested entity was not found."},
	}
	return fmt.Errorf("failed to refresh auth token: %w", reqErr)
}

func TestGoogleRegistrationGone(t *testing.T) {
	const refreshPath = "/$rpc/google.internal.communications.instantmessaging.v1.Registration/RegisterRefresh"

	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"plain error", errors.New("some transient failure"), false},
		{"404 on RegisterRefresh", refreshHTTPError(http.StatusNotFound, refreshPath), true},
		{"410 on RegisterRefresh", refreshHTTPError(http.StatusGone, refreshPath), true},
		{"401 on RegisterRefresh", refreshHTTPError(http.StatusUnauthorized, refreshPath), false},
		{"500 on RegisterRefresh", refreshHTTPError(http.StatusInternalServerError, refreshPath), false},
		{"404 on unrelated RPC", refreshHTTPError(http.StatusNotFound, "/$rpc/Some/OtherThing"), false},
		{
			"404 with no request URL falls back to the auth-refresh wrapper",
			fmt.Errorf("failed to refresh auth token: %w", events.HTTPError{
				Resp: &http.Response{StatusCode: http.StatusNotFound},
			}),
			true,
		},
		{
			"404 with no request URL and no auth-refresh wrapper",
			events.HTTPError{Resp: &http.Response{StatusCode: http.StatusNotFound}},
			false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := GoogleRegistrationGone(tc.err); got != tc.want {
				t.Fatalf("GoogleRegistrationGone(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}

func TestHandleListenFatalError_RegistrationGoneRoutesToNeedsRepair(t *testing.T) {
	const refreshPath = "/$rpc/google.internal.communications.instantmessaging.v1.Registration/RegisterRefresh"

	var connectionLost, sessionInvalid, needsRepair int
	handler := &EventHandler{
		Logger:               zerolog.Nop(),
		OnConnectionLost:     func() { connectionLost++ },
		OnSessionInvalid:     func() { sessionInvalid++ },
		OnSessionNeedsRepair: func() { needsRepair++ },
	}

	handler.Handle(&events.ListenFatalError{Error: refreshHTTPError(http.StatusNotFound, refreshPath)})
	if needsRepair != 1 || connectionLost != 0 || sessionInvalid != 0 {
		t.Fatalf("registration-gone: needsRepair=%d connectionLost=%d sessionInvalid=%d, want 1/0/0",
			needsRepair, connectionLost, sessionInvalid)
	}

	// A transient fatal error still marks the connection lost, never needs-repair.
	handler.Handle(&events.ListenFatalError{Error: errors.New("failed to refresh auth token: unexpected EOF")})
	if needsRepair != 1 || connectionLost != 1 {
		t.Fatalf("transient fatal: needsRepair=%d connectionLost=%d, want 1/1", needsRepair, connectionLost)
	}
}

func TestHandleListenFatalError_RegistrationGoneFallsBackToConnectionLost(t *testing.T) {
	const refreshPath = "/$rpc/google.internal.communications.instantmessaging.v1.Registration/RegisterRefresh"

	var connectionLost int
	handler := &EventHandler{
		Logger:           zerolog.Nop(),
		OnConnectionLost: func() { connectionLost++ },
		// OnSessionNeedsRepair intentionally unset.
	}
	handler.Handle(&events.ListenFatalError{Error: refreshHTTPError(http.StatusNotFound, refreshPath)})
	if connectionLost != 1 {
		t.Fatalf("connectionLost=%d, want 1 (fallback when OnSessionNeedsRepair is nil)", connectionLost)
	}
}
