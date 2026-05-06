package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestBackendDetection covers the AGENTIC_REVIEW_BACKEND env-var matrix
// and the implicit-fallback logic in selectBackend. The four cases the
// issue calls out (override + token / no-token, defaults) are
// exercised here, plus a few edge cases that surfaced while wiring.
func TestBackendDetection(t *testing.T) {
	cases := []struct {
		name        string
		cfg         config
		wantKind    backendKind
		wantBackend string // "github-models" / "anthropic" / "" (error expected)
		wantErrSubs string // substring expected in returned err.Error()
	}{
		{
			name:        "override-github-models with token: uses github-models",
			cfg:         config{GitHubToken: "ghs_abc", BackendOverride: "github-models"},
			wantKind:    backendGitHubModels,
			wantBackend: "github-models",
		},
		{
			name:        "override-github-models without token: degraded",
			cfg:         config{BackendOverride: "github-models"},
			wantKind:    backendGitHubModels,
			wantErrSubs: "GITHUB_TOKEN is empty",
		},
		{
			name:        "override-anthropic with key: uses anthropic",
			cfg:         config{GitHubToken: "ghs_abc", AnthropicAPIKey: "sk-ant-x", BackendOverride: "anthropic"},
			wantKind:    backendAnthropic,
			wantBackend: "anthropic",
		},
		{
			name:        "override-anthropic without key: degraded",
			cfg:         config{GitHubToken: "ghs_abc", BackendOverride: "anthropic"},
			wantKind:    backendAnthropic,
			wantErrSubs: "ANTHROPIC_API_KEY is empty",
		},
		{
			name:        "default with both tokens: prefer anthropic (operator opted in)",
			cfg:         config{GitHubToken: "ghs_abc", AnthropicAPIKey: "sk-ant-x"},
			wantKind:    backendAnthropic,
			wantBackend: "anthropic",
		},
		{
			name:        "default with only github token: prefer github-models",
			cfg:         config{GitHubToken: "ghs_abc"},
			wantKind:    backendGitHubModels,
			wantBackend: "github-models",
		},
		{
			name:        "default with only anthropic key: anthropic",
			cfg:         config{AnthropicAPIKey: "sk-ant-x"},
			wantKind:    backendAnthropic,
			wantBackend: "anthropic",
		},
		{
			name:        "default with neither: degraded",
			cfg:         config{},
			wantKind:    backendAnthropic,
			wantErrSubs: "neither GITHUB_TOKEN nor ANTHROPIC_API_KEY",
		},
		{
			name:        "unknown override: degraded",
			cfg:         config{GitHubToken: "ghs_abc", BackendOverride: "claude-direct"},
			wantErrSubs: "unknown AGENTIC_REVIEW_BACKEND",
		},
		{
			name:        "case-insensitive override: GitHub-Models accepted",
			cfg:         config{GitHubToken: "ghs_abc", BackendOverride: "GitHub-Models"},
			wantKind:    backendGitHubModels,
			wantBackend: "github-models",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			b, kind, err := selectBackend(tc.cfg)
			if tc.wantErrSubs != "" {
				if err == nil {
					t.Fatalf("expected error containing %q, got nil", tc.wantErrSubs)
				}
				if !strings.Contains(err.Error(), tc.wantErrSubs) {
					t.Fatalf("err = %q, want substring %q", err.Error(), tc.wantErrSubs)
				}
				return
			}
			if err != nil {
				t.Fatalf("selectBackend returned unexpected err: %v", err)
			}
			if kind != tc.wantKind {
				t.Errorf("kind = %q, want %q", kind, tc.wantKind)
			}
			switch tc.wantBackend {
			case "github-models":
				if _, ok := b.(*githubModelsBackend); !ok {
					t.Errorf("expected *githubModelsBackend, got %T", b)
				}
			case "anthropic":
				if _, ok := b.(*anthropicBackend); !ok {
					t.Errorf("expected *anthropicBackend, got %T", b)
				}
			}
		})
	}
}

// TestGitHubModelsAdapter_HappyPath drives the adapter against an
// httptest.Server returning a canned OpenAI-compatible chat-completions
// response. We assert (a) the adapter parses content + usage, (b) the
// request body carries the system + user messages in OpenAI shape, and
// (c) the bearer token reaches the request header.
func TestGitHubModelsAdapter_HappyPath(t *testing.T) {
	const cannedResponse = `{
		"choices": [
			{
				"message": {"role": "assistant", "content": "  Looks clean — ready for review.  "},
				"finish_reason": "stop"
			}
		],
		"usage": {"prompt_tokens": 1234, "completion_tokens": 56, "total_tokens": 1290}
	}`

	var gotPath, gotAuth, gotContentType string
	var gotBody githubModelsRequest

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		gotContentType = r.Header.Get("Content-Type")
		if err := decodeJSON(r, &gotBody); err != nil {
			t.Fatalf("decode request: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(cannedResponse))
	}))
	t.Cleanup(srv.Close)

	b := newGitHubModelsBackend("ghs_test_token_value")
	b.endpoint = srv.URL + "/inference/chat/completions"
	b.model = "anthropic/claude-sonnet-4.5"

	res, err := b.Review(context.Background(), "system rubric", "the user prompt")
	if err != nil {
		t.Fatalf("Review: %v", err)
	}
	if res.text != "Looks clean — ready for review." {
		t.Errorf("text = %q, want trimmed canned content", res.text)
	}
	if res.usageInputTokens != 1234 || res.usageOutputTokens != 56 {
		t.Errorf("usage = (%d, %d), want (1234, 56)", res.usageInputTokens, res.usageOutputTokens)
	}
	if gotPath != "/inference/chat/completions" {
		t.Errorf("path = %q, want /inference/chat/completions", gotPath)
	}
	if gotAuth != "Bearer ghs_test_token_value" {
		t.Errorf("Authorization = %q, want Bearer ghs_test_token_value", gotAuth)
	}
	if gotContentType != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", gotContentType)
	}
	if gotBody.Model != "anthropic/claude-sonnet-4.5" {
		t.Errorf("body.model = %q, want anthropic/claude-sonnet-4.5", gotBody.Model)
	}
	if gotBody.MaxTokens != maxOutputTokens {
		t.Errorf("body.max_tokens = %d, want %d", gotBody.MaxTokens, maxOutputTokens)
	}
	if len(gotBody.Messages) != 2 {
		t.Fatalf("body.messages = %d, want 2 (system + user)", len(gotBody.Messages))
	}
	if gotBody.Messages[0].Role != "system" || gotBody.Messages[0].Content != "system rubric" {
		t.Errorf("body.messages[0] = %+v, want system / system rubric", gotBody.Messages[0])
	}
	if gotBody.Messages[1].Role != "user" || gotBody.Messages[1].Content != "the user prompt" {
		t.Errorf("body.messages[1] = %+v, want user / the user prompt", gotBody.Messages[1])
	}
}

// TestGitHubModelsAdapter_RateLimited asserts the adapter surfaces the
// standard 429 with a clear, actionable error message that the
// degraded-comment helper can echo to the operator.
func TestGitHubModelsAdapter_RateLimited(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"error":{"code":"rate_limit_exceeded","message":"too many requests, retry later"}}`))
	}))
	t.Cleanup(srv.Close)

	b := newGitHubModelsBackend("ghs_test")
	b.endpoint = srv.URL + "/inference/chat/completions"

	_, err := b.Review(context.Background(), "sys", "user")
	if err == nil {
		t.Fatalf("expected error, got nil")
	}
	for _, want := range []string{"rate-limited", "429"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("err = %q, want substring %q", err.Error(), want)
		}
	}
}

// TestGitHubModelsAdapter_AuthRequired asserts that an HTTP 401 / 403
// produces an error message naming the `permissions: { models: read }`
// requirement so the operator can fix the workflow without digging.
func TestGitHubModelsAdapter_AuthRequired(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"code":"unauthorized","message":"bearer token rejected"}}`))
	}))
	t.Cleanup(srv.Close)

	b := newGitHubModelsBackend("ghs_test")
	b.endpoint = srv.URL + "/inference/chat/completions"

	_, err := b.Review(context.Background(), "sys", "user")
	if err == nil {
		t.Fatalf("expected error, got nil")
	}
	for _, want := range []string{"auth required", "permissions:", "models: read", "401"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("err = %q, want substring %q", err.Error(), want)
		}
	}
}

// TestGitHubModelsAdapter_NoChoices asserts a malformed-but-valid-JSON
// response with no choices is reported as such (rather than silently
// returning an empty review).
func TestGitHubModelsAdapter_NoChoices(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices": [], "usage": {"prompt_tokens": 1, "completion_tokens": 0}}`))
	}))
	t.Cleanup(srv.Close)

	b := newGitHubModelsBackend("ghs_test")
	b.endpoint = srv.URL + "/inference/chat/completions"

	_, err := b.Review(context.Background(), "sys", "user")
	if err == nil || !strings.Contains(err.Error(), "no choices") {
		t.Fatalf("expected no-choices error, got %v", err)
	}
}

// TestGitHubModelsModelEnvOverride asserts the env-var override
// changes both the wire model and the helper that builds the comment
// footer. Belt-and-braces for the "operator bumps the model
// identifier" path.
func TestGitHubModelsModelEnvOverride(t *testing.T) {
	t.Setenv(githubModelsModelEnv, "anthropic/claude-sonnet-4.5-20260101")
	if got := githubModelsModel(); got != "anthropic/claude-sonnet-4.5-20260101" {
		t.Errorf("githubModelsModel() = %q, want override", got)
	}
	if got := backendModelID(backendGitHubModels); got != "anthropic/claude-sonnet-4.5-20260101" {
		t.Errorf("backendModelID(github-models) = %q, want override", got)
	}
}

// decodeJSON inspects the request body shape from the httptest handler.
func decodeJSON(r *http.Request, dst any) error {
	defer func() { _ = r.Body.Close() }()
	return json.NewDecoder(r.Body).Decode(dst)
}
