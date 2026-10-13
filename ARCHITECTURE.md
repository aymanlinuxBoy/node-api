# Node API POC - End-to-End Architecture

## Overview

This document describes the complete architecture of the Node API Proof-of-Concept (POC), a production-ready, highly available Kubernetes deployment across multiple clusters with comprehensive observability, security hardening, automated deployments, and secrets management.

**Topology:**
- **3 Upstream Clusters** (RKE2-based, self-managed)
- **3 Downstream Clusters** (RKE2-based, fleet-managed)
- **Total Scale:** 9 nodes across 6 clusters, distributed for high availability and disaster recovery

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     CI/CD Pipeline                           │
│  (GitHub Actions → Build → Sign → Push → Policy Check)       │
└────────────────────────┬────────────────────────────────────┘
                         │
                    Docker Registry
                    (Signed Images)
                         │
        ┌────────────────┼────────────────┐
        │                │                │
    ┌───▼───┐        ┌───▼───┐       ┌───▼───┐
    │Upstream│       │Upstream│       │Upstream│
    │  C1    │       │  C2    │       │  C3    │
    └─┬─────┘       └─┬─────┘       └─┬─────┘
      │               │               │
      │ Fleet GitOps  │               │
      │ Automation    │               │
      │ & Sync        │               │
    ┌─▼───────────────▼───────────────▼─┐
    │                                   │
    │    Rancher Fleet Control Plane    │
    │  (Multi-Cluster Management)       │
    │  - GitOps Automation              │
    │  - Cluster Registration           │
    │  - Manifest Sync & Drift Control  │
    │  - Policy Enforcement             │
    │                                   │
    └──────────────────┬────────────────┘
                       │
        ┌──────────────┼──────────────┐
        │              │              │
    ┌───▼──┐      ┌───▼──┐       ┌───▼──┐
    │Down- │      │Down- │       │Down- │
    │stream│      │stream│       │stream│
    │ C1  │      │ C2  │       │ C3  │
    └─────┘      └─────┘       └─────┘
        │              │              │
        │         ┌─────┴──────┬──────┘
        │         │            │
        └─┬───────┘            │
          │                    │
          │    ┌───────────────┘
          │    │
    ┌─────▼────▼──┐       ┌────────┐
    │  Fluent Bit  │       │ Vault  │
    │ (DaemonSet)  │       │Secrets │
    │- App Logs    │       └───┬────┘
    │- K8s Events  │           │
    │- Metrics     │      Reloader
    │- Filtering   │     (Rotation)
    └─┬──┬─────────┘
      │  │
      │  └──────────────────────┐
      │                         │
    ┌─▼───────┐        ┌────────▼────┐
    │Longhorn │        │ PostgreSQL  │
    │ Storage │        │ (StatefulSet)
    └────────┬┘        └─────┬──────┘
             │               │
    ┌────────┴───────┬───────┘
    │                │
┌───▼──┐      ┌─────▼──┐    ┌──────────┐   ┌────────────┐
│Prometheus   │  Loki  │    │ Thanos   │   │  Grafana   │
│(Metrics)    │(Logs)  │    │(LTS Store)   │(Dashboards)
└───┬──┐      └─┬──────┘    └──────┬───┘   └────┬───────┘
    │  │        │                  │            │
    │  └────────┼──────────────────┼────────────┘
    │           │                  │
    └───────────┼──────────────────┘
                │
        ┌───────▼────────┐
        │ AlertManager   │
        │ (Notifications)│
        └────────────────┘
                │
            Slack/Email
          (Operations)
```

---

## Core Components

### 1. **Cluster Topology & Infrastructure**

#### Upstream Clusters (3x)
- **Purpose:** Primary workload execution, direct control
- **Configuration:** RKE2 with full node control
- **Nodes:** 3 nodes per cluster (vmi3565261, vmi3565262, vmi3565263)
- **Features:**
  - Direct Kubernetes API access
  - Local container runtime (containerd)
  - Network policies enforced
  - Resource guarantees via anti-affinity

#### Downstream Clusters (3x)
- **Purpose:** Fleet-managed, synchronized deployments
- **Registration:** Connected via Rancher Fleet
- **Deployment:** GitOps-driven from upstream
- **Features:**
  - Automatic sync with Fleet GitOps
  - Policy enforcement via Kyverno
  - Runtime monitoring via Falco
  - Shared observability stack

**Creation & Topology:**
- Clusters were provisioned with RKE2 using infrastructure-as-code
- Node distribution: Anti-affinity rules prevent pod concentration on overloaded nodes
- Network: Overlay networking with CoreDNS for service discovery
- Resilience: 3-node CoreDNS deployment with pod/node anti-affinity prevents DNS outages

---

### 2. **Container Image Pipeline**

```
Source Code (Git)
    │
    ├─ Linting/Testing (CI)
    │
    ├─ Build Image
    │
    ├─ Sign Image (Cosign - Keyless)
    │    └─ OpenID Connect attestation
    │
    ├─ Push to Registry
    │    └─ Docker Hub / Private Registry
    │
    ├─ Policy Verification (Kyverno)
    │    └─ Image signature validation
    │    └─ Image scan results check
    │
    └─ Deployment (GitOps Fleet)
         └─ Automatic sync to clusters
```

**Pipeline Steps:**
1. **Build Stage:** Docker image creation with security scanning
2. **Sign Stage:** Cosign keyless signing using OIDC (GitHub Actions)
3. **Push Stage:** Image pushed to registry with attestation
4. **Verify Stage:** Kyverno policies validate:
   - Image signature presence and validity
   - Container registry whitelist
   - No untagged images
5. **Deploy Stage:** Fleet GitOps syncs validated images to all clusters

**Policy Enforcement:**
- Kyverno admission controller prevents unverified images from running
- Failed policy checks block pod creation cluster-wide
- Audit logging via Falco captures policy violations

---

### 3. **GitOps & Automation (Rancher Fleet)**

**Fleet Control Plane:**
- **Centralized Multi-Cluster Management:** Controls 6 clusters (3 upstream + 3 downstream) from a single control plane
- **Git-Based Source of Truth:** All cluster configurations, deployments, and policies stored in Git
- **Automatic Synchronization:** Fleet agents on each cluster automatically pull and apply manifests
- **Cluster Registration & Management:** Downstream clusters register with Fleet for centralized control
- **Policy Enforcement Across Clusters:** Kyverno, Falco, and network policies deployed uniformly
- **Drift Detection & Auto-Remediation:** Detects config drift and automatically reconciles

**Deployment Flow:**
```
Git Repository (manifests/)
    │
    ├─ base/ (common configs)
    │   ├─ deployment.yaml
    │   ├─ service.yaml
    │   ├─ configmap.yaml
    │   └─ kustomization.yaml
    │
    ├─ overlays/ (cluster-specific)
    │   ├─ poc/ (node-api-poc app)
    │   │   ├─ kustomization.yaml (image tag, replicas)
    │   │   └─ patches/
    │   ├─ upstream-c1/
    │   ├─ upstream-c2/
    │   ├─ upstream-c3/
    │   ├─ downstream-c1/
    │   ├─ downstream-c2/
    │   └─ downstream-c3/
    │
    ├─ addons/ (shared components)
    │   ├─ prometheus/
    │   ├─ loki/
    │   ├─ vault/
    │   ├─ kyverno/
    │   ├─ falco/
    │   └─ longhorn/
    │
    └─ fleet.yaml (Fleet configuration)
         ├─ targets: [upstream-c1, downstream-*]
         ├─ helm values overrides
         └─ policy enforcement rules
         
    Fleet Agent (each cluster)
         ├─ Pulls Git changes every 15s
         ├─ Applies Kustomize overlays
         ├─ Manages Helm releases
         ├─ Syncs manifests to cluster
         ├─ Reports status back to Fleet
         └─ Auto-remedies drift (reconciliation)
```

**Key Automation Features:**
- **HelmChartConfig:** Manages RKE2 addons (CoreDNS, Ingress, Kyverno) without direct Helm access
- **Kustomize Overlays:** Environment-specific patches for each cluster (image tags, resource limits, replicas)
- **Image Tag Management:** Automatic image tag updates via CI pipeline → Git → Fleet sync
- **Drift Detection:** Detects manual changes (e.g., `kubectl edit`) and resets to Git state
- **Multi-Cluster Rollout:** Progressive deployment across clusters (canary → blue-green)
- **Cluster Health Monitoring:** Tracks sync status, resource utilization, and policy violations per cluster
- **GitOps PR Workflow:** All changes go through Git → PR review → merge → automatic sync

**Automation Benefits:**
- **Consistency:** All 6 clusters run identical configs (with cluster-specific overrides)
- **Auditability:** Git history tracks all changes (who, what, when)
- **Disaster Recovery:** Easy cluster rebuild: point Fleet to Git, let it reconcile
- **Policy Enforcement:** Kyverno/Falco policies deploy uniformly across all clusters
- **Secret Management:** Vault credentials injected via Reloader on all clusters simultaneously
- **Observability Rollout:** Fluent Bit DaemonSet, Prometheus, Loki deployed consistently across clusters
  - Fluent Bit configuration (filters, parsers, outputs) managed in Git
  - Scrape targets configured per-cluster (upstream vs downstream labels)
  - Loki datasource automatically configured in Grafana

---

### 3.5 **Deployment Strategies (Standard, Canary, Blue-Green)**

The Node API POC implements three deployment strategies via Argo Rollouts, enabling progressive rollouts, canary testing, and zero-downtime deployments:

**Directory Structure:**
```
k8s/
├── base/
│   ├── deployment.yaml              (Standard Kubernetes Deployment)
│   ├── canary/
│   │   ├── rollout.yaml            (Argo Rollouts - Canary)
│   │   └── kustomization.yaml
│   └── blue-green/
│       ├── rollout.yaml            (Argo Rollouts - Blue-Green)
│       └── kustomization.yaml
└── overlays/
    ├── poc/                         (Standard deployment)
    ├── canary/                      (Canary variant)
    └── blue-green/                  (Blue-green variant)
```

#### **1. Standard Deployment (Rolling Update)**

**Type:** Kubernetes `Deployment` (default rolling update strategy)

**Configuration:**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: node-api-poc
  namespace: devsecops
spec:
  replicas: 2
  strategy:
    type: RollingUpdate        # Default: replace pods incrementally
    rollingUpdate:
      maxSurge: 1              # Allow 1 extra pod during rollout
      maxUnavailable: 0        # Keep all pods available
```

**Rollout Behavior:**
- New pod starts → Old pod terminates
- Gradual replacement (1 pod at a time with maxSurge=1)
- Service traffic routes to both old and new versions during rollout
- No traffic control or analysis gates

**Use Case:** Standard deployments, non-critical updates, development clusters

**Verification:**
```bash
kubectl get deployment node-api-poc -n devsecops -o wide
kubectl rollout status deployment/node-api-poc -n devsecops
kubectl rollout history deployment/node-api-poc -n devsecops
```

#### **2. Canary Deployment (Progressive Rollout with Analysis)**

**Type:** Argo Rollouts `Rollout` with canary strategy

**Configuration:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: node-api-poc-canary
  namespace: devsecops-canary
spec:
  replicas: 2
  strategy:
    canary:
      steps:
      - setWeight: 10           # Step 1: Route 10% traffic to new version
      - analysis:
          templates:
            - templateName: node-api-poc-canary-success-rate
      - setWeight: 50           # Step 2: Route 50% traffic
      - analysis:
          templates:
            - templateName: node-api-poc-canary-success-rate
      - setWeight: 100          # Step 3: Route 100% traffic
      # Service automatically switches to new version after success
```

**Rollout Flow:**
```
Developer commits → CI builds & signs image
    │
    └─ Fleet detects change → Updates image tag
        │
        └─ Argo Rollouts starts canary rollout
            │
            ├─ 10% traffic to canary pod (1 new, 1 old)
            ├─ Analysis template checks success rate
            ├─ 50% traffic (1 new, 1 old)
            ├─ Analysis template checks success rate
            ├─ 100% traffic (2 new, 0 old)
            └─ Rollout completes, old pod deleted
```

**Analysis Gate Configuration:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: node-api-poc-canary-success-rate
spec:
  metrics:
  - name: success-rate
    provider:
      prometheus:
        address: http://prometheus:9090
        query: |
          rate(http_requests_total{job="node-api-poc"}[5m])
          / 
          rate(http_requests_total{job="node-api-poc"}[5m])
    thresholdRange:
      min: 0.99                 # Require 99% success rate
    interval: 1m
    count: 2                     # Check 2 times before proceeding
```

**Use Case:** Production deployments with safety gates, error rate monitoring, gradual traffic shifts

**Verification:**
```bash
kubectl get rollout node-api-poc-canary -n devsecops-canary
kubectl describe rollout node-api-poc-canary -n devsecops-canary
kubectl rollout history rollout node-api-poc-canary -n devsecops-canary
```

**Current Canary Status (from cluster):**
- Namespace: `devsecops-canary`
- Replicas: 2
- Strategy: 10% → 50% → 100% with success rate analysis
- Status: Currently monitoring traffic distribution

#### **3. Blue-Green Deployment (Instant Switchover)**

**Type:** Argo Rollouts `Rollout` with blue-green strategy

**Configuration:**
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: node-api-poc-bg
  namespace: devsecops-bg
spec:
  replicas: 2
  strategy:
    blueGreen:
      activeService: node-api-poc-bg-active      # Current live service
      previewService: node-api-poc-bg-preview    # New version service
      autoPromotionEnabled: true
      prePromotionAnalysis:
        templates:
          - templateName: node-api-poc-bg-success-rate
      scaleDownDelaySeconds: 30                  # Keep old version 30s before deletion
```

**Rollout Flow:**
```
Current State (Blue):
    2 running pods (v1.0.0)
    Service "active" → routes to v1.0.0
    
New Deployment (Green):
    2 new pods (v1.1.0) created
    Service "preview" → routes to v1.1.0 (for testing)
    Pre-promotion analysis checks success rate
    
After Analysis Passes:
    Service "active" switches → routes to v1.1.0
    v1.0.0 pods remain for 30s (rollback window)
    After 30s, v1.0.0 pods deleted
    
If Analysis Fails:
    Service "active" remains → routes to v1.0.0
    v1.1.0 pods deleted immediately
```

**Two Service Approach:**
```yaml
# Active service: what users see (production traffic)
apiVersion: v1
kind: Service
metadata:
  name: node-api-poc-bg-active
  namespace: devsecops-bg
spec:
  selector:
    app: node-api-poc-bg
  ports:
  - port: 3000
    targetPort: 3000

---
# Preview service: what we test before cutover
apiVersion: v1
kind: Service
metadata:
  name: node-api-poc-bg-preview
  namespace: devsecops-bg
spec:
  selector:
    app: node-api-poc-bg
  ports:
  - port: 3000
    targetPort: 3000
```

**Testing Flow:**
```bash
# 1. Deploy new version (automatically goes to preview service)
kubectl set image rollout/node-api-poc-bg container=v1.1.0

# 2. Test preview service
curl http://node-api-poc-bg-preview:3000/health

# 3. Run smoke tests
kubectl run test-pod --image=curlimages/curl -- \
  curl http://node-api-poc-bg-preview:3000/ready

# 4. If tests pass, promotion happens automatically (or manually)
kubectl argo rollout promote node-api-poc-bg -n devsecops-bg

# 5. Rollback if needed (within 30s window)
kubectl argo rollout abort node-api-poc-bg -n devsecops-bg
```

**Use Case:** Zero-downtime deployments, full version replacement, testing before cutover, instant rollback capability

**Verification:**
```bash
kubectl get rollout node-api-poc-bg -n devsecops-bg -o wide
kubectl get svc -n devsecops-bg node-api-poc-bg-active
kubectl get svc -n devsecops-bg node-api-poc-bg-preview
kubectl describe rollout node-api-poc-bg -n devsecops-bg
```

**Current Blue-Green Status (from cluster):**
- Namespace: `devsecops-bg`
- Replicas: 2
- Active service: Routes to current version
- Preview service: Routes to new version during deployment
- Scaledown delay: 30 seconds (rollback window)
- Auto-promotion: Enabled (after pre-promotion analysis passes)

#### **Comparison Table**

| Feature | Standard | Canary | Blue-Green |
|---------|----------|--------|-----------|
| **Rollout Speed** | Fast (sequential) | Gradual (gated) | Instant (switchover) |
| **Traffic Control** | All-or-nothing | Progressive (10→50→100%) | All old or all new |
| **Analysis Gates** | None | ✅ Per-step analysis | ✅ Pre-promotion only |
| **Rollback Speed** | Delete old pods (slow) | Stop new traffic (fast) | Instant (30s window) |
| **Testing** | Post-deployment | During deployment | Before cutover |
| **Resource Cost** | Minimal | Moderate | Highest (2 full replicas) |
| **Best For** | Dev/staging | Prod with risk gates | Prod zero-downtime |

#### **Fleet Integration (Multi-Cluster Deployment)**

All three strategies are deployed via Rancher Fleet across clusters:

```
k8s/overlays/poc/kustomization.yaml
    └─ Images: node-api-poc:latest (standard)

k8s/overlays/canary/kustomization.yaml
    └─ Uses base/canary/rollout.yaml
    └─ Images: node-api-poc-canary:latest

k8s/overlays/blue-green/kustomization.yaml
    └─ Uses base/blue-green/rollout.yaml
    └─ Images: node-api-poc-bg:latest
```

**Deployment Triggers:**
1. Developer commits to main
2. CI pipeline builds, signs, and pushes image
3. Git tags image in kustomization.yaml
4. Fleet detects change (15s polling)
5. Fleet applies manifests to all 6 clusters
6. Argo Rollouts executes the chosen strategy

#### **Monitoring Deployments**

```bash
# Watch all deployments/rollouts across namespaces
kubectl get deploy,rollout -A

# Monitor canary traffic shift
kubectl get rollout node-api-poc-canary -n devsecops-canary -w

# Check blue-green service routing
kubectl get svc -n devsecops-bg
kubectl get endpoints node-api-poc-bg-active -n devsecops-bg

# View deployment history
kubectl rollout history rollout/node-api-poc-canary -n devsecops-canary

# Check Argo Rollouts controller logs
kubectl logs -n argo-rollouts deployment/argo-rollouts
```

---

### 4. **Storage & Persistence (Longhorn + PostgreSQL)**

**Longhorn Deployment Architecture:**
```
Longhorn Storage Engine
    │
    ├─ Storage Class: "longhorn"
    ├─ Replication Factor: 3 (across nodes)
    ├─ Availability: High (any 2 nodes remain available)
    │
    ├─ Volume Configuration:
    │   ├─ Data Locality: "best-effort" (prefer local replicas)
    │   ├─ Trim: enabled (reclaim deleted block space)
    │   ├─ Snapshot Retention: 24 hourly snapshots
    │   ├─ Backup Retention: 14 daily backups
    │   └─ Backup Target: IDrive e2 (S3-compatible)
    │
    ├─ RecurringJobs:
    │   ├─ Snapshot: Every hour (cron: "0 * * * *", retain: 24)
    │   └─ Backup: Daily at 02:00 UTC (cron: "0 2 * * *", retain: 14)
    │
    └─ Persistent Volumes
         ├─ PostgreSQL Data Volume
         │   ├─ Size: 50Gi
         │   ├─ Replicated: 3 replicas across nodes
         │   ├─ Snapshots: 24 hourly (1 day history)
         │   ├─ Backups: 14 daily (2 weeks history)
         │   └─ Failover: < 30 seconds
         │
         └─ Application Logs Volume
             ├─ Size: 10Gi
             └─ Retention: 7 days
```

**Longhorn Configuration Details:**

**Storage Class:**
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn
provisioner: driver.longhorn.io/longhorn
allowVolumeExpansion: true
parameters:
  numberOfReplicas: "3"
  staleReplicaTimeout: "2880"  # 48 hours
  fromBackup: ""
```

**Volume Settings:**
- **Replication:** 3 replicas (one per node for 3-node cluster)
- **Trim:** Enabled (automatically reclaims deleted block space, reduces backup size)
- **Data Locality:** "best-effort" (schedules replicas to prefer local node storage)
- **Stale Replica Timeout:** 48 hours (rebuilds replicas that don't respond)

**Snapshot Policy (Hourly):**
```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: snapshot-hourly
  namespace: longhorn-system
spec:
  cron: "0 * * * *"           # Every hour at minute 0
  task: "snapshot"            # Create point-in-time snapshot
  groups:
  - default                   # Apply to default volume group
  retain: 24                  # Keep last 24 hourly snapshots (1 day)
  concurrency: 2              # Process 2 volumes in parallel
```

**Purpose:** Quick recovery from application errors (e.g., accidental deletion, corrupted transaction)
**Use Case:** Rollback to snapshot from 6 hours ago, verify data, restore if needed

**Backup Policy (Daily):**
```yaml
apiVersion: longhorn.io/v1beta2
kind: RecurringJob
metadata:
  name: backup-daily
  namespace: longhorn-system
spec:
  cron: "0 2 * * *"           # Daily at 2:00 AM UTC
  task: "backup"              # Create full backup to external storage
  groups:
  - default
  retain: 14                  # Keep last 14 daily backups (2 weeks)
  concurrency: 2
```

**Purpose:** Disaster recovery, cross-cluster restore, long-term archival
**Backup Target:** IDrive e2 (S3-compatible object storage)
  - Endpoint: `https://s3.idrivee2.com`
  - Bucket: `longhorn-backups-poc`
  - Retention: 14 days (2 weeks) before auto-deletion

**Backup & Recovery Flow:**
```
PostgreSQL Data (Longhorn Volume)
    │
    ├─ Hourly Snapshots (in-cluster)
    │   ├─ 1:00 AM snapshot
    │   ├─ 2:00 AM snapshot
    │   └─ ... (24 total)
    │
    └─ Daily Backups (to IDrive e2)
        ├─ Day 1 backup (full: 50GB initial)
        ├─ Day 2 backup (incremental: ~5GB changed data)
        ├─ Day 3 backup (incremental: ~5GB changed data)
        └─ ... (14 total, ~100GB stored)
```

**PostgreSQL Integration:**
- **Deployment:** StatefulSet with 1 replica (high-availability ready)
- **Storage:** Longhorn PVC with replication=3
- **Connection Pooling:** pg-pool with 10-20 connections
- **High Availability:**
  - Service DNS: `postgres.default.svc.cluster.local:5432`
  - Automatic failover via Longhorn volume promotion
  - Recovery Time Objective (RTO): < 2 minutes (failover to healthy replica)
  - Recovery Point Objective (RPO): < 5 minutes (snapshot interval)
  - Disaster Recovery: < 30 minutes (restore from daily backup)

**Failover Process (Node Failure):**
1. Node hosting primary PostgreSQL pod fails
2. Longhorn detects volume access loss (5-10 seconds)
3. Volume is promoted on replica node (remaining replicas become active)
4. Pod is rescheduled on healthy node via Kubernetes controller
5. Application reconnects via DNS (pg-pool handles retries)
6. Database consistency validated via CHECKSUMS
7. Automated alert triggered via Prometheus + AlertManager
8. Longhorn rebuilds 3rd replica from remaining 2 replicas

**Disaster Recovery Process (Complete Data Loss):**
1. Determine recovery point (snapshot or backup)
   - Last hour? → Use hourly snapshot
   - Last 2 weeks? → Use daily backup from IDrive e2
2. Create new PVC from snapshot/backup
3. Mount to recovery pod (verify data integrity)
4. Promote recovery pod to primary
5. Test application connections
6. Monitor database consistency checks
7. Update original pod to use recovered data

**Verification & Management:**

```bash
# Check Longhorn volumes and replicas
kubectl get volume -n longhorn-system
kubectl get volumereplicasets -n longhorn-system

# Check replication status
kubectl logs -n longhorn-system longhorn-manager-* | grep replica

# View snapshots for a volume
kubectl get snapshots -n longhorn-system

# List backups (stored in IDrive e2)
kubectl get backups -n longhorn-system
kubectl describe backup <backup-name> -n longhorn-system

# Monitor recurring jobs
kubectl get recurringjob -n longhorn-system
kubectl logs -n longhorn-system longhorn-recurring-job-manager-* -f

# Check backup target configuration
kubectl get setting backup-target -n longhorn-system -o yaml

# Test failover (simulate node failure)
kubectl delete node <node-name>
# Monitor Longhorn UI (http://longhorn-ui.longhorn-system.svc) for replica promotion

# Restore from snapshot (create new PVC from snapshot)
kubectl get snapshot <snapshot-name> -n longhorn-system -o yaml

# Restore from backup (create new PVC from IDrive e2 backup)
kubectl create -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-restored
spec:
  dataSource:
    name: postgres-backup-day-7
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 50Gi
EOF

# Monitor backup progress
kubectl get events -n longhorn-system --sort-by='.lastTimestamp' | grep -i backup
```

**Trim & Locality Benefits:**
- **Trim:** Deleted data in PostgreSQL (e.g., old transactions) reclaims block space
  - Reduces snapshot/backup size by 30-40%
  - Improves I/O performance (less stale data on disk)
  - Reduces storage costs (backups in IDrive e2 are smaller)
- **Locality:** Data replicas prefer local node storage
  - Reduces network I/O during reads (read from local replica)
  - Improves latency for PostgreSQL (lower p99 latencies)
  - Balances load across cluster nodes

**Backup Storage in IDrive e2:**
- **Location:** https://console.idrivee2.com/
- **Bucket:** `longhorn-backups-poc`
- **Retention Policy:** 14 daily backups (auto-deleted after 14 days)
- **Cost:** ~$0.03/GB/month (S3-compatible pricing)
- **Restore Time:** 5-10 minutes (depends on network bandwidth to IDrive e2)

**Example Recovery Scenario:**
```
Scenario: PostgreSQL corrupted after bad migration (Day 3)
  
1. Application detects data corruption at 3 PM
2. Check Longhorn snapshots:
   - 12 PM snapshot: ✓ good
   - 1 PM snapshot: ✗ corrupted
   - 2 PM snapshot: ✗ corrupted
   - 3 PM snapshot: ✗ corrupted (too late)
   
3. Use daily backup from Day 2 (2 AM, 25 hours old):
   - Restore volume from backup
   - Data loss: < 25 hours of transactions
   - RTO: 30 minutes
   
4. Verify data in restored volume
5. Promote to primary
6. Monitor PostgreSQL for consistency
7. Analyze what caused corruption
8. Migrate remaining data from old volume (manual reconciliation)
```

---

### 5. **Secrets Management (HashiCorp Vault)**

**Vault Architecture & Trust Chain:**

```
UPSTREAM CLUSTER (k3s)
┌─────────────────────────────────────────────────┐
│ HashiCorp Vault (Source of Truth)               │
│                                                 │
│ KV v2 Secrets:                                  │
│ ├─ secret/devsecops-bg/postgres                │
│ │  ├─ DB_USER                                  │
│ │  └─ DB_PASSWORD                              │
│ │                                              │
│ └─ secret/other-app/...                        │
│                                                 │
│ Policy (eso-postgres):                         │
│ └─ Read access: secret/data/devsecops-bg/*     │
│                                                 │
│ AppRole Auth:                                   │
│ └─ eso-postgres (role_id + secret_id)          │
│    └─ Bound to eso-postgres policy             │
└────────────────┬────────────────────────────────┘
                 │ Vault API (reachable URL)
                 │ http://<NODE_IP>:<NODEPORT>
                 ▼
DOWNSTREAM CLUSTER (RKE2)
┌─────────────────────────────────────────────────┐
│ Namespace: devsecops-bg                         │
│                                                 │
│ K8s Secret: vault-approle                       │
│ └─ secret_id (sensitive credential)             │
│                                                 │
│ SecretStore: vault-store                        │
│ ├─ Vault server URL + path                     │
│ ├─ AppRole auth method                         │
│ ├─ role_id (non-sensitive identifier)          │
│ └─ secret_id reference (from K8s Secret)       │
│                                                 │
│ ExternalSecret: postgres-credentials            │
│ ├─ Syncs from Vault KV secret                  │
│ ├─ Refresh interval: 1 minute                  │
│ └─ Creates/updates K8s Secret                  │
│                                                 │
│ K8s Secret: node-api-poc-bg-db-credentials     │
│ ├─ Owned by ExternalSecret                     │
│ ├─ DB_USER / DB_PASSWORD (auto-updated)        │
│ └─ Referenced by Argo Rollout                  │
│                                                 │
│ Argo Rollout: node-api-poc-bg                  │
│ └─ Mounts secret as env vars / volume          │
└─────────────────────────────────────────────────┘
```

**Three Core Concepts:**
1. **Policy:** WHAT may be accessed (read secret/data/devsecops-bg/postgres)
2. **AppRole:** WHICH machine identity can authenticate (eso-postgres)
3. **Credentials:** HOW to authenticate (role_id + secret_id → temporary token)

**Vault Installation:**
- **Deployment:** High-availability StatefulSet (3 replicas on upstream cluster)
- **Storage Backend:** Longhorn persistent volume (50Gi)
- **Authentication Methods:**
  - AppRole (for cross-cluster ESO authentication)
  - Kubernetes auth (for future pod integration)
  - Root token (for admin setup only)
- **Initialization:** Unsealing via auto-unseal (production) or Shamir keys (dev)

**Secret Types Managed:**
- **Database credentials** (PostgreSQL user/password via KV v2)
- **TLS certificates** (for ingress/internal communication)
- **API keys and OAuth tokens**
- **Container registry credentials**
- **Future:** Dynamic PostgreSQL credentials (Database Secrets Engine)

**Vault Configuration Steps:**

```bash
# 1. Enable KV v2 secrets engine
vault secrets enable -path=secret kv-v2

# 2. Create secret (with both user and password)
vault kv put secret/devsecops-bg/postgres \
  DB_USER=postgres \
  DB_PASSWORD='<DB_PASSWORD>'

# 3. Create least-privilege policy
vault policy write eso-postgres - <<'EOF'
path "secret/data/devsecops-bg/postgres" {
  capabilities = ["read"]
}
EOF

# 4. Enable AppRole auth method
vault auth enable approle

# 5. Create AppRole and attach policy
vault write auth/approle/role/eso-postgres \
  token_policies="eso-postgres" \
  token_ttl="1h" \
  token_max_ttl="4h"

# 6. Retrieve role_id (non-sensitive identifier)
vault read -field=role_id auth/approle/role/eso-postgres/role-id

# 7. Generate secret_id (sensitive credential - handle carefully)
vault write -f auth/approle/role/eso-postgres/secret-id

# 8. Test AppRole login
vault write auth/approle/login \
  role_id="<ROLE_ID>" \
  secret_id="<SECRET_ID>"
```

**Key Vault Configuration Details:**
- **KV v2 Path Rule:** CLI path: `secret/devsecops-bg/postgres` → Policy path: `secret/data/devsecops-bg/postgres` (note `/data/` segment)
- **AppRole TTL:** token_ttl=1h (auto-refresh), token_max_ttl=4h (max renewal)
- **Cross-Cluster Access:** Vault exposed on reachable URL (NodePort or Ingress) for downstream ESO connectivity

**Verification:**
```bash
# Check Vault status (upstream)
kubectl exec -it vault-0 -n vault -- vault status

# Verify KV v2 engine
kubectl exec -it vault-0 -n vault -- vault secrets list -detailed

# Verify secret exists
kubectl exec -it vault-0 -n vault -- vault kv get secret/devsecops-bg/postgres

# Verify policy
kubectl exec -it vault-0 -n vault -- vault policy read eso-postgres

# Verify AppRole configuration
kubectl exec -it vault-0 -n vault -- vault read auth/approle/role/eso-postgres

# Test Vault reachability from downstream
curl -sS http://<UPSTREAM_NODE_IP>:<VAULT_NODEPORT>/v1/sys/health
```

---

### 6. **Secret Rotation (External Secrets Operator + Reloader)**

**Complete Secret Rotation Architecture:**

```
SETUP: Upstream → Downstream
Vault Secret
    │
    ├─ Upstream: Configure AppRole + Policy
    │
    └─ Downstream: ESO → K8s Secret → Reloader → Pod Restart
    
ROTATION FLOW:
Vault KV Secret Updated (manual or automatic)
    │
    └─ ESO SecretStore detects change (via API query)
        │
        └─ ESO refreshes every 1 minute
            │
            └─ Updates K8s Secret: node-api-poc-bg-db-credentials
                │
                └─ ResourceVersion increments
                    │
                    └─ Reloader detects Secret change
                        │
                        └─ Triggers Argo Rollout restart
                            │
                            └─ Pods replaced (rolling update)
                                │
                                └─ New pods mount fresh secret
```

**Component Details:**

**1. External Secrets Operator (ESO) - Downstream cluster**

Install ESO on downstream RKE2 cluster:
```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace
```

**2. Store AppRole secret_id in Kubernetes Secret**

```bash
# On downstream cluster
kubectl create secret generic vault-approle \
  -n devsecops-bg \
  --from-literal=secret-id='<SECRET_ID>'
```

**3. SecretStore Configuration**

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-store
  namespace: devsecops-bg
spec:
  provider:
    vault:
      server: "http://<UPSTREAM_NODE_IP>:<VAULT_NODEPORT>"
      path: "secret"
      version: "v2"
      auth:
        appRole:
          path: "approle"
          roleId: "<ROLE_ID>"
          secretRef:
            name: vault-approle
            key: secret-id
```

**Key Configuration:**
- **server:** Reachable Vault API endpoint (HTTP or HTTPS)
- **path:** KV v2 engine path (default: "secret")
- **version:** "v2" (for KV v2 semantics)
- **roleId:** Non-sensitive identifier from Vault AppRole
- **secretRef:** References K8s Secret containing sensitive secret_id

**Verification:**
```bash
# Check SecretStore status
kubectl get secretstore vault-store -n devsecops-bg
kubectl describe secretstore vault-store -n devsecops-bg
# Expected: Ready=True condition
```

**4. ExternalSecret Configuration**

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: postgres-credentials
  namespace: devsecops-bg
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: vault-store
    kind: SecretStore
  target:
    name: node-api-poc-bg-db-credentials
    creationPolicy: Owner
  data:
  - secretKey: DB_USER
    remoteRef:
      key: devsecops-bg/postgres
      property: DB_USER
  - secretKey: DB_PASSWORD
    remoteRef:
      key: devsecops-bg/postgres
      property: DB_PASSWORD
```

**Key Configuration:**
- **refreshInterval:** 1m (ESO checks Vault every minute for changes)
- **secretStoreRef:** References SecretStore for Vault connection
- **target.name:** Generated K8s Secret name
- **creationPolicy: Owner:** ESO owns and manages the Secret lifecycle
- **data:** Maps Vault secret properties to K8s Secret keys

**Verification:**
```bash
# Check ExternalSecret status
kubectl get externalsecret postgres-credentials -n devsecops-bg
kubectl describe externalsecret postgres-credentials -n devsecops-bg
# Expected: SecretSynced condition = True

# Verify generated Secret was created
kubectl get secret node-api-poc-bg-db-credentials -n devsecops-bg

# Check Secret owner (should be postgres-credentials)
kubectl get secret node-api-poc-bg-db-credentials -n devsecops-bg \
  -o jsonpath='{.metadata.ownerReferences[*].name}'

# Monitor resourceVersion changes (increments on ESO sync)
kubectl get secret node-api-poc-bg-db-credentials -n devsecops-bg \
  -o jsonpath='resourceVersion={.metadata.resourceVersion}'
```

**5. Reloader Configuration**

Install Reloader with Argo Rollouts support:
```bash
helm repo add stakater https://stakater.github.io/stakater-charts
helm repo update

helm upgrade --install reloader stakater/reloader \
  -n reloader \
  --create-namespace \
  --set reloader.isArgoRollouts=true \
  --set reloader.autoReloadAll=false
```

**Configuration Notes:**
- **reloader.isArgoRollouts=true:** Enables Argo Rollouts restart support
- **reloader.autoReloadAll=false:** Only restarts workloads with explicit annotations (opt-in)

**6. Annotate Argo Rollout for Reloader**

```yaml
metadata:
  annotations:
    reloader.stakater.com/auto: "true"
    reloader.stakater.com/rollout-strategy: "restart"
  
spec:
  template:
    spec:
      containers:
      - name: app
        env:
        - name: DB_USER
          valueFrom:
            secretKeyRef:
              name: node-api-poc-bg-db-credentials
              key: DB_USER
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: node-api-poc-bg-db-credentials
              key: DB_PASSWORD
```

**Annotation Details:**
- **reloader.stakater.com/auto: "true":** Reloader watches referenced Secrets/ConfigMaps
- **reloader.stakater.com/rollout-strategy: "restart":** Restart pods without modifying rollout template (GitOps-friendly)

**Verification:**
```bash
# Check Reloader deployment
kubectl get pods -n reloader
kubectl get deployment reloader-reloader -n reloader \
  -o jsonpath='{.spec.template.spec.containers[0].args}'
# Expected: Contains --is-Argo-Rollouts=true

# Check rollout annotations
kubectl get rollout node-api-poc-bg -n devsecops-bg \
  -o jsonpath='{.metadata.annotations}'
# Expected: reloader.stakater.com/auto=true
```

**Complete Secret Rotation Test:**

```bash
# 1. Record current state
kubectl get secret node-api-poc-bg-db-credentials -n devsecops-bg \
  -o jsonpath='resourceVersion={.metadata.resourceVersion}'
kubectl get pods -n devsecops-bg -l app=node-api-poc-bg -o wide

# 2. Update Vault secret (upstream cluster)
vault kv put secret/devsecops-bg/postgres \
  DB_USER=postgres \
  DB_PASSWORD='<NEW_PASSWORD>'

# 3. Force ESO sync (optional, otherwise wait 1 minute)
kubectl annotate externalsecret postgres-credentials \
  -n devsecops-bg \
  force-sync=$(date +%s) \
  --overwrite

# 4. Monitor ESO sync
kubectl get externalsecret postgres-credentials -n devsecops-bg
kubectl describe externalsecret postgres-credentials -n devsecops-bg

# 5. Verify K8s Secret updated (resourceVersion changed)
kubectl get secret node-api-poc-bg-db-credentials -n devsecops-bg \
  -o jsonpath='resourceVersion={.metadata.resourceVersion}'

# 6. Watch Reloader logs
kubectl logs -n reloader deployment/reloader-reloader -f

# 7. Observe pod replacement (Argo Rollout)
kubectl get pods -n devsecops-bg -w
```

**Troubleshooting (Bottom → Top):**

```
Pod did not restart
    ↑
Did Reloader see the Secret update?
    ↑
Did K8s Secret resourceVersion change?
    ↑
Did ExternalSecret postgres-credentials sync?
    ↑
Is SecretStore vault-store Ready?
    ↑
Can downstream reach Vault?
    ↑
Can AppRole authenticate (role_id + secret_id)?
    ↑
Does policy eso-postgres allow read access?
    ↑
Does secret/devsecops-bg/postgres exist in Vault?
```

**Troubleshooting Commands:**

```bash
# 1. Check Reloader
kubectl logs -n reloader deployment/reloader-reloader --since=30m
kubectl get deployment reloader-reloader -n reloader \
  -o jsonpath='{.spec.template.spec.containers[0].args}'

# 2. Check K8s Secret
kubectl get secret node-api-poc-bg-db-credentials -n devsecops-bg \
  -o jsonpath='{.metadata.ownerReferences[*].name}'

# 3. Check ExternalSecret
kubectl describe externalsecret postgres-credentials -n devsecops-bg
kubectl get externalsecret postgres-credentials -n devsecops-bg -o yaml

# 4. Check SecretStore
kubectl describe secretstore vault-store -n devsecops-bg

# 5. Check Vault connectivity
curl -sS http://<UPSTREAM_NODE_IP>:<VAULT_NODEPORT>/v1/sys/health

# 6. Check Vault policy and AppRole (from upstream cluster)
vault policy read eso-postgres
vault read auth/approle/role/eso-postgres
vault kv get secret/devsecops-bg/postgres
```

**Known Limitations & Future Enhancements:**

- **Current:** Static KV v2 secrets (manual password updates)
- **Future:** Dynamic PostgreSQL credentials via Database Secrets Engine (auto-generated, short-lived)
- **Current:** 1-minute refresh interval (balance between latency and Vault load)
- **Future:** Webhook-based immediate sync (when Vault secret changes)

---

### 7. **Observability Stack**

**Overview:**
The observability stack collects metrics, logs, and events from all 6 clusters and provides unified querying and visualization:
- **Metrics:** Prometheus (scrapes every 30s) → Thanos (long-term storage)
- **Logs & Events:** Fluent Bit (DaemonSet) → Loki (aggregation & querying)
- **Visualization:** Grafana (dashboards, alerting, correlation)
- **Notifications:** AlertManager (routing, deduplication, notification channels)

**Collection Architecture:**
- **Fluent Bit:** Lightweight, flexible log/event collector (runs on every node)
- **Kubernetes Events:** Watches API server for pod lifecycle, policy violations, scheduling events
- **Application Logs:** Parsed from stdout/stderr with JSON, multiline support
- **System Logs:** Node-level diagnostics from journald
- **Custom Metrics:** Via Prometheus endpoints + Fluent Bit parsers

#### **7.1 Prometheus (Metrics Collection)**

**Architecture:**
```
Prometheus Server
    │
    ├─ Scrape Targets (30s interval)
    │   ├─ Kubernetes metrics (/metrics)
    │   ├─ Application metrics
    │   ├─ Node exporter (CPU, Memory, Disk)
    │   ├─ cAdvisor (container metrics)
    │   └─ Custom endpoints
    │
    ├─ Storage: 15 days local retention
    │    └─ Longhorn PVC
    │
    └─ Alert Rules
         ├─ CPU threshold violations
         ├─ Memory OOM warnings
         ├─ Disk space alerts
         ├─ Pod restart storms
         └─ Application-specific thresholds
```

**Key Metrics:**
- `node_cpu_seconds_total` — CPU usage per node
- `container_memory_usage_bytes` — Memory per pod
- `container_fs_usage_bytes` — Disk usage
- `http_request_duration_seconds` — API latency (custom)
- `postgres_connections` — Database connections (custom)

---

#### **7.2 Loki (Logs Aggregation) with Fluent Bit**

**Log & Event Pipeline:**
```
┌─ Application Logs (stdout/stderr)
│
├─ Kubernetes Events (API server)
│  └─ Pod lifecycle, scheduling, policy violations
│
├─ Node System Logs (syslog, kernel)
│
└─ Custom Metrics/Structured Logs
    │
    ├─ Fluent Bit (DaemonSet on each node)
    │  ├─ Input Plugins:
    │  │  ├─ tail (application logs from /var/log/containers/*)
    │  │  ├─ systemd (node logs from journald)
    │  │  ├─ kubernetes events (watches API server)
    │  │  └─ custom endpoints (Prometheus metrics)
    │  │
    │  ├─ Filter Plugins:
    │  │  ├─ kubernetes (adds k8s metadata: namespace, pod, node)
    │  │  ├─ modify (transform fields, add custom labels)
    │  │  ├─ grep (include/exclude logs by pattern)
    │  │  └─ parser (JSON parsing, multiline handling)
    │  │
    │  └─ Output Plugins:
    │     ├─ loki (ships logs to Loki)
    │     ├─ prometheus (exports metrics)
    │     └─ es (Elasticsearch integration if needed)
    │
    └─ Loki Server
        ├─ Ingest Plugins:
        │  ├─ Application logs with labels
        │  ├─ Kubernetes events (CrashLoopBackOff, PolicyViolation, etc.)
        │  └─ System logs (node-level diagnostics)
        │
        ├─ Storage: 7 days local
        │  └─ Longhorn PVC
        │
        ├─ Index: BoltDB
        └─ Chunks: On-disk compressed
```

**Fluent Bit Configuration (Example):**
```ini
# Input: Collect application logs
[INPUT]
    Name              tail
    Path              /var/log/containers/*/*.log
    Parser            docker
    Tag               kube.*
    Refresh_Interval  5

# Input: Kubernetes events
[INPUT]
    Name              kubernetes
    Tag               k8s.events
    
# Filter: Enrich with Kubernetes metadata
[FILTER]
    Name              kubernetes
    Match             kube.*
    Kube_URL          https://kubernetes.default.svc:443
    Kube_CA_File      /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    Kube_Token_File   /var/run/secrets/kubernetes.io/serviceaccount/token
    Labels            On
    Annotations       On

# Filter: Include only errors from demo-app
[FILTER]
    Name              grep
    Match             kube.var.log.containers.demo-app*
    Regex             level error|ERROR|Exception

# Filter: Add custom labels for routing
[FILTER]
    Name              modify
    Match             kube.*
    Add               cluster=poc-upstream-c1
    Add               environment=production

# Output: Ship to Loki
[OUTPUT]
    Name              loki
    Match             *
    host              loki.observability.svc.cluster.local
    port              3100
    labels            job=fluentbit,namespace=$kubernetes_namespace_name,pod=$kubernetes_pod_name
    label_keys        cluster,environment
```

**Available Log Labels (via Fluent Bit):**
- `namespace` — Kubernetes namespace
- `pod` — Pod name
- `container` — Container name
- `node` — Node hostname
- `cluster` — Cluster identifier
- `event_type` — Kubernetes event type (Pod, Node, Deployment, etc.)
- `reason` — Event reason (CrashLoopBackOff, PolicyViolation, etc.)
- `environment` — Environment tag (production, staging)
- `level` — Log level (error, warning, info) — parsed from logs

**Flexible Filtering & Collection:**
Fluent Bit can be configured to:
- **Include/Exclude:** Collect only specific namespaces, pods, or log patterns
- **Parse:** Extract structured data from JSON, multiline logs, syslog
- **Enrich:** Add Kubernetes metadata, custom fields, trace IDs
- **Route:** Send different logs to different outputs (Loki, Elasticsearch, S3)
- **Transform:** Rename fields, convert formats, redact sensitive data

**Query Examples (LogQL):**
```promql
# All logs in namespace
{namespace="default"}

# Application errors from demo-app
{pod="demo-app-*", level="error"}

# Kubernetes events (policy violations)
{event_type="Pod", reason="PolicyViolation"}

# PostgreSQL warnings
{pod="postgres-*"} | "WARNING"

# Pod crashes (CrashLoopBackOff events)
{reason="CrashLoopBackOff"}

# Multi-cluster view
{cluster=~"poc-.*"}
```

**Verification:**
```bash
# Check Fluent Bit DaemonSet
kubectl get daemonset -n observability fluent-bit

# View Fluent Bit logs
kubectl logs -n observability -l app=fluent-bit -f

# Query Loki via CLI
kubectl exec -it loki-0 -n observability -- \
  curl -s 'http://localhost:3100/loki/api/v1/query_range?query={namespace="default"}' | jq
```

---

#### **7.2.1 Kubernetes Events Collection**

**Event Types Monitored:**
- **Pod Lifecycle:** Created, Started, Ready, Failed, Deleted
- **Scheduling:** FailedScheduling, Scheduled, PreemptingExpiredNode
- **Resource Management:** OOMKilled, Evicted, DiskPressure
- **Security Violations:** PolicyViolation (Kyverno), AppArmor denials
- **Image Issues:** ImagePullBackOff, RegistryUnavailable, InvalidImageName
- **Container Errors:** CrashLoopBackOff, ExitCode, Exec probe failed
- **Node Issues:** NodeNotReady, NotReady, MemoryPressure, DiskPressure

**Event Flow:**
```
Kubernetes API Server
    │
    ├─ Emits events for all resource changes
    │
    └─ Fluent Bit Kubernetes Plugin
        │
        ├─ Watches: events.k8s.io/v1 API
        ├─ Filters: namespace, involved object type
        ├─ Enriches: adds metadata (cluster, node, timestamp)
        │
        └─ Sends to Loki with labels:
             ├─ event_type (Pod, Node, Deployment)
             ├─ reason (FailedScheduling, CrashLoopBackOff)
             ├─ involved_object (pod/deployment name)
             └─ cluster (poc-upstream-c1)
```

**Event Query Examples (LogQL):**
```promql
# All policy violations
{event_type="Pod", reason="PolicyViolation"}

# Image pull failures
{reason=~"ImagePullBackOff|RegistryUnavailable"}

# Pod crashes in production
{reason="CrashLoopBackOff", namespace=~"prod-.*"}

# Node issues
{event_type="Node", reason=~"NotReady|DiskPressure"}

# Kyverno policy events
{reason="PolicyViolation"} | json | cluster_name="poc-upstream-c1"
```

**Alert Integration:**
- Fluent Bit parses events → Loki stores with searchable labels
- Grafana dashboards visualize events timeline
- AlertManager rules trigger on specific event patterns (e.g., >5 CrashLoopBackOff in 10m)

---

#### **7.4 Thanos (Long-Term Storage)**

**Purpose:** Unlimited historical metrics retention across clusters

**Architecture:**
```
Prometheus (each cluster)
    │
    └─ Thanos Sidecar
        │
        └─ Uploads metrics to S3
            │
            └─ Thanos Object Storage Gateway
                │
                ├─ Deduplicates metrics
                ├─ Compacts data (1h → 24h → 30d)
                └─ Enables global queries
```

**Storage Tiers:**
- **Hot (0-2 days):** Prometheus local + Thanos sidecar
- **Warm (2-30 days):** S3 compressed chunks
- **Cold (30+ days):** S3 archived, searchable via Grafana

**Retention Policy:**
- Local Prometheus: 15 days
- Thanos S3: 1 year
- Total retention: 365 days

---

#### **7.5 Grafana (Dashboards & Visualization)**

**Dashboards:**

1. **Cluster Health Overview**
   - Cluster availability (%)
   - Node CPU/Memory utilization
   - Pod counts per namespace
   - Network traffic

2. **Application Performance**
   - HTTP request latency (p50, p95, p99)
   - Error rate (4xx, 5xx)
   - Database query duration
   - Cache hit ratio

3. **Database (PostgreSQL)**
   - Connection count
   - Query latency
   - Transactions/sec
   - Replication lag (if applicable)

4. **Storage (Longhorn)**
   - Volume utilization
   - I/O throughput
   - Replication status
   - Snapshot backups

5. **Security**
   - Kyverno policy violations
   - Falco runtime alerts
   - ImagePullBackOff incidents
   - Certificate expiration

**Alerting Integration:**
- Dashboards linked to Prometheus alerts
- Click-through to logs (Loki datasource)
- Multi-cluster view (Thanos datasource)

---

### 8. **Alert Management & Notifications**

**AlertManager Architecture:**
```
Prometheus Alert Rules
    │
    ├─ Triggered when threshold exceeded
    ├─ Example: `cpu_usage > 80%` for 5m
    │
    └─ AlertManager
         │
         ├─ Deduplication (same alert, multiple sources)
         ├─ Grouping (related alerts grouped)
         ├─ Routing (alert → notification channel)
         │
         └─ Notification Channels
              ├─ Slack (team-ops channel)
              ├─ PagerDuty (critical incidents)
              ├─ Email (ops@company.com)
              └─ Webhook (custom automation)
```

**Alert Routing Rules:**
```yaml
# Severity-based routing
- match:
    severity: critical
  receiver: pagerduty
  repeat_interval: 5m

- match:
    severity: warning
  receiver: slack
  repeat_interval: 1h

- match:
    severity: info
  receiver: email
  repeat_interval: 24h
```

**Common Alerts:**
- **Node Down:** Node not reporting metrics for 5m
- **Pod Crash Loop:** Pod restart count > 3 in 30m
- **Database Unreachable:** PostgreSQL connection failures
- **High Memory:** Memory usage > 90% for 5m
- **Disk Space Low:** Available disk < 10%
- **Image Pull Failed:** ImagePullBackOff events
- **Kyverno Policy Violation:** Policy denial rate > 5/min
- **Falco Runtime Alert:** Suspicious process activity

**Verification:**
```bash
# Check AlertManager status
kubectl logs -n prometheus -l app=alertmanager

# Send test alert
kubectl exec -it prometheus-0 -n prometheus -- \
  amtool alert add TestAlert

# View active alerts
kubectl exec -it prometheus-0 -n prometheus -- \
  amtool alert
```

---

### 9. **Security Hardening Layers**

#### **9.1 Kyverno (Policy Enforcement)**

**Implementation & Architecture:**

Kyverno is deployed as cluster-scoped policies that validate image references and signatures for Pods in target namespaces. Two primary policies are managed via GitOps:

**Repository Structure:**
```
k8s/
├── policies/
│   ├── kustomization.yaml
│   ├── image-validating-policy.yaml    (signature verification)
│   └── restrict-image-repository.yaml  (repository whitelist)
└── argocd/
    └── application-policies.yaml       (GitOps integration)
```

**Policies Deployed:**

1. **Image Repository Restriction** (`node-api-poc-restrict-image-repository`)
   - **Scope:** Validates `Pod CREATE` and `UPDATE` operations
   - **Target Namespaces:** `devsecops`, `devsecops-bg`, `devsecops-canary`
   - **Approved Repositories (per namespace):**
     - `devsecops` / `devsecops-bg`: `aimocont2020/node-api-poc`, `aimocont2020/devsecops-demo`
     - `devsecops-canary`: `aimocont2020/node-api-poc` (canary-specific restriction)
   - **Containers Checked:** regular containers, init containers, ephemeral containers
   - **Mode:** Audit (non-blocking, violations recorded in PolicyReport)

2. **Image Signature Verification** (`node-api-poc-verify-signature`)
   - **Policy Type:** `ImageValidatingPolicy` (CEL-based)
   - **Image Match:** `aimocont2020/node-api-poc` (with or without `docker.io/` prefix)
   - **Verification Method:** Cosign keyless signing
   - **OIDC Issuer:** `https://token.actions.githubusercontent.com`
   - **Trusted Workflow:** `https://github.com/aymanlinuxBoy/node-api/.github/workflows/ci-security.yml@refs/heads/main`
   - **Rekor Log:** `https://rekor.sigstore.dev` (transparency log)
   - **Enforcement:** `required: true`, `verifyDigest: true`, `mutateDigest: true`
   - **Mode:** Audit with `failurePolicy: Ignore` (non-blocking until switched to Deny)

3. **Resource Limits** (via Kyverno)
   - CPU/memory limits required
   - Prevents resource exhaustion attacks
   - Enforces namespace quotas

4. **Network Policies**
   - Default deny ingress/egress
   - Whitelisted pod-to-pod communication
   - DNS access only to coredns

5. **Pod Security Standards**
   - No privileged containers
   - No root user
   - Read-only filesystem required
   - Dropped Linux capabilities

6. **RBAC Enforcement**
   - ServiceAccount per workload
   - Role bindings validated
   - Prevents privilege escalation

**Validation Before Deployment:**

```bash
# 1. Render and validate Kustomize output
kubectl kustomize k8s/policies

# 2. Server-side dry-run (validates against API)
kubectl apply --dry-run=server -k k8s/policies

# 3. Check policy resources exist
kubectl get validatingpolicy node-api-poc-restrict-image-repository
kubectl get imagevalidatingpolicy node-api-poc-verify-signature

# 4. Review policy details
kubectl describe imagevalidatingpolicy node-api-poc-verify-signature
```

**GitOps Integration (Argo CD):**
- **Application:** `node-api-poc-policies` (in `argocd` namespace)
- **Repository:** `https://github.com/aymanlinuxBoy/node-api.git`
- **Branch:** `main`
- **Path:** `k8s/policies`
- **Sync:** Automated, with pruning and self-healing enabled
- **Destination:** `downstream` cluster, `kyverno` namespace

**Audit vs. Deny Modes:**

| Mode | Violation Handling | Error Handling | Current Status |
|------|-------------------|----------------|-----------------|
| `Audit` + `failurePolicy: Ignore` | Records in PolicyReport, admits Pod | Ignores errors, admits Pod | **Current (non-blocking)** |
| `Deny` + `failurePolicy: Ignore` | Rejects Pod | Ignores errors, rejects Pod | Future (after validation) |
| `Deny` + `failurePolicy: Fail` | Rejects Pod | Rejects on error (fail-closed) | Production-grade |

**Important:** Do NOT enable Deny mode until:
- All false positives are fixed
- Cosign/Sigstore connectivity is validated from all nodes
- Network timeouts won't block legitimate Pod creation
- PolicyReport violations are reviewed and classified

**Testing Policy Behavior:**

```bash
# Test 1: Unsigned image (should fail policy)
kubectl run test-unsigned --image=alpine:latest -n devsecops --dry-run=server -o yaml

# Test 2: Whitelisted image (should pass)
kubectl run test-node-api --image=aimocont2020/node-api-poc:latest -n devsecops-canary --dry-run=server -o yaml

# Test 3: Restricted repo in canary (should fail policy)
kubectl run test-devsecops-demo --image=aimocont2020/devsecops-demo:latest -n devsecops-canary --dry-run=server -o yaml
```

**Monitoring & Verification:**

```bash
# Check Kyverno controller status
kubectl get pods -n kyverno

# View PolicyReport violations
kubectl get policyreport -A
kubectl describe policyreport -n devsecops

# Monitor Kyverno logs
kubectl logs -n kyverno deployment/kyverno -f | grep -Ei 'error|violation|signature'

# Check Argo CD Application status
kubectl -n argocd get application node-api-poc-policies
```

**Impact on Deployment:**
- All pods must pass policies before scheduling (currently Audit mode, non-blocking)
- Failed policy → violation recorded in PolicyReport
- Audit logging via PolicyReport captures all violations
- When switched to Deny mode: failed policy → pod stays in `CreateContainerError`
- False positives: Adjust allow-list or request policy exemption

---

#### **9.2 Falco (Runtime Security)**

**Purpose & Architecture:**

Falco is a runtime security engine that detects anomalous behavior inside containers by monitoring kernel system calls. It complements AppArmor (preventive) by detecting (detective) what processes are doing in real-time.

**Detection Capabilities:**

1. **Suspicious Processes**
   - Unexpected binaries run in container (e.g., `bash` in nginx container)
   - Shell spawn in application pod (`/bin/sh`, `/bin/bash`)
   - Package manager execution in running container (`apt`, `apk`, `rpm`)
   - Process execution in privileged containers

2. **File Access**
   - Writes to system directories (`/etc`, `/sys`, `/proc`)
   - Reads from sensitive files (`/etc/shadow`, `/etc/passwd`, `/root/.ssh`)
   - Deletes application files
   - Modifications to application binaries

3. **Network Activity**
   - Outbound connections to unknown hosts (exfiltration attempts)
   - Port scanning activity (reconnaissance)
   - DNS queries to suspicious domains
   - Reverse shell connections

4. **Privilege Escalation**
   - setuid/setgid calls
   - Capability additions at runtime
   - Namespace escape attempts

**Installation & Configuration:**

```bash
# Add Falco Helm repository
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update

# Install Falco as DaemonSet (runs on every node)
helm upgrade --install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  -f falco-values.yaml

# Verify installation
kubectl get pods -n falco -o wide
kubectl get daemonset -n falco
```

**Custom Rule Configuration (from falco-values.yaml):**

```yaml
customRules:
  # Example: Detect cat execution in specific pod
  Cat Executed Inside AppArmor Test Deployment: |
    - rule: Cat Executed Inside AppArmor Test Deployment
      desc: Detect cat execution in labelled test pod
      condition: >
        spawned_process and 
        proc.name = "cat" and 
        container and 
        k8s.namespace.name = "default" and 
        k8s.pod.label[app] = "apparmor-test"
      output: >
        Cat command executed
        (user=%user.name, container=%container.name, pod=%k8s.pod.name)
      priority: WARNING
```

**Rule Components:**
- **condition:** CEL expression matching syscalls and metadata
- **output:** What to log when rule fires
- **priority:** Alert severity (CRITICAL, WARNING, NOTICE, INFO, DEBUG)
- **k8s.pod.label[key]:** Access pod labels (bracket syntax required)

**Alert Severity Levels:**
- **CRITICAL:** Immediate action needed (privilege escalation, reverse shell)
- **WARNING:** Investigate (shell spawn, unusual file access)
- **NOTICE:** Notable but expected (network connections)
- **INFO:** Logging only (allowed operations)

**Testing Detection:**

```bash
# 1. Find Falco pod on same node as test workload
kubectl get pods -n default -l app=apparmor-test -o wide
kubectl get pods -n falco -o wide

# 2. Watch Falco logs
kubectl logs -n falco <falco-pod> -c falco -f --since=1m \
  | grep 'Cat Executed Inside AppArmor Test Deployment'

# 3. Trigger detection in separate terminal
kubectl exec -n default deployment/apparmor-test -- cat /etc/hostname

# 4. Verify event appears in Falco logs (includes cmd, pod, namespace, container)
```

**Integration with Observability Stack:**

- **Falco → Prometheus:** Falco metrics (detections/sec, rules fired)
- **Falco → Loki:** Falco events as structured logs (queryable, filterable)
- **Falco → AlertManager:** Critical alerts trigger Slack/PagerDuty notifications

**Falcosidekick (Notification Forwarding):**

Falcosidekick bridges Falco to external systems:

```bash
# Store webhook URL in secret (never commit URLs)
kubectl create secret generic falco-teams-webhook \
  -n falco \
  --from-literal=url='https://...'

# Configure in Helm values
helm upgrade falco falcosecurity/falco \
  --set falco.grpcOutput.enabled=true \
  --set falcosidekick.enabled=true \
  --set falcosidekick.webui.enabled=true \
  --set falcosidekick.config.webhook.address='$WEBHOOK_ADDRESS'
```

**Monitoring Falco:**

```bash
# Check DaemonSet status
kubectl get daemonset -n falco
kubectl describe daemonset falco -n falco

# View Falco controller logs
kubectl logs -n falco deployment/falco -f

# Monitor alerts (tail last 5m)
kubectl logs -n falco -l app.kubernetes.io/name=falco --since=5m \
  | grep -i 'WARNING\|CRITICAL'

# Query Loki for Falco events
kubectl exec -it loki-0 -n observability -- \
  curl -s 'http://localhost:3100/loki/api/v1/query?query={job="falco"}'
```

**Current Implementation (from PoC):**

- **Deployment:** DaemonSet (one pod per node)
- **Custom rules:** Enabled via ConfigMap
- **Artifact installation:** Disabled (bypass external DNS issue)
- **Falcosidekick:** Optional webhook forwarding to Teams/Power Automate
- **Mode:** Detection only (non-blocking alerts)

**AppArmor + Falco Layered Defense:**

```text
Attack Attempt (e.g., shell spawn in nginx)
    │
    ├─ AppArmor: "Process not allowed" → BLOCKS syscall
    └─ Falco: "Shell spawned in container" → ALERTS/LOGS
    
Result: Attack prevented + incident logged
```

---

#### **9.3 AppArmor Profiles**

**Implementation & Prerequisites:**

AppArmor is a Linux kernel security module that restricts what processes inside containers may do. Each profile is loaded on cluster nodes at `/etc/apparmor.d/` and must be present before a Pod references it.

**Node Prerequisites (on each cluster node):**

```bash
# 1. Verify AppArmor is enabled in kernel
cat /sys/module/apparmor/parameters/enabled
# Expected: Y

# 2. Verify apparmor_parser utility is installed
command -v apparmor_parser

# 3. Check current profile status
sudo aa-status
```

**AppArmor Profile Deployment:**

Profiles must be deployed to `/etc/apparmor.d/` on EVERY node that may run a Pod using that profile. Two deployment methods:

**Method 1: Manual (Node-level, for PoC)**
```bash
# On each node, save and load the profile
sudo tee /etc/apparmor.d/k8s-demo-app >/dev/null <<'EOF'
#include <tunables/global>

profile k8s-demo-app flags=(attach_disconnected) {
  #include <abstractions/base>
  
  # Allow file operations
  file,
  
  # Deny writes
  deny /** w,
}
EOF

# Load and verify
sudo apparmor_parser -r /etc/apparmor.d/k8s-demo-app
sudo grep 'k8s-demo-app' /sys/kernel/security/apparmor/profiles
# Expected: k8s-demo-app (enforce)
```

**Method 2: Automated (DaemonSet-based, production)**

Create a DaemonSet that loads profiles on all nodes:

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: apparmor-loader
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: apparmor-loader
  template:
    metadata:
      labels:
        app: apparmor-loader
    spec:
      hostNetwork: true
      hostPID: true
      tolerations:
      - operator: Exists
      containers:
      - name: loader
        image: ubuntu:latest
        securityContext:
          privileged: true
        volumeMounts:
        - name: host-root
          mountPath: /host
        - name: profiles
          mountPath: /profiles
        command:
        - bash
        - -c
        - |
          mkdir -p /host/etc/apparmor.d/
          cp /profiles/* /host/etc/apparmor.d/
          chroot /host /usr/sbin/apparmor_parser -r /etc/apparmor.d/k8s-demo-app
          grep 'k8s-demo-app' /host/sys/kernel/security/apparmor/profiles
      volumes:
      - name: host-root
        hostPath:
          path: /
      - name: profiles
        configMap:
          name: apparmor-profiles
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: apparmor-profiles
  namespace: kube-system
data:
  k8s-demo-app: |
    #include <tunables/global>
    profile k8s-demo-app flags=(attach_disconnected) {
      #include <abstractions/base>
      file,
      deny /** w,
    }
```

**Pod Integration:**

Reference the profile in Pod security context using the `appArmorProfile` field:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
spec:
  template:
    spec:
      containers:
      - name: app
        image: busybox:latest
        securityContext:
          allowPrivilegeEscalation: false
          appArmorProfile:
            type: Localhost
            localhostProfile: k8s-demo-app  # Must exist on node
```

**Verification:**

```bash
# 1. Confirm process is confined
kubectl exec -it <pod> -- cat /proc/1/attr/current
# Expected: k8s-demo-app (enforce)

# 2. Test allowed operation (read)
kubectl exec -it <pod> -- cat /etc/hostname
# Should succeed

# 3. Test denied operation (write)
kubectl exec -it <pod> -- touch /tmp/test-file
# Should fail: Permission denied (if profile denies writes)
```

**Example Profile (nginx in complain mode):**
```
#include <tunables/global>

profile demo-app flags=(complain) {
  #include <abstractions/base>
  #include <abstractions/nameservice>
  
  capability net_bind_service,
  
  /etc/nginx/** r,
  /usr/sbin/nginx r,
  /var/log/nginx/** w,
  /var/cache/nginx/** rw,
  
  deny /root/** rwx,
  deny /sys/** w,
}
```

**Profile Modes:**
- **`complain`:** Audit-only; violations logged but not blocked (learning mode)
- **`enforce`:** Violations blocked; process cannot perform denied action
- **`attach_disconnected`:** Allows profile to follow process across namespace transitions (required for containers)

**AppArmor + Falco Integration:**

AppArmor restricts **what** a process can do; Falco detects **what** a process is trying to do:

```text
Pod tries to execute process
    │
    ├─ AppArmor: "Deny write to /root" → blocks syscall
    └─ Falco: "Shell spawned in confined container" → alerts
```

**Troubleshooting:**

```bash
# Check if profile loaded on node
ssh <node> "sudo grep 'k8s-demo-app' /sys/kernel/security/apparmor/profiles"

# View AppArmor denials in audit log
ssh <node> "sudo dmesg | grep apparmor | tail -20"

# Reload profile after changes
ssh <node> "sudo apparmor_parser -r /etc/apparmor.d/k8s-demo-app"

# Profile syntax validation (before loading)
apparmor_parser -d /etc/apparmor.d/k8s-demo-app
```

**Current Implementation:**

- **Mode:** Complain (audit-only, non-blocking)
- **Profiles:** Located in `security-hardnes-poc/` folder
- **Integration:** Referenced via Pod `appArmorProfile.localhostProfile`
- **Deployment:** Manual per-node setup or automated via DaemonSet
- **Monitoring:** Integration with Falco for detection; AppArmor denials logged to kernel audit

---

### 10. **Cluster Resilience & High Availability**

#### **Anti-Affinity Rules**

**Node-Level Anti-Affinity (soft preferred):**
- Avoids scheduling multiple pods on same node
- Prevents single node failure = cluster outage
- Applied to: CoreDNS, Kyverno, PostgreSQL, Prometheus

**Pod-Level Anti-Affinity (soft preferred):**
- Spreads replicas across availability zones
- CoreDNS: 3 replicas on 3 different nodes
- Kyverno: 3 controller replicas distributed

**Configuration:**
```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        labelSelector:
          matchExpressions:
          - key: app
            operator: In
            values: [coredns]
        topologyKey: kubernetes.io/hostname
```

#### **DNS Resilience (CoreDNS)**

**Problem Solved:** CoreDNS on overloaded node (83% CPU) caused DNS timeouts → connection timeouts on all services

**Solution:**
- CoreDNS replicas: 3 (was 1)
- Node anti-affinity: Spread across 3 nodes
- Pod anti-affinity: No two CoreDNS pods on same node
- HelmChartConfig manages configuration durability

**Verification:**
```bash
# Check CoreDNS replicas
kubectl get deployment -n kube-system coredns

# Test DNS resolution
kubectl run -it dns-test --image=busybox -- nslookup kubernetes

# Monitor DNS latency
kubectl logs -n kube-system -l k8s-app=kube-dns
```

---

## Complete Data Flow Example

### Scenario: Deploy Node API POC with Database

```
1. Developer commits code to Git
   └─ Triggers GitHub Actions CI pipeline

2. CI Pipeline:
   ├─ Runs tests
   ├─ Builds Docker image
   ├─ Signs image with Cosign (keyless, OIDC)
   ├─ Pushes to Docker Hub
   └─ Updates Git with new image tag

3. Fleet GitOps detects change:
   ├─ Pulls updated kustomization
   ├─ Applies to all 6 clusters
   └─ Creates deployment manifests

4. Kubernetes cluster:
   ├─ Kyverno admission controller intercepts pod creation
   ├─ Validates image signature (must be signed)
   ├─ Validates image source (must be from whitelist)
   ├─ Schedules pod on healthy node (anti-affinity honored)
   └─ Pod starts running

5. Pod initialization:
   ├─ Vault agent sidecar injects database credentials
   ├─ PostgreSQL connection pooling connects to database
   │   └─ Via DNS: postgres.default.svc.cluster.local
   │   └─ Stored on Longhorn persistent volume
   └─ Application ready

6. Runtime monitoring:
   ├─ Prometheus scrapes metrics every 30s
   │   └─ Stored on Longhorn PVC, synced to Thanos S3
   ├─ Promtail ships logs to Loki
   │   └─ Stored on Longhorn PVC
   ├─ Falco monitors pod behavior
   │   └─ Detects suspicious activity
   └─ Grafana visualizes all data

7. Incident scenario (node failure):
   ├─ Node vmi3565261 goes offline
   ├─ PostgreSQL pod is rescheduled to vmi3565262
   ├─ Longhorn volume is promoted on new node (5-10s)
   ├─ Application reconnects via DNS (pg-pool retries)
   ├─ Prometheus alert triggered (NodeDown)
   ├─ AlertManager notifies Slack/PagerDuty
   └─ Operations team investigates

8. Secret rotation scenario:
   ├─ Vault secret (DB password) expires
   ├─ Vault rotates the secret
   ├─ Vault agent on pod detects change
   ├─ Updates mounted secret file
   ├─ Reloader detects change (configmap annotation)
   ├─ Triggers rolling restart of deployment
   ├─ New pods get fresh secrets
   └─ No connection interruption (rolling update)
```

---

## System Verification Checklist

### Cluster Health

```bash
# Overall cluster status
kubectl cluster-info
kubectl top nodes
kubectl get nodes -o wide

# Component status
kubectl get cs

# Persistent volumes
kubectl get pv,pvc -A
```

### Storage (Longhorn)

```bash
# Volume status
kubectl get volume -n longhorn-system

# Replica status
kubectl logs -n longhorn-system longhorn-manager-* | grep replica

# PostgreSQL connection
kubectl exec -it postgres-0 -- psql -U postgres -c "SELECT version();"
```

### Secrets (Vault)

```bash
# Vault status
kubectl exec -it vault-0 -n vault -- vault status

# Secret retrieval
kubectl exec -it <pod> -- cat /vault/secrets/database-creds
```

### Observability Stack

**Fluent Bit:**
```bash
# Check Fluent Bit DaemonSet
kubectl get daemonset -n observability fluent-bit
kubectl get pods -n observability -l app=fluent-bit

# View Fluent Bit logs (check for errors)
kubectl logs -n observability -l app=fluent-bit -f

# Check Fluent Bit configuration
kubectl get configmap -n observability fluent-bit-config -o yaml

# Verify Loki ingestion from Fluent Bit
kubectl logs -n observability loki-0 | grep "metrics" | tail -10
```

**Prometheus:**
```bash
# Prometheus targets
kubectl exec -it prometheus-0 -n prometheus -- \
  curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets'

# Alert rules
kubectl exec -it prometheus-0 -n prometheus -- \
  curl -s localhost:9090/api/v1/rules | jq '.data.groups[].rules'
```

**Loki & Logs:**
```bash
# Loki datasource status
kubectl exec -it loki-0 -n loki -- \
  curl -s 'http://localhost:3100/loki/api/v1/label'

# Query example: logs from past 1 hour
kubectl exec -it loki-0 -n loki -- \
  curl -s 'http://localhost:3100/loki/api/v1/query_range?query={namespace="default"}&start=<epoch-1h>&end=<epoch>'

# Check Kubernetes events in Loki
kubectl exec -it loki-0 -n loki -- \
  curl -s 'http://localhost:3100/loki/api/v1/query?query={event_type="Pod"}'
```

**Grafana:**
```bash
# Grafana dashboards
kubectl port-forward -n grafana svc/grafana 3000:80
# Access http://localhost:3000 (default admin/admin)

# Check datasources
kubectl exec -it <grafana-pod> -n grafana -- \
  curl -s http://localhost:3000/api/datasources | jq
```

### Security Policies

```bash
# Kyverno policies
kubectl get clusterpolicy

# Kyverno violations
kubectl logs -n kyverno deployment/kyverno

# Falco alerts
kubectl logs -n falco -f -l app=falco

# AppArmor profiles
kubectl debug node/<node> -it --image=ubuntu:latest -- \
  bash -c "cat /host/sys/kernel/security/apparmor/profiles | grep demo-app"
```

### GitOps (Fleet)

```bash
# Fleet clusters
kubectl get clusters.fleet.cattle.io -A

# Cluster status
kubectl get clusterregistration -A

# Git sync status
kubectl logs -n cattle-fleet-system deployment/gitjob
```

---

## Troubleshooting Common Issues

### Pod in CreateContainerError

**Possible Causes:**
1. Kyverno policy violation (image unsigned, scan failed)
2. AppArmor profile not found on node
3. SecurityContext requires privilege not granted

**Resolution:**
```bash
# Check pod events
kubectl describe pod <pod-name>

# View Kyverno logs
kubectl logs -n kyverno deployment/kyverno | grep <pod-name>

# Verify image signature
kubectl exec -it cosign-checker -- \
  cosign verify --key /cosign/key.pub <image>

# Check AppArmor profile on node
kubectl debug node/<node> -it --image=ubuntu:latest -- \
  bash -c "cat /host/sys/kernel/security/apparmor/profiles"
```

### Database Connection Timeout

**Possible Causes:**
1. DNS resolution failure (CoreDNS pod on overloaded node)
2. PostgreSQL pod not ready
3. Network policy blocking traffic

**Resolution:**
```bash
# Test DNS resolution
kubectl run -it dns-test --image=busybox -- \
  nslookup postgres.default.svc.cluster.local

# Check PostgreSQL pod
kubectl get pods -l app=postgres
kubectl logs postgres-0

# Verify network policy
kubectl get networkpolicy -A
```

### Image Pull Failed / ImagePullBackOff

**Possible Causes:**
1. Image doesn't exist in registry
2. Image tag mismatch (e.g., referencing unpublished tag)
3. Image registry credentials invalid

**Resolution:**
```bash
# Verify image exists
docker pull <image>:<tag>

# Check kustomization image tag
kubectl kustomize k8s/overlays/poc | grep image:

# Verify secret for private registry
kubectl get secret -n <namespace> | grep docker
```

### High Latency / Performance Degradation

**Possible Causes:**
1. Node overload (CPU, memory, disk I/O)
2. DNS resolution delays
3. Database connection pool exhausted
4. Longhorn replication lag

**Resolution:**
```bash
# Node resource usage
kubectl top nodes

# Pod resource usage
kubectl top pods -A

# Database connection count
kubectl exec -it postgres-0 -- \
  psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"

# Longhorn replication status
kubectl logs -n longhorn-system -l component=manager | grep replica
```

---

## Deployment Commands Reference

### Initial Setup

```bash
# Create clusters (assumes RKE2 installed)
rke2 server --token <token>

# Register with Rancher Fleet
kubectl apply -f fleet-cluster-registration.yaml

# Deploy observability stack
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install prometheus prometheus-community/kube-prometheus-stack

helm repo add grafana https://grafana.github.io/helm-charts
helm install grafana grafana/grafana

# Deploy Vault
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault hashicorp/vault

# Deploy Longhorn
helm repo add longhorn https://charts.longhorn.io
helm install longhorn longhorn/longhorn -n longhorn-system

# Deploy Kyverno
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno

# Deploy Falco
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm install falco falcosecurity/falco
```

### GitOps Sync

```bash
# Force Fleet sync
kubectl rollout restart -n cattle-fleet-system deployment/gitjob

# Check Git status
kubectl logs -n cattle-fleet-system deployment/gitjob -f

# Manual kustomize apply
kubectl apply -k k8s/overlays/poc
```

---

## Next Steps & Roadmap

1. **Document Folder-Level Implementation** — Create detailed guides in each component folder
2. **Runbooks** — Create incident response procedures (node failure, database failover, etc.)
3. **Backup & Disaster Recovery** — Document backup strategy and restore procedures
4. **Performance Baseline** — Establish metrics for normal operation
5. **Capacity Planning** — Scale thresholds and upgrade paths
