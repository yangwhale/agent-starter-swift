#!/usr/bin/env bash
# run the exporter for every line of a job file inside one container:
#   each line: <skin> <look> <t0> <dur> <fps> <seed> <outfile> [mode]
set -euo pipefail
w="$1"; jobs="$2"
root="${FACEBENCH:-/tmp/facebench}"
docker run --rm -v "$w":/w -v "$root":"$root" -w /w swift:6.2-noble bash -c "
while read -r sk lk t0 du fp sd of md; do ./export \$sk \$lk \$t0 \$du \$fp \$sd \$md > \$of; done < $jobs"
