#!/usr/bin/env bash
# Deploys exactly one app+environment. Structurally can't touch any other
# environment on the box — it only ever cd's into the one directory named
# by its arguments, and only ever runs `docker compose` from inside it.
#
# Usage: ./deploy.sh <node-app|java-app> <dev|qa> [tag]
#   dev:  tag optional, defaults to "dev" (the floating tag CI pushes on every merge)
#   qa:   tag required — an explicit commit SHA/build tag being promoted, e.g.:
#         ./deploy.sh node-app qa a1b2c3d

set -euo pipefail

APP="${1:?usage: deploy.sh <node-app|java-app> <dev|qa> [tag]}"
ENV="${2:?usage: deploy.sh <node-app|java-app> <dev|qa> [tag]}"
TAG="${3:-}"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/${APP}/${ENV}"
[ -d "$DIR" ] || { echo "no such app/env: $APP/$ENV" >&2; exit 1; }

cd "$DIR"

# Refresh the secret bundle from Secrets Manager on every deploy — never
# read from a file checked into git. Empty-but-present if there are none yet,
# so env_file doesn't fail on a missing file.
SECRET_ID="varunerp/${APP}/${ENV}"
aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text \
  | jq -r 'to_entries | map("\(.key)=\(.value)") | .[]' > .env.secrets \
  || touch .env.secrets

if [ "$ENV" = "qa" ]; then
  [ -n "$TAG" ] || { echo "qa deploys require an explicit tag (the SHA being promoted)" >&2; exit 1; }
  VAR_NAME="$(echo "${APP}" | tr '-' '_' | tr '[:lower:]' '[:upper:]' | sed 's/_APP$//')_QA_TAG"
  export "${VAR_NAME}=${TAG}"
fi

# Refresh ECR auth on every deploy — the token expires after 12h and this
# box has no other login mechanism (see TailscaleSSMRole's ecr:GetAuthorizationToken grant).
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin 043207749006.dkr.ecr.us-east-1.amazonaws.com

# Explicit project name — compose otherwise infers it from the cwd's
# basename, which is just "dev"/"qa" for every app (each app's directory is
# docker/<app>/<env>). Two apps sharing a box (react-external-app and
# react-support-app both currently do) would then collide on the same
# implicit project name, and `--remove-orphans` on one app's deploy would
# tear down the other's container as an "orphan".
COMPOSE_PROJECT="${APP}-${ENV}"

docker compose -p "$COMPOSE_PROJECT" pull
docker compose -p "$COMPOSE_PROJECT" up -d --remove-orphans
docker image prune -f
