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

# ArduPilot 4.5.x waf still imports stdlib `imp` (removed in Python 3.12).
PYTHON_BIN="${PYTHON_BIN:-python3.9}"
if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  PYTHON_BIN=python3
fi
"${PYTHON_BIN}" -c "import imp" >/dev/null


{
  "${PYTHON_BIN}" ./waf --color yes --toolchain "${TOOLCHAIN}" --board sitl configure 2>&1
  # shellcheck disable=SC2086
  "${PYTHON_BIN}" ./waf "${WAF_TARGET}" ${WAF_OPTIONS} 2>&1
} | tee artifacts/build.txt

BIN_PATH="build/sitl/bin/${BINARY_NAME}"
if [[ ! -f "${BIN_PATH}" ]]; then
  echo "Missing build output: ${BIN_PATH}" >&2
  ls -la build/sitl/bin/ || true
  exit 1
fi

cp -v "${BIN_PATH}" "artifacts/${ARTIFACT_NAME}"

# Cygwin treats "name" and "name.exe" as the same path. Never use
# "${ARTIFACT_NAME}.exe" (e.g. ArduPlane.elf.exe) — `rm` would delete ArduPlane.elf too.
PROBE_EXE="artifacts/_vgcs_cygcheck_probe.exe"
cp -v "${BIN_PATH}" "${PROBE_EXE}"

while read -r line; do
  cp -v "/usr/bin/${line}" artifacts/
done < <(cygcheck "${PROBE_EXE}" | grep -oP 'cyg[^\s\\/]+\.dll' | sort -u)

rm -f "${PROBE_EXE}"

# Windows-friendly sibling (safe: ArduPlane.exe ≠ ArduPlane.elf under Cygwin rules)
EXE_NAME="${ARTIFACT_NAME%.elf}.exe"
if [[ "${EXE_NAME}" != "${ARTIFACT_NAME}" ]]; then
  cp -v "${BIN_PATH}" "artifacts/${EXE_NAME}"
fi

if [[ ! -f "artifacts/${ARTIFACT_NAME}" ]]; then
  echo "Primary artifact vanished after cygcheck staging: artifacts/${ARTIFACT_NAME}" >&2
  ls -la artifacts/ || true
  exit 1
fi

git log -1 > artifacts/git.txt
printf '%s\n' \
  "vehicle_waf=${WAF_TARGET}" \
  "artifact=${ARTIFACT_NAME}" \
  "exe=${EXE_NAME:-}" \
  "binary=${BINARY_NAME}" \
  "toolchain=${TOOLCHAIN}" \
  > artifacts/vgcs-sitl.txt

ls -l artifacts/
