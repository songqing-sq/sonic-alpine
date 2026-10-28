#!/usr/bin/env bash
# Validate the selected Lemming source; leave Alpine's package build unchanged.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
evidence="${RUNNER_TEMP:?}/lemming-evidence"
mkdir -p "$evidence"
test "$(uname -m)" = "${EXPECTED_MACHINE:?}"
git -C "$root" rev-parse HEAD > "$evidence/alpine-commit.txt"
git -C "$root" ls-tree HEAD src/libsai-grpc/lemming > "$evidence/gitlink.txt"
uname -a > "$evidence/uname.txt"
dpkg --print-architecture > "$evidence/userspace.txt"

# Shared read-only checker from build-infra #70. Keep this immutable input
# separate from the Lemming runtime and verify its bytes before execution.
curl --fail --location --retry 3 \
  https://raw.githubusercontent.com/securely1g/sonic-build-infra/3acb4ae8a2376702af176bb3dae12f0fe1eb7813/go/lock.py \
  --output "$evidence/go-lock.py"
printf '%s  %s\n' \
  1045db8ba6e6995309a0b2c02b904173e374a55a57336e4c799b9b34da066fe0 \
  "$evidence/go-lock.py" | sha256sum --check

cd "$root/src/libsai-grpc/lemming"
git rev-parse HEAD > "$evidence/lemming-commit.txt"
test "$(git rev-parse HEAD)" = "$(git -C "$root" rev-parse HEAD:src/libsai-grpc/lemming)"
git diff --exit-code
head -n 1 .bazelversion | grep -Fx 8.4.1
cp MODULE.bazel .bazelrc go.zip.sums.json "$evidence/"
# Upstream tracks its generated lock. Prove this consumer works without it,
# retain the newly generated resolution, then restore the upstream checkout.
mv MODULE.bazel.lock "$evidence/upstream-MODULE.bazel.lock"
trap 'if [ -f MODULE.bazel.lock ]; then cp MODULE.bazel.lock "$evidence/MODULE.bazel.lock"; fi; cp "$evidence/upstream-MODULE.bazel.lock" MODULE.bazel.lock' EXIT
bazel --version > "$evidence/bazel-version.txt"
python3 "$evidence/go-lock.py" --bazel bazel \
  --bazel-option=--lockfile_mode=update \
  --plan '@go_zip_lock_plan//:zip-lock.json' --check \
  2>&1 | tee "$evidence/go-lock-check.log"
bazel test --lockfile_mode=update --nocache_test_results \
  --test_output=errors --build_event_json_file="$evidence/test-events.jsonl" \
  //internal/config:config_test 2>&1 | tee "$evidence/test.log"
testlogs="$(bazel info bazel-testlogs)"
cp -L "$testlogs/internal/config/config_test/test.xml" "$evidence/config-test.xml"
cp MODULE.bazel.lock "$evidence/MODULE.bazel.lock"
git diff --exit-code -- . ':!MODULE.bazel.lock'
cmp go.zip.sums.json "$evidence/go.zip.sums.json"
sha256sum "$evidence/"* > "$evidence/files.sha256"
