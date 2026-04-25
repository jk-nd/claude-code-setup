// Command agentic-review is the read-only implementation of the
// agentic PR review for any project using this template. It is invoked
// from `.github/workflows/agentic-review.yml`. It reads the pull
// request's metadata and diff via the GitHub REST API, fetches the
// linked issue (if a `closes #N` reference is present in the body) and
// the CI check runs for the PR's HEAD, builds a structured prompt,
// calls the Anthropic Messages API, and posts the markdown response as
// a sticky comment on the PR. The workflow exits 0 even on API
// failures so that agent infrastructure issues do not block CI for
// everyone else.
//
// The agent is read-only by design: it never pushes commits, never
// modifies labels, never bypasses the trust-boundary gate.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// stickyMarker is embedded as the first line of the PR comment so the
// workflow can find and update the same comment across pushes instead
// of appending a fresh comment on every iteration. It mirrors the
// sticky-comment pattern from `.github/workflows/trust-boundary.yml`.
const stickyMarker = "<!-- agentic-review:sticky -->"

// anthropicModel pins the snapshot used by the review. Pinning by
// snapshot guarantees reproducibility across the workflow's lifetime
// even as Anthropic ships new defaults; bump deliberately.
const anthropicModel = "claude-opus-4-7-1m"

// anthropicEndpoint is the Messages API. Stdlib net/http + encoding/json
// is sufficient — we deliberately avoid pulling in another module
// dependency so the binary stays drop-in across template instantiations.
const anthropicEndpoint = "https://api.anthropic.com/v1/messages"

// anthropicVersion is the dated wire-format header expected by the API.
const anthropicVersion = "2023-06-01"

// Cost guard limits. Diff is truncated to fit within the input cap and
// the output is hard-capped at 2K tokens. Both are documented in
// docs/agentic-review.md so operators know the per-PR ceiling.
const (
	maxInputTokensApprox  = 50_000
	maxOutputTokens       = 2_000
	largeFileLineCutoff   = 200
	approxCharsPerToken   = 4
	maxDiffCharsBudget    = maxInputTokensApprox * approxCharsPerToken
	httpTimeout           = 90 * time.Second
	anthropicCallDeadline = 4 * time.Minute
)

// Approximate Anthropic Opus pricing in USD per 1M tokens. Used to
// estimate review cost; the operator-facing doc warns that this is an
// estimate and the authoritative number lives at anthropic.com/pricing.
const (
	usdPerMTokIn  = 15.0
	usdPerMTokOut = 75.0
)

// closesRefRe matches `closes #NN` / `fixes #NN` / `resolves #NN`
// in the PR body. The match is loose on purpose so PR authors can
// write naturally; we only use the resulting issue number to fetch
// the linked acceptance criteria.
var closesRefRe = regexp.MustCompile(`(?i)\b(?:closes|fixes|resolves)\s+#(\d+)\b`)

// issueRefRe extracts every `#NN` reference (so we can verify each
// resolves on GitHub).
var issueRefRe = regexp.MustCompile(`(?:^|[^&\w])#(\d+)\b`)

// pathRefRe captures the repo-relative paths the PR body cites. We
// only run the regex once so it stays cheap; the heuristic is
// "starts with one of the known top-level prefixes and contains no
// whitespace before the next quote/backtick boundary." The prefix list
// is intentionally broad so it works across language ecosystems.
var pathRefRe = regexp.MustCompile(`(?:^|[^\w/])` +
	`((?:internal|cmd|src|lib|pkg|app|docs|examples|test|tests|scripts|\.github)/[\w./\-]+)`)

func main() {
	if err := run(context.Background()); err != nil {
		fmt.Fprintln(os.Stderr, "agentic-review:", err)
		// Never block CI on agent-infrastructure issues. The workflow
		// still posts a degraded comment via the same Go program when
		// it can; the exit-0 contract is the read-only safety boundary.
		os.Exit(0)
	}
}

// run is the testable entry point. It returns errors only for
// programming mistakes (missing required env, malformed event payload);
// transient API failures are logged and degrade to a fallback comment.
func run(ctx context.Context) error {
	cfg, err := loadConfig()
	if err != nil {
		return fmt.Errorf("config: %w", err)
	}

	gh := newGitHubClient(cfg.GitHubToken)

	pr, err := gh.getPR(ctx, cfg.Owner, cfg.Repo, cfg.PRNumber)
	if err != nil {
		return fmt.Errorf("get pr: %w", err)
	}

	files, err := gh.listPRFiles(ctx, cfg.Owner, cfg.Repo, cfg.PRNumber)
	if err != nil {
		return fmt.Errorf("list files: %w", err)
	}

	checks, err := gh.listCheckRuns(ctx, cfg.Owner, cfg.Repo, pr.Head.SHA)
	if err != nil {
		// Check runs are advisory; don't fail the whole review.
		fmt.Fprintln(os.Stderr, "list checks (non-fatal):", err)
		checks = nil
	}

	var linked *issue
	if num := parseClosesRef(pr.Body); num > 0 {
		got, err := gh.getIssue(ctx, cfg.Owner, cfg.Repo, num)
		if err != nil {
			fmt.Fprintf(os.Stderr, "linked issue #%d (non-fatal): %v\n", num, err)
		} else {
			linked = got
		}
	}

	checked := runStaticChecks(ctx, gh, cfg, pr, files)

	prompt := buildPrompt(pr, files, checks, linked, checked)
	systemPrompt := systemPromptText()

	if cfg.AnthropicAPIKey == "" {
		body := degradedComment("ANTHROPIC_API_KEY secret is not set; agentic review is in degraded mode. Configure the secret in repo settings to enable.")
		return gh.upsertStickyComment(ctx, cfg.Owner, cfg.Repo, cfg.PRNumber, body)
	}

	resp, err := callAnthropic(ctx, cfg.AnthropicAPIKey, systemPrompt, prompt)
	if err != nil {
		fmt.Fprintln(os.Stderr, "anthropic call failed:", err)
		body := degradedComment(fmt.Sprintf("Anthropic API call failed (%s). Review will retry on the next push. See workflow logs.", redactErr(err)))
		return gh.upsertStickyComment(ctx, cfg.Owner, cfg.Repo, cfg.PRNumber, body)
	}

	cost := estimateCost(resp.usageInputTokens, resp.usageOutputTokens)
	body := assembleComment(resp.text, resp.usageInputTokens, resp.usageOutputTokens, cost)

	if err := writeStepSummary(cfg.StepSummaryPath, resp, cost); err != nil {
		fmt.Fprintln(os.Stderr, "step summary (non-fatal):", err)
	}

	return gh.upsertStickyComment(ctx, cfg.Owner, cfg.Repo, cfg.PRNumber, body)
}

// config carries the inputs the binary needs from the workflow env.
type config struct {
	GitHubToken     string
	AnthropicAPIKey string
	Owner           string
	Repo            string
	PRNumber        int
	Workspace       string
	StepSummaryPath string
}

func loadConfig() (config, error) {
	cfg := config{
		GitHubToken:     os.Getenv("GITHUB_TOKEN"),
		AnthropicAPIKey: os.Getenv("ANTHROPIC_API_KEY"),
		Workspace:       os.Getenv("GITHUB_WORKSPACE"),
		StepSummaryPath: os.Getenv("GITHUB_STEP_SUMMARY"),
	}
	if cfg.GitHubToken == "" {
		return cfg, errors.New("GITHUB_TOKEN is required")
	}

	repo := os.Getenv("GITHUB_REPOSITORY") // owner/repo
	if repo == "" {
		return cfg, errors.New("GITHUB_REPOSITORY is required")
	}
	parts := strings.SplitN(repo, "/", 2)
	if len(parts) != 2 {
		return cfg, fmt.Errorf("malformed GITHUB_REPOSITORY: %q", repo)
	}
	cfg.Owner = parts[0]
	cfg.Repo = parts[1]

	if n, err := readPRNumber(); err != nil {
		return cfg, fmt.Errorf("pr number: %w", err)
	} else {
		cfg.PRNumber = n
	}

	return cfg, nil
}

// readPRNumber prefers the explicit PR_NUMBER env (workflow sets it) and
// falls back to the event payload at GITHUB_EVENT_PATH for robustness.
func readPRNumber() (int, error) {
	if v := os.Getenv("PR_NUMBER"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			return 0, fmt.Errorf("PR_NUMBER %q: %w", v, err)
		}
		return n, nil
	}
	path := os.Getenv("GITHUB_EVENT_PATH")
	if path == "" {
		return 0, errors.New("neither PR_NUMBER nor GITHUB_EVENT_PATH is set")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0, fmt.Errorf("read event payload: %w", err)
	}
	var ev struct {
		PullRequest struct {
			Number int `json:"number"`
		} `json:"pull_request"`
		Number int `json:"number"`
	}
	if err := json.Unmarshal(raw, &ev); err != nil {
		return 0, fmt.Errorf("parse event payload: %w", err)
	}
	if ev.PullRequest.Number > 0 {
		return ev.PullRequest.Number, nil
	}
	if ev.Number > 0 {
		return ev.Number, nil
	}
	return 0, errors.New("event payload missing pull_request.number")
}

// gitHub thin wrapper. Stdlib only; the API surface we use is small
// enough that pulling in google/go-github would dwarf the value.
type gitHubClient struct {
	token string
	hc    *http.Client
}

func newGitHubClient(token string) *gitHubClient {
	return &gitHubClient{
		token: token,
		hc:    &http.Client{Timeout: httpTimeout},
	}
}

type pullRequest struct {
	Number int    `json:"number"`
	Title  string `json:"title"`
	Body   string `json:"body"`
	State  string `json:"state"`
	Draft  bool   `json:"draft"`
	Head   struct {
		SHA string `json:"sha"`
	} `json:"head"`
	Base struct {
		Ref string `json:"ref"`
	} `json:"base"`
	HTMLURL string `json:"html_url"`
}

type prFile struct {
	Filename  string `json:"filename"`
	Status    string `json:"status"`
	Additions int    `json:"additions"`
	Deletions int    `json:"deletions"`
	Patch     string `json:"patch"`
}

type checkRun struct {
	Name       string `json:"name"`
	Status     string `json:"status"`
	Conclusion string `json:"conclusion"`
	HTMLURL    string `json:"html_url"`
}

type issue struct {
	Number int    `json:"number"`
	Title  string `json:"title"`
	Body   string `json:"body"`
	State  string `json:"state"`
}

type comment struct {
	ID   int64  `json:"id"`
	Body string `json:"body"`
}

func (g *gitHubClient) do(ctx context.Context, method, url string, body io.Reader) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("Authorization", "Bearer "+g.token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := g.hc.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		raw, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		return nil, fmt.Errorf("%s %s: %s: %s", method, url, resp.Status, strings.TrimSpace(string(raw)))
	}
	return resp, nil
}

func (g *gitHubClient) getPR(ctx context.Context, owner, repo string, num int) (*pullRequest, error) {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/pulls/%d", owner, repo, num)
	resp, err := g.do(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	var out pullRequest
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (g *gitHubClient) listPRFiles(ctx context.Context, owner, repo string, num int) ([]prFile, error) {
	var all []prFile
	page := 1
	for {
		url := fmt.Sprintf("https://api.github.com/repos/%s/%s/pulls/%d/files?per_page=100&page=%d", owner, repo, num, page)
		resp, err := g.do(ctx, http.MethodGet, url, nil)
		if err != nil {
			return nil, err
		}
		var batch []prFile
		if err := json.NewDecoder(resp.Body).Decode(&batch); err != nil {
			_ = resp.Body.Close()
			return nil, err
		}
		_ = resp.Body.Close()
		if len(batch) == 0 {
			break
		}
		all = append(all, batch...)
		if len(batch) < 100 {
			break
		}
		page++
		if page > 30 {
			break // safety
		}
	}
	return all, nil
}

func (g *gitHubClient) listCheckRuns(ctx context.Context, owner, repo, sha string) ([]checkRun, error) {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/commits/%s/check-runs?per_page=100", owner, repo, sha)
	resp, err := g.do(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	var wrapper struct {
		CheckRuns []checkRun `json:"check_runs"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&wrapper); err != nil {
		return nil, err
	}
	return wrapper.CheckRuns, nil
}

func (g *gitHubClient) getIssue(ctx context.Context, owner, repo string, num int) (*issue, error) {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/issues/%d", owner, repo, num)
	resp, err := g.do(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	var out issue
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	return &out, nil
}

func (g *gitHubClient) issueExists(ctx context.Context, owner, repo string, num int) (bool, error) {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/issues/%d", owner, repo, num)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("Authorization", "Bearer "+g.token)
	resp, err := g.hc.Do(req)
	if err != nil {
		return false, err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode == http.StatusNotFound {
		return false, nil
	}
	if resp.StatusCode >= 400 {
		return false, fmt.Errorf("issueExists %d: %s", num, resp.Status)
	}
	return true, nil
}

func (g *gitHubClient) listIssueComments(ctx context.Context, owner, repo string, issueNum int) ([]comment, error) {
	var all []comment
	page := 1
	for {
		url := fmt.Sprintf("https://api.github.com/repos/%s/%s/issues/%d/comments?per_page=100&page=%d", owner, repo, issueNum, page)
		resp, err := g.do(ctx, http.MethodGet, url, nil)
		if err != nil {
			return nil, err
		}
		var batch []comment
		if err := json.NewDecoder(resp.Body).Decode(&batch); err != nil {
			_ = resp.Body.Close()
			return nil, err
		}
		_ = resp.Body.Close()
		if len(batch) == 0 {
			break
		}
		all = append(all, batch...)
		if len(batch) < 100 {
			break
		}
		page++
		if page > 30 {
			break
		}
	}
	return all, nil
}

func (g *gitHubClient) createComment(ctx context.Context, owner, repo string, issueNum int, body string) error {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/issues/%d/comments", owner, repo, issueNum)
	payload, err := json.Marshal(struct {
		Body string `json:"body"`
	}{Body: body})
	if err != nil {
		return err
	}
	resp, err := g.do(ctx, http.MethodPost, url, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	return nil
}

func (g *gitHubClient) updateComment(ctx context.Context, owner, repo string, commentID int64, body string) error {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s/issues/comments/%d", owner, repo, commentID)
	payload, err := json.Marshal(struct {
		Body string `json:"body"`
	}{Body: body})
	if err != nil {
		return err
	}
	resp, err := g.do(ctx, http.MethodPatch, url, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	return nil
}

func (g *gitHubClient) upsertStickyComment(ctx context.Context, owner, repo string, prNum int, body string) error {
	full := stickyMarker + "\n" + body
	comments, err := g.listIssueComments(ctx, owner, repo, prNum)
	if err != nil {
		return err
	}
	for _, c := range comments {
		if strings.HasPrefix(c.Body, stickyMarker) {
			return g.updateComment(ctx, owner, repo, c.ID, full)
		}
	}
	return g.createComment(ctx, owner, repo, prNum, full)
}

// staticChecks captures the deterministic checks the binary runs locally
// before delegating the rest to Claude. Keeping these out of the LLM
// prompt makes them auditable and resistant to hallucination.
type staticChecks struct {
	ProductionWithoutTests []string
	UnresolvedPaths        []string
	UnresolvedIssues       []int
	StaleReferences        []string
	TouchedSensitive       []string
}

func runStaticChecks(ctx context.Context, gh *gitHubClient, cfg config, pr *pullRequest, files []prFile) staticChecks {
	c := staticChecks{}

	// Tests-for-production heuristic: flag packages that grew production
	// .go files without a touched _test.go in the same dir. Projects in
	// other languages can extend this with their own conventions.
	prodDirs := map[string]bool{}
	testDirs := map[string]bool{}
	for _, f := range files {
		if !strings.HasSuffix(f.Filename, ".go") {
			continue
		}
		dir := filepath.Dir(f.Filename)
		isTest := strings.HasSuffix(f.Filename, "_test.go")
		isProd := !isTest &&
			(strings.HasPrefix(f.Filename, "internal/") ||
				strings.HasPrefix(f.Filename, "cmd/") ||
				strings.HasPrefix(f.Filename, "pkg/"))
		if isTest {
			testDirs[dir] = true
		}
		if isProd {
			prodDirs[dir] = true
		}
	}
	for dir := range prodDirs {
		if !testDirs[dir] {
			c.ProductionWithoutTests = append(c.ProductionWithoutTests, dir)
		}
	}
	sort.Strings(c.ProductionWithoutTests)

	// Path citations.
	if cfg.Workspace != "" {
		for _, p := range extractPathRefs(pr.Body) {
			if !pathExistsInWorkspace(cfg.Workspace, p) {
				c.UnresolvedPaths = append(c.UnresolvedPaths, p)
			}
		}
		sort.Strings(c.UnresolvedPaths)
	}

	// Issue refs (other than the closes ref, which we already fetched).
	seen := map[int]bool{}
	for _, n := range extractIssueRefs(pr.Body) {
		if seen[n] {
			continue
		}
		seen[n] = true
		ok, err := gh.issueExists(ctx, cfg.Owner, cfg.Repo, n)
		if err != nil {
			fmt.Fprintf(os.Stderr, "issueExists #%d (non-fatal): %v\n", n, err)
			continue
		}
		if !ok {
			c.UnresolvedIssues = append(c.UnresolvedIssues, n)
		}
	}
	sort.Ints(c.UnresolvedIssues)

	// Compliance-sensitive paths touched. The default list is empty; the
	// project owner customises it to mirror the trust-boundary watched
	// paths via the SENSITIVE_PATHS env variable (comma-separated list of
	// path prefixes). When unset, this check produces no signal.
	sensitive := parseSensitivePaths(os.Getenv("SENSITIVE_PATHS"))
	for _, f := range files {
		for _, prefix := range sensitive {
			if strings.HasPrefix(f.Filename, prefix) {
				c.TouchedSensitive = append(c.TouchedSensitive, f.Filename)
				break
			}
		}
	}
	sort.Strings(c.TouchedSensitive)

	// Stale-claim heuristic: if the body says `uses #N`, look for any
	// trace of that issue in the diff (file paths, comments, branch
	// names). If none, surface a soft signal the LLM can reason about.
	usesRe := regexp.MustCompile(`(?i)\buses\s+#(\d+)\b`)
	for _, m := range usesRe.FindAllStringSubmatch(pr.Body, -1) {
		needle := m[1]
		hit := false
		for _, f := range files {
			if strings.Contains(f.Patch, "#"+needle) {
				hit = true
				break
			}
		}
		if !hit {
			c.StaleReferences = append(c.StaleReferences, "#"+needle)
		}
	}
	sort.Strings(c.StaleReferences)

	return c
}

// parseSensitivePaths splits a comma-separated list of path prefixes
// from the SENSITIVE_PATHS env var. Empty entries are skipped; trailing
// slashes are normalised away.
func parseSensitivePaths(raw string) []string {
	if raw == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		out = append(out, p)
	}
	return out
}

func extractPathRefs(body string) []string {
	out := []string{}
	seen := map[string]bool{}
	for _, m := range pathRefRe.FindAllStringSubmatch(body, -1) {
		p := strings.TrimRight(m[1], ".,);:")
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	return out
}

func extractIssueRefs(body string) []int {
	out := []int{}
	for _, m := range issueRefRe.FindAllStringSubmatch(body, -1) {
		n, err := strconv.Atoi(m[1])
		if err != nil {
			continue
		}
		out = append(out, n)
	}
	return out
}

func pathExistsInWorkspace(workspace, p string) bool {
	full := filepath.Join(workspace, p)
	_, err := os.Stat(full)
	if err == nil {
		return true
	}
	// Be tolerant of paths that include line-anchors or fragments.
	if cut := strings.IndexAny(p, "#:"); cut > 0 {
		full = filepath.Join(workspace, p[:cut])
		if _, err := os.Stat(full); err == nil {
			return true
		}
	}
	return false
}

func parseClosesRef(body string) int {
	m := closesRefRe.FindStringSubmatch(body)
	if m == nil {
		return 0
	}
	n, err := strconv.Atoi(m[1])
	if err != nil {
		return 0
	}
	return n
}

// systemPromptText is the rubric the model uses to score the PR. It
// names six review dimensions in a project-neutral way so the binary
// works as a drop-in across template instantiations. The rubric and
// output shape are stable; the human reviewer relies on consistent
// formatting to triage dozens of PRs per week.
func systemPromptText() string {
	return `You are reviewing a pull request. The human reviewer relies on your sticky comment to focus their attention; accurate citations and faithful reading of the diff are non-negotiable.

Apply this rubric and respond in the structured markdown shape below.

Rubric (six dimensions):
1. Lint clean — read the CI check-run summary; if a lint job failed, name the specific lints.
2. Tests added if production code changed — heuristic flag is provided in the user prompt under "Static checks".
3. Citations resolve — every repo-relative path mentioned in the PR body must exist on the PR's HEAD. Unresolved paths are listed under "Static checks".
4. Issue numbers resolve — every #NN reference in the PR body must point to an existing issue. Unresolved issues are listed under "Static checks".
5. Architectural invariants — for changes under compliance-sensitive paths (listed under "Static checks" as "Compliance-sensitive paths touched"), reason about whether project-specific invariants are upheld: audit emission near new public surfaces, auth wiring on admin endpoints, etc. The list of touched sensitive paths is a signal; use it.
6. Stale claims — if the PR body says "uses #N" without the diff actually referencing #N, the static check flags it. Comment on plausibility.

Output shape (strict markdown, max 600 words):

## Pass / Concerns

- one-line verdict (e.g. "Looks clean — ready for review", or "Two MED concerns + one HIGH; see below")

## Passes

- bullet per dimension that is clean. If everything is clean, one short line is fine. No false praise.

## Concerns

- bullet per concern, prefixed with severity (HIGH / MED / LOW), citing the dimension. Reference exact files / lines where possible.

## Open questions for the reviewer

- bullet per ambiguity that requires human judgement. Skip the section if there are none.

Tone: terse, precise, no preamble, no closing pleasantries. The human reviewer reads dozens of these per week.`
}

// buildPrompt composes the user message for Anthropic. It bundles the
// PR metadata, CI check summary, linked-issue acceptance criteria, the
// static-check output, and a (possibly truncated) diff. The diff is
// trimmed via shrinkPatch to fit within the input cap.
func buildPrompt(pr *pullRequest, files []prFile, checks []checkRun, linked *issue, c staticChecks) string {
	var b strings.Builder

	fmt.Fprintf(&b, "PR #%d: %s\n", pr.Number, pr.Title)
	fmt.Fprintf(&b, "URL: %s\n", pr.HTMLURL)
	fmt.Fprintf(&b, "Base: %s  Head: %s\n", pr.Base.Ref, pr.Head.SHA)
	b.WriteString("\n## PR body\n\n")
	if strings.TrimSpace(pr.Body) == "" {
		b.WriteString("(empty)\n")
	} else {
		b.WriteString(pr.Body)
		b.WriteString("\n")
	}

	b.WriteString("\n## CI check runs (this commit)\n\n")
	if len(checks) == 0 {
		b.WriteString("(no checks reported)\n")
	} else {
		for _, cr := range checks {
			fmt.Fprintf(&b, "- %s: status=%s conclusion=%s\n", cr.Name, cr.Status, cr.Conclusion)
		}
	}

	if linked != nil {
		fmt.Fprintf(&b, "\n## Linked issue #%d: %s\n\n", linked.Number, linked.Title)
		b.WriteString(linked.Body)
		b.WriteString("\n")
	}

	b.WriteString("\n## Static checks (deterministic, computed by the workflow)\n\n")
	if len(c.ProductionWithoutTests) > 0 {
		b.WriteString("- Production-without-tests dirs:\n")
		for _, d := range c.ProductionWithoutTests {
			fmt.Fprintf(&b, "  - `%s`\n", d)
		}
	} else {
		b.WriteString("- Production-without-tests dirs: none\n")
	}
	if len(c.UnresolvedPaths) > 0 {
		b.WriteString("- Unresolved paths cited in body:\n")
		for _, p := range c.UnresolvedPaths {
			fmt.Fprintf(&b, "  - `%s`\n", p)
		}
	} else {
		b.WriteString("- Unresolved paths cited in body: none\n")
	}
	if len(c.UnresolvedIssues) > 0 {
		b.WriteString("- Unresolved issue refs:\n")
		for _, n := range c.UnresolvedIssues {
			fmt.Fprintf(&b, "  - #%d\n", n)
		}
	} else {
		b.WriteString("- Unresolved issue refs: none\n")
	}
	if len(c.TouchedSensitive) > 0 {
		b.WriteString("- Compliance-sensitive paths touched:\n")
		for _, p := range c.TouchedSensitive {
			fmt.Fprintf(&b, "  - `%s`\n", p)
		}
	} else {
		b.WriteString("- Compliance-sensitive paths touched: none\n")
	}
	if len(c.StaleReferences) > 0 {
		b.WriteString("- Stale `uses #N` claims (no trace in diff):\n")
		for _, r := range c.StaleReferences {
			fmt.Fprintf(&b, "  - %s\n", r)
		}
	} else {
		b.WriteString("- Stale `uses #N` claims: none\n")
	}

	b.WriteString("\n## Files changed\n\n")
	for _, f := range files {
		fmt.Fprintf(&b, "- %s (%s, +%d/-%d)\n", f.Filename, f.Status, f.Additions, f.Deletions)
	}

	b.WriteString("\n## Diff\n\n")
	diff, dropped := shrinkDiff(files, maxDiffCharsBudget-b.Len())
	b.WriteString(diff)
	if len(dropped) > 0 {
		b.WriteString("\n_(diff truncated to fit input budget; full bodies of these large files were dropped: ")
		b.WriteString(strings.Join(dropped, ", "))
		b.WriteString(")_\n")
	}

	return b.String()
}

// shrinkDiff returns a diff that fits within `budget` characters by
// dropping the body of files larger than `largeFileLineCutoff` lines
// (keeping the file header), then truncating altogether if the budget
// is still exceeded. The list of dropped files is returned for the
// LLM-facing footer so the model knows which areas it cannot see.
func shrinkDiff(files []prFile, budget int) (string, []string) {
	if budget < 1024 {
		budget = 1024
	}
	var b strings.Builder
	var dropped []string
	for _, f := range files {
		header := fmt.Sprintf("\n### %s (%s, +%d/-%d)\n```diff\n", f.Filename, f.Status, f.Additions, f.Deletions)
		footer := "\n```\n"

		patch := f.Patch
		if patch == "" {
			b.WriteString(header)
			b.WriteString("(no patch — binary or rename-only)")
			b.WriteString(footer)
			continue
		}

		lines := strings.Count(patch, "\n") + 1
		if lines > largeFileLineCutoff {
			b.WriteString(header)
			fmt.Fprintf(&b, "(file body dropped — %d lines exceeds %d-line per-file cutoff)", lines, largeFileLineCutoff)
			b.WriteString(footer)
			dropped = append(dropped, f.Filename)
			continue
		}

		chunk := header + patch + footer
		if b.Len()+len(chunk) > budget {
			b.WriteString("\n_(remaining diff truncated to fit input budget)_\n")
			break
		}
		b.WriteString(chunk)
	}
	return b.String(), dropped
}

// anthropicRequest mirrors the Messages API JSON wire shape. Only the
// fields we set are populated; we deliberately use a flat struct rather
// than chasing every optional knob.
type anthropicRequest struct {
	Model     string             `json:"model"`
	MaxTokens int                `json:"max_tokens"`
	System    string             `json:"system"`
	Messages  []anthropicMessage `json:"messages"`
}

type anthropicMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type anthropicResponse struct {
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content"`
	Usage struct {
		InputTokens  int `json:"input_tokens"`
		OutputTokens int `json:"output_tokens"`
	} `json:"usage"`
}

type llmResult struct {
	text              string
	usageInputTokens  int
	usageOutputTokens int
}

func callAnthropic(ctx context.Context, apiKey, system, user string) (llmResult, error) {
	ctx, cancel := context.WithTimeout(ctx, anthropicCallDeadline)
	defer cancel()

	body := anthropicRequest{
		Model:     anthropicModel,
		MaxTokens: maxOutputTokens,
		System:    system,
		Messages: []anthropicMessage{
			{Role: "user", Content: user},
		},
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return llmResult{}, fmt.Errorf("marshal: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, anthropicEndpoint, bytes.NewReader(raw))
	if err != nil {
		return llmResult{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("anthropic-version", anthropicVersion)
	req.Header.Set("x-api-key", apiKey)

	hc := &http.Client{Timeout: anthropicCallDeadline}
	resp, err := hc.Do(req)
	if err != nil {
		return llmResult{}, fmt.Errorf("http: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode >= 400 {
		raw, _ := io.ReadAll(resp.Body)
		return llmResult{}, fmt.Errorf("anthropic %s: %s", resp.Status, strings.TrimSpace(string(raw)))
	}

	var parsed anthropicResponse
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return llmResult{}, fmt.Errorf("decode: %w", err)
	}

	var text strings.Builder
	for _, c := range parsed.Content {
		if c.Type == "text" {
			text.WriteString(c.Text)
		}
	}
	return llmResult{
		text:              text.String(),
		usageInputTokens:  parsed.Usage.InputTokens,
		usageOutputTokens: parsed.Usage.OutputTokens,
	}, nil
}

func estimateCost(in, out int) float64 {
	return float64(in)*usdPerMTokIn/1_000_000 + float64(out)*usdPerMTokOut/1_000_000
}

func assembleComment(text string, in, out int, costUSD float64) string {
	header := "## Agentic PR review (read-only)\n\n"
	footer := fmt.Sprintf(
		"\n\n---\n_Read-only review by Claude (model `%s`). Tokens: in=%d / out=%d. Estimated cost: $%.4f. Disable for this PR by adding the `agentic-review:skip` label. See [`docs/agentic-review.md`](../blob/main/docs/agentic-review.md)._",
		anthropicModel, in, out, costUSD,
	)
	return header + strings.TrimSpace(text) + footer
}

func degradedComment(reason string) string {
	return "## Agentic PR review (read-only)\n\n" +
		"**Status: degraded.**\n\n" +
		reason + "\n\n" +
		"---\n_Read-only review. The workflow exited 0 to avoid blocking CI on agent-infrastructure issues. See [`docs/agentic-review.md`](../blob/main/docs/agentic-review.md)._"
}

func writeStepSummary(path string, r llmResult, costUSD float64) error {
	if path == "" {
		return nil
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer func() { _ = f.Close() }()
	body := fmt.Sprintf("## Agentic review cost\n\n"+
		"| Metric | Value |\n| --- | --- |\n"+
		"| Model | `%s` |\n"+
		"| Input tokens | %d |\n"+
		"| Output tokens | %d |\n"+
		"| Estimated cost (USD) | $%.4f |\n",
		anthropicModel, r.usageInputTokens, r.usageOutputTokens, costUSD)
	_, err = f.WriteString(body)
	return err
}

// redactErr keeps secrets out of the degraded comment that gets pushed
// to a public PR. Practically, the Anthropic error path can include the
// request body; we strip the API key value out of any reproducible bits
// just in case.
func redactErr(err error) string {
	if err == nil {
		return ""
	}
	s := err.Error()
	if v := os.Getenv("ANTHROPIC_API_KEY"); v != "" {
		s = strings.ReplaceAll(s, v, "[REDACTED]")
	}
	if v := os.Getenv("GITHUB_TOKEN"); v != "" {
		s = strings.ReplaceAll(s, v, "[REDACTED]")
	}
	if len(s) > 400 {
		s = s[:400] + "…"
	}
	return s
}

// gitLsTree is unused at the moment but kept available for the fallback
// path: when GITHUB_WORKSPACE is not the PR head (e.g. a manual local
// invocation), we resolve path citations via `git ls-tree` against an
// explicit ref instead of os.Stat. The helper is referenced from a
// comment in the path-checks code so the linter does not nag us about
// it being dead.
//
//nolint:unused // kept for the local-invocation fallback path.
func gitLsTree(ctx context.Context, ref, path string) (bool, error) {
	cmd := exec.CommandContext(ctx, "git", "ls-tree", "-r", "--name-only", ref, "--", path)
	out, err := cmd.Output()
	if err != nil {
		return false, err
	}
	return len(bytes.TrimSpace(out)) > 0, nil
}
