#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Nourax
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Simulator steps of the CI screenshot job (.github/workflows/ios.yml, job "screens").
# Runs on the macOS runner only. No signing, no secrets, no contact with the real drive.nourax.org.
#
#   screens.sh check-tools <out-dir>        print and check every simctl/xcodebuild option used here
#   screens.sh make-certs <dir>             throw-away CI root + certificate for drive.nourax.org
#   screens.sh capture-start <results-dir>  DNS capture on all interfaces (tcpdump -i pktap,all)
#   screens.sh capture-stop <results-dir>   stop it, write dns.txt (and dns-processes.txt)
#   screens.sh device                       UDID of "iPhone 17" with iOS $IOS_VERSION (default 27.0)
#   screens.sh prepare-first <udid>         erase and boot once, trust $CA_CER (the CI root), let it settle
#   screens.sh switch <udid> <lang> <locale> <light|dark>
#        remove NoDrive and the test runner (fresh permissions), set the system language
#        (reboot), appearance and a fixed status bar
#   screens.sh launch <udid> <NoDrive.app> <shots-dir> <results-dir>
#        simctl install + launch, screenshots, check that the app keeps running
#   screens.sh walk <udid> <variant> <lang> <locale>
#        the UI test walk (needs XCTESTRUN, SHOTS, RESULTS; SIGN_IN=1 taps "Log in")
set -euo pipefail

APP_ID=org.nourax.nodrive

need() {   # need <help-file> <text>...: fail when an option is not in the tool's own help
  local file=$1; shift
  for text in "$@"; do
    if grep -q -- "$text" "$file"; then echo "ok   $text  ($(basename "$file"))"; else echo "MISSING $text in $(basename "$file")"; return 1; fi
  done
}

check_tools() {
  local out=$1
  mkdir -p "$out"
  for sub in erase boot bootstatus shutdown keychain ui status_bar install uninstall privacy get_app_container launch terminate io spawn list; do
    xcrun simctl help "$sub" > "$out/simctl-$sub.txt" 2>&1 || true
  done
  need "$out/simctl-keychain.txt" add-root-cert
  need "$out/simctl-ui.txt" appearance
  need "$out/simctl-status_bar.txt" override --time --batteryState --batteryLevel --cellularBars --wifiBars
  need "$out/simctl-io.txt" screenshot --type
  grep -q -- "recordVideo" "$out/simctl-io.txt" && echo "ok   recordVideo (launch-screen frames; optional)" || echo "note: no recordVideo"
  grep -q -- "--codec" "$out/simctl-io.txt" && echo "ok   --codec" || echo "note: no --codec"
  need "$out/simctl-bootstatus.txt" -b
  need "$out/simctl-privacy.txt" reset
  need "$out/simctl-get_app_container.txt" data
  need "$out/simctl-launch.txt" launch
  need "$out/simctl-list.txt" -j
  xcodebuild -help > "$out/xcodebuild-help.txt" 2>&1 || true
  need "$out/xcodebuild-help.txt" -xctestrun -only-testing -parallel-testing-enabled -resultBundlePath -destination
  xcrun xcresulttool help export attachments > "$out/xcresulttool-export-attachments.txt" 2>&1 || true
  need "$out/xcresulttool-export-attachments.txt" --path --output-path
  tcpdump --version > "$out/tcpdump-version.txt" 2>&1 || true
  head -n 2 "$out/tcpdump-version.txt"
  security verify-cert -h > "$out/security-verify-cert.txt" 2>&1 || true
  sample > "$out/sample-usage.txt" 2>&1 || true   # diagnostics only (walk), so report, do not fail
  grep -q -- "-file" "$out/sample-usage.txt" && echo "ok   sample -file" || echo "note: sample has no -file option"
  command -v pgrep
  openssl version
}

make_certs() {
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/ca.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = NoDrive CI stand-in root (throw-away)
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF
  cat > "$dir/leaf.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = drive.nourax.org
EOF
  cat > "$dir/leaf.ext" <<'EOF'
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:drive.nourax.org
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 30 -keyout "$dir/ca.key" -out "$dir/ca.pem" \
    -config "$dir/ca.cnf" -extensions v3_ca
  openssl req -new -newkey rsa:2048 -nodes -keyout "$dir/leaf.key" -out "$dir/leaf.csr" -config "$dir/leaf.cnf"
  openssl x509 -req -in "$dir/leaf.csr" -CA "$dir/ca.pem" -CAkey "$dir/ca.key" -CAcreateserial -sha256 -days 30 \
    -extfile "$dir/leaf.ext" -out "$dir/leaf.pem"
  cat "$dir/leaf.pem" "$dir/ca.pem" > "$dir/chain.pem"
  openssl x509 -in "$dir/ca.pem" -outform der -out "$dir/ca.cer"
  rm -f "$dir/ca.key" "$dir/leaf.csr"   # the root can sign nothing else after this
  openssl verify -CAfile "$dir/ca.pem" "$dir/leaf.pem"
  openssl x509 -in "$dir/leaf.pem" -noout -subject -enddate -ext subjectAltName,extendedKeyUsage 2>/dev/null \
    || openssl x509 -in "$dir/leaf.pem" -noout -subject -enddate
}

capture_start() {
  local res=$1
  mkdir -p "$res"
  sudo nohup tcpdump -i pktap,all -n -U -w "$res/dns.pcapng" 'udp port 53 or tcp port 53' > "$res/tcpdump.out" 2>&1 &
  sleep 3
  if ! pgrep -x tcpdump > /dev/null; then
    local iface
    iface=$(route -n get default | awk '/interface:/ {print $2}')
    echo "pktap capture did not start ($(tr '\n' ' ' < "$res/tcpdump.out")); capturing on $iface"
    sudo nohup tcpdump -i "$iface" -n -U -w "$res/dns.pcapng" 'udp port 53 or tcp port 53' > "$res/tcpdump.out" 2>&1 &
    sleep 3
    pgrep -x tcpdump > /dev/null
  fi
  echo "tcpdump running: $(pgrep -x tcpdump | tr '\n' ' ')"
  scutil --dns | grep -m 3 nameserver || true
  dig +short www.apple.com | head -n 2   # control lookup; the gate looks for it in the capture
}

capture_stop() {
  local res=$1
  sudo pkill -INT -x tcpdump || true
  sleep 3
  sudo chmod a+r "$res/dns.pcapng"
  tcpdump -n -r "$res/dns.pcapng" > "$res/dns.txt" 2> "$res/dns-read.err" || true
  tcpdump -n -k -r "$res/dns.pcapng" > "$res/dns-processes.txt" 2>/dev/null || true
  echo "DNS packets: $(wc -l < "$res/dns.txt")"
  cat "$res/tcpdump.out" || true
}

device() {
  xcrun simctl list devices available -j | python3 -c '
import json, sys
want = "iOS-" + sys.argv[1].replace(".", "-")
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if runtime.endswith(want):
        for d in devices:
            if d["name"] == "iPhone 17":
                print(d["udid"])
                sys.exit(0)
sys.exit("no available iPhone 17 simulator with " + want)
' "${IOS_VERSION:-27.0}"
}

boot_wait() {
  xcrun simctl boot "$1" 2>/dev/null || true
  xcrun simctl bootstatus "$1" -b > /dev/null
}

prepare_first() {   # once per job: a clean simulator that trusts the CI root
  local udid=$1
  xcrun simctl shutdown "$udid" > /dev/null 2>&1 || true
  xcrun simctl erase "$udid"
  boot_wait "$udid"
  xcrun simctl keychain "$udid" add-root-cert "$CA_CER"
  sleep 45   # the first boot after an erase keeps the simulator busy for a while
  echo "prepared $udid (erased, CI root trusted)"
}

mac_cpu() {   # busy share of all CPUs (user + sys, %), from the second of two top samples
  top -l 2 -n 0 -s 1 | awk '/^CPU usage/ { u = $3; s = $5 } END { printf "%d", u + s }'
}

settle_cpu() {   # after a boot the simulator is busy for a while; NextcloudKit's background-QoS
  # reply queue starves under that load. Wait (up to about 180 s) for 3 calm readings in a row.
  local calm=0 reading=0 waited=0
  while [ "$waited" -lt 180 ]; do
    reading=$(mac_cpu)
    if [ "$reading" -lt 45 ]; then calm=$((calm + 1)); else calm=0; fi
    if [ "$calm" -ge 3 ]; then echo "simulator settled after ${waited} s (Mac CPU ${reading} %)"; return 0; fi
    sleep 4
    waited=$((waited + 6))
  done
  echo "still busy after ${waited} s (Mac CPU ${reading} %); top processes:"
  top -l 2 -n 8 -o cpu -stats pid,command,cpu | tail -n 9
}

switch() {   # per variant, without an erase (much faster than a first boot)
  local udid=$1 lang=$2 locale=$3 appearance=$4
  xcrun simctl terminate "$udid" com.apple.mobileslideshow > /dev/null 2>&1 || true
  for app in "$APP_ID" "$APP_ID.ui-tests.xctrunner"; do
    xcrun simctl uninstall "$udid" "$app" > /dev/null 2>&1 || true
    xcrun simctl privacy "$udid" reset all "$app" > /dev/null 2>&1 || true
  done
  xcrun simctl spawn "$udid" defaults write "Apple Global Domain" AppleLanguages -array "$lang"
  xcrun simctl spawn "$udid" defaults write "Apple Global Domain" AppleLocale -string "$locale"
  xcrun simctl shutdown "$udid"
  boot_wait "$udid"
  xcrun simctl ui "$udid" appearance "$appearance"
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
  settle_cpu
  echo "switched $udid: language $(xcrun simctl spawn "$udid" defaults read "Apple Global Domain" AppleLanguages | tr -d ' \n'), locale $locale, $appearance"
}

alive() {   # alive <pid> <when>
  if ps -p "$1" > /dev/null 2>&1; then
    echo "NoDrive (pid $1) is running $2"
  else
    echo "NoDrive (pid $1) is NOT running $2"
    ls -lt ~/Library/Logs/DiagnosticReports/ 2>/dev/null | head -n 10 || true
    return 1
  fi
}

launch() {
  local udid=$1 app=$2 shots=$3 res=$4 out pid
  mkdir -p "$shots" "$res"
  xcrun simctl install "$udid" "$app"
  echo "installed: $(xcrun simctl get_app_container "$udid" "$APP_ID" app)"
  # The launch screen shows for less time than one simctl screenshot takes, so record the screen
  # around the launch; tools/ci/video-frames.swift cuts frames, the report picks the launch screen.
  xcrun simctl io "$udid" recordVideo --codec=h264 --force "$res/launch.mp4" > "$res/record-video.log" 2>&1 &
  local rec=$!
  for _ in $(seq 1 20); do grep -qi "recording started" "$res/record-video.log" && break; sleep 0.5; done
  out=$(xcrun simctl launch "$udid" "$APP_ID" -AppleLanguages "(en)" -AppleLocale en_US)
  echo "simctl launch: $out"
  pid=${out##*: }
  sleep 7
  kill -INT "$rec" > /dev/null 2>&1 || true
  wait "$rec" 2>/dev/null || true
  xcrun simctl io "$udid" screenshot --type=png "$shots/02-launch-8s.png"
  alive "$pid" "8 s after launch"
  if [ -s "$res/launch.mp4" ]; then
    xcrun swift "$(dirname "$0")/video-frames.swift" "$res/launch.mp4" "$res/launch-frames" 8 0.1 || true
  else
    echo "note: no screen recording ($(tr '\n' ' ' < "$res/record-video.log"))"
  fi
  sleep 5
  xcrun simctl io "$udid" screenshot --type=png "$shots/03-launch-later.png"
  alive "$pid" "at the end (about 30-60 s after launch)"
  xcrun simctl spawn "$udid" launchctl list | grep -F "$APP_ID" || true
  xcrun simctl spawn "$udid" log show --last 2m --style compact --predicate 'process == "Nextcloud"' \
    > "$res/simctl-launch-app.log" 2>&1 || true
  xcrun simctl terminate "$udid" "$APP_ID" || true
}

walk() {
  local udid=$1 variant=$2 lang=$3 locale=$4 status=0
  mkdir -p "$SHOTS/$variant" "$RESULTS"
  # Diagnostics for the sign-in: 25 s after the test taps "Log in" (it writes signin-started),
  # sample the app's threads for 5 s, so a stall between status.php and the Login Flow request
  # shows where the app waits.
  (
    for _ in $(seq 1 900); do [ -f "$SHOTS/$variant/signin-started" ] && break; sleep 1; done
    sleep 25
    top -l 2 -n 15 -o cpu -stats pid,command,cpu,threads > "$RESULTS/ui-$variant-top-25s.txt" 2>&1 || true
    pid=$(pgrep -f '/Nextcloud\.app/Nextcloud( |$)' | head -n 1)
    echo "app pid at sign-in +25 s: ${pid:-none}" >> "$RESULTS/ui-$variant-top-25s.txt"
    if [ -n "$pid" ]; then
      sudo sample "$pid" 5 -file "$RESULTS/ui-$variant-sample-25s.txt" > /dev/null 2>&1 || true
    fi
  ) &
  local watcher=$!
  set +e
  TEST_RUNNER_NODRIVE_LANG="$lang" TEST_RUNNER_NODRIVE_LOCALE="$locale" TEST_RUNNER_NODRIVE_VARIANT="$variant" \
  TEST_RUNNER_NODRIVE_SHOTS_DIR="$SHOTS" TEST_RUNNER_NODRIVE_SIGN_IN="${SIGN_IN:-1}" \
    xcodebuild test-without-building \
      -xctestrun "$XCTESTRUN" \
      -destination "id=$udid" \
      -only-testing:NextcloudUITests/NoDriveScreenshotUITests \
      -parallel-testing-enabled NO \
      -resultBundlePath "$RESULTS/ui-$variant.xcresult" \
      > "$RESULTS/ui-$variant.log" 2>&1
  status=$?
  set -e
  kill "$watcher" > /dev/null 2>&1 || true
  xcbeautify --renderer github-actions < "$RESULTS/ui-$variant.log" || true
  if ! grep -Eq "Executed [1-9][0-9]* tests?" "$RESULTS/ui-$variant.log"; then
    echo "walk $variant: no test ran (check -only-testing and the .xctestrun)"
    status=1
  fi
  # NextcloudKit's own log (request start/end), in the app group: NCPreferences.sharedLogDirectory
  local group
  group=$(xcrun simctl get_app_container "$udid" "$APP_ID" "group.$APP_ID" 2>/dev/null || true)
  if [ -n "$group" ] && [ -d "$group/Logs" ]; then
    for f in "$group"/Logs/*; do
      [ -f "$f" ] && cp "$f" "$RESULTS/ui-$variant-nextcloudkit-$(basename "$f")"
    done
  else
    echo "walk $variant: no NextcloudKit log folder in the app group ($group)"
  fi
  xcrun xcresulttool get test-results summary --path "$RESULTS/ui-$variant.xcresult" \
    > "$RESULTS/ui-$variant-summary.json" 2>/dev/null || true
  xcrun simctl spawn "$udid" log show --last 6m --style compact \
    --predicate 'process == "Nextcloud" OR process == "Share"' 2>/dev/null | tail -n 4000 > "$RESULTS/ui-$variant-app.log" || true
  echo "walk $variant: xcodebuild exit $status; files: $(ls "$SHOTS/$variant" | tr '\n' ' ')"
  return $status
}

cmd=${1:-}; shift || true
case "$cmd" in
  check-tools) check_tools "$@" ;;
  make-certs) make_certs "$@" ;;
  capture-start) capture_start "$@" ;;
  capture-stop) capture_stop "$@" ;;
  device) device ;;
  prepare-first) prepare_first "$@" ;;
  switch) switch "$@" ;;
  launch) launch "$@" ;;
  walk) walk "$@" ;;
  *) echo "usage: see the header of $0" >&2; exit 2 ;;
esac
