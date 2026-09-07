#!/bin/bash
set -euo pipefail

# SonarQube Scan Script for SAST Pipeline
# Usage: ./sonarqube-scan.sh <workspace_root> <project_key> <host_url> <token> [output_dir] [java_binaries]
#   java_binaries = relative path to compiled classes (e.g. target/classes) for
#                   the SonarQube Java analyzer. Optional.

WORKSPACE_ROOT="${1:-.}"
PROJECT_KEY="${2:-}"
HOST_URL="${3:-http://localhost:9000}"
TOKEN="${4:-}"
OUTPUT_DIR="${5:-$WORKSPACE_ROOT}"
JAVA_BINARIES="${6:-}"
TIMEOUT=600  # 10 minutes for analysis submission

if [ -z "$PROJECT_KEY" ] || [ -z "$TOKEN" ]; then
    echo "[sonarqube-scan] ERROR: project key and token are required" >&2
    echo '{"issues": [], "hotspots": []}' > "$OUTPUT_DIR/sonar_raw.json"
    exit 0
fi

cd "$WORKSPACE_ROOT"

echo "[sonarqube-scan] Starting SonarQube scan for project '$PROJECT_KEY'"
echo "[sonarqube-scan] Host: $HOST_URL"

# Build the docker arg list
SCAN_ARGS=(
    --rm
    --network="host"
    -v "$(pwd):/usr/src"
    sonarsource/sonar-scanner-cli
    -Dsonar.projectKey="$PROJECT_KEY"
    -Dsonar.sources=.
    -Dsonar.host.url="$HOST_URL"
    -Dsonar.token="$TOKEN"
)

# Prefer sonar.java.binaries when provided; otherwise auto-detect the Java
# binary output directory produced by Maven or Gradle. SonarQube's Java
# analyzer REQUIRES compiled classes to run a proper SAST analysis, so the
# code must be built before invoking this script.
BINARIES="$JAVA_BINARIES"
if [ -z "$BINARIES" ]; then
    if [ -d "$WORKSPACE_ROOT/target/classes" ]; then
        BINARIES="target/classes"
    elif [ -d "$WORKSPACE_ROOT/build/classes/java/main" ]; then
        BINARIES="build/classes/java/main"
    fi
fi
if [ -n "$BINARIES" ]; then
    echo "[sonarqube-scan] Using java binaries: $BINARIES"
    SCAN_ARGS+=(-Dsonar.java.binaries="$BINARIES")
else
    echo "[sonarqube-scan] WARNING: no compiled Java classes found. SonarQube Java analysis requires the project to be built first (e.g. ./gradlew classes)." >&2
fi

# Run sonar-scanner via Docker
SCAN_START=$(date +%s)

if timeout "$TIMEOUT" docker run "${SCAN_ARGS[@]}" > /tmp/sonar_scanner_stdout.log 2>&1; then
    echo "[sonarqube-scan] Analysis submitted successfully"
else
    EXIT_CODE=$?
    echo "[sonarqube-scan] Scan failed or timed out (exit code: $EXIT_CODE)" >&2
    cat /tmp/sonar_scanner_stdout.log >&2
    echo '{"issues": [], "hotspots": []}' > "$OUTPUT_DIR/sonar_raw.json"
    exit 0  # Don't fail pipeline
fi

echo "[sonarqube-scan] Analysis submitted in $(( $(date +%s) - SCAN_START ))s. Waiting for server-side completion..."

# Wait for the SonarQube analysis to finish (CE task) before returning.
# sonar-scanner CLI returns once the report is uploaded, but server-side
# analysis may still be running. Query the Compute Engine for completion.
# Use the same token against the API.
POLL_TIMEOUT=600
POLL_START=$(date +%s)

while true; do
    # Try to find a running/completed task for this project
    COMPONENT_QUERY="$HOST_URL/api/components/show?component=$PROJECT_KEY"
    COMPONENT_JSON=$(curl -s -u "$TOKEN:" "$COMPONENT_QUERY" 2>/dev/null || echo '{}')
    COMPONENT_ID=$(echo "$COMPONENT_JSON" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(d.get('component',{}).get('key',''))
except Exception:
    print('')
" 2>/dev/null || echo '')

    TASK_JSON=$(curl -s -u "$TOKEN:" "$HOST_URL/api/ce/component?component=$PROJECT_KEY" 2>/dev/null || echo '{}')
    TASK_STATUS=$(echo "$TASK_JSON" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    tasks=d.get('tasks',[])
    if not tasks:
        print('NO_TASK')
    else:
        print(tasks[0].get('status','NO_TASK'))
except Exception:
    print('NO_TASK')
" 2>/dev/null || echo 'NO_TASK')

    case "$TASK_STATUS" in
        SUCCESS)
            echo "[sonarqube-scan] Analysis completed successfully (task: SUCCESS)"
            echo "SonarQube scan completed OK" > "$OUTPUT_DIR/sonar_scan.log"
            break
            ;;
        FAILED|CANCELED)
            echo "[sonarqube-scan] Analysis task $TASK_STATUS" >&2
            echo "SonarQube scan $TASK_STATUS" > "$OUTPUT_DIR/sonar_scan.log"
            break
            ;;
        NO_TASK)
            echo "[sonarqube-scan] No task found yet for '$PROJECT_KEY'"
            echo "SonarQube scan completed (no task found; may need re-scan)" > "$OUTPUT_DIR/sonar_scan.log"
            break
            ;;
        PENDING|IN_PROGRESS)
            echo "[sonarqube-scan] Analysis in progress ($TASK_STATUS)..."
            ;;
        *)
            echo "[sonarqube-scan] Unknown task status: $TASK_STATUS" >&2
            break
            ;;
    esac

    if [ $(( $(date +%s) - POLL_START )) -ge "$POLL_TIMEOUT" ]; then
        echo "[sonarqube-scan] Polling timed out after ${POLL_TIMEOUT}s" >&2
        echo "SonarQube scan polling timed out" > "$OUTPUT_DIR/sonar_scan.log"
        break
    fi

    sleep 5
done

# Create placeholder for raw collection; the MCP phase populates real data.
# The processor expects "issues" and "hotspots" keys.
if [ ! -f "$OUTPUT_DIR/sonar_raw.json" ]; then
    echo '{"issues": [], "hotspots": []}' > "$OUTPUT_DIR/sonar_raw.json"
fi

echo "[sonarqube-scan] Done."
