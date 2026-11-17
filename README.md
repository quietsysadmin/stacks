# Quiet Sysadmin stacks

Production-grade self-hosting for developers and small teams: hardened, reproducible Docker, Laravel and local-AI stacks.

Every command from the [Quiet Sysadmin](https://www.youtube.com/@quietsysadmin) videos ships here. Each one is run for real on a fresh server before it goes on camera.

## Layout

```
base/                  the foundation from episode 1, reused by later episodes
episodes/NN-slug/      one folder per video: a README with the steps, plus every file it uses
```

## Episodes

| # | Video | Folder |
|---|---|---|
| 01 | [A production-ready Docker host from scratch](https://www.youtube.com/watch?v=DIXj4kf2WK0) | [`episodes/01-production-docker-host`](episodes/01-production-docker-host/) |
| 02 | [Run local AI privately: Ollama + Open WebUI, hardened](https://www.youtube.com/watch?v=UVTyFuveb9Y) | [`episodes/02-local-ai`](episodes/02-local-ai/) |

Made by Vasileios Ntoufoudis, maintainer of [Laravel Chronicle](https://github.com/laravel-chronicle/core). Newsletter: https://quietsysadmin.com

## License

[MIT](LICENSE). Use the commands and configs in your own setups, commercial ones included.
