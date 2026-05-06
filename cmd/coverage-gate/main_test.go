package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEvaluate_PassFailWarn(t *testing.T) {
	b := &baseline{
		Thresholds: map[string]float64{
			"github.com/x/policy": 80,
			"github.com/x/audit":  85,
			"github.com/x/gone":   75, // missing from measured → FAIL
		},
	}
	measured := map[string]float64{
		"github.com/x/policy":   85.0, // pass
		"github.com/x/audit":    80.0, // fail
		"github.com/x/loose":    40.0, // unbaselined under 50 → WARN
		"github.com/x/loose-ok": 90.0, // unbaselined over 50 → no entry
	}
	got := evaluate(b, measured)

	statuses := map[string]Status{}
	for _, r := range got {
		statuses[r.Package] = r.Status
	}
	if statuses["github.com/x/policy"] != StatusPass {
		t.Errorf("policy: got %q, want PASS", statuses["github.com/x/policy"])
	}
	if statuses["github.com/x/audit"] != StatusFail {
		t.Errorf("audit: got %q, want FAIL", statuses["github.com/x/audit"])
	}
	if statuses["github.com/x/gone"] != StatusFail {
		t.Errorf("gone: got %q, want FAIL", statuses["github.com/x/gone"])
	}
	if statuses["github.com/x/loose"] != StatusWarn {
		t.Errorf("loose: got %q, want WARN", statuses["github.com/x/loose"])
	}
	if _, has := statuses["github.com/x/loose-ok"]; has {
		t.Errorf("loose-ok should not produce a result, got %q", statuses["github.com/x/loose-ok"])
	}

	// Sorted: failures first, warnings second, passes last.
	if got[0].Status != StatusFail {
		t.Errorf("expected FAIL first, got %q (%s)", got[0].Status, got[0].Package)
	}
}

func TestEvaluate_EpsilonTolerance(t *testing.T) {
	b := &baseline{Thresholds: map[string]float64{"github.com/x/p": 80.0}}
	// 79.97 is under 80.0 by 0.03; epsilon (0.05) means PASS.
	got := evaluate(b, map[string]float64{"github.com/x/p": 79.97})
	if got[0].Status != StatusPass {
		t.Errorf("epsilon tolerance not applied: got %q, want PASS", got[0].Status)
	}
}

func TestLoadBaseline(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "good.json")
	if err := os.WriteFile(good, []byte(`{"thresholds":{"a":80,"b":50.5}}`), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	b, err := loadBaseline(good)
	if err != nil {
		t.Fatalf("loadBaseline: %v", err)
	}
	if b.Thresholds["a"] != 80 || b.Thresholds["b"] != 50.5 {
		t.Errorf("unexpected thresholds: %+v", b.Thresholds)
	}

	bad := filepath.Join(dir, "bad.json")
	if err := os.WriteFile(bad, []byte(`not json`), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := loadBaseline(bad); err == nil {
		t.Error("expected JSON error")
	}

	empty := filepath.Join(dir, "empty.json")
	if err := os.WriteFile(empty, []byte(`{"thresholds":{}}`), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := loadBaseline(empty); err == nil {
		t.Error("expected error for empty thresholds")
	}

	outOfRange := filepath.Join(dir, "oor.json")
	if err := os.WriteFile(outOfRange, []byte(`{"thresholds":{"a":150}}`), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := loadBaseline(outOfRange); err == nil {
		t.Error("expected error for >100 threshold")
	}

	if _, err := loadBaseline("/no/such/file.json"); err == nil {
		t.Error("expected error for missing file")
	}
}

// TestRun_EndToEnd exercises the full path: load baseline, parse a
// minimal cover profile, evaluate, and assert the exit code matches the
// regression state. Captures the human log via a bytes.Buffer.
func TestRun_EndToEnd(t *testing.T) {
	dir := t.TempDir()

	baselinePath := filepath.Join(dir, "baseline.json")
	if err := os.WriteFile(baselinePath, []byte(`{
  "thresholds": {
    "github.com/example/policy": 80,
    "github.com/example/audit":  85
  }
}`), 0o644); err != nil {
		t.Fatalf("write baseline: %v", err)
	}

	profilePath := filepath.Join(dir, "cov.out")
	// policy 85% (pass), audit 50% (fail).
	body := "mode: set\n" +
		"github.com/example/policy/p.go:1.1,2.1 17 1\n" +
		"github.com/example/policy/p.go:3.1,4.1 3 0\n" +
		"github.com/example/audit/a.go:1.1,2.1 5 1\n" +
		"github.com/example/audit/a.go:3.1,4.1 5 0\n"
	if err := os.WriteFile(profilePath, []byte(body), 0o644); err != nil {
		t.Fatalf("write profile: %v", err)
	}

	// Make sure no GH env leaks into the test.
	t.Setenv("GITHUB_TOKEN", "")
	t.Setenv("PR_NUMBER", "")
	t.Setenv("GITHUB_REPOSITORY", "")
	t.Setenv("GITHUB_STEP_SUMMARY", "")

	var buf bytes.Buffer
	exit, err := run(context.Background(), baselinePath, profilePath, &buf)
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if exit != 1 {
		t.Errorf("exit=%d, want 1 (audit regressed)", exit)
	}
	out := buf.String()
	if !strings.Contains(out, "audit") || !strings.Contains(out, "FAIL") {
		t.Errorf("expected FAIL line for audit, got:\n%s", out)
	}
	if !strings.Contains(out, "policy") || !strings.Contains(out, "PASS") {
		t.Errorf("expected PASS line for policy, got:\n%s", out)
	}
}

func TestRun_StepSummaryWritten(t *testing.T) {
	dir := t.TempDir()
	baselinePath := filepath.Join(dir, "baseline.json")
	if err := os.WriteFile(baselinePath, []byte(`{"thresholds":{"github.com/example/p":50}}`), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	profilePath := filepath.Join(dir, "cov.out")
	if err := os.WriteFile(profilePath, []byte("mode: set\ngithub.com/example/p/p.go:1.1,2.1 1 1\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	stepSummary := filepath.Join(dir, "summary.md")
	t.Setenv("GITHUB_STEP_SUMMARY", stepSummary)
	t.Setenv("GITHUB_TOKEN", "")
	t.Setenv("PR_NUMBER", "")
	t.Setenv("GITHUB_REPOSITORY", "")

	var buf bytes.Buffer
	exit, err := run(context.Background(), baselinePath, profilePath, &buf)
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if exit != 0 {
		t.Errorf("exit=%d, want 0", exit)
	}
	raw, err := os.ReadFile(stepSummary)
	if err != nil {
		t.Fatalf("read summary: %v", err)
	}
	got := string(raw)
	for _, want := range []string{"## Coverage gate", "Threshold", "github.com/example/p"} {
		if !strings.Contains(got, want) {
			t.Errorf("step summary missing %q, got:\n%s", want, got)
		}
	}
}

func TestSkipRequested_NoEnv(t *testing.T) {
	t.Setenv("GITHUB_TOKEN", "")
	t.Setenv("PR_NUMBER", "")
	t.Setenv("GITHUB_REPOSITORY", "")
	got, _, err := skipRequested(context.Background())
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got {
		t.Error("expected false when no env is set")
	}
}

func TestSkipRequested_MalformedRepo(t *testing.T) {
	t.Setenv("GITHUB_TOKEN", "x")
	t.Setenv("PR_NUMBER", "1")
	t.Setenv("GITHUB_REPOSITORY", "no-slash")
	if _, _, err := skipRequested(context.Background()); err == nil {
		t.Error("expected error for malformed repo")
	}
}

func TestSkipRequested_BadPRNumber(t *testing.T) {
	t.Setenv("GITHUB_TOKEN", "x")
	t.Setenv("PR_NUMBER", "not-a-number")
	t.Setenv("GITHUB_REPOSITORY", "owner/repo")
	if _, _, err := skipRequested(context.Background()); err == nil {
		t.Error("expected error for bad PR number")
	}
}

// TestLabelJSONShape verifies the JSON shape we decode in
// skipRequested matches what GitHub returns from
// `/repos/{owner}/{repo}/issues/{n}/labels` and that our hit/miss
// detection logic does the right thing on both. We can't easily redirect
// the production function to a local server (it builds api.github.com
// URLs directly) so we test the inner logic via httptest + the same
// decode + scan dance.
func TestLabelJSONShape(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		wantHit bool
	}{
		{name: "hit", body: `[{"name":"bug"},{"name":"coverage-skip"}]`, wantHit: true},
		{name: "miss", body: `[{"name":"bug"}]`, wantHit: false},
		{name: "empty", body: `[]`, wantHit: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				_, _ = w.Write([]byte(tc.body))
			}))
			defer srv.Close()

			resp, err := http.Get(srv.URL)
			if err != nil {
				t.Fatalf("http get: %v", err)
			}
			defer func() { _ = resp.Body.Close() }()

			var labels []struct {
				Name string `json:"name"`
			}
			if err := json.NewDecoder(resp.Body).Decode(&labels); err != nil {
				t.Fatalf("decode: %v", err)
			}
			var hit bool
			for _, l := range labels {
				if l.Name == skipLabel {
					hit = true
					break
				}
			}
			if hit != tc.wantHit {
				t.Errorf("hit=%v, want %v", hit, tc.wantHit)
			}
		})
	}
}
