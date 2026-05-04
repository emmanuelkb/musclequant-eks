# MuscleQuant AI on AWS EKS

Secure, cloud-native deployment of a microservices EMG-monitoring application on
Amazon EKS. Built as the CS581 *Cloud Security Engineering* signature project.

The application is intentionally simple — a Flask **api** service that streams
EMG data from a MyoWare 2.0 sensor, plus a stateless **report-gen** service that
renders post-session reports. The interesting part is the platform: a hardened
Kubernetes cluster with IRSA, Pod Security Standards `restricted`, NetworkPolicy
default-deny, KMS-encrypted Secrets Manager pulled in via External Secrets
Operator, and continuous ECR + GuardDuty threat detection.

## Architecture (one-paragraph version)

Two managed-node-group worker nodes sit in the **private** subnets of a 2-AZ VPC.
An internet-facing Application Load Balancer in the **public** subnets terminates
TLS and forwards to the api service. The api talks to **report-gen** over
`ClusterIP` and to a private **RDS Postgres** in the database subnets. The
application secret (DB URL + Flask secret key) lives only in **AWS Secrets
Manager**, KMS-encrypted, and is synced into the cluster as a Kubernetes Secret
by the External Secrets Operator using IRSA. Pods can never reach IMDS (hop
limit = 1, NetworkPolicy denies `169.254.169.254/32`). All traffic is
constrained by NetworkPolicies; default is deny. Detection is layered: VPC flow
logs → CloudWatch, EKS audit logs → CloudWatch + GuardDuty, ECR enhanced
scanning → Inspector. See [`docs/architecture.png`](docs/architecture.png) for
the diagram and [`docs/REPORT.md`](docs/REPORT.md) for the full write-up.

## Prerequisites

| Tool | Version |
|---|---|
| `terraform` | ≥ 1.6 |
| `aws` CLI | ≥ 2.13 |
| `kubectl` | ≥ 1.28 |
| `docker` | recent |
| `envsubst` (gettext) | any |
| `jq` | any |
| AWS credentials | admin or close to it on first run |

## One-button up / down

```bash
make up      # ≈ 20–25 min: Terraform → push images → apply manifests → import TLS → ALB
make down    # ≈ 10 min:    delete namespaces, then terraform destroy
```

## Step-by-step (for the demo video)

```bash
# 1. Provision infra
make tf/init
make tf/plan
make tf/apply              # ≈ 15–18 min for EKS + RDS + helm releases

# 2. Build & push container images to the ECR repos created in step 1
make images/push

# 3. Render manifests with the live Terraform outputs and apply
make manifests/apply       # also imports the cert-manager TLS cert into ACM

# 4. Smoke test
make app/url               # prints the ALB URL
make pods

# 5. Threat simulations
make threat/run            # output captured to docs/threat-sim-output.txt

# 6. Tear down
make down
```

## Repo layout

```
services/
  api/             # Flask api: auth, EMG ingest, frontend templates
  report-gen/      # Stateless report renderer
infra/
  terraform/       # VPC + EKS + RDS + ECR + KMS + IAM + GuardDuty + Helm
  k8s/             # Manifests (envsubst placeholders, rendered to .rendered/ at apply time)
threat-sims/       # 2 scripted scenarios + runner
docs/              # Architecture diagram, technical report, threat-sim output
Makefile           # All lifecycle commands
```

## What the security controls map to

| Spec phase | Where it lives |
|---|---|
| 1. Architecture design | `docs/architecture.drawio.xml` + `docs/REPORT.md` |
| 2. EKS cluster deployment | `infra/terraform/eks.tf` (Terraform, not eksctl) |
| 3. App deployment | `services/*` + `infra/k8s/07-*`, `08-*`, `09-*`, `10-*` |
| 4. IAM | `infra/terraform/iam-irsa.tf` + `infra/k8s/01-serviceaccount.yaml`, `02-rbac.yaml` |
| 5. Network | `infra/terraform/vpc.tf` + `infra/k8s/11-networkpolicy.yaml` |
| 6. Data | `infra/terraform/kms.tf`, `rds.tf`, `secrets.tf` + cert-manager + ALB TLS |
| 7. Container | Dockerfiles (non-root, slim) + ECR enhanced scanning + PSS=restricted |
| 8. Monitoring | `guardduty.tf` + EKS control-plane logs + VPC flow logs |
| 9. Threat sim | `threat-sims/` |

## Cost note

This is sized for short demos:

- 2 × `t3.medium` worker nodes
- single NAT gateway
- `db.t3.micro` Postgres
- single-AZ RDS
- 7-day CloudWatch retention

Expect roughly **$0.40–0.60/hr** while running. **`make down` removes
everything** including ECR images (because the repos use `force_delete = true`).

## Known limitations (and what we'd do differently with more time)

- TLS cert is self-signed via cert-manager and imported to ACM — browsers warn.
  In production we'd use ACM-managed certs against a real DNS name and
  Route 53.
- The cluster API endpoint is publicly reachable so we can `kubectl` from
  laptops during the demo. Production setting: `cluster_endpoint_public_access = false`.
- Single NAT gateway is a SPOF. Production: per-AZ NAT.
- `single_nat_gateway = true` and `multi_az = false` on RDS sacrifice
  availability for cost.
