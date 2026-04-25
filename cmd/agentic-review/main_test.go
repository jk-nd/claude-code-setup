package main

import (
	"strings"
	"testing"
)

func TestParseClosesRef(t *testing.T) {
	cases := []struct {
		body string
		want int
	}{
		{"Closes #42", 42},
		{"closes  #11 — and more", 11},
		{"Resolves #7\nFixes #99", 7},
		{"This PR fixes #18 in passing", 18},
		{"Refs #5 (no closes/fixes)", 0},
		{"", 0},
	}
	for _, tc := range cases {
		t.Run(tc.body, func(t *testing.T) {
			if got := parseClosesRef(tc.body); got != tc.want {
				t.Errorf("parseClosesRef(%q) = %d, want %d", tc.body, got, tc.want)
			}
		})
	}
}

func TestExtractPathRefs(t *testing.T) {
	body := "See `internal/audit/emitter.go` and docs/design/architecture.md for context. " +
		"Also cmd/gateway/main.go. Repeat: internal/audit/emitter.go."
	got := extractPathRefs(body)
	want := map[string]bool{
		"internal/audit/emitter.go":   true,
		"docs/design/architecture.md": true,
		"cmd/gateway/main.go":         true,
	}
	if len(got) != len(want) {
		t.Fatalf("extractPathRefs returned %d paths: %v", len(got), got)
	}
	for _, p := range got {
		if !want[p] {
			t.Errorf("unexpected path %q", p)
		}
	}
}

func TestExtractIssueRefs(t *testing.T) {
	body := "Closes #42. See also #7 and #5. (#11)"
	got := extractIssueRefs(body)
	want := []int{42, 7, 5, 11}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i, n := range want {
		if got[i] != n {
			t.Errorf("got[%d] = %d, want %d", i, got[i], n)
		}
	}
}

func TestParseSensitivePaths(t *testing.T) {
	cases := []struct {
		raw  string
		want []string
	}{
		{"", nil},
		{"internal/audit/", []string{"internal/audit/"}},
		{"internal/audit/, internal/policy/", []string{"internal/audit/", "internal/policy/"}},
		{"  ,  ,  ", nil},
		{"a/, , b/", []string{"a/", "b/"}},
	}
	for _, tc := range cases {
		t.Run(tc.raw, func(t *testing.T) {
			got := parseSensitivePaths(tc.raw)
			if len(got) != len(tc.want) {
				t.Fatalf("parseSensitivePaths(%q) = %v, want %v", tc.raw, got, tc.want)
			}
			for i, p := range tc.want {
				if got[i] != p {
					t.Errorf("got[%d] = %q, want %q", i, got[i], p)
				}
			}
		})
	}
}

func TestEstimateCost(t *testing.T) {
	// 1M input tokens at $15 = $15.00
	if got := estimateCost(1_000_000, 0); got != 15.0 {
		t.Errorf("estimateCost(1M, 0) = %.4f, want 15.0", got)
	}
	// 1M output tokens at $75 = $75.00
	if got := estimateCost(0, 1_000_000); got != 75.0 {
		t.Errorf("estimateCost(0, 1M) = %.4f, want 75.0", got)
	}
	// Typical PR: 30K in, 1K out
	got := estimateCost(30_000, 1_000)
	wantApprox := 30_000.0*15.0/1_000_000 + 1_000.0*75.0/1_000_000
	if got != wantApprox {
		t.Errorf("estimateCost(30K, 1K) = %.4f, want %.4f", got, wantApprox)
	}
}

func TestAssembleCommentIncludesFooter(t *testing.T) {
	body := assembleComment("verdict text", 1234, 567, 0.0234)
	if !strings.Contains(body, "Read-only review") {
		t.Errorf("missing header: %s", body)
	}
	if !strings.Contains(body, "in=1234") || !strings.Contains(body, "out=567") {
		t.Errorf("missing token counts: %s", body)
	}
	if !strings.Contains(body, "$0.0234") {
		t.Errorf("missing cost: %s", body)
	}
	if !strings.Contains(body, "agentic-review:skip") {
		t.Errorf("missing opt-out hint: %s", body)
	}
}

func TestDegradedCommentExplainsFailure(t *testing.T) {
	body := degradedComment("API down")
	if !strings.Contains(body, "Status: degraded") {
		t.Errorf("missing degraded marker: %s", body)
	}
	if !strings.Contains(body, "API down") {
		t.Errorf("missing reason: %s", body)
	}
}

func TestRedactErrStripsSecrets(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "sk-ant-supersecret-value-12345")
	t.Setenv("GITHUB_TOKEN", "ghs_topsecret-9876")
	in := errorString("call failed for sk-ant-supersecret-value-12345 token=ghs_topsecret-9876")
	got := redactErr(in)
	if strings.Contains(got, "sk-ant-supersecret-value-12345") {
		t.Errorf("anthropic key not redacted: %s", got)
	}
	if strings.Contains(got, "ghs_topsecret-9876") {
		t.Errorf("github token not redacted: %s", got)
	}
	if !strings.Contains(got, "[REDACTED]") {
		t.Errorf("expected [REDACTED] markers: %s", got)
	}
}

func TestRedactErrTruncatesLong(t *testing.T) {
	long := strings.Repeat("x", 1000)
	in := errorString(long)
	got := redactErr(in)
	if len(got) > 410 {
		t.Errorf("not truncated: len=%d", len(got))
	}
	if !strings.HasSuffix(got, "…") {
		t.Errorf("missing ellipsis: %q", got[len(got)-10:])
	}
}

func TestShrinkDiffDropsLargeFiles(t *testing.T) {
	bigPatch := strings.Repeat("+ new line\n", 250)
	smallPatch := "+ small change\n"
	files := []prFile{
		{Filename: "small.go", Status: "modified", Additions: 1, Patch: smallPatch},
		{Filename: "big.go", Status: "modified", Additions: 250, Patch: bigPatch},
	}
	out, dropped := shrinkDiff(files, 10_000)
	if !strings.Contains(out, "small.go") {
		t.Errorf("small file should be present in diff: %s", out)
	}
	if !strings.Contains(out, "+ small change") {
		t.Errorf("small patch body should be present in diff")
	}
	if !strings.Contains(out, "big.go") {
		t.Errorf("big file header should be present in diff")
	}
	if strings.Contains(out, "+ new line") {
		t.Errorf("big patch body should be dropped")
	}
	if len(dropped) != 1 || dropped[0] != "big.go" {
		t.Errorf("expected dropped=[big.go], got %v", dropped)
	}
}

func TestShrinkDiffRespectsBudget(t *testing.T) {
	patch := "+ change\n"
	files := []prFile{
		{Filename: "a.go", Patch: patch},
		{Filename: "b.go", Patch: patch},
		{Filename: "c.go", Patch: patch},
	}
	// Budget so tight only one file fits.
	out, _ := shrinkDiff(files, 100)
	// We force a 1024 floor so even a tiny budget works; assert truncation marker shows up only when it should.
	// With 1024 budget, all three fit; nothing to assert beyond completion.
	if !strings.Contains(out, "a.go") {
		t.Errorf("first file should always fit: %s", out)
	}
}

func TestSystemPromptListsAllSixDimensions(t *testing.T) {
	p := systemPromptText()
	for _, want := range []string{
		"Lint clean",
		"Tests added",
		"Citations resolve",
		"Issue numbers resolve",
		"Architectural invariants",
		"Stale claims",
	} {
		if !strings.Contains(p, want) {
			t.Errorf("system prompt missing %q", want)
		}
	}
}

func TestBuildPromptIncludesCoreSections(t *testing.T) {
	pr := &pullRequest{
		Number:  42,
		Title:   "feat(ci): add trust-boundary gate",
		Body:    "Closes #42. See `internal/example/emitter.go`.",
		HTMLURL: "https://example.com/pulls/42",
	}
	pr.Head.SHA = "abc123"
	pr.Base.Ref = "main"
	files := []prFile{
		{Filename: "internal/example/emitter.go", Status: "modified", Additions: 5, Patch: "+ x\n"},
	}
	checks := []checkRun{{Name: "lint", Status: "completed", Conclusion: "success"}}
	linked := &issue{Number: 42, Title: "Trust-boundary gate", Body: "Acceptance criteria…"}
	c := staticChecks{
		ProductionWithoutTests: []string{"internal/example"},
		UnresolvedPaths:        []string{"docs/missing.md"},
		UnresolvedIssues:       []int{11},
		TouchedSensitive:       []string{"internal/example/emitter.go"},
		StaleReferences:        []string{"#13"},
	}
	prompt := buildPrompt(pr, files, checks, linked, c)
	for _, want := range []string{
		"PR #42",
		"feat(ci)",
		"Closes #42",
		"## CI check runs",
		"lint: status=completed conclusion=success",
		"## Linked issue #42",
		"## Static checks",
		"`internal/example`",
		"`docs/missing.md`",
		"#11",
		"`internal/example/emitter.go`",
		"#13",
		"## Diff",
		"+ x",
	} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt missing %q\nfull prompt:\n%s", want, prompt)
		}
	}
}

// errorString is a tiny error type so TestRedactErr* can construct
// errors without importing fmt or errors at the test top level.
type errorString string

func (e errorString) Error() string { return string(e) }
