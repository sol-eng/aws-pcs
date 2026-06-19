# Architecture Document

Detailed architecture of the AWS PCS HPC environment including all CloudFormation stacks, network connections, security groups, and interdependencies.

## System Diagram

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                         VPC (existing or created)                                     │
│                                         CIDR: e.g. 10.0.0.0/16                                       │
│                                                                                                      │
│  ┌─────────────────────────────────────────────┐  ┌─────────────────────────────────────────────┐   │
│  │            Subnet 1 (AZ-a)                  │  │            Subnet 2 (AZ-b)                  │   │
│  │                                             │  │                                             │   │
│  │  ┌───────────────────────────────────────┐  │  │                                             │   │
│  │  │   PCS Cluster (Managed Slurm 25.11)   │  │  │                                             │   │
│  │  │   Size: SMALL (32 nodes / 256 jobs)   │  │  │                                             │   │
│  │  │   AWS-managed head node (no access)   │  │  │                                             │   │
│  │  └───────────────────────────────────────┘  │  │                                             │   │
│  │                                             │  │                                             │   │
│  │  ┌─────────────────────┐                    │  │                    ┌─────────────────────┐  │   │
│  │  │   Login Node 1      │                    │  │                    │   Login Node 2      │  │   │
│  │  │   t3.large          │                    │  │                    │   t3.large          │  │   │
│  │  │   :8787 (PWB)       │                    │  │                    │   :8787 (PWB)       │  │   │
│  │  │   :8443 (DCV)       │                    │  │                    │   :8443 (DCV)       │  │   │
│  │  │   :22   (SSH)       │                    │  │                    │   :22   (SSH)       │  │   │
│  │  └─────────────────────┘                    │  │                    └─────────────────────┘  │   │
│  │                                             │  │                                             │   │
│  │  ┌─────────────────────┐                    │  │                    ┌─────────────────────┐  │   │
│  │  │  Compute Nodes      │                    │  │                    │  Compute Nodes      │  │   │
│  │  │  (0-5x dynamic)     │                    │  │                    │  (0-5x dynamic)     │  │   │
│  │  │  t3.large           │                    │  │                    │  t3.large           │  │   │
│  │  └─────────────────────┘                    │  │                    └─────────────────────┘  │   │
│  │                                             │  │                                             │   │
│  │  ┌───────────────────────────────────────┐  │  │  ┌───────────────────────────────────────┐  │   │
│  │  │  NLB ENI                              │  │  │  │  NLB ENI                              │  │   │
│  │  │  (internal, conditional)              │  │  │  │  (internal, conditional)              │  │   │
│  │  │  Listener :22   → TG :22   (TCP)     │  │  │  │  Shared DNS across both AZs          │  │   │
│  │  │  Listener :443  → TG :8787 (TLS)     │  │  │  │                                       │  │   │
│  │  │  Listener :8443 → TG :8443 (TCP)     │  │  │  │                                       │  │   │
│  │  └───────────────────────────────────────┘  │  │  └───────────────────────────────────────┘  │   │
│  │                                             │  │                                             │   │
│  │  ┌───────────────────────────────────────┐  │  │  ┌───────────────────────────────────────┐  │   │
│  │  │  EFS Mount Target 1                   │  │  │  │  EFS Mount Target 2                   │  │   │
│  │  └───────────────────────────────────────┘  │  │  └───────────────────────────────────────┘  │   │
│  │                                             │  │                                             │   │
│  │  ┌───────────────────────────────────────┐  │  │  ┌───────────────────────────────────────┐  │   │
│  │  │  RDS (DB Subnet Group spans both AZs) │  │  │  │  RDS (single-AZ, but subnet group    │  │   │
│  │  │  Primary may be placed here           │  │  │  │  enables failover to either subnet)   │  │   │
│  │  └───────────────────────────────────────┘  │  │  └───────────────────────────────────────┘  │   │
│  └─────────────────────────────────────────────┘  └─────────────────────────────────────────────┘   │
│                                                                                                      │
│  ┌────────────────────────────────────────────────────────────────────────────────────────────┐      │
│  │                            EFS Filesystem (encrypted, elastic)                             │      │
│  │                    :/home → mounted at /home on all nodes (both AZs)                       │      │
│  │                    :/opt-shared → mounted at /opt/shared on all nodes (both AZs)           │      │
│  └────────────────────────────────────────────────────────────────────────────────────────────┘      │
│                                                                                                      │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘

External Services:
┌──────────────────┐   ┌──────────────────┐   ┌──────────────────────────────────────────┐
│  S3 Config       │   │  EventBridge     │   │  Lambda (pcs-nlb-register-<cluster-id>)  │
│  Bucket          │   │  EC2 state-change│──▶│  Syncs login node IPs → NLB TGs          │
│  (PWB configs)   │   │  running/stopped │   │  Also runs via Custom Resource at deploy │
└──────────────────┘   │  terminated      │   └──────────────────────────────────────────┘
                       └──────────────────┘
```

## CloudFormation Stack Details

### Stack 1: `<name>-rds` (rds.yaml)

Deploys first. Creates the database with an empty security group — no ingress rules at creation time.

#### Resources

| Resource | Type | Description |
|----------|------|-------------|
| `RdsSecurityGroup` | `AWS::EC2::SecurityGroup` | Empty SG (ingress added by PCS stack) |
| `DBSubnetGroup` | `AWS::RDS::DBSubnetGroup` | Both subnets for HA placement |
| `RdsInstance` | `AWS::RDS::DBInstance` | PostgreSQL 18.4, db.t4g.micro, gp3, encrypted |

#### Outputs (consumed by PCS stack)

| Output | Usage |
|--------|-------|
| `RdsEndpoint` | Passed to login node UserData for `database.conf` |
| `RdsSecurityGroupId` | PCS stack adds port 5432 ingress from PCS SG |
| `RdsPort` | Reference (always 5432) |

#### Parameters

| Parameter | Source |
|-----------|--------|
| `VpcId` | `$VPC_ID` env var |
| `SubnetId1`, `SubnetId2` | `$SUBNET_ID1`, `$SUBNET_ID2` env vars |
| `DBMasterPassword` | `$DB_PASSWORD` env var |

---

### Stack 2: `<name>` (pcs-cluster.yaml)

Core stack. Creates all compute infrastructure and optionally adds NLB + RDS connectivity.

#### Conditions

| Condition | Trigger | Effect |
|-----------|---------|--------|
| `CreateVpc` | `ExistingVpcId` is empty | Creates VPC, IGW, route table |
| `CreateSubnet` | `ExistingSubnetId1` is empty | Creates subnet in AZ 1 |
| `CreateSecurityGroup` | `ExistingSecurityGroupId` is empty | Creates PCS security group |
| `CreateNlb` | `CertificateArn` is set | Creates NLB, target groups, listeners, health check ingress |
| `HasRds` | `RdsSecurityGroupId` is set | Creates port 5432 ingress on RDS SG |

#### Resources

| Resource | Type | Condition | Description |
|----------|------|-----------|-------------|
| `Vpc` | `AWS::EC2::VPC` | CreateVpc | VPC with DNS support |
| `Subnet` | `AWS::EC2::Subnet` | CreateSubnet | Public subnet in AZ 1 |
| `InternetGateway` | `AWS::EC2::InternetGateway` | CreateVpc | Internet access |
| `GatewayAttachment` | `AWS::EC2::VPCGatewayAttachment` | CreateVpc | IGW→VPC |
| `RouteTable` | `AWS::EC2::RouteTable` | CreateVpc | Route table |
| `DefaultRoute` | `AWS::EC2::Route` | CreateVpc | 0.0.0.0/0 → IGW |
| `SubnetRouteTableAssociation` | `AWS::EC2::SubnetRouteTableAssociation` | CreateSubnet | Subnet→RT |
| `ClusterSecurityGroup` | `AWS::EC2::SecurityGroup` | CreateSecurityGroup | PCS node SG |
| `SecurityGroupSelfIngress` | `AWS::EC2::SecurityGroupIngress` | — | All traffic within SG |
| `NlbSshIngress` | `AWS::EC2::SecurityGroupIngress` | CreateNlb | VPC CIDR → :22 |
| `NlbHttpsIngress` | `AWS::EC2::SecurityGroupIngress` | CreateNlb | VPC CIDR → :8787 |
| `NlbDcvIngress` | `AWS::EC2::SecurityGroupIngress` | CreateNlb | VPC CIDR → :8443 |
| `RdsIngress` | `AWS::EC2::SecurityGroupIngress` | HasRds | PCS SG → RDS SG :5432 |
| `EfsSecurityGroup` | `AWS::EC2::SecurityGroup` | — | NFS from PCS SG |
| `SharedFileSystem` | `AWS::EFS::FileSystem` | — | Encrypted, elastic throughput |
| `EfsMountTarget1` | `AWS::EFS::MountTarget` | — | Subnet 1 |
| `EfsMountTarget2` | `AWS::EFS::MountTarget` | — | Subnet 2 |
| `HomeAccessPoint` | `AWS::EFS::AccessPoint` | — | /home (UID 0, 0755) |
| `OptAccessPoint` | `AWS::EFS::AccessPoint` | — | /opt-shared (UID 0, 0755) |
| `PcsNodeRole` | `AWS::IAM::Role` | — | EC2 + PCS + S3 permissions |
| `PcsInstanceProfile` | `AWS::IAM::InstanceProfile` | — | Path: /aws-pcs/ |
| `LoginLaunchTemplate` | `AWS::EC2::LaunchTemplate` | — | t3.large, UserData |
| `ComputeLaunchTemplate` | `AWS::EC2::LaunchTemplate` | — | t3.large, UserData |
| `PcsCluster` | `AWS::PCS::Cluster` | — | Slurm 25.11, SMALL |
| `LoginNodeGroup` | `AWS::PCS::ComputeNodeGroup` | — | 2x static, both subnets |
| `ComputeNodeGroup` | `AWS::PCS::ComputeNodeGroup` | — | 0-10x dynamic |
| `LoginQueue` | `AWS::PCS::Queue` | — | Slurm queue for login nodes |
| `ComputeQueue` | `AWS::PCS::Queue` | — | Slurm queue for compute nodes |
| `NetworkLoadBalancer` | `AWS::ElasticLoadBalancingV2::LoadBalancer` | CreateNlb | Internal NLB, both subnets |
| `SshTargetGroup` | `AWS::ElasticLoadBalancingV2::TargetGroup` | CreateNlb | IP type, port 22, TCP health, source_ip sticky |
| `HttpsTargetGroup` | `AWS::ElasticLoadBalancingV2::TargetGroup` | CreateNlb | IP type, port 8787, HTTP health (302), source_ip sticky |
| `DcvTargetGroup` | `AWS::ElasticLoadBalancingV2::TargetGroup` | CreateNlb | IP type, port 8443, TCP health, source_ip sticky |
| `SshListener` | `AWS::ElasticLoadBalancingV2::Listener` | CreateNlb | :22 TCP passthrough |
| `HttpsListener` | `AWS::ElasticLoadBalancingV2::Listener` | CreateNlb | :443 TLS → :8787 |
| `DcvListener` | `AWS::ElasticLoadBalancingV2::Listener` | CreateNlb | :8443 TCP passthrough |

#### Key Dependencies

- `PcsCluster` → `DependsOn: SecurityGroupSelfIngress` (SG rule must exist before PCS validates)
- `LoginNodeGroup` / `ComputeNodeGroup` → implicitly depend on `PcsCluster`
- `EfsMountTarget1/2` → must exist before nodes boot (UserData mounts EFS)

#### Outputs (consumed by NLB Lambda stack)

| Output | Usage |
|--------|-------|
| `ClusterId` | Lambda uses to filter EC2 instances by tag |
| `SecurityGroupId` | Reference |
| `NlbDnsName` | User access endpoint |

---

### Stack 3: `<name>-lb` (nlb-register.yaml)

Deploys last. Registers login node IPs with NLB target groups and keeps them in sync.

#### Resources

| Resource | Type | Description |
|----------|------|-------------|
| `RegisterLambdaRole` | `AWS::IAM::Role` | ec2:DescribeInstances, ELB register/deregister |
| `RegisterFunction` | `AWS::Lambda::Function` | Python 3.12, 60s timeout |
| `InstanceStateRule` | `AWS::Events::Rule` | EC2 state-change (running/stopped/terminated) |
| `LambdaInvokePermission` | `AWS::Lambda::Permission` | EventBridge → Lambda |
| `InitialRegistration` | `Custom::RegisterTargets` | Runs Lambda once at deploy time |

#### Parameters (all from PCS stack outputs / resources)

| Parameter | Source |
|-----------|--------|
| `PcsClusterId` | PCS stack output `ClusterId` |
| `LoginNodeGroupId` | Physical resource ID of `LoginNodeGroup` (short ID extracted from ARN) |
| `SshTargetGroupArn` | Physical resource ID of `SshTargetGroup` |
| `HttpsTargetGroupArn` | Physical resource ID of `HttpsTargetGroup` |
| `DcvTargetGroupArn` | Physical resource ID of `DcvTargetGroup` |

---

## Security Groups

### PCS Cluster Security Group

Attached to all PCS nodes (login + compute).

| Rule | Protocol | Port | Source/Dest | Purpose |
|------|----------|------|-------------|---------|
| Self-ingress | All (-1) | All | Self (SG ID) | Inter-node communication (Slurm, NFS) |
| NLB SSH ingress | TCP | 22 | VPC CIDR | NLB health checks + forwarded SSH |
| NLB HTTPS ingress | TCP | 8787 | VPC CIDR | NLB health checks + forwarded PWB |
| NLB DCV ingress | TCP | 8443 | VPC CIDR | NLB health checks + forwarded DCV |
| All egress | All (-1) | All | 0.0.0.0/0 | Internet access (packages, S3, etc.) |

### EFS Security Group

Attached to EFS mount targets.

| Rule | Protocol | Port | Source | Purpose |
|------|----------|------|--------|---------|
| NFS ingress | TCP | 2049 | PCS SG | NFS mounts from all nodes |

### RDS Security Group

Created by `rds.yaml`, ingress managed by `pcs-cluster.yaml`.

| Rule | Protocol | Port | Source | Purpose |
|------|----------|------|--------|---------|
| PostgreSQL ingress | TCP | 5432 | PCS SG | Database access from login nodes |

---

## Network Connections

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Network Flow Diagram                               │
└─────────────────────────────────────────────────────────────────────────────┘

Client (VPC internal)
    │
    ├──── :22 (TCP) ────────→ NLB ──── :22 (TCP) ────────→ Login Nodes (SSH)
    ├──── :443 (TLS) ───────→ NLB ──── :8787 (TCP) ──────→ Login Nodes (PWB)
    └──── :8443 (TCP) ──────→ NLB ──── :8443 (TCP) ──────→ Login Nodes (DCV)

Login Nodes
    │
    ├──── :5432 (TCP) ──────→ RDS PostgreSQL (pwb, pwb_audit databases)
    ├──── :2049 (NFS) ──────→ EFS (/home, /opt/shared)
    ├──── :443 (HTTPS) ─────→ S3 (config sync, first boot only)
    ├──── Slurm protocol ───→ PCS Cluster head node (job scheduling)
    └──── Slurm protocol ───→ Compute Nodes (via SG self-ingress)

Compute Nodes
    │
    ├──── :2049 (NFS) ──────→ EFS (/home, /opt/shared)
    └──── Slurm protocol ───→ PCS Cluster head node (job scheduling)

Lambda (pcs-nlb-register)
    │
    ├──── ec2:DescribeInstances ──→ Finds login nodes by PCS tags
    ├──── elbv2:RegisterTargets ──→ Adds IPs to SSH/HTTPS/DCV target groups
    └──── elbv2:DeregisterTargets → Removes stale IPs

EventBridge
    │
    └──── EC2 state-change (running/stopped/terminated) ──→ Triggers Lambda
```

---

## Inter-Stack Dependencies

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│                           Deployment Order & Data Flow                                │
└──────────────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────┐         ┌──────────────────────┐         ┌──────────────────┐
  │  rds.yaml   │────────▶│   pcs-cluster.yaml   │────────▶│  nlb-register    │
  │  (Stack 1)  │         │      (Stack 2)       │         │   (Stack 3)      │
  └─────────────┘         └──────────────────────┘         └──────────────────┘
        │                          │                              │
        │                          │                              │
   Outputs:                   Consumes from RDS:            Consumes from PCS:
   • RdsEndpoint              • RdsSecurityGroupId          • ClusterId
   • RdsSecurityGroupId       • RdsEndpoint                 • LoginNodeGroup ARN
   • RdsPort                  • RdsPassword                 • SshTargetGroupArn
                                                            • HttpsTargetGroupArn
                              Creates:                      • DcvTargetGroupArn
                              • RdsIngress (→ RDS SG)
                              • All compute infra
                              • NLB + target groups

  run.sh extracts:
  • RDS outputs via `describe-stacks`
  • VPC_CIDR via `describe-vpcs`
  • LoginNodeGroupId via `describe-stack-resources` (ARN → short ID: ${ARN##*/})
  • Target group ARNs via `describe-stack-resources`
```

---

## Login Node Boot Sequence

```
┌────────────────────────────────────────────────────────────────────────┐
│                    Login Node UserData Flow                             │
└────────────────────────────────────────────────────────────────────────┘

  1. sleep 120s (wait for PCS agent / cloud-init)
  2. until apt-get update (retry loop for apt lock)
  3. Install nfs-common, amazon-efs-utils
  4. Mount EFS root → create /home, /opt-shared dirs → unmount
  5. Mount /home and /opt/shared from EFS subdirs
  6. Add to /etc/fstab
  7. Install R 4.6.0
  8. Install Posit Workbench
  9. Create systemd drop-in for rstudio-launcher (sources slurm.sh)

  ┌─── S3 Sync Lock (mkdir /opt/shared/.s3-sync-lock) ─── FIRST NODE ONLY ───┐
  │ 10. aws s3 sync config to /opt/shared/rstudio/config/                     │
  │ 11. Generate secure-cookie-key (uuidgen)                                  │
  │ 12. Generate launcher.pem + launcher.pub (openssl RSA 2048)               │
  │ 13. Create pwb_audit database on RDS (psql)                               │
  │ 14. touch /opt/shared/.s3-sync-complete                                   │
  └───── Other nodes: wait for .s3-sync-complete ─────────────────────────────┘

  15. Provision test users (posit001-005, UID 2001-2005)
  16. Copy /opt/shared/rstudio/config/* → /etc/rstudio/
  17. Generate database.conf and audit-database.conf

  ┌─── Squashfs Lock (mkdir /opt/shared/.squashfs-lock) ── FIRST NODE ONLY ───┐
  │ 18. Download rsp-session tarball                                           │
  │ 19. Extract and mksquashfs → .sqsh file on EFS                            │
  │ 20. touch /opt/shared/.squashfs-complete                                   │
  └───── Other nodes: wait for .squashfs-complete ────────────────────────────┘

  21. Install XFCE desktop (xfce4, xfce4-goodies, dbus-x11)
  22. Install Amazon DCV (server + web-viewer + xdcv)
  23. Configure DCV (dcv.conf: port 8443, system auth, virtual sessions)
  24. systemctl enable/start dcvserver
  25. Create per-user DCV sessions (posit001–posit005, each owns their named session)
  26. Activate PWB license
  27. Restart rstudio-launcher and rstudio-server
```

---

## Compute Node Boot Sequence

```
┌────────────────────────────────────────────────────────────────────────┐
│                   Compute Node UserData Flow                            │
└────────────────────────────────────────────────────────────────────────┘

  1. sleep 120s (wait for PCS agent / cloud-init)
  2. until apt-get update (retry loop for apt lock)
  3. Install nfs-common, amazon-efs-utils
  4. Mount EFS root → ensure dirs → unmount
  5. Mount /home and /opt/shared
  6. Add to /etc/fstab
  7. Install R 4.6.0
  8. Provision test users (posit001-005, UID 2001-2005)
  9. Wait for squashfs image on EFS (polling loop)
  10. Mount squashfs at /usr/lib/rstudio-server (ro,loop)
  11. Add to /etc/fstab
```

---

## IAM Permissions

### PCS Node Role (`AWSPCSNodeRole-<cluster-name>`)

| Permission | Resource | Purpose |
|------------|----------|---------|
| `pcs:RegisterComputeNodeGroupInstance` | `*` | PCS node registration |
| `ec2:RunInstances` | `*` | PCS node management |
| `ec2:CreateTags` | `*` | Tag created instances |
| `ec2:DescribeInstances` | `*` | Instance discovery |
| `ec2:DescribeInstanceStatus` | `*` | Status checks |
| `ec2:TerminateInstances` | `*` | Scale-down |
| `ec2:DescribeSubnets` | `*` | Networking |
| `ec2:DescribeSecurityGroups` | `*` | SG lookups |
| `ec2:DescribeLaunchTemplates` | `*` | LT access |
| `ec2:DescribeLaunchTemplateVersions` | `*` | LT versions |
| `s3:GetObject` | `arn:aws:s3:::<bucket>/*` | Config file download |
| `s3:ListBucket` | `arn:aws:s3:::<bucket>` | Bucket listing |
| SSM Managed Policy | — | Systems Manager access |

### Lambda Role (`pcs-nlb-register-<cluster-id>`)

| Permission | Resource | Purpose |
|------------|----------|---------|
| `ec2:DescribeInstances` | `*` | Find login nodes by PCS tags |
| `elasticloadbalancing:DescribeTargetHealth` | `*` | Get current targets (no resource support) |
| `elasticloadbalancing:RegisterTargets` | Specific TG ARNs | Add IPs |
| `elasticloadbalancing:DeregisterTargets` | Specific TG ARNs | Remove IPs |
| Lambda basic execution | — | CloudWatch Logs |

---

## NLB Target Groups & Health Checks

| Target Group | Port | Protocol | Health Check | Success Criteria | Stickiness |
|--------------|------|----------|--------------|-----------------|------------|
| SSH | 22 | TCP | TCP:22 | Connection success | Source IP |
| HTTPS (PWB) | 8787 | TCP | HTTP:8787 / | HTTP 302 response | Source IP |
| DCV | 8443 | TCP | TCP:8443 | Connection success | Source IP |

All target groups use IP-based targeting with source IP stickiness enabled. Stickiness is critical for DCV (sessions are node-local) and beneficial for PWB (session continuity). Targets are managed by the Lambda function (not CloudFormation).

---

## EFS Mount Structure

```
EFS Filesystem (encrypted, elastic throughput)
├── /home          → mounted at /home on all nodes
│   ├── posit001/
│   ├── posit002/
│   ├── posit003/
│   ├── posit004/
│   └── posit005/
└── /opt-shared    → mounted at /opt/shared on all nodes
    ├── .s3-sync-lock       (transient, mkdir-based lock)
    ├── .s3-sync-complete   (flag file)
    ├── .squashfs-lock      (transient, mkdir-based lock)
    ├── .squashfs-complete  (flag file)
    └── rstudio/
        ├── config/
        │   ├── (synced from S3)
        │   ├── secure-cookie-key  (generated, 0600)
        │   ├── launcher.pem       (generated, 0600)
        │   └── launcher.pub       (generated)
        └── session-components/
            ├── downloads/
            │   └── rsp-session-jammy-<version>-amd64.tar.gz
            └── rsw-session-<version>.sqsh
```

---

## S3 Config Pipeline

```
S3: s3://<CONFIG_BUCKET>/<CONFIG_PREFIX>/
    ├── rserver.conf
    ├── rsession.conf
    ├── launcher.conf
    ├── jupyter.conf (optional)
    └── ... (any PWB config files)

         │  (aws s3 sync, first login node only)
         ▼

EFS: /opt/shared/rstudio/config/
    ├── (all files from S3)
    ├── secure-cookie-key  (generated on first boot)
    ├── launcher.pem       (generated on first boot)
    └── launcher.pub       (generated on first boot)

         │  (cp -r, all login nodes)
         ▼

Login Node: /etc/rstudio/
    ├── (all files from EFS config dir)
    ├── database.conf       (generated dynamically from RDS params)
    └── audit-database.conf (generated dynamically from RDS params)
```
