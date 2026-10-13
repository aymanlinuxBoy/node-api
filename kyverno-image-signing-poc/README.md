# Kyverno Image Policy and Cosign Verification PoC

This PoC connects the existing GitHub Actions image-signing workflow to Kubernetes admission control. It is intentionally scoped to the Node API application namespaces rather than the whole cluster.

## What this protects

Two independent controls are included:

1. **Repository allow-list** — workloads in `devsecops`, `devsecops-canary`, and `devsecops-bg` may use only `aimocont2020/node-api-poc`. An image merely being hosted on Docker Hub is not sufficient.
2. **Signature verification** — the Node API image must have a valid keyless Cosign signature from this exact GitHub Actions workflow:
   `https://github.com/aymanlinuxBoy/node-api/.github/workflows/ci-security.yml@refs/heads/main`

The policy uses the GitHub Actions OIDC issuer `https://token.actions.githubusercontent.com` and the public Sigstore Rekor transparency log.

> **Important:** Start in `Audit` mode, verify the deployed image has a valid signature, review the reports, and only then switch to `Enforce`. Do not enforce image verification before confirming that the tag/digest you deploy was signed by the expected workflow. This PoC has not been applied to a live cluster by these repository changes.

## Scope and assumptions

- The Kubernetes namespaces are dedicated to the Node API application: `devsecops`, `devsecops-canary`, and `devsecops-bg`.
- The approved image repository is `docker.io/aimocont2020/node-api-poc`. If the Docker Hub username or repository changes, update **both** policy files and the GitOps overlays.
- The CI workflow signs images on pushes to `main`, after the build, vulnerability scan, and push steps succeed.
- The manifests use the `kyverno.io/v1` `ClusterPolicy` API with `verifyImages` keyless Cosign verification. Check the Kyverno version installed in your cluster before applying. The older `ClusterPolicy` API is suitable for broad compatibility, while newer Kyverno versions also provide the `ImageValidatingPolicy` API.

This repository allow-list intentionally allows only the application image in these namespaces. If you later add service-mesh sidecars, init containers, exporters, or migration jobs using other images, explicitly add their trusted repositories rather than broadly allowing all of Docker Hub.

## 1. Inspect Kyverno before applying anything

Run:

```bash
kubectl get nodes -o wide
kubectl get deployments -A | grep -i kyverno
kubectl get pods -A | grep -i kyverno
kubectl get clusterpolicies.kyverno.io
kubectl get crd | grep -i kyverno
kubectl version
```

Confirm the Kyverno version, that the admission controller is Ready, and whether existing policies may already affect these namespaces. If `clusterpolicies.kyverno.io` is not available, stop and check the installed Kyverno policy API/version before applying these files.

Inspect the image currently rendered by Kustomize:

```bash
kubectl kustomize k8s/overlays/poc | grep -E 'image:'
kubectl get pods -n devsecops -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}'
```

Repeat the pod inspection for `devsecops-canary` and `devsecops-bg` if those deployments are running.

## 2. Understand the complete signing and admission cycle

```text
Developer pushes code / merges to main
                |
                v
GitHub Actions: tests and security checks
                |
                v
Build container image
                |
                v
Trivy scans the image; workflow fails for configured HIGH/CRITICAL findings
                |
                v
Push image to Docker Hub and capture its immutable sha256 digest
                |
                v
Cosign signs that digest using GitHub Actions OIDC (keyless)
        |                               |
        v                               v
Fulcio issues a short-lived certificate     Signature/bundle transparency
bound to workflow identity                  recorded in public Rekor
                |
                v
Workflow verifies the signature itself
                |
                v
GitOps overlay references the image tag
                |
                v
Kubernetes receives a Deployment / Pod admission request
                |
                v
Kyverno repository policy checks the image name
                |
                v
Kyverno verification policy checks the digest's signature,
trusted workflow subject, OIDC issuer, and Rekor entry
                |
        +-------+-------+
        |               |
   verification      verification
      passes           fails
        |               |
        v               v
admission allowed   Audit: report / Enforce: reject
```

### What each part means

- **Docker Hub** stores and distributes the container image. Its location alone does not prove who built the image.
- **Cosign** signs the immutable image digest. Signing the digest binds the signature to those exact image bytes, not just to a mutable tag.
- **Keyless signing** uses the workflow's OIDC identity instead of a long-lived private key. Fulcio provides a short-lived signing certificate, and Rekor provides a public transparency log.
- **Kyverno** is the Kubernetes admission-policy engine. Its policy tells Kubernetes which image repository is allowed and which signing identity is trusted.
- **Digest mutation** makes the admitted workload refer to an immutable image digest rather than relying on a mutable tag. The verification policy enables this behavior.

A valid signature means the image digest was signed by the trusted identity and passed the verification rules. By itself, it does **not** prove the image is vulnerability-free, that every dependency is safe, or that an attestation such as an SBOM/provenance document meets a policy. Those require separate checks.

## 3. Confirm that the deployed image has a signature first

Use the exact image tag shown by your selected Kustomize overlay or running Pod, then resolve it to a digest. You can also copy the digest printed by the successful `Push image` step in the GitHub Actions run.

For example, with Cosign installed locally:

```bash
IMAGE='aimocont2020/node-api-poc:<tag-from-your-overlay>'

# Inspect the image's digest. crane is one option:
crane digest "$IMAGE"

# Replace <sha256-digest> with the digest returned above, including sha256:
cosign verify \
  --certificate-identity 'https://github.com/aymanlinuxBoy/node-api/.github/workflows/ci-security.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  'aimocont2020/node-api-poc@sha256:<digest>'
```

Do not copy the angle-bracket placeholders literally. Verification should return the signature/claim payload. If it fails, check that:
- the tag was produced by a successful `push` to `main` after Cosign signing was added;
- `DOCKERHUB_USERNAME` in GitHub Actions matches `aimocont2020`;
- the image digest is the digest that was signed; and
- the workflow file and branch in the certificate identity match the policy.

Do not switch enforcement on until this manual check succeeds.

## 4. Apply the repository allow-list in Audit mode

```bash
kubectl apply -f kyverno-image-signing-poc/policies/01-restrict-app-image-repository.yaml
kubectl describe clusterpolicy restrict-node-api-image-repository
```

In `Audit` mode, a disallowed image can still be admitted, but Kyverno should report the policy violation. Inspect the report APIs available in your cluster:

```bash
kubectl get policyreport -A
kubectl get clusterpolicyreport
kubectl get clusterpolicy restrict-node-api-image-repository -o yaml
```

The policy targets Pods in the three application namespaces and is written so Kyverno can auto-generate corresponding rules for supported workload controllers. Inspect `status.autogen.rules` after creation. Always check the actual policy status and reports; do not assume the policy is enforced merely because its object exists.

## 5. Apply the Cosign signature policy in Audit mode

```bash
kubectl apply -f kyverno-image-signing-poc/policies/02-verify-signed-node-api-image.yaml
kubectl describe clusterpolicy verify-signed-node-api-image
kubectl get clusterpolicy verify-signed-node-api-image -o yaml
```

Review the policy status, controller logs if verification fails, and available PolicyReports. Image verification needs network access from the Kyverno admission controller to the image registry and Sigstore services. Private images may require registry credentials; this example assumes the image is publicly readable.

## 6. Test the policy behavior

### Negative test: use a different public image

Run this only in one of the dedicated application namespaces while both policies are in Audit mode:

```bash
kubectl run kyverno-untrusted-image-test \
  -n devsecops \
  --image=busybox:1.36 \
  --restart=Never \
  --command -- sleep 60
```

In Audit mode, the Pod may be admitted. The expected result is a policy violation in Kyverno's report/status. Clean up the test:

```bash
kubectl delete pod kyverno-untrusted-image-test -n devsecops --ignore-not-found
```

### Positive test: use a signed Node API image

Choose a tag that you verified manually in step 3:

```bash
kubectl run kyverno-signed-image-test \
  -n devsecops \
  --image=aimocont2020/node-api-poc:<verified-tag> \
  --restart=Never
```

If the image is successfully verified, inspect the resulting Pod's image field and policy status. Delete the test Pod when finished. This is only a signature test; the app may not become Ready because it needs its normal environment and database configuration.

## 7. Switch from Audit to Enforce

Only after the repository policy reports the expected behavior, the positive signature test succeeds, and the current application image is signed:

1. Edit each policy's `spec.validationFailureAction` from `Audit` to `Enforce`.
2. Apply the changed manifests.
3. Repeat the negative test. The request to create a Pod using `busybox:1.36` should be rejected by admission.
4. Repeat the positive test with a verified Node API image. It should be admitted.
5. Watch the application rollout and check Pod events if it fails.

Do not move directly to cluster-wide enforcement. Keep the scope limited until you intentionally define approved image sources for platform, monitoring, storage, and other namespaces.

## 8. Troubleshooting

- **Policy object exists but images are still admitted:** check `validationFailureAction`, `status.conditions`, PolicyReports, namespace matching, and Kyverno admission controller health. Audit mode intentionally does not reject requests.
- **A Deployment is accepted but its Pods fail:** inspect the Pod events; the auto-generated Pod-template policy may be rejecting the image when the ReplicaSet creates it.
- **Signature verification fails:** confirm the exact digest was signed, the signature exists in Docker Hub, the subject matches the full workflow identity, the issuer is `https://token.actions.githubusercontent.com`, and the controller can reach Docker Hub and Rekor.
- **An application Pod is unexpectedly rejected by the repository policy:** inspect every container, initContainer and ephemeralContainer. The policy intentionally permits only the Node API image in the selected namespaces.
- **No PolicyReport CRDs exist:** check the installed Kyverno version and reporting features; policy admission results and controller logs can still help diagnose failures.

## Cleanup

Delete the policies if you need to roll back this PoC:

```bash
kubectl delete -f kyverno-image-signing-poc/policies/02-verify-signed-node-api-image.yaml
kubectl delete -f kyverno-image-signing-poc/policies/01-restrict-app-image-repository.yaml
```

Deleting these policies removes their admission checks; it does not delete the application workload.

## References

- [Kyverno: Verify Images overview](https://kyverno.io/docs/policy-types/cluster-policy/verify-images/overview/)
- [Kyverno: Sigstore keyless verification](https://kyverno.io/docs/policy-types/cluster-policy/verify-images/sigstore/)
- [Kyverno: Restrict Image Registries policy](https://kyverno.io/policies/best-practices/restrict-image-registries/restrict-image-registries/)
- [Sigstore: Verifying signatures](https://docs.sigstore.dev/cosign/verifying/verify/)
