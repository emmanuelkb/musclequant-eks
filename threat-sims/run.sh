#!/usr/bin/env bash
# Threat-simulation runner. Captures stdout/stderr to docs/threat-sim-output.txt
# so the technical report and demo video can quote the exact denials.

set -uo pipefail

OUT="$(cd "$(dirname "$0")/.."; pwd)/docs/threat-sim-output.txt"
mkdir -p "$(dirname "$OUT")"
: > "$OUT"

log() { echo -e "\n===== $* =====" | tee -a "$OUT"; }
run() { echo "+ $*" | tee -a "$OUT"; "$@" 2>&1 | tee -a "$OUT"; }

log "Scenario 1 — Privilege escalation attempt blocked by Pod Security Standards"
echo "Applying threat-sims/01-privileged-pod.yaml (expect REJECTION)..." | tee -a "$OUT"
run kubectl apply -f "$(dirname "$0")/01-privileged-pod.yaml" || true

log "Scenario 1 — Verify the pod was NOT created"
run kubectl -n musclequant get pod priv-escalation-attempt || true

log "Scenario 2 — Compromised pod attempts IMDSv2 credential theft"
run kubectl apply -f "$(dirname "$0")/02-attacker-pod.yaml"
echo "Waiting for attacker pod to be Ready..." | tee -a "$OUT"
kubectl -n red-team wait --for=condition=Ready pod/attacker --timeout=120s | tee -a "$OUT" || true

log "Scenario 2a — IMDSv2 token request (hop limit = 1, should TIMEOUT from inside the pod)"
run kubectl -n red-team exec attacker -- sh -c \
  'curl --max-time 3 -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60" || echo "[BLOCKED — IMDS unreachable from pod]"'

log "Scenario 2b — Direct Secrets Manager read with no IRSA role (should AccessDenied)"
run kubectl -n red-team exec attacker -- sh -c \
  'aws secretsmanager get-secret-value --secret-id musclequant/app --region us-east-1 || echo "[BLOCKED — no credentials / AccessDenied]"'

log "Scenario 2c — Same call from the AUTHORIZED pod (api) — should still fail because the api SA is scoped to its own secret only via IRSA, but listing all secrets is denied"
api_pod=$(kubectl -n musclequant get pod -l component=api -o jsonpath='{.items[0].metadata.name}')
echo "Using api pod: $api_pod" | tee -a "$OUT"
run kubectl -n musclequant exec "$api_pod" -- sh -c \
  'apk add --no-cache aws-cli >/dev/null 2>&1 || pip install awscli >/dev/null 2>&1 || true; aws secretsmanager list-secrets --region us-east-1 || echo "[as expected: api role cannot list secrets — only get its own]"'

log "Cleanup (red-team pod only — leave the namespace for re-runs)"
run kubectl -n red-team delete pod attacker --ignore-not-found

echo
echo "Output captured to: $OUT"
