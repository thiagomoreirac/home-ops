---
applyTo: '**'
---

# Home Operations - Copilot Agent Instructions

## 1. Project Vision & Goals

### Primary Objective
Build a **high-availability homelab** powered by **GitOps and AI agents**, designed to:
- **Run essential services** for home automation and personal infrastructure (e.g., Home Assistant, media servers, NFS storage)
- **Eliminate manual deployment steps** through GitHub Issues and Copilot-driven automation
- **Enable declarative infrastructure** where new applications are defined via GitHub Issues and automatically deployed by agents
- **Maintain reliability** with redundancy, monitoring, and automatic recovery

### AI Agent Responsibilities
GitHub Copilot agents are responsible for:
1. **Deployment Agent**: Parse GitHub Issues to deploy new applications to the Kubernetes cluster
2. **Security Agent**: Monitor and enforce security best practices, patch vulnerabilities, manage secrets
3. **Innovation Agent**: Discover ideas from other homelab projects and propose improvements
4. **High Availability Agent**: Ensure cluster resilience, manage failover scenarios, optimize for availability

---

## 2. Architecture Overview

### Stack & Components
- **Kubernetes Distribution**: k3s (preferable) or Talos OS (immutable, minimal OS for k8s)
- **GitOps Controller**: Flux CD (watches git repo and applies changes)
- **Package Management**: Helm + Kustomize
- **Secrets Management**: SOPS (git-encrypted) + External Secrets + Azure Key vault
- **CI/CD**: GitHub Actions + Self-hosted Actions Runner Controller (in-cluster)
- **Networking**:
  - Cilium (eBPF networking)
  - Istio (service mesh with L7 proxying)
  - Cloudflare Tunnel (secure ingress)
  - ExternalDNS (syncs to Cloudflare + adguard + tplink router)
- **Storage**:
  - Rook/Ceph (distributed block storage)
  - VolSync (backup/restore for PVs)
- **Observability**: Prometheus, Grafana, Loki, Gatus health checks
- **Dependency Management**: Renovate (auto-create PRs for updates)

### Repository Structure
```
kubernetes/
├── apps/                    # Application deployments (organized by namespace)
│   ├── actions-runner-system/
│   ├── cert-manager/
│   ├── default/            # User-facing apps (atuin, home-assistant, plex, etc.)
│   ├── flux-system/
│   ├── kube-system/
│   ├── network/
│   ├── observability/
│   └── ...
├── components/             # Reusable kustomize components (alerts, volsync, sops)
└── flux/                    # Flux system configuration

bootstrap/                   # Cluster bootstrap & helmfile templates
talos/                       # Talos machine config templates
scripts/                     # Automation scripts for bootstrapping
```

### Hardware Setup
- to be defined. initially 2 micro pcs.

---

## 3. GitOps Workflow & Issue-to-Deployment

### Issue Template for New Apps
When agents encounter a GitHub Issue for deploying a new application, expect:
```markdown
## Deploy [Application Name]

### Description
Brief description of what the app does and why it's needed

### Requirements
- Helm chart repository (if using Helm)
- Storage requirements (persistent volumes, capacity)
- Network requirements (ingress, DNS, ports)
- Resource limits (CPU, memory)
- Dependencies (other apps that must be deployed first)

### Namespace
Where the app should be deployed (e.g., `default`, `monitoring`, `network`)

### Configuration
Any custom values, environment variables, secrets needed

### Labels & Annotations
Custom labels for this application workload
```

### Deployment Process (Agent Workflow)
1. **Parse Issue**: Extract app name, requirements, namespace, config
2. **Create Structure**:
   - Create app directory: `kubernetes/apps/{namespace}/{app-name}/`
   - Create `kustomization.yaml` (namespace declaration)
   - Create `ks.yaml` (Flux Kustomization manifest)
   - Create `helmrelease.yaml` (if Helm chart) or raw Kubernetes manifests
3. **Handle Dependencies**:
   - Use `.spec.dependsOn` in Flux Kustomization to order deployments
   - Add `weight` to Kustomization for priority sequencing
4. **Manage Secrets**:
   - Store sensitive config in 1Password or Azure Key Vault
   - Use External Secrets to inject into cluster
   - Encrypt file secrets with SOPS (age encryption)
5. **Network Configuration**:
   - Create Ingress for app (internal class: `internal`, external: `external`)
   - ExternalDNS will sync to Cloudflare (external) or UniFi (internal)
6. **Storage (if needed)**:
   - Use StorageClass `ceph-block` (Rook) for block storage
   - Reference NFS shares from TrueNAS for bulk data
7. **Commit & Push**:
   - Create a branch from the issue
   - Commit all manifests to `kubernetes/apps/{namespace}/{app-name}/`
   - Open PR, link to issue
8. **Flux Reconciliation**:
   - Once PR merges to `main`, Flux detects changes and applies them
   - Monitor deployment status via `kubectl` or GitHub Actions

### Example: Deploying Home Assistant
```
Issue: Deploy Home Assistant for home automation
├── Create: kubernetes/apps/default/home-assistant/
│   ├── kustomization.yaml (declares namespace)
│   ├── ks.yaml (Flux Kustomization, depends on: rook-ceph-cluster)
│   ├── helmrelease.yaml (Helm chart configuration)
│   ├── ingress.yaml (Ingress for internal access)
│   ├── configmap.yaml (non-secret config)
│   └── externalsecret.yaml (pulls db password from 1Password)
└── Flux applies → cluster reconciles → Home Assistant runs
```

---

## 4. Security Best Practices for Agents

### Secret Management
- **Never commit plaintext secrets** to git
- Use SOPS with age encryption for git-committed secrets (keys in `~/.config/sops/age/keys.txt`)
- Use External Secrets Operator to fetch secrets from 1Password at runtime
- Use Azure Key Vault for secrets that are not uploaded to github, such as age.key, and machine-specific secrets, such as nodes.yaml (bootstrap.sh manages this)

### RBAC & Pod Security
- Apply least-privilege RBAC (ClusterRoles, Roles, RoleBindings)
- Use Pod Security Standards (PSS) for namespace-level policies
- Enable network policies with Cilium to restrict inter-pod traffic
- Use read-only root filesystems where possible

### Image & Supply Chain Security
- Scan container images for vulnerabilities (Trivy, Snyk)
- Use private container registries for sensitive workloads
- Pin image versions (no `latest` tags in production)
- Review and approve Renovate PRs for version updates before merging

### Monitoring & Alerting
- Configure Prometheus scrape configs for new apps
- Create alerts in `kubernetes/apps/observability/kube-prometheus-stack/` for critical metrics
- Log all agent actions and deployments for audit trails
- Use Gatus for synthetic health checks on critical services

### Access Control
- Restrict cluster access via OIDC/OAuth2 (integrate with GitHub)
- Use separate service accounts per application (no `default` SA)
- Audit GitHub Actions runner actions (Self-hosted runner in-cluster)
- Enable audit logging for all API server calls

---

## 5. High Availability & Reliability Patterns

### Cluster Resilience
- **2-node cluster** (all nodes are control planes + workers) for quorum and HA
- Talos autoupgrades and automatic rollback on failure
- Use Pod Disruption Budgets (PDB) to protect critical apps during maintenance
- Implement topology spread constraints to distribute pods across nodes

### Application Resilience
- **Replicas**: Deploy apps with 3+ replicas when possible (e.g., `replicas: 3`)
- **Affinity**: Use pod anti-affinity to spread replicas across nodes
- **Resource Requests**: Always set CPU/memory requests and limits
- **Health Checks**: Configure liveness and readiness probes
- **Restart Policy**: Use `OnFailure` or `Always` appropriately

### Data Protection
- **Persistent Volumes**: Use StorageClass `ceph-block` for critical data
- **Backups**: Enable VolSync for automatic PV snapshots/backups to TrueNAS
- **Database Replication**: For stateful apps (e.g., Home Assistant DB), ensure replication
- **RTO/RPO**: Target Recovery Time/Recovery Point—optimize based on criticality

### Monitoring & Observability
- **Prometheus**: Scrape metrics from all workloads
- **Grafana**: Create dashboards for critical services
- **Alerts**: Configure AlertManager for Page/Slack/Email notifications
- **Logging**: Collect logs via Fluent Bit → Loki for persistence & querying
- **Gatus**: Health check endpoint monitoring for synthetic tests

### Network Resilience
- **CNI**: Cilium provides redundancy and network isolation
- **Service Mesh**: Istio enables traffic management, retries, circuit breaking
- **Ingress**: Multiple ingress replicas, load-balanced via service mesh
- **DNS**: Dual ExternalDNS instances (Cloudflare + UniFi) for failover

---

## 6. Dependency Management & Versioning

### Renovate Automation
- Renovate watches the entire repo for dependency updates (Helm, kustomize, container images)
- Auto-creates PRs for version bumps following semver
- **Agents should**:
  - Review and test Renovate PRs before merging
  - Update Helm chart versions in `helmrelease.yaml`
  - Update container image tags in `kustomization.yaml` or Helm values
  - Check for breaking changes in release notes

### Flux Dependency Ordering
Use Flux's `dependsOn` to ensure correct deployment order:
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: atuin
spec:
  dependsOn:
    - name: rook-ceph-cluster
      namespace: rook-ceph
```

This ensures `rook-ceph-cluster` is healthy before deploying `atuin`.

---

## 7. Common Patterns & Templates

### Basic App Deployment (Helm-based)
```
kubernetes/apps/default/{app-name}/
├── kustomization.yaml
├── ks.yaml
└── helmrelease.yaml
```

**kustomization.yaml**:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: default
resources:
  - ks.yaml
```

**ks.yaml** (Flux Kustomization):
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: {app-name}
  namespace: flux-system
spec:
  targetNamespace: default
  prune: true
  sourceRef:
    kind: GitRepository
    name: home-ops
    namespace: flux-system
  path: ./kubernetes/apps/default/{app-name}
  interval: 5m
  retryInterval: 5m
  timeout: 5m
  decryption:
    provider: sops
    secretRef:
      name: sops-age
  postBuild:
    substitute:
      DOMAIN: example.com
```

**helmrelease.yaml**:
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: {app-name}
  namespace: default
spec:
  interval: 5m
  chart:
    spec:
      chart: {app-name}
      version: "1.0.0"
      sourceRef:
        kind: HelmRepository
        name: {repo-name}
        namespace: flux-system
  values:
    # Custom values
    replicaCount: 3
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
  dependsOn:
    - name: rook-ceph-cluster
      namespace: rook-ceph
```

### With External Secrets
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {app-name}-secret
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: onepassword-secret-store
    kind: SecretStore
  target:
    name: {app-name}-secret
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        path: {app-name}
        field: password
```

### With Storage
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {app-name}-data
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ceph-block
  resources:
    requests:
      storage: 10Gi
```

---

## 8. Agent Responsibilities & Decision Matrix

| Agent Type | Responsibilities | Triggers | Constraints |
|---|---|---|---|
| **Deployment** | Parse issues, create app manifests, handle dependencies | GitHub Issue label: `deploy/app` | Must follow Helm/Kustomize standards, validate manifests |
| **Security** | Review RBAC, scan images, manage secrets, alert on vulns | GitHub PR, scheduled scans, alerts | Never commit plaintext secrets, follow PSS |
| **Innovation** | Scan external homelab repos, propose features | Scheduled (weekly), manual trigger | Vet suggestions before proposing, consider resource usage |
| **High Availability** | Monitor uptime, optimize replicas/affinity, manage PDBs | Cluster metrics, downtime events | Preserve RTO/RPO targets, test failover scenarios |

---

## 9. Common Operations

### Adding a New App
1. Create issue with `deploy/app` label
2. Agent creates PR with app structure in `kubernetes/apps/{namespace}/{app-name}/`
3. Include `kustomization.yaml`, `ks.yaml`, and Helm/manifest files
4. Handle secrets via External Secrets or SOPS
5. Configure ingress and DNS (ExternalDNS picks it up)
6. Merge PR → Flux reconciles → App deploys

### Updating an Existing App
1. Renovate creates PR for version update
2. Agent reviews changes, tests if needed
3. Merge PR → Flux applies update

### Monitoring & Alerting
1. Prometheus scrapes metrics (auto-discovered via ServiceMonitor)
2. Grafana visualizes dashboards
3. AlertManager sends alerts on thresholds
4. Gatus performs synthetic health checks

### Backup & Recovery
1. VolSync snapshots PVs automatically
2. Recovery: restore from snapshot or backup to TrueNAS
3. Test recovery procedures monthly

---

## 10. References & Resources

### Official Documentation
- [Flux CD](https://fluxcd.io/docs/)
- [Helm](https://helm.sh/docs/)
- [Kubernetes](https://kubernetes.io/docs/)
- [Talos OS](https://www.talos.dev/)
- [Cilium](https://docs.cilium.io/)
- [Istio](https://istio.io/latest/docs/)
- [SOPS](https://github.com/getsops/sops)
- [External Secrets](https://external-secrets.io/)

### Community Resources
- [Home Operations Discord](https://discord.gg/home-operations)
- [kubesearch.dev](https://kubesearch.dev/) - Kubernetes app discovery
- [Awesome Homelab](https://github.com/awesome-selfhosted/awesome-selfhosted)

### This Repository
- GitHub: [thiagomoreirac/home-ops](https://github.com/thiagomoreirac/home-ops)
- Issues: Use labels `deploy/app`, `security`, `innovation`, `ha`
- Branches: Create feature branches from `main`, open PRs with issue reference

---

## 11. Agent Development Best Practices

### Code Quality
- Validate all YAML manifests (use `kubeval`, `kube-score`)
- Test Helm charts locally (use `helm lint`, `helm template`)
- Follow Kubernetes API conventions (labels, annotations, ownerReferences)
- Use consistent indentation (2 spaces)

### Git Workflow
- Create descriptive branch names: `feat/deploy-{app-name}`, `fix/security-{issue}`, `chore/update-{app}`
- Commit messages: `[Type] Description` (e.g., `[deploy] Add Home Assistant`, `[security] Fix RBAC`)
- Link PRs to issues: "Closes #123" in PR body
- Require approval before merging (at least 1 review)

### Testing & Validation
- Use `flux reconcile` to test manifests locally
- Run `kustomize build` to validate kustomize overlays
- Test Helm rendering: `helm template {release} {chart}`
- Dry-run: `kubectl apply --dry-run=client --validate=strict -f manifest.yaml`

### Documentation
- Document custom values in HelmRelease comments
- Link to upstream chart documentation
- Note any breaking changes or migration steps
- Keep README.md in app directory updated

---

## 12. Escalation & Manual Intervention

### When Agents Should Escalate
- **Complex dependency chains** (more than 3 apps)
- **Custom CRDs** not in standard repos
- **Breaking changes** in dependencies
- **Cluster-wide policy changes** (network policies, RBAC)
- **Data migration** scenarios
- **Emergency security patches**

### Escalation Process
1. Create GitHub Issue with `needs-review` label
2. Include detailed analysis, options, and recommendation
3. Assign to repository owner/maintainers
4. Wait for approval before proceeding

---

## 13. Success Metrics

Track these metrics to measure agent effectiveness:

| Metric | Target | Rationale |
|---|---|---|
| **Deployment Time** (Issue → Production) | < 1 hour | Fast iteration, reduced manual work |
| **Cluster Uptime** | > 99.9% | HA requirements for essential services |
| **Security Patch Response** | < 24 hours | Timely vulnerability remediation |
| **Failed Deployments** | < 5% | Quality and reliability |
| **Manual Interventions** | < 10/month | Automation maturity |
| **Cost per Month** | < $50 (cloud) | Efficient resource usage |

---

## 14. Autonomous Agent Implementation Guide

This section provides **concrete, actionable steps** to implement autonomous Copilot agents that work without human intervention.

### 14.1 Architecture: Agent Orchestration

```
GitHub Events
    ↓
┌───────────────────────────────────────┐
│ GitHub Actions Workflows              │
├───────────────────────────────────────┤
│ • Issue Created/Updated               │
│ • Schedule (CRON)                     │
│ • Manual Trigger (/command)           │
└───────────────────────────────────────┘
    ↓
┌───────────────────────────────────────┐
│ Agent Decision Router                 │
├───────────────────────────────────────┤
│ Route to: Deployment/Security/HA/Innov│
└───────────────────────────────────────┘
    ↓
┌───────────────────────────────────────┐
│ Specialized Copilot Agents            │
├───────────────────────────────────────┤
│ 1. Deployment Agent                   │
│ 2. Security Agent                     │
│ 3. Innovation Agent                   │
│ 4. High Availability Agent            │
└───────────────────────────────────────┘
    ↓
┌───────────────────────────────────────┐
│ Kubernetes + Git Operations           │
├───────────────────────────────────────┤
│ • kubectl apply manifests             │
│ • helm operations                     │
│ • git commit & push                   │
│ • Create/Update PRs                   │
└───────────────────────────────────────┘
```

### 14.2 Implementation Stack

Use **three complementary tools** for autonomous operation:

#### Tool 1: GitHub Actions (Orchestration & Triggering)
- **Role**: Watch for events, trigger agents, validate outputs
- **Cost**: Free (within GitHub's free tier limits)
- **Runs**: In minutes, with full GitHub API access

#### Tool 2: GitHub Copilot Agents (Intelligence)
- **Role**: Autonomous decision-making and code generation
- **Cost**: Via API calls (pay-as-you-go)
- **Capability**: Multi-step reasoning, tool use, context awareness

#### Tool 3: Azure Container Instances / Actions Runner (Execution)
- **Role**: Run long-lived operations, execute kubectl commands, git operations
- **Option A**: Self-hosted GitHub Actions runner in Kubernetes cluster
- **Option B**: Containerized agent running in Azure Container Instances (ACI)
- **Cost**: Minimal (self-hosted uses cluster resources)

### 14.3 Agent Implementation: Step-by-Step

#### Phase 1: GitHub Actions Workflows (Entry Points)

Create workflow files in `.github/workflows/`:

**File: `.github/workflows/agent-deployment.yaml`**
```yaml
name: Deployment Agent

on:
  issues:
    types: [opened, edited, labeled]
  workflow_dispatch:
    inputs:
      issue_number:
        description: 'Issue number to process'
        required: true

jobs:
  deployment-agent:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      issues: write
      pull-requests: write

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          token: ${{ secrets.GITHUB_TOKEN }}

      - name: Fetch issue details
        id: issue
        uses: actions/github-script@v7
        with:
          script: |
            const issueNumber = context.payload.issue?.number || context.inputs.issue_number;
            const issue = await github.rest.issues.get({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: issueNumber
            });
            console.log('Issue:', JSON.stringify(issue.data, null, 2));
            core.setOutput('number', issueNumber);
            core.setOutput('title', issue.data.title);
            core.setOutput('body', issue.data.body);
            core.setOutput('labels', issue.data.labels.map(l => l.name).join(','));

      - name: Route to correct agent
        id: route
        shell: bash
        run: |
          LABELS="${{ steps.issue.outputs.labels }}"
          if [[ "$LABELS" == *"deploy/app"* ]]; then
            echo "agent_type=deployment" >> $GITHUB_OUTPUT
          elif [[ "$LABELS" == *"security"* ]]; then
            echo "agent_type=security" >> $GITHUB_OUTPUT
          elif [[ "$LABELS" == *"innovation"* ]]; then
            echo "agent_type=innovation" >> $GITHUB_OUTPUT
          elif [[ "$LABELS" == *"ha"* ]]; then
            echo "agent_type=ha" >> $GITHUB_OUTPUT
          else
            echo "agent_type=unknown" >> $GITHUB_OUTPUT
          fi

      - name: Call Deployment Agent
        if: steps.route.outputs.agent_type == 'deployment'
        uses: github/copilot-agent@v1
        with:
          agent-type: deployment-kubernetes
          prompt-file: .github/prompts/homelab-agent.instructions.md
          context: |
            Issue #${{ steps.issue.outputs.number }}: ${{ steps.issue.outputs.title }}

            Description:
            ${{ steps.issue.outputs.body }}

            Labels: ${{ steps.issue.outputs.labels }}

            Task: Parse this GitHub issue and create Kubernetes manifests to deploy the requested application.

            Requirements:
            1. Create manifests in kubernetes/apps/{namespace}/{app-name}/ directory
            2. Follow the patterns in the instructions for HelmRelease/Kustomization
            3. Handle secrets properly (External Secrets or SOPS)
            4. Configure ingress and DNS
            5. Create a pull request with all changes
            6. Link PR to this issue

            Validation:
            - Run: kustomize build kubernetes/apps/{namespace}/{app-name}
            - Run: helm lint on any Helm charts
            - Validate YAML: kubeval

            When complete:
            - Create PR with conventional commit message: [deploy] Add {app-name}
            - Add comment to issue with PR link

      - name: Create issue comment on success
        if: success()
        uses: actions/github-script@v7
        with:
          script: |
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: '✅ Agent processing started. Creating deployment manifests...'
            });

      - name: Create issue comment on failure
        if: failure()
        uses: actions/github-script@v7
        with:
          script: |
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: '❌ Agent processing failed. Please check workflow logs.'
            });
```

**File: `.github/workflows/agent-security.yaml`**
```yaml
name: Security Agent

on:
  schedule:
    - cron: '0 2 * * *'  # Daily at 2 AM UTC
  workflow_dispatch:
  pull_request:
    types: [opened, synchronize]

jobs:
  security-scan:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
      security-events: write

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Scan for secrets in repo
        uses: gitleaks/gitleaks-action@v2
        with:
          verbose: true

      - name: Scan container images
        run: |
          # For each HelmRelease, extract image and scan
          for helmfile in $(find kubernetes -name "helmrelease.yaml"); do
            echo "Scanning images in $helmfile"
            # Agent will parse and scan images
          done

      - name: Call Security Agent
        uses: github/copilot-agent@v1
        with:
          agent-type: security-kubernetes
          prompt-file: .github/prompts/homelab-agent.instructions.md
          context: |
            Task: Perform security audit on Kubernetes manifests and deployments.

            Checks to perform:
            1. RBAC validation - ensure least privilege
            2. Pod Security Standards - check PSS labels on namespaces
            3. Network Policies - verify segmentation
            4. Secret management - check for hardcoded secrets
            5. Image scanning - check for vulnerabilities
            6. SOPS encryption - verify secrets are encrypted

            Report findings as:
            - Critical: Create issue with label "security/critical"
            - High: Create PR with fixes
            - Medium: Add comment to relevant PR

            Auto-fix when possible:
            - Add missing RBAC rules
            - Add Pod Security Standard labels
            - Create network policies for new apps
```

**File: `.github/workflows/agent-innovation.yaml`**
```yaml
name: Innovation Agent

on:
  schedule:
    - cron: '0 3 * * 0'  # Weekly on Sunday at 3 AM UTC
  workflow_dispatch:

jobs:
  innovation:
    runs-on: ubuntu-latest
    permissions:
      issues: write
      contents: read

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Call Innovation Agent
        uses: github/copilot-agent@v1
        with:
          agent-type: innovation-homelab
          prompt-file: .github/prompts/homelab-agent.instructions.md
          context: |
            Task: Discover and suggest improvements for the homelab.

            Research Sources:
            1. Popular homelab GitHub repos (HomeOps community projects)
            2. Kubernetes ecosystem updates (new tools, patterns)
            3. Security bulletins (CVEs, best practices)
            4. Cost optimization opportunities

            For each discovery:
            1. Evaluate fit with current architecture
            2. Assess resource impact (CPU, memory, cost)
            3. Check for conflicts with existing apps
            4. Create GitHub issue with:
               - Title: [innovation] {Suggestion}
               - Labels: innovation, enhancement
               - Body: Description, links, proposed implementation

            Examples of good suggestions:
            - "Upgrade Cilium from v1.14 to v1.15 (new features)"
            - "Add SpiceDB for fine-grained access control"
            - "Implement automated disaster recovery testing"
            - "Add observability: Tempo for distributed tracing"
```

**File: `.github/workflows/agent-ha-monitor.yaml`**
```yaml
name: High Availability Monitor

on:
  schedule:
    - cron: '*/5 * * * *'  # Every 5 minutes
  workflow_dispatch:

jobs:
  ha-monitor:
    runs-on: ubuntu-latest
    permissions:
      issues: write
      contents: read

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Setup kubeconfig
        run: |
          mkdir -p $HOME/.kube
          echo "${{ secrets.KUBECONFIG_B64 }}" | base64 -d > $HOME/.kube/config
          chmod 600 $HOME/.kube/config

      - name: Query cluster health
        id: health
        run: |
          # Check node status
          kubectl get nodes -o json > /tmp/nodes.json

          # Check pod health
          kubectl get pods --all-namespaces -o json > /tmp/pods.json

          # Check critical services
          kubectl get svc -n default -o json > /tmp/services.json

          echo "health_report=$(cat /tmp/nodes.json /tmp/pods.json /tmp/services.json)" >> $GITHUB_OUTPUT

      - name: Call HA Agent
        uses: github/copilot-agent@v1
        with:
          agent-type: ha-kubernetes
          prompt-file: .github/prompts/homelab-agent.instructions.md
          context: |
            Task: Monitor cluster health and optimize for HA.

            Current Cluster State:
            ${{ steps.health.outputs.health_report }}

            Analyze:
            1. Node status - all healthy and schedulable?
            2. Critical pod replicas - meet HA requirements (3+ replicas)?
            3. Pod distribution - spread across nodes?
            4. Resource usage - identify bottlenecks?
            5. PDB (Pod Disruption Budgets) - adequate?

            Actions if issues found:
            1. Pod with 1 replica → Create PR to add replicas
            2. Pods on same node → Create PR with affinity rules
            3. Resource pressure → Create issue for scaling
            4. Critical service down → Create critical issue + Slack alert

            Automatic fixes (require no approval):
            - Adjust replica counts for non-critical apps
            - Add pod anti-affinity
            - Scale up resources

            Manual review needed for:
            - Hardware scaling
            - Major architecture changes
```

#### Phase 2: Self-Hosted GitHub Actions Runner in Cluster

Deploy a self-hosted runner in Kubernetes for agent execution:

**File: `kubernetes/apps/actions-runner-system/runner-deployment/helmrelease.yaml`**
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: actions-runner-controller
  namespace: actions-runner-system
spec:
  interval: 5m
  chart:
    spec:
      chart: actions-runner-controller
      version: "0.24.0"
      sourceRef:
        kind: HelmRepository
        name: actions-runner-controller
        namespace: flux-system
  values:
    authSecret:
      create: true
      namespace: actions-runner-system
      name: controller-manager

    # Self-managed runners
    runners:
      - name: deployment-agent
        replicas: 2
        image: ghcr.io/actions/runner:latest
        resourceRequests:
          cpu: 500m
          memory: 1Gi
        resourceLimits:
          cpu: 1000m
          memory: 2Gi
        labels:
          - agent
          - deployment

      - name: security-agent
        replicas: 1
        image: ghcr.io/actions/runner:latest
        resourceRequests:
          cpu: 500m
          memory: 1Gi
        labels:
          - agent
          - security

      - name: innovation-agent
        replicas: 1
        image: ghcr.io/actions/runner:latest
        resourceRequests:
          cpu: 250m
          memory: 512Mi
        labels:
          - agent
          - innovation
```

#### Phase 3: Agent Configuration via GitHub Issue Templates

Create templates to guide users and agents:

**File: `.github/ISSUE_TEMPLATE/deploy-app.md`**
```markdown
---
name: Deploy New Application
about: Deploy a new application to the homelab
title: 'Deploy [App Name]'
labels: deploy/app
---

## Application Details

**App Name**:
**Description**:

## Requirements

### Storage
- [ ] Persistent Volume needed?
- [ ] Size:
- [ ] Type (block/NFS):

### Networking
- [ ] Ingress needed?
- [ ] Internal/External:
- [ ] Custom domain:

### Dependencies
- [ ] Depends on other apps (list):

### Secrets/Config
- [ ] Environment variables (list):
- [ ] Secrets to store in 1Password (list):

## Helm Chart Info

**Repository**:
**Chart Name**:
**Chart Version**:

## Additional Notes

<!-- Agent will use this to deploy the app -->
```

**File: `.github/ISSUE_TEMPLATE/security-audit.md`**
```markdown
---
name: Security Audit
about: Request security audit
title: 'Security audit: [Component]'
labels: security
---

## Component to Audit

## Concerns

## Acceptance Criteria

<!-- Security agent will perform audit and create PR with fixes -->
```

### 14.4 Agent Capabilities & Limitations

#### Autonomous (No Approval Needed)
✅ Deploy non-critical apps
✅ Update app versions via Renovate PRs
✅ Add pod replicas for non-critical workloads
✅ Add pod anti-affinity rules
✅ Create monitoring alerts
✅ Security fixes (RBAC, pod security)

#### Requires Approval (PR Review)
⚠️ Deploy critical apps (Home Assistant, databases)
⚠️ Storage changes (resize PVs, change storage classes)
⚠️ Network policy changes
⚠️ Secret rotation
⚠️ Cluster configuration changes

#### Escalates to Humans
🔴 Hardware scaling decisions
🔴 Major architecture changes
🔴 Emergency security incidents (with incident post)
🔴 Breaking changes in dependencies
🔴 Cost increases > 20%

### 14.5 Example: Autonomous Deployment Flow

```
User creates issue:
  Title: "Deploy Home Assistant"
  Labels: deploy/app
  Body: Requirements, storage, network, etc.
    ↓
GitHub triggers: issues.opened event
    ↓
Workflow: agent-deployment.yaml starts
    ↓
Copilot Agent reads issue + instructions
    ↓
Agent generates:
  - kubernetes/apps/default/home-assistant/kustomization.yaml
  - kubernetes/apps/default/home-assistant/ks.yaml
  - kubernetes/apps/default/home-assistant/helmrelease.yaml
  - kubernetes/apps/default/home-assistant/ingress.yaml
  - kubernetes/apps/default/home-assistant/externalsecret.yaml
    ↓
Workflow validates:
  - kustomize build
  - helm lint
  - kubeval
    ↓
Agent creates PR:
  - Branch: feat/deploy-home-assistant
  - Commit message: [deploy] Add Home Assistant
  - Linked to issue #123
    ↓
Self-hosted runner in cluster:
  - Runs PR tests
  - Comments with validation results
    ↓
(Option A) Auto-merge if:
  - All tests pass
  - No sensitive changes
  - App is non-critical
    ↓
(Option B) Await review if:
  - App is critical (Home Assistant)
  - Complex dependencies
  - Manual decision needed
    ↓
PR merges → Flux detects changes
    ↓
Flux applies manifests
    ↓
Home Assistant deploys to cluster
    ↓
Agent adds issue comment:
  "✅ Deployment complete!"
  "Application ready at: https://home-assistant.local"
```

### 14.6 Monitoring & Logging Agents

Track agent actions and performance:

**File: `.github/workflows/agent-audit-log.yaml`**
```yaml
name: Agent Audit Log

on:
  workflow_run:
    workflows: [Deployment Agent, Security Agent, Innovation Agent]
    types: [completed]

jobs:
  log-to-storage:
    runs-on: ubuntu-latest
    steps:
      - name: Log agent execution
        run: |
          cat > /tmp/agent-log.json <<EOF
          {
            "timestamp": "$(date -Iseconds)",
            "workflow": "${{ github.workflow }}",
            "status": "${{ job.status }}",
            "actor": "${{ github.actor }}",
            "commit": "${{ github.sha }}",
            "artifacts": []
          }
          EOF

          # Upload to S3 or Azure Blob for long-term storage
          # This enables audit trails and analytics
```

### 14.7 Cost Optimization Strategy

TBD

### 14.8 Debugging & Troubleshooting Agents

When agents fail:

1. **Check workflow logs**:
   - GitHub Actions UI → Workflow → Recent runs
   - Look for error messages and exit codes

2. **Enable debug logging**:
   - Set `ACTIONS_STEP_DEBUG: true` in workflow env
   - Agents will output detailed debug traces

3. **Test agent locally**:
   - Clone repo locally
   - Run agent prompt in VS Code Copilot Chat
   - Verify output before deploying

4. **Create fallback issue**:
   - If agent fails, create GitHub issue with:
     - Label: `needs-manual-review`
     - Body: Agent error output + context
     - Assign to owner for manual intervention

---

## Final Notes

This homelab is a **learning platform and production system**. Agents should:
- ✅ **Automate repetitive tasks** (deployments, updates, monitoring)
- ✅ **Enforce best practices** (security, HA, GitOps)
- ✅ **Improve reliability** (monitoring, alerting, failover)
- ✅ **Innovate thoughtfully** (suggest improvements, test ideas)
- ⚠️ **Ask for help** when uncertain (escalate to humans for review)
- ⚠️ **Document decisions** (commit messages, PR comments, issues)

The goal is a **self-healing, declarative infrastructure** where users define desired state via GitHub Issues and agents make it happen.

Happy automating! 🚀
