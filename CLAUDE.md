# CLAUDE.md

Guidelines and reference documentation for AI coding assistants (Claude Code, Antigravity, and peer agents) working in `soar-rs`.

---

## 1. Project Overview

`soar-rs` is a wire-compatible Rust implementation of **[Soar](https://github.com/getlantern/soar)** (by Lantern), a censorship-circumvention DNS tunnel designed for networks that block all outbound traffic except DNS queries. It interoperates bidirectionally with the reference Go implementation and passes the wire test vectors defined in `testdata/vectors.json`.

### Architecture Philosophy: Sans-I/O
The core transport protocol is strictly **sans-I/O**:
- `src/session.rs` (`Session`), `src/client/core.rs` (`ClientCore`), and `src/server/core.rs` (`ServerCore`) contain **no sockets, no system clocks, and no Tokio runtimes**.
- Time is passed explicitly via `std::time::Instant` (`now: Instant`), making protocol behavior 100% deterministic and unit-testable without async mocks.
- Tokio runtimes live exclusively in `src/client/mod.rs` (`Client`, `Conn`) and `src/server/mod.rs` (`serve`).

---

## 2. Agent Coordination & Communication Instructions

When working on this repository as an AI agent (or in a multi-agent team), please adhere to these coordination guidelines:

### How to Leave Notes for Other Agents
1. **Append updates to `AGENT_NOTES.md`:**
   Whenever you implement a feature, refactor code, investigate a bug, or discover an architectural nuance, document it in [`AGENT_NOTES.md`](./AGENT_NOTES.md) using the standard entry format:
   ```markdown
   ### [YYYY-MM-DD HH:MM UTC] <Agent Name / Model> - <Topic/Task>
   - **Summary of Changes**: What was changed and why.
   - **Key Decisions & Invariants Upheld**: Trade-offs or design choices made.
   - **Verification**: Tests run, commands executed, results observed.
   - **Open Items / Next Steps**: What remains for future agents or human reviewers.
   ```
2. **Review `REVIEW_FINDINGS.md`:**
   Review [`REVIEW_FINDINGS.md`](./REVIEW_FINDINGS.md) for known vulnerabilities, security findings, platform limitations (e.g., Windows DNS discovery), and protocol caveats.
3. **State Your Communication Preferences:**
   Different agents and models have distinct context constraints and processing styles. When leaving notes in `AGENT_NOTES.md`, **please include how you prefer peer agents to communicate with and leave notes for you** (e.g., preferred level of technical granularity, diff format, exact file/line links, minimal prose vs. detailed rationale).
4. **Commit Attribution Convention:**
   Follow the existing repository style for agent co-authorship in git commits:
   ```text
   <component>: <short summary>

   <detailed explanation>

   Co-Authored-By: Claude <version/model> <noreply@anthropic.com>
   Claude-Session: <session-url-if-applicable>
   ```

---

## 3. Key Invariants & Architectural Rules

Do not violate the following fundamental design rules:

1. **Keep the Cores Sans-I/O:**
   - Never import `tokio::*`, `std::net::UdpSocket`, or `std::time::Instant::now()` inside `session.rs`, `client/core.rs`, or `server/core.rs`.
   - Pass time down through `now: Instant` on `tick()`, `handle()`, `receive()`, and `handle_timeout()`.
2. **Plaintext Floor & Tag Invariant:**
   - Poly1305 MAC tags are truncated to `TAG_LEN = 8` bytes.
   - Packet number masking requires a sample of `SAMPLE_LEN = 12` bytes.
   - Therefore, all plaintexts MUST have at least `MIN_PLAIN = 4` bytes (padded with `frames::PADDING` = `0x00`). `Session::build` ensures this; never bypass this floor.
3. **Queue Overflow Protection:**
   - `MAX_CTRL_QUEUE` is 1024; `MAX_STREAMS_CAP` is `MAX_CTRL_QUEUE / 4` (256).
   - Control frames must not be queued indefinitely. A misbehaving peer opening infinite streams must trigger deterministic session closure rather than OOM.
4. **SSRF & Dial Policy Protection:**
   - Any server dialing changes must respect `DialPolicy` in `src/server/dial.rs`.
   - Private IP ranges, loopbacks, link-local, multicast, documentation/benchmarking ranges, and IPv6 embedded forms (NAT64 `64:ff9b::/96`, 6to4 `2002::/16`) must NEVER be dialed unless `allow_private` is explicitly enabled.
   - The destination IP check MUST run *after* hostname resolution on the exact `SocketAddr` being dialed to prevent DNS rebinding.
   - Interface addresses on the host must be checked to prevent self-dialing attacks through firewalls.

---

## 4. Development & Build Commands

```sh
# Format & Lint
cargo fmt --check
cargo clippy --all-targets -- -D warnings

# Run all unit and integration tests
cargo test

# Check that test vectors match pinned commit from getlantern/soar
scripts/sync-vectors.sh --check

# Re-sync wire test vectors from getlantern/soar (e.g. main or commit SHA)
scripts/sync-vectors.sh main

# Run interop tests (requires Go installed)
interop/run.sh           # Go client vs Rust server
interop/run-reverse.sh   # Rust client vs Go server
```

---

## 5. Directory Map

| Path | Purpose |
| :--- | :--- |
| `src/varint.rs` | QUIC variable-length integer encoding (RFC 9000 §16) |
| `src/base32.rs` | Unpadded lowercase Base32 codec for query names (RFC 4648) |
| `src/dns.rs` | DNS message encoder/decoder (TXT chunking, numbered AAAA, EDNS0, SOA) |
| `src/crypto.rs` | ChaCha20-Poly1305 (8-byte tag), packet number masking, X25519, Ed25519 |
| `src/frames.rs` | QUIC-style frame parsing and serialization (PING, ACK, STREAM, RESET, etc.) |
| `src/ranges.rs` | Disjoint interval set (`RangeSet`) for packet numbers and stream offsets |
| `src/stream.rs` | Per-stream send/receive sliding windows, reassembly buffers, flow control |
| `src/session.rs` | Sans-I/O session engine: packet numbers, streams, ACKs, loss recovery |
| `src/client/core.rs` | Sans-I/O client state machine: multipath, RTT, cwnd, name/size probing |
| `src/client/discovery.rs` | Resolver candidate discovery, country lists, and IPv4 range sampling |
| `src/client/mod.rs` | Tokio runtime driver for `Client` and `Conn` (`AsyncRead`/`AsyncWrite`) |
| `src/server/core.rs` | Sans-I/O authoritative name server: held polls, RRL, anti-amplification |
| `src/server/dial.rs` | SSRF prevention and destination dial policy (`DialPolicy`) |
| `src/server/mod.rs` | Tokio runtime driver for `serve` (authoritative UDP loop + relays) |
| `src/bin/soar-client.rs` | Local TCP-to-DNS tunnel proxy CLI |
| `src/bin/soar-server.rs` | Authoritative tunnel DNS server CLI |
| `tests/runtime.rs` | Comprehensive Tokio integration tests on loopback |
| `testdata/vectors.json` | Pinned wire format test vectors from upstream reference |
