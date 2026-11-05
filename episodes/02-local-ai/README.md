# EP 02: Run local AI privately: Ollama + Open WebUI, hardened

Video: coming 2026-11-17.

Ollama runs the models on your GPU. Open WebUI is the chat in your browser. Both in Docker, on one machine.

What you get:

- Ollama with no published ports: nothing on the network can reach it
- Open WebUI on `127.0.0.1:3000` only: a browser on this machine, nothing else
- The first account is the admin, and nobody can sign up after it
- No cloud providers, web search, community sharing, update checks or telemetry
- Images pinned by digest, so updates happen when you decide
- `checks/verify-ai.sh`: six checks before you trust it

Tested on Fedora 44 with an NVIDIA RTX 4050 Laptop GPU (6 GB), Docker 29.9 and the NVIDIA Container Toolkit 1.20. The same files work on Debian and Ubuntu. AMD, Mac and CPU-only: [section 9](#9-amd-mac-or-no-gpu).

```
episodes/02-local-ai/
├── compose.yaml          Ollama + Open WebUI, private network, localhost port
├── .env.example          WEBUI_SECRET_KEY, optional context length
├── checks/
│   └── verify-ai.sh      PASS / WARN / FAIL for the six checks
└── .gitignore            .env never goes in git
```

## Why not the quick start

Ollama's Docker instructions publish port 11434 with `-p 11434:11434`. That means every network interface, and Ollama's API has no login: anyone on your network can list your models, run prompts on your GPU, pull models until your disk is full, or delete the ones you have. Open WebUI's quick start publishes port 3000 the same way, and the first person to open it and sign up becomes the admin.

The host firewall doesn't save you:

- **Fedora Workstation:** the default firewalld zone allows every port from 1025 up. Check yours: `firewall-cmd --get-default-zone`, then `firewall-cmd --list-ports`.
- **Debian and Ubuntu with ufw:** Docker writes its own iptables rules for published ports, and ufw never sees the traffic ([episode 1](../01-production-docker-host/README.md)).

Installed directly (not in Docker), Ollama listens on `127.0.0.1` only. It's the Docker `-p` that opens it up. This build doesn't rely on any firewall: nothing listens on the network in the first place.

## 1. The GPU, inside Docker

You need the NVIDIA driver and the NVIDIA Container Toolkit on the host.

- Driver: Fedora via RPM Fusion (`akmod-nvidia`); Debian and Ubuntu via their `nvidia-driver` packages. `nvidia-smi` must work on the host first.
- Toolkit: follow [NVIDIA's install guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) (apt or dnf repository), then:

```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Check it, step by step:

```bash
nvidia-smi --query-gpu=name,memory.total --format=csv
nvidia-ctk --version
docker info | grep -i runtimes                     # lists nvidia
docker run --rm --gpus all \
  nvidia/cuda:12.9.1-base-ubuntu24.04 nvidia-smi    # the same card, from a container
```

If the last command fails, stop here. Without it Ollama quietly runs on the CPU, and everything is slow.

## 2. Get the files

```bash
git clone https://github.com/quietsysadmin/stacks.git ~/stacks
mkdir -p ~/local-ai && cd ~/local-ai
cp ~/stacks/episodes/02-local-ai/compose.yaml \
  ~/stacks/episodes/02-local-ai/.env.example .
```

Already cloned? `git -C ~/stacks pull`.

## 3. One secret

Open WebUI signs logins with `WEBUI_SECRET_KEY`. Generate it, and keep the file private:

```bash
cp .env.example .env
sed -i "s/^WEBUI_SECRET_KEY=.*/WEBUI_SECRET_KEY=$(openssl rand -hex 32)/" .env
chmod 600 .env
```

## 4. Start it, and check what listens

```bash
docker compose up -d
docker compose ps
ss -tln | grep -E ':3000|:11434'
```

One line: `127.0.0.1:3000`. Port 11434 isn't there at all.

What's in `compose.yaml`, and why:

- **Ollama** has no `ports:` section. It reaches out to pull models; nothing reaches in. `OLLAMA_NO_CLOUD=1` turns off Ollama's cloud models and web search.
- **Open WebUI** reaches Ollama by name (`http://ollama:11434`) over the `ai` network, and publishes one port on `127.0.0.1`. A port bound there answers this machine only. No firewall rule, Docker's or anyone else's, changes that.
- **Settings are environment variables, every start.** `ENABLE_PERSISTENT_CONFIG=false` means Open WebUI reads them from `compose.yaml` each time, instead of saving them in its database on the first start. The admin panel can still change settings, but a restart puts the compose values back.
- **`OFFLINE_MODE=true`** stops update checks and model downloads from Hugging Face. The models Open WebUI needs for documents and speech are already in the image; the named `webui` volume gets a copy on first start. Use a named volume, not a folder (bind mount): a folder hides those models.
- **Telemetry:** the image already ships `ANONYMIZED_TELEMETRY=false`, `DO_NOT_TRACK=true` and `SCARF_NO_ANALYTICS=true`. They're set again in `compose.yaml` so they stay off whatever the image does.
- **`no-new-privileges`** on both: nothing inside can gain rights it didn't start with.

## 5. What fits in your GPU

A model needs video memory for its weights and for the context (the conversation it keeps in mind). Rule of thumb: the download size plus about 1 GB. Ollama's default tags are 4-bit, which is what you want on a small card.

```bash
docker compose exec ollama ollama pull qwen3:4b
docker compose exec ollama ollama list
docker compose exec ollama ollama run qwen3:4b --verbose \
  "Explain a Docker volume in two sentences."
docker compose exec ollama ollama ps               # PROCESSOR: 100% GPU
```

`100% GPU` is the line you want. A split like `18%/82% CPU/GPU` means it didn't fit: it still works, just slower, and the more is on the CPU, the slower it gets. A longer context needs more memory too, so check `ollama ps` again after raising `OLLAMA_CONTEXT_LENGTH` in `.env`.

Measured on the 6 GB RTX 4050 Laptop GPU (Ollama 0.40.14, context 4096, one run each; speeds vary between runs):

| Model | Download | `ollama ps` | Speed |
|---|---|---|---|
| qwen3:4b | 2.5 GB | 3.2 GB, 100% GPU | ~64 tokens/s |
| qwen3:8b | 5.2 GB | 6.0 GB, 18%/82% CPU/GPU | ~14-26 tokens/s |
| qwen3:14b | 9.3 GB | 10 GB, 53%/47% CPU/GPU | ~2 tokens/s |

On 6 GB, an 8B model at 4-bit is just over the edge (even at 2048 context, 14% stays on the CPU). Stay at about 4.5 GB of download or less, and check `ollama ps` once for each new model. An 8 GB card has room for it: it needs about 6 GB here.

## 6. The first account

Open http://localhost:3000 on this machine. The first account you create is the admin. After that, sign-ups are off: `ENABLE_SIGNUP=false` in `compose.yaml`, and Open WebUI turns them off by itself after the first account anyway. Anyone else who needs an account, the admin adds in Admin Panel, Users.

Then pick a model and ask it something.

## 7. Prove it

```bash
~/stacks/episodes/02-local-ai/checks/verify-ai.sh
```

Six checks: Ollama publishes nothing, Open WebUI is on localhost only, sign-ups are off, telemetry and cloud are off, the model runs on the GPU, the images are pinned. Then from another device on the same network (a phone with Termux works):

```bash
nmap -Pn -p 3000,11434 <this-machine-ip>           # both closed or filtered
```

And the offline test: turn off Wi-Fi (and unplug the cable), open a new chat, ask again. It still answers.

## 8. Updates and backups

**Updates are on purpose.** Once a month, check the [Ollama](https://github.com/ollama/ollama/releases) and [Open WebUI](https://github.com/open-webui/open-webui/releases) releases. To update, change the tag and digest in `compose.yaml` (get the digest with `docker pull <image>:<tag>`, it prints it), then:

```bash
docker compose pull && docker compose up -d
~/stacks/episodes/02-local-ai/checks/verify-ai.sh
```

Open WebUI releases can change its database. Back up first (below).

**Back up the chats.** Models you can pull again. Accounts, chats and settings live in the `local-ai_webui` volume. With [restic](https://restic.net) (`sudo dnf install restic` or `sudo apt install restic`) to a USB disk or any restic repository:

```bash
install -m 600 /dev/null ~/.config/restic-local-ai.pw
openssl rand -base64 32 > ~/.config/restic-local-ai.pw
export RESTIC_REPOSITORY=/run/media/$USER/backup/local-ai
export RESTIC_PASSWORD_FILE=~/.config/restic-local-ai.pw
restic init                                        # once
docker compose stop open-webui
sudo -E restic backup \
  /var/lib/docker/volumes/local-ai_webui/_data
docker compose start open-webui
```

Stopping Open WebUI for the backup keeps its database consistent; it takes a few seconds. Keep a copy of the password file somewhere else: without it, the backup can't be read.

To restore: stop Open WebUI, `sudo -E restic restore latest --target /` puts the files back in place, start it again.

## 9. AMD, Mac, or no GPU

- **AMD:** use `ollama/ollama:rocm` (pin it the same way), replace `gpus: all` with `devices: ["/dev/kfd", "/dev/dri"]`. See Ollama's [Docker docs](https://github.com/ollama/ollama/blob/main/docs/docker.mdx).
- **Mac:** Docker can't use the Mac's GPU. Install Ollama natively (it listens on `127.0.0.1` only), delete the `ollama` service from `compose.yaml`, and set `OLLAMA_BASE_URL: http://host.docker.internal:11434` for Open WebUI. Keep `OLLAMA_HOST` unset, so Ollama stays on localhost.
- **No GPU:** delete the `gpus: all` line. Stick to small models (`qwen3:4b` or smaller); it works, slowly.

The private part (no ports, localhost only, no sign-ups, no cloud) stays the same everywhere.
