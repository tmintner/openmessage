package client

import (
	"errors"
	"net/http"
	"strings"

	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
)

// GoogleRegistrationGone reports whether err means the Google Messages
// linked-device registration no longer exists on Google's servers: a 404 (or
// 410) from the Registration/RegisterRefresh RPC, which carries a TachyonError
// with type NOT_FOUND ("Requested entity was not found.").
//
// This condition is terminal. A one-off HTTP 401 or an expired cookie is
// recoverable — a reconnect or a cookie refresh brings the session back — but a
// missing registration is not: the phone has unlinked this device (commonly
// after the app is offline for weeks) and only a re-pair restores it. libgm
// reports it as a "fatal" listen error on every auth-token refresh, so without
// special handling the supervisor's reconnect loop retries it forever, never
// sets needs_repair, and hammers Google's auth endpoint (a throttling risk).
func GoogleRegistrationGone(err error) bool {
	if err == nil {
		return false
	}
	var httpErr events.HTTPError
	if !errors.As(err, &httpErr) || httpErr.Resp == nil {
		return false
	}
	if httpErr.Resp.StatusCode != http.StatusNotFound && httpErr.Resp.StatusCode != http.StatusGone {
		return false
	}
	// Scope to the auth/registration refresh path so an unrelated 404 (a deleted
	// conversation, a stale media blob) can never be mistaken for a dead session.
	if req := httpErr.Resp.Request; req != nil && req.URL != nil {
		return strings.Contains(req.URL.Path, "RegisterRefresh") ||
			strings.Contains(req.URL.Path, "Registration/")
	}
	// No request URL on the response (unusual): fall back to the wrapper libgm
	// puts on every auth-token refresh failure.
	return strings.Contains(strings.ToLower(err.Error()), "refresh auth token")
}
