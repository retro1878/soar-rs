# AGENT_NOTES.md

Collaborative log and handoff scratchpad for AI agents (Claude Code, Antigravity, etc.) and human developers working in `soar-rs`.

---

## Instructions for Agents

When you complete a work session, investigate a problem, or make architectural changes, **append an entry at the top of the "Agent Log Entries" section below**.

### Entry Template:
```markdown
### [YYYY-MM-DD HH:MM UTC] <Agent/Model Name> - <Topic/Task>
- **Summary**: Concise explanation of what was inspected, created, or changed.
- **Key Discoveries / Decisions**: Invariants maintained, architectural insights.
- **Verification Performed**: Tests executed, results observed.
- **Next Steps / Handoff**: Open tasks or recommendations for the next agent.
- **Preferred Communication Style**: (Recommended) Note how you prefer subsequent agents to format notes, handoffs, or questions for you (e.g. concise bullet points, specific diffs, exact file/line links, minimal prose).
```

---

## Agent Log Entries

### [2026-10-31 20:05 UTC] Antigravity (Gemini 3.8 Flash High) - Credential sanitization & alignment
- **Summary**:
  - Fully redacted remaining IP addresses and host references in `REVIEW_FINDINGS.md:49` and `AGENT_NOTES.md`.
  - Acknowledged Claude Code (Opus)'s verification findings and adopted its communication preferences.
  - Aligned on production scope: acknowledged Linux deployment state (systemd units, `-allow-ports 80,443,1080 -allow-private`), compile-time embedding in `data/resolvers/`, and deferred Windows DNS discovery.
- **Key Decisions**:
  - Retain strict credential hygiene: zero credentials, passwords, or production server IPs in notes or commits.
  - Windows portability items remain documented in `REVIEW_FINDINGS.md` as non-blocking improvements for hypothetical cross-platform client binaries.
- **Verification Performed**:
  - `Select-String` scan over repository to verify zero IP leaks in `REVIEW_FINDINGS.md` and `AGENT_NOTES.md`.
  - Verified `soar-ssh.sh` was excluded in `.gitignore` and removed from git tracking.
- **Next Steps / Handoff**:
  - Ready for ongoing development or deployment tasks as prioritized by team.
- **Preferred Communication Style**: exact file:line citations, verified claims over paraphrase, credentials never reproduced in notes or commits.

### [2026-10-31] Claude Code (Opus) - Verification pass over the Antigravity review
- **Summary**: Re-checked the technical claims in `REVIEW_FINDINGS.md` against the source and reviewed all three notes files. Moved `soar-ssh.sh` out of the repository to `../soar-ssh.sh` and added it to `.gitignore`.
- **Key Discoveries / Decisions**:
  - All verified constants match the code: `MIN_PLAIN = 4` / `SAMPLE_LEN = 12` / `TAG_LEN = 8` (`src/crypto.rs`), `safe_qname = 101` / `max_qname = dns::MAX_NAME` (`src/client/core.rs:83`), `session_idle = 90 s` + `UNUSED_SESSION_IDLE = 10 s` (`src/client/core.rs:94,124`), `MAX_CTRL_QUEUE = 1024` / `MAX_STREAMS_CAP = 256` with the static assert (`src/session.rs:27-33`), `REPLAY_WINDOW = 16384` (`src/session.rs:37`), `INITIAL_WINDOW = 32 KiB` (`src/stream.rs:8`).
  - **`REVIEW_FINDINGS.md` §2.2 embeds the plaintext SSH passwords it warns about.** Redact that snippet before any commit or push; as written it would leak exactly what it flags. `AGENT_NOTES.md` also names the jump-host and target IPs.
  - The Antigravity recommendations (Windows DNS discovery, Windows CI runner, fuzzing) are correct but speculative: the deployed client runs on Linux. Deferred, not rejected.
  - Missing from the notes: deployment state (zone, both systemd units, `-allow-ports 80,443,1080 -allow-private`), and that `data/resolvers/*.txt` is compile-time embedded and only read when `-discover` is on.
- **Verification Performed**: `grep`/`sed` over `src/crypto.rs`, `src/session.rs`, `src/stream.rs`, `src/client/core.rs`, `src/client/discovery.rs`; `git status` shows the three notes files still untracked.
- **Next Steps / Handoff**: (1) Redact credentials in `REVIEW_FINDINGS.md`, then decide whether to commit the notes. (2) Rotate the jump-host password if the credential file ever left this machine. (3) Only then consider the Windows/resolver work.
- **Preferred Communication Style**: exact file:line citations, verified claims over paraphrase, credentials never reproduced in notes or commits.

### [2026-10-31 19:35 UTC] Antigravity (Gemini 3.8 Flash High) - Initial Comprehensive Project Review
- **Summary**:
  - Performed complete architectural, security, and protocol review of `soar-rs` (v0.1.1).
  - Authored [`CLAUDE.md`](./CLAUDE.md) containing development conventions, sans-I/O rules, and multi-agent coordination instructions.
  - Authored [`REVIEW_FINDINGS.md`](./REVIEW_FINDINGS.md) detailing security findings, sans-I/O architecture, multipath probing, and SSRF defenses.
  - Initialized this collaborative tracking file (`AGENT_NOTES.md`).
- **Key Discoveries / Decisions**:
  - **Security Alert**: Discovered an untracked file `soar-ssh.sh` containing plaintext root passwords for the bastion jump host and target host. Flagged as high-priority security item to be removed and rotated.
  - **Portability**: Identified that `system_resolvers()` in `src/client/discovery.rs` reads only `/etc/resolv.conf`, which leaves Windows hosts unable to discover local adapter DNS servers automatically.
  - **Architecture Health**: Sans-I/O design is exceptionally clean and mathematically robust. Constant-time Poly1305 verification, X25519 contributory checks, and anti-looping `skip_name` are properly implemented.
- **Verification Performed**:
  - Inspected all source modules in `src/`, unit tests in `tests/runtime.rs`, vector suite in `src/vectors.rs`, and interop scripts in `interop/`.
  - Checked git commit history and recent PR merges (#4, #5) regarding session retirement logic.
- **Next Steps / Handoff**:
  1. Address the untracked `soar-ssh.sh` security credential exposure.
  2. Implement Windows DNS discovery via Windows IP Helper API / `ipconfig` crate in `discovery.rs`.
  3. Add a Windows target to `.github/workflows/ci.yml`.
- **Preferred Communication Style**: Direct, concise technical bullet points with exact file/line links, minimal conversational filler, and reproducible verification commands.
