#!/usr/bin/env bash
# Before you trust your local AI: six checks, PASS / WARN / FAIL.
#   ./verify-ai.sh            (as a user in the docker group, or with sudo)
# Then, from another device on the same network: nmap -Pn -p 3000,11434 <this-machine-ip>
#   -> both closed or filtered.
# Exit code: 0 if nothing failed, 1 otherwise.
set -u

fails=0
pass() { printf '\033[32mPASS\033[0m  %s\n' "$1"; }
warn() { printf '\033[33mWARN\033[0m  %s\n' "$1"; }
fail() { printf '\033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }

if ! docker info >/dev/null 2>&1; then
  echo "Can't reach Docker. Run as a user in the docker group, or: sudo $0" >&2
  exit 2
fi

# The two containers, found by their compose service names (works from any folder).
find_one() { docker ps -q --filter "label=com.docker.compose.service=$1" | head -1; }
ollama=$(find_one ollama)
webui=$(find_one open-webui)
[[ -n $ollama ]] || { echo "No running 'ollama' service. Start it: docker compose up -d" >&2; exit 2; }
[[ -n $webui ]] || { echo "No running 'open-webui' service. Start it: docker compose up -d" >&2; exit 2; }
env_of() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1"; }
bindings() { docker inspect -f '{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}}:{{.HostPort}}->{{$p}} {{end}}{{end}}' "$1" | sed 's/ *$//'; }

# 1. Ollama publishes nothing, and nothing on this machine listens on 11434.
ollama_ports=$(bindings "$ollama")
if [[ -n $ollama_ports ]]; then
  fail "Ollama: publishes ports: $ollama_ports"
elif ss -Htln 'sport = :11434' 2>/dev/null | grep -q .; then
  fail "Ollama: something listens on port 11434 on this machine: $(ss -Htlnp 'sport = :11434' | awk '{print $4}' | tr '\n' ' ')"
else
  pass "Ollama: publishes no ports"
fi

# 2. Open WebUI: every published port is on 127.0.0.1 (or ::1).
webui_ports=$(bindings "$webui")
open=$(tr ' ' '\n' <<<"$webui_ports" | grep . | grep -vE '^(127\.0\.0\.1|::1|\[::1\]):' | paste -sd' ')
if [[ -z $webui_ports ]]; then
  warn "Open WebUI: publishes no ports (fine, but how do you reach it?)"
elif [[ -n $open ]]; then
  fail "Open WebUI: reachable from the network: $open"
else
  pass "Open WebUI: bound to localhost only ($webui_ports)"
fi

# 3. Sign-ups: off, as the running app reports it (not just the setting).
# The address Open WebUI is published on (0.0.0.0 or :: is reachable as 127.0.0.1).
url=$(tr ' ' '\n' <<<"$webui_ports" | sed -nE 's/^(.*):([0-9]+)->8080.*$/\1 \2/p' | head -1 |
  awk '{h=$1; if (h=="0.0.0.0" || h=="::" || h=="[::]") h="127.0.0.1"; if (h ~ /:/ && h !~ /^\[/) h="[" h "]"; print "http://" h ":" $2}')
url=${url:-http://127.0.0.1:3000}
cfg=$(curl -s --max-time 10 "$url/api/config")
signup=$(jq -r '.features.enable_signup | if . == null then empty else tostring end' <<<"$cfg" 2>/dev/null)
persist=$(env_of "$webui" | grep -oP '^ENABLE_PERSISTENT_CONFIG=\K.*')
if [[ -z $cfg ]]; then
  fail "Sign-ups: Open WebUI doesn't answer on $url"
elif [[ $signup == false ]]; then
  pass "Sign-ups: off"
elif [[ $signup == true ]]; then
  fail "Sign-ups: on, anyone who can open the page can make an account"
else
  warn "Sign-ups: couldn't read the setting from /api/config (ENABLE_SIGNUP in compose.yaml should be false)"
fi
[[ $persist == false ]] || warn "Settings: ENABLE_PERSISTENT_CONFIG isn't false, so the admin panel can override compose.yaml"

# 4. Telemetry and cloud: off, in both containers.
want_webui='OFFLINE_MODE=true ANONYMIZED_TELEMETRY=false DO_NOT_TRACK=true SCARF_NO_ANALYTICS=true ENABLE_OPENAI_API=false ENABLE_DIRECT_CONNECTIONS=false ENABLE_WEB_SEARCH=false ENABLE_COMMUNITY_SHARING=false'
have_webui=$(env_of "$webui")
missing=""
for kv in $want_webui; do grep -qxi "$kv" <<<"$have_webui" || missing+="$kv "; done
grep -qx 'OLLAMA_NO_CLOUD=1' <<<"$(env_of "$ollama")" || missing+="OLLAMA_NO_CLOUD=1 "
if [[ -z $missing ]]; then
  pass "Telemetry and cloud: off (no cloud providers, web search, sharing or update checks)"
else
  fail "Telemetry and cloud: not set: $missing"
fi

# 5. The GPU: a loaded model should say 100% GPU.
ps_out=$(docker exec "$ollama" ollama ps 2>/dev/null | tail -n +2)
if [[ -z $ps_out ]]; then
  if docker logs "$ollama" 2>&1 | grep -qiE 'inference compute.*(library=cuda|library=CUDA)'; then
    warn "GPU: Ollama found a CUDA GPU, no model loaded yet. Run one, then check again"
  else
    fail "GPU: Ollama didn't find a CUDA GPU (docker logs $ollama | grep -i 'inference compute')"
  fi
else
  not_gpu=$(grep -v '100% GPU' <<<"$ps_out" | awk '{print $1}' | tr '\n' ' ')
  if [[ -z $not_gpu ]]; then
    pass "GPU: every loaded model runs 100% on the GPU"
  else
    warn "GPU: partly on the CPU (slow): $not_gpu (smaller model or shorter context)"
  fi
fi

# 6. Images pinned by digest: an update never lands by surprise.
unpinned=""
for c in "$ollama" "$webui"; do
  img=$(docker inspect -f '{{.Config.Image}}' "$c")
  [[ $img == *@sha256:* ]] || unpinned+="$img "
done
if [[ -z $unpinned ]]; then
  pass "Images: pinned by digest"
else
  fail "Images: not pinned by digest: $unpinned"
fi

echo
if ((fails == 0)); then
  echo "All checks passed. Now scan from another device: nmap -Pn -p 3000,11434 <this-machine-ip>"
else
  echo "$fails check(s) failed."
  exit 1
fi
