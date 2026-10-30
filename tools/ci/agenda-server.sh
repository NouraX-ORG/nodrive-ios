#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
#
# CI only (ubuntu runner). A throwaway Nextcloud 35 in Docker, never drive.nourax.org, with the calendar, tasks,
# Deck and nc_gantt 2.4.1 apps installed from their pinned releases (SHA-256 checked), for the NoAgenda checks.
#   start      create the server and its users (admin, mara, ali, sara, olaf); an app password for each. Values are
#              random, masked in the log, written to build/agenda-server/server.env (0600) and exported to
#              $GITHUB_ENV; they are never printed.
#   apps       download the four apps, check every SHA-256, install and enable them.
#   discover   print what the pinned nc_gantt exposes (routes and request fields of its controllers), for the seed.
#   seed       tools/ci/agenda-seed.py
#   check      tools/ci/server_agenda_check.py (auth proof, the app's own request bodies, the contract)
#   snapshot   tools/ci/agenda-snapshot.py (the real answers the app reads, per user, no secret)
#   stop       remove the container.
set -euo pipefail

IMAGE="nextcloud:35.0.2-apache@sha256:89af7ee7a96ff5e9668280566209268ae6b2d02327f6ef6d56f6d68228cf9431"
NAME="nodrive-ci-agenda"
PORT="${NODRIVE_AGENDA_PORT:-8081}"
OUT="build/agenda-server"
APPS_DIR="$OUT/apps"

# name | url | sha256 | folder inside the archive
APPS=(
  "nc_gantt|https://codeberg.org/fds2610/NC-Gantt/releases/download/v2.4.1-9a09070/nc_gantt-2.4.1-9a09070.tar.gz|9003904a4398f94f1870cc93e6a129d6c7e72298de05b3c5d0104efa976bcfb9"
  "deck|https://github.com/nextcloud-releases/deck/releases/download/v1.19.1/deck-v1.19.1.tar.gz|382e11139ee399444bdfa17f018aa9109376928f9bd36090ead8ea340b4d3f0e"
  "calendar|https://github.com/nextcloud-releases/calendar/releases/download/v6.6.4/calendar-v6.6.4.tar.gz|0557b6b5852a467cf3f746e59d56478d227f78bf7a66357b30dfc10cae4c7e3c"
  "tasks|https://github.com/nextcloud/tasks/releases/download/v0.18.1/tasks.tar.gz|0c988d50531c9bfa246e6c31f3f95369adde1629ba70d15194915ab56e24687b"
)
USERS=(mara ali sara olaf)

occ() { docker exec -u www-data "$NAME" php occ "$@"; }

start() {
    mkdir -p "$OUT"
    local admin_pw
    admin_pw=$(openssl rand -hex 16)
    echo "::add-mask::$admin_pw"
    docker rm -f "$NAME" > /dev/null 2>&1 || true
    docker run -d --name "$NAME" -p "$PORT:80" \
        -e SQLITE_DATABASE=nc -e NEXTCLOUD_ADMIN_USER=ciadmin -e "NEXTCLOUD_ADMIN_PASSWORD=$admin_pw" \
        -e NEXTCLOUD_TRUSTED_DOMAINS="localhost" "$IMAGE" > /dev/null
    local ok=""
    for _ in $(seq 1 120); do
        if curl -fsS "http://localhost:$PORT/status.php" 2> /dev/null | grep -q '"installed":true'; then ok=1; break; fi
        sleep 3
    done
    if [ -z "$ok" ]; then docker logs "$NAME" 2>&1 | tail -n 30; echo "server did not come up"; exit 1; fi
    curl -fsS "http://localhost:$PORT/status.php" | tee "$OUT/status.json"; echo
    grep -q '"versionstring":"35.0.2"' "$OUT/status.json"
    occ app:disable firstrunwizard > /dev/null || true

    local envfile="$OUT/server.env"
    ( umask 077; echo "NODRIVE_AGENDA_PORT=$PORT" > "$envfile"; echo "NODRIVE_AGENDA_ADMIN_PW=$admin_pw" >> "$envfile" )
    local user pw token
    for user in "${USERS[@]}"; do
        pw=$(openssl rand -hex 16)
        echo "::add-mask::$pw"
        docker exec -u www-data -e OC_PASS="$pw" "$NAME" php occ user:add --password-from-env --display-name "$(tr '[:lower:]' '[:upper:]' <<< "${user:0:1}")${user:1}" "$user" > /dev/null
        token=$(docker exec -u www-data -e NC_PASS="$pw" "$NAME" php occ user:auth-tokens:add --password-from-env --name nodrive-ci "$user" | tail -n 1 | tr -d '\r')
        echo "::add-mask::$token"
        [ ${#token} -ge 32 ] || { echo "app password for $user failed"; exit 1; }
        ( umask 077; echo "NODRIVE_AGENDA_PW_${user^^}=$token" >> "$envfile" )
    done
    if [ -n "${GITHUB_ENV:-}" ]; then cat "$envfile" >> "$GITHUB_ENV"; fi
    echo "server up on port $PORT, users: ${USERS[*]} (app passwords created, values masked)"
}

apps() {
    mkdir -p "$APPS_DIR"
    local entry name url sha file
    for entry in "${APPS[@]}"; do
        IFS='|' read -r name url sha <<< "$entry"
        file="$APPS_DIR/$name.tar.gz"
        curl -fsSL --retry 3 -o "$file" "$url"
        echo "$sha  $file" | sha256sum -c - > /dev/null || { echo "SHA-256 of $name does not match the pin"; exit 1; }
        echo "$name: SHA-256 ok"
        mkdir -p "$APPS_DIR/$name"
        tar -xzf "$file" -C "$APPS_DIR/$name"
        local root
        root=$(find "$APPS_DIR/$name" -mindepth 1 -maxdepth 1 -type d | head -n 1)
        [ "$(basename "$root")" = "$name" ] || { mv "$root" "$APPS_DIR/$name/$name"; root="$APPS_DIR/$name/$name"; }
        docker cp "$root" "$NAME:/var/www/html/apps/$name"
        docker exec "$NAME" chown -R www-data:www-data "/var/www/html/apps/$name"
        occ app:enable "$name"
    done
    occ app:list | grep -E "^  - (nc_gantt|deck|calendar|tasks):" | tee "$OUT/apps.txt"
}

discover() {
    local dir="$APPS_DIR/nc_gantt/nc_gantt"
    {
        echo "== routes"
        sed -n '1,200p' "$dir/appinfo/routes.php"
        echo "== controllers"
        for f in "$dir"/lib/Controller/*.php; do
            echo "-- $(basename "$f")"
            grep -nE "public function |#\[|@param" "$f" | head -n 60
        done
    } > "$OUT/discover.txt" 2>&1
    {
        echo "== create and update signatures"
        local pair file pat
        for pair in "ProjectController.php|public function create" "ProjectController.php|public function update"                     "TaskController.php|public function create" "TaskController.php|public function update"                     "SubProjectController.php|public function create" "ShareController.php|public function create"; do
            file="${pair%%|*}"; pat="${pair#*|}"
            echo "-- $file $pat"
            grep -n -A34 "$pat" "$dir/lib/Controller/$file" | head -n 48
        done
        echo "== task resource rows"
        grep -n "resource_id\|'work'\|\"work\"" "$dir/lib/Service/TaskResourceAssignmentService.php" | head -n 30
        echo "== project and task creation fields"
        grep -n "'title'\|'start_date'\|'end_date'\|'owner_id'" "$dir/lib/Service/ProjectService.php" "$dir/lib/Service/TaskService.php" | head -n 40
    } >> "$OUT/discover.txt" 2>&1
    wc -l "$OUT/discover.txt"
}

case "${1:-}" in
    start) start ;;
    apps) apps ;;
    discover) discover ;;
    seed) python3 tools/ci/agenda-seed.py --container "$NAME" --out "$OUT" ;;
    check) python3 tools/ci/server_agenda_check.py --container "$NAME" --out "$OUT" ;;
    snapshot) python3 tools/ci/agenda-snapshot.py --out "$OUT" ;;
    stop) docker rm -f "$NAME" > /dev/null 2>&1 || true ;;
    *) echo "usage: $0 start|apps|discover|seed|check|snapshot|stop"; exit 2 ;;
esac
