# Terra + Terragrunt: Total Map and Pipeline (Crash Course)

This doc is the **structural map** of how we use Terraform and Terragrunt in this project: where files live, what gets generated, and how that drives the cloud. For **layers**, **deploy order**, **Option B**, and **teardown**, see [TERRA_LEARNED.md](TERRA_LEARNED.md).

**Goals:** (1) One place for the full pipeline from repo layout → cache → Terraform → AWS. (2) Terraform-only vs Terragrunt usage. (3) The role of `//`, leaf vs root modules, and generated artifacts. Examples are from this repo.

**Guide to sections:** §1 = total mapping and structure; §2 = Terraform without Terragrunt, then with Terragrunt; §3 = full pipeline (environments/, _component/, modules/ → generated cache and files → cloud); §3.2 = generated files (cache dir, lock files, backend.tf, provider.tf); §4 = `//` and leaf vs composition/root modules.

---

## 1. Where Terra lives in this project (total mapping)

### 1.1 The five `terra` trees

We have five separate Terra/Terragrunt trees. Each has the same **layout pattern**: `environments/<env>/<layer>/` (Terragrunt config) and `modules/` (Terraform `.tf` source). After the refactor, core infra, long-term (Secrets Manager), and frontend (S3 + CloudFront) each have their own tree.

```mermaid
%%{init: {'themeVariables': {'fontSize': '9px'}}}%%
flowchart LR
  subgraph basic["module_infra_basic/aws/terra"]
    B_env[environments/dev, prod]
    B_mod[modules/]
    B_comp[_component/]
    B_env --- B_mod
    B_env --- B_comp
  end
  subgraph longterm["module_infra_longterm/aws/terra"]
    L_env[environments/dev, prod]
    L_mod[modules/secrets-manager]
    L_comp[_component/]
    L_env --- L_mod
    L_env --- L_comp
  end
  subgraph frontend["module_infra_frontend/aws/terra"]
    F_env[environments/dev, prod]
    F_mod[modules/frontend]
    F_comp[_component/]
    F_env --- F_mod
    F_env --- F_comp
  end
  subgraph kube["module_infra_kubetypes/kube/aws/terra"]
    K_env[environments/dev, prod]
    K_mod[modules/root_eks]
    K_comp[_component/]
    K_env --- K_mod
    K_env --- K_comp
  end
  subgraph nonkube["module_infra_kubetypes/nonkube/aws/terra"]
    N_env[environments/dev, prod]
    N_mod[modules/root_ecs, alb]
    N_comp[_component/]
    N_env --- N_mod
    N_env --- N_comp
  end
  style basic fill:#e3f2fd
  style longterm fill:#e8f5e9
  style frontend fill:#f3e5f5
  style kube fill:#fff3e0
  style nonkube fill:#fce4ec
```

| Tree | Purpose | Example layers (dev) | Example modules |
|------|--------|----------------------|-----------------|
| **module_infra_basic/aws/terra/** | Core infra (VPC, Aurora, IAM, S3 data) | infrastructure | root_infrastructure, vpc, aurora, iam, s3-data |
| **module_infra_longterm/aws/terra/** | Long-term resources (Secrets Manager) | infrastructure-longterm | secrets-manager |
| **module_infra_frontend/aws/terra/** | Frontend (S3 + CloudFront) | frontend-eks, frontend-ecs | frontend |
| **module_infra_kubetypes/kube/aws/terra/** | EKS app | eks | root_eks |
| **module_infra_kubetypes/nonkube/aws/terra/** | ECS app | ecs | root_ecs, alb |

### 1.2 One layer = one directory under `environments/<env>/`

- **Path:** e.g. `module_infra_basic/aws/terra/environments/dev/infrastructure/` (or `module_infra_frontend/.../frontend-eks`, `module_infra_longterm/.../infrastructure-longterm`, etc.)
- **Contents:** `terragrunt.hcl` (required), often `.terraform.lock.hcl` (provider versions).
- **Meaning:** Running `terragrunt apply` (or `plan`/`destroy`) in that directory applies **one layer** and uses **one state file** (e.g. S3 key `dev/infrastructure/terraform.tfstate`). See [TERRA_LEARNED.md §1](TERRA_LEARNED.md#1-what-is-a-layer).

### 1.3 Shared building blocks: `root.hcl`, `env.hcl`, `_component/*.hcl`

- **root.hcl** (at `environments/root.hcl` in each tree): Defines remote state (S3), state key via `path_relative_to_include()`, and **generates** `backend.tf` and `provider.tf` in the working directory so Terraform talks to S3 and AWS.
- **env.hcl** (per env, e.g. `environments/dev/env.hcl`): Shared inputs for that environment (project_name, vpc_cidr, etc.).
- **_component/** (e.g. `_component/infrastructure-base.hcl`): Per-**layer type** template: sets `terraform { source = "..." }`, `download_dir`, and `inputs` for that layer. Each layer dir’s `terragrunt.hcl` **includes** root + the right component (e.g. `infrastructure-base.hcl` for the infrastructure layer).

Example: `environments/dev/infrastructure/terragrunt.hcl` includes root and `../../_component/infrastructure-base.hcl`. The component sets `source = ".../modules//root_infrastructure"` and passes inputs from `env.hcl`.

---

## 2. Terraform without Terragrunt (conceptual baseline)

### 2.1 Pure Terraform flow

1. You have a directory with `.tf` files (the “root module”).
2. You run `terraform init` → downloads providers, (if backend is remote) configures state.
3. You run `terraform plan` / `terraform apply` → Terraform builds a graph, talks to the provider (e.g. AWS), and creates/updates/deletes resources.
4. **State** (e.g. in S3) records what Terraform created so the next run can diff and update.

No notion of “layers”: one directory = one state. To get multiple states you’d run Terraform in different directories (or use workspaces), and you’d repeat backend/provider config and variable wiring yourself.

### 2.2 What Terragrunt adds (high level)

- **Layers:** One Terragrunt config per “layer” (e.g. `dev/infrastructure`). Each layer = one state, one apply/destroy.
- **Source:** Points Terraform at the right **module** (e.g. `modules//root_infrastructure`). Terragrunt **copies** that source into a cache and runs Terraform there.
- **Generated files:** Terragrunt generates `backend.tf`, `provider.tf` (and optionally more) in the cache so you don’t hand-write them per layer.
- **Inputs:** Pass variables from HCL (env, component, layer) into the module as Terraform variables.
- **Dependencies:** Optional `dependency` blocks so one layer can read another’s outputs (e.g. EKS layer depends on infrastructure for `vpc_id`, subnets).

So: **Terraform** does the actual cloud API calls; **Terragrunt** decides where to run it, what module to use, where state lives, and what inputs to pass.

---

## 3. Terraform with Terragrunt: the full pipeline

### 3.1 What you run

From the repo root (or via `orchestration/terraform/deploy.sh`):

- `cd` into a layer directory, e.g. `module_infra_basic/aws/terra/environments/dev/infrastructure`
- Run `terragrunt plan` or `terragrunt apply`

Terragrunt then (in order):

1. **Resolves includes** (root, component, env).
2. **Resolves `terraform { source }`** and **download_dir**.
3. **Copies** the module source into the cache (see §3.2).
4. **Generates** `backend.tf`, `provider.tf` in the cache (from root.hcl).
5. **Injects inputs** into the module (e.g. via `terraform.tfvars` or mechanism Terragrunt uses).
6. Runs **terraform init** (in the cache) → providers, backend.
7. Runs **terraform plan** / **apply** (in the cache) → Terraform talks to AWS and updates state.

### 3.2 Generated and cache layout

**Cache directory** (from `download_dir` in component, e.g. `infrastructure-base.hcl`):

- Path: `temp_terra_gen/.terragrunt-cache/<env>/<layer_name>/`
- Example: `temp_terra_gen/.terragrunt-cache/dev/infrastructure/`

**What Terragrunt puts there:**

1. **Copied module tree:** The path **before** `//` in `source` is copied here. The part **after** `//` is the Terraform **root** inside that copy (see §4). So you get e.g. a full `modules/` tree with `root_infrastructure/` as the working root.
2. **Generated files** (from root.hcl):
   - `backend.tf` — backend "s3" block (bucket, key, region, encrypt, use_lockfile).
   - `provider.tf` — terraform required_version, required_providers, provider "aws".
3. **Terraform’s own generated/state:**
   - `.terraform/` — providers, modules (after `terraform init`).
   - `.terraform.lock.hcl` — can live in the **layer dir** in the repo (e.g. `environments/dev/infrastructure/.terraform.lock.hcl`) and is used when running in the cache; lock file pins provider versions.
   - **State** is **remote** (S3); only the lock (e.g. `terraform.tfstate.lock.info`) may appear locally during runs.

**State key:** From root.hcl, `key = "${path_relative_to_include()}/terraform.tfstate"`. The include is root, so path is relative to the `environments/` folder → e.g. `dev/infrastructure/terraform.tfstate`.

```mermaid
%%{init: {'themeVariables': {'fontSize': '9px'}}}%%
flowchart TB
  subgraph repo["Repo (committed)"]
    L[environments/dev/infrastructure/terragrunt.hcl]
    C[_component/infrastructure-base.hcl]
    R[root.hcl]
    M[modules/root_infrastructure, vpc, aurora, ...]
  end
  subgraph cache["Generated: temp_terra_gen/.terragrunt-cache/dev/infrastructure/"]
    T[backend.tf, provider.tf]
    CP[copied modules/ tree, root = root_infrastructure]
    TF[.terraform/ after init]
  end
  subgraph remote["Remote"]
    S3[(S3: dev/infrastructure/terraform.tfstate)]
    AWS[(AWS resources)]
  end
  L --> C
  L --> R
  C -->|source + download_dir| cache
  R -->|generate| T
  CP --> TF
  T --> S3
  TF --> AWS
  style repo fill:#e8f5e9
  style cache fill:#fff3e0
  style remote fill:#e3f2fd
```

### 3.3 How the cloud provider is configured “properly”

1. **backend.tf** (generated) → Terraform stores state in S3; no local state file.
2. **provider.tf** (generated) → Terraform uses the AWS provider (region, etc.); credentials come from the environment (e.g. `AWS_PROFILE`, `AWS_ACCESS_KEY_ID`).
3. **Module code** (`.tf` in the copied tree) → Declares resources (vpc, subnets, EKS cluster, etc.). Terraform turns these into **API calls** to AWS (CreateVpc, CreateSubnet, CreateCluster, …).
4. **Inputs** (from Terragrunt) → Feed into variables (e.g. `vpc_cidr`, `environment`) so the same module can be reused for dev/prod or different layers.
5. **State** → After apply, state holds resource IDs and attributes; the next plan/apply diffs state vs config and only changes what’s needed.

So: **HCL + .tf** describe desired state; **Terragrunt** wires layer → module and backend/provider; **Terraform** executes against the provider and keeps state in S3.

---

## 4. The `//` and leaf vs root (composition) modules

### 4.1 Why `source = ".../modules//root_infrastructure"` uses `//`

- **Without `//`:** Terragrunt would copy only the subdir after the path (e.g. `root_infrastructure/`). The Terraform root would have no siblings, so `source = "../vpc"` in `root_infrastructure/main.tf` would break.
- **With `//`:** Terragrunt copies **everything before** `//` (the whole `modules/` directory), then uses the part **after** `//` as the **Terraform root** inside that copy. So the cache contains e.g. `root_infrastructure/`, `vpc/`, `aurora/`, … and from `root_infrastructure/main.tf` the paths `../vpc`, `../aurora` resolve to siblings. See [TERRA_LEARNED.md §6.3](TERRA_LEARNED.md#63-why-the-infrastructure-layer-can-use-vpc-aurora-etc).

### 4.2 Leaf vs root (composition) modules

| Type | Role | In this project |
|------|------|------------------|
| **Leaf** | One main AWS concern (one “thing”). Reusable from other modules. | vpc, iam, aurora, s3-data, alb, frontend, secrets-manager |
| **Root / composition** | Entry point for a **layer**. Composes multiple resources and often calls leaf modules. One Terragrunt layer runs Terraform with this dir as root. | root_infrastructure, root_eks, root_ecs |

Example: The **infrastructure** layer uses `source = ".../modules//root_infrastructure"`. So Terraform’s root is `root_infrastructure/`. That module’s `main.tf` calls `module "vpc" { source = "../vpc" }`, `module "aurora" { source = "../aurora" }`, etc. So one **layer** (one apply) uses one **root** module that composes several **leaf** modules.

```mermaid
%%{init: {'themeVariables': {'fontSize': '9px'}}}%%
flowchart LR
  subgraph layer["Layer: dev/infrastructure"]
    TG[terragrunt.hcl]
  end
  subgraph cache["Cache: .../dev/infrastructure/"]
    ROOT[root_infrastructure]
    VPC[vpc]
    AUR[aurora]
    IAM[iam]
    S3[s3_data]
    ROOT --> VPC
    ROOT --> AUR
    ROOT --> IAM
    ROOT --> S3
  end
  TG -->|source //root_infrastructure| cache
  style ROOT fill:#ffcc80
  style VPC fill:#c8e6c9
  style AUR fill:#c8e6c9
  style IAM fill:#c8e6c9
  style S3 fill:#c8e6c9
```

### 4.3 One-line summary

- **Layer** = one directory under `environments/<env>/` + one state key + one `terragrunt apply`.
- **Root module** = the subdir after `//` (e.g. `root_infrastructure`); Terragrunt copies the whole `modules/` tree so that root can reference sibling leaf modules via `../vpc`, etc.
- **Generated** = cache dir (copied module tree), `backend.tf`, `provider.tf`, and after init `.terraform/` and lock; state lives in S3.

---

## 5. End-to-end flow (one layer, one apply)

Numbered flow for one layer (e.g. **dev/infrastructure**):

1. You run `terragrunt apply` in `module_infra_basic/aws/terra/environments/dev/infrastructure/` (or the appropriate layer dir in another tree).
2. Terragrunt loads `terragrunt.hcl` → includes `root.hcl` and `_component/infrastructure-base.hcl`.
3. From component: `source = ".../modules//root_infrastructure"`, `download_dir = ".../temp_terra_gen/.terragrunt-cache/dev/infrastructure"`.
4. Terragrunt copies the full `modules/` dir into that cache; Terraform root = `root_infrastructure/`.
5. Terragrunt generates `backend.tf` and `provider.tf` in the cache (from root.hcl).
6. Terragrunt runs `terraform init` in the cache → backend S3, providers (e.g. hashicorp/aws), and `.terraform.lock.hcl` used if present.
7. Terragrunt passes **inputs** (from env.hcl + component) into the module.
8. Terragrunt runs `terraform plan` then `terraform apply` in the cache → Terraform updates state in S3 and creates/updates AWS resources (VPC, subnets, Aurora, IAM, etc.).
9. State key in S3: `dev/infrastructure/terraform.tfstate` (from `path_relative_to_include()` in root.hcl).

No step in this flow **edits** the committed repo; only the cache and remote state (and AWS) change.

---

## 6. Quick reference (this doc)

| Item | Meaning |
|------|--------|
| **Layer** | One dir under `environments/<env>/`, one state file, one `terragrunt apply`/`destroy`. See [TERRA_LEARNED.md](TERRA_LEARNED.md). |
| **Root module** | The dir after `//` in `source` (e.g. `root_infrastructure`). Terraform runs with this as the root. |
| **Leaf module** | A single-concern module (vpc, aurora, …) called by a root or another module via `source = "../vpc"` etc. |
| **Cache** | `temp_terra_gen/.terragrunt-cache/<env>/<layer>/` — copied module tree + generated backend.tf, provider.tf, .terraform/ after init. |
| **State key** | From root.hcl: `path_relative_to_include()/terraform.tfstate` (e.g. `dev/infrastructure/terraform.tfstate`). |
| **Generated files** | backend.tf, provider.tf (from root.hcl); lock file can live in layer dir or cache; state in S3. |
| **Import/reconcile scripts** | Per-layer `import-existing-*.sh` helpers that reconcile Terraform state with AWS before **apply** and **destroy** (including lock handling and “already managed / non-existent” cases). See `docs/learned/TERRA_LEARN_IMPORT_PREEXIST.md`. |

---

*This doc: `docs/learned/TERRA_LEARNED_TOTAL.md`. For layers, deploy order, Option B, and teardown: [TERRA_LEARNED.md](TERRA_LEARNED.md).*
