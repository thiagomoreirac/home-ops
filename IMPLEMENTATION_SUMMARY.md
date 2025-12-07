# Azure Arc & Azure Key Vault CSI Driver Integration - Implementation Summary

## Overview

Successfully integrated Azure Arc and Azure Key Vault CSI Driver into the bootstrap process, replacing the 1Password dependency. The implementation provides secure, managed secret handling with Azure-native authentication.

## Files Created

### 1. `scripts/bootstrap-azure-arc.sh` (NEW)
- Installs and configures Azure Arc on Kubernetes clusters
- Supports both Talos and K3s distributions
- Configures Workload Identity for pod-managed authentication
- Enables Azure Key Vault Secrets Provider extension
- Features:
  - Prerequisite validation
  - Arc agent installation and monitoring
  - Managed Identity configuration
  - Key Vault extension setup
  - Comprehensive logging and error handling

**Usage:**
```bash
./scripts/bootstrap-azure-arc.sh \
  --resource-group homelab \
  --cluster-name homelab-k8s \
  --talos
```

### 2. `kubernetes/apps/azure-keyvault-csi/` (NEW DIRECTORY)

#### `kustomization.yaml`
- Kustomization for Azure Key Vault CSI driver resources
- Includes ClusterSecretStore and SecretProviderClass

#### `namespace.yaml`
- Kubernetes namespace definition for kube-system

#### `clustersecretstore.yaml`
- ClusterSecretStore for Azure Key Vault access
- Configured for Workload Identity authentication
- Uses environment variables for vault configuration

#### `secretproviderclass.yaml`
- SecretProviderClass for CSI driver volume mounting
- Specifies secrets to mount from Key Vault
- Configurable for pod-level identity

### 3. `kubernetes/apps/external-secrets/externalsecrets.yaml` (NEW)
- ExternalSecret resources for syncing Key Vault secrets
- Includes:
  - `sops-age-keys`: SOPS encryption key
  - `cloudflare-tunnel`: Cloudflare tunnel configuration
  - `github-credentials`: GitHub access token
- OnChange refresh policy for automatic updates

### 4. `AZURE_BOOTSTRAP_GUIDE.md` (NEW)
- Comprehensive guide for Azure Arc and Key Vault integration
- Prerequisites and setup instructions
- Configuration and troubleshooting
- Migration guide from 1Password
- Best practices and additional resources

## Files Modified

### 1. `scripts/bootstrap.sh`
**Changes:**
- Added `AZURE_SETUP` flag
- New `--azure-setup` option for Azure prerequisite configuration
- New `setup_azure_prerequisites()` function that:
  - Creates Managed Identity for external-secrets
  - Assigns Key Vault Secrets Officer role
  - Generates `.azure-arc-config` configuration file
- Updated usage documentation

### 2. `bootstrap/mod.just`
**Changes:**
- Added `azure-arc` target to bootstrap sequence
- Calls `bootstrap-azure-arc.sh` with environment variables
- Integrated between `wait` and `namespaces` stages
- Updated default task to include Azure Arc installation

### 3. `bootstrap/resources.yaml.j2`
**Changes:**
- Removed 1Password secret (`onepassword-secret`)
- Added `azure-credentials` secret for Workload Identity
- Kept SOPS and Cloudflare secrets (still synced via External Secrets)

### 4. `bootstrap/helmfile.d/01-apps.yaml`
**Changes:**
- Replaced `onepassword` release with `azure-keyvault-csi`
- Points to Microsoft's official CSI driver chart
- Includes hooks for:
  - Waiting for External Secrets CRDs
  - Applying ClusterSecretStore configuration
- Properly ordered dependencies

### 5. `kubernetes/apps/external-secrets/kustomization.yaml`
**Changes:**
- Removed reference to `./onepassword/ks.yaml`
- Added reference to `../azure-keyvault-csi/kustomization.yaml`

### 6. `kubernetes/apps/external-secrets/external-secrets/app/kustomization.yaml`
**Changes:**
- Added `./externalsecrets.yaml` to resources
- Now includes External Secrets for Key Vault sync

## Key Features

### 1. Azure Arc Integration
- Automatic registration of cluster with Azure Arc
- Installation of required Azure extensions
- Workload Identity configuration for secure pod authentication
- Support for both Talos and K3s distributions

### 2. Secure Secret Management
- Secrets stored in Azure Key Vault (Microsoft-managed)
- No need for external tools or VPNs
- Audit logging through Azure
- Automatic secret rotation support

### 3. Workload Identity Authentication
- Pod-level managed identity without API keys
- Federated identity credentials
- OIDC token-based authentication
- Zero-trust security model

### 4. External Secrets Integration
- Automatic sync from Azure Key Vault to Kubernetes Secrets
- Configurable refresh policies
- Template support for secret transformations
- Multi-namespace support

### 5. CSI Driver Integration
- Direct mounting of Key Vault secrets into pods
- Separate from Kubernetes Secret syncing
- Auto-update capability
- Per-pod identity support

## Bootstrap Sequence

The updated bootstrap process now follows this order:

```
1. Talos Installation       - Configure OS and network
2. Kubernetes Bootstrap     - Initialize cluster
3. Fetch Kubeconfig         - Get cluster credentials
4. Wait for Nodes           - Ensure nodes are ready
5. Azure Arc Setup          - Register with Arc, install extensions
6. Apply Namespaces         - Create required namespaces
7. Apply Resources          - Deploy bootstrap resources
8. Apply CRDs               - Install custom resource definitions
9. Apply Apps               - Deploy Helm releases (including Azure Key Vault CSI)
10. Fetch Kubeconfig        - Final kubeconfig update
```

## Environment Variables

Key environment variables for configuration:

```bash
# Required for bootstrap
AZURE_RESOURCE_GROUP="homelab"
CLUSTER_NAME="homelab-k8s"

# Azure configuration
AZURE_SUBSCRIPTION_ID="..."
AZURE_TENANT_ID="..."
AZURE_KEYVAULT_URL="https://*.vault.azure.net/"
AZURE_KEYVAULT_NAME="homelab-kv"
AZURE_CLIENT_ID="..."
AZURE_LOCATION="eastus"
```

## Configuration Template Variables

The following template variables need to be set in your environment:

- `${AZURE_KEYVAULT_URL}` - Full URL of Key Vault
- `${AZURE_TENANT_ID}` - Azure AD tenant ID
- `${AZURE_CLIENT_ID}` - Managed Identity client ID
- `${AZURE_KEYVAULT_NAME}` - Key Vault name
- `${AZURE_RESOURCE_GROUP}` - Resource group name

## Breaking Changes from 1Password

1. **Secret Storage**: Move from 1Password Vault to Azure Key Vault
2. **Agent**: Remove 1Password Connect pod deployment
3. **Authentication**: Switch from token-based to Workload Identity
4. **Secret Format**: Ensure secrets in Key Vault match expected format

## Migration Path

1. Create Azure Key Vault and Managed Identity
2. Export secrets from 1Password to Key Vault
3. Run `bootstrap.sh --azure-setup` to configure prerequisites
4. Run full bootstrap sequence
5. Verify secrets sync via External Secrets
6. Remove 1Password-related configurations

## Security Considerations

✅ **Implemented:**
- Pod-managed identity via Workload Identity
- Azure RBAC for Managed Identity access
- Key Vault audit logging
- Encrypted secret transmission
- No exposed credentials in cluster

⚠️ **Recommended:**
- Use Private Endpoints for Key Vault
- Enable Advanced Threat Protection
- Implement Network Policies
- Regular audit log review
- Automatic secret rotation policies

## Validation Checklist

- [ ] Azure CLI installed and authenticated
- [ ] kubectl configured for cluster access
- [ ] Azure Resource Group created
- [ ] Azure Key Vault created with secrets
- [ ] Sufficient Azure permissions for Arc registration
- [ ] Talos or K3s cluster running
- [ ] Helm 3+ installed
- [ ] Network connectivity to Azure APIs
- [ ] Age tool installed for SOPS (optional)

## Deployment Instructions

```bash
# 1. Set up Azure infrastructure
az group create --name homelab --location eastus
az keyvault create --name homelab-kv --resource-group homelab

# 2. Add secrets to Key Vault
az keyvault secret set --vault-name homelab-kv --name age-private-key --file ~/.config/sops/age/keys.txt
az keyvault secret set --vault-name homelab-kv --name github-push-token --value "<token>"

# 3. Run bootstrap with Azure setup
./scripts/bootstrap.sh --vault homelab-kv --vault-rg homelab --azure-setup

# 4. Run full bootstrap
just bootstrap

# 5. Verify deployment
kubectl get pods -n azure-arc
kubectl get externalsecrets -A
kubectl get secretproviderclass -A
```

## Troubleshooting Resources

- See `AZURE_BOOTSTRAP_GUIDE.md` for detailed troubleshooting steps
- Check Arc cluster status: `az connectedk8s show --name ... --resource-group ...`
- Monitor CSI driver: `kubectl logs -n kube-system -l app=secrets-store-csi-driver`
- Verify External Secrets: `kubectl describe externalsecret -n <namespace> <name>`

## Testing and Validation

After deployment, verify:

1. **Arc Connection**
   ```bash
   az connectedk8s show --name homelab-k8s --resource-group homelab
   kubectl get pods -n azure-arc
   ```

2. **Key Vault Access**
   ```bash
   kubectl get secretproviderclass -A
   kubectl describe externalsecret -n flux-system sops-age-keys
   ```

3. **Secret Sync**
   ```bash
   kubectl get secret -n flux-system sops-age-secret
   kubectl get secret -n network cloudflare-tunnel-id-secret
   ```

4. **Pod Identity**
   ```bash
   kubectl describe pod -n external-secrets <pod-name>
   kubectl logs -n external-secrets <pod-name>
   ```

## Next Steps

1. Complete the deployment using the instructions above
2. Configure additional namespaces and applications
3. Set up Pod-level Workload Identity for custom applications
4. Implement Azure Key Vault policies and access controls
5. Review and customize the External Secrets for your use case
6. Monitor Arc and Key Vault in Azure Portal

## Support & Documentation

- **Azure Arc**: https://learn.microsoft.com/azure/azure-arc/
- **Key Vault CSI**: https://github.com/Azure/secrets-store-csi-driver-provider-azure
- **External Secrets**: https://external-secrets.io/
- **Workload Identity**: https://azure.github.io/azure-workload-identity/
