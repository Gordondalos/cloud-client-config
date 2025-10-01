Cloud Client Config – Development Guidelines

Scope
These notes capture project-specific details to help advanced contributors work efficiently. They focus on: build/configuration, testing, and development practices particular to this repository.

Overview of this repo
- Purpose: Quickly provision and run a client stack in an infrastructure environment using Docker Compose.
- Entrypoints:
  - generate-compose.sh – renders docker-compose.yml from docker-compose.template.yml and .env.
  - update.sh – end-to-end update flow: pulls repo, pulls images, generates compose, brings services up, waits for bd-proxy-$BD_PROXY_ID to become healthy, then triggers migrations in the container.
- Package.json convenience scripts:
  - npm run generate-docker-compose → ./generate-compose.sh
  - npm run start → npm run generate-docker-compose && docker compose up -d
  - npm run update → ./update.sh

Build/Configuration Instructions
Prerequisites (local or target server):
- Docker Engine 24+ and Docker Compose v2 (docker compose …)
- bash, coreutils, grep, sed
- envsubst (from GNU gettext) – used by generate-compose.sh
- git and npm (npm only for running the provided scripts; Node runtime is not otherwise used here)

Required environment (.env):
At minimum the following are required for successful compose generation and boot:
- BD_PROXY_ID – integer identifier of the client instance. Used to name services/containers (db-$BD_PROXY_ID, bd-proxy-$BD_PROXY_ID).
- IMAGE_TAG – tag to pull for kreditpro-proxy-bd image (e.g., latest or a release tag).
- TZ – time zone string (e.g., Europe/Moscow) propagated into containers.
Additional variables may be used by downstream services or in your environment (see readme.md examples):
- MYSQL_HOST, API_PROXY_BD_SERVER_PORT – referenced in documentation/infra but not enforced by scripts.

How compose rendering works:
- generate-compose.sh will:
  1) source .env (fail if BD_PROXY_ID is missing),
  2) pre-replace occurrences of db-${BD_PROXY_ID} and bd-proxy-${BD_PROXY_ID} in service keys and container_name (sed) so that the literal keys get the numeric ID (envsubst does not substitute inside compose keys reliably),
  3) run envsubst over the result to substitute remaining ${VAR}s,
  4) write docker-compose.yml.
- Optional promtail support: if traefik-config/promtail-config.yml exists, it will be rendered to traefik-config/promtail-config.rendered.yml via envsubst. The repository does not include this file by default; the step is skipped when absent.

update.sh flow details:
- Writes logs to Update.log in repo root (stdout/stderr redirected).
- git pull is attempted first (non-fatal on failure).
- Loads .env and derives CONTAINER_NAME="bd-proxy-${BD_PROXY_ID}".
- docker compose pull (best-effort) to pre-pull images.
- npm run start: generates compose and brings services up detached.
- Waits up to ~60 seconds (30 × 2s) for the bd-proxy container to reach running status.
- Executes migrations inside the bd-proxy container with: docker exec -i "$CONTAINER_NAME" /bin/sh -c "npm run migrate-run".
  - Assumes the image kreditpro-proxy-bd contains an npm script migrate-run. If your image changes, ensure this remains available or update the script accordingly.

Networking/volumes specifics:
- Compose defines a custom bridge network mynetwork with subnet 10.10.30.0/24.
- MySQL service exposes 3307:3306 by default and mounts:
  - Named volume fnt-db for persistent data
  - ./mysql.cnf to MySQL config locations
  - ./scripts to /docker-entrypoint-initdb.d (optional; add init scripts there if needed)

Testing Information
Test model (bash-based):
- There is no dedicated test framework in this repo. For quick validation, prefer small bash scripts that run generate-compose.sh with a controlled .env and assert on the rendered docker-compose.yml.
- Keep tests ephemeral (do not commit them) unless you establish a formal test layout. The CI/CD story is currently out of scope for this repo.

How to run tests locally:
1) Prepare a controlled .env and run the generator:
   - Example values used for verification:
     BD_PROXY_ID=12
     TZ=Europe/Moscow
     IMAGE_TAG=latest
2) Run the generator and assert outputs. For convenience, here is an example sequence you can paste into your shell:
   cp -a . ._backup >/dev/null 2>&1 || true
   cat > .env <<'ENV' 
   BD_PROXY_ID=12
   TZ=Europe/Moscow
   IMAGE_TAG=latest
   ENV
   ./generate-compose.sh
   test -f docker-compose.yml
   grep -q "container_name: db-12" docker-compose.yml
   grep -q "container_name: bd-proxy-12" docker-compose.yml
   grep -q "image: kreditpro.org:445/kreditpro/kreditpro-proxy-bd:latest" docker-compose.yml
   echo "compose generation OK"
   # cleanup
   rm -f docker-compose.yml .env
   rm -rf ._backup

Guidelines for adding new tests:
- Create a temporary bash script that:
  - Writes a controlled .env with explicit BD_PROXY_ID, TZ, IMAGE_TAG.
  - Invokes ./generate-compose.sh.
  - Greps docker-compose.yml for the expected substitutions (service names and image tag).
  - Restores any pre-existing docker-compose.yml and .env or removes the ones it created.
- If you need to validate update.sh logic without Docker, you can dry-run portions by setting BD_PROXY_ID and mocking docker/grep with small wrappers on PATH in a temporary environment, but prefer not to commit such tooling.

Notes and gotchas:
- envsubst must be present; if missing, generate-compose.sh will fail. On Debian/Ubuntu: apt-get install -y gettext-base.
- BD_PROXY_ID is mandatory. The generator will exit early if it is not set in .env.
- If you introduce new variables into docker-compose.template.yml, ensure they are documented and have sensible defaults or are validated in generate-compose.sh.
- update.sh assumes Docker Compose v2 (docker compose). If only docker-compose v1 is available, either install v2 or adapt the script accordingly.
- Migrations: The update script relies on an npm script inside the bd-proxy container. Validate that your image publishes the required script when updating images.

Code style and conventions:
- Shell scripts:
  - Use set -e (and -u/-o pipefail where appropriate) to fail fast.
  - Keep scripts idempotent where possible; avoid leaving temporary artifacts in the workspace.
  - Prefer explicit checks and informative error messages (as already used in generate-compose.sh).
- Compose:
  - Keep service names deterministic and derived from BD_PROXY_ID to avoid collisions across environments.
  - Log rotation is already configured via json-file driver with size/file limits; preserve or extend as needed.

Validated example (manually executed while writing this document):
- Using the sample .env (BD_PROXY_ID=12, TZ=Europe/Moscow, IMAGE_TAG=latest), ./generate-compose.sh produced docker-compose.yml with:
  - container_name: db-12
  - container_name: bd-proxy-12
  - image: kreditpro.org:445/kreditpro/kreditpro-proxy-bd:latest
- After verification, temporary files were removed to keep the repo clean.

Housekeeping
- Do not commit environment-specific artifacts (docker-compose.yml, .env, Update.log). Keep them local.
- When adding new configuration templates, ensure they render via envsubst and provide clear warnings if optional files are missing (pattern used for promtail).
