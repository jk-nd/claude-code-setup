// Command coverage-gate enforces a per-package coverage baseline. It is
// intended to be invoked from `.github/workflows/ci.yml` on every
// pull-request — a worked example of the wiring lives in the
// `coverage-gate:` block (commented out by default) of the template's
// `ci.yml.template`.
//
// The gate reads a Go coverage profile produced by
//
//	go test -coverprofile=cov.out ./...
//
// and a baseline JSON (default `ops/coverage-baseline.json`), then for
// every package listed in the baseline:
//
//   - status=PASS  → measured ≥ threshold
//   - status=FAIL  → measured < threshold (compliance-critical regression)
//   - status=WARN  → measured < 50% but the package is not in the
//     baseline; the gate emits a warning annotation and exits 0.
//
// The binary respects an opt-out: when run on a PR carrying the
// `coverage-skip` label, it logs decisions and writes the step summary
// but ALWAYS exits 0. The label is queried from the GitHub REST API
// using GITHUB_TOKEN; if either GITHUB_TOKEN or PR_NUMBER is missing
// (e.g. when invoked locally) the gate enforces strictly without
// consulting GitHub. Stdlib only — no module dependencies beyond the
// Go standard library.
//
// Operator procedure (creating the `coverage-skip` label, populating
// the baseline, running locally) is documented in `docs/setup.md`
// §Coverage gate.
//
// The gate runs only on `pull_request`, not on `push` to main, so a
// regression that is somehow merged does not block subsequent PRs that
// inherit the lower baseline. The remediation path is to file a separate
// baseline-update PR with justification.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

// httpTimeout caps the GitHub API call. The label query is a single GET
// against `/repos/.../issues/N/labels`; 30s is generous and matches the
// tone of `cmd/agentic-review/main.go`.
const httpTimeout = 30 * time.Second

// skipLabel is the literal label name the operator applies to a PR to
// reduce a coverage regression from FAIL to WARN. Documented in
// docs/setup.md §Coverage gate.
const skipLabel = "coverage-skip"

// epsilon is the float-comparison slack used when comparing the measured
// coverage against the threshold. Coverage percentages are rounded by
// the cover tool to one decimal; a tighter tolerance would bounce on
// floating-point noise. Practical effect: a measured value within 0.05
// of the threshold is treated as "meets threshold".
const epsilon = 0.05

func main() {
	var (
		baselinePath = flag.String("baseline", "ops/coverage-baseline.json", "path to the baseline JSON")
		profilePath  = flag.String("profile", "cov.out", "path to the Go coverage profile")
	)
	flag.Parse()

	exit, err := run(context.Background(), *baselinePath, *profilePath, os.Stdout)
	if err != nil {
		fmt.Fprintln(os.Stderr, "coverage-gate:", err)
		os.Exit(2)
	}
	os.Exit(exit)
}

// run is the testable entry point. It returns the process exit code (0,
// 1) and a non-nil error only for programming mistakes (missing files,
// malformed inputs); a coverage regression is signalled via exitCode=1
// with err=nil. The third argument is the writer used for human-facing
// log lines so tests can capture them.
func run(ctx context.Context, baselinePath, profilePath string, w io.Writer) (int, error) {
	baseline, err := loadBaseline(baselinePath)
	if err != nil {
		return 2, fmt.Errorf("load baseline: %w", err)
	}

	measured, err := parseProfile(profilePath)
	if err != nil {
		return 2, fmt.Errorf("parse profile: %w", err)
	}

	skipReq, skipReason, err := skipRequested(ctx)
	if err != nil {
		fmt.Fprintln(os.Stderr, "skip-label check (non-fatal):", err)
	}

	results := evaluate(baseline, measured)

	logResults(w, results)

	if err := writeStepSummary(os.Getenv("GITHUB_STEP_SUMMARY"), results, skipReq, skipReason); err != nil {
		fmt.Fprintln(os.Stderr, "step summary (non-fatal):", err)
	}

	exitCode := 0
	for _, r := range results {
		if r.Status == StatusFail {
			exitCode = 1
			break
		}
	}
	if skipReq && exitCode != 0 {
		_, _ = fmt.Fprintf(w, "coverage-gate: %s label set; downgrading FAILs to WARN and exiting 0\n", skipLabel)
		exitCode = 0
	}
	return exitCode, nil
}

// baseline is the JSON shape of `ops/coverage-baseline.json`. The
// leading underscore in `_Comment` keeps the JSON encoder happy with the
// editorial preamble and matches the convention in the file itself.
type baseline struct {
	Comment    string             `json:"_comment,omitempty"`
	Thresholds map[string]float64 `json:"thresholds"`
}

func loadBaseline(path string) (*baseline, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var b baseline
	if err := json.Unmarshal(raw, &b); err != nil {
		return nil, fmt.Errorf("unmarshal: %w", err)
	}
	if len(b.Thresholds) == 0 {
		return nil, errors.New("no thresholds declared")
	}
	for pkg, t := range b.Thresholds {
		if t < 0 || t > 100 {
			return nil, fmt.Errorf("%s: threshold %.1f outside [0,100]", pkg, t)
		}
	}
	return &b, nil
}

// Status is the per-package gate outcome.
type Status string

const (
	StatusPass Status = "PASS"
	StatusFail Status = "FAIL"
	StatusWarn Status = "WARN"
)

// result is a single per-package decision. The gate logs one line per
// result and writes the table that ends up in $GITHUB_STEP_SUMMARY.
type result struct {
	Package   string
	Threshold float64
	Actual    float64
	Status    Status
	// HasMeasurement is false when the baseline lists a package that the
	// coverage profile does not cover (e.g. the package was renamed or
	// deleted). Treated as FAIL so a stale baseline does not silently
	// stop enforcing.
	HasMeasurement bool
}

// evaluate joins the baseline with the measured map and produces one
// `result` per package in the baseline plus one WARN per measured
// package that is not in the baseline but slipped below 50%. The 50%
// threshold for unbaselined packages avoids a flood of WARNs from
// scaffolding/test-helper packages that genuinely don't need coverage.
func evaluate(b *baseline, measured map[string]float64) []result {
	out := make([]result, 0, len(b.Thresholds)+8)
	for pkg, threshold := range b.Thresholds {
		actual, ok := measured[pkg]
		r := result{
			Package:        pkg,
			Threshold:      threshold,
			Actual:         actual,
			HasMeasurement: ok,
		}
		switch {
		case !ok:
			r.Status = StatusFail
		case actual+epsilon >= threshold:
			r.Status = StatusPass
		default:
			r.Status = StatusFail
		}
		out = append(out, r)
	}

	// Surface unbaselined regressions as WARN so the operator can decide
	// whether to add them to the baseline. Threshold of 50 is a soft
	// floor; everything below this is worth a glance during review.
	const unbaselinedFloor = 50.0
	for pkg, actual := range measured {
		if _, has := b.Thresholds[pkg]; has {
			continue
		}
		if actual < unbaselinedFloor {
			out = append(out, result{
				Package:        pkg,
				Threshold:      unbaselinedFloor,
				Actual:         actual,
				Status:         StatusWarn,
				HasMeasurement: true,
			})
		}
	}

	sort.Slice(out, func(i, j int) bool {
		// Failing packages first, then warnings, then passes — easier on
		// a reviewer skimming the workflow log.
		statusRank := map[Status]int{StatusFail: 0, StatusWarn: 1, StatusPass: 2}
		if statusRank[out[i].Status] != statusRank[out[j].Status] {
			return statusRank[out[i].Status] < statusRank[out[j].Status]
		}
		return out[i].Package < out[j].Package
	})
	return out
}

func logResults(w io.Writer, results []result) {
	for _, r := range results {
		measured := fmt.Sprintf("%.1f", r.Actual)
		if !r.HasMeasurement {
			measured = "n/a"
		}
		_, _ = fmt.Fprintf(w, "%s threshold=%.1f actual=%s status=%s\n",
			r.Package, r.Threshold, measured, r.Status)
	}
}

// writeStepSummary appends a markdown table to $GITHUB_STEP_SUMMARY.
// When path is empty (e.g. local invocation) the function is a no-op.
func writeStepSummary(path string, results []result, skipReq bool, skipReason string) error {
	if path == "" {
		return nil
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()

	var b strings.Builder
	b.WriteString("## Coverage gate\n\n")
	if skipReq {
		fmt.Fprintf(&b, "**`%s` label is applied — failures are reported below but do not block the PR.**\n\n%s\n\n", skipLabel, skipReason)
	}
	var fails, warns, passes int
	for _, r := range results {
		switch r.Status {
		case StatusFail:
			fails++
		case StatusWarn:
			warns++
		case StatusPass:
			passes++
		}
	}
	fmt.Fprintf(&b, "Summary: %d FAIL, %d WARN, %d PASS\n\n", fails, warns, passes)

	b.WriteString("| Package | Threshold | Actual | Status |\n")
	b.WriteString("| --- | ---: | ---: | --- |\n")
	for _, r := range results {
		actual := fmt.Sprintf("%.1f", r.Actual)
		if !r.HasMeasurement {
			actual = "n/a"
		}
		fmt.Fprintf(&b, "| `%s` | %.1f | %s | %s |\n",
			r.Package, r.Threshold, actual, r.Status)
	}
	if fails > 0 && !skipReq {
		fmt.Fprintf(&b, "\nThe job will fail because at least one compliance-critical package regressed below baseline. To override (e.g. legitimate package removal): apply the `%s` label and re-run; document the rationale in the PR body. See `docs/setup.md` §Coverage gate.\n", skipLabel)
	}

	_, err = f.WriteString(b.String())
	return err
}

// skipRequested checks the PR for a `coverage-skip` label. It returns
// (false, "", nil) for any non-PR invocation or when the GitHub token /
// PR number is unavailable. The reason string is used for the step
// summary so the reader knows why the gate was permissive.
func skipRequested(ctx context.Context) (bool, string, error) {
	token := os.Getenv("GITHUB_TOKEN")
	prNumber := os.Getenv("PR_NUMBER")
	repo := os.Getenv("GITHUB_REPOSITORY")
	if token == "" || prNumber == "" || repo == "" {
		return false, "", nil
	}
	parts := strings.SplitN(repo, "/", 2)
	if len(parts) != 2 {
		return false, "", fmt.Errorf("malformed GITHUB_REPOSITORY: %q", repo)
	}
	num, err := strconv.Atoi(prNumber)
	if err != nil {
		return false, "", fmt.Errorf("PR_NUMBER %q: %w", prNumber, err)
	}

	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/issues/%d/labels?per_page=100",
		parts[0], parts[1], num)
	ctx, cancel := context.WithTimeout(ctx, httpTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, "", err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("Authorization", "Bearer "+token)
	hc := &http.Client{Timeout: httpTimeout}
	resp, err := hc.Do(req)
	if err != nil {
		return false, "", err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode >= 400 {
		raw, _ := io.ReadAll(resp.Body)
		return false, "", fmt.Errorf("list labels: %s: %s", resp.Status, strings.TrimSpace(string(raw)))
	}
	var labels []struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&labels); err != nil {
		return false, "", fmt.Errorf("decode labels: %w", err)
	}
	for _, l := range labels {
		if l.Name == skipLabel {
			return true, fmt.Sprintf("PR #%d carries the `%s` label.", num, skipLabel), nil
		}
	}
	return false, "", nil
}
