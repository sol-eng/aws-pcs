# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AWS PCS (Parallel Computing Service) HPC environment deployed via CloudFormation. Provisions a Slurm-based cluster with Posit Workbench (RStudio Server) and Amazon DCV (remote desktop) on login nodes, R on compute nodes, backed by shared EFS storage and an RDS PostgreSQL database.

## Deployment

```bash
# Full deploy (RDS + PCS)
./run.sh
```

Configuration is set via environment variables at the top of `run.sh`. Key variables:
- `VPC_ID`, `SUBNET_ID1`, `SUBNET_ID2` — existing networking (both subnets must be in the same VPC, different AZs)
- `SECURITY_GROUP_ID` — optional; one is created if omitted
- `CERTIFICATE_ARN` — set to enable NLB with TLS termination and Lambda target registration
- `DB_PASSWORD` — required for RDS stack
- `AWS_REGION` — defaults to `us-east-1`; PCS supported in: us-east-1, us-east-2, us-west-2, eu-central-1, eu-west-1, ap-northeast-1
- `STACK_NAME` — CloudFormation stack name prefix (used for all stacks and resource naming)
- `CONFIG_BUCKET` — S3 bucket containing Posit Workbench config files
- `CONFIG_PREFIX` — S3 key prefix within the bucket (default: `config/rstudio`)
- `PWB_LICENSE` — Posit Workbench license key
- `PWB_VERSION` / `PWB_VERSION_SHORT` — full and short PWB version strings

Deployment order: RDS → PCS. The PCS stack adds the RDS security group ingress rule and (if NLB enabled) deploys Lambda for target registration.

To delete stacks in reverse order: `<name>` → `<name>-rds`.

## Architecture

```
run.sh  (orchestrator — deploys stacks sequentially, passes outputs between them)
  ├── rds.yaml           (RDS PostgreSQL, deploys first with empty SG)
  └── pcs-cluster.yaml   (main stack: VPC/SG/EFS/IAM/PCS cluster/node groups/queues/NLB/Lambda, adds RDS SG ingress)
```

**PCS Cluster (head node)**: Managed Slurm 25.11 controller (SMALL size: 32 nodes, 256 jobs max). No user access — AWS-managed.

**Login nodes** (2x t3.large, static): Run Posit Workbench on port 8787 and Amazon DCV on port 8443. First node syncs config from S3, generates crypto keys (secure-cookie-key, launcher.pem/pub), creates `pwb_audit` DB, and builds squashfs image on EFS via lock-file patterns; second waits. UserData installs R, PWB, XFCE, DCV, postgresql-client, activates PWB license, provisions test users.

**Compute nodes** (0–10 t3.xlarge, dynamic): Scale with Slurm job demand. Mount squashfs from EFS at `/usr/lib/rstudio-server`. UserData installs R and provisions test users.

**EFS**: Single filesystem with two mount paths — `/home` (user dirs) and `/opt/shared` (shared software, squashfs images, config). Mounted on all nodes via NFS in UserData.

**RDS**: PostgreSQL 18.4 on db.t4g.micro. Databases: `pwb` (main) and `pwb_audit` (created by first login node). Security group ingress managed by PCS stack. Instance ID: `<stack-name>-rds-postgres`.

**NLB** (conditional on `CertificateArn`): Internal, three listeners — TCP:22 passthrough for SSH, TLS:443 terminating to port 8787 for Workbench, TCP:8443 passthrough for DCV. Source IP stickiness on all target groups (required for DCV sessions which are node-local). Health check ingress rules from VPC CIDR on ports 22, 8787, 8443.

**DCV** (Amazon DCV): Installed on login nodes with XFCE desktop. Per-user virtual sessions (posit001–posit005) in software-rendering mode (no GPU). Users connect via DCV client or web browser on port 8443. Authentication uses system PAM.

**Lambda** (conditional on `CertificateArn`, inside `pcs-cluster.yaml`): Triggered by EC2 state-change events. Discovers login nodes by PCS tags (`aws:pcs:cluster-id`, `aws:pcs:compute-node-group-id`), syncs IPs with target groups (SSH:22, HTTPS:8787, DCV:8443). Also runs on initial deployment via Custom Resource.

**S3 Config**: Posit Workbench config files stored in S3, synced to `/opt/shared/rstudio/config/` on EFS by the first login node, then copied to `/etc/rstudio/` on all login nodes at boot. Database config (`database.conf`, `audit-database.conf`) is generated dynamically from RDS parameters.

**Test users**: posit001–posit005 (UID 2001–2005, password "rstudio") provisioned on all nodes.

## CloudFormation Quirks (eu-west-1)

- `AWS::EFS::FileSystem` and `AWS::EFS::AccessPoint` do NOT accept `Tags` property — will fail with "extraneous key [Tags] is not permitted"
- PCS cluster requires `DependsOn: SecurityGroupSelfIngress` to ensure the SG inbound rule exists before validation
- Self-referencing SG ingress must use a separate `AWS::EC2::SecurityGroupIngress` resource (not inline) to avoid circular dependencies
- PCS node IAM role must have path `/aws-pcs/` or name starting with `AWSPCS`
- PCS node role needs `ec2:RunInstances` and related EC2 permissions beyond just `pcs:RegisterComputeNodeGroupInstance`
- `aws pcs` CLI subcommand may not be available — use CloudFormation resource lookups instead
- `elasticloadbalancing:DescribeTargetHealth` does not support resource-level permissions — must use `Resource: '*'`
- NLB health checks originate from NLB ENI IPs (within VPC CIDR), NOT from the PCS security group — need separate VpcCidr ingress rules

## UserData Conventions

- Use `${!VAR}` to escape bash variables from CloudFormation `!Sub` interpolation
- Bootstrap logs go to `/var/log/pcs-login-init.log` and `/var/log/pcs-compute-init.log`
- 2-minute sleep at start to allow PCS agent / cloud-init to finish
- `apt-get update` wrapped in `until` retry loop (handles apt lists lock contention from cloud-init/PCS agent)
- `-o DPkg::Lock::Timeout=300` on `apt-get update` covers dpkg lock; `until` loop covers apt lists lock
- Two separate lock-file sections on login nodes (use `mkdir` for atomic NFS-safe lock):
  - S3 config sync: lock=`/opt/shared/.s3-sync-lock`, done=`/opt/shared/.s3-sync-complete`
  - Squashfs build: lock=`/opt/shared/.squashfs-lock`, done=`/opt/shared/.squashfs-complete`
- AMI is Ubuntu 24.04 based (`aws-pcs-ready-dlami-base-ubuntu2404-x86_64`), UserData uses `apt-get`
- MIME multipart format required by PCS (Content-Type: multipart/mixed; boundary="==BOUNDARY==")
- `rstudio-launcher` service uses a systemd drop-in override to source `/etc/profile.d/slurm.sh`
- DCV config uses `printf '%s\n'` (not heredoc) to avoid indentation issues inside `!Sub |` blocks
- Lock-file sections must release the lock via `trap ... EXIT` and give waiters a timeout that reclaims a stale lock — under `set -euo pipefail`, a build failure otherwise leaves the lock (e.g. `.squashfs-lock`) stuck on EFS forever, deadlocking every future boot of every node on that wait loop (symptom looks unrelated, e.g. "license activation never runs" because it's sequenced after the lock section)

## Tagging

All EC2 instances get: `rs:project=solutions`, `rs:environment=development`, `rs:owner=michael.mayer@posit.co`
