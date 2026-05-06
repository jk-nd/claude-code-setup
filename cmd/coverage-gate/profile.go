package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// parseProfile reads a Go coverage profile produced by `go test
// -coverprofile=...` and returns a per-package coverage map keyed by
// the import-path prefix of each file (everything before the trailing
// `/file.go`). The percentage is computed as
// statements-covered / statements-total * 100, matching what
// `go tool cover -func=` reports per package.
//
// Profile format (mode: set/count/atomic; we treat all the same):
//
//	mode: set
//	import/path/file.go:startLine.startCol,endLine.endCol numStatements covered
//	...
//
// Only the import path before the last `/` and the count fields are
// load-bearing here; the line-column ranges are ignored. The function
// is intentionally stdlib-only: pulling in golang.org/x/tools/cover
// would add a non-stdlib dep for what is a one-line-format parse.
func parseProfile(path string) (map[string]float64, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = f.Close() }()

	type acc struct {
		total, covered int
	}
	pkgs := map[string]*acc{}

	sc := bufio.NewScanner(f)
	// Cover profiles can grow large; lift the default 64 KiB scanner cap.
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	first := true
	for sc.Scan() {
		line := sc.Text()
		if first {
			first = false
			if !strings.HasPrefix(line, "mode:") {
				return nil, fmt.Errorf("not a coverage profile: missing `mode:` header")
			}
			continue
		}
		if line == "" {
			continue
		}
		stmts, covered, fileBefore, ok := splitProfileLine(line)
		if !ok {
			return nil, fmt.Errorf("malformed profile line: %q", line)
		}
		pkg := importPathForFile(fileBefore)
		if pkg == "" {
			continue
		}
		a, ok := pkgs[pkg]
		if !ok {
			a = &acc{}
			pkgs[pkg] = a
		}
		a.total += stmts
		if covered > 0 {
			a.covered += stmts
		}
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("scan profile: %w", err)
	}
	if len(pkgs) == 0 {
		return nil, errors.New("profile is empty (no files covered)")
	}

	out := make(map[string]float64, len(pkgs))
	for pkg, a := range pkgs {
		if a.total == 0 {
			continue
		}
		out[pkg] = float64(a.covered) / float64(a.total) * 100
	}
	return out, nil
}

// splitProfileLine parses one body line of a coverage profile.
// Format: `<file>:<startLine>.<startCol>,<endLine>.<endCol> <stmts> <covered>`.
// Returns (statements, count, file-portion, ok).
func splitProfileLine(line string) (int, int, string, bool) {
	// Last two whitespace-separated tokens are the integers; everything
	// before the first ':' is the file path. We split right-to-left so
	// the file path can contain colons (rare on Linux but legal).
	lastSpace := strings.LastIndexByte(line, ' ')
	if lastSpace < 0 {
		return 0, 0, "", false
	}
	covered, err := strconv.Atoi(line[lastSpace+1:])
	if err != nil {
		return 0, 0, "", false
	}
	rest := line[:lastSpace]
	prevSpace := strings.LastIndexByte(rest, ' ')
	if prevSpace < 0 {
		return 0, 0, "", false
	}
	stmts, err := strconv.Atoi(rest[prevSpace+1:])
	if err != nil {
		return 0, 0, "", false
	}
	beforeStmts := rest[:prevSpace]
	colon := strings.LastIndexByte(beforeStmts, ':')
	if colon < 0 {
		return 0, 0, "", false
	}
	return stmts, covered, beforeStmts[:colon], true
}

// importPathForFile returns the package import path for a given file
// path as recorded in the cover profile (e.g.
// `github.com/example/foo/bar/engine.go` → `github.com/example/foo/bar`).
// Files not under any directory return "".
func importPathForFile(file string) string {
	slash := strings.LastIndexByte(file, '/')
	if slash < 0 {
		return ""
	}
	return file[:slash]
}
