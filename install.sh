#!/usr/bin/env bash
# FF7 Remake Intergrade on Steam Deck: FSR 4.1 (INT8 Lite) upscaling + 16:10
#
#   ./install.sh [--preset 60|40] [--scale PERCENT] [--game-dir DIR]   install (or update) the mods
#      60 (default): FSR 3.1 at 58% render scale, for a 60 fps cap (dips in the heaviest scenes)
#      40: FSR 4.1 INT8 Lite at 67%, sharper, for a 40 Hz / 40 fps cap
#   ./install.sh --uninstall [--game-dir DIR]           remove them and restore the backup
#
# Run it in Desktop Mode with the game closed. It installs, into the game's End/Binaries/Win64 folder:
#   - Luma for FF7R (DX11 mod with FSR 4), patched for true upscaling with a fixed render scale (wiggyoats/Luma-Framework)
#   - OptiScaler (makes FSR 4.1 INT8 Lite available under Proton on the Deck's GPU)
#   - FF7RemakeFix by Lyall (16:10 / any aspect ratio)
# and sets the render scale in Engine.ini. FFVIIHook (needed for Engine.ini to be read) has to be downloaded from
# Nexus Mods by hand, see the README.
set -euo pipefail

APPID=1462040
LUMA_URL=${LUMA_URL:-'https://github.com/wiggyoats/Luma-Framework/releases/download/ff7r-deck-1/Luma-Final_Fantasy_VII_Remake-deck.zip'}
LUMA_SHA='d983692a6de6f4b4feac4f7f98be8010b3f2f7635175e21ca72d33bbd757c823'
OPTI_URL=${OPTI_URL:-'https://github.com/wiggyoats/OptiScaler/releases/download/ff7r-deck-1/OptiScaler-ff7r-deck.zip'}
OPTI_SHA='a2d0d7a98930058ccf8feb099055c211687b81f24df389a9d1a50cdd176a6202'
FIX_URL=${FIX_URL:-'https://codeberg.org/Lyall/FF7RemakeFix/releases/download/0.0.2/FF7RemakeFix_0.0.2.zip'}
FIX_SHA='9a11e6ee833e98484a5cd8588cf20727f24e283efd512b34fad82c525d096402'
VCREDIST_URL='https://aka.ms/vs/17/release/vc_redist.x64.exe'

# Every file and folder we add to Win64 (removed again by --uninstall)
OURS=(dxgi.dll OptiScaler.ini OptiScaler ReShade64.dll ReShade.ini "Luma-Final Fantasy VII Remake.addon" Luma
      amd_fidelityfx_loader_dx12.dll amd_fidelityfx_upscaler_dx12.dll dsound.dll FF7RemakeFix.asi FF7RemakeFix.ini)

say() { printf '\e[1m[ff7r-deck]\e[0m %s\n' "$*"; }
die() { printf '[ff7r-deck] error: %s\n' "$*" >&2; exit 1; }

PRESET=60; SCALE=""; GAME_DIR=""; UNINSTALL=0
while [ $# -gt 0 ]; do
    case "$1" in
        --preset) PRESET=$2; shift ;;
        --scale) SCALE=$2; shift ;;
        --game-dir) GAME_DIR=$2; shift ;;
        --uninstall) UNINSTALL=1 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done
case "$PRESET" in
    60) SR_TYPE=3; SCALE=${SCALE:-58} ;; # Luma's FSR 3.1
    40) SR_TYPE=4; SCALE=${SCALE:-67} ;; # Luma's FSR 4 (4.1 INT8 Lite through OptiScaler)
    *) die "--preset must be 60 or 40" ;;
esac
[[ "$SCALE" =~ ^[0-9]+$ ]] && [ "$SCALE" -ge 50 ] && [ "$SCALE" -le 100 ] || die "--scale must be 50 to 100"

STEAM="$HOME/.local/share/Steam"
[ -d "$STEAM/steamapps" ] || STEAM="$HOME/.steam/steam"

# --- find the game (any Steam library, internal or SD card) ---
if [ -z "$GAME_DIR" ]; then
    for lib in "$STEAM" $(grep -o '"path"[[:space:]]*"[^"]*"' "$STEAM/steamapps/libraryfolders.vdf" 2>/dev/null | cut -d'"' -f4); do
        d="$lib/steamapps/common/FINAL FANTASY VII REMAKE"
        [ -f "$d/End/Binaries/Win64/ff7remake_.exe" ] && { GAME_DIR="$d"; break; }
    done
fi
[ -n "$GAME_DIR" ] || die "game not found, pass --game-dir \"/path/to/FINAL FANTASY VII REMAKE\""
WIN64="$GAME_DIR/End/Binaries/Win64"
[ -f "$WIN64/ff7remake_.exe" ] || die "no ff7remake_.exe in $WIN64"
PFX="$STEAM/steamapps/compatdata/$APPID/pfx"
CONFIG="$PFX/drive_c/users/steamuser/Documents/My Games/FINAL FANTASY VII REMAKE/Saved/Config/WindowsNoEditor"
BACKUP="$HOME/ff7r-deck-backup"
say "game: $GAME_DIR"

pgrep -x ff7remake_.exe >/dev/null && die "close the game first"

# --- uninstall ---
if [ $UNINSTALL = 1 ]; then
    for f in "${OURS[@]}"; do rm -rf "${WIN64:?}/$f"; done
    if [ -d "$BACKUP/Win64" ]; then
        cp -a "$BACKUP/Win64/." "$WIN64/"
        say "restored the files that were there before from $BACKUP/Win64"
    fi
    if [ -f "$BACKUP/Engine.ini" ]; then cp "$BACKUP/Engine.ini" "$CONFIG/Engine.ini"; else rm -f "$CONFIG/Engine.ini"; fi
    say "done. Remove the launch options in Steam too."
    exit 0
fi

# --- backup (only once, so re-running the installer never overwrites the original backup) ---
if [ ! -d "$BACKUP/Win64" ]; then
    mkdir -p "$BACKUP/Win64"
    for f in "${OURS[@]}"; do [ -e "$WIN64/$f" ] && cp -a "$WIN64/$f" "$BACKUP/Win64/"; done
    [ -f "$CONFIG/Engine.ini" ] && cp "$CONFIG/Engine.ini" "$BACKUP/Engine.ini"
    say "backed up the files we replace to $BACKUP"
fi

# --- downloads ---
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fetch() {   # fetch URL FILE SHA256
    say "downloading $(basename "$2")"
    curl -fL --retry 3 -o "$2" "$1"
    echo "$3  $2" | sha256sum -c --status || die "$(basename "$2"): checksum mismatch"
}
unzip_to() { python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"; }

fetch "$LUMA_URL" "$TMP/luma.zip" "$LUMA_SHA"
fetch "$OPTI_URL" "$TMP/opti.zip" "$OPTI_SHA"
fetch "$FIX_URL" "$TMP/fix.zip" "$FIX_SHA"
mkdir "$TMP/luma" "$TMP/opti" "$TMP/fix"
unzip_to "$TMP/luma.zip" "$TMP/luma"
unzip_to "$TMP/opti.zip" "$TMP/opti"
unzip_to "$TMP/fix.zip" "$TMP/fix"

# --- install ---
# OptiScaler is the dxgi.dll the game loads, it then loads Luma's ReShade (renamed to ReShade64.dll) and gives it FSR 4
rm -rf "$WIN64/Luma" "$WIN64/OptiScaler"
cp -a "$TMP/luma/Luma" "$TMP/luma/Luma-Final Fantasy VII Remake.addon" "$TMP/luma/amd_fidelityfx_loader_dx12.dll" "$TMP/luma/amd_fidelityfx_upscaler_dx12.dll" "$WIN64/"
cp "$TMP/luma/dxgi.dll" "$WIN64/ReShade64.dll"
cp -a "$TMP/opti/OptiScaler" "$WIN64/"
cp "$TMP/opti/OptiScaler.dll" "$WIN64/dxgi.dll"
cp "$TMP/opti/OptiScaler.ini" "$WIN64/OptiScaler.ini"
cp "$TMP/fix/End/Binaries/Win64/dsound.dll" "$TMP/fix/End/Binaries/Win64/FF7RemakeFix.asi" "$WIN64/"
[ -f "$WIN64/FF7RemakeFix.ini" ] || cp "$TMP/fix/End/Binaries/Win64/FF7RemakeFix.ini" "$WIN64/"

# OptiScaler: pass Luma's FSR calls through FSR 4.1, with the INT8 Lite model (the one made for handhelds)
ini_set() {   # ini_set FILE KEY VALUE (first match of "KEY=")
    grep -q "^$2=" "$1" || die "$2 missing in $(basename "$1")"
    sed -i "0,/^$2=.*/s//$2=$3/" "$1"
}
O="$WIN64/OptiScaler.ini"
ini_set "$O" Dx12Upscaler fsr31
ini_set "$O" EnableFfxInputs true
ini_set "$O" UseFfxInputs true
ini_set "$O" Fsr4Model 3
ini_set "$O" LoadReshade true
ini_set "$O" Dxgi false
ini_set "$O" OverlayMenu true

# Luma: the super resolution type of the preset
R="$WIN64/ReShade.ini"
touch "$R"
if grep -q '^\[Luma\]' "$R"; then
    if grep -q '^SRUserType=' "$R"; then sed -i "s/^SRUserType=.*/SRUserType=$SR_TYPE/" "$R"; else sed -i "/^\\[Luma\\]/a SRUserType=$SR_TYPE" "$R"; fi
else
    printf '\n[Luma]\nSRUserType=%s\n' "$SR_TYPE" >> "$R"
fi

# FF7RemakeFix: replace the game's 3840x2160 option with the Deck's 1280x800
F="$WIN64/FF7RemakeFix.ini"
sed -i 's/^Width = .*/Width = 1280/; s/^Height = .*/Height = 800/' "$F"

# Engine.ini (read thanks to FFVIIHook): a fixed render scale (the game's dynamic resolution doesn't run in DX11),
# and the settings that cost the most on the Deck for the least visible difference at 800p (measured, see the README):
# sun shadows (1024 instead of 2048 maps, 2 cascades: +15 fps, some shadow pop-in in big areas), a coarser volumetric fog grid
# (+4 fps, keeps the haze) and a smaller translucency lighting volume (+4 fps)
mkdir -p "$CONFIG"
{
    printf '[SystemSettings]\r\n'
    printf '%s\r\n' r.DynamicRes.OperationMode=0 "r.ScreenPercentage=$SCALE" \
        r.Shadow.MaxCSMResolution=1024 r.Shadow.CSM.MaxCascades=2 \
        r.VolumetricFog.GridPixelSize=16 r.VolumetricFog.GridSizeZ=32 r.VolumetricFog.HistoryMissSupersampleCount=1 \
        r.TranslucencyLightingVolumeDim=24
} > "$CONFIG/Engine.ini"

# --- Visual C++ runtime in the game's prefix (Luma needs a newer one than the prefix has) ---
# Use the Proton the prefix was last run with (Steam writes it to config_info), else the newest installed one
PROTON=$(sed -n 2p "$(dirname "$PFX")/config_info" 2>/dev/null | sed -n 's|/files/.*||p')/proton
[ -f "$PROTON" ] || PROTON=$(ls -d "$STEAM"/steamapps/common/Proton*/proton 2>/dev/null | sort -V | tail -1 || true)
# FileVersion of msvcp140.dll in the prefix (0 if missing); Luma needs 14.40 or newer
vc_version() {
    python3 - "$PFX/drive_c/windows/system32/msvcp140.dll" <<'PYEOF' 2>/dev/null || echo 0
import sys, re
d = open(sys.argv[1], "rb").read().decode("utf-16-le", "ignore")
m = re.search(r"FileVersion\W*(\d+)\.(\d+)", d)
print(int(m.group(1)) * 100 + int(m.group(2)) if m else 0)
PYEOF
}
if [ ! -d "$PFX" ] || [ ! -f "$PROTON" ]; then
    say "warning: no Proton prefix yet. Start the game once without mods, then run this again"
elif [ "$(vc_version)" -ge 1440 ]; then
    say "the Visual C++ runtime in the game's prefix is already new enough"
else
    say "installing the Visual C++ runtime into the game's prefix (up to 5 minutes)"
    curl -fsSL --retry 3 -o "$TMP/vc_redist.x64.exe" "$VCREDIST_URL"
    STEAM_COMPAT_DATA_PATH="$(dirname "$PFX")" STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM" \
        timeout 300 "$PROTON" run "$TMP/vc_redist.x64.exe" /install /quiet /norestart >/dev/null 2>&1 || true
    # the installer can leave Wine running after it finishes
    WINEPREFIX="$PFX" timeout 30 "$(dirname "$PROTON")/files/bin/wineserver" -k 2>/dev/null || true
    [ "$(vc_version)" -ge 1440 ] || say "warning: the Visual C++ runtime install failed, see the README"
fi

[ -f "$WIN64/xinput1_3.dll" ] || say "FFVIIHook (xinput1_3.dll) is missing: get it from Nexus Mods (see the README), otherwise the render scale is ignored"

cat <<EOF

Installed. Now, in Steam: FINAL FANTASY VII REMAKE INTERGRADE > Properties > Launch Options:

  WINEDLLOVERRIDES="xinput1_3,dsound,dxgi=n,b" %COMMAND% -dx11

In the game's graphics settings, pick the resolution that used to say 3840x2160 (now 1280x800), and a 60 fps frame rate.
EOF
if [ "$PRESET" = 40 ]; then
    echo "Then in the Deck's quick access menu (... button) > Performance: Refresh Rate 40, Frame Limit 40."
fi
echo "Preset: $PRESET fps ($([ "$SR_TYPE" = 3 ] && echo "FSR 3.1" || echo "FSR 4.1 INT8 Lite"), ${SCALE}% render scale). Switch with: ./install.sh --preset 40 (or 60)"
