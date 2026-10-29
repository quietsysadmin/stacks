#!/usr/bin/env bash
# Before you trust this server in production: six checks, PASS / WARN / FAIL.
#   sudo ./verify.sh whoami.example.com
# Then, from another machine: nmap -Pn <server-ip>   -> only 22, 80 and 443 open.
# Exit code: 0 if nothing failed, 1 otherwise.
set -u

host=${1:-}
fails=0
pass() { printf '\033[32mPASS\033[0m  %s\n' "$1"; }
warn() { printf '\033[33mWARN\033[0m  %s\n' "$1"; }
fail() { printf '\033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails + 1)); }

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0 ${host:-<hostname>}" >&2
  exit 2
fi

# 1. SSH: the running config, not the file you edited.
sshd_config=$(sshd -T 2>/dev/null)
if grep -qx 'permitrootlogin no' <<<"$sshd_config" &&
  grep -qx 'passwordauthentication no' <<<"$sshd_config" &&
  grep -qx 'kbdinteractiveauthentication no' <<<"$sshd_config"; then
  pass "SSH: keys only, root login off"
else
  fail "SSH: root or password login still allowed ($(grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication) ' <<<"$sshd_config" | tr '\n' ' '))"
fi

# 2. Ports: ufw allows 22, 80, 443 only, and no container publishes anything else.
ufw_status=$(ufw status verbose 2>/dev/null)
if ! grep -q '^Status: active' <<<"$ufw_status"; then
  fail "Firewall: ufw is not active"
elif ! grep -q 'deny (incoming)' <<<"$ufw_status"; then
  fail "Firewall: incoming traffic is not denied by default"
else
  extra=$(ufw status | awk '/ALLOW/ {print $1}' | sort -u | grep -vxE 'OpenSSH|22|22/tcp|80|80/tcp|443|443/tcp|80,443/tcp' | tr '\n' ' ')
  if [[ -z $extra ]]; then
    pass "Firewall: deny by default, open: 22, 80, 443"
  else
    fail "Firewall: extra rules open: $extra"
  fi
fi

if ! command -v docker >/dev/null; then
  fail "Docker: not installed"
else
  published=$(docker ps --format '{{.Names}}\t{{.Ports}}' | while IFS=$'\t' read -r name ports; do
    tr ',' '\n' <<<"$ports" | grep -oE '[^ ]+:[0-9-]+->' | sed 's/->$//' | while read -r binding; do
      addr=${binding%:*} port=${binding##*:}
      case $addr in 127.0.0.1 | '[::1]') continue ;; esac
      [[ $name == *traefik* && ($port == 80 || $port == 443) ]] && continue
      echo "$name $binding"
    done
  done | sort -u | tr '\n' ' ')
  if [[ -z $published ]]; then
    pass "Docker: only Traefik publishes ports (80, 443)"
  else
    fail "Docker: published past ufw: $published"
  fi
fi

# 3. HTTPS with a valid certificate (curl verifies it; a staging certificate fails here).
if [[ -z $host ]]; then
  warn "HTTPS: skipped, pass a hostname: sudo $0 whoami.example.com"
else
  code=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' "https://$host")
  rc=$?
  if [[ $rc -eq 0 && $code == 200 ]]; then
    pass "HTTPS: https://$host answers with a valid certificate"
  elif [[ $rc -eq 60 ]]; then
    fail "HTTPS: https://$host has a certificate curl doesn't trust (still on Let's Encrypt staging?)"
  else
    fail "HTTPS: https://$host answered $code (curl exit code $rc)"
  fi
fi

# 4. Security updates install themselves.
if dpkg -s unattended-upgrades >/dev/null 2>&1 &&
  apt-config dump APT::Periodic::Unattended-Upgrade | grep -q '"1"' &&
  systemctl is-active --quiet apt-daily-upgrade.timer; then
  pass "Updates: unattended-upgrades on, daily timer active"
else
  fail "Updates: unattended-upgrades not installed or not enabled"
fi

# 5. Backups: the timer runs, the last run worked, the repository is healthy.
if ! systemctl is-active --quiet restic-backup.timer; then
  fail "Backups: restic-backup.timer is not active"
else
  last=$(systemctl show restic-backup.service -p ExecMainExitTimestamp --value)
  result=$(systemctl show restic-backup.service -p Result --value)
  if [[ -z $last ]]; then
    fail "Backups: restic-backup.service has never run (sudo systemctl start restic-backup.service)"
  elif [[ $result != success ]]; then
    fail "Backups: last run failed ($result), see journalctl -u restic-backup.service"
  elif (($(date +%s) - $(date -d "$last" +%s) > 26 * 3600)); then
    fail "Backups: last successful run is older than 26 hours ($last)"
  else
    pass "Backups: last run succeeded ($last)"
  fi
fi

# shellcheck source=/dev/null
if [[ ! -r /etc/restic.env ]]; then
  fail "Backups: /etc/restic.env missing"
elif (set -a && . /etc/restic.env && restic check -q >/dev/null 2>&1); then
  pass "Backups: restic check passes. Restore-test it monthly."
else
  fail "Backups: restic check failed (sudo bash -c 'set -a; . /etc/restic.env; restic check')"
fi

# 6. Reboots: updates land on their own, new kernels wait for a reboot.
if [[ -e /var/run/reboot-required ]]; then
  warn "Reboot needed for: $(sort -u /var/run/reboot-required.pkgs 2>/dev/null | tr '\n' ' ')"
else
  pass "Reboots: none pending"
fi

echo
if ((fails == 0)); then
  echo "All checks passed. Now scan from outside: nmap -Pn <server-ip>"
else
  echo "$fails check(s) failed."
  exit 1
fi
