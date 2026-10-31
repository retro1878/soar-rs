# Comprehensive Technical Review & Findings: `soar-rs`

**Review Date**: 2026-10-31  
**Target Repository**: `sessions/soar-rs`  
**Reference Specification**: [Soar SPEC.md (getlantern/soar)](https://github.com/getlantern/soar/blob/main/SPEC.md)  
**Version Reviewed**: 0.1.1 (commit `fda6c75`)

---

## 1. Executive Summary

`soar-rs` is a high-performance, wire-compatible Rust implementation of Lantern's Soar DNS tunneling protocol. It enables reliable TCP transport tunneled exclusively through recursive DNS queries (TXT and AAAA records) for circumvention in hostile environments where all non-DNS traffic is blocked.

The implementation is exceptionally well-structured, featuring a clean **sans-I/O** architecture that separates pure state-machine protocol logic from asynchronous Tokio runtimes. It achieves parity with the reference Go implementation, passes the upstream wire test vectors, and includes robust resilience mechanisms (probing name lengths, answer size trials, tail duplication, and multi-path congestion control).

---

## 2. Security Audit & Cryptographic Verification

### 2.1 Cryptographic Primitives & Key Schedule
- **Key Exchange**: Ephemeral X25519 with strict validation:
  ```rust
  let ee = ours.diffie_hellman(&PublicKey::from(*theirs));
  if !ee.was_contributory() {
      return Err(Error::WeakKey);
  }
  ```
  This effectively blocks small-subgroup / low-order public key attacks.
- **Server Authentication**: Ed25519 signing key on the server signs the transcript (`"soar v1 hello" || client_eph || server_eph || sid`). Clients verify using `verify_strict`.
- **Packet Protection**:
  - ChaCha20-Poly1305 with tag truncated to 8 bytes (`TAG_LEN = 8`, $2^{-64}$ forgery probability per attempt).
  - Authenticated Decryption checks tags in constant time via `subtle::ConstantTimeEq` (`Self::tag(...).ct_eq(tag)`).
  - Packet Number Protection: 16-bit packet numbers on the wire are masked using a ChaCha20 keystream generated from a 12-byte sample of the ciphertext (`SAMPLE_LEN = 12`).
  - Plaintext Floor: All packets are padded to at least `MIN_PLAIN = 4` bytes (`SAMPLE_LEN - TAG_LEN`), guaranteeing `mask()` never slices out of bounds.
- **Unknown Session Protocol**: The server signs `"soar v1 unknown session" || question` on NXDOMAIN replies. This prevents off-path or malicious injectors from tearing down active client sessions with forged NXDOMAIN packets.

### 2.2 Critical Security Finding: Untracked Script with Passwords
> [!CAUTION]
> **HIGH SEVERITY: Hardcoded Root SSH Credentials**
> An untracked script `soar-ssh.sh` was discovered in the repository root, holding a plaintext
> password for a bastion host and another for the target host. The script has since been moved out
> of the working tree and added to `.gitignore`; values are omitted here deliberately.
> **Risks:**
> 1. Accidental commitment into git would leak production/test jump host and backend root access.
> 2. `StrictHostKeyChecking=no` leaves SSH connections vulnerable to MITM interception.
> 
> **Immediate Mitigations:**
> 1. Delete `soar-ssh.sh` from disk or add it to `.gitignore`.
> 2. Rotate the passwords for `root@85.155.228.13` and `root@206.1.100.223`.
> 3. Switch to SSH key-based authentication with a dedicated bastion configuration.

---

## 3. Sans-I/O Core Architecture

### 3.1 Session Layer (`src/session.rs`)
- **Deterministic Time Injection**: Core structs (`Session`, `ClientCore`, `ServerCore`) take `now: Instant` as an argument on every call. No system clock calls exist within the transport logic.
- **Flow Control**:
  - Streams enforce `INITIAL_WINDOW = 32 KiB`.
  - Re-advertising window updates occurs when half the window is consumed (`rread + rwin - rmax >= rwin / 2`).
  - Receiving data beyond `rmax` immediately drops the stream with `"soar: peer exceeded stream flow control"`.
- **Replay Protection**:
  - Received packet numbers are tracked in a `RangeSet`.
  - Sliding `REPLAY_WINDOW` (16,384 packet numbers) rejects delayed replays.
- **Resource Exhaustion Defense**:
  - `MAX_CTRL_QUEUE = 1024` and `MAX_STREAMS_CAP = 256`.
  - Compile-time assertion `3 * MAX_STREAMS_CAP < MAX_CTRL_QUEUE` guarantees that valid stream states cannot overflow the queue.
  - Floods of stream opens or invalid control frames fail deterministically by closing the session, avoiding unbounded memory growth.

### 3.2 DNS Encoding & Compression Pointer Safety (`src/dns.rs`)
- **Anti-Looping `skip_name`**:
  ```rust
  pub fn skip_name(msg: &[u8], mut i: usize) -> Result<usize, Error> {
      loop {
          let n = *msg.get(i).ok_or(Error::Dns)? as usize;
          match n {
              0 => return Ok(i + 1),
              _ if n & 0xC0 == 0xC0 => return Ok(i + 2),
              _ if n > MAX_LABEL => return Err(Error::Dns),
              _ => i += 1 + n,
          }
      }
  }
  ```
  `skip_name` terminates on pointer `0xC0` without recursing or chasing pointers, providing full immunity against cyclic compression pointer denial-of-service.
- **Numbered AAAA Carrier**:
  Supports environments where recursive resolvers inspect or strip TXT records. Numbers each 15-byte chunk (`AAAA_CHUNK = 15`) with a 1-byte sequence index to correctly reassemble shuffled or deduplicated RRsets.

---

## 4. Client Multipath & Network Probing

### 4.1 Safe QName Probing
- Starts query names at `safe_qname` (default: 101 presentation characters), designed to slip under middlebox DPI rules (such as Iran's DPI threshold).
- Transparently pads and probes up to `max_qname` (253 presentation characters) on verified paths.

### 4.2 Statistical Answer-Size Probing (DNS Path MTU Discovery)
- Starts answer size limit at 512 bytes (guaranteed DNS UDP payload).
- Conducts dual-window statistical trials (`test_win` vs `base_win`) using standard error hypothesis testing:
  $$\Delta = \frac{k_a}{n_a} - \frac{k_b}{n_b} > \max\left(0.25, 3 \cdot \text{SE}\right)$$
  This differentiates size-specific middlebox drops from general network congestion or packet loss.
- Truncated replies (`TC` bit set) trigger immediate exponential backoff on answer size.

### 4.3 Resilience & Fallbacks
- **Automatic TCP/53 Siblings**: If UDP queries to a resolver repeatedly fail (`out_n >= 2`), a sibling TCP path is created automatically.
- **Tail Duplication**: The final chunk/packet of an upload is duplicated on a secondary healthy path to avoid head-of-line blocking on packet loss.
- **Session Idle Expiration**: Sessions without active streams are automatically retired after 90 seconds (or 10 seconds if unused), preventing connects from sending data on sessions the server already timed out.

---

## 5. Server Hardening & Defense-in-Depth

### 5.1 Anti-SSRF & Destination Dial Policy (`src/server/dial.rs`)
- Restricts default destination ports to 80 and 443.
- `is_public(addr)` filters out:
  - RFC 1918 private subnets (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`)
  - Loopback (`127.0.0.0/8`, `::1`)
  - Carrier-Grade NAT (`100.64.0.0/10`)
  - Link-Local, Multicast, Broadcast, IETF protocol assignments, TEST-NET
  - Embedded IPv4 formats in IPv6 (NAT64 `64:ff9b::/96` and 6to4 `2002::/16`)
- **Self-Dialing Protection**: Queries local network interfaces via `if_addrs` to prevent clients from connecting to the host's own internal services via its public IP.
- **DNS Rebinding Protection**: The security check runs directly on the resolved IP (`SocketAddr`) *after* resolution, immediately prior to `TcpStream::connect`.

### 5.2 Anti-Amplification & Response Rate Limiting (RRL)
- Limits response bytes per second per source prefix (/24 for IPv4, /48 for IPv6) in `ServerCore::allow_amplification`.
- Only amplified bytes ($L_{\text{response}} - L_{\text{query}}$) consume rate tokens.
- Bounded table size: Caps prefix tracking table at `MAX_RRL_PREFIXES = 65,536` with an overflow shared bucket, preventing memory exhaustion from spoofed source IPs.

### 5.3 Held Polls Priority Queue
- Idle client queries are held up to `max_hold` (default 1.5s) waiting for server data.
- Deadlines are stored in a `BinaryHeap<Reverse<(Instant, u64, u64)>>`, making timeout polling $O(\log N)$ rather than $O(N)$.
- Polls are released in arrival order so answers do not trigger false loss detections on the client.

---

## 6. Cross-Platform & Runtime Observations

### 6.1 Windows System DNS Resolution
- In `src/client/discovery.rs` lines 107-119:
  ```rust
  fn system_resolvers() -> Vec<String> {
      let Ok(conf) = std::fs::read_to_string("/etc/resolv.conf") else {
          return Vec::new();
      };
      ...
  }
  ```
  This implementation is Unix-specific. On Windows, `/etc/resolv.conf` does not exist, so `system_resolvers()` returns an empty vector.
  - **Impact**: On Windows machines with discovery enabled and no explicit `-resolver` flags, automatic detection of the local network's DNS server will not occur.
  - **Recommendation**: Add a conditional compilation block for Windows using the Windows IP Helper API (or a lightweight crate such as `ipconfig`) to enumerate adapter DNS addresses.

### 6.2 Dual-Stack Server Sockets
- In `src/bin/soar-server.rs`, `bind_any()` explicitly configures `IPV6_V6ONLY = false` on dual-stack sockets, correctly ensuring cross-platform behavior across Linux, Windows, and OpenBSD.

---

## 7. Action Items & Recommendations

1. **Security (Immediate)**: Remove `soar-ssh.sh` from the working copy and rotate credentials on the target hosts.
2. **Platform Support**: Implement Windows adapter DNS discovery in `src/client/discovery.rs`.
3. **CI Matrix**: Consider adding a Windows runner (`windows-latest`) to `.github/workflows/ci.yml` alongside `ubuntu-latest` to verify dual-stack socket binding and compilation on Windows targets.
4. **Fuzzing**: The Sans-I/O design makes `parse_query`, `parse_answer`, and `Session::receive` ideal candidates for `cargo-fuzz` / `libfuzzer-sys`.
