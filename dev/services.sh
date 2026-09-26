#!/usr/bin/env bash
#
# The services the suite's :postgres and :s3 tests reach, as Docker containers:
# Postgres on port 54329 and MinIO, an S3 service, on port 59000.
#
#   dev/services.sh          start them, or start them again where they stopped
#   dev/services.sh stop     remove them, and what they held
#
# The suite reads WARDRIK_TEST_DATABASE_URL, WARDRIK_TEST_S3_ENDPOINT,
# WARDRIK_TEST_S3_ACCESS_KEY_ID and WARDRIK_TEST_S3_SECRET_ACCESS_KEY, and
# reaches these containers where they are unset. Without them it skips those
# tests and says so.
set -euo pipefail

postgres_image=${WARDRIK_TEST_POSTGRES_IMAGE:-postgres:17-alpine}
s3_image=${WARDRIK_TEST_S3_IMAGE:-cgr.dev/chainguard/minio:latest}

start() {
  local name=$1
  shift

  if docker container inspect "$name" >/dev/null 2>&1; then
    docker start "$name" >/dev/null
  else
    docker run -d --name "$name" "$@" >/dev/null
  fi

  echo "$name is up"
}

case "${1:-start}" in
  start)
    start wardrik-test-postgres -p 54329:5432 -e POSTGRES_PASSWORD=postgres "$postgres_image"
    start wardrik-test-s3 -p 59000:9000 \
      -e MINIO_ROOT_USER=wardrik -e MINIO_ROOT_PASSWORD=wardrik-secret "$s3_image" server /data
    ;;
  stop)
    docker rm -f wardrik-test-postgres wardrik-test-s3 >/dev/null 2>&1 || true
    echo "removed wardrik-test-postgres and wardrik-test-s3"
    ;;
  *)
    echo "usage: dev/services.sh [start|stop]" >&2
    exit 64
    ;;
esac
