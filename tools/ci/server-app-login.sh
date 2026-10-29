#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
#
# CI only (ubuntu runner). A throwaway Nextcloud server of the same release as drive.nourax.org runs in
# Docker, never drive.nourax.org itself. It proves, on the real server code, that the app's sign-in for the
# in-app web view works: the app sends one request with its app password, the server answers with session
# cookies, and the web view then needs nothing but those cookies (tools/ci/server_login_check.py).
#   start  create the server, one user and two app passwords (with and without a login password; the
#          second kind is what a "Log in with Nourax" user has). Values are random, masked in the log and
#          exported through $GITHUB_ENV (never printed).
#   check  run tools/ci/server_login_check.py against that server (report in build/server-login/).
#   reports run tools/ci/server_reports_check.py (the folder "Problem reports", never replacing a report, the read-only
#          share to nourax-support; report reports.md).
#   stop   remove the container.
set -euo pipefail

IMAGE="nextcloud:35.0.2-apache@sha256:89af7ee7a96ff5e9668280566209268ae6b2d02327f6ef6d56f6d68228cf9431"
NAME="nodrive-ci-server"
PORT="${NODRIVE_WS_PORT:-8080}"
USER_ID="citest"
OUT="build/server-login"

occ() { docker exec -u www-data "$@"; }

start() {
    mkdir -p "$OUT"
    local admin_pw login_pw
    admin_pw=$(openssl rand -hex 16); login_pw=$(openssl rand -hex 16)
    echo "::add-mask::$admin_pw"; echo "::add-mask::$login_pw"

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

    occ "$NAME" php occ app:disable firstrunwizard > /dev/null || true
    occ -e OC_PASS="$login_pw" "$NAME" php occ user:add --password-from-env --display-name "Demo User" "$USER_ID" > /dev/null
    local pw_token sso_token
    pw_token=$(occ -e NC_PASS="$login_pw" "$NAME" php occ user:auth-tokens:add \
        --password-from-env --name nodrive-ci "$USER_ID" | tail -n 1 | tr -d '\r')
    echo "::add-mask::$pw_token"
    sso_token=$(occ "$NAME" php occ -n user:auth-tokens:add --name nodrive-ci-sso "$USER_ID" | tail -n 1 | tr -d '\r')
    echo "::add-mask::$sso_token"
    [ ${#pw_token} -ge 32 ] && [ ${#sso_token} -ge 32 ] || { echo "app password creation failed"; exit 1; }

    local envfile="$OUT/server.env"
    ( umask 077; {
        echo "NODRIVE_WS_PORT=$PORT"
        echo "NODRIVE_WS_USER=$USER_ID"
        echo "NODRIVE_WS_PW_TOKEN=$pw_token"
        echo "NODRIVE_WS_SSO_TOKEN=$sso_token"
        echo "NODRIVE_WS_LOGIN_PASSWORD=$login_pw"
    } > "$envfile" )
    if [ -n "${GITHUB_ENV:-}" ]; then cat "$envfile" >> "$GITHUB_ENV"; fi
    echo "server up on port $PORT, user $USER_ID, two app passwords created (values masked)"
}

case "${1:-}" in
    start) start ;;
    check)
        mkdir -p "$OUT"
        python3 tools/ci/server_login_check.py --container "$NAME" --out "$OUT"
        ;;
    reports)
        mkdir -p "$OUT"
        python3 tools/ci/server_reports_check.py --container "$NAME" --out "$OUT"
        ;;
    stop) docker rm -f "$NAME" > /dev/null 2>&1 || true ;;
    *) echo "usage: $0 start|check|reports|stop"; exit 2 ;;
esac
