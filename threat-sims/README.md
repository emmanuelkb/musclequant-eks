# Threat Simulations

Two scripted scenarios that exercise the controls implemented in this project.
Each scenario describes the **threat**, the **control** that mitigates it, the
**detection** path, and the **expected output**.

Run all of them in one shot:

```bash
./threat-sims/run.sh
# Output is captured to docs/threat-sim-output.txt
```

---

## Scenario 1 — Privilege escalation attempt

**Threat.** An attacker who somehow obtained Kubernetes credentials with
`create pods` in the `musclequant` namespace tries to schedule a pod that:

- runs as root,
- mounts the host root filesystem,
- enables `hostPID` / `hostNetwork`,
- adds `SYS_ADMIN`, `NET_ADMIN`, `SYS_PTRACE` capabilities,
- chroots into the host and reads `/etc/shadow`.

**Control.** The `musclequant` namespace carries
`pod-security.kubernetes.io/enforce: restricted`. The Pod Security admission
controller rejects the manifest at API-server admission time, before any
container is scheduled.

**Detection.** The rejection is logged in:

- the `kubectl apply` exit code and stderr,
- the EKS control-plane **audit log** stream in CloudWatch (`/aws/eks/<cluster>/cluster`),
- GuardDuty's EKS Audit Log feature, which raises the
  `Policy:Kubernetes/PrivilegeEscalation` finding family.

**Expected output (excerpt):**

```
Error from server (Forbidden): error when creating "01-privileged-pod.yaml":
pods "priv-escalation-attempt" is forbidden: violates PodSecurity "restricted:latest":
host namespaces (hostNetwork=true, hostPID=true), hostPath volumes, privileged
(container "hostroot" must not set securityContext.privileged=true), allowPrivilegeEscalation
!= false, unrestricted capabilities (container "hostroot" must not include
"NET_ADMIN", "SYS_ADMIN", "SYS_PTRACE" in securityContext.capabilities.add),
runAsNonRoot != true, seccompProfile (must be set to one of "RuntimeDefault" or
"Localhost")
```

---

## Scenario 2 — Compromised pod attempts cloud-credential theft

**Threat.** A workload running in a less-restricted namespace (`red-team`) is
assumed compromised. The attacker tries to escalate from "shell on a pod" to
"AWS credentials" by:

1. **(2a)** Hitting the EC2 Instance Metadata Service (IMDSv2) at
   `169.254.169.254` to steal the **node** instance role's credentials.
2. **(2b)** Calling Secrets Manager directly without any IAM identity.
3. **(2c)** Demonstrating that even an *authorized* pod (the api) cannot list
   all secrets — its IRSA role is scoped to a single secret ARN.

**Controls.**

| # | Control |
|---|---|
| 2a | Node `metadata_options.http_put_response_hop_limit = 1` — packets to IMDS from inside a pod (hop count 2) are dropped at the kernel before they leave the node. IMDSv2 token requirement adds defense in depth. |
| 2a | Egress NetworkPolicy on the `musclequant` namespace explicitly excludes `169.254.169.254/32`. |
| 2b | The attacker pod has no IRSA annotation. The pod's projected service-account token is not bound to any IAM role, so STS rejects the AssumeRoleWithWebIdentity call. |
| 2c | The api pod's IRSA role allows `secretsmanager:GetSecretValue` on a single ARN, with no `ListSecrets` permission. |

**Detection.**

- IMDS call timeout is visible in the pod logs.
- AccessDenied calls to Secrets Manager are recorded in CloudTrail and surface in GuardDuty as `UnauthorizedAccess:IAMUser/InstanceCredentialExfiltration` (when the source is a different VPC) or as `Discovery:S3/MaliciousIPCaller`-style findings depending on the API.
- VPC flow logs show the dropped IMDS attempt.

**Expected output (excerpt):**

```
+ kubectl -n red-team exec attacker -- sh -c 'curl --max-time 3 -s -X PUT ...'
[BLOCKED — IMDS unreachable from pod]

+ kubectl -n red-team exec attacker -- aws secretsmanager get-secret-value ...
Unable to locate credentials. You can configure credentials by running "aws configure".
[BLOCKED — no credentials / AccessDenied]
```

---

## Mapping to the rubric

| Phase | Control demonstrated |
|---|---|
| 4 — IAM | IRSA on api pod scoped to a single secret ARN (2c). |
| 5 — Network | NetworkPolicy default-deny + explicit IMDS deny (2a). |
| 6 — Data | Secrets Manager + CMK encryption (2b). |
| 7 — Container | Pod Security Standards `restricted` (1). |
| 8 — Monitoring | CloudWatch audit logs + GuardDuty EKS findings (all). |
| 9 — Threat sim | Two end-to-end documented scenarios with detect/mitigate/respond. |
