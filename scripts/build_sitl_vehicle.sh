#!/usr/bin/env bash
# Build one ArduPilot SITL vehicle with the Cygwin toolchain (Mission Planner style).
# Expects to run inside a Cygwin bash with the ardupilot tree as CWD.
set -euo pipefail
set -x

WAF_TARGET="${1:?waf target required (plane|copter|rover|sub)}"
ARTIFACT_NAME="${2:?artifact file name required (e.g. ArduPlane.elf)}"
BINARY_NAME="${3:?build/sitl/bin name required (e.g. arduplane)}"

TOOLCHAIN=x86_64-pc-cygwin
GPP_COMPILER="${TOOLCHAIN}-g++"

"${GPP_COMPILER}" -print-sysroot
SYS_ROOT="$("${GPP_COMPILER}" -print-sysroot)"
echo "SYS_ROOT=${SYS_ROOT}"

rm -rf artifacts
mkdir -p artifacts

if [[ -z "${GITHUB_ACTIONS:-}" || "${GITHUB_ACTIONS}" != "true" ]]; then
  WAF_OPTIONS="-j8"
else
  WAF_OPTIONS=""
fi

{
  python3 ./waf --color yes --toolchain "${TOOLCHAIN}" --board sitl configure 2>&1
  # shellcheck disable=SC2086
  python3 ./waf "${WAF_TARGET}" ${WAF_OPTIONS} 2>&1
} | tee artifacts/build.txt

BIN_PATH="build/sitl/bin/${BINARY_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
  echo "Missing build output: ${BIN_PATH}" >&2
  ls -la build/sitl/bin/ || true
  exit 1
fi

cp -v "${BIN_PATH}" "artifacts/${ARTIFACT_NAME}"
# cygcheck resolves DLL deps more reliably with an .exe suffix
cp -v "${BIN_PATH}" "artifacts/${ARTIFACT_NAME}.exe"

while read -r line; do
  cp -v "/usr/bin/${line}" artifacts/
done < <(cygcheck "artifacts/${ARTIFACT_NAME}.exe" | grep -oP 'cyg[^\s\\/]+\.dll' | sort -u)

rm -f "artifacts/${ARTIFACT_NAME}.exe"

git log -1 > artifacts/git.txt
printf '%s\n' \
  "vehicle_waf=${WAF_TARGET}" \
  "artifact=${ARTIFACT_NAME}" \
  "binary=${BINARY_NAME}" \
  "toolchain=${TOOLCHAIN}" \
  > artifacts/vgcs-sitl.txt

ls -l artifacts/
