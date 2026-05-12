#!/usr/bin/env python3
"""Get a second opinion on a plan or spec from a model other than the planner.

Usage:
    second-opinion.py [--provider gemini|opus] [--model NAME] PATH

The critique is written to stdout. The input file is not modified. The caller
(typically the `plan-reviewer` subagent) appends the output to the plan as a
"## Second opinion: <provider>" section.

Providers:
    gemini  Google AI Studio (free tier). Needs GOOGLE_AI_STUDIO_API_KEY.
            Default model: gemini-2.5-pro.
    opus    Shells out to `claude --print --model NAME`. Uses your local
            Claude Code CLI session (Max/Ultra subscription via OAuth).
            Default model: claude-opus-4-7.
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.request


PROMPT = """You are a critical reviewer of a software engineering plan or spec.
The document below is intended to be executed by an autonomous agent team.
Read it carefully and identify, in order:

1. Hidden assumptions the author did not surface.
2. Underspecified risks (security, performance, data integrity, ops,
   compatibility, concurrency, observability).
3. Sequencing or dependency issues in the task order.
4. Testability gaps — what would be hard to verify or impossible to falsify.
5. Anything you would push back on, including scope creep, premature
   optimisation, unstated coupling, or "we will figure it out later" hand-waves.

Cite the section or task you are commenting on (e.g., "Task T3",
"Approach summary"). Skip generic advice. If the plan is fine on a dimension,
say so in one line and move on. Be terse, specific, and adversarial. The goal
is to find what is wrong, not to be polite.

DOCUMENT:
---
{doc}
---
"""

DEFAULT_MODELS = {
    "gemini": "gemini-2.5-pro",
    "opus":   "claude-opus-4-7",
}


def critique_gemini(prompt: str, model: str) -> str:
    key = os.environ.get("GOOGLE_AI_STUDIO_API_KEY")
    if not key:
        sys.exit("error: GOOGLE_AI_STUDIO_API_KEY is not set in the environment")
    url = (
        f"https://generativelanguage.googleapis.com/v1beta/models/"
        f"{model}:generateContent?key={key}"
    )
    body = json.dumps({"contents": [{"parts": [{"text": prompt}]}]}).encode()
    req = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            payload = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        sys.exit(f"error: gemini HTTP {e.code}: {e.read().decode(errors='replace')}")
    return payload["candidates"][0]["content"]["parts"][0]["text"]


def critique_opus(prompt: str, model: str) -> str:
    try:
        proc = subprocess.run(
            ["claude", "--print", "--model", model],
            input=prompt, capture_output=True, text=True, timeout=300,
        )
    except FileNotFoundError:
        sys.exit("error: `claude` CLI not found on PATH; install Claude Code first")
    if proc.returncode != 0:
        sys.exit(
            f"error: claude --print exited {proc.returncode}: {proc.stderr.strip()}"
        )
    return proc.stdout


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Get a second opinion on a plan/spec from a different model."
    )
    parser.add_argument(
        "--provider",
        choices=("gemini", "opus"),
        default="gemini",
        help="Which model family asks for the critique. Default: gemini.",
    )
    parser.add_argument(
        "--model",
        help="Override the default model name for the chosen provider.",
    )
    parser.add_argument("path", help="Path to the plan / spec document.")
    args = parser.parse_args()

    try:
        with open(args.path, "r") as f:
            doc = f.read()
    except FileNotFoundError:
        sys.exit(f"error: file not found: {args.path}")

    model = args.model or DEFAULT_MODELS[args.provider]
    prompt = PROMPT.format(doc=doc)
    fn = {"gemini": critique_gemini, "opus": critique_opus}[args.provider]
    print(fn(prompt, model))


if __name__ == "__main__":
    main()
