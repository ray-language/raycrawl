#!/bin/sh
# Throughput of raycrawl against the local fixture site: native vs VM, 1 vs N fetchers per
# host, 1 vs 4 hosts. Each host reuses its connections (http.pool_stream), so a run leaves
# almost nothing in TIME_WAIT; the drain stays as a guard (a fresh connection per request, as
# before net 0.17, piled up ~PAGES sockets and ran the ephemeral ports out).
set -eu
PAGES=${PAGES:-1500}
cd "$(dirname "$0")/.."
[ -x ./raycrawl ] || { echo "build first: make build" >&2; exit 1; }

drain() {
    while [ "$(netstat -an -p tcp | grep -c TIME_WAIT)" -gt 1000 ]; do sleep 2; done
}

run() {
    drain
    "$@"
}

for ph in 1 4 16; do
    run ./raycrawl bench --pages "$PAGES" --per-host "$ph" | sed 's/^/native /'
    run ray run . bench --pages "$PAGES" --per-host "$ph" | sed 's/^/vm     /'
done
run ./raycrawl bench --pages $((PAGES / 4)) --per-host 4 --hosts 4 | sed 's/^/native /'
run ray run . bench --pages $((PAGES / 4)) --per-host 4 --hosts 4 | sed 's/^/vm     /'
