#!/usr/bin/env bash

set -u

REPORTS_DIR="${1:-${REPORTS_DIR:-security-reports}}"
REVIEW_FILE="$REPORTS_DIR/Agentreview.json"
SONAR_FILE="$REPORTS_DIR/sonar_raw.json"

export REVIEW_FILE SONAR_FILE
export FAIL_ON_SEVERITIES="${FAIL_ON_SEVERITIES:-BLOCKER,HIGH}"
export FAIL_ON_VERDICT="${FAIL_ON_VERDICT:-false}"
export CHECK_SONAR_RAW="${CHECK_SONAR_RAW:-true}"
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
sonar_file  = os.environ["SONAR_FILE"]
fail_verdict = os.environ["FAIL_ON_VERDICT"].lower() == "true"
check_sonar  = os.environ["CHECK_SONAR_RAW"].lower() == "true"

# Skala MQR: INFO < LOW < MEDIUM < HIGH < BLOCKER
RANK = {"INFO": 0, "LOW": 1, "MEDIUM": 2, "HIGH": 3, "BLOCKER": 4}
# Skala lama -> MQR (dipakai sebagai fallback dan untuk konfigurasi lama)
LEGACY_TO_MQR = {"CRITICAL": "HIGH", "MAJOR": "MEDIUM", "MINOR": "LOW"}
CLOSED = {"ACCEPTED", "FALSE_POSITIVE", "FIXED", "CLOSED", "RESOLVED"}

def norm(s):
    s = str(s).strip().upper()
    return LEGACY_TO_MQR.get(s, s)

fail_sevs = []
for s in os.environ["FAIL_ON_SEVERITIES"].split(","):
    s = norm(s)
    if s and s in RANK and s not in fail_sevs:
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

def review_count(s):
    n = sev.get(s, 0)
    # Laporan lama masih memakai CRITICAL/MAJOR/MINOR
    if s not in sev:
        for legacy, mqr in LEGACY_TO_MQR.items():
            if mqr == s:
                n += sev.get(legacy, 0)
    return n

print(f"GATE [Agentreview.json]: verdict={verdict} " +
      " ".join(f"{k}={review_count(k)}" for k in fail_sevs))

for s in fail_sevs:
    n = review_count(s)
    if n > 0:
        print(f"GATE:   -> {s} ditemukan: {n}")
        failed = True

if fail_verdict and verdict == "NOT_READY":
    print("GATE:   -> verdict NOT_READY")
    failed = True

def security_severity(issue):
    """Severity dampak SECURITY (tertinggi). Fallback ke severity lama."""
    impacts = issue.get("impacts")
    if impacts:
        sevs = [norm(i.get("severity", "")) for i in impacts
                if str(i.get("softwareQuality", "")).upper() == "SECURITY"]
        sevs = [s for s in sevs if s in RANK]
        return max(sevs, key=RANK.get) if sevs else None
    # Tanpa impacts: hanya hitung jika bertipe keamanan
    if str(issue.get("type", "")).upper() in {"VULNERABILITY", "SECURITY_HOTSPOT"}:
        s = norm(issue.get("severity", ""))
        return s if s in RANK else None
    return None

if check_sonar:
    if not os.path.isfile(sonar_file):
        print("GATE [sonar_raw.json]: file tidak ditemukan, cross-check dilewati")
    else:
        try:
            with open(sonar_file) as f:
                sonar = json.load(f)
            issues = sonar.get("issues", [])
            total = sonar.get("paging", {}).get("total", sonar.get("total", len(issues)))
            if total > len(issues):
                print(f"GATE [sonar_raw.json]: WARNING - data terpotong ({len(issues)} dari {total} issue)")
            counts = {s: 0 for s in fail_sevs}
            for i in issues:
                status = str(i.get("issueStatus") or i.get("status") or "OPEN").upper()
                if status in CLOSED:
                    continue
                s = security_severity(i)
                if s in counts:
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

if [ "$rc" -eq 2 ]; then
  report_error
fi
exit "$rc"
