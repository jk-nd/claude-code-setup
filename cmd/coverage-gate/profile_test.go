package main

import (
	"math"
	"os"
	"path/filepath"
	"testing"
)

func TestSplitProfileLine(t *testing.T) {
	cases := []struct {
		name        string
		in          string
		wantStmts   int
		wantCovered int
		wantFile    string
		wantOK      bool
	}{
		{
			name:        "covered",
			in:          "github.com/x/y/foo.go:10.13,12.50 2 1",
			wantStmts:   2,
			wantCovered: 1,
			wantFile:    "github.com/x/y/foo.go",
			wantOK:      true,
		},
		{
			name:        "uncovered",
			in:          "github.com/x/y/foo.go:1.13,3.50 4 0",
			wantStmts:   4,
			wantCovered: 0,
			wantFile:    "github.com/x/y/foo.go",
			wantOK:      true,
		},
		{
			name:   "missing-spaces",
			in:     "garbage",
			wantOK: false,
		},
		{
			name:   "non-int-stmts",
			in:     "github.com/x/foo.go:1.1,2.1 abc 1",
			wantOK: false,
		},
		{
			name:   "non-int-covered",
			in:     "github.com/x/foo.go:1.1,2.1 3 def",
			wantOK: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s, c, f, ok := splitProfileLine(tc.in)
			if ok != tc.wantOK {
				t.Fatalf("ok=%v, want %v", ok, tc.wantOK)
			}
			if !ok {
				return
			}
			if s != tc.wantStmts || c != tc.wantCovered || f != tc.wantFile {
				t.Errorf("got (%d,%d,%q), want (%d,%d,%q)",
					s, c, f, tc.wantStmts, tc.wantCovered, tc.wantFile)
			}
		})
	}
}

func TestImportPathForFile(t *testing.T) {
	cases := map[string]string{
		"github.com/x/y/foo.go":   "github.com/x/y",
		"a/b/c.go":                "a/b",
		"plain.go":                "",
		"":                        "",
		"github.com/x/y/sub/z.go": "github.com/x/y/sub",
	}
	for in, want := range cases {
		if got := importPathForFile(in); got != want {
			t.Errorf("importPathForFile(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParseProfile_HappyPath(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cov.out")
	body := "mode: set\n" +
		// pkg A: 3 covered out of 4 → 75%
		"github.com/example/a/foo.go:1.1,2.1 3 1\n" +
		"github.com/example/a/foo.go:3.1,4.1 1 0\n" +
		// pkg B: 2 covered out of 2 → 100%
		"github.com/example/b/bar.go:1.1,2.1 2 1\n"
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	got, err := parseProfile(path)
	if err != nil {
		t.Fatalf("parseProfile: %v", err)
	}
	if v := got["github.com/example/a"]; math.Abs(v-75.0) > 0.01 {
		t.Errorf("pkg a: got %.4f, want 75.0", v)
	}
	if v := got["github.com/example/b"]; math.Abs(v-100.0) > 0.01 {
		t.Errorf("pkg b: got %.4f, want 100.0", v)
	}
}

func TestParseProfile_MissingMode(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cov.out")
	if err := os.WriteFile(path, []byte("github.com/x/foo.go:1.1,2.1 1 1\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := parseProfile(path); err == nil {
		t.Fatal("expected error for missing mode header")
	}
}

func TestParseProfile_Empty(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cov.out")
	if err := os.WriteFile(path, []byte("mode: set\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := parseProfile(path); err == nil {
		t.Fatal("expected error for empty profile")
	}
}

func TestParseProfile_Malformed(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "cov.out")
	if err := os.WriteFile(path, []byte("mode: set\nthis is not a valid line\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := parseProfile(path); err == nil {
		t.Fatal("expected error for malformed line")
	}
}

func TestParseProfile_NotFound(t *testing.T) {
	if _, err := parseProfile("/no/such/file/cov.out"); err == nil {
		t.Fatal("expected error opening non-existent profile")
	}
}
