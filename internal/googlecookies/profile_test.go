package googlecookies

import (
	"os"
	"path/filepath"
	"testing"
)

func accountCookieRows() []dbCookie {
	rows := make([]dbCookie, 0, len(requiredCookies))
	for _, req := range requiredCookies {
		rows = append(rows, dbCookie{req.host, req.name, []byte("v10stub")})
	}
	return rows
}

func writeProfileCookies(t *testing.T, base, profile string, rows []dbCookie) {
	t.Helper()
	dir := filepath.Join(base, profile, "Network")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir %s: %v", dir, err)
	}
	writeCookieDB(t, filepath.Join(dir, "Cookies"), rows)
}

func TestDefaultChromeProfileDirPrefersProfileWithAccountCookies(t *testing.T) {
	home := t.TempDir()
	base := chromeUserDataDir(home)

	// "Default" exists but holds no Google account cookies; "Profile 1" does.
	writeProfileCookies(t, base, "Default", []dbCookie{{".google.com", "NID", []byte("v10stub")}})
	writeProfileCookies(t, base, "Profile 1", accountCookieRows())

	got := defaultChromeProfileDir(home)
	want := filepath.Join(base, "Profile 1")
	if got != want {
		t.Fatalf("defaultChromeProfileDir() = %q, want %q", got, want)
	}
}

func TestDefaultChromeProfileDirHonoursLocalStateOrder(t *testing.T) {
	home := t.TempDir()
	base := chromeUserDataDir(home)

	writeProfileCookies(t, base, "Default", accountCookieRows())
	writeProfileCookies(t, base, "Profile 2", accountCookieRows())
	if err := os.WriteFile(filepath.Join(base, "Local State"),
		[]byte(`{"profile":{"last_used":"Profile 2","profiles_order":["Profile 2","Default"]}}`), 0o600); err != nil {
		t.Fatal(err)
	}

	got := defaultChromeProfileDir(home)
	want := filepath.Join(base, "Profile 2")
	if got != want {
		t.Fatalf("defaultChromeProfileDir() = %q, want %q (last_used should win)", got, want)
	}
}

func TestDefaultChromeProfileDirFallsBackToDefault(t *testing.T) {
	home := t.TempDir()
	base := chromeUserDataDir(home)

	// No profiles on disk at all.
	got := defaultChromeProfileDir(home)
	want := filepath.Join(base, "Default")
	if got != want {
		t.Fatalf("defaultChromeProfileDir() = %q, want %q", got, want)
	}
}

func TestDefaultChromeProfileDirUsesAnyProfileWithDBWhenNoneHaveAccountCookies(t *testing.T) {
	home := t.TempDir()
	base := chromeUserDataDir(home)

	writeProfileCookies(t, base, "Profile 3", []dbCookie{{".google.com", "NID", []byte("v10stub")}})

	got := defaultChromeProfileDir(home)
	want := filepath.Join(base, "Profile 3")
	if got != want {
		t.Fatalf("defaultChromeProfileDir() = %q, want %q", got, want)
	}
}
