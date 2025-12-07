#!/usr/bin/env bash
set -euo pipefail

# bootstrap.sh
# Fetch or upload secrets to Azure Key Vault and write them to local paths.
# Supports interactive SSO via `az login`.

VAULT=""
VAULT_RG=""
SUBSCRIPTION=""
UPLOAD=0
UPLOAD_ONLY=0
FORCE=0
AZURE_SETUP=0

usage() {
  cat <<EOF
Usage: $0 --vault VAULT_NAME [--fetch-only] [--upload] [--force] [--azure-setup]

Options:
  --vault NAME     Name of the existing Azure Key Vault to use (required).
  --upload         Upload local files to Key Vault when missing.
  --upload-only    Upload existing local files to Key Vault and exit (do not generate missing keys).
  --force          Overwrite local files even if they exist.
  --vault-rg NAME   (optional) Resource group containing the Key Vault.
  --subscription ID (optional) Azure subscription id to target the Key Vault.
  --azure-setup    Configure Azure Arc prerequisites (setup managed identity, assign roles).
  --help           Show this help.

This script will fetch the following secrets from Key Vault (if present):
  - age-private-key          -> ~/.config/sops/age/keys.txt
  - kubeconfig               -> ~/.kube/config
  - github-deploy-key        -> ~/.ssh/github-deploy.key
  - github-deploy-key-pub    -> ~/.ssh/github-deploy.key.pub
  - github-push-token        -> ~/.config/home-ops/github-push-token.txt
  - cloudflare-tunnel        -> ~/.cloudflared/tunnel.json
  - cluster-yaml             -> ./cluster.yaml
  - nodes-yaml               -> ./nodes.yaml

Use --upload to push existing local files to Key Vault using the secret names above.
Use --azure-setup to configure Azure Arc and managed identities (requires admin permissions).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --vault) VAULT="$2"; shift 2;;
    --vault-rg|--vault-resource-group) VAULT_RG="$2"; shift 2;;
    --subscription) SUBSCRIPTION="$2"; shift 2;;
    --upload) UPLOAD=1; shift;;
    --upload-only) UPLOAD_ONLY=1; shift;;
    --force) FORCE=1; shift;;
    --azure-setup) AZURE_SETUP=1; shift;;
    --help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [ -z "$VAULT" ]; then
  echo "--vault is required" >&2
  usage
  exit 2
fi

command -v az >/dev/null 2>&1 || { echo "az CLI not found. Install the Azure CLI first." >&2; exit 3; }

# Ensure we're logged in (interactive SSO will open browser when needed)
if ! az account show >/dev/null 2>&1; then
  echo "Not logged in to Azure. Opening browser to authenticate (SSO)..."
  az login
fi

# Resolve the vault to ensure uniqueness (use resource group/subscription if provided)
AZ_ARGS=()
if [ -n "$SUBSCRIPTION" ]; then
  AZ_ARGS+=("--subscription" "$SUBSCRIPTION")
fi

if [ -n "$VAULT_RG" ]; then
  # Confirm the vault exists in the specified resource group
  if ! az keyvault show --name "$VAULT" --resource-group "$VAULT_RG" "${AZ_ARGS[@]}" >/dev/null 2>&1; then
    echo "Key Vault '$VAULT' not found in resource group '$VAULT_RG' (subscription: '${SUBSCRIPTION:-current}')." >&2
    exit 4
  fi
else
  # If resource group not given, try to find the vault; using subscription helps ensure uniqueness
  if [ -n "$SUBSCRIPTION" ]; then
    if ! az keyvault show --name "$VAULT" "${AZ_ARGS[@]}" >/dev/null 2>&1; then
      echo "Key Vault '$VAULT' not found in subscription '$SUBSCRIPTION'." >&2
      exit 4
    fi
  else
    # Best-effort check
    if ! az keyvault show --name "$VAULT" >/dev/null 2>&1; then
      echo "Key Vault '$VAULT' not found in the current subscription/context. Provide --vault-rg or --subscription to disambiguate." >&2
      exit 4
    fi
  fi
fi

declare -A SECRET_TO_PATH
SECRET_TO_PATH["age-private-key"]="$HOME/.config/sops/age/keys.txt"
SECRET_TO_PATH["kubeconfig"]="$HOME/.kube/config"
SECRET_TO_PATH["github-deploy-key"]="$HOME/.ssh/github-deploy.key"
SECRET_TO_PATH["github-deploy-key-pub"]="$HOME/.ssh/github-deploy.key.pub"
SECRET_TO_PATH["github-push-token"]="$HOME/.config/home-ops/github-push-token.txt"
SECRET_TO_PATH["cloudflare-tunnel"]="$HOME/.cloudflared/tunnel.json"
SECRET_TO_PATH["cluster-yaml"]="$PWD/cluster.yaml"
SECRET_TO_PATH["nodes-yaml"]="$PWD/nodes.yaml"

mkdir -p "$HOME/.config/sops/age"
mkdir -p "$HOME/.ssh"
mkdir -p "$HOME/.kube"
mkdir -p "$HOME/.config/home-ops"
mkdir -p "$HOME/.cloudflared"

fetch_secret() {
  local name="$1"
  local dest="$2"

  echo "Fetching secret '$name' from vault '$VAULT'..."
  if az keyvault secret show --vault-name "$VAULT" --name "$name" --query value -o tsv >/tmp/kv_secret_value 2>/dev/null; then
    mkdir -p "$(dirname "$dest")"
    cat /tmp/kv_secret_value > "$dest"
    if [[ "$name" == github-deploy-key || "$name" == age-private-key || "$name" == kubeconfig ]]; then
      chmod 600 "$dest" || true
    fi
    echo "Wrote $dest"
    rm -f /tmp/kv_secret_value
    return 0
  else
    rm -f /tmp/kv_secret_value || true
    echo "Secret '$name' not found in vault '$VAULT'"
    return 1
  fi
}

upload_secret() {
  local name="$1"
  local src="$2"

  if [ ! -f "$src" ]; then
    echo "Local file $src not found, skipping upload for $name"
    return 1
  fi
  echo "Uploading local $src to vault '$VAULT' as secret '$name'..."
  # Use az to set secret; multiline values are supported
  az keyvault secret set --vault-name "$VAULT" --name "$name" --value "$(cat "$src")" >/dev/null
  echo "Uploaded $name"
}

setup_azure_prerequisites() {
  echo "Setting up Azure prerequisites for Arc and Key Vault CSI Driver..."

  # Get subscription ID
  local sub_id
  sub_id=$(az account show --query id -o tsv)
  echo "Using subscription: $sub_id"

  # Create Managed Identity for external-secrets
  local mi_name="external-secrets-mi"
  echo "Creating Managed Identity: $mi_name..."

  if az identity show --name "$mi_name" --resource-group "$VAULT_RG" >/dev/null 2>&1; then
    echo "Managed Identity '$mi_name' already exists"
  else
    az identity create \
      --name "$mi_name" \
      --resource-group "$VAULT_RG" \
      --location "${AZURE_LOCATION:-eastus}"
    echo "Created Managed Identity: $mi_name"
  fi

  # Get Managed Identity details
  local mi_id
  local mi_client_id
  mi_id=$(az identity show --name "$mi_name" --resource-group "$VAULT_RG" --query id -o tsv)
  mi_client_id=$(az identity show --name "$mi_name" --resource-group "$VAULT_RG" --query clientId -o tsv)

  echo "Managed Identity ID: $mi_id"
  echo "Client ID: $mi_client_id"

  # Get Key Vault resource ID
  local kv_id
  kv_id=$(az keyvault show --name "$VAULT" --resource-group "$VAULT_RG" --query id -o tsv)
  echo "Key Vault ID: $kv_id"

  # Assign Key Vault Secrets Officer role to the Managed Identity
  echo "Assigning 'Key Vault Secrets Officer' role to Managed Identity..."
  az role assignment create \
    --assignee "$mi_client_id" \
    --role "Key Vault Secrets Officer" \
    --scope "$kv_id" || echo "Role assignment may have already been created"

  # Store the managed identity details for cluster configuration
  cat > "${PWD}/.azure-arc-config" << EOF
AZURE_RESOURCE_GROUP="$VAULT_RG"
AZURE_SUBSCRIPTION_ID="$sub_id"
AZURE_KEYVAULT_NAME="$VAULT"
AZURE_MANAGED_IDENTITY_NAME="$mi_name"
AZURE_MANAGED_IDENTITY_CLIENT_ID="$mi_client_id"
EOF

  echo "Azure prerequisites setup complete!"
  echo "Configuration saved to: ${PWD}/.azure-arc-config"
}

upload_secret() {
  local name="$1"
  local src="$2"

  if [ ! -f "$src" ]; then
    echo "Local file $src not found, skipping upload for $name"
    return 1
  fi
  echo "Uploading local $src to vault '$VAULT' as secret '$name'..."
  # Use az to set secret; multiline values are supported
  az keyvault secret set --vault-name "$VAULT" --name "$name" --value "$(cat "$src")" >/dev/null
  echo "Uploaded $name"
}

for name in "${!SECRET_TO_PATH[@]}"; do
  dest=${SECRET_TO_PATH[$name]}
  if [ "$UPLOAD_ONLY" -eq 1 ]; then
    # Upload-only mode: upload existing local files and skip generation
    if [ -f "$dest" ]; then
      upload_secret "$name" "$dest"
    else
      echo "Local file $dest not found, skipping upload for $name"
    fi
    continue
  fi

  if fetch_secret "$name" "$dest"; then
    continue
  else
    if [ "$UPLOAD" -eq 1 ]; then
      # If secret missing in KV and local file exists, upload
      if [ -f "$dest" ]; then
        upload_secret "$name" "$dest"
      else
        # For age key specifically, create a new one and upload it
        if [ "$name" = "age-private-key" ]; then
          echo "No age key locally. Generating new age key pair..."
          mkdir -p "$(dirname "$dest")"
          # requires age (age-keygen) or using openssl as fallback
          if command -v age-keygen >/dev/null 2>&1; then
            age-keygen -o "$dest"
            chmod 600 "$dest"
            upload_secret "$name" "$dest"
          else
            echo "age-keygen not found. Generating a simple keypair via openssl as fallback. Please install 'age' for a proper age keypair." >&2
            openssl genpkey -algorithm RSA -out "$dest" -pkeyopt rsa_keygen_bits:4096
            chmod 600 "$dest"
            upload_secret "$name" "$dest"
          fi
        else
          echo "Secret $name missing and no local file to upload. Skipping."
        fi
      fi
    else
      echo "Secret $name missing in vault and upload not enabled. Skipping."
    fi
  fi
done

# Run Azure setup if requested
if [ "$AZURE_SETUP" -eq 1 ]; then
  setup_azure_prerequisites
fi

echo "Done."
