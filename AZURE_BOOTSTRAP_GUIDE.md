# Azure Arc & Key Vault CSI Driver Bootstrap Guide

This document describes the integration of Azure Arc and Azure Key Vault CSI Driver for secret management, replacing the 1Password dependency.

## Overview

The bootstrap process now includes:

1. **Azure Arc Installation** (`bootstrap-azure-arc.sh`): Registers your Kubernetes cluster with Azure Arc, enabling managed Kubernetes services.
2. **Azure Key Vault CSI Driver**: Mounts secrets from Azure Key Vault directly into pods using the Secrets Store CSI Driver.
3. **Workload Identity**: Uses Azure AD pod-managed identity for secure, keyless authentication.
4. **External Secrets Operator**: Syncs secrets from Azure Key Vault to Kubernetes Secrets.

## Prerequisites

- **Azure Subscription**: Active Azure subscription with appropriate permissions
- **Resource Group**: Azure Resource Group for storing Key Vault and related resources
- **Azure CLI**: Installed and authenticated (`az login`)
- **kubectl**: Configured and connected to your cluster
- **Talos or K3s**: Running Kubernetes cluster
- **Helm 3+**: For installing charts
- **age**: For SOPS encryption (optional but recommended)

## Bootstrap Process

### Step 1: Prepare Azure Infrastructure

Create an Azure Key Vault and store your secrets:

```bash
# Create a resource group
az group create --name homelab --location eastus

# Create a Key Vault
az keyvault create \
  --name homelab-kv \
  --resource-group homelab \
  --location eastus \
  --enable-purge-protection

# Add secrets to Key Vault
az keyvault secret set \
  --vault-name homelab-kv \
  --name age-private-key \
  --file ~/.config/sops/age/keys.txt

az keyvault secret set \
  --vault-name homelab-kv \
  --name github-push-token \
  --value "your-token-here"

az keyvault secret set \
  --vault-name homelab-kv \
  --name cloudflare-tunnel-id \
  --value "your-tunnel-id"

# Add other secrets as needed
```

### Step 2: Run Bootstrap with Azure Setup

```bash
# Set environment variables
export AZURE_RESOURCE_GROUP="homelab"
export CLUSTER_NAME="homelab-k8s"

# Run bootstrap.sh with --azure-setup flag
./scripts/bootstrap.sh \
  --vault homelab-kv \
  --vault-rg homelab \
  --azure-setup

# This will:
# 1. Create a Managed Identity for external-secrets
# 2. Assign Key Vault access roles
# 3. Generate .azure-arc-config with configuration
```

### Step 3: Install Azure Arc

```bash
# Run the Azure Arc bootstrap script
./scripts/bootstrap-azure-arc.sh \
  --resource-group homelab \
  --cluster-name homelab-k8s \
  --location eastus \
  --talos  # or --k3s if using K3s

# This will:
# 1. Register cluster with Azure Arc
# 2. Install Arc agents
# 3. Install Workload Identity extension
# 4. Install Key Vault CSI Driver extension
```

### Step 4: Run Full Bootstrap

Once Azure prerequisites are configured:

```bash
# Run the complete bootstrap sequence
just bootstrap

# This runs in order:
# 1. Talos installation
# 2. Kubernetes bootstrap
# 3. Kubeconfig retrieval
# 4. Wait for nodes
# 5. Azure Arc installation (NEW)
# 6. Apply namespaces
# 7. Apply resources
# 8. Apply CRDs
# 9. Apply apps (including Azure Key Vault CSI Driver)
```

## Configuration Files

### 1. `scripts/bootstrap-azure-arc.sh`

Installs Azure Arc and required extensions on your cluster.

**Options:**
- `--resource-group`: Azure Resource Group name (required)
- `--cluster-name`: Cluster name for Arc registration (required)
- `--location`: Azure region (default: eastus)
- `--talos`: Enable Talos-specific handling
- `--k3s`: Enable K3s-specific handling
- `--skip-validation`: Skip prerequisite checks (not recommended)

### 2. `scripts/bootstrap.sh`

Enhanced with Azure support for managing secrets in Key Vault.

**New Options:**
- `--azure-setup`: Configure Azure prerequisites (Managed Identity, roles)

### 3. `kubernetes/apps/azure-keyvault-csi/`

Contains Kubernetes resources for Azure Key Vault integration:

- **clustersecretstore.yaml**: ClusterSecretStore for Azure Key Vault access
- **secretproviderclass.yaml**: SecretProviderClass for CSI driver mounting
- **kustomization.yaml**: Kustomization for resources

### 4. `kubernetes/apps/external-secrets/externalsecrets.yaml`

External Secrets resources that sync secrets from Key Vault:

- `sops-age-keys`: Age encryption key for SOPS
- `cloudflare-tunnel`: Cloudflare tunnel configuration
- `github-credentials`: GitHub access token

### 5. `bootstrap/helmfile.d/01-apps.yaml`

Updated Helmfile with Azure Key Vault CSI Driver instead of 1Password:

```yaml
- name: azure-keyvault-csi
  namespace: kube-system
  # Deploys the CSI driver and agents
```

### 6. `bootstrap/resources.yaml.j2`

Removed 1Password secret references, now uses Azure credentials.

## Environment Variables

Set these before running bootstrap:

```bash
# Azure subscription settings
export AZURE_RESOURCE_GROUP="homelab"
export AZURE_SUBSCRIPTION_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Cluster settings
export CLUSTER_NAME="homelab-k8s"

# Key Vault
export AZURE_KEYVAULT_NAME="homelab-kv"
export AZURE_KEYVAULT_URL="https://homelab-kv.vault.azure.net/"
export AZURE_TENANT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export AZURE_CLIENT_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# Optional
export AZURE_LOCATION="eastus"
```

## Secret Sync Process

### How External Secrets Works

1. **ClusterSecretStore**: Defines connection to Azure Key Vault with Workload Identity
2. **ExternalSecret**: Specifies which secrets to sync and target Kubernetes Secret
3. **Operator**: Periodically syncs secrets based on `refreshPolicy` (OnChange, Periodic, CreatedOnce)

### Adding New Secrets

1. **Add to Key Vault:**
   ```bash
   az keyvault secret set \
     --vault-name homelab-kv \
     --name my-secret \
     --value "secret-value"
   ```

2. **Create ExternalSecret** in `kubernetes/apps/external-secrets/externalsecrets.yaml`:
   ```yaml
   ---
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
     name: my-secrets
     namespace: my-namespace
   spec:
     refreshPolicy: OnChange
     secretStoreRef:
       kind: ClusterSecretStore
       name: azure-keyvault
     target:
       name: my-secret
       creationPolicy: Owner
     data:
       - secretKey: mySecret
         remoteRef:
           key: my-secret
   ```

3. **Apply:** `kubectl apply -f kubernetes/apps/external-secrets/externalsecrets.yaml`

## Workload Identity Setup

### For Applications Needing Key Vault Access

1. **Create a Federated Identity Credential:**
   ```bash
   az identity federated-credential create \
     --name "my-app" \
     --identity-name "external-secrets-mi" \
     --resource-group "homelab" \
     --issuer "https://eastus.oic.prod-aks.azure.com/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx/" \
     --subject "system:serviceaccount:my-namespace:my-sa"
   ```

2. **Annotate ServiceAccount:**
   ```yaml
   apiVersion: v1
   kind: ServiceAccount
   metadata:
     name: my-sa
     namespace: my-namespace
     annotations:
       azure.workload.identity/client-id: "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   ```

3. **Add Pod Label:**
   ```yaml
   spec:
     template:
       metadata:
         labels:
           azure.workload.identity/use: "true"
   ```

## Troubleshooting

### Arc Agent Issues

```bash
# Check Arc agents status
kubectl get pods -n azure-arc

# Check Arc cluster status
az connectedk8s show --name homelab-k8s --resource-group homelab

# View agent logs
kubectl logs -n azure-arc -l app=clusterconnect-agent
```

### Key Vault CSI Driver Issues

```bash
# Check CSI driver pods
kubectl get pods -n kube-system | grep keyvault

# Check SecretProviderClass status
kubectl get secretproviderclass -A

# View driver logs
kubectl logs -n kube-system -l app=secrets-store-csi-driver
```

### External Secrets Issues

```bash
# Check ExternalSecret status
kubectl get externalsecrets -A
kubectl describe externalsecret -n flux-system sops-age-keys

# View operator logs
kubectl logs -n external-secrets -l app=external-secrets
```

### Workload Identity Issues

```bash
# Verify pod identity annotations
kubectl describe pod -n external-secrets <pod-name>

# Check OIDC token
kubectl exec -n external-secrets <pod-name> -- \
  cat /var/run/secrets/azure/tokens/azure-identity-token

# Verify Managed Identity assignment
az identity federated-credential list \
  --identity-name external-secrets-mi \
  --resource-group homelab
```

## Migration from 1Password

### What Changed

| Aspect | 1Password | Azure Key Vault |
|--------|-----------|-----------------|
| Secret Storage | 1Password Vault | Azure Key Vault |
| Pod Access | 1Password Connect agent | Workload Identity + CSI Driver |
| Authentication | Token-based | AD federated identity |
| Secret Sync | 1Password operator | External Secrets operator |
| Secret Injection | Environment variables | CSI volume mount |

### Migration Steps

1. **Export secrets from 1Password:**
   ```bash
   # Export all secrets to Key Vault
   # Use 1Password CLI or manual export
   ```

2. **Create corresponding Key Vault secrets:**
   ```bash
   az keyvault secret set --vault-name homelab-kv \
     --name <secret-name> --file <secret-file>
   ```

3. **Update Kubernetes manifests:**
   - Remove 1Password operator references
   - Update External Secrets to use `azure-keyvault` ClusterSecretStore

4. **Deploy new configuration:**
   ```bash
   kubectl apply -f kubernetes/apps/external-secrets/
   ```

5. **Remove 1Password resources:**
   ```bash
   kubectl delete namespace external-secrets
   # Then recreate with Azure configuration
   ```

## Best Practices

1. **Least Privilege Access**: Grant Managed Identity minimal necessary Key Vault permissions
2. **Regular Rotation**: Enable automatic key rotation in Azure Key Vault
3. **Audit Logging**: Enable diagnostic logging on Key Vault for audit trails
4. **Namespace Isolation**: Use separate ServiceAccounts per namespace for multi-tenancy
5. **Secret Versioning**: Use Key Vault versioning for secret updates without downtime
6. **Network Security**: Use Private Endpoints for Key Vault if possible
7. **RBAC**: Use Azure RBAC for fine-grained access control

## Additional Resources

- [Azure Arc Documentation](https://learn.microsoft.com/azure/azure-arc/)
- [Azure Key Vault Secrets Provider](https://github.com/Azure/secrets-store-csi-driver-provider-azure)
- [External Secrets Operator](https://external-secrets.io/)
- [Workload Identity Webhook](https://azure.github.io/azure-workload-identity/docs/)
- [Talos Documentation](https://www.talos.dev/)
- [K3s Documentation](https://docs.k3s.io/)
