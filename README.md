# setup

Один скрипт для первичной настройки VPS. Ubuntu 22.04/24.04, Debian 12. Идемпотентный — можно гонять повторно.

## Быстрый сетап

Одна команда, работает и на голом сервере, и когда `~/setup` уже склонирован:

```bash
git clone https://github.com/wakeupmetha/setup.git ~/setup 2>/dev/null; cd ~/setup && git pull --ff-only && sudo ./setup.sh
```

HTTPS, потому что на свежем сервере ключа в GitHub ещё нет — его как раз генерит секция `ssh`. После того как добавишь ключ, можно переключить:

```bash
git remote set-url origin git@github.com:wakeupmetha/setup.git
```

## meth-setup

После первого прогона появляется команда `meth-setup` — она сама подтягивает репозиторий и перезапускает скрипт, из любой директории, без `cd` и `git pull`:

```bash
meth-setup                # обновиться и прогнать дефолтный набор
meth-setup node           # только проверка ноды
meth-setup firewall sshd  # пересобрать правила
meth-setup --help         # список секций
```

Если в локальной копии есть несохранённые правки, `meth-setup` не будет их затирать — скажет об этом и запустит версию с диска.

## Использование

```bash
sudo ./setup.sh                 # дефолтный набор
sudo ./setup.sh docker shell    # только эти секции
sudo ./setup.sh verify          # что стоит, чего нет
```

После первого прогона — перелогиниться (или `source /etc/profile.d/99-vps-set.sh`), чтобы подхватились шорткаты и группа `docker`.

Вывод apt не сыпется в терминал — только прогресс-бар, всё остальное пишется в `/var/log/vps-set.log`. При падении шага скрипт сам печатает последние 20 строк лога. Смотреть установку вживую:

```bash
VERBOSE=1 sudo -E ./setup.sh
```

Интерактивные сторонние установщики (motd, warp) под бар не заворачиваются — им нужен терминал для своих вопросов.

### Переменные окружения

| Переменная | Что |
|---|---|
| `SSH_EMAIL` | комментарий (почта) на GitHub-ключе; если не задана — спросит |
| `GIT_NAME`, `GIT_EMAIL` | `git config --global user.name/user.email` |
| `ANI_FILE` | какую гифку крутить в `ani` |
| `PANEL_HOST` | хост панели: полный доступ + единственный источник для node API (`main-land.meth.ee`) |
| `NODE_API_PORT` | порт node API, открывается только панели (`3000`) |
| `NODE_PUBLIC_PORTS` | доп. VLESS-инбаунды сверх 80/443/2525, например `"8443 2053"` |
| `NODE_UDP_PORTS` | udp-инбаунды (XHTTP/h3/hysteria), по умолчанию пусто |
| `SELFSTEAL_PORT` | порт декоя caddy, проверяется на утечку и никогда не открывается (`9443`) |
| `UFW_YES=1` | включить ufw без подтверждения (для неинтерактивных прогонов) |
| `VERBOSE=1` | полный вывод вместо прогресс-бара |
| `LOGFILE` | куда писать лог (по умолчанию `/var/log/vps-set.log`) |

С `sudo` передавай через `-E`: `SSH_EMAIL=me@mail.com sudo -E ./setup.sh ssh`

## Секции

| Секция | Дефолт | Что делает |
|---|---|---|
| `base` | да | `apt update && upgrade`, curl/wget/git/htop/tmux/jq/unzip/rsync/tree/ncdu, net-tools/dnsutils/mtr/nmap, build-essential, ufw, fail2ban |
| `docker` | да | docker-ce + cli + containerd + buildx + compose-plugin из официального репозитория, `systemctl enable --now docker`, добавляет юзера в группу `docker` |
| `python` | да | python3, venv, pip, dev-headers, pipx + `pipx ensurepath` |
| `fetch` | да | fastfetch + панель входа, chafa, ffmpeg (`--no-install-recommends`, иначе тянет ~100 МБ mesa/gtk/vulkan, бесполезных на headless), `pipx install anifetch-cli`, копирует медиа из `assets/` |
| `speedtest` | да | [cloudflare-speed-cli](https://github.com/kavehtehrani/cloudflare-speed-cli) — статический musl-бинарь из релизов в `/usr/local/bin`, с проверкой sha256 |
| `motd` | да | `toilet` + `toilet-fonts`, ставит [distillium/motd](https://github.com/distillium/motd) |
| `shell` | да | `/etc/profile.d/99-vps-set.sh` — шорткаты для всех юзеров, плюс команда `meth-setup` |
| `ssh` | да | ed25519-ключ для GitHub с почтой в комментарии, `~/.ssh/config`, пин хост-ключей github.com, печатает pubkey |
| `firewall` | да | ufw под ноду: deny incoming/routed, 22 (limit) + 80/443/2525, node API только с IP панели, ufw-docker, суточный таймер резолва панели |
| `sshd` | да, последней | вход только по ключам (`PasswordAuthentication no`), `PermitRootLogin prohibit-password`, fail2ban jail на порты живого sshd |
| `node` | **нет** | проверка VLESS-пути после деплоя ноды: контейнеры, слушающие порты vs ufw, утечка декоя |
| `crowdsec` | **нет** | crowdsec + iptables-bouncer, блоклисты сканеров |
| `warp` | **нет** | [distillium/warp-native](https://github.com/distillium/warp-native) — Cloudflare WARP через WireGuard |
| `remnawave` | **нет** | CLI-обёртки [DigneZzZ/remnawave-scripts](https://github.com/DigneZzZ/remnawave-scripts) в `/usr/local/bin` |
| `verify` | — | проверка всего установленного, ненулевой exit если чего-то не хватает |

### Шорткаты (`shell`)

| Команда | Что |
|---|---|
| `ip` | публичный IPv4 + IPv6 сервера |
| `ip a`, `ip route`, `ip -6 addr …` | обычный iproute2, как был |
| `ipv6` / `ipv6 off` / `ipv6 on` | статус / выключить / включить IPv6 (sysctl, переживает ребут) |
| `ani` | anifetch с гифкой из `assets/` |
| `ff` | neofetch (или fastfetch) |
| `speedtest` | `cloudflare-speed-cli` — замер скорости через speed.cloudflare.com |
| `ports` | `ss -tulpn` |
| `update` | `apt update && apt upgrade` |
| `d` `dc` `dps` `dlog` | docker / docker compose / ps в таблицу / logs -f |
| `ll` `..` `...` `df` `free` | обычные удобства |

**Про `ip`.** Это функция, а не алиас: без аргументов показывает внешние адреса, с любым аргументом уходит в `command ip "$@"`. То есть `ip a`, `ip route`, `ip link set …` работают как раньше. Скрипты и systemd-юниты вообще не задеты — функции из `/etc/profile.d` видны только интерактивным шеллам, motd и прочее продолжают звать настоящий бинарник.

`ipv6 off` откажется работать, если ты сам подключён по IPv6 (иначе разорвёт сессию) — проверяется `$SSH_CONNECTION`. Продавить: `ipv6 off -f`. Выключение пишется в `/etc/sysctl.d/99-disable-ipv6.conf`, `ipv6 on` его удаляет.

### Панель входа (`fetch`)

Справа от анимации `ani` рисуется fastfetch с конфигом под сервер. Он же выводится по `ff`.

```
os      Ubuntu 24.04.3 LTS x86_64      docker  6 running / 8 total
kernel  6.8.0-136-generic              node    remnanode up
up      12 days, 4 hours               ufw     active, 11 rules
shell   bash 5.2.21                    f2b     3 banned now / 47 total
pkgs    812 (dpkg)                     logins  188.4.2.1   Jul 28 19:02
cpu     AMD EPYC 7443 (4)                      93.72.10.5  Jul 27 08:44
load    0.08 0.11 0.09                 updates 7 pending, 3 security
ram     1.94 GiB / 7.76 GiB (25%)      reboot  REQUIRED - new kernel staged
swap    disabled
disk    18 GiB / 78 GiB (23%)
lan     10.0.0.5
wan     5.181.x.x
geo     Tallinn, EE - AS47583 Hostinger
```

**Почему это не тормозит вход.** Публичный IP, город и счётчик обновлений — сетевые и медленные (`apt-get -s upgrade` ~1 сек). Они считаются раз в сутки таймером `vps-set-fetch-cache.timer` и складываются в `/var/cache/vps-set/fetch.env`, а панель их только читает. Всё остальное локальное и быстрое, команды помечены `parallel` и выполняются одновременно.

```bash
vps-set-fetch-cache                        # обновить кэш руками
systemctl list-timers vps-set-fetch-cache.timer
```

Правится конфиг в `~/.config/fastfetch/config.jsonc` — обычный JSONC, модули документированы в [схеме fastfetch](https://github.com/fastfetch-cli/fastfetch/blob/dev/doc/json_schema.json). `logo: none` стоит намеренно: картинку рисует anifetch, свой ASCII-логотип fastfetch рисовать не должен.

`ufw` и `f2b` требуют root — под обычным юзером в этих строках будет `no access` / `n/a`.

fastfetch в репозиториях Ubuntu появился только в 25.04, поэтому на 24.04 ставится `.deb` из релизов проекта.

### Анимация для `ani` (`fetch`)

Положи `.gif` / `.mp4` в `assets/` до запуска. Если файлов несколько — скрипт покажет меню:

```
Animation for `ani`:
  1) shadow-shadow-the-hedgehog.mp4
  2) playboi-carti.mp4
  3) yeat-twizzyrich.mp4
Choice [1-3, default 1]:
```

Один файл или неинтерактивный запуск — берётся первый, без вопросов. Задать сразу и пропустить меню:

```bash
ANI_FILE=shadow.mp4 sudo -E ./setup.sh fetch shell
```

Поменять потом — правь `ANIFETCH_FILE` в `/etc/profile.d/99-vps-set.sh` или прогони `sudo ./setup.sh fetch shell` ещё раз.

**Если `ani` сыпет `chafa: Unknown file format` на каждом кадре** — это битый кэш кадров от прерванного рендера:

```bash
ani --fresh
```

`-fr` сам по себе тут не спасает: anifetch вызывает ffmpeg **без `-y`**, поэтому уже лежащие кадры не перезаписываются, и повторный рендер молча оставляет мусор. `--fresh` сносит каталоги кэша (хэш-имена, `assets` не трогает) и рендерит с нуля.

### GitHub-ключ (`ssh`)

Комментарий на ключе (то, что GitHub показывает рядом с ним) спрашивается при запуске, либо задаётся заранее:

```bash
SSH_EMAIL=wakeupmetha@icloud.com sudo -E ./setup.sh ssh
```

Если ключ уже есть, он **не** перегенерится — но комментарий перепишется на новый (`ssh-keygen -c`), так что `root@v70139` меняется на почту без удаления ключа и повторного добавления на GitHub.

Ключ генерится **без пароля** — иначе не работают unattended `git pull`. Добавить пароль: `ssh-keygen -p -f ~/.ssh/id_ed25519`.

Скрипт печатает фингерпринты хост-ключей github.com — сверь их с [официальным списком](https://docs.github.com/en/authentication/keeping-your-account-secure/githubs-ssh-key-fingerprints), `ssh-keyscan` сам по себе ничего не проверяет.

Имя/почта для git (опционально):

```bash
GIT_NAME="Имя" GIT_EMAIL="mail@example.com" sudo -E ./setup.sh ssh
```

Дальше: добавить pubkey на https://github.com/settings/ssh/new и проверить `ssh -T git@github.com`.

### Firewall (`firewall`)

Профиль под лёгкую ноду: remnanode + caddy selfsteal, всё в докере. Идёт предпоследней секцией — сначала всё ставится, потом закрывается. Спрашивает три вещи (Enter = дефолт):

```
Panel host [main-land.meth.ee]:
Node API port, panel-only [3000]:
Extra public ports (space separated) [none]:
```

Порядок: база ufw → фикс докера → фиксированные правила → параметризованные → резолв IP панели → таймер.

**Политика**

```
default deny incoming
default allow outgoing
default deny routed
```

**Открыто всем**

| Порт | Зачем |
|---|---|
| порт живого sshd (обычно 22) | `ufw limit` — >6 коннектов за 30 сек и IP улетает в дроп |
| 80/tcp | ACME HTTP-01 / декой по http |
| 443/tcp | **вход юзеров: Xray VLESS Reality** |
| 2525/tcp | remnawave-web-backend, SMTP relay |
| `NODE_PUBLIC_PORTS` | дополнительные VLESS-инбаунды конкретной ноды |
| `NODE_UDP_PORTS` | udp-инбаунды, если используется XHTTP/h3/hysteria |

Порт sshd не хардкожен — берётся из `sshd -T`. Переехал на 2222 — правило поедет за ним, а не отрежет тебя.

```bash
NODE_PUBLIC_PORTS="8443 2053" NODE_UDP_PORTS="443" sudo -E ./setup.sh firewall
```

**Что не открывается:** `SELFSTEAL_PORT` (по умолчанию 9443). Caddy-декой висит на `127.0.0.1:9443`, наружу его светит только Xray через Reality `dest`. Если этот порт станет доступен снаружи — тот же сертификат отвечает на двух портах, и маскировка палится. Скрипт проверяет и ругается, если правило на него откуда-то появилось.

**Только с IP панели**

Node API (`NODE_API_PORT`, у remnanode это `APP_PORT`, по умолчанию 3000) открывается только для `main-land.meth.ee`. IP не хардкодятся: резолвятся при каждом прогоне и **пересинкиваются раз в сутки** через systemd-таймер `vps-set-panel-ip.timer` — панель переедет на другой IP, ноды подхватят сами.

```bash
vps-set-panel-ip                    # синкнуть руками
systemctl list-timers vps-set-panel-ip.timer
cat /etc/vps-set/panel.conf         # PANEL_HOST, NODE_API_PORT
```

Если DNS лежит, скрипт **не трогает существующие правила** — не открывает лишнего и не отрезает панель.

**Docker и почему ufw-docker тут ни при чём**

И `remnanode`, и caddy-selfsteal разворачиваются с `network_mode: host` — свои сокеты они вешают прямо на сетевой стек хоста. Значит их трафик идёт обычной цепочкой INPUT, и правила ufw выше на них работают **напрямую**. `ufw-docker allow remnanode 443/tcp` не нужен и не сработает: у host-контейнера нет bridge-IP, с которым ufw-docker умеет работать.

[ufw-docker](https://github.com/chaifeng/ufw-docker) всё равно ставится — он закрывает **все остальные** контейнеры на машине. Любой обычный `-p 5432:5432` пишет ACCEPT прямо в FORWARD и торчит наружу мимо ufw (ровно случай `cryptobot_db:5432`). Скрипт проходит по запущенным контейнерам: host-режим помечает как «уже покрыто», у bridge-контейнеров **читает реально опубликованные порты** из `docker inspect` и разрешает именно их, ничего не угадывая.

По той же причине `deny routed` не ломает Xray: host-сеть не задействует FORWARD вообще, а Xray проксирует на уровне приложения — входящее в INPUT, исходящее в OUTPUT под `allow outgoing`.

**Включение**

Перед `ufw enable` печатает список правил и ждёт подтверждения. Неинтерактивно правила добавит, но не включит — для этого `UFW_YES=1`.

ICMP трогать не надо: дефолтный `/etc/ufw/before.rules` уже пропускает echo-request.

### Проверка ноды (`node`)

Запускать **после** разворачивания remnanode/selfsteal — отвечает на вопрос «почему юзеры не подключаются»:

```bash
sudo ./setup.sh node
```

```
  ok   remnanode    running (network=host)
  ok   caddy        running (network=host)

  publicly bound sockets:
    tcp 0.0.0.0:443

  inbound vs ufw:
    ok      443    listening, allowed
    BLOCKED 8443   listening but ufw drops it — ufw allow 8443/tcp

  ok   selfsteal 9443 bound to loopback only
```

Сверяет три вещи: контейнеры подняты и в каком сетевом режиме, каждый публично слушающий сокет имеет правило в ufw, декой не торчит наружу. Самый частый случай — добавил инбаунд в панели, а порт на ноде не открыл: тут он подсветится как `BLOCKED`.

### SSH hardening + fail2ban (`sshd`)

```
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
```

Пишется в `/etc/ssh/sshd_config.d/00-vps-set.conf`. Префикс `00`, а не `99`, намеренно: в sshd выигрывает **первое** вхождение директивы, а облачные образы кладут `50-cloud-init.conf` с `PasswordAuthentication yes` — с 99 наш файл бы просто не сработал.

**Защита от лока:** если ни у root, ни у твоего юзера нет непустого `~/.ssh/authorized_keys` — секция отказывается выключать пароли и говорит об этом. Это не тот ключ, что генерит секция `ssh` (тот для GitHub, исходящий) — нужен именно твой публичный ключ на сервере:

```bash
ssh-copy-id root@<сервер>
```

Конфиг применяется только после `sshd -t`; если проверка падает, файл удаляется и sshd не трогается. После рестарта печатает фактические значения из `sshd -T`.

fail2ban: jail `sshd` с портами из `sshd -T`, `backend = systemd` (в 24.04 без rsyslog нет `/var/log/auth.log`, и на файловом бэкенде jail просто не поднимется), `maxretry 5`, `bantime 1h`.

### CrowdSec (`crowdsec`, opt-in)

```bash
sudo ./setup.sh crowdsec
```

Ставит crowdsec + `crowdsec-firewall-bouncer-iptables` через официальный инсталлятор репозитория. Даёт блоклисты известных сканеров и ботнетов до того, как они доберутся до ноды. С fail2ban не конфликтует, но дублирует его по SSH — если хочешь только crowdsec: `systemctl disable --now fail2ban`.

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

- Не меняет порт sshd и не настраивает swap. Секция `sshd` только выключает пароли; переезд на другой порт — руками, после чего прогони `firewall` заново, чтобы правило поехало следом.
- Не разворачивает саму ноду. `remnawave` кладёт только CLI, деплой — `remnanode install` вручную, после него `sudo ./setup.sh node` для проверки.
- Сторонние инсталляторы (motd, warp) скачиваются во временный файл, путь печатается перед запуском — можно прервать и посмотреть.
