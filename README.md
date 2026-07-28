# setup

Один скрипт для первичной настройки VPS. Ubuntu 22.04/24.04, Debian 12. Идемпотентный — можно гонять повторно.

## Быстрый сетап

```bash
git clone git@github.com:wakeupmetha/setup.git && cd setup && chmod +x setup.sh && sudo ./setup.sh
```

SSH-клон требует ключа, уже добавленного в GitHub. На свежем сервере ключа ещё нет — либо сначала `sudo ./setup.sh ssh` (см. ниже), либо забирай по HTTPS:

```bash
git clone https://github.com/wakeupmetha/setup.git && cd setup && chmod +x setup.sh && sudo ./setup.sh
```

Без клона (тогда не подхватятся гифки из `assets/`):

```bash
curl -fsSL https://raw.githubusercontent.com/wakeupmetha/setup/main/setup.sh -o /tmp/setup.sh && sudo bash /tmp/setup.sh
```

## Использование

```bash
sudo ./setup.sh                 # дефолтный набор
sudo ./setup.sh docker shell    # только эти секции
sudo ./setup.sh verify          # что стоит, чего нет
```

После первого прогона — перелогиниться (или `source /etc/profile.d/99-vps-set.sh`), чтобы подхватились шорткаты и группа `docker`.

## Секции

| Секция | Дефолт | Что делает |
|---|---|---|
| `base` | да | `apt update && upgrade`, curl/wget/git/htop/tmux/jq/unzip/rsync/tree/ncdu, net-tools/dnsutils/mtr/nmap, build-essential, ufw, fail2ban |
| `docker` | да | docker-ce + cli + containerd + buildx + compose-plugin из официального репозитория, `systemctl enable --now docker`, добавляет юзера в группу `docker` |
| `python` | да | python3, venv, pip, dev-headers, pipx + `pipx ensurepath` |
| `fetch` | да | neofetch (fallback → fastfetch), chafa, ffmpeg, `pipx install anifetch`, копирует `assets/*` в `~/.local/share/anifetch/assets` |
| `motd` | да | `toilet` + `toilet-fonts`, ставит [distillium/motd](https://github.com/distillium/motd) |
| `shell` | да | пишет `/etc/profile.d/99-vps-set.sh` — шорткаты для всех юзеров |
| `ssh` | да | ed25519-ключ для GitHub, `~/.ssh/config`, пин хост-ключей github.com, печатает pubkey |
| `warp` | **нет** | [distillium/warp-native](https://github.com/distillium/warp-native) — Cloudflare WARP через WireGuard |
| `remnawave` | **нет** | CLI-обёртки [DigneZzZ/remnawave-scripts](https://github.com/DigneZzZ/remnawave-scripts) в `/usr/local/bin` |
| `verify` | — | проверка всего установленного, ненулевой exit если чего-то не хватает |

### Шорткаты (`shell`)

| Команда | Что |
|---|---|
| `myip` | публичный IPv4 (ifconfig.me → ipify → локальный интерфейс) |
| `myip -l` | адреса локальных интерфейсов |
| `myip6` | публичный IPv6 |
| `ports` | `ss -tulpn` |
| `update` | `apt update && apt upgrade` |
| `ff` | neofetch (или fastfetch) |
| `ani` | anifetch с гифкой из `assets/` |
| `d` `dc` `dps` `dlog` | docker / docker compose / ps в таблицу / logs -f |
| `ll` `..` `...` `df` `free` | обычные удобства |

`ip` намеренно **не** переопределён — это бинарник iproute2, его перекрытие ломает систему (включая сам motd).

### Анимация для `ani` (`fetch`)

Положи `.gif` / `.mp4` в `assets/` до запуска — первый файл станет анимацией по умолчанию. Явно:

```bash
ANI_FILE=shadow.mp4 sudo -E ./setup.sh fetch shell
```

Поменять потом — правь `ANIFETCH_FILE` в `/etc/profile.d/99-vps-set.sh`.

### GitHub-ключ (`ssh`)

Ключ генерится **без пароля** — иначе не работают unattended `git pull`. Добавить пароль: `ssh-keygen -p -f ~/.ssh/id_ed25519`.

Скрипт печатает фингерпринты хост-ключей github.com — сверь их с [официальным списком](https://docs.github.com/en/authentication/keeping-your-account-secure/githubs-ssh-key-fingerprints), `ssh-keyscan` сам по себе ничего не проверяет.

Имя/почта для git (опционально):

```bash
GIT_NAME="Имя" GIT_EMAIL="mail@example.com" sudo -E ./setup.sh ssh
```

Дальше: добавить pubkey на https://github.com/settings/ssh/new и проверить `ssh -T git@github.com`.

### WARP (`warp`)

```bash
sudo ./setup.sh warp
```

Меняет маршрутизацию, поэтому не в дефолтном наборе. Сервис — `wg-quick@warp` (`systemctl status|restart wg-quick@warp`). Снести:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/uninstall.sh)
```

### Remnawave (`remnawave`)

```bash
sudo ./setup.sh remnawave
```

Кладёт в `/usr/local/bin` только команды `remnawave`, `remnanode`, `selfsteal`, `wtm`. **Ничего не разворачивает** — панель/нода ставятся интерактивно вручную, там вопросы про домены, порты и ключи:

```bash
remnanode install
```

## Чего скрипт не делает

- Не включает `ufw` — включение вслепую по SSH отрезает доступ к серверу. Пакет ставится, правила и `ufw enable` за тобой.
- Не трогает конфиг sshd (порт, отключение парольного входа) и не настраивает swap.
- Сторонние инсталляторы (motd, warp) скачиваются во временный файл, путь печатается перед запуском — можно прервать и посмотреть.
