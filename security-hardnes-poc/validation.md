# Validation checklist

Use the downstream cluster context. Run the checks after applying the manifests and verify expected results.

## AppArmor

```bash
kubectl config current-context
kubectl get nodes -o wide
kubectl get pods -n default -l app=apparmor-test -o wide
kubectl exec -n default deployment/apparmor-test -- cat /proc/1/attr/current
kubectl exec -n default deployment/apparmor-test -- cat /etc/hostname
kubectl exec -n default deployment/apparmor-test -- touch /tmp/apparmor-test-file
```

Expected:
- context is the intended downstream cluster;
- the pod is Ready;
- process label includes `k8s-apparmor-deny-write (enforce)`;
- `cat /etc/hostname` succeeds;
- `touch` is denied by AppArmor.

## Falco event

```bash
kubectl get pods -n default -l app=apparmor-test -o wide
kubectl get pods -n falco -o wide
kubectl logs -n falco <falco-agent-pod-on-same-node> -c falco -f --since=1m \
  | grep --line-buffered 'Cat Executed Inside AppArmor Test Deployment'
```

From another terminal:

```bash
kubectl exec -n default deployment/apparmor-test -- cat /etc/hostname
```

Expected Falco event fields include:
- rule: `Cat Executed Inside AppArmor Test Deployment`
- `proc.cmdline=cat /etc/hostname`
- namespace `default`
- pod name prefixed `apparmor-test-`
- container `tester`

## Notification delivery

Detection and notification are different assertions. First ensure the Falco event is in the agent log. Then inspect Falcosidekick logs and Power Automate workflow run history.

```bash
kubectl logs -n falco <falcosidekick-pod> --since=5m
```

Do not mark Teams delivery as validated until the message appears in the Teams channel. Rotate any webhook URL that was ever pasted into chat or committed accidentally.
