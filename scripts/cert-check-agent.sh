#!/usr/bin/env bash
# Checks all TLS certificates used by the runai namespace for auto-renewal
# configuration and expiry risk. Covers:
#   - cert-manager Certificate resources in runai namespace
#   - TLS secrets in runai namespace (including cross-namespace refs)
#   - The wildcard cert that runai uses (wildcard-integrant-tls in cert-manager ns)
#   - Ingress TLS references in runai namespace
#
# Exit codes: 0 = all good, 1 = warnings found, 2 = critical issues found

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

WARN_DAYS=${WARN_DAYS:-30}   # warn if expiring within 30 days
CRIT_DAYS=${CRIT_DAYS:-7}    # critical if expiring within 7 days

exit_code=0
warnings=0
criticals=0

log_ok()   { echo -e "${GREEN}  [OK]${NC}     $*"; }
log_warn() { echo -e "${YELLOW}  [WARN]${NC}   $*"; ((warnings++)); exit_code=1; }
log_crit() { echo -e "${RED}  [CRIT]${NC}   $*"; ((criticals++)); exit_code=2; }
log_info() { echo -e "${CYAN}  [INFO]${NC}   $*"; }
log_skip() { echo -e "  [SKIP]    $*"; }

section() { echo -e "\n${BOLD}=== $* ===${NC}"; }

# Returns days until expiry for a TLS secret; prints negative if already expired
days_until_expiry() {
  local ns=$1 secret=$2
  local cert_pem
  cert_pem=$(kubectl get secret "$secret" -n "$ns" \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d 2>/dev/null) || return 1
  [[ -z "$cert_pem" ]] && return 1
  local expiry_date
  expiry_date=$(echo "$cert_pem" | openssl x509 -noout -enddate 2>/dev/null \
    | cut -d= -f2) || return 1
  local expiry_epoch now_epoch
  expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null \
    || date -j -f "%b %d %T %Y %Z" "$expiry_date" +%s 2>/dev/null) || return 1
  now_epoch=$(date +%s)
  echo $(( (expiry_epoch - now_epoch) / 86400 ))
}

check_certificate_resource() {
  local ns=$1 name=$2
  echo -e "\n  ${BOLD}Certificate:${NC} $name (namespace: $ns)"

  local ready renew_before duration secret_name issuer_name issuer_kind
  ready=$(kubectl get certificate "$name" -n "$ns" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  renew_before=$(kubectl get certificate "$name" -n "$ns" \
    -o jsonpath='{.spec.renewBefore}' 2>/dev/null)
  duration=$(kubectl get certificate "$name" -n "$ns" \
    -o jsonpath='{.spec.duration}' 2>/dev/null)
  secret_name=$(kubectl get certificate "$name" -n "$ns" \
    -o jsonpath='{.spec.secretName}' 2>/dev/null)
  issuer_name=$(kubectl get certificate "$name" -n "$ns" \
    -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null)
  issuer_kind=$(kubectl get certificate "$name" -n "$ns" \
    -o jsonpath='{.spec.issuerRef.kind}' 2>/dev/null)

  # Auto-renewal check: cert-manager always auto-renews; renewBefore makes it explicit
  if [[ -n "$renew_before" ]]; then
    log_ok "Auto-renewal configured (renewBefore: $renew_before)"
  else
    log_warn "No renewBefore set — cert-manager will still auto-renew at 2/3 of duration, but explicit renewBefore is recommended (duration: ${duration:-unknown})"
  fi

  # Ready status
  if [[ "$ready" == "True" ]]; then
    log_ok "Certificate is Ready"
  else
    log_crit "Certificate NOT Ready (status: ${ready:-unknown}) — check cert-manager logs"
  fi

  log_info "Issuer: $issuer_kind/$issuer_name"
  log_info "Backing secret: $secret_name"

  # Check actual expiry from the TLS secret
  if [[ -n "$secret_name" ]]; then
    local days
    if days=$(days_until_expiry "$ns" "$secret_name" 2>/dev/null); then
      if (( days <= 0 )); then
        log_crit "Certificate EXPIRED ${days#-} days ago! Secret: $secret_name"
      elif (( days <= CRIT_DAYS )); then
        log_crit "Expires in $days days — CRITICAL (threshold: $CRIT_DAYS days)"
      elif (( days <= WARN_DAYS )); then
        log_warn "Expires in $days days — approaching threshold ($WARN_DAYS days)"
      else
        log_ok "Expires in $days days — healthy"
      fi
    else
      log_warn "Could not read expiry from secret '$secret_name' — secret may not exist yet"
    fi
  fi
}

check_issuer_health() {
  local kind=$1 name=$2 ns=${3:-""}
  local ready
  if [[ "$kind" == "ClusterIssuer" ]]; then
    ready=$(kubectl get clusterissuer "$name" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  else
    ready=$(kubectl get issuer "$name" -n "$ns" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  fi

  if [[ "$ready" == "True" ]]; then
    log_ok "$kind/$name is Ready"
  else
    log_crit "$kind/$name is NOT Ready (status: ${ready:-unknown})"
  fi
}

echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║      Run:ai Namespace TLS Certificate Check Agent      ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo -e "Thresholds: WARN < ${WARN_DAYS}d, CRIT < ${CRIT_DAYS}d\n"

# ─── 1. cert-manager Certificate resources in runai namespace ──────────────────
section "1. Certificate resources in runai namespace"

mapfile -t runai_certs < <(kubectl get certificates -n runai \
  --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)

if [[ ${#runai_certs[@]} -eq 0 ]]; then
  log_info "No cert-manager Certificate resources found in runai namespace"
  log_info "runai likely consumes the wildcard cert from cert-manager namespace (checked below)"
else
  for cert in "${runai_certs[@]}"; do
    check_certificate_resource "runai" "$cert"
  done
fi

# ─── 2. Wildcard cert that runai references (cross-namespace) ─────────────────
section "2. Wildcard cert consumed by runai (wildcard-integrant-tls)"

check_certificate_resource "cert-manager" "wildcard-integrant-com"

# Check the secret is also present/synced in runai namespace (some setups copy it)
if kubectl get secret wildcard-integrant-tls -n runai &>/dev/null; then
  log_info "Secret 'wildcard-integrant-tls' also present in runai namespace (synced copy)"
  local_days=$(days_until_expiry "runai" "wildcard-integrant-tls" 2>/dev/null || echo "err")
  if [[ "$local_days" == "err" ]]; then
    log_warn "Could not parse expiry from runai/wildcard-integrant-tls"
  elif (( local_days <= CRIT_DAYS )); then
    log_crit "Synced copy in runai expires in $local_days days"
  elif (( local_days <= WARN_DAYS )); then
    log_warn "Synced copy in runai expires in $local_days days"
  else
    log_ok "Synced copy in runai expires in $local_days days"
  fi
else
  log_info "No local copy of wildcard-integrant-tls in runai namespace (using cross-namespace reference)"
fi

# ─── 3. All TLS secrets in runai namespace ────────────────────────────────────
section "3. All TLS secrets in runai namespace"

mapfile -t tls_secrets < <(kubectl get secrets -n runai --field-selector type=kubernetes.io/tls \
  --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)

if [[ ${#tls_secrets[@]} -eq 0 ]]; then
  log_info "No TLS secrets found directly in runai namespace"
else
  for secret in "${tls_secrets[@]}"; do
    echo -e "\n  ${BOLD}TLS Secret:${NC} $secret"
    # Check if managed by cert-manager
    managed=$(kubectl get secret "$secret" -n runai \
      -o jsonpath='{.metadata.annotations.cert-manager\.io/certificate-name}' 2>/dev/null || true)
    if [[ -n "$managed" ]]; then
      log_ok "Managed by cert-manager (Certificate: $managed) — auto-renewal active"
    else
      log_warn "NOT managed by cert-manager — no automatic renewal"
    fi
    days=$(days_until_expiry "runai" "$secret" 2>/dev/null || echo "err")
    if [[ "$days" == "err" ]]; then
      log_warn "Could not parse certificate expiry"
    elif (( days <= 0 )); then
      log_crit "EXPIRED ${days#-} days ago"
    elif (( days <= CRIT_DAYS )); then
      log_crit "Expires in $days days — CRITICAL"
    elif (( days <= WARN_DAYS )); then
      log_warn "Expires in $days days"
    else
      log_ok "Expires in $days days"
    fi
  done
fi

# ─── 4. Ingress TLS references in runai namespace ────────────────────────────
section "4. Ingress TLS references in runai namespace"

mapfile -t ingresses < <(kubectl get ingress -n runai --no-headers \
  -o custom-columns=NAME:.metadata.name 2>/dev/null || true)

if [[ ${#ingresses[@]} -eq 0 ]]; then
  log_info "No Ingress resources found in runai namespace"
else
  for ing in "${ingresses[@]}"; do
    echo -e "\n  ${BOLD}Ingress:${NC} $ing"
    # Check cert-manager annotation
    issuer=$(kubectl get ingress "$ing" -n runai \
      -o jsonpath='{.metadata.annotations.cert-manager\.io/cluster-issuer}' 2>/dev/null \
      || kubectl get ingress "$ing" -n runai \
      -o jsonpath='{.metadata.annotations.cert-manager\.io/issuer}' 2>/dev/null || true)
    if [[ -n "$issuer" ]]; then
      log_ok "cert-manager annotation present (issuer: $issuer) — auto-renewal active"
    else
      log_warn "No cert-manager annotation — TLS secret must be managed manually"
    fi
    # List TLS secrets referenced
    mapfile -t ing_tls < <(kubectl get ingress "$ing" -n runai \
      -o jsonpath='{.spec.tls[*].secretName}' 2>/dev/null | tr ' ' '\n' || true)
    for s in "${ing_tls[@]}"; do
      [[ -z "$s" ]] && continue
      log_info "TLS secret: $s"
    done
  done
fi

# ─── 5. Issuer health check ────────────────────────────────────────────────────
section "5. ClusterIssuer / Issuer health"

check_issuer_health "ClusterIssuer" "intermediate-ca"

# Check if any namespace-scoped issuers are used by runai certs
for cert in "${runai_certs[@]}"; do
  kind=$(kubectl get certificate "$cert" -n runai \
    -o jsonpath='{.spec.issuerRef.kind}' 2>/dev/null)
  issuer=$(kubectl get certificate "$cert" -n runai \
    -o jsonpath='{.spec.issuerRef.name}' 2>/dev/null)
  if [[ "$kind" == "Issuer" ]]; then
    check_issuer_health "Issuer" "$issuer" "runai"
  fi
done

# ─── Summary ──────────────────────────────────────────────────────────────────
section "Summary"

echo -e "  Warnings:  $warnings"
echo -e "  Criticals: $criticals"

if (( criticals > 0 )); then
  echo -e "\n${RED}${BOLD}  RESULT: CRITICAL — action required to prevent outage${NC}"
elif (( warnings > 0 )); then
  echo -e "\n${YELLOW}${BOLD}  RESULT: WARNING — review recommended${NC}"
else
  echo -e "\n${GREEN}${BOLD}  RESULT: ALL GOOD — certs are healthy and auto-renewal is configured${NC}"
fi

exit $exit_code
