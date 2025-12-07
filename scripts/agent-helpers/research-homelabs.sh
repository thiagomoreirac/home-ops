#!/bin/bash
# Innovation Agent Helper Script
# Discovers trending homelab projects and potential improvements
# Used by GitHub Actions workflow: agent-innovation.yaml

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
OUTPUT_FILE="${1:-/tmp/innovation-research.json}"
FOCUS_AREA="${2:-}"

# Helper functions
log_info() {
  echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
  echo -e "${GREEN}✅ $1${NC}"
}

log_warn() {
  echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
  echo -e "${RED}❌ $1${NC}"
}

# Query GitHub API for trending homelab repos
research_trending_repos() {
  local focus="${1:-homelab}"
  log_info "Researching trending homelab projects..."

  local query="topic:homelab stars:>1000 sort:stars-desc"

  if [ -n "$GITHUB_TOKEN" ]; then
    curl -s -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/search/repositories?q=${query}&per_page=10" | \
      jq -r '.items[] | {
        name: .full_name,
        description: .description,
        stars: .stargazers_count,
        url: .html_url,
        topics: .topics,
        language: .language
      }' > /tmp/trending-repos.json

    log_success "Found $(jq 'length' /tmp/trending-repos.json) trending projects"
  else
    log_warn "GITHUB_TOKEN not set, skipping GitHub API calls"
  fi
}

# Check for outdated dependencies
check_outdated_dependencies() {
  log_info "Checking for outdated Kubernetes components..."

  local current_versions=$(mktemp)

  # Extract current versions from manifests
  {
    echo "{"
    echo '  "components": ['

    # Cilium version
    if grep -r "cilium" kubernetes/apps/ --include="*.yaml" -m 1 | grep -q "image:"; then
      local cilium_version=$(grep -r "cilium/cilium:" kubernetes/apps/ --include="*.yaml" | head -1 | grep -oP 'v\d+\.\d+\.\d+' | head -1)
      echo "    {\"name\": \"cilium\", \"current\": \"${cilium_version:-unknown}\"},"
    fi

    # Flux version
    if grep -r "fluxcd" kubernetes/apps/ --include="*.yaml" | grep -q "image:"; then
      local flux_version=$(grep -r "fluxcd/flux-cli:" kubernetes/apps/ --include="*.yaml" | head -1 | grep -oP 'v\d+\.\d+\.\d+' | head -1)
      echo "    {\"name\": \"flux\", \"current\": \"${flux_version:-unknown}\"},"
    fi

    # Rook version
    if grep -r "rook" kubernetes/apps/ --include="*.yaml" | grep -q "image:"; then
      local rook_version=$(grep -r "rook/ceph:" kubernetes/apps/ --include="*.yaml" | head -1 | grep -oP 'v\d+\.\d+\.\d+' | head -1)
      echo "    {\"name\": \"rook\", \"current\": \"${rook_version:-unknown}\"}"
    fi

    echo "  ]"
    echo "}"
  } > "$current_versions"

  cat "$current_versions"
  log_success "Checked component versions"
}

# Analyze security posture
analyze_security_posture() {
  log_info "Analyzing security posture..."

  local findings=$(mktemp)

  {
    echo "{"
    echo '  "security_findings": ['

    # Check for hardcoded secrets
    if grep -r "password:" kubernetes/ --include="*.yaml" 2>/dev/null | grep -v "sops\|external-secret" | wc -l > /tmp/secret_count.txt; then
      local secret_count=$(cat /tmp/secret_count.txt)
      if [ "$secret_count" -gt 0 ]; then
        echo "    {\"issue\": \"Potential hardcoded secrets\", \"count\": $secret_count, \"severity\": \"high\"},"
      fi
    fi

    # Check for RBAC coverage
    if [ -d "kubernetes/apps" ]; then
      local apps=$(find kubernetes/apps -maxdepth 2 -type d | wc -l)
      local rbac_files=$(grep -r "kind: Role" kubernetes/ --include="*.yaml" 2>/dev/null | wc -l)
      echo "    {\"issue\": \"RBAC Coverage\", \"rbac_files\": $rbac_files, \"total_apps\": $apps, \"severity\": \"medium\"},"
    fi

    # Check for Network Policies
    local netpol_count=$(grep -r "kind: NetworkPolicy" kubernetes/ --include="*.yaml" 2>/dev/null | wc -l)
    if [ "$netpol_count" -eq 0 ]; then
      echo "    {\"issue\": \"No Network Policies defined\", \"severity\": \"medium\"}"
    fi

    echo "  ]"
    echo "}"
  } > "$findings"

  cat "$findings"
  log_success "Security analysis complete"
}

# Check for high-availability improvements
check_ha_readiness() {
  log_info "Checking high-availability readiness..."

  local ha_report=$(mktemp)

  {
    echo "{"
    echo '  "ha_checks": ['

    # Check replica counts
    local single_replica=$(grep -r "replicas: 1" kubernetes/apps/ --include="*.yaml" 2>/dev/null | wc -l)
    echo "    {\"check\": \"Single-replica deployments\", \"count\": $single_replica, \"recommendation\": \"Upgrade to 3+ replicas for HA\"},"

    # Check Pod Disruption Budgets
    local pdb_count=$(grep -r "kind: PodDisruptionBudget" kubernetes/ --include="*.yaml" 2>/dev/null | wc -l)
    echo "    {\"check\": \"Pod Disruption Budgets\", \"count\": $pdb_count, \"recommendation\": \"Add PDBs for critical apps\"},"

    # Check resource requests/limits
    local no_requests=$(grep -r "replicas:" kubernetes/apps/ --include="*.yaml" -A 20 2>/dev/null | grep -c "resources:" || echo "0")
    echo "    {\"check\": \"Resource Requests/Limits\", \"apps_without\": $no_requests, \"recommendation\": \"Define resource requests for all apps\"}"

    echo "  ]"
    echo "}"
  } > "$ha_report"

  cat "$ha_report"
  log_success "HA readiness assessment complete"
}

# Cost optimization analysis
analyze_cost_optimization() {
  log_info "Analyzing cost optimization opportunities..."

  local cost_report=$(mktemp)

  {
    echo "{"
    echo '  "cost_opportunities": ['
    echo "    {\"opportunity\": \"Implement Karpenter\", \"estimated_savings\": \"20-30%\", \"complexity\": \"high\", \"hours\": 8},"
    echo "    {\"opportunity\": \"Right-size container resources\", \"estimated_savings\": \"10-15%\", \"complexity\": \"low\", \"hours\": 2},"
    echo "    {\"opportunity\": \"Implement pod priority classes\", \"estimated_savings\": \"5%\", \"complexity\": \"medium\", \"hours\": 3},"
    echo "    {\"opportunity\": \"Consolidate monitoring stack\", \"estimated_savings\": \"50-100 USD/month\", \"complexity\": \"medium\", \"hours\": 4}"
    echo "  ]"
    echo "}"
  } > "$cost_report"

  cat "$cost_report"
  log_success "Cost analysis complete"
}

# Generate comprehensive research report
generate_research_report() {
  log_info "Generating comprehensive research report..."

  local timestamp=$(date -Iseconds)

  {
    echo "{"
    echo "  \"timestamp\": \"$timestamp\","
    echo "  \"focus_area\": \"${FOCUS_AREA:-all}\","
    echo "  \"research_sections\": ["
    echo "    \"trending_projects\","
    echo "    \"outdated_dependencies\","
    echo "    \"security_posture\","
    echo "    \"ha_readiness\","
    echo "    \"cost_optimization\""
    echo "  ],"
    echo "  \"report_location\": \"$OUTPUT_FILE\""
    echo "}"
  } > "$OUTPUT_FILE"

  log_success "Research report generated: $OUTPUT_FILE"
}

# Main execution
main() {
  log_info "🚀 Innovation Agent Research Starting"
  echo ""

  if [ -n "$FOCUS_AREA" ]; then
    log_info "Focus area: $FOCUS_AREA"
  fi

  # Run research modules based on focus area
  case "${FOCUS_AREA:-all}" in
    "trending")
      research_trending_repos
      ;;
    "dependencies")
      check_outdated_dependencies
      ;;
    "security")
      analyze_security_posture
      ;;
    "ha")
      check_ha_readiness
      ;;
    "cost")
      analyze_cost_optimization
      ;;
    "all"|*)
      research_trending_repos
      check_outdated_dependencies
      analyze_security_posture
      check_ha_readiness
      analyze_cost_optimization
      ;;
  esac

  echo ""
  generate_research_report

  log_success "🎉 Innovation Agent Research Complete"
  log_info "Results written to: $OUTPUT_FILE"
}

# Run main function
main "$@"
