# Security Hardening PoC: AppArmor + Falco

This folder documents a hands-on proof of concept on the downstream three-node RKE2 cluster. It is intentionally separate from the application's normal Kustomize deployment. Do not apply these lab manifests to production without reviewing the node prerequisites, privileges, and profiles.

## Contents

- [Overview and architecture](#overview-and-architecture)
- [Prerequisites](#prerequisites)
- [1. Deploy the simple test workload](#1-deploy-the-simple-test-workload)
- [2. Install and verify AppArmor prerequisites](#2-install-and-verify-apparmor-prerequisites)
- [3. Create and load the AppArmor profile](#3-create-and-load-the-apparmor-profile)
- [4. Attach AppArmor to the Deployment](#4-attach-apparmor-to-the-deployment)
- [5. Validate AppArmor enforcement](#5-validate-apparmor-enforcement)
- [6. Install Falco](#6-install-falco)
- [7. Falco custom rule](#7-falco-custom-rule)
- [8. Validate Falco detection from the terminal](#8-validate-falco-detection-from-the-terminal)
- [9. FalcoSidekick and notifications](#9-falcosidekick-and-notifications)
- [Troubleshooting notes](#troubleshooting-notes)
- [Cleanup](#cleanup)
- [References](#references)

## Overview and architecture

The lab demonstrates two complementary controls:

1. **AppArmor** restricts what a process inside a container may do. The custom profile below denies file writes while allowing normal reads.
2. **Falco** observes kernel/system events and generates an event when `cat` is executed in the specifically labelled test pod.
3. **Falcosidekick** can forward Falco events to configured outputs. Teams delivery is a separate integration step and must be tested independently.

Expected flow:

```text
kubectl exec ... cat /etc/hostname
             |
             v
       Falco syscall event
             |
             v
 Custom rule matches pod metadata:
 namespace=default, app=apparmor-test
             |
             v
        Falcosidekick
             |
             v
 Power Automate workflow -> Teams channel (optional)
```

This rule detects process execution; it does **not** indicate that AppArmor denied the command. The test command is a read and is expected to succeed under the profile used here.

## Prerequisites

- A working `kubectl` context for the downstream RKE2 cluster.
- SSH/root or sudo access to each downstream node.
- AppArmor enabled in the host kernel and the `apparmor_parser` utility installed.
- Helm 3 and connectivity to the Falco chart repository when installing/upgrading Falco.
- Network/DNS access from Falco artifact init containers to the Falco artifact repository, unless artifact installation is deliberately disabled for a constrained lab.
- If Teams notifications are required: a Power Automate workflow that accepts the payload shape sent by the selected Falcosidekick webhook integration, plus a Kubernetes Secret in namespace `falco`. Do not commit webhook URLs or credentials.

The known downstream nodes during this PoC were:

| Node | Address seen by Kubernetes |
|---|---|
| `vmi3565261` | `176.57.189.45` |
| `vmi3565262` | `94.250.202.136` |
| `vmi3565263` | `185.197.249.98` |

Confirm current node addresses before relying on this table:

```bash
kubectl config current-context
kubectl get nodes -o wide
```

## 1. Deploy the simple test workload

The lab uses a one-replica BusyBox Deployment in the `default` namespace, labelled `app=apparmor-test`. It deliberately runs an idle shell so that commands can be executed with `kubectl exec`.

Apply the manifest in [apparmor-test-deployment.yaml](apparmor-test-deployment.yaml):

```bash
kubectl apply -f security-hardnes-poc/apparmor-test-deployment.yaml
kubectl rollout status deployment/apparmor-test -n default --timeout=120s
kubectl get pods -n default -l app=apparmor-test -o wide
```

The pod should be Ready. Note which node it is scheduled on. The manifest includes the AppArmor Localhost profile reference, so the profile must already be installed on any node to which the pod may be scheduled.

## 2. Install and verify AppArmor prerequisites

Run on **each downstream node** (not just the Rancher management cluster):

```bash
cat /sys/module/apparmor/parameters/enabled
command -v apparmor_parser
sudo aa-status
```

Expected: the AppArmor enabled file reports `Y`, `apparmor_parser` is available, and `aa-status` lists AppArmor profiles. If not, install/enable AppArmor using the distribution's supported procedures and reboot only if required by the host OS/kernel configuration. Do not proceed until all candidate Kubernetes nodes support AppArmor.

## 3. Create and load the AppArmor profile

On **each downstream node**, save the profile to a file so it can be reloaded at boot and to avoid parsing the profile through stdin (which can emit a cache warning):

```bash
sudo tee /etc/apparmor.d/k8s-apparmor-deny-write >/dev/null <<'EOF'
#include <tunables/global>

profile k8s-apparmor-deny-write flags=(attach_disconnected) {
    #include <abstractions/base>

    file,

    deny /** w,
}
EOF

sudo apparmor_parser -r -W /etc/apparmor.d/k8s-apparmor-deny-write
sudo grep 'k8s-apparmor-deny-write' /sys/kernel/security/apparmor/profiles
```

Expected profile status:

```text
k8s-apparmor-deny-write (enforce)
```

The profile is intentionally broad for demonstration. It denies file writes within the confined process, so some ordinary applications would fail if run under it. Do not use this profile as a production application profile without tailoring and testing it.

## 4. Attach AppArmor to the Deployment

The pod template's container security context selects a node-local profile by name:

```yaml
securityContext:
  allowPrivilegeEscalation: false
  appArmorProfile:
    type: Localhost
    localhostProfile: k8s-apparmor-deny-write
```

The full manifest is [apparmor-test-deployment.yaml](apparmor-test-deployment.yaml). It uses `appArmorProfile`, the current Kubernetes pod security context field. A Localhost profile must be present on the node before the container can start.

Apply/restart and verify:

```bash
kubectl apply -f security-hardnes-poc/apparmor-test-deployment.yaml
kubectl rollout status deployment/apparmor-test -n default --timeout=120s
kubectl get pods -n default -l app=apparmor-test -o wide
kubectl describe pod -n default -l app=apparmor-test
```

## 5. Validate AppArmor enforcement

First confirm the process is confined:

```bash
kubectl exec -n default deployment/apparmor-test -- cat /proc/1/attr/current
```

Expected output includes:

```text
k8s-apparmor-deny-write (enforce)
```

Then verify a read is allowed:

```bash
kubectl exec -n default deployment/apparmor-test -- cat /etc/hostname
```

Finally test a write. This should fail with permission denied:

```bash
kubectl exec -n default deployment/apparmor-test -- touch /tmp/apparmor-test-file
```

Because the profile denies writes broadly, even writing under `/tmp` is expected to be blocked. If the command succeeds, verify the pod is using the intended profile and check host AppArmor logs/profile state before concluding that enforcement is working.

## 6. Install Falco

Add and update the Helm chart repository on the machine where Helm is run:

```bash
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm search repo falcosecurity/falco
```

Create namespace if needed:

```bash
kubectl create namespace falco --dry-run=client -o yaml | kubectl apply -f -
```

The chart can run Falco as a DaemonSet so an agent runs on each node. Install/upgrade with the lab configuration:

```bash
helm upgrade --install falco falcosecurity/falco \
  --namespace falco \
  -f security-hardnes-poc/falco-values.yaml \
  --set falcoctl.artifact.install.enabled=false \
  --set falcoctl.artifact.follow.enabled=false
```

**Artifact note:** In this PoC, Falco's `falcoctl-artifact-install` init container previously failed because the cluster could not resolve `falcosecurity.github.io`. The two `--set` flags bypassed this failing external artifact download so the locally supplied custom rule could be tested. This is a workaround, not a DNS fix. It also means the standard external rules artifact is not being installed/followed; restore artifact installation after fixing cluster DNS and validating the desired artifact configuration.

Check the DaemonSet and agents:

```bash
helm list -n falco --all
kubectl get pods -n falco -o wide
kubectl get daemonset -n falco
```

Expected: a Falco agent pod running on each eligible downstream node. Falcosidekick pods may also run when enabled.

## 7. Falco custom rule

The full Helm values file is [falco-values.yaml](falco-values.yaml). It defines a rule in `customRules` that matches execution events when:

- event type is `execve` or `execveat`;
- the event is in a container;
- process name is `cat`;
- Kubernetes namespace is `default`;
- the pod label `app` equals `apparmor-test`.

The label field uses bracket syntax:

```text
k8s.pod.label[app] = "apparmor-test"
```

Falco's parser rejects dotted syntax like `k8s.pod.label.app`; `k8s.pod.label` requires a label-key argument.

After upgrade, inspect logs for rule-load errors:

```bash
kubectl logs -n falco <falco-pod-name> -c falco --since=10m \
  | grep -Ei 'Cat Executed|LOAD_ERR|invalid|error'
```

If rule compilation fails, fix the rule before testing notifications.

## 8. Validate Falco detection from the terminal

Find the test pod and note its node:

```bash
kubectl get pods -n default -l app=apparmor-test -o wide
kubectl get pods -n falco -o wide
```

Start a log watch on the Falco agent on the same node as the test workload:

```bash
kubectl logs -n falco <falco-agent-pod-on-same-node> -c falco -f --since=1m \
  | grep --line-buffered 'Cat Executed Inside AppArmor Test Deployment'
```

In a second terminal, execute `cat` inside the workload:

```bash
kubectl exec -n default deployment/apparmor-test -- cat /etc/hostname
```

During the PoC, Falco logged an event with the rule name, `proc.cmdline=cat /etc/hostname`, pod name `apparmor-test-...`, namespace `default`, container `tester`, and image `docker.io/library/busybox:1.36`. This confirms local detection.

If no event appears:

1. Confirm you are watching the Falco pod on the same node.
2. Check rule-load errors with the command above.
3. Confirm the current pod has label `app=apparmor-test` and namespace `default`.
4. Trigger a fresh `cat` after starting the log stream.

## 9. Falcosidekick and notifications

Falcosidekick is the forwarding component. It is distinct from Falco's detection engine and from the separate Prometheus Alertmanager used elsewhere in the monitoring stack.

For webhook forwarding, store the workflow URL in a Secret in namespace `falco`; never commit the actual URL:

```bash
kubectl create secret generic falco-teams-webhook \
  -n falco \
  --from-literal=url='<ROTATED-POWER-AUTOMATE-WORKFLOW-URL>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

The placeholder above is not a real URL. Prefer prompting for secret input or a secret-management system in production because inline literal values can remain in shell history. The webhook URL was exposed during the original lab discussion and should be rotated before reuse.

The Helm configuration refers to the Secret via `WEBHOOK_ADDRESS`. Verify the deployed values/env before assuming the hook is loaded:

```bash
kubectl get deploy -n falco -o wide
kubectl get deployment -n falco falco-falcosidekick -o yaml \
  | grep -n -A4 -B2 'WEBHOOK_ADDRESS'
kubectl logs -n falco -l app.kubernetes.io/name=falcosidekick \
  --all-containers=true --prefix=true --since=5m
```

The successful Falco rule event is confirmed. **Teams notification delivery must be validated separately** by checking Falcosidekick logs and Power Automate run history. Confirm the Workflow accepts the payload format delivered by the selected Falcosidekick webhook output; a generic HTTP webhook and a Teams-specific incoming webhook may require different payload formats.

For simple terminal-level testing without the UI:

```bash
kubectl logs -n falco <falco-agent-pod> -c falco -f --since=1m
kubectl logs -n falco <falcosidekick-pod> -f --since=1m
```

Then run `cat /etc/hostname` in the test Deployment and correlate Falco's detected event with Falcosidekick's forwarding logs and the Power Automate run history.

## Troubleshooting notes

### AppArmor

- `/sys/module/apparmor/parameters/enabled` should report `Y`.
- The profile must be loaded on every node where the pod can be scheduled.
- The current pod process should report `k8s-apparmor-deny-write (enforce)` in `/proc/1/attr/current`.
- `cat` should work; `touch` should be denied.

### Falco

- An `Init:Error` in `falcoctl-artifact-install` was caused by a DNS timeout to `falcosecurity.github.io`, not by the custom rule.
- A rule parse error occurred when the label was written as `k8s.pod.label.app`. The correct field usage is `k8s.pod.label[app]`.
- If Falco logs the event but Teams doesn't receive a message, troubleshooting should continue in Falcosidekick/webhook/Power Automate; do not rewrite the Falco condition before validating event forwarding.

### Cluster DNS and networking

This cluster also showed intermittent DNS timeouts to `10.43.0.10:53` and cross-node connectivity issues. These affected services such as Loki, Redis and Rancher Webhook. If Falco artifact downloads, Redis connections, or notification requests time out, diagnose service DNS and cross-node connectivity independently; don't interpret every timeout as a Falco rule issue.

### Falcosidekick UI

The optional UI is not required to validate Falco. Use `kubectl logs` as above. During this PoC, a UI replica stalled in the `wait-redis` init container, while another UI replica ran; Redis and its Service endpoint existed, but a Redis test from another node timed out. The UI problem was not the reason Falco's local rule event failed—the rule had already been verified in the agent logs.

## Cleanup

Delete only the lab workload and temporary diagnostics when no longer needed:

```bash
kubectl delete -f security-hardnes-poc/apparmor-test-deployment.yaml
kubectl delete pod redis-check redis-check-node2 -n falco --ignore-not-found
kubectl delete pod dns-check-node2 -n falco --ignore-not-found
```

Do not delete the entire `falco` namespace if it also contains the Falco agents, Falcosidekick, Redis, the UI, or other resources you want to keep.

To remove the host-local profile, first remove workloads referencing it. Then, on each node:

```bash
sudo apparmor_parser -R /etc/apparmor.d/k8s-apparmor-deny-write
sudo rm -f /etc/apparmor.d/k8s-apparmor-deny-write
```

## References

- Kubernetes AppArmor security context: https://kubernetes.io/docs/tutorials/security/apparmor/
- Falco documentation: https://falco.org/docs/
- Falco Helm chart: https://github.com/falcosecurity/charts
- Falcosidekick: https://github.com/falcosecurity/falcosidekick
