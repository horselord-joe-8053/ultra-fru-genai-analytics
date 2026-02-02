# VPC & Terraform Crash Course (Dummy-Style)

A short, visual crash course that bridges two gaps: **cloud (AWS VPC)** and **Terraform/Terragrunt (state, locks, plan/apply/destroy)**. Ends with how our **RDS subnet group / VPC mismatch** ties them together.

**Context:** Useful for AWS Certified ML Engineer – Associate and Google Professional ML Engineer (concepts transfer to GCP VPC + Terraform).

**See also:** [TERRA_LEARNED.md](TERRA_LEARNED.md) (Terraform layers), [DEPLOYMENT_ERRORS_AND_FIXES.md](../DEPLOYMENT_ERRORS_AND_FIXES.md), [README_WAR_STORIES.md](../../README_WAR_STORIES.md).

---

## Part 1: AWS VPC — The Cloud Side

### 1.1 What is a VPC?

A **VPC (Virtual Private Cloud)** is your own isolated slice of the AWS (or GCP) network. Nothing in another customer's VPC can talk to yours unless you explicitly allow it (peering, etc.).

- **One VPC** = one logical network (IP range, e.g. `10.0.0.0/16`).
- **Region-scoped:** Each VPC lives in one region; you can have multiple VPCs per region per account.

### 1.2 VPC → Subnets → Resources (Dependency Order)

Resources live **inside** a VPC. Many of them live in **subnets**, which are chunks of the VPC's IP range (e.g. `10.0.1.0/24`, `10.0.2.0/24`). Subnets are often split into **public** (internet-facing) and **private** (no direct internet; e.g. DBs, app servers).

**Rule:** A subnet belongs to **exactly one VPC**. A resource (RDS, EKS, ENI) that uses subnets must use subnets from **the same VPC**. You cannot "move" a DB subnet group to another VPC by changing its subnet IDs.

Dependency order (who depends on whom) looks like this:

```mermaid
flowchart TB
    subgraph vpc["🔵 VPC (one network)"]
      subgraph subnets["🟢 Subnets (chunks of VPC IP range)"]
        pub["Public subnet A"]
        priv["Private subnet B"]
      end
      sg["Security groups"]
      igw["Internet Gateway"]
    end

    subgraph resources["🟠 Resources that use subnets"]
      eni["ENIs (network interfaces)"]
      alb["ALB / NLB"]
      rds_sg["RDS DB Subnet Group"]
      aurora["Aurora / RDS"]
    end

    vpc --> subnets
    subnets --> eni
    subnets --> rds_sg
    eni --> alb
    rds_sg --> aurora
    sg --> eni
    sg --> aurora
```

**Takeaway:**  
VPC → Subnets → things that live in subnets (ENIs, **DB subnet group**, etc.) → higher-level resources (ALB, **RDS/Aurora**). RDS needs a **DB subnet group**; that group can only list subnets from **one VPC**. So: one VPC → one set of subnets → one DB subnet group → one Aurora cluster, all tied together.

### 1.3 Why Teardown Order Matters

You can't delete a VPC while something still depends on it (subnets, ENIs, security groups, etc.). So **teardown order** is the reverse of creation:

1. Delete resources that use subnets (Aurora, then DB subnet group; ALBs; EKS; etc.).
2. Release ENIs (often after ALB/EKS deletion; AWS may take 10–30 min — see [War Story 7: ELB ENIs](../../README_WAR_STORIES.md#7-elb-deletion-and-enis-eventual-consistency-not-a-bug)).
3. Delete VPC endpoints, then subnets, then security groups, then the VPC.

See [War Story 6: VPC teardown dependency order](../../README_WAR_STORIES.md#6-vpc-teardown-dependency-order-enis-and-vpc-endpoints) for the full graph and script order.

### 1.4 One Picture: "Healthy" Single-VPC Setup

```mermaid
flowchart LR
    subgraph aws["AWS Account"]
      subgraph vpc1["VPC A (e.g. 10.0.0.0/16)"]
        sub1["Subnet 1"]
        sub2["Subnet 2"]
        sg_db["DB Subnet Group"]
        aurora["Aurora"]
      end
    end

    vpc1 --> sub1
    vpc1 --> sub2
    sub1 --> sg_db
    sub2 --> sg_db
    sg_db --> aurora

    style vpc1 fill:#cce5ff
    style sg_db fill:#ffe5cc
    style aurora fill:#e5ffcc
```

All in one VPC → no mismatch.

---

## Part 2: Terraform & Terragrunt — The IaC Side

### 2.1 Plan, Apply, Destroy (One-Way Flow)

Terraform manages **desired state** in code (`.tf` files). It compares that to **actual state** and makes AWS match the code.

| Command   | What it does |
|----------|----------------|
| **plan** | "What would change?" — reads state + code, prints diff. Does **not** change AWS or state. |
| **apply** | "Make it so." — runs plan, then applies changes to AWS and **writes new state**. |
| **destroy** | "Delete everything in state." — removes resources in AWS and **removes them from state**. |

```mermaid
flowchart LR
    code["📄 .tf code\n(desired state)"]
    state["📦 State\n(what TF thinks exists)"]
    aws["☁️ AWS\n(what actually exists)"]

    plan["plan"]
    apply["apply"]
    destroy["destroy"]

    code --> plan
    state --> plan
    plan --> apply
    apply --> state
    apply --> aws
    state --> destroy
    destroy --> aws

    style code fill:#e5ccff
    style state fill:#ffcce5
    style aws fill:#cce5ff
```

**Takeaway:**  
State is Terraform's **memory** of what it created. If state and AWS get out of sync (e.g. something deleted outside Terraform, or a new VPC created with different state), the next plan/apply can do surprising things (e.g. try to "update" a resource that actually lives in another VPC).

### 2.2 Where State Lives (Remote + Lock)

State is usually stored **remotely** (e.g. S3 bucket) so the team shares one source of truth. Terragrunt configures this (e.g. `remote_state` in `root.hcl`).

**Problem:** Two people (or two runs) must not write state at the same time. So Terraform uses a **lock**:

1. Before **apply** or **destroy**, Terraform tries to **acquire a lock** on the state (e.g. in S3/DynamoDB).
2. If someone else holds the lock (or a previous run crashed and never released it), you get **"Error acquiring the state lock"**.
3. You must **force-unlock** (after confirming no other run is active) or wait for the lock to expire.

```mermaid
flowchart TB
    subgraph your_run["Your run"]
      A["terraform apply/destroy"]
      B["Acquire lock?"]
      C["Write state"]
      D["Release lock"]
    end

    subgraph backend["Remote backend (e.g. S3)"]
      lock["🔒 Lock\n(per state file)"]
      state_file["State file"]
    end

    A --> B
    B -->|"yes"| C
    B -->|"no → Error"| E["Fail: state lock"]
    C --> D
    D --> state_file
    B --> lock

    style lock fill:#ffcccc
    style state_file fill:#ffcce5
    style E fill:#ff6666
```

**Recovery:**  
`terragrunt force-unlock <LOCK_ID>` (and type `yes`, or `echo yes | terragrunt force-unlock <LOCK_ID>`). See [War Story 17: State lock and fail-fast](../../README_WAR_STORIES.md#17-preempt-teardown-state-lock-failure-and-teardown-reporting-success-on-failure).

### 2.3 Terragrunt in One Sentence

**Terragrunt** wraps Terraform: it keeps **per-layer** config (e.g. `dev/eks`, `dev/infrastructure`), pulls shared config (backend, account ID), and runs `terraform` in the right order. So "teardown EKS" = run `terragrunt destroy` in the EKS layer directory; state and lock are **per layer** (one state file per layer). See [TERRA_LEARNED.md](TERRA_LEARNED.md) for what a "layer" is.

---

## Part 3: The Mismatch — Tying VPC and Terraform Together

### 3.1 What Went Wrong (Two VPCs, One Subnet Group)

In code, **one** Terraform module creates: VPC → subnets → DB subnet group → Aurora. So in a single apply, everything is in one VPC. The mismatch happens when **reality** and **state** diverge:

1. **Past:** A run created **VPC A** and the **DB subnet group** (using VPC A's subnets) and Aurora. State recorded: "I own VPC A, these subnets, this subnet group, this Aurora."
2. **Later:** State was lost or a different state was used (e.g. new state bucket, or state reset). Terraform ran again and created **VPC B** and **new subnets**.
3. **Now:** In AWS you still have the **old DB subnet group** (and maybe Aurora) tied to **VPC A**. In **state** Terraform thinks it owns **VPC B** and subnets in VPC B.
4. **Apply:** Terraform tries to **update** the DB subnet group (same resource name in state) to use **VPC B's subnets**. AWS says: "The new subnets are not in the same VPC as the existing subnet group." **Error.**

```mermaid
flowchart TB
    subgraph state["📦 Terraform state (thinks)"]
      state_vpc["VPC B"]
      state_sub["Subnets B"]
      state_sg["DB Subnet Group\n(subnet_ids → B)"]
    end

    subgraph aws["☁️ AWS (reality)"]
      vpc_a["VPC A"]
      vpc_b["VPC B"]
      sub_a["Subnets A"]
      sub_b["Subnets B"]
      sg_real["DB Subnet Group\n(actually uses Subnets A)"]
      aurora_real["Aurora"]
    end

    state_vpc --> state_sub
    state_sub --> state_sg
    vpc_a --> sub_a
    vpc_b --> sub_b
    sub_a --> sg_real
    sg_real --> aurora_real

    apply["apply: set subnet group\n→ Subnets B"]
    apply -.->|"AWS: No! Subnet group\nis in VPC A"| conflict["❌ Error"]

    state_sg --> apply
    apply --> conflict

    style state fill:#ffcce5
    style aws fill:#cce5ff
    style sg_real fill:#ffe5cc
    style conflict fill:#ff6666
```

So: **cloud rule** (subnet group must stay in one VPC) + **Terraform behavior** (update resource from state using new subnet IDs) = error when state points at a different VPC than the one the live resource uses.

### 3.2 How We Fix It (Align State and Reality)

- **Option A — Clean slate:** Tear down **everything** Terraform manages for that env (including **shared** infra: VPC, Aurora, DB subnet group), then apply again. That removes the old subnet group and creates one new VPC + new subnet group + new Aurora. So state and AWS match again. (Our preempt now uses `--container-type all` so shared is destroyed too; see [War Story 16](../../README_WAR_STORIES.md#16-phase-2-infrastructure-rds-subnet-group-vpc-mismatch).)
- **Option B — Import:** If you want to **keep** the existing VPC/subnet group in AWS, import them into Terraform state so Terraform "owns" that VPC and those subnets; then it won't try to create a second VPC or change the subnet group to another VPC.

### 3.3 One Diagram: Before vs After Fix (Clean Slate)

```mermaid
flowchart LR
    subgraph before["Before (broken)"]
      s1["State: VPC B"]
      a1["AWS: VPC A + subnet group"]
      a2["AWS: VPC B"]
      x["❌ Apply tries to point\nsubnet group at VPC B"]
    end

    subgraph after["After (clean slate)"]
      s2["State: empty or new"]
      a3["AWS: one VPC + one subnet group + Aurora"]
      ok["✅ Apply creates one VPC,\none subnet group, Aurora"]
    end

    before --> after
    s1 --> x
    a1 --> x
    s2 --> ok
    a3 --> ok

    style x fill:#ff6666
    style ok fill:#66ff66
```

---

## Quick Reference

| Topic | Idea |
|-------|------|
| **VPC** | Isolated network; subnets are chunks of it; resources (e.g. RDS subnet group) must use subnets from **one** VPC. |
| **Teardown order** | Reverse of creation: delete DB/subnet group, ENIs, then subnets/VPC; ENIs can lag after ALB/EKS delete ([War Story 6](../../README_WAR_STORIES.md#6-vpc-teardown-dependency-order-enis-and-vpc-endpoints), [7](../../README_WAR_STORIES.md#7-elb-deletion-and-enis-eventual-consistency-not-a-bug)). |
| **State** | Terraform's list of what it manages; stored remotely (e.g. S3); must stay in sync with AWS. |
| **Lock** | Prevents two applies/destroys from writing state at once; stale lock → "Error acquiring the state lock" → `force-unlock <ID>` ([War Story 17](../../README_WAR_STORIES.md#17-preempt-teardown-state-lock-failure-and-teardown-reporting-success-on-failure)). |
| **Mismatch** | State says "VPC B"; live DB subnet group is in VPC A → apply fails. Fix: align state and reality (full teardown or import) ([War Story 16](../../README_WAR_STORIES.md#16-phase-2-infrastructure-rds-subnet-group-vpc-mismatch)). |

---

*This doc: `docs/learned/VPC_LEARNED.md`. Layers: [TERRA_LEARNED.md](TERRA_LEARNED.md). War stories: [README_WAR_STORIES.md](../../README_WAR_STORIES.md). Deployment errors: [DEPLOYMENT_ERRORS_AND_FIXES.md](../DEPLOYMENT_ERRORS_AND_FIXES.md).*
