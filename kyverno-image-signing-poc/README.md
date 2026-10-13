# Kyverno Image Allow-List and Cosign Verification PoC

This PoC connects the existing GitHub Actions image-signing workflow to Kyverno admission control, with Argo CD managing the live policy manifests from Git. The actual policy files live under `k8s/policies/`, which is already the source path of the `node-api-poc-policies` Argo CD Application. This guide stays separate as documentation.

## What this PoC protects

Two separate policies provide two different controls:

1. **Repository allow-list** — a `ValidatingPolicy` restricts images in `devsecops`, `devsecops-canary`, and `devsecops-bg` to `aimocont2020/node-api-poc`. It does not trust Docker Hub as a whole.
2. **Signature verification** — an `ImageValidatingPolicy` requires the Node API image to have a valid Cosign keyless signature from this exact workflow identity:
   `https://github.com/aymanlinuxBoy/node-api/.github/workflows/ci-security.yml@refs/heads/main`

Both policies start with `validationActions: [Audit]` and `failurePolicy: Ignore` so policy-evaluation errors don't block the initial audit rollout. The modern CEL policy API uses `Deny` to reject non-compliant admissions; this differs from the legacy `ClusterPolicy` API's `validationFailureAction: Enforce`. Before enforcement, change `validationActions` to `Deny` and `failurePolicy` to `Fail` in both policies.

> **Safety first:** This PR has not been applied to the live cluster. Start in Audit mode, confirm the currently deployed image digest was signed by the expected workflow, review the policy behavior, and only then change `validationActions` from `Audit` to `Deny`.

## Why the newer API is used

Your cluster reports Kyverno `v1.19.1`, and the `ImageValidatingPolicy`, `ValidatingPolicy`, and namespaced variants are installed. Kyverno 1.19 deprecates the legacy `ClusterPolicy` API, with removal planned for v1.20, so this PoC uses:

- `policies.kyverno.io/v1`, kind `ValidatingPolicy` for repository allow-listing.
- `policies.kyverno.io/v1`, kind `ImageValidatingPolicy` for Cosign signature verification.

The live schema in your cluster is authoritative. Use server-side dry-run before merging. Since the Argo CD Application tracks `main`, changes in this PR will not be deployed by Argo CD until the PR is merged.

## Scope and assumptions

- The three listed namespaces are dedicated to the Node API application.
- Approved image repository: `docker.io/aimocont2020/node-api-poc`.
- Other images, sidecars, init containers, exporters, and migration tools are not automatically trusted. This allow-list is intentionally strict; amend it only after reviewing which extra repositories are needed.
- The CI workflow `.github/workflows/ci-security.yml` builds the image, runs Trivy, pushes to Docker Hub, signs the pushed digest with Cosign keyless signing, then verifies the signature.
- Public image access is assumed. If the image becomes private, ensure Kyverno has appropriate registry credentials.
- The signature verification policy disables background scanning and evaluates image signatures during admission.

## 1. Inspect Kyverno and the target workloads

```bash
kubectl config current-context

kubectl -n kyverno get deployment kyverno-admission-controller \
  -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{" = "}{.image}{"\n"}{end}'

kubectl get crd | grep 'policies.kyverno.io'

kubectl get validatingpolicies.policies.kyverno.io
kubectl get imagevalidatingpolicies.policies.kyverno.io

kubectl kustomize k8s/overlays/poc | grep -E 'image:'
kubectl get pods -n devsecops -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```

Repeat the Pod inspection for `devsecops-canary` and `devsecops-bg` if those deployments are running. Verify the installed policy CRDs serve `policies.kyverno.io/v1`.

## 2. Understand the complete signing and admission cycle

```text
Developer pushes or merges code to main
                 |
                 v
GitHub Actions tests and security checks
                 |
                 v
Build image -> Trivy scan -> push image to Docker Hub
                 |
                 v
Capture immutable sha256 image digest
                 |
                 v
Cosign signs that digest using GitHub Actions OIDC
          |                            |
          v                            v
Fulcio short-lived certificate       Rekor transparency log
bound to workflow identity           records signing metadata
                 |
                 v
CI verifies the Cosign signature
                 |
                 v
GitOps overlay references the image tag
                 |
                 v
Kubernetes admission request for a Pod
                 |
                 +------------------------------+
                 |                              |
                 v                              v
ValidatingPolicy                       ImageValidatingPolicy
checks repository                      verifies signature and signer
                 |                              |
                 +---------------+--------------+
                                 |
                    +------------+-----------+
                    |                        |
               Validation passes       Validation fails
                    |                        |
                    v                        v
              Audit: allow             Audit: allow + record
              Deny: allow              Deny: reject admission
```

### What the pieces mean

- **Docker Hub** distributes the image. Hosting on Docker Hub does not establish who built it.
- **Cosign** signs the image digest. A digest identifies immutable image content; a tag can move to different content.
- **Keyless signing** uses the GitHub Actions OIDC identity rather than a long-lived private key. Fulcio issues a short-lived certificate, and Rekor provides a public transparency log.
- **Kyverno** evaluates the policies at Kubernetes admission. The repository policy checks the allowed image name; the image policy verifies the cryptographic signature against the expected workflow identity.
- **Digest mutation and verification** help ensure the admitted workload is tied to the verified digest rather than continuing to rely on a mutable tag.

A valid signature means the digest was signed by the identity that the policy trusts. It does **not** by itself prove the image is vulnerability-free, that its dependencies are safe, or that it has a valid SBOM/provenance attestation. Those require additional checks.

## 3. Verify a deployed image manually before enforcement

Use the actual image tag from the selected overlay or running Pod. Resolve the tag to its digest with `crane` (or another registry tool), then verify that digest with Cosign.

```bash
# Replace <tag> with a real tag from your overlay or Pod.
crane digest docker.io/aimocont2020/node-api-poc:<tag>

# Replace <digest> with the real sha256 digest returned above.
cosign verify \
  --certificate-identity 'https://github.com/aymanlinuxBoy/node-api/.github/workflows/ci-security.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  'docker.io/aimocont2020/node-api-poc@sha256:<digest>'
```

Do not enter the angle-bracket placeholders literally. Successful verification should return the verified signature/claim payload. If it fails, check that:

- The image was pushed and signed by a successful run on `main` after the signing step was introduced.
- The GitHub Actions `DOCKERHUB_USERNAME` secret corresponds to `aimocont2020`.
- The reference uses the exact digest that was signed.
- The workflow file, branch, subject and OIDC issuer match the policy.

Do not switch to `Deny` until this check succeeds for the image you are deploying.

## 4. Validate the GitOps manifests before merging

From the repository root, render the exact directory tracked by Argo CD and ask the API server to validate it without persisting resources:

```bash
kubectl kustomize k8s/policies
kubectl apply --dry-run=server -k k8s/policies
```

This checks whether the API server accepts the resource schemas. It does not prove the CEL expressions work or that a real image signature verifies. Do not deploy these policies with a separate `kubectl apply` for normal operations; Argo CD should manage their lifecycle. The Application currently targets the `main` branch, so it will only pick up these PR changes after merge.

## 5. Let Argo CD reconcile both policies

After this PR is merged to `main`, check the existing Application:

```bash
kubectl -n argocd get application node-api-poc-policies
argocd app get node-api-poc-policies
kubectl get validatingpolicy node-api-poc-restrict-image-repository -o yaml
```

The Application's source path is `k8s/policies`. Its Kustomization includes both the repository restriction policy and the signature policy. Both start in Audit mode, so a repository violation should not block admission. Review policy status, generated PolicyReports, and Kyverno controller logs.

## 6. Check signature verification in Audit mode

```bash
kubectl get imagevalidatingpolicy node-api-poc-verify-signature -o yaml
kubectl logs -n kyverno deployment/kyverno-admission-controller --since=10m
```

The `ImageValidatingPolicy` matches Node API image references and verifies Cosign signatures using:

- Subject: `https://github.com/aymanlinuxBoy/node-api/.github/workflows/ci-security.yml@refs/heads/main`
- Issuer: `https://token.actions.githubusercontent.com`
- Transparency log: `https://rekor.sigstore.dev`

The policy uses `mutateDigest: true` and `verifyDigest: true`. Since background evaluation is disabled, validate behavior by creating/updating test Pods and reviewing admission results and controller logs; do not expect a background signature scan.

## 7. Test both outcomes

### Negative test: use an unapproved public image

Run this only in a dedicated application namespace while policies are in Audit mode:

```bash
kubectl run kyverno-untrusted-image-test \
  -n devsecops \
  --image=busybox:1.36 \
  --restart=Never \
  --command -- sleep 60
```

The repository policy should report a violation, while Audit mode should still allow the Pod object to be created. The image-verification policy only matches the Node API repository. Clean up:

```bash
kubectl delete pod kyverno-untrusted-image-test -n devsecops --ignore-not-found
```

### Positive test: use a verified Node API image

Replace `<verified-tag>` with a tag whose digest passed step 3:

```bash
kubectl run kyverno-signed-image-test \
  -n devsecops \
  --image=aimocont2020/node-api-poc:<verified-tag> \
  --restart=Never
```

This tests admission only. The app might not become Ready because the test Pod lacks the application's normal environment and database configuration. Inspect the Pod's image and admission/controller output, then clean up:

```bash
kubectl delete pod kyverno-signed-image-test -n devsecops --ignore-not-found
```

## 8. Move from Audit to Deny

Only after the unapproved image generates the expected violation, the signed image is accepted, and the currently deployed image digest is verified:

1. In **both** manifests, change `spec.validationActions` from `[Audit]` to `[Deny]` and change `spec.failurePolicy` from `Ignore` to `Fail`.
2. Commit the changes and merge them through the normal reviewed GitOps workflow. Argo CD then reconciles the updated policies from `main`.
3. Repeat the negative test: `busybox:1.36` should be rejected at admission in the application namespace.
4. Repeat the positive test with the verified Node API image.
5. Monitor workload rollouts and Pod events.

For the new CEL policy APIs, the action is `Deny`; do not use the legacy `ClusterPolicy` field `validationFailureAction: Enforce`.

Do not make these policies cluster-wide without separately designing an approved-image strategy for Rancher, monitoring, storage, and other platform namespaces.

## Troubleshooting

- **Server-side dry-run rejects a field:** check that the manifest uses `apiVersion: policies.kyverno.io/v1` and the relevant installed CRD is serving `v1`.
- **Unapproved image is still admitted in Audit mode:** this is expected. Check the policy status and audit/reporting output. Change to `Deny` only after validation.
- **Unapproved image remains admitted after switching to Deny:** verify that the policy is Ready, the Pod namespace matches the `matchConditions`, and the admission controller is healthy.
- **Signature verification fails or evaluates with an error:** check the exact image digest, public registry reachability from Kyverno, Rekor reachability, the signer subject, and the issuer. In Audit mode, `failurePolicy: Ignore` avoids blocking admissions on an evaluation error, so inspect controller logs and confirm the signature manually before moving to `Deny`/`Fail`.
- **A Pod includes a sidecar or init container:** this PoC intentionally treats these namespaces as application-image-only. Add and verify any additional images explicitly before enabling Deny.

## Rollback

Because Argo CD manages these resources with automated sync, `selfHeal: true`, and `prune: true`, do not delete the live policies by hand as a normal rollback—the GitOps controller may restore them or prune them based on Git. Revert the policy change in Git and merge the rollback through review; Argo CD will reconcile the desired state. If there is an urgent incident, follow your cluster's approved break-glass procedure and then reconcile Git to the intended state.

## References

- [Kyverno 1.19 release announcement](https://kyverno.io/blog/2026/08/20/announcing-kyverno-release-1.19/)
- [Kyverno policy type overview](https://kyverno.io/docs/policy-types/overview/)
- [Kyverno ValidatingPolicy](https://kyverno.io/docs/policy-types/validating-policy/)
- [Kyverno ImageValidatingPolicy](https://kyverno.io/docs/policy-types/image-validating-policy/)
- [Sigstore Cosign verification](https://docs.sigstore.dev/cosign/verifying/verify/)
