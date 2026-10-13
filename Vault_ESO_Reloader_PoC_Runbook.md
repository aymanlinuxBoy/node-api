Upstream k3s + Downstream RKE2

*Build sequence, commands, verification, and troubleshooting*

  **Upstream cluster**              k3s management cluster
  --------------------------------- --------------------------------
  **Vault namespace**               vault
  **Downstream cluster**            RKE2 workload cluster
  **Application namespace**         devsecops-bg
  **Application workload**          Argo Rollout: node-api-poc-bg
  **Generated Kubernetes Secret**   node-api-poc-bg-db-credentials

+----------------------------------------------------------------------+
| **How to use this runbook**                                          |
|                                                                      |
| For initial setup, follow the sequence TOP → BOTTOM. For             |
| troubleshooting, start at the application and work BOTTOM → TOP.     |
| Sensitive values are shown only as placeholders such as              |
| \<ROLE\_ID\>, \<SECRET\_ID\>, and \<DB\_PASSWORD\>.                  |
+----------------------------------------------------------------------+

Contents
========

1\. Architecture and trust chain

2\. Confirmed current PoC objects

3\. Build sequence at a glance

4\. Upstream: install and configure Vault

5\. Upstream: create secret, policy, AppRole, Role ID, Secret ID

6\. Cross-cluster connectivity to Vault

7\. Downstream: install and configure External Secrets Operator

8\. Downstream: SecretStore and ExternalSecret

9\. Downstream: application and Reloader integration

10\. End-to-end test

11\. Verification command reference

12\. Troubleshooting: bottom → top

13\. Cleanup / known stale object

14\. Optional next step: dynamic PostgreSQL credentials

1. Architecture and trust chain
===============================

The upstream cluster hosts the source of truth and authentication
controls. The downstream cluster consumes the secret and restarts the
workload when the Kubernetes Secret changes.

UPSTREAM k3s CLUSTER\
┌────────────────────────────────────────────────────────────┐\
│ HashiCorp Vault │\
│ │\
│ KV v2 secret: secret/devsecops-bg/postgres │\
│ │ │\
│ ▼ │\
│ Policy: eso-postgres ── allows READ only │\
│ │ │\
│ ▼ │\
│ AppRole: eso-postgres │\
│ ├── role\_id │\
│ └── secret\_id │\
└───────────────────────┬────────────────────────────────────┘\
│ Vault API over reachable URL\
▼\
DOWNSTREAM RKE2 CLUSTER\
┌────────────────────────────────────────────────────────────┐\
│ namespace: devsecops-bg │\
│ │\
│ K8s Secret: vault-approle (stores secret\_id) │\
│ │ │\
│ SecretStore: vault-store │\
│ │ AppRole login (role\_id + secret\_id) │\
│ ▼ │\
│ ExternalSecret: postgres-credentials │\
│ │ refreshInterval: 1m │\
│ ▼ │\
│ K8s Secret: node-api-poc-bg-db-credentials │\
│ │ │\
│ ├── application reads DB\_USER / DB\_PASSWORD │\
│ └── Reloader detects change │\
│ │ │\
│ ▼ │\
│ Argo Rollout: node-api-poc-bg │\
│ │ │\
│ ▼ │\
│ restarted/new Pods │\
└────────────────────────────────────────────────────────────┘

+----------------------------------------------------------------------+
| **Three concepts to remember**                                       |
|                                                                      |
| Policy = WHAT may be accessed. AppRole = WHICH machine identity can  |
| authenticate. role\_id + secret\_id = credentials used to            |
| authenticate that AppRole and obtain a temporary Vault token.        |
+----------------------------------------------------------------------+

2. Confirmed current PoC objects
================================

These names reflect the active objects observed during the PoC. Values
that are environment-specific or sensitive remain placeholders in the
commands later in this document.

  **Location**   **Object type**         **Name / value**                 **State / role**
  -------------- ----------------------- -------------------------------- -----------------------------------------
  Upstream       Kubernetes              k3s cluster                      Management / Vault host
  Upstream       Namespace               vault                            Vault namespace
  Vault          KV v2 path              secret/devsecops-bg/postgres     DB\_USER / DB\_PASSWORD source
  Vault          Policy                  eso-postgres                     Read access to KV v2 data path
  Vault          Auth method             approle/                         Machine authentication
  Vault          AppRole                 eso-postgres                     Bound to eso-postgres policy
  Downstream     Namespace               devsecops-bg                     Application / ESO objects
  Downstream     SecretStore             vault-store                      Healthy Vault connection path
  Downstream     ExternalSecret          postgres-credentials             Healthy; refresh interval 1m
  Downstream     K8s Secret              node-api-poc-bg-db-credentials   Owned by postgres-credentials
  Downstream     Reloader namespace      reloader                         Reloader controller
  Downstream     Argo Rollout            node-api-poc-bg                  Consumes DB Secret
  Downstream     Legacy ExternalSecret   node-api-poc-bg-db-sync          SecretSyncedError; creationPolicy Merge

+----------------------------------------------------------------------+
| **Important**                                                        |
|                                                                      |
| The active ExternalSecret is postgres-credentials. The older         |
| node-api-poc-bg-db-sync object is not the healthy path and should    |
| not be used as the reference design.                                 |
+----------------------------------------------------------------------+

3. Build sequence at a glance
=============================

1\. Install / verify Vault on upstream.

2\. Enable / verify KV v2 at secret/.

3\. Create secret/devsecops-bg/postgres.

4\. Create Vault policy eso-postgres.

5\. Enable AppRole auth.

6\. Create AppRole eso-postgres and attach the policy.

7\. Retrieve role\_id and generate secret\_id.

8\. Confirm AppRole login manually.

9\. Expose a reachable Vault API endpoint to downstream.

10\. Install ESO on downstream.

11\. Store secret\_id in a downstream Kubernetes Secret.

12\. Create SecretStore vault-store with role\_id + secret\_id
reference.

13\. Create ExternalSecret postgres-credentials.

14\. Confirm generated Secret node-api-poc-bg-db-credentials.

15\. Install / configure Reloader with Argo Rollouts support.

16\. Annotate node-api-poc-bg and test a secret rotation end to end.

4. Upstream: install and configure Vault
========================================

+----------------------------------------------------------------------+
| **If Vault is already installed**                                    |
|                                                                      |
| Skip the Helm installation command and start from verification. The  |
| exact production storage/HA values depend on your design; this       |
| runbook focuses on the integration chain.                            |
+----------------------------------------------------------------------+

4.1. Point kubectl to the upstream cluster
------------------------------------------

export KUBECONFIG=\"/path/to/upstream-kubeconfig\"\
kubectl get nodes

4.2. Add the HashiCorp Helm repository
--------------------------------------

helm repo add hashicorp https://helm.releases.hashicorp.com\
helm repo update

4.3. Install Vault (example)
----------------------------

helm upgrade \--install vault hashicorp/vault \\\
-n vault \\\
\--create-namespace

**Verify:**

kubectl get pods -n vault\
kubectl get svc -n vault\
helm list -n vault

4.4. Access the Vault CLI
-------------------------

For administrative setup you can use the Vault CLI inside the Vault pod
or port-forward locally. Use whichever matches your installed server pod
name.

kubectl get pods -n vault\
kubectl exec -it vault-0 -n vault \-- sh

Inside the pod:

export VAULT\_ADDR=http://127.0.0.1:8200\
vault status\
vault login \<ADMIN\_OR\_ROOT\_TOKEN\>

5. Upstream: create secret, policy, AppRole, Role ID, Secret ID
===============================================================

5.1. Verify KV v2 at secret/
----------------------------

vault secrets list -detailed

If secret/ does not exist as KV v2:

vault secrets enable -path=secret kv-v2

5.2. Create the PostgreSQL secret
---------------------------------

vault kv put secret/devsecops-bg/postgres \\\
DB\_USER=postgres \\\
DB\_PASSWORD=\'\<DB\_PASSWORD\>\'\
\
vault kv get secret/devsecops-bg/postgres

+----------------------------------------------------------------------+
| **KV v2 path rule**                                                  |
|                                                                      |
| CLI path: secret/devsecops-bg/postgres. Policy API data path:        |
| secret/data/devsecops-bg/postgres. The /data/ segment is required in |
| the policy because the engine is KV v2.                              |
+----------------------------------------------------------------------+

5.3. Create the least-privilege policy
--------------------------------------

vault policy write eso-postgres - \<\<\'EOF\'\
path \"secret/data/devsecops-bg/postgres\" {\
capabilities = \[\"read\"\]\
}\
EOF

**Verify:**

vault policy list\
vault policy read eso-postgres

5.4. Enable AppRole authentication
----------------------------------

vault auth list\
vault auth enable approle\
vault auth list

+----------------------------------------------------------------------+
| **If already enabled**                                               |
|                                                                      |
| vault auth enable approle will fail if approle/ already exists. In   |
| that case, do not recreate it; continue to the role.                 |
+----------------------------------------------------------------------+

5.5. Create AppRole eso-postgres and attach the policy
------------------------------------------------------

vault write auth/approle/role/eso-postgres \\\
token\_policies=\"eso-postgres\" \\\
token\_ttl=\"1h\" \\\
token\_max\_ttl=\"4h\"

**Verify:**

vault list auth/approle/role\
vault read auth/approle/role/eso-postgres

5.6. Read the role\_id
----------------------

vault read auth/approle/role/eso-postgres/role-id\
\
\# Only the value:\
vault read -field=role\_id auth/approle/role/eso-postgres/role-id

5.7. Generate the secret\_id
----------------------------

vault write -f auth/approle/role/eso-postgres/secret-id

+----------------------------------------------------------------------+
| **Secret handling**                                                  |
|                                                                      |
| Treat secret\_id as sensitive. Do not commit it to Git. role\_id is  |
| an identifier; secret\_id is the sensitive proof used together with  |
| role\_id for AppRole login.                                          |
+----------------------------------------------------------------------+

5.8. Test AppRole login manually before configuring ESO
-------------------------------------------------------

vault write auth/approle/login \\\
role\_id=\"\<ROLE\_ID\>\" \\\
secret\_id=\"\<SECRET\_ID\>\"

The response should contain auth.client\_token and show the eso-postgres
policy. To test the token without replacing your admin shell
permanently:

APPROLE\_TOKEN=\$(vault write -field=token auth/approle/login \\\
role\_id=\"\<ROLE\_ID\>\" \\\
secret\_id=\"\<SECRET\_ID\>\")\
\
VAULT\_TOKEN=\"\$APPROLE\_TOKEN\" vault kv get
secret/devsecops-bg/postgres

6. Cross-cluster connectivity to Vault
======================================

A Kubernetes Service DNS name such as vault.vault.svc.cluster.local is
only directly resolvable inside the upstream cluster. The downstream ESO
therefore needs a network-reachable Vault API URL.

**Inspect Vault services and identify a reachable endpoint:**

kubectl get svc -n vault -o wide

\# Example structure only:\
VAULT\_SERVER=\"http://\<UPSTREAM\_NODE\_IP\>:\<VAULT\_NODEPORT\>\"

**From the downstream network, test Vault health:**

curl -sS \"\$VAULT\_SERVER/v1/sys/health\"

+----------------------------------------------------------------------+
| **Protocol matters**                                                 |
|                                                                      |
| If Vault is exposed with HTTP, configure ESO with http://. If TLS is |
| configured, use https:// and provide the proper CA trust. An HTTPS   |
| client pointed at an HTTP Vault endpoint will fail.                  |
+----------------------------------------------------------------------+

7. Downstream: install and configure External Secrets Operator
==============================================================

7.1. Point kubectl to downstream RKE2
-------------------------------------

export KUBECONFIG=\"/Users/ayman.aly/rke2-downstream.yaml\"\
kubectl get nodes

7.2. Install ESO with Helm
--------------------------

helm repo add external-secrets https://charts.external-secrets.io\
helm repo update\
\
helm upgrade \--install external-secrets \\\
external-secrets/external-secrets \\\
-n external-secrets \\\
\--create-namespace

**Verify:**

kubectl get pods -n external-secrets\
kubectl get crd \| grep external-secrets

7.3. Store the AppRole secret\_id in Kubernetes
-----------------------------------------------

kubectl create secret generic vault-approle \\\
-n devsecops-bg \\\
\--from-literal=secret-id=\'\<SECRET\_ID\>\'

**Verify metadata only:**

kubectl get secret vault-approle -n devsecops-bg

8. Downstream: SecretStore and ExternalSecret
=============================================

8.1. Create SecretStore vault-store
-----------------------------------

cat \> vault-secretstore.yaml \<\<\'EOF\'\
apiVersion: external-secrets.io/v1\
kind: SecretStore\
metadata:\
name: vault-store\
namespace: devsecops-bg\
spec:\
provider:\
vault:\
server: \"http://\<UPSTREAM\_NODE\_IP\>:\<VAULT\_NODEPORT\>\"\
path: \"secret\"\
version: \"v2\"\
auth:\
appRole:\
path: \"approle\"\
roleId: \"\<ROLE\_ID\>\"\
secretRef:\
name: vault-approle\
key: secret-id\
EOF\
\
kubectl apply -f vault-secretstore.yaml

**Verify:**

kubectl get secretstore vault-store -n devsecops-bg\
kubectl describe secretstore vault-store -n devsecops-bg

Expected condition: Ready=True.

8.2. Create ExternalSecret postgres-credentials
-----------------------------------------------

cat \> postgres-externalsecret.yaml \<\<\'EOF\'\
apiVersion: external-secrets.io/v1\
kind: ExternalSecret\
metadata:\
name: postgres-credentials\
namespace: devsecops-bg\
spec:\
refreshInterval: 1m\
secretStoreRef:\
name: vault-store\
kind: SecretStore\
target:\
name: node-api-poc-bg-db-credentials\
creationPolicy: Owner\
data:\
- secretKey: DB\_USER\
remoteRef:\
key: devsecops-bg/postgres\
property: DB\_USER\
- secretKey: DB\_PASSWORD\
remoteRef:\
key: devsecops-bg/postgres\
property: DB\_PASSWORD\
EOF\
\
kubectl apply -f postgres-externalsecret.yaml

**Verify sync:**

kubectl get externalsecret -n devsecops-bg\
\
kubectl get externalsecret postgres-credentials \\\
-n devsecops-bg\
\
kubectl describe externalsecret postgres-credentials \\\
-n devsecops-bg

8.3. Verify generated Kubernetes Secret
---------------------------------------

kubectl get secret node-api-poc-bg-db-credentials -n devsecops-bg\
\
kubectl get secret node-api-poc-bg-db-credentials -n devsecops-bg \\\
-o jsonpath=\'{.metadata.ownerReferences\[\*\].name}{\"\\n\"}\'\
\
kubectl get secret node-api-poc-bg-db-credentials -n devsecops-bg \\\
-o jsonpath=\'resourceVersion={.metadata.resourceVersion}{\"\\n\"}\'

Expected owner: postgres-credentials. Avoid decoding or printing
DB\_PASSWORD during routine verification.

9. Downstream: application and Reloader integration
===================================================

9.1. Reference the generated Secret from the Argo Rollout
---------------------------------------------------------

env:\
- name: DB\_USER\
valueFrom:\
secretKeyRef:\
name: node-api-poc-bg-db-credentials\
key: DB\_USER\
- name: DB\_PASSWORD\
valueFrom:\
secretKeyRef:\
name: node-api-poc-bg-db-credentials\
key: DB\_PASSWORD

Your current Rollout also mounts the same Secret as a volume. Reloader
can detect referenced Secrets when auto mode is enabled.

9.2. Install / upgrade Reloader with Argo Rollouts support
----------------------------------------------------------

helm repo add stakater https://stakater.github.io/stakater-charts\
helm repo update\
\
helm upgrade \--install reloader stakater/reloader \\\
-n reloader \\\
\--create-namespace \\\
\--reuse-values \\\
\--set reloader.isArgoRollouts=true \\\
\--set reloader.autoReloadAll=false

+----------------------------------------------------------------------+
| **First-time install note**                                          |
|                                                                      |
| \--reuse-values is useful for an existing release. If this is a      |
| brand-new installation and Helm rejects \--reuse-values, omit that   |
| flag.                                                                |
+----------------------------------------------------------------------+

**Verify running arguments:**

kubectl get deployment reloader-reloader -n reloader \\\
-o jsonpath=\'{.spec.template.spec.containers\[0\].args}{\"\\n\"}\'

In the current chart, the rendered Argo Rollouts flag may appear as
\--is-Argo-Rollouts=true.

9.3. Annotate the Argo Rollout
------------------------------

metadata:\
annotations:\
reloader.stakater.com/auto: \"true\"\
reloader.stakater.com/rollout-strategy: \"restart\"

-   reloader.stakater.com/auto: \"true\" tells Reloader to watch
    referenced Secrets/ConfigMaps for this workload.

-   reloader.stakater.com/rollout-strategy: \"restart\" tells Reloader
    to restart Pods without changing the Rollout pod template, which is
    useful for GitOps-managed workloads.

-   autoReloadAll=false remains fine because the Rollout explicitly opts
    in with the annotation.

**Verify annotations:**

kubectl get rollout node-api-poc-bg -n devsecops-bg \\\
-o jsonpath=\'{.metadata.annotations}{\"\\n\"}\'

10. End-to-end test
===================

Use this procedure to prove the entire chain without exposing the secret
value.

10.1. Record current state on downstream
----------------------------------------

kubectl get secret node-api-poc-bg-db-credentials -n devsecops-bg \\\
-o jsonpath=\'resourceVersion={.metadata.resourceVersion}{\"\\n\"}\'\
\
kubectl get pods -n devsecops-bg -l app=node-api-poc-bg -o wide

10.2. Update the Vault source secret on upstream
------------------------------------------------

+----------------------------------------------------------------------+
| **Avoid accidentally deleting a key**                                |
|                                                                      |
| vault kv put replaces the data at that KV version. Include both      |
| DB\_USER and DB\_PASSWORD when rotating only the password.           |
+----------------------------------------------------------------------+

vault kv put secret/devsecops-bg/postgres \\\
DB\_USER=postgres \\\
DB\_PASSWORD=\'\<NEW\_DB\_PASSWORD\>\'

10.3. Force ESO sync (optional; otherwise wait for 1m refresh)
--------------------------------------------------------------

kubectl annotate externalsecret postgres-credentials \\\
-n devsecops-bg \\\
force-sync=\$(date +%s) \\\
\--overwrite

10.4. Confirm ESO changed the Kubernetes Secret
-----------------------------------------------

kubectl get externalsecret postgres-credentials -n devsecops-bg\
\
kubectl get secret node-api-poc-bg-db-credentials -n devsecops-bg \\\
-o jsonpath=\'resourceVersion={.metadata.resourceVersion}{\"\\n\"}\'

The resourceVersion should change if ESO writes new data.

10.5. Observe Reloader and Pod replacement
------------------------------------------

\# Terminal 1\
kubectl logs -n reloader deployment/reloader-reloader -f\
\
\# Terminal 2\
kubectl get pods -n devsecops-bg -w

**Filter Reloader logs if needed:**

kubectl logs -n reloader deployment/reloader-reloader \--since=15m \|
\\\
grep -Ei
\'node-api-poc-bg\|node-api-poc-bg-db-credentials\|reload\|secret\|rollout\'

11. Verification command reference
==================================

  **Layer**            **Command**                                                            **Healthy signal**
  -------------------- ---------------------------------------------------------------------- -------------------------------------------
  Vault status         vault status                                                           Initialized and unsealed
  KV engine            vault secrets list -detailed                                           secret/ is KV v2
  Policy               vault policy read eso-postgres                                         read on secret/data/devsecops-bg/postgres
  AppRole              vault read auth/approle/role/eso-postgres                              token\_policies includes eso-postgres
  Role ID              vault read -field=role\_id auth/approle/role/eso-postgres/role-id      returns an ID
  Vault reachability   curl -sS \<VAULT\_SERVER\>/v1/sys/health                               Vault JSON health response
  SecretStore          kubectl get secretstore vault-store -n devsecops-bg                    Ready=True
  ExternalSecret       kubectl get externalsecret postgres-credentials -n devsecops-bg        SecretSynced / True
  Generated Secret     kubectl get secret node-api-poc-bg-db-credentials -n devsecops-bg      exists; owner postgres-credentials
  Reloader             kubectl get pods -n reloader                                           Running
  Reloader args        kubectl get deploy reloader-reloader -n reloader -o jsonpath=\...      Argo Rollouts support flag present
  Rollout annotation   kubectl get rollout node-api-poc-bg -n devsecops-bg -o jsonpath=\...   reloader.stakater.com/auto=true

12. Troubleshooting: bottom → top
=================================

For a failure such as "Vault changed but Pod did not restart," work
upward from the Pod rather than rebuilding everything.

Pod did not restart\
↑\
Did Reloader see the Secret update?\
↑\
Did Kubernetes Secret resourceVersion change?\
↑\
Did ExternalSecret postgres-credentials sync?\
↑\
Is SecretStore vault-store Ready?\
↑\
Can downstream reach Vault?\
↑\
Can AppRole authenticate with role\_id + secret\_id?\
↑\
Does policy eso-postgres allow the required path?\
↑\
Does secret/devsecops-bg/postgres exist?

12.1. Pod / Rollout
-------------------

kubectl get rollout node-api-poc-bg -n devsecops-bg\
kubectl get pods -n devsecops-bg -l app=node-api-poc-bg\
kubectl get rollout node-api-poc-bg -n devsecops-bg -o
jsonpath=\'{.metadata.annotations}{\"\\n\"}\'

12.2. Reloader
--------------

kubectl get pods -n reloader\
kubectl logs -n reloader deployment/reloader-reloader \--since=30m\
kubectl get deployment reloader-reloader -n reloader \\\
-o jsonpath=\'{.spec.template.spec.containers\[0\].args}{\"\\n\"}\'

12.3. Generated Secret
----------------------

kubectl get secret node-api-poc-bg-db-credentials -n devsecops-bg \\\
-o jsonpath=\'resourceVersion={.metadata.resourceVersion}{\"\\n\"}\'\
\
kubectl get secret node-api-poc-bg-db-credentials -n devsecops-bg \\\
-o jsonpath=\'{.metadata.ownerReferences\[\*\].name}{\"\\n\"}\'

12.4. ESO
---------

kubectl get externalsecret -n devsecops-bg\
\
kubectl get externalsecret postgres-credentials \\\
-n devsecops-bg\
\
kubectl describe externalsecret postgres-credentials \\\
-n devsecops-bg

12.5. Vault auth and policy
---------------------------

vault policy read eso-postgres\
vault read auth/approle/role/eso-postgres\
vault read auth/approle/role/eso-postgres/role-id\
vault kv get secret/devsecops-bg/postgres

13. Cleanup / known stale object
================================

The PoC currently contains an older ExternalSecret named
node-api-poc-bg-db-sync. It targets the same Kubernetes Secret but
reports SecretSyncedError and uses creationPolicy: Merge. The active
healthy owner is postgres-credentials with creationPolicy: Owner.

+----------------------------------------------------------------------+
| **GitOps warning**                                                   |
|                                                                      |
| If this object is managed by Argo CD/Kustomize, remove it from Git   |
| first. Deleting it manually without changing Git may cause Argo CD   |
| to recreate it.                                                      |
+----------------------------------------------------------------------+

\# Inspect before removal\
kubectl get externalsecret node-api-poc-bg-db-sync -n devsecops-bg -o
yaml\
\
\# Remove only after deleting it from the Git source of truth\
kubectl delete externalsecret node-api-poc-bg-db-sync -n devsecops-bg

14. Optional next step: dynamic PostgreSQL credentials
======================================================

The current proven path uses KV v2 static values. Dynamic database
credentials are a separate Vault Database Secrets Engine design. Do not
mix the two concepts while troubleshooting the current flow.

Current proven flow (static KV)\
Vault KV v2 → ESO → Kubernetes Secret → Reloader → Pod\
\
Future dynamic flow\
Vault Database Secrets Engine → short-lived DB user/password\
↓\
ESO\
↓\
Kubernetes Secret\
↓\
Reloader\
↓\
Pod

-   Configure Vault database/ engine and PostgreSQL connection.

-   Create a Vault database role with creation/revocation statements.

-   Set desired TTL / max TTL.

-   Point ESO to the dynamic secret path.

-   Choose refresh timing so credentials are refreshed before lease
    expiry.

-   Ensure Reloader restarts the workload when the Kubernetes Secret
    changes.

Operational summary
===================

SETUP: TOP → BOTTOM\
Vault → KV secret → Policy → AppRole → role\_id + secret\_id\
→ reachable Vault endpoint → ESO → SecretStore → ExternalSecret\
→ Kubernetes Secret → Reloader → Argo Rollout → Pods\
\
TROUBLESHOOT: BOTTOM → TOP\
Pods → Reloader → K8s Secret → ExternalSecret → SecretStore\
→ Vault network → AppRole → Policy → Vault secret

+----------------------------------------------------------------------+
| **Core rule**                                                        |
|                                                                      |
| Vault is the source of truth. ESO copies/refreshes the value into    |
| Kubernetes. Reloader reacts to the Kubernetes Secret update. The     |
| application never needs a Vault root token.                          |
+----------------------------------------------------------------------+
