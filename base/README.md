# base: a production-ready Docker host from scratch

The foundation from episode 1. Most later episodes build on a server set up like this.

What you get:

- SSH with keys only, no root login
- ufw: deny incoming by default, open 22, 80 and 443
- Security updates that install themselves
- Docker from Docker's own repository
- Traefik as the only container that publishes ports, with automatic TLS from Let's Encrypt
- Nightly encrypted backups with restic to S3-compatible storage, plus a restore test
- `checks/verify.sh`: six checks before you trust the server

Tested on Debian 13 (trixie). Run every step yourself and read what it does. Examples use `203.0.113.10` for the server and `example.com` for the domain.

```
base/
├── traefik/
│   ├── compose.yaml          Traefik + a whoami test app
│   └── .env.example          ACME_EMAIL, DOMAIN, staging switch
├── restic/
│   ├── restic.env.example    goes to /etc/restic.env (root, 600)
│   ├── restic-backup.service
│   └── restic-backup.timer
├── checks/
│   └── verify.sh             PASS / WARN / FAIL for the six checks
└── .gitignore                .env and letsencrypt/ never go in git
```

## 1. A user, and SSH keys only

As root, on the fresh server. Your provider put your key in root's `authorized_keys`.

```bash
adduser ops
usermod -aG sudo ops
install -d -m 700 -o ops -g ops /home/ops/.ssh
install -m 600 -o ops -g ops /root/.ssh/authorized_keys \
  /home/ops/.ssh/authorized_keys

cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF
sshd -t && systemctl reload ssh
```

Keep the root session open. From your laptop, in a new terminal:

```bash
ssh ops@203.0.113.10      # gets in
ssh root@203.0.113.10     # Permission denied (publickey)
```

Only then close the root session. The first value sshd reads wins, so the file name starts with `10-` to sort before anything else in `sshd_config.d`.

## 2. Firewall: deny by default

As `ops` from here on.

```bash
sudo apt update && sudo apt install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80,443/tcp
sudo ufw enable
sudo ufw status verbose
```

Allow SSH before `ufw enable`. The other way round, on a remote server, locks you out.

If your provider has its own firewall in front of the server (Google Cloud, AWS, some VPS panels), it filters first. That's fine, but keep ufw: it's the one that travels with the server.

## 3. Security updates that install themselves

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -f noninteractive -plow unattended-upgrades
cat /etc/apt/apt.conf.d/20auto-upgrades
sudo unattended-upgrade --dry-run --debug 2>&1 | tail -5
```

It doesn't reboot by default. New kernels wait for a reboot: see check 6.

## 4. Docker, from Docker's own repository

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker ops     # log out and back in
docker version
```

Anyone in the `docker` group is effectively root on this machine. On a single-admin server that's the trade-off. On a shared one, it isn't.

Check [Docker's install guide](https://docs.docker.com/engine/install/debian/) if these steps have changed.

## 5. The trap: Docker walks past ufw

Docker writes its own firewall rules for published ports, and they're checked before ufw's. See it for yourself:

```bash
docker run -d --name trap -p 8080:80 nginx:alpine
# from your laptop:
nmap -Pn -p 8080,8081 203.0.113.10   # 8080 open (Docker), 8081 filtered (ufw)
docker rm -f trap
```

The rule on this server: **apps never publish ports.** Only Traefik does, on 80 and 443. Apps join the `proxy` network and are reachable only through Traefik. Need a port for debugging? Bind it to localhost (`127.0.0.1:8080:80`) and use an SSH tunnel.

## 6. Traefik with automatic TLS

Point a DNS record for `whoami.example.com` (or `*.example.com`) at the server first. If your DNS provider can proxy traffic (Cloudflare's orange cloud), turn that off for this record.

```bash
sudo apt install -y git
git clone https://github.com/quietsysadmin/stacks.git ~/stacks

sudo install -d -o ops -g ops /srv/traefik
cp ~/stacks/base/traefik/compose.yaml ~/stacks/base/traefik/.env.example \
  /srv/traefik/
cd /srv/traefik
cp .env.example .env && nano .env    # ACME_EMAIL and DOMAIN
docker network create proxy
docker compose up -d
docker compose logs -f traefik
curl -sI https://whoami.example.com | head -1
```

Traefik gets certificates with the HTTP challenge: Let's Encrypt connects to the server on port 80 and asks for a token Traefik serves. No API keys. One certificate per hostname. For wildcard certificates you need the [DNS challenge](https://doc.traefik.io/traefik/https/acme/#dnschallenge) and an API token from your DNS provider.

Rehearse first: uncomment `ACME_CA_SERVER` in `.env` to use Let's Encrypt staging (untrusted certificates, generous limits). For the real run, comment it out again, `rm letsencrypt/acme.json` and `docker compose up -d`.

To route another app through Traefik, give it the `proxy` network and labels like `whoami`'s, and no `ports:`.

Traefik reads the Docker socket. Access to that socket is root on the host, and mounting it read-only helps less than it sounds. A socket proxy is the proper fix: a later episode.

## 7. Backups with restic, off the server

Storage: any S3-compatible bucket that isn't on this server. Create a key that works on that one bucket only.

```bash
sudo apt install -y restic
sudo install -m 600 ~/stacks/base/restic/restic.env.example /etc/restic.env
sudoedit /etc/restic.env
sudo sh -c 'umask 077; head -c 32 /dev/urandom | base64 > /etc/restic.password'
sudo ls -l /etc/restic.env /etc/restic.password   # -rw------- root root, both
sudo bash -c 'set -a; . /etc/restic.env; restic init'
```

Copy `/etc/restic.password` to your password manager now. Without it, the backups can't be read by anyone, you included.

The key on this server can delete backups too. Whoever takes over the server can wipe them. Turn on versioning, soft delete or object lock on the bucket if your storage has it.

Nightly, on a timer:

```bash
sudo cp ~/stacks/base/restic/restic-backup.service ~/stacks/base/restic/restic-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now restic-backup.timer
sudo systemctl start restic-backup.service      # first backup now, not tonight
sudo bash -c 'set -a; . /etc/restic.env; restic snapshots'
```

It backs up `/etc` (configuration) and `/srv` (apps and their data) every night around 03:00, then keeps 7 daily, 4 weekly and 6 monthly snapshots. Databases need a consistent dump before the backup: each stack that has one adds it.

## 8. The restore test

A backup you haven't restored isn't a backup.

```bash
sudo bash -c 'set -a; . /etc/restic.env; restic restore latest --target /tmp/restore-test --include /srv/traefik'
sudo diff -r /srv/traefik /tmp/restore-test/srv/traefik && echo "restore matches"
sudo rm -rf /tmp/restore-test
```

Do it again every month.

## 9. Before you trust it in production

```bash
sudo ~/stacks/base/checks/verify.sh whoami.example.com
nmap -Pn 203.0.113.10     # from your laptop: 22, 80 and 443 only
```

`verify.sh` checks, using the running state rather than config files:

1. SSH: root login and passwords off (`sshd -T`)
2. Ports: ufw denies by default and opens 22, 80, 443 only; no container publishes anything past ufw
3. HTTPS: answers with a valid certificate
4. Updates: unattended-upgrades enabled, daily timer active
5. Backups: timer active, last run succeeded within 26 hours, `restic check` passes
6. Reboots: warns when a reboot is pending

Updates land on their own, but a new kernel waits for a reboot. Pick a maintenance window.
