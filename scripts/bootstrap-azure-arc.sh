#!/usr/bin/env bash
set -euo pipefail

# bootstrap-azure-arc.sh
# Installs and configures Azure Arc on Kubernetes (K3s or Talos)
# Requires active Azure CLI session and appropriate permissions

RESOURCE_GROUP=""
CLUSTER_NAME=""
LOCATION="eastus"
TALOS_ENABLED=false
K3S_ENABLED=false
SKIP_VALIDATION=false

usage() {
  cat <<EOF
Usage: $0 --resource-group RG --cluster-name NAME [options]

Options:
  --resource-group RG    Azure Resource Group name (required).
  --cluster-name NAME    Kubernetes cluster name for Arc registration (required).
  --location LOCATION    Azure region (default: eastus).
  --talos                Enable for Talos clusters (will handle system-critical pods).
  --k3s                  Enable for K3s clusters.
  --skip-validation      Skip validation checks (not recommended).
  --help                 Show this help.

This script will:
  1. Verify Azure CLI and kubectl are available
  2. Install Azure Arc agents on the cluster
  3. Configure Managed Identity for workload access
  4. Enable Arc extensions for Key Vault integration

Prerequisites:
  - Azure CLI (az) installed and authenticated
  - kubectl configured and connected to target cluster
  - Appropriate Azure permissions (Owner or Arc-specific roles)
  - For Talos: CoreDNS must be installed in kube-system
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --resource-group) RESOURCE_GROUP="$2"; shift 2;;
    --cluster-name) CLUSTER_NAME="$2"; shift 2;;
    --location) LOCATION="$2"; shift 2;;
    --talos) TALOS_ENABLED=true; shift;;
    --k3s) K3S_ENABLED=true; shift;;
    --skip-validation) SKIP_VALIDATION=true; shift;;
    --help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [ -z "$RESOURCE_GROUP" ] || [ -z "$CLUSTER_NAME" ]; then
  echo "Error: --resource-group and --cluster-name are required" >&2
  usage
  exit 1
fi

log_info() {
  echo -e "\033[0;34m[INFO]\033[0m $1"
}

log_success() {
  echo -e "\033[0;32m[SUCCESS]\033[0m $1"
}

log_error() {
  echo -e "\033[0;31m[ERROR]\033[0m $1"
}

log_warn() {
  echo -e "\033[1;33m[WARN]\033[0m $1"
}

# Validate prerequisites
validate_prerequisites() {
  log_info "Validating prerequisites..."

  if [ "$SKIP_VALIDATION" = false ]; then
    if ! command -v az >/dev/null 2>&1; then
      log_error "Azure CLI (az) not found. Install it first."
      exit 3
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
      log_error "kubectl not found. Install it first."
      exit 3
    fi

    if ! az account show >/dev/null 2>&1; then
      log_error "Not authenticated to Azure. Run 'az login' first."
      exit 4
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
      log_error "Cannot connect to Kubernetes cluster. Check kubeconfig."
      exit 4
    fi

    # Check if resource group exists
    if ! az group show --name "$RESOURCE_GROUP" >/dev/null 2>&1; then
      log_error "Resource group '$RESOURCE_GROUP' not found."
      exit 4
    fi

    log_success "All prerequisites validated"
  else
    log_warn "Skipping prerequisite validation (--skip-validation used)"
  fi
}

# Install Azure Arc agents
install_arc_agents() {
  log_info "Installing Azure Arc agents..."

  # Generate Azure Arc onboarding script
  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" EXIT

  log_info "Downloading Azure Arc onboarding script..."
  az connectedk8s connect \
    --name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --distribution talos \
    --infrastructure onprem \
    --skip-helm-release || {
    log_error "Failed to connect cluster to Arc"
    return 1
  }

  log_success "Azure Arc agents installed successfully"
}

# Wait for Arc agents to be ready
wait_for_arc_agents() {
  log_info "Waiting for Azure Arc agents to be ready (this may take a few minutes)..."

  local max_attempts=60
  local attempt=0

  while [ $attempt -lt $max_attempts ]; do
    local total=$(kubectl get deployment -n azure-arc -o jsonpath='{.items | length}')
    local ready=$(kubectl get deployment -n azure-arc -o jsonpath='{.items[?(@.status.readyReplicas==@.status.replicas)].metadata.name}' | wc -w)

    if [ "$total" -gt 0 ] && [ "$ready" -eq "$total" ]; then
      log_success "Arc agents are ready"
      return 0
    fi

    echo "  Agents ready: $ready/$total"
    sleep 5
    ((attempt++))
  done

  log_warn "Arc agents did not become ready within timeout. Check with: kubectl get pods -n azure-arc"
}

# Create Managed Identity for the cluster
configure_managed_identity() {
  log_info "Configuring Managed Identity for Arc cluster..."

  # Get Arc resource ID
  local arc_id
  arc_id=$(az connectedk8s show \
    --name "$CLUSTER_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query id -o tsv) || {
    log_error "Failed to get Arc cluster resource ID"
    return 1
  }

  log_info "Arc Cluster Resource ID: $arc_id"

  # Verify identity extension exists
  local identity_status
  identity_status=$(az k8s-extension show \
    --resource-group "$RESOURCE_GROUP" \
    --cluster-type connectedClusters \
    --cluster-name "$CLUSTER_NAME" \
    --name "azure-workload-identity-kube-system" \
    --query provisioningState -o tsv 2>/dev/null || echo "NotFound")

  if [ "$identity_status" != "Succeeded" ]; then
    log_info "Installing Azure Workload Identity extension..."
    az k8s-extension create \
      --resource-group "$RESOURCE_GROUP" \
      --cluster-type connectedClusters \
      --cluster-name "$CLUSTER_NAME" \
      --name "azure-workload-identity-kube-system" \
      --extension-type "microsoft.workloadidentityext" \
      --auto-upgrade false \
      --scope cluster \
      --release-namespace kube-system || {
      log_error "Failed to install Workload Identity extension"
      return 1
    }
    log_success "Workload Identity extension installed"
  else
    log_success "Workload Identity extension already installed"
  fi
}

# Enable Key Vault extension
enable_keyvault_extension() {
  log_info "Enabling Azure Key Vault extension..."

  local kv_status
  kv_status=$(az k8s-extension show \
    --resource-group "$RESOURCE_GROUP" \
    --cluster-type connectedClusters \
    --cluster-name "$CLUSTER_NAME" \
    --name "azure-keyvault-secrets-provider" \
    --query provisioningState -o tsv 2>/dev/null || echo "NotFound")

  if [ "$kv_status" != "Succeeded" ]; then
    log_info "Installing Azure Key Vault Secrets Provider extension..."
    az k8s-extension create \
      --resource-group "$RESOURCE_GROUP" \
      --cluster-type connectedClusters \
      --cluster-name "$CLUSTER_NAME" \
      --name "azure-keyvault-secrets-provider" \
      --extension-type "microsoft.azurekeyvaultsecretsprovider" \
      --auto-upgrade false \
      --scope cluster \
      --release-namespace kube-system \
      --configuration-settings "secrets-store-csi-driver.syncSecret.enabled=true" \
      --configuration-settings "secrets-store-csi-driver.linux.privileged=true" || {
      log_error "Failed to install Key Vault Secrets Provider extension"
      return 1
    }
    log_success "Key Vault Secrets Provider extension installed"
  else
    log_success "Key Vault Secrets Provider extension already installed"
  fi
}

# Main execution
main() {
  log_info "Starting Azure Arc bootstrap for cluster: $CLUSTER_NAME"
  log_info "Resource Group: $RESOURCE_GROUP"
  log_info "Location: $LOCATION"

  if [ "$TALOS_ENABLED" = true ]; then
    log_info "Talos cluster mode enabled"
  fi

  if [ "$K3S_ENABLED" = true ]; then
    log_info "K3s cluster mode enabled"
  fi

  validate_prerequisites || exit $?
  install_arc_agents || exit $?
  wait_for_arc_agents || exit $?
  configure_managed_identity || exit $?
  enable_keyvault_extension || exit $?

  log_success "Azure Arc bootstrap completed successfully!"
  log_info "Next steps:"
  log_info "  1. Create an Azure Key Vault (if not already created)"
  log_info "  2. Create a Managed Identity and grant it access to Key Vault"
  log_info "  3. Create SecretProviderClass resources for Key Vault access"
  log_info "  4. Update your applications to use the Key Vault volumes"

  return 0
}

main "$@"
