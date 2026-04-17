# Homelab Template

A git-driven deployment system for self-hosted Docker Compose services on a single VPS. No Kubernetes, no Terraform — just Docker Compose, GitHub Actions, and optional secret management with [Infisical](https://infisical.com).

## What this gives you

- **Git as the source of truth** for all your service configurations
- **Automatic deploys** when you push changes to this repo or merge code in a service repo
- **Secret management via UI** instead of SSH-ing into your server to edit `.env` files
- **Easy onboarding** for new services — add a folder, push, deploy

## Architecture

```
┌──────────────────┐         ┌──────────────────┐
│  Service Repos   │         │   This Repo      │
│  (your apps)     │         │   (homelab)       │
│                  │         │                   │
│  build & push    │ ──────► │  deploy workflow  │
│  Docker image    │ dispatch│  SSHes into VPS   │
└──────────────────┘         └────────┬──────────┘
                                      │
                             ┌────────▼──────────┐
                             │      VPS          │
                             │                   │
                             │  git pull         │
                             │  pull secrets     │
                             │  docker compose   │
                             │  up -d            │
                             └───────────────────┘
```

There are two types of services:

| Type | Example | Deployed by | Secrets |
|------|---------|-------------|---------|
| **Infra service** | Dozzle, Traefik, Pi-hole | Push to this repo | Optional |
| **App service** | Your custom app with its own repo | Push to the app's repo → dispatches here | Optional |

## Repository structure

```
homelab/
├── .github/
│   └── workflows/
│       ├── deploy-infra.yml      # Deploys on push to this repo
│       └── deploy-service.yml    # Deploys on dispatch from service repos
├── scripts/
│   └── deploy.sh                 # Shared deploy logic
├── services/
│   ├── example-app/
│   │   └── compose.yml           # App with its own repo + secrets
│   └── example-static-site/
│       └── compose.yml           # Simple service, no secrets
├── infisical-projects.json       # Maps services to Infisical project IDs
├── .gitignore
└── README.md
```

## Prerequisites

- A VPS running Docker (tested on Ubuntu 22.04+)
- GitHub account with Actions enabled
- Docker installed on the VPS with your deploy user in the `docker` group
- A reverse proxy (this template assumes Traefik, but any will work)

## Setup

### 1. Use this template

Click **"Use this template"** on GitHub, or clone and reinitialize:

```bash
git clone https://github.com/jallalcode/homelab-template.git homelab
cd homelab
rm -rf .git && git init
```

### 2. Set up your VPS

Clone the repo on your VPS:

```bash
git clone git@github.com:YOUR_USER/homelab.git /opt/homelab
```

Make the deploy script executable:

```bash
chmod +x /opt/homelab/scripts/deploy.sh
```

Ensure your deploy user can run Docker without sudo:

```bash
sudo usermod -aG docker $USER
# Log out and back in
```

### 3. Configure GitHub secrets

Add these secrets to your homelab repo (Settings → Secrets and variables → Actions):

| Secret | Purpose |
|--------|---------|
| `VPS_HOST` | Your VPS hostname or IP |
| `VPS_USER` | SSH user on the VPS |
| `VPS_SSH_KEY` | SSH private key for that user |

If using Infisical for secret management, also add:

| Secret | Purpose |
|--------|---------|
| `INFISICAL_CLIENT_ID` | Machine identity Client ID (from Universal Auth config) |
| `INFISICAL_CLIENT_SECRET` | Machine identity Client Secret |

### 4. (Optional) Set up Infisical

If any of your services need secrets (database passwords, API keys, etc.), set up Infisical:

1. Self-host Infisical or use [Infisical Cloud](https://app.infisical.com)
2. Create an organization and a Machine Identity with Universal Auth
3. For each service that needs secrets, create a project and add the Machine Identity to it
4. Install the Infisical CLI on your VPS:
   ```bash
   curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | sudo -E bash
   sudo apt-get install -y infisical
   ```
5. Update `INFISICAL_API_URL` in `scripts/deploy.sh` to point to your Infisical instance

If you don't need secret management, everything still works — services without an Infisical project ID simply skip the secret injection step.

## Adding services

### Infra service (no separate repo)

For services like Dozzle, Traefik, Uptime Kuma — things you pull from a registry and configure:

**1.** Create a folder under `services/`:

```bash
mkdir services/my-service
```

**2.** Add a `compose.yml`:

```yaml
name: my-service

services:
  app:
    image: some-image:latest
    container_name: my-service
    restart: unless-stopped
    labels:
      - traefik.enable=true
      - traefik.http.routers.my-service.rule=Host(`my-service.example.com`)
      - traefik.http.routers.my-service.entrypoints=websecure
      - traefik.http.routers.my-service.tls=true
      - traefik.http.routers.my-service.tls.certresolver=le
      - traefik.http.services.my-service.loadbalancer.server.port=8080
    networks:
      - web

networks:
  web:
    external: true
```

**3.** Register the service in `infisical-projects.json` (even without secrets):

```json
{
  "my-service": ""
}
```

**4.** Add the path trigger in `deploy-infra.yml`:

```yaml
paths:
  - 'services/my-service/**'
```

**5.** If the service needs secrets, create an Infisical project, add the secrets, and put the project ID in `infisical-projects.json`:

```json
{
  "my-service": "your-infisical-project-id"
}
```

**6.** Push to `main`. The workflow deploys automatically.

### App service (has its own repo)

For services you build yourself — your app has its own repo with a Dockerfile:

**1.** Follow steps 1–5 above for the infra side.

**2.** Add a skip entry in `deploy-infra.yml` so pushes to this repo don't double-deploy:

```yaml
case "$dir" in
  my-app) continue ;;
esac
```

**3.** In your app's repo, add a release workflow. Here's a minimal example:

```yaml
# .github/workflows/release.yml
name: Release

on:
  push:
    branches: [main]

permissions:
  packages: write

env:
  IMAGE_NAME: ghcr.io/${{ github.repository_owner }}/${{ github.event.repository.name }}

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ${{ env.IMAGE_NAME }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - name: Trigger homelab deploy
        run: |
          curl -fsSL -X POST \
            -H "Accept: application/vnd.github+json" \
            -H "Authorization: Bearer ${{ secrets.INFRA_DISPATCH_TOKEN }}" \
            https://api.github.com/repos/${{ github.repository_owner }}/homelab/dispatches \
            -d '{"event_type":"deploy","client_payload":{"service":"${{ github.event.repository.name }}"}}'
```

**4.** Add an `INFRA_DISPATCH_TOKEN` secret to the app repo — a GitHub PAT with `repo` scope.

The repo name must match the folder name under `services/`.

## Secret management

Secrets flow like this:

```
Infisical UI  →  deploy.sh exports to .env  →  Docker Compose reads .env
```

The `.env` files are generated at deploy time and never committed to git. The `.gitignore` ensures this.

For services **with** secrets:
- Add secrets to an Infisical project via the web UI
- Add the Infisical project ID to `infisical-projects.json`
- The deploy script pulls secrets automatically

For services **without** secrets:
- Leave the project ID as `""` in `infisical-projects.json`
- The deploy script skips secret injection

### Variable mapping

If your app expects different variable names than what you store in Infisical, you have two options:

**Option A (recommended):** Store variables in Infisical with the names your app expects. If your app needs both `POSTGRES_PASSWORD` (for the db) and `SPRING_DATASOURCE_PASSWORD` (for the app), store both in Infisical with the same value.

**Option B:** Use the compose `environment:` block to map variables, with `env_file: .env` providing the base values. See `services/example-app/compose.yml` for an example.

## Migrating from Portainer

If you're moving services from Portainer, follow this process for each service:

1. **Check the project name:** `docker compose ls` — note the NAME column
2. **Set `name:` in your compose file** to match exactly (this ensures Docker reuses existing volumes)
3. **Back up any databases** before migrating:
   ```bash
   docker exec <db-container> pg_dump -U <user> <database> > ~/backup.sql
   ```
4. **Add the service** to this repo and push
5. **Deploy** from the new location (the project name match means volumes are reattached)
6. **Remove from Portainer** — stop the stack in Portainer, then delete it. Bring it back up from the homelab directory. It will reappear in Portainer as "Limited" control.

## Manual deploy

From the GitHub Actions UI:
- Go to Actions → "Deploy Infra Services" or "Deploy Service" → Run workflow → enter the service name

From the VPS:

```bash
cd /opt/homelab

# Without secrets
bash scripts/deploy.sh my-service

# With secrets (requires INFISICAL_CLIENT_ID and INFISICAL_CLIENT_SECRET in env)
export INFISICAL_CLIENT_ID=<your-client-id>
export INFISICAL_CLIENT_SECRET=<your-client-secret>
bash scripts/deploy.sh my-service <infisical-project-id>
```

## FAQ

**Do I need Infisical?**
No. If none of your services have secrets, everything works without it. The deploy script skips secret injection when no project ID is provided.

**Can I use a different secret manager?**
Yes. Replace the Infisical CLI calls in `deploy.sh` with your tool of choice (Doppler, Vault, etc). The rest of the system is secret-manager-agnostic.

**Can I use this with multiple VPS instances?**
The workflows assume a single VPS. For multiple servers, you'd duplicate the deploy steps or parameterize the SSH target.

**Why two workflows?**
`deploy-infra.yml` triggers on push to this repo (for services without their own repos). `deploy-service.yml` triggers on `repository_dispatch` (for services with their own repos that build and push images). They share the same `deploy.sh` and concurrency group.

**What about Traefik configuration?**
This template assumes you already have Traefik running. Each service's compose file includes the Traefik labels it needs. If you use a different reverse proxy, adjust the labels accordingly.