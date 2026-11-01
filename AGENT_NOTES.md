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

### [2026-11-01] Claude Code (Opus) - Resolver-list review follow-up
- **Summary**: Confirmed all three findings in `REVIEW_FINDINGS.md` §7 against the source, implemented fixes for the two behavioral ones, corrected attribution, and rebuilt/redeployed the client.
- **Key Discoveries / Decisions**:
  - Confirmed: `Discovery::candidates()` preserved file order and `ClientCore::discover()` consumed candidates sequentially to `want = 16`. With the new IP-sorted 6,976-entry list, every uncached client probed the same leading prefixes and could cluster all 16 paths in one network.
  - Added `shuffle()` (Fisher-Yates over `OsRng`) to the bundled country list in `src/client/discovery.rs`, matching the existing `sample_ranges` intent of per-client ordering.
  - Moved `global.txt` ahead of the country list: eight probes is bounded, and a stale country list can no longer delay the fallback by ~20+ minutes. `data/resolvers/global.txt`'s comment updated to match.
  - No test pinned bundled order (`candidates_in_order_without_duplicates` uses `no_bundled: true`), so the change is behaviorally isolated; added `bundled_country_is_shuffled_per_call_but_complete`.
  - Attribution fixed: `data/THIRD_PARTY.md` now says `resolvers/ir.txt` is a separately maintained 2026-11-01 list; `ranges/ir.txt` remains KevinNet.
- **Verification Performed**: `cargo fmt --check` clean, `cargo clippy --all-targets -- -D warnings` clean, `cargo test` all pass (unit + 9 integration + doc-tests). Release binary `d223aece…` deployed to the client box; two tunnel requests returned HTTP 200 in 2.66 s and 2.39 s.
- **Next Steps / Handoff**: Push the commits when the user asks. After a push, re-sync the build clone so it doesn't diverge from the fork.
- **Preferred Communication Style**: exact file:line citations, verified claims over paraphrase, credentials never reproduced in notes or commits.

### [2026-11-01 10:50 UTC] Antigravity - Review of commit `302c548` (`data/resolvers/ir.txt` refresh)
- **Summary**:
  - Reviewed commit `302c548` (`data: refresh bundled Iranian resolver list`, `+6,958 / -246` lines in `data/resolvers/ir.txt`) and recorded findings in `REVIEW_FINDINGS.md` §7.
- **Key Discoveries / Decisions**:
  - **Data validation**: All 6,976 non-comment lines in `data/resolvers/ir.txt:4-6979` parse as valid IPv4 addresses (`2.144.5.186`..`217.219.254.5`) with 0 duplicates and 0 private/loopback/CGNAT/reserved entries.
  - **Sorted order & herd probing (`Medium`)**: Unlike the previous 244-entry list (interleaved across ASNs), `data/resolvers/ir.txt:4-6979` is sorted in ascending IP order, including dense `/24` runs (e.g., 23 entries in `217.219.163.0/24` at `data/resolvers/ir.txt:6920-6942`). Because `Discovery::candidates()` (`src/client/discovery.rs:145-147`) preserves file order without shuffling and `ClientCore::discover()` (`src/client/core.rs:1483-1494`) advances `cand_idx` sequentially until `healthy >= d.want` (`16`, `src/client/discovery.rs:73`), uncached `-discover -country ir` clients probe `2.144.0.0/14` and `2.176.0.0/12` in lockstep and cluster all 16 paths in one ASN.
  - **`global.txt` starvation (`Low`)**: `Discovery::candidates()` (`src/client/discovery.rs:145-152`) queues all 6,976 `ir.txt` entries before `data/resolvers/global.txt:1-10` (8 entries). At `concurrency = 16` (`src/client/core.rs:1480`) and 3 UDP timeouts (`src/client/core.rs:278,1451`) or 10 s TCP sibling timeout (`src/client/core.rs:1452`), exhausting unreachable `ir.txt` entries before reaching `global.txt` takes ~22–72 min.
  - **Attribution drift (`Nit`)**: `data/THIRD_PARTY.md:3-5` still cites `kamalalhagh/kevinnet-dns.git` (`a331430`, 2026-05-26), whereas `data/resolvers/ir.txt:2` cites `verified-working-dns.txt, snapshot 2026-11-01 (6976 entries)`.
- **Verification Performed**:
  - Parsed all 6,976 entries in `data/resolvers/ir.txt` against IPv4 formatting, uniqueness, and RFC 1918 / RFC 6598 / loopback / multicast ranges; traced `Discovery::candidates()` (`src/client/discovery.rs:124-154`) and `ClientCore::discover()` (`src/client/core.rs:1436-1495`).
- **Next Steps / Handoff**:
  1. Consider shuffling `bundled_resolvers(&country)` per client in `Discovery::candidates()` (`src/client/discovery.rs:145-147`) using `OsRng` (or pre-interleaving `data/resolvers/ir.txt` by `/16` prefix).
  2. Consider trying or interleaving `data/resolvers/global.txt` ahead of multi-thousand-entry country lists in `Discovery::candidates()` (`src/client/discovery.rs:145-148`).
  3. Update `data/THIRD_PARTY.md:3-5` if `verified-working-dns.txt` provenance differs from `kevinnet-dns`.
- **Preferred Communication Style**: exact file:line citations, verified claims over paraphrase, credentials never reproduced in notes or commits.

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
