# Kyverno Image Policy Implementation and Operations Runbook

**Repository:** [aymanlinuxBoy/node-api](https://github.com/aymanlinuxBoy/node-api)  
**Policy directory:** `k8s/policies/`  
**Argo CD Application:** `node-api-poc-policies`  
**Target cluster:** `downstream`  
**Kyverno namespace:** `kyverno`  
**Document status:** reflects the implementation and test evidence available on 2026-10-13.

## 1. Purpose and scope

Kyverno is used to validate image references for Pods in three application namespaces:

- `devsecops`
- `devsecops-bg`
- `devsecops-canary`

Two cluster-scoped Kyverno CEL policy resources are managed in Git and reconciled by Argo CD:

1. **`node-api-poc-restrict-image-repository`** — restricts which container image repositories may be used in the scoped namespaces.
2. **`node-api-poc-verify-signature`** — verifies the Node API image signature against the expected keyless identity from the GitHub Actions workflow.

The policies currently use **Audit** and **`failurePolicy: Ignore`**. They are not currently intended to reject Pod admission. A policy report result of `fail` in this stage is a recorded violation, not proof that Kubernetes denied the Pod.

## 2. Implementation structure

The relevant repository layout is:

```text
node-api/
├── argocd/
│   └── application-policies.yaml
└── k8s/
    └── policies/
        ├── kustomization.yaml
        ├── image-validating-policy.yaml
        └── restrict-image-repository.yaml
```

### What each file does

| File | Responsibility |
|---|---|
| `k8s/policies/image-validating-policy.yaml` | Defines the `ImageValidatingPolicy` for Cosign keyless signature verification. |
| `k8s/policies/restrict-image-repository.yaml` | Defines the `ValidatingPolicy` that checks container, init-container, and ephemeral-container image repositories. |
| `k8s/policies/kustomization.yaml` | Bundles both policy manifests for Kustomize and Argo CD. |
| `argocd/application-policies.yaml` | Defines the Argo CD Application that tracks the Git repository's `main` branch and `k8s/policies` path. |

Kyverno was observed running as version `v1.19.1` in the downstream cluster's `kyverno` namespace. This document records policy/GitOps management; the exact original Kyverno installation command is not represented by these policy manifests.

## 3. Policy definitions

### 3.1 Repository restriction

Resource: `ValidatingPolicy/policies.kyverno.io`  
Name: `node-api-poc-restrict-image-repository`

It evaluates Pod `CREATE` and `UPDATE` operations, including the Pod ephemeral-container subresource, in the three namespaces listed above. It checks regular containers, init containers, and ephemeral containers.

The intended repository allow-list is:

| Namespace | Approved repositories |
|---|---|
| `devsecops` | `aimocont2020/node-api-poc`, `aimocont2020/devsecops-demo` |
| `devsecops-bg` | `aimocont2020/node-api-poc`, `aimocont2020/devsecops-demo` |
| `devsecops-canary` | `aimocont2020/node-api-poc` |

Both unqualified Docker Hub references and references explicitly prefixed with `docker.io/` are accepted. Tags and digests are allowed, but the repository path must match the namespace's allow-list.

**Why the allow-list is per namespace:** the shared `devsecops` and `devsecops-bg` namespaces run both the Node API and the DevSecOps demo application. Allowing only the Node API repository incorrectly reports the demo application as a violation. The canary namespace remains restricted to the Node API repository.

The branch associated with this runbook corrects that allow-list. Confirm the PR is merged and Argo CD has synced before expecting these exact repository-policy results in the cluster.

### 3.2 Image signature validation

Resource: `ImageValidatingPolicy/policies.kyverno.io`  
Name: `node-api-poc-verify-signature`

The policy:

- Applies to Pods being created or updated in `devsecops`, `devsecops-bg`, and `devsecops-canary`.
- Matches the `aimocont2020/node-api-poc` image repository, with or without the explicit `docker.io/` prefix.
- Uses Cosign keyless verification.
- Trusts this OIDC issuer: `https://token.actions.githubusercontent.com`.
- Trusts this workflow identity: `https://github.com/aymanlinuxBoy/node-api/.github/workflows/ci-security.yml@refs/heads/main`.
- Uses the Sigstore Rekor transparency log at `https://rekor.sigstore.dev`.
- Sets `required: true`, `verifyDigest: true`, and `mutateDigest: true`.
- Has background evaluation disabled; do not assume this policy automatically revalidates all existing Pods just because a policy changed.

Only images matching the policy's image-reference patterns are signature-checked by this policy. A different repository may therefore show a signature-policy pass because it is outside this policy's match scope; this does **not** certify that image as signed.

## 4. Policy enforcement: Audit versus Deny

The two controls serve different purposes:

- **`validationActions`** determines what happens when the policy expression evaluates to a violation.
- **`failurePolicy`** determines how an evaluation/webhook error is handled.

| Configuration | Result for a policy violation | Result for an evaluation error |
|---|---|---|
| `validationActions: [Audit]`, `failurePolicy: Ignore` | Records the violation; normally admits the Pod | Does not block admission because of the evaluation error |
| `validationActions: [Deny]`, `failurePolicy: Ignore` | Rejects a policy violation | Ignores evaluation errors, so enforcement has a possible fail-open path |
| `validationActions: [Deny]`, `failurePolicy: Fail` | Rejects a policy violation | Fails closed; evaluation errors can reject otherwise valid Pod requests |

The current manifests use the first row. **Deny is not enabled yet.**

Do not switch to Deny simply because a sample violation appears in a PolicyReport. First review all existing findings, fix false positives, validate the manifests, and prove that the signature controller can reach the registry and transparency-log services. A network timeout can otherwise block legitimate Pod creation when fail-closed enforcement is enabled.

## 5. Validate policy manifests before syncing

Run these from a checkout of the PR branch or the intended release commit.

### 5.1 Render Kustomize

```bash
kubectl kustomize k8s/policies
```

Review the output and confirm that both policy resources are present.

### 5.2 Server-side dry-run validation

First confirm that your kubectl context points to the downstream cluster:

```bash
kubectl config current-context
kubectl get crd validatingpolicies.policies.kyverno.io
kubectl get crd imagevalidatingpolicies.policies.kyverno.io
```

Then validate the resources against the downstream API without persisting them:

```bash
kubectl apply --dry-run=server -k k8s/policies
```

The dry run should complete without YAML, schema, or admission-validation errors. A local render by itself is not enough: server-side dry-run also checks the target cluster's API/CRD validation path.

### 5.3 Review the Git diff

```bash
git diff --check
git diff -- k8s/policies/
```

Confirm the namespace lists remain present in both policies, the signature identity remains exact, and no policy was inadvertently switched to Deny.

> For CI, make the render, `git diff --check`, and server-side policy validation part of the pre-merge checks where cluster access is available. If CI cannot access the target cluster, use a pinned Kyverno CLI/version and an explicit policy test suite, then retain server-side dry-run as a deployment check. Do not treat YAML parsing alone as proof that CEL expressions or image-signature verification work.

## 6. Argo CD integration

The Application manifest is `argocd/application-policies.yaml`.

It tracks:

- Repository: `https://github.com/aymanlinuxBoy/node-api.git`
- Revision: `main`
- Path: `k8s/policies`
- Application name: `node-api-poc-policies`
- Destination cluster name: `downstream`
- Destination namespace association: `kyverno`
- Automated sync: enabled
- Prune: enabled
- Self-heal: enabled

The policies themselves are cluster-scoped resources. The `kyverno` destination namespace in the Argo CD Application is an Application destination/association and does not mean that policy matching is limited to Pods in that namespace.

Check the Application:

```bash
kubectl -n argocd get application node-api-poc-policies
kubectl -n argocd get application node-api-poc-policies \
  -o jsonpath='{.status.sync.status}{" | "}{.status.health.status}{"\n"}'
```

If the Argo CD CLI is installed:

```bash
argocd app get node-api-poc-policies
argocd app diff node-api-poc-policies
```

Check that both policy resources exist in the downstream cluster:

```bash
kubectl get validatingpolicy node-api-poc-restrict-image-repository
kubectl get imagevalidatingpolicy node-api-poc-verify-signature
```

After a PR is merged, wait for automated sync or request a sync through your normal Argo CD workflow. Verify the Application is **Synced** and **Healthy**, then re-check the live policy resources. Do not make manual live-only edits: Argo CD self-heal can revert them, and they would not be reproducible from Git.

## 7. Test cases: pass, fail, and error

**Important:** run one test at a time. These examples create short-lived Pods. In Audit mode, a Pod can be admitted even when the PolicyReport shows a failure.

Before testing, check the context:

```bash
kubectl config current-context
```

### 7.1 Test A — Approved Node API image (expected pass)

The tag below was tested previously and both policies reported `pass`:

```bash
kubectl run kyverno-approved-image-test \
  -n devsecops \
  --image=aimocont2020/node-api-poc:d2dbfc4eb04f \
  --restart=Never \
  --command -- node -e 'setTimeout(() => {}, 60000)'
```

Expected in the PolicyReport:

- Repository policy: `pass`
- Signature policy: `pass` when signature verification and registry access succeed

If the signature policy returns `error`, do not call it a pass or a signature failure; diagnose the error separately.

### 7.2 Test B — Disallowed repository (expected repository-policy failure in Audit)

```bash
kubectl run kyverno-repo-negative-test \
  -n devsecops \
  --image=busybox:1.36 \
  --restart=Never \
  --command -- sleep 90
```

Expected:

- Repository policy: `fail`, because BusyBox is outside the allow-list.
- Signature policy: it may show `pass` because BusyBox is outside that policy's Node API image-reference match; this does **not** mean BusyBox has a trusted signature.
- In the current Audit mode, the Pod can still be created.

After the repository policy fix is synced, a `devsecops-demo` image in `devsecops` or `devsecops-bg` should no longer be a repository-policy violation. That repository should still be rejected by the repository policy in `devsecops-canary`.

### 7.3 Test C — Node API image without a signature (expected signature-policy failure in Audit)

This image reference was tested previously; manual Cosign verification returned `no signatures found`.

```bash
kubectl run kyverno-unsigned-image-test \
  -n devsecops \
  --image=aimocont2020/node-api-poc:dcc44ff08039 \
  --restart=Never \
  --command -- node -e 'setTimeout(() => {}, 60000)'
```

Expected in the PolicyReport:

- Repository policy: `pass` — the repository path is approved.
- Signature policy: `fail` — the image does not have a verifiable signature from the trusted workflow identity.
- In Audit mode, Pod creation is not blocked by the policy violation.

### 7.4 Test D — Explicit digest reference

The canary image tag `1433721ecbc7` was manually verified with Cosign, and the reported digest was:

```text
sha256:538d94f1e77389a6d27368aa1b0337a35adc5c54202bfd138a3cdb084a0b6bb2
```

The equivalent explicit-digest test was created in `devsecops-canary`:

```bash
kubectl run kyverno-signed-digest-test \
  -n devsecops-canary \
  --image=docker.io/aimocont2020/node-api-poc@sha256:538d94f1e77389a6d27368aa1b0337a35adc5c54202bfd138a3cdb084a0b6bb2 \
  --restart=Never \
  --command -- node -e 'setTimeout(() => {}, 60000)'
```

The recorded PolicyReport result was `error`, with an `i/o timeout` while contacting `https://index.docker.io/v2/`. This is an **evaluation/network error**, not evidence that the signature is invalid. The manual Cosign verification of the tag succeeded, but Kyverno's policy result for the digest reference remained unconfirmed because of the network error.

Before enabling Deny, verify outbound connectivity from the Kyverno controller's network path to Docker Hub and the Sigstore/Rekor endpoints. A one-time DNS resolution is not enough: verify the HTTPS request receives a response. Review controller logs around the failed evaluation.

### 7.5 Read the report for one test Pod

Set `NS` and `POD` to the namespace and Pod under investigation:

```bash
NS=devsecops-canary
POD=kyverno-signed-digest-test

kubectl get policyreports.wgpolicyk8s.io -n "$NS" -o json |
  jq -r --arg pod "$POD" '
    .items[]
    | select(.scope.name == $pod)
    | .results[]
    | "Policy: \(.policy) | Result: \(.result) | Message: \(.message)"
  '
```

Result meanings:

- **`pass`** — the policy evaluated and the tested resource passed its rule.
- **`fail`** — the rule evaluated and identified a policy violation.
- **`error`** — evaluation could not complete, for example because the registry request timed out.
- **No matching report** — the report might not have been generated yet, the Pod name/namespace may be wrong, or the request/resource may not have reached the reporting path. Check the Pod and Kyverno logs rather than assuming success.

### 7.6 Clean up test Pods

Run only after capturing the report:

```bash
kubectl delete pod kyverno-approved-image-test -n devsecops --ignore-not-found
kubectl delete pod kyverno-repo-negative-test -n devsecops --ignore-not-found
kubectl delete pod kyverno-unsigned-image-test -n devsecops --ignore-not-found
kubectl delete pod kyverno-signed-digest-test -n devsecops-canary --ignore-not-found
```

These are examples; delete only test Pods that currently exist.

## 8. Check policy scope and namespace coverage

Both current policy manifests already include all three namespaces.

For signature validation, inspect the selector and exact image-reference matches:

```bash
kubectl get imagevalidatingpolicy node-api-poc-verify-signature -o yaml
```

For repository restrictions:

```bash
kubectl get validatingpolicy node-api-poc-restrict-image-repository -o yaml
```

Confirm the effective namespace list is:

```text
devsecops
devsecops-bg
devsecops-canary
```

The namespace coverage being present does not guarantee that every app image is allowed by the repository restriction; ensure the repo allow-list also matches the actual application inventory.

## 9. Switch to Deny only after the audit phase

Do not enable this yet solely on the basis of the test samples. Recommended gates:

1. Merge the repository allow-list correction and confirm Argo CD is Synced/Healthy.
2. Review PolicyReports across all three namespaces and resolve false positives.
3. Re-run both positive and negative image tests.
4. Fix registry and Rekor connectivity. Confirm signature validation produces `pass` for a known signed image digest and `fail` for a known unsigned image, not `error`.
5. Confirm all production workloads use approved image references and that the CI signer identity is deliberately restricted to the expected workflow.
6. Prepare a rollback plan and communicate that new or updated Pods may be rejected.

The intended enforced configuration, once approved, is:

```yaml
spec:
  validationActions:
    - Deny
  failurePolicy: Fail
```

Apply this change through Git and Argo CD. Change one policy at a time if you want to isolate repository enforcement from signature verification. The signature policy is especially sensitive to registry and transparency-log availability when configured to fail closed.

## 10. Recommendations

1. **Prefer digest-pinned images.** Tags are mutable. Require deployment manifests to reference an image digest that CI has signed; keep the verification policy's digest checks enabled.
2. **Keep the signer identity narrow.** Do not weaken the issuer or subject to trust every workflow in the GitHub organization. Protect changes to the trusted CI workflow and its branch.
3. **Fix egress before enforcing signatures.** Allow and monitor the registry and Sigstore endpoints needed by the installed Kyverno/Cosign implementation. Alert on policy evaluation errors separately from signature failures.
4. **Keep image allow-lists aligned with workloads.** Shared namespaces need allow-lists for each approved app; canary should remain narrowly scoped to the Node API repo.
5. **Automate policy validation.** Validate Kustomize rendering, manifest formatting, CEL/policy tests, and—where possible—server-side dry-run in a required PR check.
6. **Test Deny in a controlled namespace first.** A rejected Pod is different from an Audit violation. Verify the actual admission response, not just PolicyReports.
7. **Review reports regularly.** Query all namespaces after a policy change and retain test evidence. Remove temporary test Pods.
8. **Manage only through GitOps.** Keep Argo CD pointed at `k8s/policies`, review PRs, and verify sync/health after merge.
9. **Consider app-level boundaries.** A namespace allow-list restricts repositories per namespace, not per Deployment. If apps must be isolated from each other's repositories, use separate namespaces or add stronger workload-specific controls backed by identity/ownership controls; do not rely on user-editable Pod labels alone.

## 11. Quick operations checklist

- [ ] kubectl context points to `downstream`.
- [ ] Kyverno controller Pods are healthy.
- [ ] Both policy CRDs exist.
- [ ] Kustomize rendering succeeds.
- [ ] Server-side dry-run succeeds.
- [ ] `node-api-poc-policies` is Synced and Healthy.
- [ ] Both policies include all three namespaces.
- [ ] Repository allow-list matches real workloads.
- [ ] Known approved image reports `pass`.
- [ ] Known disallowed repository reports repository-policy `fail` in Audit.
- [ ] Known unsigned Node API image reports signature-policy `fail` in Audit.
- [ ] Registry/transparent-log failures show no `error` for valid signed digest tests.
- [ ] Deny mode is enabled only after approval and a rollback plan.

## 12. References

- [Policy manifests](https://github.com/aymanlinuxBoy/node-api/tree/main/k8s/policies)
- [Argo CD Application manifest](https://github.com/aymanlinuxBoy/node-api/blob/main/argocd/application-policies.yaml)
- [Kyverno documentation](https://kyverno.io/docs/)
- [Sigstore Cosign verification](https://docs.sigstore.dev/cosign/verifying/verify/)
