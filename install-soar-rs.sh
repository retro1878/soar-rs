#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/retro1878/soar-rs.git}"
FS_URL="${FS_URL:-}"
KEY_FILE=/etc/soar/key

die() { echo "error: $*" >&2; exit 1; }

# ask NAME QUESTION [DEFAULT]: prompt unless NAME is already set in the environment.
ask() {
	local name=$1 v
	[[ -v $name ]] && return 0
	read -r -p "$2${3:+ [$3]}: " v || die "no input; set $name in the environment"
	printf -v "$name" '%s' "${v:-$3}"
}

port53() { ss -H -ulpn 'sport = :53'; ss -H -tlpn 'sport = :53'; }

free_port_53() {
	local holders conf=/etc/systemd/resolved.conf i
	holders=$(port53)
	if [[ -z $holders ]]; then
		echo ":53 is free"
		return
	fi
	if ! grep -qi 'systemd-resolve' <<<"$holders"; then
		echo "port 53 is in use by:" >&2
		echo "$holders" >&2
		exit 1
	fi
	[[ -e $conf.bak ]] || cp "$conf" "$conf.bak"
	if grep -q '^[[:space:]]*DNSStubListener=' "$conf"; then
		sed -i 's/^[[:space:]]*DNSStubListener=.*/DNSStubListener=no/' "$conf"
	elif grep -q '^\[Resolve\]' "$conf"; then
		sed -i '/^\[Resolve\]/a DNSStubListener=no' "$conf"
	else
		printf '\n[Resolve]\nDNSStubListener=no\n' >>"$conf"
	fi
	echo "set DNSStubListener=no in $conf"
	if grep -q '127\.0\.0\.53' /etc/resolv.conf 2>/dev/null; then
		if [[ -e /run/systemd/resolve/resolv.conf ]]; then
			rm -f /etc/resolv.conf
			ln -s /run/systemd/resolve/resolv.conf /etc/resolv.conf
			echo "relinked /etc/resolv.conf -> /run/systemd/resolve/resolv.conf"
		else
			echo "warning: /run/systemd/resolve/resolv.conf missing; fix /etc/resolv.conf by hand" >&2
		fi
	fi
	systemctl restart systemd-resolved
	for ((i = 0; i < 45; i++)); do
		[[ -z $(port53) ]] && break
		sleep 1
	done
	holders=$(port53)
	if [[ -n $holders ]]; then
		echo "port 53 still in use after 45s:" >&2
		echo "$holders" >&2
		exit 1
	fi
	echo ":53 is free"
}

ask_source() {
	local c
	if [[ -v SOURCE ]]; then
		c=$SOURCE
	else
		echo "source:" >&2
		echo "  1) Download prebuilt binaries${FS_URL:+ from $FS_URL/dl/} (default)" >&2
		echo "  2) Compile from source" >&2
		read -r -p "Select [1-2]: " c || die "no input; set SOURCE=download|build"
	fi
	c=${c:-1}
	case ${c,,} in
	1 | download | dl) SRC=download ;;
	2 | build | compile | source) SRC=build ;;
	*) die "bad source: $c" ;;
	esac
}

# Download the prebuilt server and client. Fails (after saying why) if this
# host cannot run them, so the caller can fall back to a source build.
fetch_prebuilt() {
	local p tmp
	if [[ -z $FS_URL ]]; then
		read -r -p "distribution base URL, serves /dl/ (e.g. http://host:8080): " FS_URL ||
			die "no input; set FS_URL"
	fi
	if [[ $(uname -m) != x86_64 ]]; then
		echo "prebuilt binaries are x86_64; this host is $(uname -m)." >&2
		return 1
	fi
	command -v curl >/dev/null ||
		{ apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y curl; }
	tmp=$(mktemp -d)
	for p in soar-server soar-client; do
		if ! curl -fsSL "$FS_URL/dl/$p" -o "$tmp/$p"; then
			echo "download failed: $FS_URL/dl/$p" >&2
			rm -rf "$tmp"
			return 1
		fi
		chmod 0755 "$tmp/$p"
	done
	if ! "$tmp/soar-server" -h >/dev/null 2>&1 ||
		! "$tmp/soar-client" -h >/dev/null 2>&1; then
		echo "the downloaded binaries do not run on this host." >&2
		rm -rf "$tmp"
		return 1
	fi
	install -m 0755 "$tmp/soar-server" "$tmp/soar-client" /usr/local/bin/
	rm -rf "$tmp"
	tar -C /usr/local/bin -czf /root/soar-client-bundle.tar.gz soar-client
}

install_server() {
	local p pkgs=() need=1 ver="" triple zone ports pub other

	echo "== server =="
	command -v dpkg >/dev/null || die "Debian/Ubuntu required"
	ask_source

	if [[ $SRC == download ]] && ! fetch_prebuilt; then
		echo "cannot use the prebuilt binaries here; compiling from source instead (needs internet and Rust >= 1.88)." >&2
		SRC=build
	fi
	if [[ $SRC == build ]]; then
		for p in git curl ca-certificates build-essential musl-tools; do
			dpkg -s "$p" >/dev/null 2>&1 || pkgs+=("$p")
		done
		if ((${#pkgs[@]})); then
			apt-get update
			DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
		fi
		export PATH="$HOME/.cargo/bin:$PATH"
		if command -v rustc >/dev/null 2>&1; then
			ver=$(rustc --version 2>/dev/null | awk '{print $2}') || ver=""
			[[ -n $ver ]] || ver=0
			[[ $(printf '%s\n1.88\n' "$ver" | sort -V | head -n1) == 1.88 ]] && need=0
		fi
		if ((need)); then
			curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal ||
				die "rustup install failed; install Rust >= 1.88 by hand"
		fi
		command -v rustup >/dev/null || die "rustup not found; install Rust >= 1.88 with rustup"
		triple="$(uname -m)-unknown-linux-musl"
		rustup target add "$triple"

		if [[ -d /opt/soar-rs/.git ]]; then
			git -C /opt/soar-rs pull --ff-only
		elif [[ -e /opt/soar-rs ]]; then
			die "/opt/soar-rs exists but is not a git clone; remove it first"
		else
			git clone "$REPO_URL" /opt/soar-rs
		fi
		cd /opt/soar-rs
		cargo build --release --locked --bins
		install -m 0755 target/release/soar-server target/release/soar-client /usr/local/bin/
		cargo build --release --locked --bin soar-client --target "$triple"
		tar -C "target/$triple/release" -czf /root/soar-client-bundle.tar.gz soar-client
	fi

	ask ZONE "zone (e.g. t.example.com)" ""
	[[ -n ${ZONE:-} ]] || die "zone is required"
	ask ALLOW_PORTS "allowed ports" "22,1080"
	zone=$ZONE
	ports=${ALLOW_PORTS// /}
	[[ $ports =~ ^[0-9]+(,[0-9]+)*$ ]] ||
		die "allowed ports must be a comma-separated list of port numbers (not 'any')"

	install -d -m 0755 /etc/soar
	if [[ ! -s $KEY_FILE ]]; then
		(umask 077; /usr/local/bin/soar-server keygen | awk '$1 == "private" { print $2 }' >"$KEY_FILE")
	fi
	[[ -s $KEY_FILE ]] || die "key file is empty: $KEY_FILE"

	other=$(port53 | grep -viE 'systemd-resolve|soar-server' || true)
	if [[ -n $other ]]; then
		echo "port 53 is in use by:" >&2
		port53 >&2
		exit 1
	fi
	systemctl stop soar-server.service 2>/dev/null || true
	free_port_53

	cat >/etc/systemd/system/soar-server.service <<EOF
[Unit]
Description=soar DNS tunnel server

[Service]
ExecStart=/usr/local/bin/soar-server -zone $zone -key-file $KEY_FILE -listen :53 -allow-ports $ports -allow-private
Restart=always
RestartSec=2
NoNewPrivileges=yes
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable soar-server.service
	systemctl restart soar-server.service
	sleep 2
	systemctl is-active --quiet soar-server.service ||
		die "soar-server did not stay up; check journalctl -u soar-server.service"

	pub=$(/usr/local/bin/soar-server pubkey "$KEY_FILE")
	cat <<EOF

server installed.
  public key : $pub
  zone       : $zone
  ports      : $ports
  bundle     : /root/soar-client-bundle.tar.gz

copy the bundle to the client host (must be the same CPU architecture):
  scp /root/soar-client-bundle.tar.gz root@<client-host>:/root/

DNS: create an NS record for $zone pointing at a name whose A/AAAA record is this server's public IP.
Firewall: allow UDP 53 and TCP 53 (the client falls back to TCP when UDP fails).
Warning: anyone who knows the zone can open streams through the tunnel, so any SOCKS inbound must
require a username and password, and sshd on port 22 should be key-only (PasswordAuthentication no).
EOF
}

install_client() {
	local src="${BUNDLE_ARG:-${BUNDLE:-}}" tmp bin discover args lh lp fp

	echo "== client =="
	if [[ -z $src ]]; then
		read -r -p "soar-client: local file, bundle or URL${FS_URL:+ [$FS_URL/dl/soar-client]}: " src ||
			die "no input; pass the path or URL, or set BUNDLE"
		src=${src:-$FS_URL/dl/soar-client}
		[[ -n $src ]] || die "pass a path or URL, or set BUNDLE"
	fi

	tmp=""
	if [[ $src == http://* || $src == https://* ]]; then
		command -v curl >/dev/null || die "curl is needed to download $src"
		tmp=$(mktemp -d)
		curl -fsSL "$src" -o "$tmp/soar-client" || die "download failed: $src"
		bin="$tmp/soar-client"
	elif [[ $src == *.tar.gz || $src == *.tgz ]]; then
		[[ -f $src ]] || die "no such file: $src"
		tmp=$(mktemp -d)
		tar -xzf "$src" -C "$tmp"
		bin=$(find "$tmp" -type f -name soar-client -print -quit)
		[[ -n $bin ]] || die "no soar-client found in $src"
	else
		[[ -f $src ]] || die "no such file: $src"
		bin=$src
	fi
	install -m 0755 "$bin" /usr/local/bin/soar-client
	if [[ -n $tmp ]]; then rm -rf "$tmp"; fi
	/usr/local/bin/soar-client -h >/dev/null 2>&1 ||
		die "soar-client does not run here (wrong CPU architecture?)"

	ask ZONE "zone" ""
	ask PUBKEY "server public key (base64)" ""
	ask RESOLVERS "resolvers (comma-separated)" "9.9.9.9,8.8.8.8"
	ask DISCOVER "enable discovery with the bundled resolver list (-discover -country ir) [y/n]" "y"
	ask LISTEN "listen address" "127.0.0.1:7000"
	if [[ ! -v FORWARD ]]; then
		local c
		echo "server-side exit for this client (one target per client):" >&2
		echo "  1) sshd on 127.0.0.1:22 (pair with ssh -D for SOCKS5)" >&2
		echo "  2) SOCKS/HTTP inbound on 127.0.0.1:1080 (xray mixed)" >&2
		echo "  3) something else" >&2
		read -r -p "Select [1-3] (default 2): " c || die "no input; set FORWARD=host:port"
		case ${c:-2} in
		1 | ssh) FORWARD=127.0.0.1:22 ;;
		2 | socks | "") FORWARD=127.0.0.1:1080 ;;
		3 | other) ask FORWARD "forward target (host:port)" "127.0.0.1:1080" ;;
		*) die "bad choice: $c" ;;
		esac
	fi

	[[ -n ${ZONE:-} ]] || die "zone is required"
	[[ -n ${PUBKEY:-} ]] || die "public key is required"
	[[ -n ${FORWARD:-} ]] || die "forward target is required"
	discover=0
	case "${DISCOVER:-n}" in
	[yY] | [yY][eE][sS] | 1 | true) discover=1 ;;
	esac
	RESOLVERS="${RESOLVERS// /}"
	if [[ -z $RESOLVERS && $discover -eq 0 ]]; then
		die "refusing: no resolvers and discovery is off (soar-client would exit)"
	fi

	args="-zone $ZONE -pubkey $PUBKEY"
	if [[ -n $RESOLVERS ]]; then args+=" -resolver $RESOLVERS"; fi
	args+=" -listen $LISTEN -forward $FORWARD"
	if ((discover)); then args+=" -discover -country ir"; fi

	cat >/etc/systemd/system/soar-client.service <<EOF
[Unit]
Description=soar DNS tunnel client

[Service]
ExecStart=/usr/local/bin/soar-client $args
Restart=always
RestartSec=2
NoNewPrivileges=yes
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable soar-client.service
	systemctl restart soar-client.service
	sleep 2
	systemctl is-active --quiet soar-client.service ||
		die "soar-client did not stay up (check zone/pubkey); journalctl -u soar-client.service"

	lh=${LISTEN%:*}
	lp=${LISTEN##*:}
	fp=${FORWARD##*:}
	echo
	echo "client installed."
	echo "  zone   : $ZONE"
	echo "  listen : $LISTEN"
	echo "  forward: $FORWARD (dialed by the server)"
	echo
	if [[ $fp == 22 ]]; then
		echo "test:"
		echo "  ssh -p $lp -N -D 127.0.0.1:1080 root@$lh"
		echo "  curl --socks5-hostname 127.0.0.1:1080 https://example.com/"
	else
		echo "test:"
		echo "  curl --socks5-hostname $LISTEN https://example.com/"
		echo "  (add user:pass@ before the address if the SOCKS inbound needs auth)"
		echo
		echo "xray outbound for this tunnel (address is this client's listen):"
		echo "  {\"tag\":\"soar\",\"protocol\":\"socks\",\"settings\":{\"servers\":[{\"address\":\"${lh}\",\"port\":${lp}}]}}"
		echo "  no users unless the exit inbound requires them; route the inbound you want onto this tag."
	fi
}

uninstall() {
	local s
	for s in soar-server soar-client; do
		if [[ -f /etc/systemd/system/$s.service ]]; then
			systemctl disable --now "$s.service" || true
			rm -f "/etc/systemd/system/$s.service"
		fi
	done
	systemctl daemon-reload
	rm -f /usr/local/bin/soar-server /usr/local/bin/soar-client
	if ((PURGE)); then
		rm -rf /etc/soar /opt/soar-rs /root/soar-client-bundle.tar.gz
		echo "removed key, repo and bundle"
	else
		echo "kept $KEY_FILE (--purge removes it)"
	fi
	echo "resolved.conf not reverted: set DNSStubListener=yes in /etc/systemd/resolved.conf and restart systemd-resolved to restore it."
}

ACTION=""
BUNDLE_ARG=""
PURGE=0
for a in "$@"; do
	case "$a" in
	1 | server) ACTION=server ;;
	2 | client) ACTION=client ;;
	3 | uninstall) ACTION=uninstall ;;
	--purge) PURGE=1 ;;
	-h | --help)
		echo "usage: install-soar-rs.sh [1|server] [2|client [BUNDLE]] [3|uninstall] [--purge]"
		exit 0
		;;
	-*) die "unknown option: $a" ;;
	*) BUNDLE_ARG="${BUNDLE_ARG:-$a}" ;;
	esac
done

[[ $EUID -eq 0 ]] || die "run as root"

if [[ -z $ACTION ]]; then
	echo "1) Install server"
	echo "2) Install client"
	echo "3) Uninstall"
	read -r -p "Select [1-3]: " a || die "no input"
	case "$a" in
	1 | server) ACTION=server ;;
	2 | client) ACTION=client ;;
	3 | uninstall) ACTION=uninstall ;;
	*) die "bad selection: $a" ;;
	esac
fi

case $ACTION in
server) install_server ;;
client) install_client ;;
uninstall) uninstall ;;
esac
