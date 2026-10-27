#!/usr/bin/env bash

set -u

REPORTS_DIR="${1:-${REPORTS_DIR:-security-reports}}"
REVIEW_FILE="$REPORTS_DIR/Agentreview.json"

export REVIEW_FILE
export FAIL_ON_SEVERITIES="${FAIL_ON_SEVERITIES:-BLOCKER,HIGH}"
export FAIL_ON_VERDICT="${FAIL_ON_VERDICT:-false}"
ON_REPORT_ERROR="${ON_REPORT_ERROR:-fail}"

report_error() {
  if [ "$ON_REPORT_ERROR" = "warn" ]; then
    echo "GATE: WARNING - laporan tidak bisa dievaluasi, gate dilewati (ON_REPORT_ERROR=warn)"
    exit 0
  fi
  echo "GATE: GAGAL - laporan tidak bisa dievaluasi (ON_REPORT_ERROR=fail)"
  exit 1
}

if ! command -v python3 >/dev/null 2>&1; then
  echo "GATE: python3 tidak ditemukan"
  report_error
fi

python3 - <<'PY'
import json, os, sys

review_file = os.environ["REVIEW_FILE"]
fail_verdict = os.environ["FAIL_ON_VERDICT"].lower() == "true"

# Skala MQR: INFO < LOW < MEDIUM < HIGH < BLOCKER
VALID = {"INFO", "LOW", "MEDIUM", "HIGH", "BLOCKER"}

fail_sevs = []
for s in os.environ["FAIL_ON_SEVERITIES"].split(","):
    s = s.strip().upper()
    if s and s in VALID and s not in fail_sevs:
        fail_sevs.append(s)

if not fail_sevs:
    print("GATE: FAIL_ON_SEVERITIES tidak valid (gunakan BLOCKER,HIGH,MEDIUM,LOW,INFO)")
    sys.exit(2)

failed = False

try:
    with open(review_file) as f:
        review = json.load(f)
except Exception as e:
    print(f"GATE: tidak bisa membaca {review_file}: {e}")
    sys.exit(2)

sev = review.get("counts", {}).get("by_severity", {})
verdict = review.get("overall_assessment", {}).get("verdict", "UNKNOWN")
print(f"GATE [Agentreview.json]: verdict={verdict} " +
      " ".join(f"{k}={sev.get(k, 0)}" for k in fail_sevs))

for s in fail_sevs:
    n = sev.get(s, 0)
    if n > 0:
        print(f"GATE:   -> {s} ditemukan: {n}")
        failed = True

if fail_verdict and verdict == "NOT_READY":
    print("GATE:   -> verdict NOT_READY")
    failed = True

if failed:
    print("GATE: GAGAL - ada finding yang melewati batas")
    sys.exit(1)

print("GATE: LOLOS")
sys.exit(0)
PY
rc=$?

if [ "$rc" -eq 2 ]; then
  report_error
fi
exit "$rc"
