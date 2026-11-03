#!/usr/bin/env bash
# =============================================================================
# flash_mcus.sh - Build and flash Kalico firmware to Venom24 MCUs via Katapult
# -----------------------------------------------------------------------------
# Location : ~/printer_data/config/firmware/flash_mcus.sh
# Configs  : one Kconfig per board, same folder (see BOARDS below)
# Method   : Per-board KCONFIG_CONFIG builds (Voron docs, "Automating Klipper
#            MCU Updates"), flashed over USB with Katapult flashtool.py.
#            flashtool asks the running Klipper firmware to reboot into the
#            Katapult bootloader, uploads, verifies, and the board boots the
#            new Klipper. Katapult itself is never modified.
#
# Usage    : ./flash_mcus.sh              check versions, build + flash boards
#                                         that don't match the host (asks first)
#            ./flash_mcus.sh --check      report host vs MCU versions, change nothing
#            ./flash_mcus.sh --force      flash all boards even if versions match
#            ./flash_mcus.sh --only h36   limit to one board (by name below)
#            ./flash_mcus.sh --yes        no confirmation prompts
#
# Requires : ~/klipper (Kalico), ~/katapult (host tools), ~/klippy-env (has
#            pyserial - system python3 does not), Moonraker on localhost.
#
# Safety   : - Refuses to run while printing or paused.
#            - Builds ALL boards before stopping Klipper; a build failure stops
#              the run with nothing flashed.
#            - Restarts Klipper on exit, even after an error.
#            - If a flash fails mid-write the board stays in Katapult (empty
#              app area). Recover by re-running flashtool against the
#              usb-katapult_* device shown in /dev/serial/by-id/.
#
# History  : 2026-11-03  Created from the manual reflash to v2026.11.00-17.
# =============================================================================
set -euo pipefail

# ---- Paths ------------------------------------------------------------------
KLIPPER_DIR="$HOME/klipper"
FLASHTOOL="$HOME/katapult/scripts/flashtool.py"
PY="$HOME/klippy-env/bin/python"
CFG_DIR="$HOME/printer_data/config/firmware"
BUILD_DIR="$HOME/firmware_builds"          # outside config + outside the repo
MOONRAKER="http://localhost"

# ---- Boards -----------------------------------------------------------------
# name | Kconfig file in CFG_DIR | MCU name in printer.cfg | USB device (running Klipper)
BOARDS=(
  "octopus|octopus_pro_h723.config|mcu|/dev/serial/by-id/usb-Klipper_stm32h723xx_37000B000851313339373836-if00"
  "h36|h36_combo.config|H36_combo|/dev/serial/by-id/usb-Klipper_stm32g0b1xx_3D0037000950415742363820-if00"
)

# ---- Options ----------------------------------------------------------------
CHECK_ONLY=false; FORCE=false; ASSUME_YES=false; ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK_ONLY=true ;;
    --force) FORCE=true ;;
    --yes|-y) ASSUME_YES=true ;;
    --only) ONLY="${2:-}"; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# ---- Helpers ----------------------------------------------------------------
info()    { echo "==> $*"; }
die()     { echo "ERROR: $*" >&2; exit 1; }
confirm() { $ASSUME_YES && return 0; read -r -p "$1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }

# moon <path> <python expression on d>  -> prints result, empty on any failure
moon() {
  curl -s --max-time 5 "$MOONRAKER/$1" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print($2)" 2>/dev/null || true
}

mcu_version() {   # $1 = MCU name as in printer.cfg
  local obj="mcu"; [[ "$1" != "mcu" ]] && obj="mcu $1"
  moon "printer/objects/query?${obj// /%20}" "d['result']['status']['$obj']['mcu_version']"
}

KLIPPER_STOPPED=false
cleanup() {
  if $KLIPPER_STOPPED; then
    info "Starting Klipper"
    sudo systemctl start klipper || echo "WARNING: failed to start Klipper" >&2
  fi
}
trap cleanup EXIT

# ---- Preflight --------------------------------------------------------------
[[ -d "$KLIPPER_DIR" ]] || die "$KLIPPER_DIR not found"
[[ -f "$FLASHTOOL"   ]] || die "flashtool not found - git clone https://github.com/Arksine/katapult ~/katapult"
[[ -x "$PY"          ]] || die "$PY not found"

state="$(moon 'printer/objects/query?print_stats' "d['result']['status']['print_stats']['state']")"
[[ "$state" == "printing" || "$state" == "paused" ]] && die "Printer is $state - refusing to flash"

HOST_VER="$(git -C "$KLIPPER_DIR" describe --always --tags --long --dirty)"
info "Host Kalico: $HOST_VER"

# ---- Version check ----------------------------------------------------------
SELECTED=()
printf '    %-9s %-12s %s\n' "BOARD" "MCU" "FIRMWARE"
for b in "${BOARDS[@]}"; do
  IFS='|' read -r name cfg mcu dev <<< "$b"
  [[ -n "$ONLY" && "$ONLY" != "$name" ]] && continue
  ver="$(mcu_version "$mcu")"
  if [[ "$ver" == "$HOST_VER" ]]; then mark="ok"; else mark="NEEDS FLASH"; fi
  printf '    %-9s %-12s %-30s %s\n' "$name" "$mcu" "${ver:-<unknown - Klippy not ready?>}" "$mark"
  if $FORCE || [[ "$ver" != "$HOST_VER" ]]; then SELECTED+=("$b"); fi
done

$CHECK_ONLY && exit 0
[[ ${#SELECTED[@]} -eq 0 ]] && { info "All boards match the host. Nothing to do (use --force to reflash anyway)."; exit 0; }
[[ "$HOST_VER" == *-dirty ]] && echo "WARNING: host tree is dirty - firmware will be built from local changes"

names="$(for b in "${SELECTED[@]}"; do echo -n "${b%%|*} "; done)"
confirm "Build firmware for: ${names}?" || exit 0

# ---- Build (all boards before touching Klipper) -----------------------------
mkdir -p "$BUILD_DIR"
cd "$KLIPPER_DIR"
for b in "${SELECTED[@]}"; do
  IFS='|' read -r name cfg mcu dev <<< "$b"
  F="$CFG_DIR/$cfg"
  [[ -f "$F" ]] || die "Config $F not found"
  info "[$name] Building from $cfg"
  cp "$F" "$F.prev"                                   # last-known config before olddefconfig
  make clean KCONFIG_CONFIG="$F" >/dev/null
  make olddefconfig KCONFIG_CONFIG="$F" >/dev/null
  if ! diff -q "$F.prev" "$F" >/dev/null; then
    echo "    Kconfig changes from olddefconfig (new options at defaults):"
    diff "$F.prev" "$F" | sed 's/^/      /' || true
  fi
  make -j"$(nproc)" KCONFIG_CONFIG="$F" > "$BUILD_DIR/$name.build.log" 2>&1 \
    || die "[$name] build failed - see $BUILD_DIR/$name.build.log"
  cp out/klipper.bin "$BUILD_DIR/$name-$HOST_VER.bin"
  info "[$name] OK: $BUILD_DIR/$name-$HOST_VER.bin ($(stat -c %s out/klipper.bin) bytes)"
done

confirm "Builds OK. Stop Klipper and flash ${names}?" || exit 0

# ---- Flash ------------------------------------------------------------------
info "Stopping Klipper"
sudo systemctl stop klipper
KLIPPER_STOPPED=true

for b in "${SELECTED[@]}"; do
  IFS='|' read -r name cfg mcu dev <<< "$b"
  [[ -e "$dev" ]] || die "[$name] $dev not present - check /dev/serial/by-id/"
  info "[$name] Flashing"
  out="$("$PY" "$FLASHTOOL" -d "$dev" -f "$BUILD_DIR/$name-$HOST_VER.bin" 2>&1 | tee /dev/stderr)"
  grep -q "Programming Complete" <<< "$out" || die "[$name] flash did not complete - see output above"
  for _ in $(seq 1 20); do [[ -e "$dev" ]] && break; sleep 1; done   # wait for Klipper USB to return
  [[ -e "$dev" ]] || die "[$name] did not come back as $dev after flashing"
  info "[$name] Flashed and back online"
done

# ---- Restart + verify -------------------------------------------------------
info "Starting Klipper"
sudo systemctl start klipper
KLIPPER_STOPPED=false
for _ in $(seq 1 60); do
  [[ "$(moon 'printer/info' "d['result']['state']")" == "ready" ]] && break
  sleep 2
done

fail=0
for b in "${SELECTED[@]}"; do
  IFS='|' read -r name cfg mcu dev <<< "$b"
  ver="$(mcu_version "$mcu")"
  if [[ "$ver" == "$HOST_VER" ]]; then info "[$name] verified: $ver"
  else echo "ERROR: [$name] reports '${ver:-unknown}', expected $HOST_VER" >&2; fail=1; fi
done
[[ $fail -eq 0 ]] && info "Done - all flashed boards match host $HOST_VER" || exit 1
