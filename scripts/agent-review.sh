#!/usr/bin/env bash
#
# agent-review.sh - Quality gate untuk hasil AI review & SonarQube.
#
# Usage:
#   ./scripts/agent-review.sh [REPORTS_DIR]
#
# Exit code (dipakai Jenkins untuk menentukan status build):
#   0 = lolos
#   1 = GAGAL (ada BLOCKER/CRITICAL, atau laporan tidak bisa dievaluasi)
#
# Environment (opsional):
#   FAIL_ON_SEVERITIES  default "BLOCKER,CRITICAL"
#   FAIL_ON_VERDICT     "true" untuk ikut gagal jika verdict = NOT_READY (default: false)
#   CHECK_SONAR_RAW     "true" untuk cross-check sonar_raw.json (default: true)
#   ON_REPORT_ERROR     "fail" (default) = build gagal jika Agentreview.json hilang/rusak
#                       "warn" = hanya tampilkan peringatan, build tetap lolos

set -u

REPORTS_DIR="${1:-${REPORTS_DIR:-security-reports}}"
REVIEW_FILE="$REPORTS_DIR/Agentreview.json"
SONAR_FILE="$REPORTS_DIR/sonar_raw.json"

export REVIEW_FILE SONAR_FILE
export FAIL_ON_SEVERITIES="${FAIL_ON_SEVERITIES:-BLOCKER,CRITICAL}"
export FAIL_ON_VERDICT="${FAIL_ON_VERDICT:-false}"
export CHECK_SONAR_RAW="${CHECK_SONAR_RAW:-true}"
ON_REPORT_ERROR="${ON_REPORT_ERROR:-fail}"

# Dipanggil saat laporan tidak bisa dievaluasi
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
sonar_file  = os.environ["SONAR_FILE"]
fail_sevs   = [s.strip().upper() for s in os.environ["FAIL_ON_SEVERITIES"].split(",") if s.strip()]
fail_verdict = os.environ["FAIL_ON_VERDICT"].lower() == "true"
check_sonar  = os.environ["CHECK_SONAR_RAW"].lower() == "true"

failed = False

# --- 1. Agentreview.json (hasil AI) ---
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
    if sev.get(s, 0) > 0:
        print(f"GATE:   -> {s} ditemukan: {sev[s]}")
        failed = True

if fail_verdict and verdict == "NOT_READY":
    print("GATE:   -> verdict NOT_READY")
    failed = True

# --- 2. sonar_raw.json (data mentah, tidak bergantung pada AI) ---
if check_sonar:
    if not os.path.isfile(sonar_file):
        print(f"GATE [sonar_raw.json]: file tidak ditemukan, cross-check dilewati")
    else:
        try:
            with open(sonar_file) as f:
                sonar = json.load(f)
            issues = sonar.get("issues", [])
            closed = {"CLOSED", "RESOLVED"}
            counts = {s: 0 for s in fail_sevs}
            for i in issues:
                s = str(i.get("severity", "")).upper()
                if s in counts and str(i.get("status", "OPEN")).upper() not in closed:
                    counts[s] += 1
            print("GATE [sonar_raw.json]: " + " ".join(f"{k}={v}" for k, v in counts.items()))
            for s, n in counts.items():
                if n > 0:
                    print(f"GATE:   -> {s} ditemukan: {n}")
                    failed = True
        except Exception as e:
            print(f"GATE [sonar_raw.json]: gagal dibaca ({e}), cross-check dilewati")

if failed:
    print("GATE: GAGAL - ada finding yang melewati batas")
    sys.exit(1)

print("GATE: LOLOS")
sys.exit(0)
PY
rc=$?

# rc: 0 = lolos, 1 = ada BLOCKER/CRITICAL, 2 = laporan tidak bisa dievaluasi
if [ "$rc" -eq 2 ]; then
  report_error
fi
exit "$rc"
