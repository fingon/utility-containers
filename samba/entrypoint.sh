#!/usr/bin/env bash
set -Eeuo pipefail

exec /usr/sbin/smbd --no-process-group --foreground --debug-stdout
