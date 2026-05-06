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
	"strings"
)

// GitHub Models is GitHub's hosted, OpenAI-compatible inference
// endpoint. It accepts a `Bearer ${{ secrets.GITHUB_TOKEN }}` when the
// workflow declares `permissions: { models: read }` and exposes a
// catalogue of models — including Anthropic Claude variants — at a
// single chat-completions URL.
//
// Endpoint reference:
//
//   POST https://models.github.ai/inference/chat/completions
//
// Wire format is OpenAI-compatible: a {model, messages, max_tokens,
// temperature} request and a {choices: [{message: {content}}]} response.
//
// Default model is anthropic/claude-sonnet-4.5 — the most-recent Claude
// snapshot generally available in the GitHub Models catalogue at the
// time this template was instantiated. Override at runtime via the
// AGENTIC_REVIEW_GITHUB_MODELS_MODEL env var without rebuilding the
// binary, e.g. when GitHub bumps the canonical Sonnet identifier.
const (
	githubModelsEndpoint     = "https://models.github.ai/inference/chat/completions"
	githubModelsDefaultModel = "anthropic/claude-sonnet-4.5"
	githubModelsModelEnv     = "AGENTIC_REVIEW_GITHUB_MODELS_MODEL"
	githubModelsEndpointEnv  = "AGENTIC_REVIEW_GITHUB_MODELS_ENDPOINT"
)

// githubModelsModel returns the model identifier to use for the
// GitHub Models backend, honouring the env-var override. Used by both
// the request builder and the comment / step-summary helpers so the
// surfaced label always matches what hit the wire.
func githubModelsModel() string {
	if v := strings.TrimSpace(os.Getenv(githubModelsModelEnv)); v != "" {
		return v
	}
	return githubModelsDefaultModel
}

// githubModelsBackend calls the OpenAI-compatible chat completions
// endpoint hosted by GitHub Models. Auth is the workflow's
// GITHUB_TOKEN with `permissions: { models: read }`; no separate
// secret is required.
type githubModelsBackend struct {
	token    string
	endpoint string // overridable for tests
	model    string // overridable for tests
	hc       *http.Client
}

func newGitHubModelsBackend(token string) *githubModelsBackend {
	endpoint := githubModelsEndpoint
	if v := strings.TrimSpace(os.Getenv(githubModelsEndpointEnv)); v != "" {
		endpoint = v
	}
	return &githubModelsBackend{
		token:    token,
		endpoint: endpoint,
		model:    githubModelsModel(),
		hc:       &http.Client{Timeout: llmCallDeadline},
	}
}

type githubModelsMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// githubModelsRequest mirrors the OpenAI chat-completions wire shape
// the GitHub Models endpoint accepts. Only fields we set are
// populated; the endpoint accepts the broader OpenAI request schema
// but we deliberately constrain ourselves to a stable subset.
type githubModelsRequest struct {
	Model       string                `json:"model"`
	Messages    []githubModelsMessage `json:"messages"`
	MaxTokens   int                   `json:"max_tokens"`
	Temperature float64               `json:"temperature"`
}

type githubModelsResponse struct {
	Choices []struct {
		Message struct {
			Content string `json:"content"`
		} `json:"message"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
	Usage struct {
		PromptTokens     int `json:"prompt_tokens"`
		CompletionTokens int `json:"completion_tokens"`
		TotalTokens      int `json:"total_tokens"`
	} `json:"usage"`
	// Error mirrors the OpenAI-compatible error envelope GitHub Models
	// returns on auth / rate-limit failures (e.g. {"error":{"code":"...",
	// "message":"..."}}). We surface the message in the operator-facing
	// degraded comment so they can act on it without digging into logs.
	Error *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
		Type    string `json:"type"`
	} `json:"error,omitempty"`
}

func (b *githubModelsBackend) Review(ctx context.Context, system, user string) (llmResult, error) {
	ctx, cancel := context.WithTimeout(ctx, llmCallDeadline)
	defer cancel()

	if b.token == "" {
		return llmResult{}, errors.New("GITHUB_TOKEN is empty")
	}

	body := githubModelsRequest{
		Model: b.model,
		Messages: []githubModelsMessage{
			{Role: "system", Content: system},
			{Role: "user", Content: user},
		},
		MaxTokens:   maxOutputTokens,
		Temperature: 0.2,
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return llmResult{}, fmt.Errorf("marshal: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, b.endpoint, bytes.NewReader(raw))
	if err != nil {
		return llmResult{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Authorization", "Bearer "+b.token)

	resp, err := b.hc.Do(req)
	if err != nil {
		return llmResult{}, fmt.Errorf("http: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		raw, _ := io.ReadAll(resp.Body)
		return llmResult{}, fmt.Errorf("github models auth required (HTTP %d): %s. Ensure the workflow declares `permissions: { models: read }` and is running with the workflow GITHUB_TOKEN", resp.StatusCode, snippet(raw))
	}
	if resp.StatusCode == http.StatusTooManyRequests {
		raw, _ := io.ReadAll(resp.Body)
		return llmResult{}, fmt.Errorf("github models rate-limited (HTTP 429): %s. Wait for the rate-limit window to reset, or switch backends to anthropic", snippet(raw))
	}
	if resp.StatusCode >= 400 {
		raw, _ := io.ReadAll(resp.Body)
		return llmResult{}, fmt.Errorf("github models %s: %s", resp.Status, snippet(raw))
	}

	var parsed githubModelsResponse
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return llmResult{}, fmt.Errorf("decode: %w", err)
	}
	if parsed.Error != nil {
		return llmResult{}, fmt.Errorf("github models error %q: %s", parsed.Error.Code, parsed.Error.Message)
	}
	if len(parsed.Choices) == 0 {
		return llmResult{}, errors.New("github models returned no choices")
	}

	return llmResult{
		text:              strings.TrimSpace(parsed.Choices[0].Message.Content),
		usageInputTokens:  parsed.Usage.PromptTokens,
		usageOutputTokens: parsed.Usage.CompletionTokens,
	}, nil
}

// snippet trims a wire-error body to a length appropriate for the
// degraded-comment surface. The body is not redacted of secrets here
// because the GitHub Models endpoint never echoes the bearer token —
// only the operator-supplied messages, which the workflow already
// authored.
func snippet(raw []byte) string {
	s := strings.TrimSpace(string(raw))
	if len(s) > 240 {
		s = s[:240] + "…"
	}
	return s
}
