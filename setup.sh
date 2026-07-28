#!/usr/bin/env bash
# VPS bootstrap: base packages, docker, python, fastfetch/anifetch, distillium/motd,
# shell shortcuts, github ssh key. Ubuntu 22.04/24.04, Debian 12. Run as root or with sudo.
#
#   ./setup.sh                  # default sections
#   ./setup.sh docker shell     # only these sections
#   ./setup.sh verify           # check what's installed
#
# Default:  base docker python fetch speedtest motd shell ssh firewall sshd
# Opt-in:   warp (cloudflare warp, changes routing)  remnawave (vpn panel CLIs)
#
# Env: SSH_EMAIL=you@mail.com   comment on the github key (asked interactively if unset)
#      GIT_NAME= GIT_EMAIL=     git config --global
#      ANI_FILE=x.mp4           animation for `ani` (menu if unset and assets/ has several)
#      PANEL_HOST=host          panel host (full access + node API)  default main-land.meth.ee
#      NODE_API_PORT=3000       remnanode APP_PORT, opened to the panel only
#      NODE_PUBLIC_PORTS="8443" extra VLESS inbound ports on top of 80/443/2525
#      NODE_UDP_PORTS="443"     udp inbounds (XHTTP/h3/hysteria only)
#      SELFSTEAL_PORT=9443      caddy decoy port, checked for leaks (never opened)
#      UFW_YES=1                enable ufw unattended
#      VERBOSE=1                full apt output instead of the progress bar
set -euo pipefail

# user whose $HOME gets pipx/anifetch/ssh keys (sudo-aware)
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
# gif/video anifetch plays; drop files into ./assets next to this script
ANI_FILE="${ANI_FILE:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOGFILE="${LOGFILE:-/var/log/vps-set.log}"
VERBOSE="${VERBOSE:-0}"

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
as_user() { sudo -u "$TARGET_USER" -H "$@"; }

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0 $*"; exit 1; }
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1   # no service-restart menu mid-run

# --- progress bar -------------------------------------------------------
STEP=0 STEPS_TOTAL=0
BAR_FULL='########################' BAR_EMPTY='........................'

draw() { # pct msg spinner
  local pct=$1 filled=$(( $1 * 24 / 100 ))
  printf '\r\033[K  [%s%s] %3d%%  %s %s' \
    "${BAR_FULL:0:filled}" "${BAR_EMPTY:0:$((24-filled))}" "$pct" "$3" "$2"
}

# step "what it's doing" cmd args...   — output goes to $LOGFILE, bar to the terminal.
# Only for non-interactive commands; anything that asks questions runs in the foreground.
step() {
  local msg=$1; shift
  STEP=$((STEP+1))
  local pct=$(( STEPS_TOTAL > 0 ? STEP * 100 / STEPS_TOTAL : 100 ))
  [ "$pct" -le 100 ] || pct=100

  if [ "$VERBOSE" = 1 ] || [ ! -t 1 ]; then
    printf '  -> %s\n' "$msg"
    "$@"
    return
  fi

  "$@" </dev/null >>"$LOGFILE" 2>&1 &
  local pid=$! i=0 rc=0 spin='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    draw "$pct" "$msg" "${spin:i++%4:1}"
    sleep 0.2
  done
  wait "$pid" || rc=$?
  if [ "$rc" -eq 0 ]; then
    draw "$pct" "$msg" $'\033[32mok\033[0m'; printf '\n'
  else
    draw "$pct" "$msg" $'\033[31mFAIL\033[0m'; printf '\n'
    warn "last 20 lines of $LOGFILE:"; tail -n 20 "$LOGFILE"
    return "$rc"
  fi
}

# download a third-party installer to /tmp, print the path, then run it (keeps the TTY —
# these ask questions)
run_remote() {
  local url=$1 tmp; tmp=$(mktemp "/tmp/$(basename "$url").XXXXXX")
  curl -fsSL "$url" -o "$tmp"
  warn "third-party installer at $tmp (from $url) — review with: less $tmp"
  bash "$tmp"
  rm -f "$tmp"
}

# --- base ---------------------------------------------------------------
base() {
  log "base packages"
  step "apt update"  apt-get update -qq
  step "apt upgrade" apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade
  step "tools" apt-get install -y -qq \
    ca-certificates curl wget gnupg lsb-release apt-transport-https software-properties-common \
    git nano vim htop tmux screen unzip zip tar rsync tree ncdu jq \
    net-tools iproute2 dnsutils iputils-ping mtr-tiny nmap \
    build-essential pkg-config ufw fail2ban
  # ufw installed but NOT enabled — enabling blind over SSH locks you out.
}

# --- docker -------------------------------------------------------------
docker_repo() {
  install -m 0755 -d /etc/apt/keyrings
  local distro; distro=$(. /etc/os-release && echo "$ID")
  curl -fsSL "https://download.docker.com/linux/$distro/gpg" \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/$distro $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
}

docker_enable() {
  systemctl enable --now docker
  [ "$TARGET_USER" = root ] || usermod -aG docker "$TARGET_USER"
}

docker_install() {
  if have docker; then log "docker already installed ($(docker --version))"; return; fi
  log "docker"
  step "docker apt repo" docker_repo
  step "docker engine + compose" apt-get install -y -qq \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  step "enable docker" docker_enable
}

# --- python -------------------------------------------------------------
python_install() {
  log "python"
  step "python3 + pipx" apt-get install -y -qq python3 python3-pip python3-venv python3-dev pipx
  step "pipx ensurepath" as_user pipx ensurepath
}

# --- neofetch / anifetch ------------------------------------------------
# fastfetch only entered the ubuntu archive in 25.04, so on noble it comes from the
# release deb. anifetch drives fastfetch by default and its config is what renders
# the panel next to the animation.
fastfetch_pkg() {
  have fastfetch && return 0
  apt-get install -y -qq fastfetch 2>/dev/null && return 0
  local arch tmp
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) warn "no fastfetch build for $(uname -m), falling back to neofetch"
       apt-get install -y -qq neofetch; return 0 ;;
  esac
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/fastfetch.deb" \
    "https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-$arch.deb"
  apt-get install -y -qq "$tmp/fastfetch.deb"
  rm -rf "$tmp"
}
# PyPI `anifetch` is an abandoned 0.1.0 that divides by total_swap and dies with
# ZeroDivisionError on any swapless box. The maintained package is `anifetch-cli`
# (same `anifetch` command). Needs python >= 3.11.
anifetch_pkg() {
  as_user pipx uninstall anifetch >/dev/null 2>&1 || true
  as_user pipx install anifetch-cli || as_user pipx upgrade anifetch-cli
}

fetch_install() {
  log "fastfetch / anifetch"
  step "fastfetch" fastfetch_pkg
  # --no-install-recommends: ffmpeg otherwise drags in ~100 MB of mesa/gtk/vulkan
  # drivers that are useless on a headless VPS.
  step "chafa + ffmpeg" apt-get install -y -qq --no-install-recommends chafa ffmpeg
  step "anifetch" anifetch_pkg
  step "login panel + daily cache" fetch_panel
  echo "  panel keys are Nerd Font glyphs — install one in your LOCAL terminal, or they render as boxes"

  # copy local gifs/videos into anifetch's asset dir — media only, the README in
  # there is documentation, not something to play
  local assets="$TARGET_HOME/.local/share/anifetch/assets" f copied=0
  for f in "$SCRIPT_DIR"/assets/*; do
    [ -f "$f" ] || continue
    is_media "$f" || continue
    install -d -o "$TARGET_USER" -g "$TARGET_USER" "$assets"
    cp "$f" "$assets/"; copied=1
  done
  [ "$copied" = 0 ] || chown -R "$TARGET_USER:$TARGET_USER" "$assets"
  [ -n "$ANI_FILE" ] || pick_animation "$assets" \
    || warn "no anifetch asset found — put a .gif/.mp4 in $SCRIPT_DIR/assets or run: ANI_FILE=x.mp4 $0 fetch shell"

  # For video sources anifetch renders JPEG frames via `ffmpeg -vf format=rgba`, and
  # mjpeg cannot do rgba — the result is an RGB JPEG with no JFIF header, which chafa
  # 1.14 (the version in noble) refuses with "Unknown file format". A .gif source takes
  # anifetch's transparent path and yields PNG frames instead, which always load.
  case "${ANI_FILE,,}" in
    ""|*.gif) ;;
    *) if step "converting $ANI_FILE to gif" gif_convert "$assets/$ANI_FILE" \
          && [ -s "$assets/${ANI_FILE%.*}.gif" ]; then
         ANI_FILE="${ANI_FILE%.*}.gif"
         echo "  animation: $ANI_FILE"
       else
         warn "gif conversion failed — keeping $ANI_FILE, chafa may reject its frames"
       fi ;;
  esac
}

gif_convert() {
  local src=$1 dst="${1%.*}.gif"
  [ -s "$dst" ] && return 0
  ffmpeg -y -v error -i "$src" \
    -vf "fps=12,scale=480:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" \
    -loop 0 "$dst"
  chown "$TARGET_USER:$TARGET_USER" "$dst"
}

# Everything in the login panel that needs the network or a slow apt call is
# refreshed once a day here, never at login.
fetch_cache_install() {
  cat > /usr/local/bin/vps-set-fetch-cache <<'EOF'
#!/usr/bin/env bash
# Cache public IP, geo and pending updates for the login panel.
set -uo pipefail
OUT="${FETCH_CACHE:-/var/cache/vps-set/fetch.env}"
mkdir -p "$(dirname "$OUT")"
get() { curl -fsS --max-time 6 "$@" 2>/dev/null; }
json=$(get https://ipinfo.io/json || true)
field() { printf '%s' "$json" | jq -r ".$1 // empty" 2>/dev/null; }
ip4=$(field ip); [ -n "$ip4" ] || ip4=$(get -4 https://ipinfo.io/ip || true)
ip6=$(get -6 https://ipinfo.io/ip || true)
# -s upgrade is slow (~1s) but this runs daily in the background, not at login
upg=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst ') || upg=0
sec=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep '^Inst ' | grep -ci security) || sec=0
{
  printf 'PUBLIC_IP4=%q\n' "$ip4"
  printf 'PUBLIC_IP6=%q\n' "$ip6"
  printf 'CITY=%q\n'       "$(field city)"
  printf 'REGION=%q\n'     "$(field region)"
  printf 'COUNTRY=%q\n'    "$(field country)"
  printf 'ORG=%q\n'        "$(field org)"
  printf 'UPDATES=%q\n'    "$upg"
  printf 'SECURITY=%q\n'   "$sec"
} > "$OUT"
chmod 644 "$OUT"
EOF
  chmod 755 /usr/local/bin/vps-set-fetch-cache

  cat > /etc/systemd/system/vps-set-fetch-cache.service <<'EOF'
[Unit]
Description=Refresh the login panel cache
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-set-fetch-cache
EOF
  cat > /etc/systemd/system/vps-set-fetch-cache.timer <<'EOF'
[Unit]
Description=Daily login panel cache refresh
[Timer]
OnCalendar=daily
OnBootSec=2min
Persistent=true
RandomizedDelaySec=30m
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now vps-set-fetch-cache.timer >/dev/null
}

# The panel anifetch draws next to the animation (and what plain `ff` prints).
# logo: none — anifetch supplies the visual, fastfetch must not draw its own.
fastfetch_config() {
  local dir="$TARGET_HOME/.config/fastfetch"
  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$dir"
  cat > "$dir/config.jsonc" <<'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "type": "none"
  },
  "display": {
    "separator": "  ",
    "color": {
      "keys": "33"
    },
    "key": {
      "width": 3
    }
  },
  "modules": [
    {
      "type": "title",
      "key": "",
      "format": "{user-name}@{host-name}"
    },
    "break",
    {
      "type": "os",
      "key": ""
    },
    {
      "type": "kernel",
      "key": ""
    },
    {
      "type": "uptime",
      "key": ""
    },
    {
      "type": "shell",
      "key": ""
    },
    {
      "type": "packages",
      "key": ""
    },
    "break",
    {
      "type": "cpu",
      "key": "󰉉"
    },
    {
      "type": "loadavg",
      "key": "󰍛"
    },
    {
      "type": "memory",
      "key": "󰩟"
    },
    {
      "type": "swap",
      "key": "󰩟"
    },
    {
      "type": "disk",
      "key": "",
      "folders": "/"
    },
    "break",
    {
      "type": "localip",
      "key": "",
      "defaultRouteOnly": true,
      "showIpv6": false
    },
    {
      "type": "command",
      "key": "󰊢",
      "parallel": true,
      "text": "[ -f /var/cache/vps-set/fetch.env ] && . /var/cache/vps-set/fetch.env; printf '%s' \"${PUBLIC_IP4:-n/a}\"; [ -n \"${PUBLIC_IP6:-}\" ] && printf '  %s' \"$PUBLIC_IP6\"; echo"
    },
    {
      "type": "command",
      "key": "",
      "parallel": true,
      "text": "[ -f /var/cache/vps-set/fetch.env ] && . /var/cache/vps-set/fetch.env; echo \"${CITY:-?}, ${COUNTRY:-?} - $(echo \"${ORG:-?}\" | cut -c1-28)\""
    },
    "break",
    {
      "type": "command",
      "key": "",
      "parallel": true,
      "text": "command -v docker >/dev/null || { echo 'not installed'; exit 0; }; r=$(docker ps -q 2>/dev/null | wc -l); t=$(docker ps -aq 2>/dev/null | wc -l); echo \"$r running / $t total\""
    },
    {
      "type": "command",
      "key": "",
      "parallel": true,
      "text": "docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode && echo 'remnanode up' || echo 'not deployed'"
    },
    {
      "type": "command",
      "key": "",
      "parallel": true,
      "text": "s=$(ufw status 2>/dev/null | sed -n 's/^Status: //p'); n=$(ufw status numbered 2>/dev/null | grep -c '^\\['); echo \"${s:-no access}${n:+, $n rules}\""
    },
    {
      "type": "command",
      "key": "󰝚",
      "parallel": true,
      "text": "s=$(fail2ban-client status sshd 2>/dev/null) || { echo 'n/a'; exit 0; }; c=$(printf '%s' \"$s\" | sed -n 's/.*Currently banned:[[:space:]]*//p'); t=$(printf '%s' \"$s\" | sed -n 's/.*Total banned:[[:space:]]*//p'); echo \"${c:-0} banned now / ${t:-0} total\""
    },
    "break",
    {
      "type": "command",
      "key": "",
      "parallel": true,
      "text": "last -i -w -n 12 2>/dev/null | awk '$1!=\"reboot\" && $3 ~ /^[0-9]/ {printf \"%-15s %s %s %s\\n\", $3, $5, $6, $7}' | head -3",
      "splitLines": true
    },
    "break",
    {
      "type": "command",
      "key": "",
      "parallel": true,
      "text": "[ -f /var/cache/vps-set/fetch.env ] && . /var/cache/vps-set/fetch.env; echo \"${UPDATES:-?} pending, ${SECURITY:-0} security\""
    },
    {
      "type": "command",
      "key": "󰅐",
      "text": "[ -f /var/run/reboot-required ] && echo 'REQUIRED - new kernel or libs staged' || echo 'not needed'"
    },
    "break",
    "colors"
  ]
}
EOF
  chown "$TARGET_USER:$TARGET_USER" "$dir/config.jsonc"
}

fetch_panel() { fastfetch_config; fetch_cache_install; /usr/local/bin/vps-set-fetch-cache; }

is_media() { case "${1,,}" in *.gif|*.mp4|*.webm|*.mkv|*.mov|*.avi|*.m4v) return 0 ;; *) return 1 ;; esac; }

# menu of playable files in the assets dir; sets $ANI_FILE. One file or no tty -> first.
pick_animation() {
  local assets=$1 files=() n i=1
  [ -d "$assets" ] || return 1
  mapfile -t files < <(cd "$assets" && ls -1 | grep -Ei '\.(gif|mp4|webm|mkv|mov|avi|m4v)$')
  [ ${#files[@]} -gt 0 ] || return 1

  if [ ${#files[@]} -eq 1 ] || [ ! -t 0 ]; then
    ANI_FILE="${files[0]}"
  else
    echo
    echo "Animation for \`ani\`:"
    for f in "${files[@]}"; do printf '  %d) %s\n' "$i" "$f"; i=$((i+1)); done
    read -r -p "Choice [1-${#files[@]}, default 1]: " n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#files[@]}" ] || n=1
    ANI_FILE="${files[n-1]}"
  fi
  echo "  animation: $ANI_FILE"
}

# --- cloudflare speedtest -----------------------------------------------
# prebuilt static musl binary from the release page — `cargo install` would pull
# the whole rust toolchain for a single CLI.
speedtest_get() {
  local arch
  case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64-unknown-linux-musl ;;
    aarch64|arm64) arch=aarch64-unknown-linux-musl ;;
    *) echo "no prebuilt binary for $(uname -m)"; return 1 ;;
  esac
  apt-get install -y -qq xz-utils
  local base=https://github.com/kavehtehrani/cloudflare-speed-cli/releases/latest/download
  local f="cloudflare-speed-cli-$arch.tar.xz" tmp
  tmp=$(mktemp -d)
  curl -fsSL -o "$tmp/$f" "$base/$f"
  curl -fsSL -o "$tmp/$f.sha256" "$base/$f.sha256"
  ( cd "$tmp" && sha256sum -c "$f.sha256" )   # release ships checksums, so check them
  tar -xJf "$tmp/$f" -C "$tmp"
  install -m 755 "$tmp/cloudflare-speed-cli-$arch/cloudflare-speed-cli" /usr/local/bin/
  rm -rf "$tmp"
}

speedtest_install() {
  log "cloudflare-speed-cli"
  step "download + verify + install" speedtest_get
}

# --- motd (distillium) --------------------------------------------------
motd_install() {
  log "distillium/motd"
  step "toilet" apt-get install -y -qq toilet toilet-fonts
  run_remote https://raw.githubusercontent.com/distillium/motd/main/install-motd.sh
  # configure later with: motd-set   |  render manually: motd
}

# --- github ssh key -----------------------------------------------------
ssh_key() {
  local dir="$TARGET_HOME/.ssh" key="$TARGET_HOME/.ssh/id_ed25519"
  local comment="${SSH_EMAIL:-${GIT_EMAIL:-}}" default="$TARGET_USER@$(hostname -s)"
  install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$dir"

  # comment is what GitHub shows next to the key — an email makes it identifiable
  if [ -z "$comment" ] && [ -t 0 ]; then
    read -r -p "Email for the GitHub key comment [$default]: " comment
  fi
  comment="${comment:-$default}"

  if [ -f "$key" ]; then
    log "ssh key exists: $key"
    # rewrite the comment on an existing key when an email was given explicitly
    if [ -n "${SSH_EMAIL:-${GIT_EMAIL:-}}" ]; then
      as_user ssh-keygen -c -C "$comment" -f "$key" -q -P "" \
        && echo "  comment -> $comment" || warn "could not change key comment (passphrase-protected?)"
    fi
  else
    log "generating ed25519 key for github"
    # no passphrase: unattended git pulls / deploy keys. Add one with `ssh-keygen -p -f $key`.
    step "ssh-keygen ($comment)" as_user ssh-keygen -t ed25519 -C "$comment" -f "$key" -N "" -q
  fi
  chown "$TARGET_USER:$TARGET_USER" "$key" "$key.pub"
  chmod 600 "$key"; chmod 644 "$key.pub"

  if ! grep -qs '^Host github.com' "$dir/config"; then
    log "ssh config -> github.com"
    cat >> "$dir/config" <<EOF

Host github.com
    User git
    IdentityFile $key
    IdentitiesOnly yes
    AddKeysToAgent yes
EOF
    chown "$TARGET_USER:$TARGET_USER" "$dir/config"; chmod 600 "$dir/config"
  fi

  if ! grep -qs 'github.com' "$dir/known_hosts"; then
    log "pinning github.com host keys"
    ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null >> "$dir/known_hosts"
    chown "$TARGET_USER:$TARGET_USER" "$dir/known_hosts"; chmod 644 "$dir/known_hosts"
    warn "verify these against https://docs.github.com/en/authentication/keeping-your-account-secure/githubs-ssh-key-fingerprints:"
    ssh-keygen -lf "$dir/known_hosts" | sed 's/^/    /'
  fi

  [ -z "${GIT_NAME:-}" ]  || as_user git config --global user.name  "$GIT_NAME"
  [ -z "${GIT_EMAIL:-}" ] || as_user git config --global user.email "$GIT_EMAIL"

  printf '\n\033[1;32mAdd this key at https://github.com/settings/ssh/new\033[0m\n\n'
  cat "$key.pub"
  printf '\nthen test:  ssh -T git@github.com\n'
}

# --- cloudflare warp (native/wireguard) ---------------------------------
warp_install() {
  log "distillium/warp-native"
  run_remote https://raw.githubusercontent.com/distillium/warp-native/main/install.sh
  # service: wg-quick@warp   | uninstall: .../uninstall.sh
}

# --- remnawave CLI wrappers ---------------------------------------------
remnawave_get() {
  local base=https://github.com/DigneZzZ/remnawave-scripts/raw/main s
  for s in remnawave remnanode selfsteal wtm; do
    curl -fsSL "$base/$s.sh" -o "/usr/local/bin/$s"
    chmod 755 "/usr/local/bin/$s"
  done
}

remnawave_install() {
  log "DigneZzZ/remnawave-scripts (CLI wrappers only)"
  step "remnawave remnanode selfsteal wtm" remnawave_get
  warn "wrappers only — nothing deployed. Run the install yourself, e.g. 'remnanode install' (interactive)."
}

# --- shell shortcuts ----------------------------------------------------
shell_install() {
  log "meth-setup -> /usr/local/bin"
  # one entry point from anywhere: updates the repo, then re-runs this script
  local origin
  origin=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null) \
    || origin=https://github.com/wakeupmetha/setup.git
  { printf '#!/usr/bin/env bash\nDIR=%q\nREPO=%q\n' "$SCRIPT_DIR" "$origin"
    cat <<'EOF'
# meth-setup [section...] — pull the repo and run setup.sh
set -euo pipefail
case "${1:-}" in
  -h|--help)
    echo "meth-setup [section...]"
    echo "  sections: base docker python fetch speedtest motd shell ssh"
    echo "            firewall sshd node crowdsec warp remnawave verify"
    echo "  no args  = default run"
    exit 0 ;;
esac
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" pull --ff-only || {
    echo "[!] repo not updated — running the copy on disk" >&2
    git -C "$DIR" status --short >&2
  }
else
  git clone "$REPO" "$DIR"
fi
[ "$(id -u)" -eq 0 ] && exec "$DIR/setup.sh" "$@" || exec sudo -E "$DIR/setup.sh" "$@"
EOF
  } > /usr/local/bin/meth-setup
  chmod 755 /usr/local/bin/meth-setup
  echo "  meth-setup [section...]  — updates $SCRIPT_DIR and re-runs from anywhere"

  log "shortcuts -> /etc/profile.d/99-vps-set.sh"
  # $ANI_FILE is set by the fetch section; running `shell` on its own must not wipe
  # the animation, so recover it from the file we are about to overwrite.
  if [ -z "$ANI_FILE" ]; then
    ANI_FILE=$(sed -n 's/^ANIFETCH_FILE="\(.*\)"$/\1/p' /etc/profile.d/99-vps-set.sh 2>/dev/null) || true
    # nothing configured yet: take the first asset, never prompt from here
    [ -n "$ANI_FILE" ] \
      || pick_animation "$TARGET_HOME/.local/share/anifetch/assets" </dev/null \
      || true
  fi
  printf '%s\n' "ANIFETCH_FILE=\"${ANI_FILE:-}\"" > /etc/profile.d/99-vps-set.sh
  cat >> /etc/profile.d/99-vps-set.sh <<'EOF'
# --- vps-set shortcuts ---
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
export PATH

# `ip` with no args -> public IPv4 + IPv6 of this box.
# With any argument it falls through to real iproute2, so `ip a`, `ip route`,
# and every script keep working (functions aren't exported to non-interactive shells).
ip() {
  [ $# -eq 0 ] || { command ip "$@"; return; }
  local v4 v6
  v4=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null) \
    || v4=$(command ip -4 -o addr show scope global | awk 'NR==1{sub(/\/.*/,"",$4); print $4}')
  v6=$(curl -6 -fsS --max-time 5 https://ifconfig.me 2>/dev/null) \
    || v6=$(command ip -6 -o addr show scope global | awk 'NR==1{sub(/\/.*/,"",$4); print $4}')
  printf 'IPv4: %s\nIPv6: %s\n' "${v4:-none}" "${v6:-disabled}"
}

# ipv6 [status|off|on] — sysctl-level toggle, persisted in /etc/sysctl.d
ipv6() {
  local S=""; [ "$(id -u)" -eq 0 ] || S=sudo
  case "${1:-status}" in
    off|disable)
      case "${SSH_CONNECTION:-}" in
        *:*:*) echo "refusing: you are connected over IPv6 — this would drop your session." >&2
               echo "reconnect over IPv4 first, or force it with: ipv6 off -f" >&2
               [ "${2:-}" = "-f" ] || return 1 ;;
      esac
      printf 'net.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\nnet.ipv6.conf.lo.disable_ipv6 = 1\n' \
        | $S tee /etc/sysctl.d/99-disable-ipv6.conf >/dev/null
      $S sysctl --system >/dev/null && echo "IPv6 disabled (persists across reboot)"
      ;;
    on|enable)
      $S rm -f /etc/sysctl.d/99-disable-ipv6.conf
      $S sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 net.ipv6.conf.lo.disable_ipv6=0
      echo "IPv6 enabled"
      ;;
    status|*)
      if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" = 1 ] \
         || [ ! -e /proc/sys/net/ipv6 ]; then echo "IPv6: disabled"
      else echo "IPv6: enabled"; fi
      ;;
  esac
}

ports()  { ss -tulpn; }
alias speedtest='cloudflare-speed-cli'
update() { sudo apt-get update && sudo apt-get -y upgrade; }
ff()     { command -v fastfetch >/dev/null && fastfetch "$@" || neofetch "$@"; }

alias d='docker'
alias dc='docker compose'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dlog='docker logs -f --tail 100'
alias ll='ls -alFh'
alias ..='cd ..'
alias ...='cd ../..'
alias df='df -hT -x tmpfs -x devtmpfs'
alias free='free -h'

# animated neofetch.  `ani --fresh` throws the frame cache away first: anifetch calls
# ffmpeg without -y, so it will not overwrite frames left behind by an interrupted
# render, and -fr alone keeps replaying the broken ones.
ani() {
  if [ "${1:-}" = "--fresh" ]; then
    shift
    find "$HOME/.local/share/anifetch" -maxdepth 1 -type d \
      -regextype posix-extended -regex '.*/[0-9a-f]{64}' -exec rm -rf {} + 2>/dev/null
    set -- -fr "$@"
  fi
  [ -n "$ANIFETCH_FILE" ] || { echo "set ANIFETCH_FILE in /etc/profile.d/99-vps-set.sh"; return 1; }
  local f="$HOME/.local/share/anifetch/assets/$ANIFETCH_FILE"
  [ -f "$f" ] || f="$ANIFETCH_FILE"
  # anifetch drives fastfetch by default; noble ships neofetch instead
  local backend=""
  command -v fastfetch >/dev/null || backend="-nf --force"
  # --no-input-restore: without it anifetch imports pynput on exit to replay your
  # keystrokes, which needs an X display and blows up on a headless box.
  # --symbols block: `wide` means full-width CJK glyphs — that is why the animation
  # comes out as japanese text. Override the lot with ANI_CHAFA=...
  anifetch "$f" -r 10 -W 60 -H 30 \
    -ca "${ANI_CHAFA:---symbols block --fg-only}" --no-input-restore $backend "$@"
}
EOF
  chmod 644 /etc/profile.d/99-vps-set.sh
  # profile.d is read at login, so the shell running this one still has none of it
  echo "  ani / ip / ipv6 / ports / speedtest ready — this shell won't see them until:"
  echo "      source /etc/profile.d/99-vps-set.sh    (or just re-login)"
}

# --- firewall -----------------------------------------------------------
# Node profile: remnanode + caddy selfsteal, everything in docker.
PANEL_HOST="${PANEL_HOST:-main-land.meth.ee}"   # panel: full access + the only source allowed on the node API
NODE_API_PORT="${NODE_API_PORT:-3000}"          # remnanode APP_PORT — must match the node's .env
NODE_PUBLIC_PORTS="${NODE_PUBLIC_PORTS:-}"      # extra VLESS inbound ports, e.g. "8443 2053"
NODE_UDP_PORTS="${NODE_UDP_PORTS:-}"            # only if an inbound uses XHTTP/h3/hysteria
SELFSTEAL_PORT="${SELFSTEAL_PORT:-9443}"        # caddy decoy — must stay 127.0.0.1 only
FIXED_PORTS="80 443 2525"                       # decoy http, xray reality inbound, remnawave smtp relay

# whatever sshd is really listening on — hardcoding 22 locks you out on a moved port
sshd_ports() {
  local p
  p=$(sshd -T 2>/dev/null | awk '/^port /{print $2}') || true
  [ -n "$p" ] || p=$(ss -tlnpH 2>/dev/null | awk '/sshd/{sub(/.*:/,"",$4); print $4}' | sort -u) || true
  echo "${p:-22}"
}

# without this docker writes ACCEPT straight into FORWARD and every published
# container port is reachable regardless of ufw
ufw_docker_get() {
  curl -fsSL -o /usr/local/bin/ufw-docker https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker
  chmod 755 /usr/local/bin/ufw-docker
  ufw-docker install
  systemctl restart ufw || true
}

# resolves the panel host and syncs the node-API rule; run now and daily by timer
panel_sync_install() {
  cat > /usr/local/bin/vps-set-panel-ip <<'EOF'
#!/usr/bin/env bash
# Sync the ufw rule for the node API port with the panel host's current IPs.
set -euo pipefail
. "${PANEL_CONF:-/etc/vps-set/panel.conf}"
STATE="${PANEL_STATE:-/etc/vps-set/panel.ips}"
new=$(getent ahosts "$PANEL_HOST" | awk '{print $1}' | sort -u)
# DNS down: keep the rules that are there. Never open up, never lock out.
[ -n "$new" ] || { echo "cannot resolve $PANEL_HOST — keeping current rules"; exit 0; }
old=$(cat "$STATE" 2>/dev/null || true)
[ "$new" = "$old" ] && exit 0
for ip in $old; do
  ufw --force delete allow from "$ip" to any port "$NODE_API_PORT" proto tcp >/dev/null 2>&1 || true
  ufw --force delete allow from "$ip" >/dev/null 2>&1 || true
done
for ip in $new; do
  ufw allow from "$ip" to any port "$NODE_API_PORT" proto tcp comment "panel $PANEL_HOST" >/dev/null
  ufw allow from "$ip" comment "panel $PANEL_HOST" >/dev/null
done
printf '%s\n' "$new" > "$STATE"
echo "panel $PANEL_HOST -> $(echo $new | tr '\n' ' ')"
EOF
  chmod 755 /usr/local/bin/vps-set-panel-ip

  cat > /etc/systemd/system/vps-set-panel-ip.service <<'EOF'
[Unit]
Description=Sync ufw rules with the panel host's IP
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/vps-set-panel-ip
EOF
  cat > /etc/systemd/system/vps-set-panel-ip.timer <<'EOF'
[Unit]
Description=Daily panel IP re-resolve
[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now vps-set-panel-ip.timer >/dev/null
}

firewall() {
  log "ufw (node profile)"
  have ufw || step "ufw" apt-get install -y -qq ufw

  local host="$PANEL_HOST" api="$NODE_API_PORT" extra="$NODE_PUBLIC_PORTS" ans p
  if [ -t 0 ]; then
    read -r -p "Panel host [$PANEL_HOST]: " ans; host="${ans:-$PANEL_HOST}"
    read -r -p "Node API port, panel-only [$NODE_API_PORT]: " ans; api="${ans:-$NODE_API_PORT}"
    read -r -p "Extra public ports (space separated) [${NODE_PUBLIC_PORTS:-none}]: " ans; extra="${ans:-$NODE_PUBLIC_PORTS}"
  fi

  have docker && step "ufw-docker" ufw_docker_get

  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  ufw default deny routed    >/dev/null
  echo "  default: deny incoming / allow outgoing / deny routed"

  # ssh open to the world but rate-limited: >6 connections in 30s and the source is dropped
  for p in $(sshd_ports); do
    ufw limit "$p"/tcp comment 'ssh rate-limited' >/dev/null && echo "  limit $p/tcp (sshd)"
  done

  for p in $(printf '%s\n' $FIXED_PORTS $extra | sort -un); do
    ufw allow "$p"/tcp comment 'vps-set node' >/dev/null && echo "  allow $p/tcp"
  done
  for p in $NODE_UDP_PORTS; do
    ufw allow "$p"/udp comment 'vps-set node' >/dev/null && echo "  allow $p/udp"
  done

  # the selfsteal decoy is fronted by xray on 127.0.0.1 — reachable from outside it
  # answers with the same cert on a second port and gives the disguise away
  if ufw status | grep -q "^$SELFSTEAL_PORT"; then
    warn "$SELFSTEAL_PORT/tcp (caddy selfsteal) is open to the world — remove it: ufw delete allow $SELFSTEAL_PORT/tcp"
  fi

  install -d /etc/vps-set
  printf 'PANEL_HOST=%s\nNODE_API_PORT=%s\n' "$host" "$api" > /etc/vps-set/panel.conf
  panel_sync_install
  /usr/local/bin/vps-set-panel-ip || warn "panel rule not applied — check: vps-set-panel-ip"

  if ufw status | grep -q '^Status: active'; then
    ufw reload >/dev/null; echo "  ufw already active, rules reloaded"
  else
    echo; ufw show added
    if [ -t 0 ]; then
      read -r -p $'\nEnable ufw now? Everything else gets closed. [y/N]: ' ans
      [ "$ans" = y ] || [ "$ans" = Y ] || { warn "left disabled — enable later with: ufw enable"; return 0; }
    elif [ "${UFW_YES:-0}" != 1 ]; then
      warn "non-interactive: not enabling. Re-run with UFW_YES=1, or: ufw enable"; return 0
    fi
    ufw --force enable
  fi

  container_ports
}

# remnanode and caddy-selfsteal both run with network_mode: host, so their sockets land
# in the normal INPUT chain and the ufw rules above already cover them — ufw-docker has
# no bridge IP to work with and would just error out. It still matters for every OTHER
# container on the box: bridge + `-p` publishes straight past ufw.
container_ports() {
  local c mode ports p
  have docker || return 0
  echo
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null || true); do
    mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$c" 2>/dev/null || echo '?')
    if [ "$mode" = host ]; then
      printf '  %-16s network=host — covered by the ufw rules above\n' "$c"
      continue
    fi
    # read what it actually published instead of guessing: "0.0.0.0:443->443/tcp"
    ports=$(docker inspect -f '{{range $p, $c := .NetworkSettings.Ports}}{{if $c}}{{$p}} {{end}}{{end}}' "$c" 2>/dev/null || true)
    if [ -z "$ports" ]; then
      printf '  %-16s network=%s, nothing published\n' "$c" "$mode"
      continue
    fi
    for p in $ports; do
      ufw-docker allow "$c" "$p" >/dev/null 2>&1 \
        && echo "  ufw-docker allow $c $p" \
        || warn "ufw-docker allow $c $p failed — run it by hand"
    done
  done
}

# --- node check ---------------------------------------------------------
# Run this after deploying remnanode/selfsteal: answers "why can't users connect".
node_check() {
  log "node check"
  local c mode p listen

  for c in remnanode caddy; do
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
      mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$c")
      printf '  \033[32mok\033[0m   %-12s running (network=%s)\n' "$c" "$mode"
    else
      printf '  \033[33m--\033[0m   %-12s not running\n' "$c"
    fi
  done

  echo
  echo "  publicly bound sockets:"
  ss -tulnH 2>/dev/null | awk '{print $1, $5}' | grep -Ev ' (127\.0\.0\.1|\[::1\])' \
    | sort -u | sed 's/^/    /'

  # every public listener should have a matching ufw rule, or users get nothing
  echo
  echo "  inbound vs ufw:"
  for p in $(ss -tlnH 2>/dev/null | awk '{print $4}' | grep -Ev '^(127\.0\.0\.1|\[::1\])' \
             | sed 's/.*://' | sort -un); do
    if ufw status | grep -qE "^$p(/tcp)?[[:space:]]+ALLOW|^$p(/tcp)? "; then
      printf '    \033[32mok\033[0m   %-6s listening, allowed\n' "$p"
    else
      printf '    \033[31mBLOCKED\033[0m %-6s listening but ufw drops it — ufw allow %s/tcp\n' "$p" "$p"
    fi
  done

  # decoy must answer only to xray on loopback
  listen=$(ss -tlnH "sport = :$SELFSTEAL_PORT" 2>/dev/null | awk '{print $4}' || true)
  echo
  case "$listen" in
    "")            echo "  selfsteal $SELFSTEAL_PORT: nothing listening (caddy down?)" ;;
    127.0.0.1:*|\[::1\]:*) printf '  \033[32mok\033[0m   selfsteal %s bound to loopback only\n' "$SELFSTEAL_PORT" ;;
    *)             warn "selfsteal $SELFSTEAL_PORT is bound to $listen — should be 127.0.0.1 only, it leaks the decoy" ;;
  esac
}

# --- sshd hardening + fail2ban ------------------------------------------
sshd_harden() {
  log "sshd hardening"
  local keys=0 f
  for f in /root/.ssh/authorized_keys "$TARGET_HOME/.ssh/authorized_keys"; do
    [ -s "$f" ] && keys=1 || true
  done
  if [ "$keys" = 0 ]; then
    warn "no authorized_keys for root or $TARGET_USER — NOT disabling password auth, that would lock you out."
    warn "install your key first (ssh-copy-id root@this-host), then: $0 sshd"
  else
    if ! grep -qs '^Include /etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config; then
      warn "/etc/ssh/sshd_config has no Include for sshd_config.d — set PasswordAuthentication no there by hand"
    else
      # 00- prefix so this wins over cloud-init's 50-cloud-init.conf (first match wins in sshd)
      cat > /etc/ssh/sshd_config.d/00-vps-set.conf <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
      if sshd -t; then
        systemctl reload ssh 2>/dev/null || systemctl reload sshd
        sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication) ' | sed 's/^/  /'
      else
        rm -f /etc/ssh/sshd_config.d/00-vps-set.conf
        warn "sshd -t failed, config reverted"
      fi
    fi
  fi

  log "fail2ban"
  have fail2ban-server || step "fail2ban" apt-get install -y -qq fail2ban
  # backend=systemd: 24.04 has no /var/log/auth.log unless rsyslog is installed
  cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled  = true
port     = $(sshd_ports | tr '\n' ',' | sed 's/,$//')
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' || warn "sshd jail not up — check: journalctl -u fail2ban -n 30"
}

# --- crowdsec (opt-in) --------------------------------------------------
crowdsec_install() {
  log "crowdsec"
  run_remote https://install.crowdsec.net
  step "crowdsec + firewall bouncer" apt-get install -y -qq crowdsec crowdsec-firewall-bouncer-iptables
  warn "crowdsec and fail2ban both ban ssh brute force — running both is redundant but harmless. Drop fail2ban with: systemctl disable --now fail2ban"
}

# --- verify -------------------------------------------------------------
verify() {
  log "verify"
  local rc=0
  check() { if have "$1"; then printf '  \033[32mok\033[0m   %-12s %s\n' "$1" "$(${2:-true} 2>/dev/null | head -n1)"; else printf '  \033[31mMISS\033[0m %s\n' "$1"; rc=1; fi; }
  check docker   "docker --version"
  check python3  "python3 --version"
  check pipx     "pipx --version"
  check chafa    "chafa --version"
  check ffmpeg
  check toilet
  check jq
  check cloudflare-speed-cli "cloudflare-speed-cli --version"
  have fastfetch || have neofetch || { echo "  MISS fastfetch/neofetch"; rc=1; }
  [ -f "$TARGET_HOME/.config/fastfetch/config.jsonc" ] || { printf '  \033[31mMISS\033[0m login panel config\n'; rc=1; }
  [ -f /var/cache/vps-set/fetch.env ] || { printf '  \033[31mMISS\033[0m panel cache (run: vps-set-fetch-cache)\n'; rc=1; }
  [ -x "$TARGET_HOME/.local/bin/anifetch" ] || { printf '  \033[31mMISS\033[0m anifetch\n'; rc=1; }
  [ -f /etc/profile.d/99-vps-set.sh ] || { printf '  \033[31mMISS\033[0m shortcuts\n'; rc=1; }
  [ -x /usr/local/bin/meth-setup ] || { printf '  \033[31mMISS\033[0m meth-setup\n'; rc=1; }
  [ -f /etc/update-motd.d/00-dist-motd ] || { printf '  \033[31mMISS\033[0m motd\n'; rc=1; }
  [ -f "$TARGET_HOME/.ssh/id_ed25519.pub" ] || { printf '  \033[31mMISS\033[0m github ssh key\n'; rc=1; }
  # opt-in sections: reported, never counted as failures
  ufw status 2>/dev/null | grep -q '^Status: active' && echo "  ok   ufw         active" || echo "  --   ufw         inactive"
  [ -x /usr/local/bin/ufw-docker ] && echo "  ok   ufw-docker  installed" || echo "  --   ufw-docker  missing (docker bypasses ufw)"
  systemctl is-active --quiet fail2ban && echo "  ok   fail2ban    active" || echo "  --   fail2ban    inactive"
  [ "$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}')" = no ] \
    && echo "  ok   sshd        password auth off" || echo "  --   sshd        password auth still on"
  systemctl is-active --quiet wg-quick@warp && echo "  ok   warp        active" || echo "  --   warp        not installed/inactive"
  [ -x /usr/local/bin/remnanode ] && echo "  ok   remnawave   CLIs present" || echo "  --   remnawave   not installed"
  return $rc
}

# --- main ---------------------------------------------------------------
# step count per section, only used to scale the progress bar (over/undershoot is clamped)
steps_of() {
  case $1 in
    base) echo 3;; docker) echo 3;; python) echo 2;; fetch) echo 4;;
    motd) echo 1;; ssh) echo 1;; remnawave) echo 1;; speedtest) echo 1;;
    firewall) echo 2;; sshd) echo 1;; crowdsec) echo 1;; *) echo 0;;
  esac
}

run() {
  case "$1" in
    base)   base ;;
    docker) docker_install ;;
    python) python_install ;;
    fetch)  fetch_install ;;
    speedtest) speedtest_install ;;
    motd)   motd_install ;;
    shell)  shell_install ;;
    ssh)    ssh_key ;;
    firewall) firewall ;;
    node)   node_check ;;
    sshd)   sshd_harden ;;
    crowdsec) crowdsec_install ;;
    warp)   warp_install ;;
    remnawave) remnawave_install ;;
    verify) verify ;;
    *) echo "unknown section: $1 (base docker python fetch speedtest motd shell ssh firewall sshd node crowdsec warp remnawave verify)"; exit 1 ;;
  esac
}

SECTIONS=("$@")
# firewall/sshd last: they close everything off once the rest is in place
[ $# -eq 0 ] && SECTIONS=(base docker python fetch speedtest motd shell ssh firewall sshd)
for s in "${SECTIONS[@]}"; do STEPS_TOTAL=$(( STEPS_TOTAL + $(steps_of "$s") )); done

: > "$LOGFILE" || true
[ "$VERBOSE" = 1 ] || echo "full output -> $LOGFILE  (VERBOSE=1 to see it live)"

for s in "${SECTIONS[@]}"; do run "$s"; done

if [ $# -eq 0 ]; then
  verify || warn "some checks failed"
  log "done — re-login (or: source /etc/profile.d/99-vps-set.sh) to get the shortcuts"
fi
