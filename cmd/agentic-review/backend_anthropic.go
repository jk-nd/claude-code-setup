package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

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

// Approximate Anthropic Opus pricing in USD per 1M tokens. Used to
// estimate review cost; the operator-facing doc warns that this is an
// estimate and the authoritative number lives at anthropic.com/pricing.
const (
	anthropicUSDPerMTokIn  = 15.0
	anthropicUSDPerMTokOut = 75.0
)

// anthropicBackend calls the Anthropic Messages API directly with an
// API key the operator owns. This is the historical default; GitHub
// Models is preferred for personal-account use because it auths via
// GITHUB_TOKEN with no separate billing relationship.
type anthropicBackend struct {
	apiKey   string
	endpoint string // overridable for tests
	hc       *http.Client
}

func newAnthropicBackend(apiKey string) *anthropicBackend {
	return &anthropicBackend{
		apiKey:   apiKey,
		endpoint: anthropicEndpoint,
		hc:       &http.Client{Timeout: llmCallDeadline},
	}
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

func (b *anthropicBackend) Review(ctx context.Context, system, user string) (llmResult, error) {
	ctx, cancel := context.WithTimeout(ctx, llmCallDeadline)
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

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, b.endpoint, bytes.NewReader(raw))
	if err != nil {
		return llmResult{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("anthropic-version", anthropicVersion)
	req.Header.Set("x-api-key", b.apiKey)

	resp, err := b.hc.Do(req)
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
