#!/usr/bin/env bash
# VPS bootstrap: base packages, docker, python, neofetch/anifetch, distillium/motd,
# shell shortcuts, github ssh key. Ubuntu 22.04/24.04, Debian 12. Run as root or with sudo.
#
#   ./setup.sh                  # default sections
#   ./setup.sh docker shell     # only these sections
#   ./setup.sh verify           # check what's installed
#
# Default:  base docker python fetch motd shell ssh
# Opt-in:   warp (cloudflare warp, changes routing)  remnawave (vpn panel CLIs)
set -euo pipefail

# user whose $HOME gets pipx/anifetch (sudo-aware)
TARGET_USER="${SUDO_USER:-$(id -un)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
# gif/video anifetch plays; drop files into ./assets next to this script
ANI_FILE="${ANI_FILE:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
as_user() { sudo -u "$TARGET_USER" -H "$@"; }
# download a third-party installer to /tmp, print the path, then run it
run_remote() {
  local url=$1 tmp; tmp=$(mktemp "/tmp/$(basename "$url").XXXXXX")
  curl -fsSL "$url" -o "$tmp"
  warn "third-party installer at $tmp (from $url) — review with: less $tmp"
  bash "$tmp"
  rm -f "$tmp"
}

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo $0 $*"; exit 1; }
export DEBIAN_FRONTEND=noninteractive

# --- base ---------------------------------------------------------------
base() {
  log "apt update + upgrade"
  apt-get update -qq
  apt-get -y -o Dpkg::Options::=--force-confold upgrade

  log "base packages"
  apt-get install -y \
    ca-certificates curl wget gnupg lsb-release apt-transport-https software-properties-common \
    git nano vim htop tmux screen unzip zip tar rsync tree ncdu jq \
    net-tools iproute2 dnsutils iputils-ping mtr-tiny nmap \
    build-essential pkg-config ufw fail2ban
  # ufw installed but NOT enabled — enabling blind over SSH locks you out.
}

# --- docker -------------------------------------------------------------
docker_install() {
  if have docker; then log "docker already installed ($(docker --version))"; return; fi
  log "docker (official repo)"
  install -m 0755 -d /etc/apt/keyrings
  local distro; distro=$(. /etc/os-release && echo "$ID")
  curl -fsSL "https://download.docker.com/linux/$distro/gpg" \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/$distro $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  [ "$TARGET_USER" = root ] || usermod -aG docker "$TARGET_USER"
}

# --- python -------------------------------------------------------------
python_install() {
  log "python + pipx"
  apt-get install -y python3 python3-pip python3-venv python3-dev pipx
  as_user pipx ensurepath >/dev/null 2>&1 || true
}

# --- neofetch / anifetch ------------------------------------------------
fetch_install() {
  log "neofetch / fastfetch"
  apt-get install -y neofetch 2>/dev/null || apt-get install -y fastfetch \
    || warn "neither neofetch nor fastfetch in repos"

  log "anifetch (pipx) + chafa + ffmpeg"
  apt-get install -y chafa ffmpeg
  have pipx || apt-get install -y pipx
  as_user pipx install anifetch 2>&1 | grep -v "already seems to be installed" || true

  # copy any local gifs/videos into anifetch's asset dir
  local assets="$TARGET_HOME/.local/share/anifetch/assets"
  if [ -d "$SCRIPT_DIR/assets" ] && compgen -G "$SCRIPT_DIR/assets/*" >/dev/null; then
    install -d -o "$TARGET_USER" -g "$TARGET_USER" "$assets"
    cp "$SCRIPT_DIR"/assets/* "$assets/"
    chown -R "$TARGET_USER:$TARGET_USER" "$assets"
  fi
  # pick the animation: $ANI_FILE, else first asset present
  if [ -z "$ANI_FILE" ] && [ -d "$assets" ]; then
    ANI_FILE="$(cd "$assets" && ls -1 2>/dev/null | head -n1)"
  fi
  [ -n "$ANI_FILE" ] || warn "no anifetch asset found — put a .gif/.mp4 in $SCRIPT_DIR/assets or run: ANI_FILE=x.mp4 $0 fetch shell"
}

# --- motd (distillium) --------------------------------------------------
motd_install() {
  log "distillium/motd"
  apt-get install -y toilet toilet-fonts
  run_remote https://raw.githubusercontent.com/distillium/motd/main/install-motd.sh
  # configure later with: motd-set   |  render manually: motd
}

# --- github ssh key -----------------------------------------------------
ssh_key() {
  local dir="$TARGET_HOME/.ssh" key="$TARGET_HOME/.ssh/id_ed25519"
  install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$dir"

  if [ -f "$key" ]; then
    log "ssh key exists: $key"
  else
    log "generating ed25519 key for github"
    # no passphrase: unattended git pulls / deploy keys. Add one with `ssh-keygen -p -f $key`.
    as_user ssh-keygen -t ed25519 -C "$TARGET_USER@$(hostname -s)" -f "$key" -N "" -q
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

  # only if you told us who you are:  GIT_NAME="x" GIT_EMAIL="y" sudo -E ./setup.sh ssh
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
  # service: wg-quick@warp   | uninstall: run_remote .../uninstall.sh
}

# --- remnawave CLI wrappers ---------------------------------------------
remnawave_install() {
  log "DigneZzZ/remnawave-scripts (CLI wrappers only)"
  local base=https://github.com/DigneZzZ/remnawave-scripts/raw/main s
  for s in remnawave remnanode selfsteal wtm; do
    curl -fsSL "$base/$s.sh" -o "/usr/local/bin/$s" && chmod 755 "/usr/local/bin/$s" \
      && echo "  installed /usr/local/bin/$s" || warn "failed to fetch $s.sh"
  done
  warn "wrappers only — nothing deployed. Run the actual install yourself, e.g. 'remnanode install' (interactive, asks for ports/keys)."
}

# --- shell shortcuts ----------------------------------------------------
shell_install() {
  log "shortcuts -> /etc/profile.d/99-vps-set.sh"
  # NOTE: not aliasing `ip` — that's iproute2's binary. Shortcut is `myip`.
  printf '%s\n' "ANIFETCH_FILE=\"${ANI_FILE:-}\"" > /etc/profile.d/99-vps-set.sh
  cat >> /etc/profile.d/99-vps-set.sh <<'EOF'
# --- vps-set shortcuts ---
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
export PATH

# public IPv4 of this server; `myip -l` for local interface addresses
myip() {
  if [ "${1:-}" = "-l" ]; then
    ip -4 -o addr show scope global | awk '{print $2": "$4}'
  else
    curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null \
      || curl -4 -fsS --max-time 5 https://api.ipify.org \
      || ip -4 -o addr show scope global | awk 'NR==1{sub(/\/.*/,"",$4); print $4}'
    echo
  fi
}
myip6() { curl -6 -fsS --max-time 5 https://ifconfig.me 2>/dev/null; echo; }

ports()  { ss -tulpn; }
update() { sudo apt-get update && sudo apt-get -y upgrade; }
ff()     { command -v neofetch >/dev/null && neofetch "$@" || fastfetch "$@"; }

alias d='docker'
alias dc='docker compose'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'
alias dlog='docker logs -f --tail 100'
alias ll='ls -alFh'
alias ..='cd ..'
alias ...='cd ../..'
alias df='df -hT -x tmpfs -x devtmpfs'
alias free='free -h'

# animated neofetch
ani() {
  [ -n "$ANIFETCH_FILE" ] || { echo "set ANIFETCH_FILE in /etc/profile.d/99-vps-set.sh"; return 1; }
  anifetch "$ANIFETCH_FILE" -r 10 -W 60 -H 30 -c "--symbols wide --fg-only" "$@"
}
EOF
  chmod 644 /etc/profile.d/99-vps-set.sh
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
  have neofetch || have fastfetch || { echo "  MISS neofetch/fastfetch"; rc=1; }
  [ -x "$TARGET_HOME/.local/bin/anifetch" ] || { printf '  \033[31mMISS\033[0m anifetch\n'; rc=1; }
  [ -f /etc/profile.d/99-vps-set.sh ] || { printf '  \033[31mMISS\033[0m shortcuts\n'; rc=1; }
  [ -f /etc/update-motd.d/00-dist-motd ] || { printf '  \033[31mMISS\033[0m motd\n'; rc=1; }
  [ -f "$TARGET_HOME/.ssh/id_ed25519.pub" ] || { printf '  \033[31mMISS\033[0m github ssh key\n'; rc=1; }
  # opt-in sections: reported, never counted as failures
  systemctl is-active --quiet wg-quick@warp && echo "  ok   warp        active" || echo "  --   warp        not installed/inactive"
  [ -x /usr/local/bin/remnanode ] && echo "  ok   remnawave   CLIs present" || echo "  --   remnawave   not installed"
  return $rc
}

# --- main ---------------------------------------------------------------
run() {
  case "$1" in
    base)   base ;;
    docker) docker_install ;;
    python) python_install ;;
    fetch)  fetch_install ;;
    motd)   motd_install ;;
    shell)  shell_install ;;
    ssh)    ssh_key ;;
    warp)   warp_install ;;
    remnawave) remnawave_install ;;
    verify) verify ;;
    *) echo "unknown section: $1 (base docker python fetch motd shell ssh warp remnawave verify)"; exit 1 ;;
  esac
}

if [ $# -eq 0 ]; then
  for s in base docker python fetch motd shell ssh; do run "$s"; done
  verify || warn "some checks failed"
  log "done — re-login (or: source /etc/profile.d/99-vps-set.sh) to get the shortcuts"
else
  for s in "$@"; do run "$s"; done
fi
