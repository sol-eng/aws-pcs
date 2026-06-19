# AWS PCS HPC Environment

An AWS Parallel Computing Service (PCS) cluster with Posit Workbench, Amazon DCV remote desktop, shared EFS storage, and a PostgreSQL database, deployed via CloudFormation.

## Architecture

```
                                 +---------------------------+
                                 |      AWS PCS Cluster      |
                                 |   (Managed Slurm 25.11)  |
                                 +-------------+-------------+
                                               |
                  +----------------------------+----------------------------+
                  |                                                         |
    +-------------+-------------+                         +----------------+----------------+
    |   Login Node Group (2x)   |                         |   Compute Node Group (0-10x)    |
    |       t3.large            |                         |         t3.large                |
    |   - Posit Workbench :8787 |                         |   - R 4.6.0                     |
    |   - Amazon DCV :8443      |                         |   - Squashfs session mount      |
    |   - R 4.6.0               |                         |   - Fully dynamic (scales to 0) |
    |   - XFCE desktop          |                         |   - Test users (posit001-005)   |
    |   - Test users (posit001) |                         |                                 |
    +-------------+-------------+                         +----------------+----------------+
                  |                                                         |
                  +----------------------------+----------------------------+
                                               |
                              +----------------+----------------+
                              |          Shared EFS             |
                              |   /home  (user directories)    |
                              |   /opt/shared (shared software) |
                              +---------------------------------+

    +------------------+          +------------------+          +------------------+
    |   NLB (optional) |          |   RDS PostgreSQL |          |  NLB Register    |
    |   :22  TCP->22   |          |   db.t4g.micro   |          |  Lambda          |
    |   :443 TLS->8787 |          |   Port 5432      |          |  (EventBridge)   |
    |   :8443 TCP->8443|          |   Encrypted      |          |                  |
    |   Internal       |          |   pwb + pwb_audit|          |                  |
    +------------------+          +------------------+          +------------------+

    +------------------+
    |   S3 Config      |
    |   Bucket         |
    |   (PWB configs)  |
    +------------------+
```

## CloudFormation Stacks

Deployed in this order:

| # | Stack | Template | Description |
|---|-------|----------|-------------|
| 1 | `<name>-rds` | `rds.yaml` | RDS PostgreSQL instance with empty SG (ingress added by PCS stack) |
| 2 | `<name>` | `pcs-cluster.yaml` | Core infrastructure: VPC/SG (optional), EFS, IAM, PCS cluster, login & compute node groups, queues, NLB (optional), RDS SG ingress |
| 3 | `<name>-lb` | `nlb-register.yaml` | Lambda + EventBridge rule to register login node IPs with NLB target groups |

## Prerequisites

- AWS CLI configured with credentials
- An existing VPC with 2 subnets in different AZs
- S3 bucket with Posit Workbench config files (optional)
- ACM certificate (optional, for NLB with TLS)
- Posit Workbench license key

## Deployment

```bash
# Edit configuration at the top of run.sh, then:
./run.sh
```

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `VPC_ID` | Yes | Existing VPC ID |
| `SUBNET_ID1` | Yes | Subnet in AZ 1 (must be in same VPC) |
| `SUBNET_ID2` | Yes | Subnet in AZ 2 (must be in same VPC) |
| `DB_PASSWORD` | Yes | RDS master password (min 8 chars) |
| `PWB_LICENSE` | Yes | Posit Workbench license key |
| `PWB_VERSION` | Yes | Full PWB version (e.g. `2026.05.1-225.pro10`) |
| `PWB_VERSION_SHORT` | Yes | Short PWB version (e.g. `2026.05.1`) |
| `AWS_REGION` | No | Defaults to `us-east-1`. PCS available in: us-east-1, us-east-2, us-west-2, eu-central-1, eu-west-1, ap-northeast-1 |
| `STACK_NAME` | No | Defaults to `hpc-cluster`. Used as prefix for all stack and resource names |
| `SECURITY_GROUP_ID` | No | Existing SG (created if omitted, must allow self-ingress) |
| `CERTIFICATE_ARN` | No | ACM cert ARN to enable NLB with TLS termination |
| `CONFIG_BUCKET` | No | S3 bucket name for Posit Workbench config files |
| `CONFIG_PREFIX` | No | S3 key prefix for configs (default: `config/rstudio`) |

## Stack Details

### rds.yaml

PostgreSQL 18.4 on `db.t4g.micro`. Storage encrypted, single-AZ, not publicly accessible. Deploys with an empty security group — the PCS stack adds the ingress rule allowing access from PCS nodes on port 5432. The first login node creates the `pwb_audit` database at boot.

Instance identifier: `<stack-name>-postgres` (e.g., `michael-rds-postgres`).

### pcs-cluster.yaml

**Networking** (conditional): VPC, subnet, internet gateway, route table, security group with self-referencing ingress rule.

**RDS access**: Adds `AWS::EC2::SecurityGroupIngress` on the RDS SG allowing port 5432 from PCS nodes.

**NLB health checks**: Adds ingress rules from VPC CIDR on ports 22, 8787, and 8443 (conditional on NLB creation).

**EFS**: Single encrypted filesystem with elastic throughput. Two subdirectories mounted on all nodes:
- `/home` - user home directories
- `/opt/shared` - shared software, config, squashfs images

**IAM**: Node role with `pcs:RegisterComputeNodeGroupInstance`, EC2 permissions, SSM managed policy, and S3 read access to the config bucket. Instance profile path `/aws-pcs/`.

**PCS Cluster**: Managed Slurm 25.11 controller (SMALL size: 32 nodes max, 256 jobs max).

**Login Nodes** (2x static):
- Posit Workbench on port 8787
- Amazon DCV (XFCE desktop) on port 8443
- First node syncs S3 config to EFS, generates crypto keys, creates `pwb_audit` DB, builds squashfs image
- All nodes copy config from EFS to `/etc/rstudio/`, generate `database.conf` and `audit-database.conf`
- Systemd drop-in ensures `rstudio-launcher` sources Slurm environment
- PWB license activation and service restart
- Test users posit001–posit005 provisioned

**Compute Nodes** (0-10x dynamic): Scale with Slurm job demand. Mount squashfs session components from EFS. Wait for the image to be built by a login node before mounting. Test users provisioned.

**NLB** (conditional on `CertificateArn`): Internal Network Load Balancer with TCP:22 passthrough, TLS:443 terminating to port 8787, and TCP:8443 passthrough for DCV. Source IP stickiness on all target groups ensures users always reach the same login node (required for DCV sessions which are node-local). HTTPS health check on port 8787 expects HTTP 302.

### nlb-register.yaml

Python 3.12 Lambda triggered by EC2 instance state-change events (running/stopped/terminated). Discovers login nodes by PCS tags and syncs their IPs with NLB target groups (SSH:22, HTTPS:8787, DCV:8443). Also runs once at deploy time via a CloudFormation Custom Resource.

### DCV Sessions

Each test user gets a pre-provisioned virtual DCV session named after their username. Users connect to `https://<NLB-DNS>:8443/#<username>` (e.g., `#posit001`). Sessions are node-local, so source IP stickiness on the NLB ensures users always reach the node hosting their session.

## Configuration

Posit Workbench config files are managed via S3:

1. Upload config files to `s3://<CONFIG_BUCKET>/<CONFIG_PREFIX>/`
2. First login node syncs them to `/opt/shared/rstudio/config/` on EFS
3. First login node also generates `secure-cookie-key` and `launcher.pem`/`launcher.pub`
4. All login nodes copy from EFS to `/etc/rstudio/` at boot
5. `database.conf` and `audit-database.conf` are generated dynamically from RDS parameters

To update configs: update the S3 files and redeploy (or manually trigger on a running node).

## Test Users

Five test users are provisioned on all nodes (login + compute):

| User | UID | Password |
|------|-----|----------|
| posit001 | 2001 | rstudio |
| posit002 | 2002 | rstudio |
| posit003 | 2003 | rstudio |
| posit004 | 2004 | rstudio |
| posit005 | 2005 | rstudio |

## Teardown

Delete stacks in reverse order:

```bash
aws cloudformation delete-stack --stack-name <name>-lb --region <region>
# Wait for above to complete, then:
aws cloudformation delete-stack --stack-name <name> --region <region>
# Wait for above to complete, then:
aws cloudformation delete-stack --stack-name <name>-rds --region <region>
```

## Tags

All EC2 instances are tagged with:
- `rs:project` = solutions
- `rs:environment` = development
- `rs:owner` = michael.mayer@posit.co
