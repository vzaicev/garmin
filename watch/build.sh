#!/usr/bin/env bash
# Сборка voice.prg для Forerunner 970.  ./build.sh [device]   (по умолчанию fr970)
# Нужно: tools/jdk, tools/sdk-9.3.0, описание устройства в ~/.Garmin/ConnectIQ/Devices/<device>.
set -euo pipefail
cd "$(dirname "$0")"
G=$(cd .. && pwd)
DEV=${1:-fr970}
export JAVA_HOME="$G/tools/jdk" PATH="$G/tools/jdk/bin:$PATH"
SDK="$G/tools/sdk-9.3.0"
SEC="$G/.secrets"; mkdir -p "$SEC"; chmod 700 "$SEC"
KEY="$SEC/developer_key.der"
if [ ! -f "$KEY" ]; then
  openssl genrsa -out "$SEC/developer_key.pem" 4096 2>/dev/null
  openssl pkcs8 -topk8 -inform PEM -outform DER -in "$SEC/developer_key.pem" -out "$KEY" -nocrypt
  chmod 600 "$SEC"/developer_key.*
fi
# Config.mc из секрета (не в git)
TOKEN=$(grep -oP '^VOICE_TOKEN=\K.*' "$HOME/ws/memory/.secrets/voice.env")
URL=${VOICE_URL:-https://voice-gw.tail22b878.ts.net}
umask 077
cat > source/Config.mc <<MC
// Сгенерировано build.sh — НЕ коммитить.
const SERVER_URL = "$URL";
const API_TOKEN = "$TOKEN";
MC
mkdir -p bin
"$SDK/bin/monkeyc" -f monkey.jungle -d "$DEV" -o bin/voice.prg -y "$KEY" -w
ls -la bin/voice.prg
