# Terraform — analysis

This is a plan for Terraform in Overterm. It covers the editor, the plan, the apply, the state, and the agents that run `terraform` in their own worktrees:
- a checkout's roots, their workspaces and backends, and which of them are production,
- HCL in the editor, with terraform-ls when it is installed,
- a plan read as data, in the right slot beside the diff that caused it,
- the apply of that plan and nothing else,
- the agent's own terminal: what Overterm can see there, and the guards it can put around it,
- typed `tf_` MCP tools that never hand an agent a secret.

The goal is HCP Terraform's structured plan, VS Code's editor and Atlantis's "which roots does this change touch", at the place none of them is: the checkout, its terminal, its diff and the agent working in it.

This document covers:
- what this Mac has, and what the sandboxes verified (2026-11-08),
- the features of the CLI and of the tools around it, and what we do for each,
- what Overterm adds beyond them,
- how we run Terraform, with every flag and signal checked against Terraform 1.17.1,
- the security model for infrastructure that is real,
- the interface, the shortcuts and the integration points,
- the stages, performance, tests and risks,
- the decisions: the ones taken here, and the ones that need the user's answer.

**Status: design, decisions taken (2026-11-08: every recommended option in Section 13).** Nothing is built. It was written against branch `kubernetes` at `d6f2daf`, read only. It is meant to become `docs/design/terraform/analysis.md`. Five research notes went into it (codebase, domain, landscape, safety, UX), then four reviews (feasibility, safety, user value, Terraform correctness). Section 15 says what the reviews changed.

Every behaviour marked **[verified]** was run with Terraform v1.17.1 (darwin_arm64) in sandboxes under the study's scratchpad: `env -i`, an empty `TF_CLI_CONFIG_FILE`, `HOME` and `TF_DATA_DIR` inside the sandbox, `CHECKPOINT_DISABLE=1`, only the `null`, `random`, `local` and `terraform_data` resources, a local backend or a fake `http` backend. Names are fictional (`acme-*`, `globex-*`). No user configuration, state, `~/.terraform.d`, `~/.aws` or cloud was read or touched. Anything not run is marked **per docs** with a source in Section 14, or **unverified**.

## In short

- **Terraform is Kubernetes without a proxy.** There is no socket between Overterm and the cloud, so nothing like `--reject-methods` can make a root read-only. Every operation is a `terraform` process that runs provider binaries with the user's own credentials.
  - So read-only is a check in Overterm's code when it starts a process (`TerraformProcessCheck`), locked by tests. It is never a property of the credentials.
  - Neither covers what a person or an agent types in a terminal tab. There, Overterm's job is to **see** and to **say**, and, for the agents it launches, to start them with Terraform's writes denied (Section 3.4).
- **A root belongs to a checkout; a cluster context does not.** So the weights are Kubernetes' reversed. The first surfaces are:
  - the **rail panel** (`SidebarPanel.terraform`, ⌥⌘E): the selected tab's checkout's roots, each with its workspace, backend, class and last plan;
  - the **right slot** (`RightPane.Mode.terraformPlan`): one plan, beside the changes pane;
  - the **pane header** on any pane where `terraform` runs, the agent's included: root, workspace, backend, red on production;
  - the **Inbox**: an agent asking to run `terraform apply`, or Terraform's own "Do you want to perform these actions in workspace …?", marked on the tab and never answered for you.

  A page across every checkout (`WorkspacePage`) is stage 3, if the cross-checkout list proves useful.
- **The only apply is `terraform apply <the plan Overterm showed>`.** It runs as Overterm's own process, **detached from the app**, in the **same recorded environment as the plan**, with the **same absolute binary**. [verified] A saved plan pins the config, the state's lineage and serial, and the workspace. It does **not** pin credentials, account, region or kube context: those are read again at apply from the environment. So the plan and its apply run in one environment, or the apply doesn't run. No path skips the shown plan: no `-auto-approve`, no `apply` without a plan, no `-lock=false`, never typed into the user's shell.
- **Plans and state hold secrets in clear; `sensitive` only hides them from the CLI's text.** [verified] A sensitive variable's value sits in `show -json`'s `variables`, a sensitive output's in `output -json` and in `output_changes.*.before`, and backend passwords in the plan file and in `.terraform/terraform.tfstate`. So:
  - the plan JSON is decoded through an **allow-list** of keys, masked by Terraform's `*_sensitive` mirrors, then by `Secrets`;
  - a plan file lives seconds as a path in a 0700 per-process folder in `$TMPDIR`, then only as an open file descriptor;
  - nothing of a run is written where Overterm keeps things: not the support folder, the session, the scrollback of a Terraform pane, or a log.
- **Production is a class, as in Kubernetes, and stickier.** It is recognised by name in the workspace, the backend's bucket, key, prefix or organisation, the root's path, the var files, the backend-config files and the AWS profile. Once a state identity has been production, it stays production in every worktree and under every folder name. A class set by hand can only raise it. A root is writable unless `terraform.roots` sets `writable: false` (the owner's decision, 1.6.0); every apply on production asks for the root's name to be typed.
- **Wrong-target accidents are the ones that hurt.** The DataTalks.Club incident (February 2026) was an agent running `terraform destroy` against a state it had swapped in. Three verified traps get their own guards:
  - a workspace that doesn't exist, whether named by `TF_WORKSPACE` **or by `.terraform/environment`**, is silently created, and its plan creates everything again [verified];
  - a new worktree of a local-backend root has no state, so its plan creates everything again;
  - an apply with a newer Terraform than the state's moves the whole team's state forward, with no way back.
- **Agents get a masked plan, never the file, and never an apply in stages 1–2.** `tf_plan_summary` gives counts, addresses, reasons and the cause chain, cheaper in tokens than 3,000 lines of CLI text and with no secret in it. It also reads a plan the agent saved itself. `tf_plan` is offered on non-production roots, asked in the window once per root and session.
- **What Overterm alone can show:** why a resource is replaced, down to the changed line in this branch (`replace_paths` → `references` → `DiffModel`); which roots a shared-module edit affects; which other worktree's apply just made your plan stale.
- **The floor is stage 1 (1a–1d). It can't change infrastructure:** the editor, the roots and the pane header, the agent guards, and the plan in the right slot. Stage 2a adds the apply, with every guard in place, as Kubernetes' stage 2a added writes.
- **No new package is needed.** The plan file is read through Terraform (`show -json`), never unzipped by us except for the prior state's lineage and serial, which a small pure central-directory reader gives.

## 1. What this Mac has (2026-11-08)

| Tool | Where | Note |
|---|---|---|
| `terraform` v1.17.1 | `/opt/homebrew/bin/terraform` | Homebrew (hashicorp tap). BSL 1.1. Not on the PATH of an app launched from the Dock |
| `mise` | `/opt/homebrew/bin/mise` | Already used by this repository (`mise.toml`); can pin terraform per directory |
| `tofu`, `terraform-ls`, `tflint`, `terragrunt`, `tfenv`, `tenv`, `asdf` | not installed | Every OpenTofu and Terragrunt fact here is per docs |
| HCL grammar | not in `Scripts/build-treesitter.sh` | Helix 25.07.1 (our pinned `HELIX_REF`) uses `tree-sitter-grammars/tree-sitter-hcl` at `9e3ec9848f28d26845ba300fd73c740459b83e9b` |
| A language server | not in `LanguageServers.specs` | Helix's entry: `terraform-ls serve` |

No user configuration, state or credential was read. Nothing here says whether the user has real Terraform roots; the design assumes they do, and that some are production.

### The spike (2026-11-08), in sandboxes only

Ten sandboxes ran (`sandbox-{codebase,domain,landscape,safety,ux,analysis,review0,review1,review3,revise}`). What they decided:

| # | What was run | Result | Decided |
|---|---|---|---|
| 1 | `show -json` of a plan with a `sensitive = true` variable, a sensitive output, `random_password` | `variables.db_password.value`, `output_changes.*.before` and `change.before.*` in clear; only the `*_sensitive` mirrors say where | Allow-list decode, mask at decode (Section 5.6) |
| 2 | `output -json`, `output NAME` | Sensitive values in clear | Overterm never runs them for display; outputs come from `show -json` state, masked |
| 3 | The plan file | A zip: `tfplan`, `tfstate`, `tfstate-prev` (lineage, serial, every secret), `tfconfig/`, `.terraform.lock.hcl`; written 0644 under umask 022 | A secret at rest; 0700 folder, fd-held (4.4) |
| 4 | `-backend-config=password=…` | In clear in `.terraform/terraform.tfstate` **and** in the plan file | The backend record is read through an allow-list of keys |
| 5 | Two plans on one state, the first applied, then `apply` of the second | "Saved plan is stale"; another workspace's plan refused | Terraform's checks are authoritative and shown verbatim |
| 6 | Plan with `ACME_TARGET=acme-staging`, apply of that plan with `ACME_TARGET=acme-prod` | The provisioner ran with `acme-prod` | **A saved plan does not pin the environment.** Plan and apply run in one recorded environment (4.6) |
| 7 | `TF_CLI_ARGS_apply=-auto-approve`, `TF_CLI_ARGS_apply=-lock=false` | The first silently skipped the prompt. With the second, two saved-plan applies on one state **ran at once**, unlocked, and one created object was orphaned | `TF_CLI_ARGS*` cleared, and `-lock=true` written explicitly |
| 8 | `TF_CLI_ARGS_apply=-lock=false` plus `-lock=true -lock-timeout=0s` on the command line, while another apply held the lock | "Error acquiring the state lock" | The explicit flag after the env args wins (4.6) |
| 9 | `TF_LOG=trace` | argv logged, `-var` values included | `TF_LOG*` removed; no secret ever on argv |
| 10 | SIGINT to terraform's pid, and to its whole group, 6 s into an apply with a `local-exec` | Both: "Interrupt received… Gracefully shutting down", `provision_errored`, exit 1, state written, lock released, the resource **tainted** | Stop is one SIGINT to the group (4.7); the dialog says resources may be tainted |
| 11 | SIGTERM to pid or group; SIGKILL; **SIGHUP** | SIGTERM graceful. SIGKILL: exit 137, `.lock.info` left. **SIGHUP (closing a pane): exit 129 at once, no graceful stop, lock left** | Overterm's applies never live in a pane; closing a pane where terraform writes asks first (4.8) |
| 12 | The reader of an apply's stdout exiting mid-apply | **Exit 141 (SIGPIPE)**, no graceful stop, lock left, the in-flight resource unrecorded | Overterm's applies write to files, not a pipe, in a session of their own (4.7) |
| 13 | `TF_WORKSPACE=acme-typo terraform plan`; `TF_WORKSPACE=acme-typo3 terraform state pull`; `TF_WORKSPACE=acme-ghost terraform init` | All exit 0, each **creates** the workspace; the plan creates everything | Never pin by `TF_WORKSPACE` without checking the name exists (4.9) |
| 14 | `.terraform/environment` naming a workspace that doesn't exist, `TF_WORKSPACE` unset | Plan exit 0, workspace created, everything planned as a create | The check is for every run, not only pinned ones |
| 15 | In a shell with `TF_WORKSPACE` set: `workspace select default`, `workspace new` | Both refused ("overridden using the TF_WORKSPACE environment variable") | Terminal tabs are never pinned by `TF_WORKSPACE` (4.9) |
| 16 | A plan on an empty workspace | `show -json` has **no `prior_state` key**; every change a create | The "no state found" guard (5.4) |
| 17 | `TF_DATA_DIR=/dev/null/overterm-pin-lost` | `plan`, `apply`, `init`, `state list` all exit 1 at once, state untouched | Kept as the way to make a tab's terraform refuse, should one ever be needed (rejected for pins, 4.9) |
| 18 | `exec 3<plan; rm plan; terraform apply /dev/fd/3`, and `show -json /dev/fd/3` | Both work | The plan is held by an fd once written (4.4) |
| 19 | `init -backend=false` with a scratch `TF_DATA_DIR`, then `validate` under `TF_LOG=trace` | `init` **wrote `.terraform.lock.hcl` into the checkout**; `validate` **started the provider binaries** | Validate is not side-effect free; `-lockfile=readonly`, credentials stripped (5.9) |
| 20 | A provider binary edited; `init -lockfile=readonly` with no lock file | Edit refused by the lock-file hashes; readonly init refused | The lock file protects providers; Overterm never rewrites it silently |
| 21 | `data "local_command"` and `action "local_command"` (local 2.9.1) | The data source **ran a shell command during `plan`**; the plan JSON has a top-level `action_invocations` | The `local` provider is not "local"; actions are destructive by default (5.2, 5.5) |
| 22 | `init`, `plan -out`, `show -json`, `apply <plan>`, `output -json` with `terraform_data` only, proxies pointed at a dead port | All work offline; **no `TF_DATA_DIR`, no lock file created** | Scenarios use the real binary offline (11); "needs init" is a diagnostic, not a missing folder (4.12) |
| 23 | `plan -json -detailed-exitcode` | Exit 2 with changes, 0 without; exit 1 still writes a plan file on a failing precondition | The flag is always passed; exit 1 is failure whatever was written |
| 24 | `apply -auto-approve` that fails, and one interrupted | Each has a `change_summary` with `"operation":"plan"` and none with `apply` | "Apply done" is the exit code plus a summary whose operation is `apply` |
| 25 | A refresh-only plan, an errored plan, a destroy plan | No `resource_changes` key; no `output_changes`/`prior_state`; no `resource_drift` | Every collection is optional in the decoder |
| 26 | An ephemeral variable given at plan, then `apply -input=false <plan>`; `apply -var …`; `TF_VAR_…` | Fails at once; `-var` accepted for an ephemeral variable only; `TF_VAR_` works | Ephemeral values go again through the environment at apply (4.6) |
| 27 | `terraform state rm -dry-run -lock-timeout=0s <none>` while an apply held the lock; with no lock | Fails with the lock text; "Would have removed nothing." | The lock probe (4.10); `state list` takes no lock and can't serve |
| 28 | Local backend `path = "acme.tfstate"`, workspace `acme-stage` | State at `terraform.tfstate.d/acme-stage/terraform.tfstate`, not `…/acme.tfstate` | `path` applies to `default` only (4.11) |
| 29 | A 2,000-resource update plan | `show -json` 14.9 MB in 1.8 s; stream 2.9 MB; parsed in 0.06 s by a C parser | The performance budgets (10) |

Still to verify in the stage that needs it (each listed again where it applies):
- how Claude Code and Codex run a command: as descendants of the pane's login process with no tty (so Terraform's own prompt never reaches the screen, and the agent's permission prompt is what to read), and whether a `--disallowedTools` deny holds under `--dangerously-skip-permissions` (stage 1c);
- whether Terraform keeps a pre-created 0600 file's mode for `-out` (stage 1d; the 0700 folder covers it either way);
- `show -json` of a saved **cloud** plan (stage 3);
- everything about `tofu` and `terragrunt` with real binaries (stage 3).

## 2. Feature inventory

Columns: **CLI** (what `terraform` gives in a terminal), **Others** (HCP Terraform, Atlantis, Spacelift/env0/Scalr, VS Code's HashiCorp extension, JetBrains), **Ours**, **How** (Run: a `terraform` process Overterm starts; Local: pure code over data read; Editor; LSP: terraform-ls; Tab: the user's own terminal), **Stage** (Section 9; Out = left out, with why).

### 2.1 Roots, checkouts and worktrees

| Feature | CLI | Others | Ours | How | Stage |
|---|---|---|---|---|---|
| Find roots | `-chdir` by hand | HCP: a workspace per directory; Atlantis: `atlantis.yaml` or autodetect | One `Git.run` `ls-files` over `*.tf`, `*.tf.json`, `*.tofu`, `*.tfvars*`, `*terragrunt.hcl`, `*root.hcl`, `*.terraform.lock.hcl`, `*.tftest.hcl`, then a pure `TerraformRootGuess` over the folders (4.12). 16 ms on this repository | Local | 1b |
| Roots of every worktree | — | — | One row per root of the selected tab's checkout; the root's other worktrees named beside it, "shares state" when the identity matches | Local | 1b |
| Which roots a change touches | — | Atlantis autoplan | Changed files (`DiffModel`) mapped to roots, **and** a shared module mapped back to every root that calls it ("modules/network: 5 roots"), from `module` sources and `modules.json` | Local | 1b |
| A root's choices | `-var-file` | HCP variables | Var files and the chosen workspace per checkout and root in `TerraformRootStore` (support folder, never the repository). The display name and class in `terraform.roots` (settings.json) | Local | 1b |
| No state in this worktree | — | — | A local-backend root whose state file is missing here but present in another worktree of the repository: red on the root, the pane header and the plan, "the state is in `main`'s checkout" (5.4) | Local | 1b |
| Init | `init` | HCP does it | "Init" on the root's verbs, the person's click (New Task's `-backend=false` init aside, 4.13): `init -input=false -lockfile=readonly -json`. "Upgrade providers…" (`-upgrade`) asked, because it rewrites `.terraform.lock.hcl`, shown as a diff | Run | 1d |
| Shared provider cache | `plugin_cache_dir` | — | Offered at the first Init in a window with two worktrees of one repository: `TF_PLUGIN_CACHE_DIR` under a new `AppEnvironment.terraformCacheDirectory`, Overterm's runs only, inits serialised per cache (4.13) | Run | 1d |
| New Task's roots | — | — | After `git worktree add`: the roots the branch has, the no-state warning, and `init -backend=false -lockfile=readonly` for validate and the editor (no credentials) | Run | 2b |
| Terragrunt units, stacks | — | Terragrunt | Detected and labelled in 1b ("Terragrunt unit: run it with terragrunt in a terminal"); units as roots in stage 3 | Local | 1b / 3 |
| Terramate, CDKTF, Pulumi | — | yes | **Out**: other models of roots and runs | — | Out |

### 2.2 Plan

| Feature | CLI | Others | Ours | How | Stage |
|---|---|---|---|---|---|
| Plan | text | HCP/Spacelift structured; Atlantis a PR comment | `plan -input=false -json -detailed-exitcode -lock=true -lock-timeout=10s -out=<run folder>/plan [-var-file …]`; the stream drives progress, then `show -json` of the fd is the plan view (4.4) | Run | 1d |
| Summary bar | "Plan: 1 to import, 5 to add…" | HCP: +/~/- | `+5 ~1 -3 ±2 →4 ⇣1 ⚠1 ⚡1`: create, update, delete, replace, moved, imported, drift, actions, counted from `resource_changes`, `action_invocations` and `resource_drift`; replace counted once, the CLI's sentence on hover so numbers match | Local | 1d |
| Risky first | grep for destroy | Scalr "smart outputs" | Replace, delete, forget and action invocations first, red, with `action_reason` in words and the forcing attribute from `replace_paths` | Local | 1d |
| Why it is replaced | — | — | **The cause chain** for replace and delete rows: `replace_paths` → `configuration…expressions.<attr>.references` → the variable or local → the file and line that changed in this branch (3.1) | Local | 1d |
| Same change on N resources | — | tf-summarize | Rows with identical actions, changed attribute paths and `replace_paths` folded into one row ×N, expandable. Collapses `timestamp()` tag noise | Local | 1d |
| Attribute diff | `~`, `(known after apply)`, `(sensitive value)` | HCP | A tree of `before`/`after` walked with `after_unknown` ("known after apply"), the sensitive mirrors (••••, never a value, even on hover) and `replace_paths`; unchanged folded ("12 unchanged"); long strings by `LineDiff`, JSON in a string pretty-printed first | Local | 1d |
| Moved, imported, forgotten | text | HCP badges | Their own groups: "Moved (4)", "Imported (1) ← p-9hUg", "Forgotten: kept in the cloud, out of state". A move or import is a no-op with a marker (`previous_address`, `change.importing`), not an action [verified] | Local | 1d |
| Drift in a plan | "Objects have changed outside of Terraform" | HCP drift tab | `resource_drift` as a yellow section above the changes | Local | 1d |
| Actions (1.14+) | "Actions: N to invoke" | — | `action_invocations` as their own red group, `config_values` masked by `config_sensitive` | Local | 1d |
| Filter | — | — | `/` text over the address, plus action chips. The `attr:`/`provider:` language later, if asked | Local | 1d / later |
| Jump to the block | — | VS Code no | `o` on a row: `TerraformConfigIndex` (pure, over tree-sitter trees) maps an address through `modules.json` to `resource "type" "name"` in its file; a diagnostic opens at its `range` | Editor | 1d |
| Plan as text, for a PR | `show planfile` | Atlantis | "Copy summary" (the bar, risky rows and causes, masked) in 1d; "Post to pull request…" (`gh pr comment`, the text shown first) in 2f. Never raw `show` text | Local | 1d / 2f |
| Missing variables | "No value for required variable" | HCP variables | On that diagnostic, the root's `*.tfvars` and `*.auto.tfvars` offered; the choice remembered per checkout and root, and shown on the chip | Local | 1d |
| Inputs that change a plan | — | — | The review header names the var files, the auto-loaded `*.auto.tfvars`, and the `TF_VAR_*` **names** in the run's environment (never values) | Local | 1d |
| Targeted, replace, destroy plans | flags | HCP | "Plan only these" (`-target`, labelled partial), "Plan with replace", "Plan destroy…" behind the root's menu | Run | 2a |
| Fast plan (`-minimal-refresh`) | flag | — | **Out**: it skips checking for drift on untouched resources, so a reviewed plan would not be what it seems | — | Out |
| Cost estimate | — | Infracost, HCP | **Out** in stages 1–2; Infracost if installed and configured by the user, stage 3 | — | 3 |
| Policy results | `-policies` | HCP, Spacelift | Shown when the stream carries `policy_*` messages; no engine of ours | Local | 3 |

### 2.3 Apply

| Feature | CLI | Others | Ours | How | Stage |
|---|---|---|---|---|---|
| Apply a shown plan | `apply planfile` | HCP Confirm & Apply | Only from the plan on screen, only that file (its fd), by the binary that made it, in the environment it was made in; the checks of 5.4; `WriteConfirmation` naming root, worktree, branch, workspace, backend; the root's name typed on every production apply | Run | 2a |
| Progress | text | HCP log | "7 of 12 · 2 running · 1m 12s"; each row waiting → running → done/errored; replace phases and provisioner output as raw text under the row | Local | 2a |
| Errors | text | text | `apply_errored` plus its `diagnostic` by `address`: red row, "Open at main.tf:67", Ask Why. The end is the exit code plus a `change_summary` whose `operation` is `apply` | Local | 2a |
| Stop | ⌃C once, twice | HCP cancel / force cancel | One SIGINT to the run's group; the bar says "Stopping: running resources may be left tainted". A second Stop asks, saying state may be lost, then a second SIGINT. Never SIGKILL while it runs | Run | 2a |
| Survives a crash or a quit | — | — | The apply runs in its own session, writing to files; Overterm tails them, and reattaches at the next launch (4.7) | Run | 2a |
| Auto-approve | flag | Atlantis autoapply | **Out**: no path skips the shown plan | — | Out |
| Agent apply | — | HCP MCP behind `ENABLE_TF_OPERATIONS` | **Out** in stages 1–2; a decision for stage 3 (13, D-12) | — | 3? |

### 2.4 State, outputs, workspaces, backends

| Feature | CLI | Others | Ours | How | Stage |
|---|---|---|---|---|---|
| Resource list | `state list` | HCP resources tab | `state list` first (0.16 s for 2,000), `show -json` while the list shows; grouped by module; masked | Run | 2c |
| One resource | `state show` | yes | From the `show -json` tree, masked by `sensitive_values` then `Secrets`; "Open block". There is no `state show -json` | Local | 2c |
| Outputs | `output -json` (prints secrets) | yes | From state `show -json`: name, type, non-sensitive value; a sensitive one says "sensitive", with no Show in stages 1–2 | Local | 2c |
| Outputs into Overterm | — | — | A non-sensitive URL, host or port output offered as "Open in Browser", "New Database Connection…" (password asked, never read from an output), "Add to API environment"; an EKS/GKE/AKS cluster as "Open in Kubernetes" | Local | 2c |
| Workspaces | `workspace list/select/new/delete` | HCP | The chip lists them (`workspace list`, cached per identity). "Select" runs `workspace select <name>` with `TF_WORKSPACE` cleared: it refuses unknown names, and it writes the checkout's `.terraform/environment`, which the menu says. New and delete are typed in a terminal | Run | 1d |
| Backend shown | — | — | Always on the chip: `s3 · acme-tfstate/prod/network.tfstate · eu-west-1`, `cloud · globex/net-prod`, `local · terraform.tfstate` | Local | 1b |
| State surgery: `state mv/rm`, CLI `import`, `taint`, `push`, `replace-provider` | yes | tftui, HCP some | **Out** as buttons. `moved`, `removed` and `import` blocks are the way, through plan and apply. `taint` and CLI `import` write state with no plan, so they contradict "every write is a shown plan" | — | Out |
| State versions | — | HCP | **Out**: backend-specific | — | Out |

### 2.5 Locks

| Feature | CLI | Others | Ours | How | Stage |
|---|---|---|---|---|---|
| Who holds it | the error text | HCP shows it | Parsed from the `Error acquiring the state lock` diagnostic's `detail` only (ID, Path, Operation, Who, Version, Created, Info; an http variant): "Locked by ci@globex-runner-7 since 09:00 (an apply, Terraform 1.17.1)". Never read from a `.lock.info` file | Local | 1d |
| Overterm's own runs | — | Atlantis's PR lock | One run per state identity at a time, app-wide; a second waits in a queue that says so; "applied from `bump-eks`: your plan is stale" at once | Local | 1d |
| Wait | `-lock-timeout` | — | "Wait for it" re-runs with `-lock-timeout=5m` | Run | 1d |
| Force unlock | `force-unlock` | HCP button | Only from a lock parsed in this window, re-probed (4.10), the holder shown, the root's name typed, on every class; the http backend's empty-bodied UNLOCK said | Run | 2e |

### 2.6 Drift

| Feature | CLI | Others | Ours | How | Stage |
|---|---|---|---|---|---|
| Check drift | `plan -refresh-only` | HCP, Spacelift, Scalr scheduled | "Check drift": `plan -refresh-only -json -out=…`, locked like any plan; its age shown, never a stale count as current | Run | 2d |
| Accept into state | `apply -refresh-only` | HCP | Applying that refresh-only plan, asked (it writes state) | Run | 2d |
| Scheduled checks | — | paid everywhere | **Out**: credentials and cloud reads on a timer, and `-lock=false` reads a half-written state | — | Out |

### 2.7 Editor

| Feature | CLI | Others | Ours | How | Stage |
|---|---|---|---|---|---|
| Highlighting | — | VS Code | tree-sitter-hcl at Helix 25.07.1's pin with Helix's `hcl/` queries; `EditorLanguage("hcl", …)` for `tf`, `tfvars`, `hcl`, `tofu`, `tftest.hcl`, `tfquery.hcl`, `.terraform.lock.hcl`, `terragrunt.hcl` (4.14) | Editor | 1a |
| Language server | — | VS Code | `terraform-ls serve` as a `LanguageServers.Spec`, when found; launched without credential variables; its `validateOnSave` off | LSP | 1a |
| Format on save | `fmt` | VS Code | `terraform fmt -` over the buffer, one `replaceText` edit, undoable; on by default only where the checkout already passes `fmt -check` | Run | 1a |
| Validate | `validate -json` | VS Code | On demand and before every plan; on save only where terraform-ls isn't running. Credentials stripped, `-lockfile=readonly`; "needs init" said once | Run | 1a |
| Go to definition, references, hover | — | terraform-ls | terraform-ls; without it, F12 on `var.x`/`module.y`/`local.z` by the static index | LSP / Editor | 1a |
| Provider docs | registry | VS Code hover | terraform-ls hover; without it, `providers schema -json` read when asked (tens of MB for a cloud provider), in memory, capped | Run | 2+ |
| Lint, security (tflint, trivy, checkov, conftest) | — | yes | If on PATH, run on request, results as diagnostics and in the plan view; never bundled | Run | 3 |

### 2.8 Versions, binaries, OpenTofu, Terragrunt, HCP

| Feature | Ours | Stage |
|---|---|---|
| Which binary | Per root: `terraform.path`, else `mise which terraform` with the root as cwd when mise is found, else the shell's PATH; resolved to an absolute path, `version -json` once per path (4.2) | 1b |
| Version pill | "1.17.1 ≠ required ~> 1.9" from `required_version`, `.terraform-version`, `.tool-versions`, `mise.toml` | 1b |
| Version guard | Apply refused when the plan's `terraform_version` is newer in minor than `prior_state.terraform_version`, unless confirmed with the consequence spelled out | 2a |
| Lock file differs between worktrees | "aws 5.80 here, 6.2 in `main`" from `git diff` of `.terraform.lock.hcl` | 2b |
| OpenTofu | Detected (`.opentofu-version`, mise `opentofu`, `.tofu` files, a lock file naming `registry.opentofu.org`, `tofu version`'s first line); features gated by product and version; encryption-aware readers. Everything unverified until run against a real `tofu` | 3 |
| Terragrunt | Units listed (`terragrunt find`), per-unit plan with an absolute `-out`, JSON forwarded; `run --all` refused as a builder; the pane header recognises `run --all`, `run-all`, `apply-all`, `destroy-all` (in 1b) | 3 |
| HCP Terraform, `cloud {}` roots | Editor, pane header, prompt watch, Ask Why, a link to the run in stages 1–2. A saved cloud plan through `show -json` if it works (unverified), or the JSON plan API with a token the user types into the keychain, in stage 3. Never `credentials.tfrc.json` | 1 / 3 |

### 2.9 Tests, review, agents

| Feature | Others | Ours | Stage |
|---|---|---|---|
| `terraform test` | — | Run blocks listed in the right slot with status per run; failures as editor diagnostics; `tf_test` for agents. Only for test files whose every provider is mocked (`mock_provider`), or asked: a run with real providers creates real infrastructure | 2d |
| Review tab | Atlantis, HCP speculative plans | A review tab whose diff touches roots lists them, with the latest plan of each root in the worktree that has the head; else "Check out in a new worktree and plan". Planning someone else's branch asks first (5.5) | 2f |
| Plan diff across worktrees | — | Two plans of one root and workspace compared by address | 3 |
| Ask Why | — | `a` on a failed plan or apply, or a held lock: `TerraformAgentBrief` to the checkout's agent | 1d |
| MCP tools | HashiCorp's MCP server (registry, HCP) | `tf_` tools, local, complementary (5.10) | 1c / 1d |

### 2.10 What Overterm does against the incumbents

The user's question is whether this beats VS Code with HashiCorp's extension plus HCP Terraform for someone running agents in several worktrees. Honestly:

| Job | VS Code + extension | HCP Terraform | Atlantis | Overterm (floor = stage 1) |
|---|---|---|---|---|
| Edit HCL with completion | Yes (terraform-ls) | — | — | Same, when terraform-ls is installed; highlighting and fmt without it |
| Read a plan as data, destroys first | No (text in a terminal) | Yes, structured | Text in a PR | Yes, beside the diff |
| Why is this replaced | No | Attribute only | No | **Down to the changed line in this branch** |
| Which roots does this change touch | Module Calls view, buggy | Per workspace | Yes (autoplan) | Yes, shared modules included |
| See which root, workspace, backend a pane is about to touch | No | — | — | **Yes, in the pane header, the agent's pane included** |
| Stop an agent's `terraform apply` on production | No | Only if runs are remote | Only through PRs | **Agents launched with Terraform's writes denied; the agent's ask marked in the Inbox** |
| Hand an agent a plan without secrets | No | Its MCP reads HCP runs | — | **Yes, `tf_plan_summary`, its own saved plans too** |
| Five worktrees of one root | No | — | One per PR | Yes: shared state named, "your plan is stale", no-state warning |
| Version trap | No | Pinned per workspace | Pinned | Pill and guard |
| Policy, cost, run history, team approvals | No | **Yes** | Partly | **No, and out on purpose** |
| Remote execution | — | **Yes** | Yes | Link to the run only |

HCP keeps policy, cost, history and approvals; Overterm doesn't try. For local-execution roots (s3, gcs, azurerm, local backends, including Atlantis shops whose developers plan locally), the floor is better than both where the agent works. For `cloud {}` roots it adds the guards and the editor, little more, until stage 3.

## 3. Beyond the CLI, HCP and Atlantis

### 3.1 A plan that knows the code that caused it

The plan opens in the right slot beside the changes pane. For each replace and delete row it gives the chain:

```
± random_pet.acme   replaced
    ← prefix                 (replace_paths: [["prefix"]])
    ← var.acme_name          (configuration.root_module.resources[…].expressions.prefix.references)
    ← envs/acme-prod.tfvars:3   changed in this branch   [Open]
```

- `replace_paths` names the forcing attribute; `configuration…expressions.<attr>.references` names what it reads; the variable resolves to its default, its tfvars line or a module input; `DiffModel`'s changed hunks say which of those lines this branch changed. `TerraformCauseChain` is pure.
- Clicking the hunk in the changes pane lights the plan rows it causes, and back.
- Floor: replace and delete only, where it matters. Updates and creates later.
- Nothing like it exists: Atlantis shows the plan and the PR shows the diff, two places, joined by hand.

### 3.2 The pane header on every pane where `terraform` runs

`TerraformPaneWarning` (the analogue of `KubePaneWarning`) puts a 38 pt bar over a pane while a `terraform`, `tofu` or `terragrunt` process runs anywhere in its tree:

```
 ⛰ envs/prod · workspace prod · s3 acme-tfstate/prod/network.tfstate · AWS_PROFILE acme-prod-admin · apply   PRODUCTION
```

- The process is found **in the pane's tree, not only its foreground group**: an agent runs its commands as its own children, without the pane's tty (to verify per agent in stage 1c). The root comes from that process's cwd and `-chdir`, read with `ProcessInspector.arguments(of:)`; the workspace and profile from its `environment(of:)` (`TF_WORKSPACE`, `AWS_PROFILE`, names and the profile's name only) and the root's `.terraform/environment`; the backend from the allow-listed backend record.
- It is a **notice, not a guard**: it appears once the command has started. Commands that probably run Terraform (`tf`, `make`, `just`, `task`, `./deploy*.sh`, `atlantis`) get "probably" when the root is all the files settle.
- An inherited `TF_WORKSPACE` or `TF_DATA_DIR` in that process's environment is said in amber: either decides silently.
- Cost: a stated exception to "read only on screen", with a budget. While a checkout has roots, its panes' process trees are walked every 2 s (one `proc_listchildpids` walk, no file reads); files are read only when a terraform process appears. Panes of checkouts without roots are never walked. The screen (for 3.3's ask) is read on the main thread (`ghostty_surface_read_text`), so only on a cheap signal: the tab waits on the agent (its notification), a terraform runs in the tree, an ask stands, or the pane printed, scrolled, rang or titled since the last look (stage 1c review). An idle agent's pane costs the walk alone.

### 3.3 The agent's ask, marked before anyone answers

The Inbox already reads an agent's question off the screen (`AgentPrompt`). `TerraformPrompt` adds two shapes:
- **an agent's permission prompt whose command parses** (`TerraformCommandLine`) as `apply`, `destroy`, `state rm|mv|push`, `force-unlock`, `import`, `taint`, `workspace delete`, or carries `-auto-approve`: the card names the root, workspace and class, red on production;
- **Terraform's own prompt** ("Do you want to perform these actions in workspace "acme-prod"? … Enter a value:", "Do you really want to destroy all resources?") in a pane where terraform has the tty.

Either marks the tab and, for an agent's tab, notifies, as an agent's question does. A person's own pane, where they are looking, gets the mark only. **Nothing is ever answered by Overterm**: no button types "yes", and no automated reply may answer a `TerraformPrompt`.

### 3.4 Agents launched with Terraform's writes denied

Overterm starts the agents of New Task and of agent tabs (`Agent.command(arguments:)`, with Settings ▸ Agents' extra arguments). For a checkout with a production-class root, `terraform.agentWriteGuard` (on by default) adds, **for that launch only**:
- Claude Code: `--disallowedTools` with, for `terraform`, `tofu` and `terragrunt` × `apply`, `destroy`, `import`, `taint`, `untaint`, `force-unlock`, `state`, `workspace delete`, `refresh`, `test`, `apply-all`, `destroy-all`, three rules each — `Bash(terraform apply:*)` (the documented prefix form), `Bash(*terraform * apply*)` (after flags: `-chdir=envs/prod apply`, `terragrunt run --all apply`) and `Bash(* terraform apply*)` (after an assignment: `TF_WORKSPACE=prod terraform apply`) — plus `Bash(*terraform *-auto-approve*)`, `-migrate-state` and `-force-copy` (https://docs.anthropic.com/en/docs/claude-code/cli-reference). Terragrunt's `run:*` became per-operation rules: `run --all plan` stays the agent's. All comma-joined in one quoted word, last on the line.
- **Stage 1c's check, as done**: running Claude Code reaches its model provider, so it was checked statically against the installed 2.1.322 — its `--disallowedTools` splitter keeps commas and spaces inside parentheses (each rule arrives whole), and its rule linter accepts a `*` anywhere in a `Bash` rule. Whether each rule matches at run time, per command of a compound line, and holds under `--dangerously-skip-permissions` is its documentation's word, **unverified**; the setting ships on (D-8) and its help and the docs say it is unverified. A live check with the owner's consent stays open (in a sandbox, a throwaway checkout, `terraform_data` only).
- **Fails closed**: a checkout not known to have no production root — never read, a capped listing, not a repository — is guarded; "none" is kept only from a complete listing under the same class settings and production identities, and every launch reads again (stage 1c review).
- Codex: no per-command deny flag is known; its approval policy is the nearest lever. Stage 1c: not guarded, and its pane says "terraform writes not guarded" for as long as it runs in a checkout with a production root.

It writes nothing to the user's agent config and puts no shim on PATH. It is weaker than a shim (`bash -c`, a script, `make apply` get around it), and the setting's help says so. It is the strongest guard that touches nothing persistent. A PATH shim stays a rejected default (13, D-8).

### 3.5 The agent gets the plan, masked, with its blast radius

`tf_plan_summary` gives counts, every destroy, replace, forget and action with its reason and cause chain, moves and imports, drift, and the attribute paths that change. Never a value marked sensitive, a sensitive variable, or anything `Secrets` matches; strings cut at 200 characters. It reads the last plan Overterm made for the root, **or a plan the agent saved itself** (`terraform plan -out=X` in its worktree): `show -json X`, the path resolved inside the calling pane's checkout. That meets agents where they already are.

### 3.6 Many worktrees, one state

`TerraformStateIdentity` (pure) keys a root by product, backend type, the backend's location keys and the workspace (4.11). The app's one `TerraformRunRegistry` uses it to:
- name the other worktrees with the same identity on each root ("also open in `bump-eks`");
- run Overterm's plans and applies on one identity one at a time, queued and said;
- after an apply, mark every other plan of that identity stale at once ("applied from `bump-eks` at 14:52: plan again"), before Terraform's own refusal;
- make production sticky (5.1).

### 3.7 The new worktree that would create everything again

A local backend with a relative path keeps state in the checkout, usually gitignored, so a new worktree has none, and `terraform.tfstate.d/` neither [verified for both]. When the same root in another worktree has state and this one has none, the root, the pane header and any plan say "no state in this worktree; the state is in `main`'s checkout", red. A plan with no `prior_state` on a non-`default` workspace, or on a root with state elsewhere, is marked "creates everything: no state found", and its Apply asks for the root's name on every class. New Task never copies the source checkout's workspace selection onto such a root.

### 3.8 The version that would move the team's state

The plan JSON carries both versions: `terraform_version` (the binary) and `prior_state.terraform_version`. A newer minor moves the state forward and older binaries can't read it again. Apply refuses that unless confirmed with "This moves the state of envs/prod to Terraform 1.17; anyone on 1.9 can no longer plan it". Pure, no extra remote read.

## 4. How we run Terraform

### Options

| | How | For | Against |
|---|---|---|---|
| A. Type every command into a terminal tab | `insertText` + `pressReturn()`, as `KubeTabWrite` does | Reuses everything; the person sees it | Overterm owns no descriptor of it: no progress, no cleared environment. The tab's shell has its own `AWS_PROFILE`, direnv, `TF_CLI_ARGS_apply=-lock=false` [verified], aliases and shims, so the plan reviewed and the target applied can differ [verified]. Closing the tab sends SIGHUP: the apply dies at once with the lock held [verified] |
| B. Overterm's own process for reads and plans, applies in a tab | | Progress for plans | Still A's environment and SIGHUP problems for the write that matters most |
| **C. Overterm's own processes for everything it starts; applies detached** | `TerraformRun` on `ProcessGroup`; an apply in a session of its own, writing to files, in the plan's recorded environment | One environment from plan to apply; Stop is graceful; a crash or a quit doesn't kill an apply; progress per row | No scrollback tab (the raw log is shown in the slot); more to build |

**Decision: C.** A pipe and a pty are each a way to kill an apply ungracefully (SIGPIPE and SIGHUP, both verified), and the shell is a way to change its target. What a person or an agent types in a terminal stays theirs, under Sections 3.2–3.4.

### 4.1 Who runs what

| Kind | Commands | How |
|---|---|---|
| Short reads | `version -json`, `workspace list`, `state list`, `modules -json`, `fmt -check -list`, `metadata functions -json` | `TerraformRun.short`: bounded output (1 MB), timeout 30 s, on a GCD thread. **Not** `KubeProcessRun`: that is Kubernetes code with five callers, ends in SIGKILL at quit, and its cap doesn't fit. It is left alone until a third user shows up |
| Large reads | `show -json` (plan or state), `providers schema -json` | `TerraformRun`, stdout streamed into a bounded `Data` (`terraform.maxPlanBytes`, 64 MB) on a GCD thread; beyond it, the stream's summary only |
| Validate | `validate -json` | Credentials stripped (4.5), `-lockfile=readonly` before it if Overterm ran the init |
| Plans | `plan … -out` | `TerraformRun`, its stream read line by line on a GCD thread, decoded off main, applied in 120 ms batches |
| Init | `init -input=false -lockfile=readonly -json` (text below 1.9) | `TerraformRun`, the person's click, serialised per plugin cache (New Task's `init -backend=false`: 4.13) |
| Applies | `apply -input=false -json -lock=true -lock-timeout=60s /dev/fd/3` | `TerraformApplyRun`: detached (4.7) |
| Test (2d) | `test -json -no-color [-filter=<file>]` | `TerraformTestRun`, its stream read as plans' are |
| Lock probe, force-unlock (2e) | `state rm -dry-run …` of an address no configuration has, `force-unlock -force -no-color <id>` | `TerraformRun.short`, not interruptible (they take the lock, or write it): a cancelled task leaves them to end, quitting waits briefly first (4.7) |
| Everything else | `console`, `state mv/rm/push`, `workspace new/delete`, `init -migrate-state`, `taint`, `import` | The user's terminal |

None of Overterm's terraform processes is a `ManagedProcess`, and none is in `ManagedProcess.closeAll` or `KubeProcessRun.stopAll`: those end with SIGTERM at grace 0 and `killpg(SIGKILL)` respectively, wrong for a plan holding a lock.

### 4.2 Which binary

- `terraform.path` (setting), else `mise which terraform` with cwd at the root when `mise` is found and the root or a parent up to the checkout has `mise.toml`, `.tool-versions` or `.terraform-version`, else the first `terraform` on `ShellEnvironment`'s PATH (a Dock-launched app's PATH has no Homebrew).
- Shims (tfenv, asdf) read `.terraform-version` in their cwd, so they run with cwd at the root.
- The result is an **absolute path** and its `version -json` (with `CHECKPOINT_DISABLE=1`: `terraform_outdated` is a call home), cached per (path, root). The plan record keeps both; the apply uses that path and refuses if `version -json` now says otherwise.
- The product is decided by the binary (its name, `tofu version`'s first line "OpenTofu v…"), never by `terraform_version`, which tofu also fills. Features are gated by (product, version). Stage 3 verifies this against a real `tofu`.
- In isolated runs and unit tests the binary is `OVERTERM_TERRAFORM` only; with none, no terraform is found (as no Docker engine is reached without `OVERTERM_DOCKER_HOST`).

### 4.3 The commands, exactly

| Use | Command (cwd = the root; never `-chdir`, so `range.filename` is relative to it) |
|---|---|
| Plan, a person's | `plan -input=false -json -detailed-exitcode -lock=true -lock-timeout=10s -out=<run folder>/plan [-var-file=<path inside the root>]… [-parallelism=N]` |
| Plan, an agent's | the same with `-lock-timeout=0s`: a held lock is reported, never queued behind CI |
| Show | `show -json -no-color /dev/fd/3` |
| Apply | `apply -input=false -json -lock=true -lock-timeout=60s /dev/fd/3` |
| Refresh-only (2d) | `plan -refresh-only` with the person's plan flags |
| Init | `init -input=false -json -lockfile=readonly` (no `-upgrade`, `-reconfigure`, `-migrate-state`, `-force-copy`, ever) |
| New Task's init (2b) | `init -backend=false -input=false -lockfile=readonly -no-color`, validate's environment (no credential, no workspace) |
| Validate, version | `validate -json -no-color`, `version -json` |
| Format | `fmt -no-color -` (a buffer on stdin), `fmt -check -list=true [-recursive] -no-color`, an agent's `fmt -check -diff -no-color` |
| Workspace list | `workspace list` |
| Workspace select | `workspace select <name>` with `TF_WORKSPACE` removed (it refuses unknown names; `-or-create` never) |
| State (2c) | `state list -no-color`, then `show -json -no-color` (the state, no file named) |
| Test (2d) | `test -json -no-color [-filter=<test file, relative to the root, inside it>]` |
| Lock probe (2e) | `state rm -dry-run -lock=true -lock-timeout=0s -no-color terraform_data.overterm_lock_probe` |
| Force unlock (2e) | `force-unlock -force -no-color <lock ID>` (one ID parsed from Terraform's own diagnostic in this window, probed just before) |

- This table is `TerraformCommands.all`, `plan(…)`, `workspaceSelect(_:)`, `test(file:)` and `forceUnlock(id:)`: nothing else is built, and `TerraformCommands.refusal` refuses any other line before it starts.
- `TerraformCommands` is pure and cannot express `apply` without a plan, `-auto-approve`, `-lock=false`, `-refresh=false`, `-minimal-refresh`, `-target` on an apply, `-var` with a value, `-backup`, or any `init` flag above. A test enumerates every builder output and asserts it.
- An exit code decides, never the stream: plan 0 (no changes), 2 (changes), 1 (failed, even though a plan file was written on a failing precondition [verified]).
- `planArgs` is not free text: `terraform.roots.<r>` allows `parallelism` (an integer) and var files inside the root, nothing else.

### 4.4 Plan files: a folder per process, then an fd

- **The folder.** `$TMPDIR/ot-tf-<uid>-<pid>/`, made 0700, after `KubeSocketFolder`: one per app process, a run folder per plan inside it. Isolated runs and unit tests put it under `AppEnvironment.supportDirectory`'s scratch, so an E2E run never touches the user's app's folder. At launch, a sweep removes only folders whose pid is dead **and** whose detached apply (4.7) is not alive.
- **The mode.** `posix_spawn` has no umask, and the app's own umask is process-wide, so plans start through `/bin/sh -c 'umask 077; exec "$0" "$@"'`. The 0700 folder protects the file either way.
- **The fd.** When `plan` exits 0 or 2, Overterm opens the file, hashes it from that fd, and unlinks the path. From then on the plan is the fd: `show -json /dev/fd/3` and `apply /dev/fd/3` take it as fd 3 [verified both]. There is no path left to swap, nothing to sweep after a crash, and nothing in Time Machine.
- **What it leaves.** For the seconds between `plan` writing the file and Overterm unlinking it, a same-user process can read it. An agent runs as the same user; the 0700 folder keeps out other users, not the agent. That is said in Section 5.12.
- The SHA-256 is still kept and checked before apply: it is cheap, and it catches a bug of ours.

### 4.5 The environment

Every run gets `TerraformEnvironment.build(for:)` (pure):

| | Rule |
|---|---|
| Base | `ShellEnvironment.environment()`, the user's login shell's, so credential chains (SSO, `aws-vault`, gcloud ADC, `ARM_*`, `TF_TOKEN_*`) reach providers unchanged. Values are never read except the names in 3.2 |
| Removed | `TF_CLI_ARGS`, every `TF_CLI_ARGS_*` [verified to inject `-auto-approve` and `-lock=false`]; `TF_LOG`, `TF_LOG_PATH`, `TF_LOG_CORE`, `TF_LOG_PROVIDER` [verified to log `-var` values]; `TF_REATTACH_PROVIDERS` (it bypasses the lock-file hashes); an inherited `TF_WORKSPACE` and `TF_DATA_DIR` |
| Set | `CHECKPOINT_DISABLE=1`, `TF_INPUT=0`, `TF_IN_AUTOMATION=1`, `TF_DATA_DIR=<root>/.terraform`, `TF_WORKSPACE=<the checked workspace>` (4.9) |
| Opt-in | `TF_PLUGIN_CACHE_DIR` (4.13) |
| Validate and agents' reads | Also every `AWS_*`, `GOOGLE_*`, `CLOUDSDK_*`, `ARM_*`, `AZURE_*`, `TF_TOKEN_*`, `TF_VAR_*`, `VAULT_*`, `KUBECONFIG` removed, and `HOME` a scratch folder: validate needs none of them, and the providers it starts get none |
| Isolated runs, unit tests | `AppEnvironment.guardsTerraform`: nothing from the user's shell; `HOME` and `TF_CLI_CONFIG_FILE` (an empty file) scratch; `TF_DATA_DIR` scratch; the scenario runner refuses to start when its own environment carries any credential variable |

- An inherited `TF_DATA_DIR` shared by every root mixes backends and workspace selections; it is never used, and the root card says "your shell sets TF_DATA_DIR; Overterm uses the root's .terraform".
- `dev_overrides` in the user's CLI config make Terraform use an unlocked provider binary. Its warning ("Provider development overrides are in effect") greys Apply with that reason.
- `TF_ENCRYPTION` (OpenTofu) carries key material: in `Secrets`' names, passed through, never shown.

### 4.6 One environment from plan to apply

A saved plan doesn't pin where it applies [verified, spike 6]. So `TerraformPlanRecord` (memory only) holds:
- the run's whole environment as built for the plan, and the absolute binary and its version;
- the root, workspace and `TF_DATA_DIR`;
- the plan's fd and its SHA-256, `timestamp`, `prior_state`'s lineage and serial (from the zip's `tfstate`, through a small pure central-directory reader), `applyable`, `complete`, `errored`;
- the masked plan model and its risk list (5.4);
- for an ephemeral variable given at plan through a one-shot field: its value, in memory only, dropped when the record is.

The apply gets **that environment**, with the ephemeral variables as `TF_VAR_<name>` (never `-var`: argv is visible to `ps` and to `TF_LOG`) [verified that both `-var` and `TF_VAR_` work for an ephemeral variable, and that nothing else does]. The names come from `configuration.root_module.variables.<n>.ephemeral`; the plan JSON has no `variables` entry for them.

What this leaves: a credential that lives in a file (an SSO cache, `~/.aws/config`'s profile contents) can change between plan and apply. The review header names the profile and region of the run's environment, so the person sees which account the plan was made for. And the app's `ShellEnvironment` is captured at launch: a later `export AWS_PROFILE` in a tab doesn't reach Overterm's runs. The header says which profile Overterm uses; "Plan with this pane's environment" is a later idea, not stage 2.

### 4.7 Stop, signals, and an apply that outlives the app

- **Stop** = `killpg(pgid, SIGINT)` once, what Ctrl-C in a terminal sends. Pid-only and group SIGINT behave the same [verified]: graceful, state written, lock released, an in-flight provisioner cancelled and its resource **tainted**. go-plugin providers ignore SIGINT and wait for core's `Stop`. A second, confirmed Stop sends SIGINT again ("exit now, data loss may occur"). `killpg(SIGKILL)` only after terraform has exited, to sweep stray plugins.
- **The apply runs detached**: spawned with `POSIX_SPAWN_SETSID`, a new option on `ProcessGroup.spawn` (its own session, so no controlling tty and no SIGHUP), stdout and stderr to 0600 files in its run folder, its pid and start time in a small JSON file there. Overterm tails the files; no pipe can SIGPIPE it [verified that one would].
- **Crash or quit.** The apply keeps going. At launch the sweep finds a run folder whose apply pid is alive with the same executable and start time, and the right slot says "an apply in envs/prod has been running since 14:41, started before Overterm last quit", with Stop. It reattaches by tailing the files.
- **Quit while an apply runs** asks "Quit and let it finish / Cancel". It never waits on a minutes-long graceful stop at quit (no `.terminateLater` machinery); Stop is a separate act in the slot.
- Plans and reads stay in the app's process group; quitting stops them with SIGINT and doesn't wait. The short runs that take a lock or write — New Task's `init -backend=false`, the lock probe, `force-unlock` — are given up to 3 s to end first (`TerraformRun.stopAll`), then interrupted; a force-unlock interrupted says the lock may or may not have been removed.
- Long runs: `apply_progress` every 10 s is the heartbeat; a silence over 2 minutes is said, never acted on.

### 4.8 Closing a pane where terraform writes

Overterm's own applies are detached, so closing never touches them. What remains is terraform typed in a pane, a person's or an agent's: closing sends SIGHUP and kills an apply at once [verified]. `TerraformCloseGuard` (its decision pure) is consulted by **all four close paths**: `closePane(_:in:)` (it checks `pane.needsConfirmClose`, not `needsCloseConfirmation`), `closeTabs`, `windowShouldClose` and `applicationShouldTerminate`. For every pane in `tab.terminals`, it finds terraform processes in the pane's tree by pid (never `pkill -f`, never `lazy.compactMap(…).first`) and their operation from `arguments(of:)`. For `apply`, `destroy`, `import`, `state *`, `force-unlock` or `workspace delete`, the close asks, whatever the close setting says:

> terraform apply is running in envs/prod (this pane). Closing kills it at once: the lock may stay held and what it was creating may be lost.
> **Interrupt** / Close Anyway / Cancel

**Interrupt** sends SIGINT to that terraform's group and cancels the close; the pane shows Terraform shutting down, and a notice offers "Close now" when it exits. All four paths stay synchronous. A scenario drives the tab, window and pane sheets (`window.attachedSheet`/`endSheet`, as `E2ERunner+CloseKeys.swift` does); the quit `runModal` is covered by the pure decision's tests.

### 4.9 Workspaces

- **Every run checks its workspace exists before it starts**: the local backend's `terraform.tfstate.d/<ws>` (or `default`); a remote backend's last `workspace list`, cached per identity and refreshed on a miss. A workspace that doesn't exist refuses the run: "Workspace acme-stage no longer exists in s3 acme-tfstate". This covers both verified traps: `TF_WORKSPACE` naming it, and `.terraform/environment` naming it (spikes 13, 14).
- Overterm's runs pass `TF_WORKSPACE` explicitly, set to the checked name: the root's chosen workspace in `TerraformRootStore`, else what `.terraform/environment` says, else `default`.
- **Terminal tabs are never pinned by `TF_WORKSPACE`.** In a pinned shell `workspace select` and `workspace new` refuse, `init` creates the named workspace, and the pin follows `cd` into a sibling root [all verified]. "Terminal in this root" opens a tab with cwd at the root, a `TabKind.terraform` icon, and the pane header saying the workspace `.terraform/environment` selects. The `TF_DATA_DIR=/dev/null/…` trick (spike 17) is not needed without pins.
- The chip's Select runs `workspace select` (4.3) and says it writes the checkout's `.terraform/environment`, which every terminal in that root then follows.
- `cloud { workspaces { name = … } }` can't be switched; with `tags`, `TF_WORKSPACE` selects among them.

### 4.10 Locks

- Overterm's plans take the lock (`-lock=true`), 10 s for a person's, 0 s for an agent's; applies 60 s. `-lock=false` is never built, for anything.
- A held lock is parsed only from `Error acquiring the state lock`'s `detail` (`TerraformLockInfo.parse`, pure): `ID`, `Path`, `Operation` (`OperationTypeApply`, `OperationTypePlan`), `Who` (`user@host`), `Version`, `Created` (a Go time string, `2026-11-08 11:42:46.353924 +0000 UTC`), `Info`; the http variant's `HTTP remote state already locked:`. `cloud {}`/`remote` roots say "workspace … is locked by run …": said as an HCP lock, never through this parser.
- **A `.lock.info` file is never read or deleted.** On the local backend the lock is an OS lock that went with its process; a leftover file is not a lock [verified].
- When `Who` is this Mac's `user@host`, Overterm looks for a live terraform in that root in every pane and in its own registry, and says "no Terraform is running on this Mac; the lock is 3 h old" when there is none.
- **Force unlock (stage 2e)** is offered only from a lock parsed in this window. Just before running it, the probe (`state rm -dry-run -lock-timeout=0s` on an address that doesn't exist) must fail with the **same ID**; it takes the lock without refreshing or starting a provider, and changes nothing when free [verified on local; to check against `FakeTerraformBackend` before it is relied on for s3 and gcs]. A `plan` is never the probe: if the lock was released meanwhile, it runs a full plan against production. The sheet types the root's name, names the holder and says "if that apply is still running, its state write will collide with the next run". On the http backend (GitLab-managed state too), UNLOCK goes with an empty body [verified], so it removes whatever lock is there: said on the sheet.

### 4.11 Backends and the state identity

| Backend | Identity (default workspace / other workspaces) | Lock | Note |
|---|---|---|---|
| `local` | the absolute state path; `path` applies to `default` only [verified]; others `<workspace_dir, default terraform.tfstate.d>/<ws>/terraform.tfstate` | OS lock | Usually per worktree (3.7) |
| `s3` | `bucket` + `key`; others `<workspace_key_prefix, default env:>/<ws>/<key>` | `use_lockfile` → `<key>.tflock` (experimental 1.10, GA 1.11); DynamoDB deprecated | `profile`, `role_arn` are production signals |
| `gcs` | `bucket` + `<prefix>/<ws>.tfstate` | `<prefix>/<ws>.tflock` | |
| `azurerm` | account + container + `key`; others `<key>env:<ws>` (no slash) | blob lease | |
| `kubernetes` | Secret `tfstate-<ws>-<secret_suffix>` | Lease `lock-tfstate-<ws>-<secret_suffix>` | its context is a signal, by `KubeClassifier` |
| `pg` | schema `terraform_remote_state`, table `states`, a row per workspace | advisory lock | |
| `http` | `address` (host and path) | `LOCK`/`UNLOCK` | force-unlock's empty body |
| `cloud {}` / `remote` | `organization` + workspace name | server-side | remote execution (2.8) |

The backend is read from `.terraform/terraform.tfstate` (the init record) **and** from the HCL block, each through an allow-list of keys (`type`, `bucket`, `key`, `prefix`, `region`, `profile`, `role_arn`, `organization`, `workspaces`, `address`, `path`, `workspace_dir`, `workspace_key_prefix`, `use_lockfile`, `dynamodb_table`, `storage_account_name`, `container_name`, `secret_suffix`); nothing else is decoded. **Never `Secrets.isSecret`** for this: its substring match on `KEY` would hide the S3 `key` and `workspace_key_prefix`. When the HCL and the init record differ, plans refuse: "the backend changed since init: run init in a terminal". Overterm and agents never pass `-reconfigure` or `-migrate-state`.

### 4.12 Finding roots

1. **Candidates, one git call** (`Git.run`, gitignore-aware, so `.terraform/`, `.terragrunt-cache/` and `node_modules` are skipped): `ls-files -z --cached --others --exclude-standard --` with the patterns of 2.1. Capped at 20,000 matches and 2,000 folders, said when capped. Outside a git checkout, `KubeCheckoutScan`'s bounded walk with `isRepositoryRoot` (never from `~` or `/`).
2. **Classify folders** (`TerraformRootGuess`, pure, at most 120 files and 256 KB each):
   - root: a `backend` or `cloud` block, a committed lock file, `*.tfvars` beside it, a configured `provider` block;
   - child module: a local `source` of another folder's `module` block (`TerraformBlocks`, a line-and-brace scan of top-level blocks, or `modules.json`'s `Dir` once initialised), or under `modules/`;
   - example or test: under `examples/` or `test(s)/`, or with `*.tftest.hcl`; listed, folded;
   - Terragrunt: a `terragrunt.hcl` with `terraform { source }` is a unit; `root.hcl` or a top-level `terragrunt.hcl` is config.
3. **Per root, cheap facts, read only while shown:** `.terraform/environment`, the backend record (allow-listed), `modules.json`, the lock file's providers, `terraform.tfstate.d/*` names, whether a local state file exists.
4. **"Needs init"** is never "no `.terraform/` folder": a root with only `terraform_data` initialises without one [verified]. It is a validate or plan answering `Backend initialization required` / `Module not installed`, or a `required_providers` entry with no lock entry.
5. **Which root a file belongs to:** the nearest root above it, bounded, stopping at `pathComponents.count <= 1` (CLAUDE.md). A module file belongs to every root whose `modules.json` or static source graph reaches it.
6. **Watching:** the window's `DiffModel` stream already watches the checkout; the panel takes its "files changed" from it rather than opening a second one (CLAUDE.md). Under `.terraform/`, only `environment`, `terraform.tfstate` and `modules/` count; `init` writes ~50 MB into `providers/`, and `DiffModel` must not recount on those events (checked by a scenario).

### 4.13 Init and the plugin cache

- Init is a person's click, never an agent's tool, never automatic — with one exception: New Task's `init -backend=false -input=false -lockfile=readonly` (stage 2b, `terraform.newWorktreeInit`, on by default) in a worktree it just made: no backend, the lock file read only, validate's environment (no credential, a scratch HOME, no workspace; no agent socket, no system gitconfig), and only in a root whose fetch list flags nothing — every provider the root and its local modules name, required or implied, in the lock file; every module local or a registry module at an exact version, never a remote source outside the registry whatever its ref; never an HCP root. Its CLI config allows registry installs with no `credentials` block (a guarded run's fetches nothing); the panel's Init and Plan of that root wait while it runs. Before the person's Init, the slot lists what will be fetched, read statically: provider sources and constraints, module sources, and a flag on anything not a registry source with an exact version (a branch ref, a bare git URL, an `http://` source) or a provider not in the lock file. Modules are not locked by the lock file.
- `-lockfile=readonly` always; a lock-file change is a separate, confirmed "Upgrade providers…" whose diff shows in the changes pane, as any edit does.
- **The plugin cache.** Each worktree's `.terraform/providers` holds its own copies: 50 MB for three tiny providers, hundreds of MB for a cloud one. At the first Init in a window where two worktrees of one repository have roots, Overterm offers `TF_PLUGIN_CACHE_DIR` under a new `AppEnvironment.terraformCacheDirectory` (`~/Library/Caches/<bundle id>/Terraform/plugins`; a scratch folder in isolated runs, so a scenario never writes executables into the real cache) for its own runs only. It never writes `~/.terraformrc`. Inits on one cache run one at a time, app-wide ("not guaranteed to be concurrency safe"). It is not offered when the user already has a CLI config (`TF_CLI_CONFIG_FILE` set, or `~/.terraformrc` exists: checked for existence only, never opened, since it can hold `credentials` blocks) or `TF_PLUGIN_CACHE_DIR` in the environment. `plugin_cache_may_break_dependency_lock_file` is never set.

### 4.14 The editor

- **Tree-sitter.** One `GRAMMARS` line in `Scripts/build-treesitter.sh`: `"hcl|https://github.com/tree-sitter-grammars/tree-sitter-hcl|9e3ec9848f28d26845ba300fd73c740459b83e9b|-"`. The sparse checkout already takes `runtime/queries`, so `hcl/` (highlights, indents, folds, injections, textobjects) comes along; `tfvars/` is only `; inherits: hcl`. `EditorLanguage("hcl", "Terraform", extensions: ["tf", "tfvars", "hcl", "tofu", "nomad"], fileNames: [".terraform.lock.hcl", "terragrunt.hcl", "root.hcl"], aliases: ["terraform", "tf", "tfvars", "opentofu"], lineComment: "# ", blockComment: ("/*", "*/"))`; `x.tftest.hcl` falls to `hcl` by its last extension; `*.tf.json` stays JSON.
  - Helix's `hcl/injections.scm` injects `comment`, which has no grammar here; `SyntaxDocumentTests` must be run on that, not assumed.
  - Editing the script changes CI's frameworks cache key (`ci.yml`, `release.yml`), so the next CI run rebuilds GhosttyKit too, with Zig, once; every developer re-runs `make treesitter`.
- **terraform-ls.** `Spec(id: "terraform", extensions: ["tf": "terraform", "tfvars": "terraform-vars", "tofu": "opentofu"], rootMarkers: [], launch: [.executable("terraform-ls", ["serve"]), .zedTerraformLS])`:
  - `rootMarkers: []` makes the root the git top, a linked worktree's `.git` file included: one server per worktree, the cost said;
  - `.zedTerraformLS` is a **new** `ServerDiscovery.Candidate` (the newest `terraform-ls-<version>/terraform-ls` in Zed's extension work folder, as `zedGopls` picks), with its own test;
  - a new `Spec.initializationOptions` (a `Hashable`, `Sendable` JSON value, since `Spec` is a dictionary key): `indexing.ignoreDirectoryNames` (`.terragrunt-cache`, `node_modules`: names wherever they are — `indexing.ignorePaths` takes whole paths), `terraform.path` (the binary of 4.2, added at launch as far as it is known without waiting: the login shell is asked when a Terraform file opens), `experimentalFeatures.validateOnSave: false`;
  - a new `Spec.environmentRemoved`: the credential names of 4.5, so the server and the `terraform validate` it runs never get them;
  - a new `Spec.environmentAdded`, set over the app's and the command's variables (a removed name still wins): `CHECKPOINT_DISABLE=1` always (5.13 rule 11) and `HOME` a scratch folder (4.5, "Validate and agents' reads"), since the stripped variables alone leave `~/.aws`, `~/.config/gcloud` and `~/.terraform.d/credentials.tfrc.json` readable to the providers `validate` starts;
  - **`workspace/didChangeWatchedFiles`**: terraform-ls relies on the client since #953, or it never hears of an `init` or an agent's files. `DirectoryWatcher` reports folders only, so it gains a `fileEvents:` option (`kFSEventStreamCreateFlagFileEvents`, with created/changed/removed flags passed through), a pure `LSPGlob` matcher handles `GlobPattern`/`RelativePattern`, and `client/registerCapability` (only acknowledged today) is answered. Declaring `dynamicRegistration: true` changes gopls' and rust-analyzer's behaviour too (they stop watching for themselves), so stage 0 checks each existing server.
  - **Stage 0's check, as done.** Each server's registration is a fixture in `LSPWatchedFilesTests`: gopls v0.21.1 and sourcekit-lsp captured from the installed servers; clangd registers nothing; rust-analyzer as its `reload.rs` builds them; pyright/basedpyright as `languageServerBase.ts` builds them — `**` and its config files on the root, plus `**` on each search path outside it (the standard library, site-packages, the user's site: three extra file-level FSEvents roots on a Homebrew Python, of the 16 allowed); vtsls as VS Code's TypeScript extension asks for tsserver's watches (a registration per folder or file: `node_modules/@types`, a lookup's parent beside the root, its own TypeScript's `lib`). pyright and vtsls aren't installed on this Mac and nothing was downloaded to capture them, so theirs are modelled on the sources; typescript-language-server (its tsserver watches for itself), the json, yaml and bash servers weren't captured either. The rule against `/`, a volume's top, the home folder and above holds for the root too: a `.py` opened from `~` with no marker makes `~` the root, which is then not watched — only the registered folders that pass. Events under a folder outside the root go back in the server's own spelling (`/tmp`, a link), not FSEvents' real path.
  - Tests and isolated runs launch no real server (`mayLaunchRealServers`).
- **Without terraform-ls** (this Mac): F12 on `var.x`, `module.y`, `local.z` by `TerraformConfigIndex`; ⇧⌘O symbols from the same index; validate diagnostics (UTF-8 columns converted to UTF-16, as `SyntaxDocument` does).
- **The editor bar** (`EditorViewController+Terraform`, like `showManifestBar`) over a `.tf` file: its root, workspace, class band, Plan, Validate, Format. Format replaces the buffer's text through `replaceText`; nothing is written behind it.

### 4.15 Formats

- The stream: `@level`, `@message`, `@module`, `@timestamp`, `type`; `ui` "1.3". A minor bump adds fields; an unknown major refuses to parse ("this Terraform's output is a version Overterm doesn't read"). A line that isn't JSON (panics, crash output) is kept as raw log text.
- Messages interleave across resources; correlate by `hook.resource.addr` and, for a replace's two phases, by `(addr, action)`. `planned_change` omits no-ops [verified], so the resource list and counts come only from `show -json`'s `resource_changes`.
- The plan representation: `format_version` "1.2". Every collection key is optional: absent means empty (`resource_changes` on a refresh-only plan, `prior_state` on an empty workspace, `resource_drift`, `output_changes`) [verified]. An unknown **major** refuses.
- **An unknown top-level key** in a plan (as `action_invocations` was, in 1.14) is not dropped silently: the plan is "partly understood" and Apply is greyed with the key named, "apply it in a terminal". The decoder learns it in a PATCH.
- `outputs` in an apply stream omit `value` for sensitive ones [verified]: still masked by `sensitive`, never by absence.

## 5. Security for infrastructure that is real

### 5.1 Classes and how a root is recognised

A class belongs to a (root, workspace): one folder with three workspaces can be three classes.

| Class | Recognised by | Default |
|---|---|---|
| **Production** | Any signal matches `terraform.productionPattern`, or the state identity was ever production | Red everywhere; writable like any root, each plan gate's question and every apply asked with the root's name typed. `writable: false` makes it plan only (the owner's decision, 1.6.0: no session switch) |
| **Local** | A local backend inside the checkout **and** every condition below | Writable |
| **Remote** | Everything else | Writable unless the root's `writable` is false |

**Signals**, all read without running Terraform and without credentials, by name only:
1. the workspace (the checked one, 4.9);
2. the root's path relative to the repository (`infra/envs/prod/network`);
3. the backend's location keys (4.11), from both the init record and the HCL;
4. the var files the run uses (`prod.tfvars`) and backend-config files (`prod.s3.tfbackend`, `backend/prod.hcl`);
5. `AWS_PROFILE` in the run's environment, a literal `profile` or `role_arn` in a provider or backend block, and an account ID in any `arn:aws:iam::<12 digits>:` matched against `terraform.productionAccounts`; a literal GCP `project` or Azure `subscription_id`. `~/.aws/config` is never read: a profile's name is the signal, not its contents.

The branch is shown on the chip but is **not** a signal: branches name the work (`fix/prod-logging`), not the target.

**The pattern** defaults to Kubernetes' with a trailing digit run allowed, `(^|[-_/.:@])(prod|prd|production|live)\d*([-_/.:@]|$)`, so `prod1`, `prd01`, `prod2-eu` and `production2` match. A `live` that is the top folder of a Terragrunt tree (its canonical `live/<account>/…` layout) is structure, not a signal.

**Local is strict**, because "local backend and local providers" is not local [verified, spike 21]. A root is local only if, statically in the HCL and again in the plan JSON:
- its backend is `local` with a path inside the checkout;
- it has no `provisioner` block;
- it has no `local_command` data source, ephemeral resource or action, no `external` or `http` provider;
- it has no `terraform_remote_state` whose backend isn't local inside the checkout (one reads another root's state, production's included);
- its providers are only `null`, `random`, `local` (no `local_command`), `time`, `tls` and the builtin `terraform.io/builtin/terraform`, matched on (namespace, type) over `registry.terraform.io` and `registry.opentofu.org`; a `kubernetes`, `helm` or `docker` provider counts only when its context or host is a **literal** that `KubeClassifier` calls local;
- its providers are pinned by a lock file.

**Precedence:**
1. production by any signal, or by identity;
2. a class set by hand in `terraform.roots` — which can only **raise**: "remote" over local, "production" over anything. "Not production after all" is a change to the pattern, never a setting (a production root is writable anyway: what its class adds is confirmation);
3. local by the rule above;
4. remote.

**Production is sticky by identity.** Any root whose `TerraformStateIdentity` equals one seen production is production, in every worktree and under any folder name. Renaming `envs/prod` to `envs/p`, on a backend key with no "prod" in it, keeps the class. The identities seen are kept by `TerraformRootStore` in the support folder (names only).

Pinned in `TerraformClassifierTests`, as in `KubeClassifierTests`: production for `acme-api/prod`, `infra/envs/prd/eks`, the bucket `acme-tfstate-production`, `globex-live`, `prod1`, `prd01`, `production2`, the workspace `production`, `prod.tfvars`; not production for `product-catalog`, `delivery`, `envs/staging`, `reproduce`; production for `envs/prod-copy` on a local backend; remote for a root with a `local-exec` or `data "local_command"`, a `terraform_remote_state`, a `kubernetes` provider with no literal context; local for `random` + `local` + a lock file.

### 5.2 What each guarantee covers

| Guarantee | Covers | Doesn't cover |
|---|---|---|
| Terraform's saved plan | Its config snapshot, the state's lineage and serial (stale refused), the workspace | Credentials, account, region, kube context, provisioner environment: read again at apply [verified] |
| Overterm's one environment (4.6) | The same environment, binary and data dir from plan to apply | What lives in files the environment points at (SSO caches, `~/.aws/config`) |
| The fd-held plan (4.4) | Nobody swaps the file after it is written | The seconds before it is unlinked; same-user processes reading it then |
| `TerraformProcessCheck` | Every process Overterm starts, against the root's class | Anything typed in a terminal |
| The pane header and the Inbox (3.2, 3.3) | Seeing what a terminal's terraform is about to touch, and the moment before an agent's apply | Stopping it; a command run another way (`bash -c`, a script) is seen only as "probably" |
| `agentWriteGuard` (3.4) | Claude Code's own `terraform apply/destroy/state …` tool calls, in agents Overterm launched | Agents started outside Overterm; indirection (`make apply`); Codex until verified |
| MCP tools (5.10) | What an agent gets through Overterm: never a secret, never an apply in stages 1–2 | What it does in its own shell with the user's credentials |

Said in the panel's help and the page's: "Overterm checks what it runs. What you or an agent type in a terminal is your own terraform, with your credentials."

### 5.3 What changes infrastructure: verbs by class

| Verb | Read-only root (`writable: false`, any class) | Writable root | Overterm's form |
|---|---|---|---|
| `version`, `fmt`, `validate`, `workspace list/show`, `state list`, `show -json`, `modules`, `providers schema` | Started | Started | 4.1; validate with credentials stripped |
| `init` | Started on the person's click; downloads code, changes no infrastructure. The one exception: New Task's `init -backend=false` in a new worktree's root whose fetch list flags nothing (4.13) | Same | 4.13 |
| `plan -out` | Started. It runs provider code and data sources with the user's credentials and takes the lock: the first plan per root and session on production asks ("Plan on acme-api · prod runs its providers with AWS_PROFILE acme-prod-admin") | Started | 4.3 |
| `workspace select` | Started, said as a write to the checkout's data dir | Same | 4.9 |
| `apply <plan>` | **Refused** | 5.4 | The only apply |
| `plan -destroy` → apply | Plan started; apply refused | Root's name typed, every class | 2a |
| `apply -refresh-only` | Refused | Asked | 2d |
| `force-unlock` | Allowed: a stale lock on a read-only root blocks the person's own CI; parsed ID, probed, root typed | Same | 2e |
| `state rm/mv`, CLI `import`, `taint`/`untaint`, `state push`, `apply` without a plan, `-auto-approve`, `-lock=false`, `workspace new/delete`, `init -upgrade` by an agent | **Never built**, any class | Never | `removed`/`moved`/`import` blocks through plan and apply; the rest in a terminal |
| A terminal in a root | Opened; header red on production; nothing enforced | Opened | 4.9 |

`TerraformProcessCheck.refused(verb, rootClass, writable)` (pure, the analogue of `KubeProcessCheck`) is the one place this table lives; a unit test runs every verb against every class and writable value.

**Writes on production** — the owner's decision (1.6.0), replacing the session switch this section first had: a root is writable by default whatever its class, and `terraform.roots`' `writable: false` makes one plan only. Production keeps every confirmation: red everywhere, the plan gate's questions (its first plan asked, risks), the apply sheet with the root's name typed, every 5.4 check. Nothing has to be turned on first. Agents are unchanged: `tf_plan` is never offered on production, there is no `tf_apply`, and an agent's `tf_test` with real providers is refused on production and runs on a remote root only where its entry sets `writable: true` (`TerraformTestRun.writable`), as before the default changed.

### 5.4 Applying a shown plan

Checked in order, each refusal with its reason, never run:
1. **Applyable:** `applyable && !errored`. `complete == false` (a `-target` plan, deferred changes) is refused on production and labelled "partial" elsewhere: deliberate, since `-target` is break-glass and a partial apply on production is its own risk.
2. **Same plan:** the fd's SHA-256 equals the record's.
3. **Same place:** the binary's path and version, the workspace (it still exists, 4.9), the data dir and the environment are the record's; the lock file's hash equals the one in the plan zip [verified: an edited lock file fails the apply].
4. **Understood:** no unknown top-level key (4.15); no `dev_overrides` warning.
5. **Age:** at most `terraform.planMaxAgeMinutes` (30). Terraform's stale check sees state writes, not cloud drift.
6. **Not stale in the registry:** no apply on the same identity since the plan.
7. **Version:** the plan's `terraform_version` isn't a newer minor than `prior_state.terraform_version`, or the person confirmed 3.8's sentence.
8. **State exists:** no `prior_state`, on a non-`default` workspace or on a root with state in another worktree, is "creates everything: no state found" (3.7), red, root's name typed on every class.
9. **Risk list read:** shown above the sheet's buttons (below).

Overterm does not reimplement the lineage and serial check: Terraform's refusal is authoritative, shown as "Someone changed the state since this plan: plan again". The review shows the lineage and serial the plan was made against.

**The sheet** (`WriteConfirmation`) names the root, worktree, branch @ commit, workspace, backend identity and class, red on production; the counts; every destroy, replace, forget and action invocation by address (the first 50, all in the scroll view), each address with non-printables escaped as `DockerMCP.displayed` does (a `for_each` key can hold bidi or zero-width characters); the risk list; the profile and region of the run's environment; and the exact command.

**Typed names:**
- **every apply on production:** the root's display name, `@<workspace>` when it isn't `default` (`envs/prod@acme-eu`). In-place updates can be the worst change (`deletion_protection = false`, `force_destroy = true`, an ingress opened to `0.0.0.0/0`), so the class decides, not the actions;
- destroy plans and "creates everything": the same, on every class;
- elsewhere a confirmation, with **risky updates** highlighted: `deletion_protection`, `force_destroy`, `skip_final_snapshot`, `prevent_destroy` removed in this branch's diff, `*policy*`, `cidr_blocks` containing `0.0.0.0/0`, `ingress`. Labelled a heuristic;
- force unlock: the root's name, every class.

**The risk list** (`TerraformRunRisks`, pure, over the HCL against the base branch's and the plan JSON): `external`, `http` and `local_command` data sources; providers added against the base's lock file; module sources changed; provisioners; `terraform_remote_state`; actions. It is computed for every plan. When non-empty for a plan **of code the person didn't write** (5.5), the Plan button asks first, listing it; on a plan's apply sheet it is always shown.

### 5.5 Planning code you didn't write

A plan executes the configuration: data sources, providers, modules [verified: `data "local_command"` ran during plan]. Atlantis's security page says it plainly: apply approvals are not enough, because plan runs the PR's code.
- **Planning a commit the person didn't author, or a branch they didn't create** (a review tab, a pull request, a teammate's branch) always asks, on every class, with the risk list.
- **"Plan this" after an agent's edit** asks only when the risk list is non-empty against the base branch. A plan whose risk list is empty runs on the click.
- **No automatic plan, of anything, ever:** not on save, not on an agent's edit, not on a branch switch, not on a schedule.

### 5.6 Secrets: plans, state, outputs, logs

Clear values are in [verified]: the plan file (state, `-var` values, backend credentials); `show -json` of a plan (`before`/`after`, `variables`, `output_changes.*.before`, `prior_state`, `planned_values`, `configuration…constant_value`, `relevant_attributes`, `checks`, `action_invocations[].config_values`, `diagnostic.snippet.values`); `show -json` of state; `state pull/show`; `output -json` and `output NAME`; `.terraform/terraform.tfstate`; the stream's `provision_progress.output` and `apply_complete.id_value`; `TF_LOG` traces.

**Rules:**
1. **The decoder is an allow-list** (`TerraformPlan`, pure). It keeps, per resource change, the address, mode, type, name, index, provider, `actions`, `action_reason`, `replace_paths`, `previous_address`, `importing.id`, and `before`/`after` walked against `before_sensitive`/`after_sensitive` and `after_unknown`; per output, its actions and its value only when neither mirror marks it; per variable, its name and whether it is sensitive or ephemeral (from `configuration`); from `configuration`, only `references` (never `constant_value`); from `prior_state`, its lineage, serial and `terraform_version` only; `resource_drift` as resource changes; `action_invocations` masked by `config_sensitive`; `checks` by address and status. **Everything else is dropped at decode**, so a new Terraform field can't leak by default.
2. **Mask at decode.** A leaf whose mirror is `true` becomes `.sensitive`; a whole object or list when its mirror is `true`. No clear value survives into a model a view, a log or a tool could read. The raw `Data` is dropped once decoded.
3. **Then `Secrets`.** Every kept string goes through `Secrets.scrub`: unmarked secrets (`user_data`, a container's `environment`, a Helm values string) are only caught by heuristics, and the plan view says "masked by Terraform's marks and Overterm's rules".
4. **Attribute names: a narrower list.** `Secrets.isSecret` is a substring match on `KEY`, `AUTH`, `SESSION`, `TOKEN`…; in a plan diff it would hide `key_name`, `public_key`, `kms_key_id`, `ssh_keys`, `session_name` and `auth_mode`, exactly what a reviewer must see change. So the attribute heuristic is `TerraformSecretNames`: `password`, `secret`, `private_key`, `client_secret`, `token`, `connection_string`, `*_password`, `sas_token`, `*_pem`. Tests pin that `key`, `key_name`, `public_key` and `kms_key_id` are **not** masked. The broad `Secrets.isSecret` stays for what goes to an agent, where hiding too much costs little.
5. **Nothing of a run is written where Overterm keeps things.** No plan, plan JSON, state, output, diagnostic or provisioner output in the support folder, the session, `CommandHistory` or a log. The runs list is in memory: counts, addresses and times.
6. **Scrollback.** `Session/Scrollback.swift` saves every pane's last 2,000 lines at quit. A pane whose `CommandLedger` saw `terraform output|show|console|state show|state pull`, or a `terraform` process with a sensitive prompt, is saved **without** scrollback. A change to existing behaviour, tested.
7. **Ask Agent (⌘L)** over a selection in such a pane is scrubbed first (`AskSelection`, which already scrubs a pod's and a pinned tab's).
8. **Copy summary for a PR** is the masked model's text, never `terraform show` output.
9. **Outputs** come from state `show -json`, masked by `sensitive`; `output -json` and `output NAME` are never run for display. No Show of a sensitive value in stages 1–2. If one comes later, it is per value, naming each.
10. **Diagnostics** keep `summary`, `detail` (scrubbed), `range` and `snippet.code`; `snippet.values` go through the same masking or are dropped.
11. **The backend record** is decoded through its allow-list (4.11); `password`, `access_key`, `secret_key`, `token`, `*_pem` are never decoded.
12. A sentinel test plants the sandbox's sentinels (`acme-hunter2-SECRET`, `tok-acme-123`, `globex-BKPW`) in **each** path listed above and asserts none survives in the decoded model's `String(reflecting:)`, an MCP answer, the brief, the history or the scrollback.

### 5.7 Credentials: never read, only passed through

- **Overterm never opens** `~/.aws/*`, `~/.terraform.d/credentials.tfrc.json`, `~/.terraformrc` or `TF_CLI_CONFIG_FILE` (existence is checked for the cache, 4.13), `~/.config/gcloud/*`, `~/.azure/`, `~/.kube/config` for Terraform's sake.
- Their contents reach terraform through the user's environment and the providers' own chains (4.5).
- **Credential expiry** (`ExpiredToken`, `SSO session`, `No valid credential sources`, `oauth2: … token expired`) stops that root's runs at the first failure, no retry storm, and says what to run: "`aws sso login --profile acme-prod-admin` in a terminal", offered in a **new** tab only, never typed into an agent's pane (CLAUDE.md has the incident).
- A default AWS profile with no `AWS_PROFILE` may be a production admin; Overterm can't tell without reading `~/.aws/config`, so such a root is remote, never local. Said in the residuals.

### 5.8 Settings an agent can write

settings.json is a plain file any agent can edit. One edit could make production local, name roots in `agentPlans`, or set `productionPattern` to `^$`.
- Hand-set classes can only raise (5.1).
- **Security keys changed outside the Settings page** (seen when `Settings` reloads the file) take effect only after a banner in each window confirms them: "settings.json changed outside Overterm: `terraform.productionPattern` is now `^$`. Keep / Revert". The keys: `terraform.roots`, `terraform.productionPattern`, `terraform.productionAccounts`, `terraform.agent*`.
- The same hole exists today for `kubernetes.contexts`, `kubernetes.productionPattern` and `kubernetes.agentWrites`. Fixing it there too is recommended, as its own commit (13, D-7).

### 5.9 Supply chain: `init` and `validate` run code

- `init` downloads providers (native binaries, run with the user's credentials) and modules (HCL from registries, git with the user's SSH keys, S3, HTTP). The lock file pins **providers only**; a `?ref=main` module changes under the same lock file.
- `validate` starts every provider binary [verified]. So Overterm's validate runs with every credential variable removed and `HOME` scratch (4.5), only after a lock file exists, with `-lockfile=readonly` on any init Overterm runs before it.
- Rules: init only on the person's click, but for New Task's `init -backend=false` in a root whose fetch list flags nothing and that has no remote module outside the registry (4.13, stage 2b); the fetch list shown first (4.13); never `-upgrade` silently; agents never run init.

### 5.10 Agents

The `tf_` tools are built like `KubeMCP`'s, dispatched in `BrowserMCP.handle` by prefix, defaulting to the **calling pane's checkout** (`KubeMCP.paneCheckout`'s rule). Both halves are wired: `tools/list` builds from `offered(in:)` with a new `terraformAgentAccess` field in its settings snapshot (not a `Settings.shared` read), and `tools/call` dispatches. The list is not announced again when a setting changes (Kubernetes' caveat).

| Tool | What | Default | Guard |
|---|---|---|---|
| `tf_roots` | The checkout's roots: path, class, workspaces, backend summary, needs init, last plan's counts and age | on | names only |
| `tf_fmt_check` | `fmt -check -diff` of a root | on | runs no provider |
| `tf_validate` | `validate -json` diagnostics | on | Only when the root's lock file exists and is unchanged from `HEAD` and every module is already in `modules.json`; credentials removed, `HOME` scratch; otherwise "needs init: ask the person". Never an init |
| `tf_plan_summary(root?, path?)` | The last plan Overterm made for the root, or a plan file the agent saved (`path`, resolved inside the checkout): counts, rows by action with reasons, cause chains, moves, imports, drift, actions, changed attribute paths | on | The masked model only (5.6); strings cut at 200 characters |
| `tf_plan_resource(address)` | One resource's masked diff | on | as above |
| `tf_plan(root, workspace?)` | Starts a plan in Overterm's registry and run folder; returns a run ID at once | **offered** on non-production roots | No flags at all: not `-var-file` (it reads any file into the plan), not `-refresh=false`, not `-generate-config-out` (it writes files). The first call per root and session is asked in the window, naming the root, the profile and the risk list. Production: never — the person plans there. `-lock-timeout=0s` |
| `tf_run_status(id)` | A plan run's state and, when done, its summary | on | A plan can take minutes; one loopback HTTP request must not hold the lock, and an MCP client's tool timeout must not cancel it. The window keeps the record |
| `tf_state_list` | Addresses | on (2c) | |
| `tf_state_show(address)` | One object, masked | on (2c), off on production | `sensitive_values`, then `Secrets` |
| `tf_outputs` | Names, types, non-sensitive values | on (2c) | Never a sensitive value; no tool for one, as there is none for Kubernetes Secrets |
| `tf_test(root, file?)` | `terraform test -json` | on (2d) | Only test files whose every provider is mocked; otherwise asked, since a real run creates real infrastructure — never on production, on a remote root only where `terraform.roots` sets it `writable: true` |
| `tf_why(root)` | The brief of the last failed run or held lock | on | `TerraformAgentBrief` |
| `tf_apply`, `tf_destroy`, `tf_state_*`, `tf_unlock`, `tf_import`, `tf_init`, `tf_workspace_*` | **Do not exist** in stages 1–2 | — | An agent writes `removed`, `moved` and `import` blocks, which go through plan and apply. Agent apply is decision D-12 for stage 3 |

**Every `tf_*` path argument** is resolved with `realpath` and must stay inside the calling pane's checkout: no `..`, no absolute path, no symlink out (`envs/prod -> ../../acme-live/prod`).

**MCP tools run outside the agent's sandbox.** A tool that starts terraform starts the providers the checkout names, with whatever environment Overterm gives them. That is why validate and the agent's reads get no credentials, and why `tf_plan` is asked. Said in the agents section of the docs.

**The bridge's token must be per pane (stage 0).** `BrowserBridge` uses one bearer token for every pane and one path per pane, `/mcp/<tag>`, and every pane's config is a file in `supportDirectory/mcp/<tag>.json`, 0600 to the same user. An agent in worktree A can read B's file and call B's tools; the window's confirmation then names B's checkout, so the person approves what they think B's agent asked. The fix: a token per pane, bound to its tag, rejected on any other tag, and **kept out of every file**: the config's header is `Bearer ${OVERTERM_MCP_TOKEN}`, which Claude Code expands, and `OVERTERM_MCP_TOKEN` is set in that pane's environment only, beside `OVERTERM_MCP_CONFIG` (a token written in the file would be read by A as easily as B's path). It applies to `k8s_`, `docker_` and `db_` tools today, so it is its own security commit before any `tf_` tool lands. Every confirmation an MCP call asks also names the asking tab and agent, "asked through MCP" (`MCPAsker`: the call's pane, a task-local, read by `WriteConfirmation.ask`), in that pane's window — Docker's, Kubernetes' and the databases' writes today; the API client's and the notes' tools ask nothing. What is left is in 5.12.

**Ask Why** (`TerraformAgentBrief`, pure, every word through `Secrets`): the root, workspace, backend type and class; the operation and its diagnostics (`summary`, `detail`, `range`, `snippet.code`); the resource's address and masked change; the provider and version from the lock file; `terraform version`; the last 60 lines of the raw log, scrubbed; for a held lock, the parsed holder and its age. It goes to the checkout's agent as Docker's and Kubernetes' Ask Why do.

### 5.11 Terragrunt and OpenTofu (stage 3)

- **Terragrunt** runs Terraform inside `.terragrunt-cache/<hash>/<hash>/`, so a relative `-out` lands there: Overterm passes an absolute one. Its logger wraps Terraform's stdout; JSON needs `--tf-forward-stdout` or the JSON out-dir (flag names verified against https://docs.terragrunt.com/reference/cli/commands/run before use). `run --all apply|destroy` adds `-auto-approve` to each unit; external dependencies are prompted for, or excluded under `--non-interactive` unless `--queue-include-external`. Overterm never builds `run --all apply|destroy`; a later stage plans each unit to its own file and applies each file. The pane header recognises `run --all`, `run-all`, `apply-all` and `destroy-all` from stage 1b.
- **OpenTofu**: same JSON family, but the provider addresses (`registry.opentofu.org/…`), encrypted state and plans (`{encrypted_data, encryption_version, meta}`; a plan that isn't a zip: the zip reader says "unknown (encrypted)" and the checks that need it say so), `TF_ENCRYPTION` key material, `-exclude`, and no actions, `query` or policies. A Terraform plan can't be applied by tofu or the reverse: switching binary means planning again, which the binary pin enforces. The domain note's rows on `removed`/`destroy`, `-json-into` and `TOFU_*` variables are unverified and not relied on.

### 5.12 Residuals

| Risk | Mitigation | Residual |
|---|---|---|
| A plan runs untrusted code with production credentials | First plan per root and session asks on production; the risk list; others' code asks; agents' `tf_plan` asked; no automatic plans | A person who clicks Plan on hostile code, after reading the list, runs it, as in their terminal |
| An agent reads the plan file | 0700 folder, unlinked at once, fd-held | Same-user processes, during the seconds before the unlink |
| Credentials change in files between plan and apply | Same environment; profile and region named on the sheet | SSO caches, `~/.aws/config` contents |
| An agent's terraform in its own shell | Header, Inbox mark, `agentWriteGuard` for agents Overterm launched | Agents started elsewhere, indirect commands, Codex until verified |
| Two worktrees with different configs on one state | Identity, queue, stale marking | Their terminals, CI |
| A secret no provider marked | `Secrets` on every kept string, the narrower attribute list | Heuristic |
| Future plan fields, actions, unknown verbs | Allow-list decode; unknown top-level keys grey Apply; unknown actions destructive | — |
| A default AWS profile that is production | Never local | Its applies are still asked, every 5.4 check made |
| HCP remote runs | Guards and a link | Stage 3 |
| An agent calls another pane's MCP tools | A token per pane, good on its own path only, in that pane's environment and in no file; every MCP confirmation names the asking tab and agent, in that pane's window (D-15) | A same-user process outside a sandbox can read another process's environment (`KERN_PROCARGS2`, `ps eww`) and so another pane's token; the confirmation then names the pane it pretends to be. Agents' sandboxes that deny reading other processes close it; Overterm can't |

### 5.13 Rules enforced in code and locked by tests

1. **The only apply is `apply <the fd of a plan Overterm showed>`**, by the recorded binary, in the recorded environment. `TerraformCommands` can't express the forms of 4.3; a test enumerates its outputs.
2. **The plan applied is the plan shown.** 5.4's checks, each with a test: a swapped fd, an edited lock file, an old plan, another worktree's apply (stale), an environment changed between plan and apply (refused), a newer-minor binary.
3. **One environment.** A hostile environment (`TF_CLI_ARGS_apply=-lock=false`, `TF_CLI_ARGS_apply=-auto-approve`, `TF_LOG=trace`, `TF_REATTACH_PROVIDERS`) never reaches a run; the recording wrapper (11) asserts argv and environment names.
4. **A workspace that doesn't exist refuses every run** before it starts, whichever variable or file names it.
5. **Writes are turned off in one place.** `terraform.roots`' `writable: false`, on any class (there is no session switch: the owner's decision); agents' settings only say whether a tool exists where Overterm itself may write.
6. **Every write is confirmed** with `WriteConfirmation`, the typed names of 5.4.
7. **Secrets are masked at decode** through the allow-list; the sentinel test of 5.6.
8. **No credentials file is read**, and `guardsTerraform` holds in isolated runs and unit tests.
9. **Locks:** every plan and apply passes `-lock=true` and a `-lock-timeout`; force-unlock takes only a parsed, probed ID.
10. **Overterm writes nothing in a checkout** except what the person asked: `.terraform/` by init, a lock-file change shown as a diff, a formatted buffer, `.terraform/environment` by Select.
11. **No telemetry:** `CHECKPOINT_DISABLE=1` always. terraform-ls reaches registry.terraform.io for module and provider metadata, and `tf_*` answers go to the agent's model provider: "nothing leaves this Mac except through the tools you installed and the agents you started" is the honest wording.
12. **Classes only rise by hand; production is sticky by identity; security keys edited outside the page wait for a confirmation.**

## 6. Interface

### 6.1 Where Terraform lives

| Layer | Type | When | What |
|---|---|---|---|
| **Rail panel** | `SidebarPanel.terraform` (`toggleKey` `terraform.enabled`; placed after Kubernetes in `general.sidebarOrder`), `TerraformPanelModel`/`View` | Working in a checkout | The selected tab's checkout's roots, grouped by top folder, `modules/` and `examples/` folded: name, class band, workspace chip, backend, version pill, needs-init, last plan's bar and age, "no state here", "also in `bump-eks`". Verbs: Plan, Validate, Init, Terminal in this root, Select workspace, Ask Why. Reads files only while it is the panel on screen, and starts no terraform by itself |
| **Right slot** | `RightPane.Mode.terraformPlan`, with a sticky `terraformPlanOpened` flag like `manifestOpened`, and a tab in the pane's switch | A plan, a run | The plan view (6.3); during a run, its progress and raw log (`LogTextView`). It joins the slot and never adds a column (CLAUDE.md, RightSlot) |
| **Pane header** | `TerraformPaneWarning` in `PaneHeaderView` | terraform running in a pane | 3.2 |
| **Inbox** | `TerraformPrompt` beside `AgentPrompt` | an agent asks, or Terraform prompts | 3.3 |
| **Editor bar** | `EditorViewController+Terraform` | a `.tf` file | Root, workspace, class, Plan, Validate, Format |
| **Changes pane** | `DiffModel` | `.tf`/`.tfvars` changed under a root | "Plan envs/dev" in the header, "touches envs/dev, envs/prod (module acme-net)" on the ± badge |
| **Page** (stage 3) | `WorkspaceOverlay.terraform`, a `WorkspacePage` (`square.stack.3d.up`) | Across checkouts | The roots of every open checkout, state, runs. Built only if the panel's single checkout proves too narrow |
| **Terminal tabs** | `TabKind.terraform` | The user's own | "Terminal in this root": cwd at the root, no `TF_WORKSPACE` (4.9), placed by `addTab`/`NewTabGroup.placement` |

### 6.2 The root chip

```
 envs/prod · feature-x @ 3f2a91c ▾   ⬤ PRODUCTION   workspace prod ▾   s3 · acme-tfstate/prod/network.tfstate · eu-west-1   tf 1.17.1   lock: free
```

- Red band and PRODUCTION on production; amber REMOTE; grey LOCAL. `ChromeTheme`'s colours.
- The workspace is per worktree; its menu lists `workspace list` (cached per identity) and says Select writes `.terraform/environment`.
- "lock": free, held by Overterm (which worktree, since when), or held by Who (from the last parsed lock). Never polled; known from runs.
- The version pill turns amber on a `required_version` mismatch.
- Counts, serials, ports and pids are `Text(verbatim:)` (CLAUDE.md: the Turkish locale writes `+1.234`).

### 6.3 The plan view

```
 Plan · envs/prod · feature-x @ 3f2a91c · 2 min ago · AWS_PROFILE acme-prod-admin      +5 ~1 -3 ±2 →4 ⇣1 ⚠1     [Apply…] [Copy summary] [Discard]
 / filter           [replace] [delete] [update] [create]                     var files: prod.tfvars · TF_VAR_: acme_region
 ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ⚠ Drift (1)
     local_file.acme_config            deleted outside Terraform
 ± random_password.acme_db            replace · length can't change in place
       ← length ← var.acme_db_length ← envs/prod/prod.tfvars:7   changed in this branch
 ± random_pet.acme_api                replace · keepers forces it
 ~ aws_s3_bucket.acme_logs  ×12       update · tags.deployed_at            (12 resources, same change)
 + local_file.acme_config             create
 ⇣ random_id.acme_imported            import ← p-9hUg
 → module.globex_worker               moved from module.globex_app (4)
 Outputs:  api_name  known after apply   db_password  sensitive
```

Detail of a row:

```
 ± random_password.acme_db   replace (delete, then create) — replace_because_cannot_update
   length        24 → 32                  forces replacement
   result        ••••••  → known after apply     sensitive
   7 unchanged attributes ▸
   main.tf:21  [Open block]
```

- Replace, delete, forget and actions first, red; `read` (data sources) folded at the bottom; unknown never empty.
- A stale plan says so in its header ("envs/prod changed after this plan", "applied from `bump-eks`: plan again"), and Apply is greyed with why.
- `ResourceTable` rows, reused while scrolling; ↩ the detail; right-click the verb menu (`ResourceVerb`), a verb that can't be done greyed with why.

### 6.4 The apply flow (stage 2a)

1. Plan on screen → **Apply…** (`⇧A`). Greyed with why: stale, errored, partial on production, older than 30 min, another run on this state, a part not understood, a newer-minor binary not confirmed.
2. The sheet (5.4), the typed name where it applies.
3. Run: the plan view becomes the progress view in place, same rows with their state; the bar counts and elapsed; Stop (`.`).
4. End: "Apply complete — 5 added, 1 changed, 3 destroyed" from the exit code and an `apply` summary; outputs refreshed from state; the record and its fd dropped; a runs row in memory (time, who started it, counts, result).
5. Failure: red rows, the diagnostic under each, "1 failed — state saved, 11 applied", Ask Why, Plan again.

### 6.5 Keyboard first

As the Kubernetes and Docker lists: the list keeps its place across updates, single letters while it has the keyboard, the verb menu on right-click.

## 7. Shortcuts

### Global (proposed)

Checked against `KeyCommands` (`Settings/Keybindings.swift`) and Ghostty's defaults in `vendor/ghostty/src/config/Config.zig` (vendored at `332b2ae`, the v1.3.1 pin): ⌘E is Ghostty's `search_selection`; ⌥⌘E and ⌃⌘E are bound by neither.

| Shortcut | Command | Note |
|---|---|---|
| ⌥⌘E | The Terraform rail panel (`terraform.show`, group Panels, as ⌥⌘G Overgit, ⌥⌘N Notes, ⌥⌘B Database) | Free. ⌥⌘Y, the other free candidate, has no better claim; E is next to the Panels' letters |
| ⌃⌘E | Terraform switcher: roots and workspaces of the selected checkout, then of other open checkouts, and addresses in the shown plan (`terraform.switch`) | Free: `KeyCommands`' ⌃⌘ keys are B, F, G, I, J, N, S, 1–9 and = |
| — | Plan this root, Validate, Terminal in this root, Copy plan summary | Palette and menu; bindable (`terraform.plan`, `terraform.validate`, `terraform.terminal`, `terraform.copySummary`) |

The comment beside `kubernetes.page` in `Keybindings.swift` records what Ghostty binds; the Terraform entries get the same comment, citing the vendored file.

### While the plan or the roots list has the keyboard

| Key | Action | Kubernetes' meaning |
|---|---|---|
| ↑ ↓, ← → | Move; open or close a group | same |
| ↩ | Detail | same |
| `p` | Plan the root | pause (no counterpart) |
| `v` | Validate | — |
| `i` | Init… | — |
| `⇧A` | Apply this plan… (2a) | — |
| `o` | Open the block in the editor | open |
| `a` | Ask Why | same |
| `t` | Terminal in this root | follow in a tab |
| `w` | Workspace picker | wide columns (`w` for workspace reads better) |
| `/` | Filter | same |
| `.` | Stop the running apply (asked the second time) | — |
| ⌘C | Copy the address | copy the name |
| ⌫ | Discard the plan | delete (asked) |
| `?` | This table | same |

## 8. Integration points in Overterm

| Where | File | What Terraform adds |
|---|---|---|
| Rail | `Sidebar/SidebarView.swift` (`SidebarPanel`, `toggleKey`, `ordered`) | `.terraform`, symbol `square.stack.3d.up` |
| Right slot | `Diff/RightPaneView.swift` (`RightPane.Mode`, the `…Opened` flags); `Window/TerminalWindowController+Browser.swift` (`RightSlot`) | `.terraformPlan`, `terraformPlanOpened` |
| Pane header | `Splits/PaneHeaderView.swift`; `Kubernetes/KubePaneWarning.swift` (`KubeCommandLine`) | `TerraformPaneWarning`, `TerraformCommandLine`; `KubeCommandLine`'s splitter shared once the Kubernetes branch has landed |
| Process trees | `Info/ProcessInspector.swift` (`arguments(of:)`, `environment(of:)`, `foregroundGroup(of:)`), `SurfaceProcesses.loginPID(of:)` | finding terraform in a pane's tree; Tab Info's terraform rows (operation, root, workspace, running for, lock held, provider children, `.terraform` size by `DiskUsage`) |
| Inbox | `Inbox/AgentPrompt.swift`, `InboxModel` | `TerraformPrompt`; the tab's attention mark |
| Agent launch | `Tabs/Agent.swift` (`command(arguments:)`), `Tasks/TaskCreator.swift` | `agentWriteGuard`'s per-launch flags |
| Close | `TerminalWindowController.closePane(_:in:)`, `closeTabs`, `windowShouldClose`; `AppDelegate.applicationShouldTerminate` | `TerraformCloseGuard` |
| Processes | `Net/ProcessGroup.swift` | `TerraformRun`, `TerraformApplyRun` (a `POSIX_SPAWN_SETSID` option; fd 3 by `adddup2`, since the spawn closes every other descriptor) |
| Environment | `ShellEnvironment`, `AppEnvironment` | `TerraformEnvironment`; `OVERTERM_TERRAFORM`, `guardsTerraform`, `terraformCacheDirectory`, the run folder's isolated base |
| Tables, verbs | `ResourcePage/` (`ResourceTable`, `ResourceVerb`, `ResourceActionBar`) | the plan, the roots, later the state |
| Confirmations | `Window/WriteConfirmation.swift` (`typedName`) | every write; the risk list |
| Secrets | `Secrets.swift` | `TF_TOKEN_*`, `TF_ENCRYPTION`, HCP tokens (`….atlasv1.…`) in its names and patterns; `TerraformSecretNames` beside it |
| Editor | `Scripts/build-treesitter.sh`, `Editor/Syntax/EditorLanguage.swift`, `Editor/LSP/LanguageServers.swift`, `LanguageServer.swift` | the grammar line, `hcl`, the `terraform` spec, `initializationOptions`, `environmentRemoved`, `didChangeWatchedFiles`, `.zedTerraformLS` |
| Watching | `Sidebar/DirectoryWatcher.swift`, `Diff/DiffModel.swift` | `fileEvents:`; the panel fed from `DiffModel`'s stream |
| Changes, review | `Diff/DiffModel.swift`, `Review/ReviewModel.swift` | "Plan this", the badge's roots, the review's Terraform section (2f) |
| Agents | `Browser/BrowserMCP.swift`, `BrowserBridge.swift` | `TerraformMCP` in both halves; the per-pane token (stage 0) |
| Settings, keys | `Settings/SettingsSchema.swift`, `SettingsPage.swift` (`SettingsSection`), `Keybindings.swift` | `.terraform` section; §7's commands |
| Session | `Session/SessionState.swift`, `Session/Scrollback.swift` | nothing pinned to restore (4.9); the scrollback rule (5.6) |
| Palette | `Palette/PaletteModel.swift` | `Plan <root>`, `Terminal in <root>`, `Select workspace…`, `Validate <root>` |
| Other features | Browser, Database, API client, Kubernetes | outputs as links (2c) |

New folder `Sources/Overterm/Terraform/`, every type named by the part it belongs to ("pure" = no IO, unit-tested):

| File | Types | Pure |
|---|---|---|
| `TerraformCLI.swift` | `TerraformCLI` (binary per root, `version -json`) | no |
| `TerraformEnvironment.swift` | `TerraformEnvironment` | yes |
| `TerraformRun.swift`, `TerraformApplyRun.swift` | runs, `TerraformStop`, the detached apply and its reattach | no |
| `TerraformRunFolder.swift` | the per-process folder, the sweep | no |
| `TerraformCommands.swift` | `TerraformCommands` | yes |
| `TerraformUIStream.swift` | `TerraformUIMessage` | yes |
| `TerraformPlan.swift` | `TerraformPlan` (the allow-list decoder), `TerraformResourceChange`, `TerraformPlanZip` (lineage, serial, lock-file hash) | yes |
| `TerraformCauseChain.swift`, `TerraformConfigIndex.swift`, `TerraformBlocks.swift` | causes, addresses → file and line, the top-level block scan | yes |
| `TerraformRunRisks.swift` | the risk list | yes |
| `TerraformState.swift` | state `show -json` (2c) | yes |
| `TerraformDiagnostics.swift`, `TerraformLock.swift` | diagnostics, `TerraformLockInfo` | yes |
| `TerraformRoots.swift`, `TerraformRootStore.swift` | `TerraformRootScan`, `TerraformRootGuess`, `TerraformRoot`, the store | partly |
| `TerraformClass.swift`, `TerraformStateIdentity.swift` | `TerraformClassifier`, identities | yes |
| `TerraformProcessCheck.swift` | `TerraformVerb`, `TerraformProcessCheck` | yes |
| `TerraformCommandLine.swift`, `TerraformPaneWarning.swift`, `TerraformPrompt.swift`, `TerraformCloseGuard.swift` | what a pane runs, its header, its prompts, the close decision | mostly |
| `TerraformAgentGuard.swift` | `agentWriteGuard`'s flags per agent | yes |
| `TerraformModel.swift` | the app's one: binaries, `TerraformRunRegistry`, records | no |
| `TerraformPanelModel/View.swift`, `TerraformPlanPaneModel/View.swift` | the panel, the slot | no |
| `TerraformAgentBrief.swift`, `TerraformMCP.swift` | Ask Why, the tools | partly |
| `FakeTerraformBackend.swift` | the tests' http state backend | no |

Window wiring: `TerminalWindowController+Terraform.swift`, `+TerraformPanel.swift`. Editor: `EditorViewController+Terraform.swift`. E2E: `E2E/E2ERunner+Terraform.swift`. Commits are `terraform: …`, a new area.

## 9. Stages

Each stage is usable on its own and has its own E2E check. Security comes first: the cleared environment, the classifier, the allow-list decoder and the agent guards land before any plan runs, and every write lands with its check and confirmation. Stage 0's extractions touch files the Kubernetes job is committing on this branch now (`KubePaneWarning.swift`, `LanguageServer.swift` is shared); they are scheduled after that work lands.

**The floor is stage 1 (1a–1d).** Nothing in it can change infrastructure: it can plan (which reads the cloud and takes the lock, asked on production), never apply. That mirrors Kubernetes' stage 1, which changed no object.

| Stage | Scope | Useful alone because | Check | Bump |
|---|---|---|---|---|
| **0. Groundwork** | The per-pane MCP token in `BrowserBridge` (a security fix for every existing tool). `DirectoryWatcher(fileEvents:)`, `LSPGlob`, `didChangeWatchedFiles` answered, checked against gopls, rust-analyzer, clangd, sourcekit-lsp. `Spec.initializationOptions` and `environmentRemoved`. `ServerDiscovery.zedTerraformLS`. `AppEnvironment` guards. The shared command-line splitter. `FakeTerraformBackend` and the recording wrapper | Nothing visible changes, except that one pane's token no longer opens another's tools | Pane A's token on B's tag is a 401; existing LSP scenarios pass | PATCH each |
| **1a. The editor** | HCL tree-sitter; the terraform-ls spec when found; fmt on save where the checkout passes `fmt -check`; validate on demand with credentials stripped; F12 and symbols by `TerraformConfigIndex` | HCL is plain text today | `terraform`: a `.tf` file coloured, validate's diagnostic at its line, fmt undoable, the checkout byte-identical after validate (no lock file appears) | MINOR |
| **1b. Knowing where you are** | Binaries per root and the version pill. Root discovery, the rail panel (⌥⌘E), the chip, `TerraformClassifier` with stickiness and the settings banner, the identity, the no-state warning, shared module → roots, inherited `TF_WORKSPACE`/`TF_DATA_DIR` warnings. The pane header for terraform anywhere in a pane's tree. Terminal in this root. Tab Info's rows. The `.terraform` noise filter in `DiffModel`. No terraform process except `version -json` | "Which root, which workspace, is it production?" before anyone runs anything, the agent's pane included | Two roots and a module listed; `envs/prod` red; a pane running the real terraform (offline) gets the header; the panel reads nothing while hidden; `init`'s writes don't recount the changes pane | MINOR |
| **1c. Guarding agents** | `TerraformPrompt` (both shapes) in the Inbox; `agentWriteGuard` for Claude Code after its spike, Codex's answer; the scrollback rule; `tf_roots`, `tf_fmt_check`, `tf_validate` (guarded), `tf_plan_summary` over an agent's own saved plan; Ask Why on a validate failure | The one moment a person can still say no to an agent's apply is marked; agents get masked plans | A fake agent's permission prompt for `terraform apply` marks its tab; the launch command carries the deny flags; a sentinel absent from `tf_plan_summary` | MINOR |
| **1d. The plan in the right slot** | Init (the fetch list, `-lockfile=readonly`) and the plugin cache offer. Overterm's plan: the run folder, the fd, the cleared environment, the workspace check, the risk list and "code you didn't write". The allow-list decoder; the plan view: risky first, ×N, the cause chain for replace and delete, drift, actions, moves and imports, stale and "applied elsewhere", missing variables, inputs named; Copy summary. Locks parsed, Wait. The registry's queue. `tf_plan`, `tf_run_status`, `tf_plan_resource`, `tf_why` | The plan read as data, beside its cause, for people and agents | A plan in the slot with the sentinel absent from every view and the accessibility text; the cause chain to the changed tfvars line; a missing workspace refused; a lock from `FakeTerraformBackend` named; the second worktree's plan marked stale after the first's apply (from the CLI) | MINOR |
| **2a. Apply** | The detached apply in the plan's environment, every 5.4 check, typed names, the risky-update highlight, Stop, reattach after a crash, Quit's question. `TerraformCloseGuard` on all four close paths. Production writable with its name typed (the session switch it first had was removed by the owner's decision). Targeted, replace and destroy plans | The first time Overterm changes infrastructure, with every guard in place | Apply on a local root lands; on `envs/prod` it asks for the name (refused only while `writable: false`); a hostile `TF_CLI_ARGS_apply` doesn't reach it; closing a pane where the real terraform applies asks, Interrupt leaves the resource tainted and the lock free; the app killed mid-apply, relaunched, finds it | MINOR |
| **2b. Worktrees** | New Task's roots: the no-state warning, `init -backend=false -lockfile=readonly`, the workspace not copied; lock files compared across worktrees | A new worktree that validates and doesn't plan "create everything" | A New Task worktree's root warned; validate works there | MINOR |
| **2c. State and outputs** | State list and one resource, masked; outputs; outputs into the Browser, Database, API client and Kubernetes; `tf_state_list`, `tf_state_show`, `tf_outputs` | State without `state show` in a terminal | A sensitive output never valued in the view or a tool | MINOR |
| **2d. Drift and tests** | Check drift and Accept into state; `terraform test` in the slot, `tf_test` (mocked only, else asked) | The one write-free feedback loop for agents | A mocked test file's runs listed with one failure at its line | MINOR |
| **2e. Locks** | Force unlock with the probe; the http warning | A stale lock cleared without a terminal | The probe refuses a lock that changed hands; the root's name typed | MINOR |
| **2f. Review** | The review tab's Terraform section; "Post to pull request…" | "What will this PR change in the cloud" beside its diff | A branch's touched roots listed; planning it asks with its risk list | MINOR |
| **3. Optional** | The page across checkouts; Terragrunt units; OpenTofu (after a real-binary spike); HCP saved cloud plans or the JSON plan API (keychain token); tflint/trivy/checkov/conftest if on PATH; Infracost if configured; policy results; plan diff across worktrees; `terraform query` → import blocks; agent apply (D-12) | — | — | MINOR each |

**Stage notes: deferred from 1d.** Built in 1d and its review pass: the plan view, the cause chain from the branch's own lines (`git diff -U0 <merge base>`, committed lines too), the list's keys (↑↓, ↩, `o`, `a`, `/`, ⌫, ⌘C), long strings and JSON in a string diffed by line, the `terraformPerf` scenario. Left for stage 2a, with the plan view's progress rows:
- a hunk in the changes pane lighting the plan rows it causes, and back (3.1);
- "Open block" for a module's resources through `modules.json` (2.2): 1d finds only the root's own blocks;
- the rows as a `ResourceTable` (6.3): 1d keeps them in the model and the rows observe nothing, which a 2,000-resource plan's filter and scroll needed; the verb menu on right-click comes with Apply.

## 10. Performance and reliability at scale

Measured in `sandbox-ux` (M-series, Terraform 1.17.1, `terraform_data` × 2,000 with 20 labels and a 1 KB string each):

| What | Size | Time |
|---|---|---|
| Plan, 2,000 creates | stream 0.85 MB; `show -json` 5.5 MB | plan 0.5 s; show 0.5 s |
| Plan, 2,000 updates | stream 2.9 MB; `show -json` 14.9 MB | plan 7.2 s; show 1.8 s |
| Parse of that JSON (a C parser, a lower bound) | — | 0.06 s |
| Apply, 2,000 creates, local backend | stream 2.8 MB; state 11.5 MB | 141 s, Terraform's own persisting |
| `state list` of 2,000 | — | 0.16 s |
| Root discovery on this repository (922 files) | one `ls-files` | 16 ms |

Budgets, checked by a `terraformPerf` scenario on generated plans of these sizes:
- **A 2,000-resource plan (15 MB):** decoded off the main thread in under 0.5 s with `JSONSerialization`, one pass into rows (address, actions, reason, module, `replace_paths`, changed paths, the ×N key); `before`/`after` kept as the decoded, masked sub-trees and diffed only for the row shown. First draw under 150 ms after decode, 60 fps scroll in `ResourceTable`. The main thread never decodes.
- **Beyond `terraform.maxPlanBytes` (64 MB):** the stream's summary only, "too large to show attribute diffs".
- **The stream:** decoded per line on the reader thread, applied in 120 ms batches; a 2,000-resource apply's 6,000 hook lines touch rows by address, never reload the table.
- **Idle:** the panel hidden and no plan in the slot means no terraform process and no file reads; only the pane-tree walk of 3.2 for checkouts with roots (every 2 s, no IO).
- **Monorepos:** hundreds of roots are grouped by top folder; no stat beyond the capped list; facts per root read only for the roots shown.
- **terraform-ls:** one server per worktree, `indexing.ignorePaths` keeping it to the roots. With five worktrees that is five servers; a decision if it costs too much (only the focused worktree's).
- **Reliability:** an exit code is final, not the stream; a line that doesn't decode is raw text; an unknown `ui` major refuses with "apply it in a terminal".

## 11. Tests

Tests never reach a cloud, a registry, the user's state or the user's configuration. The real binary works offline for everything a test needs, because `terraform_data` and `local-exec` are built in [verified, spike 22]. So, unlike Docker's and Kubernetes' fakes of a server, **the real terraform is the test subject**, and the fakes are the backend and a recording wrapper.

**Unit tests** (`Tests/OvertermTests/`, pure, fixtures from the sandboxes' real output, fictional names, checked in):
- `TerraformUIStreamTests`: every message type in the samples, an unknown type, a non-JSON line, a replace's two hook pairs, `change_summary` operations (`apply-errored.jsonl`, `apply-interrupted.jsonl` report failure).
- `TerraformPlanTests`: the allow-list (a planted key outside it is dropped); the sentinels absent in every path of 5.6; nested mirrors; `after_unknown`; replace in both orders; `forget`; moves and imports as no-ops with markers; `action_invocations`; refresh-only with no `resource_changes`, errored with no `prior_state`; an unknown top-level key marks "partly understood"; an unknown major refused.
- `TerraformSecretNamesTests`: `password`, `client_secret` masked; `key`, `key_name`, `public_key`, `kms_key_id` not.
- `TerraformCauseChainTests`, `TerraformConfigIndexTests`: an address through `modules.json` to file and line; a tfvars line found.
- `TerraformRootGuessTests`: envs, modules, examples, Terragrunt `root.hcl` against units, `.terragrunt-cache` and `.terraform` ignored, the upward walk bounded at `/`; "needs init" by diagnostic, a root with no providers not flagged.
- `TerraformClassifierTests`: 5.1's names; strict local; precedence (a hand-set class lowers nothing); stickiness by identity; the Terragrunt `live/`.
- `TerraformStateIdentityTests`: every backend of 4.11, local non-default workspaces under `terraform.tfstate.d/<ws>/terraform.tfstate`.
- `TerraformLockTests`: the local and http diagnostic texts, `Info`, the Go time format; a `.lock.info` file never consulted.
- `TerraformProcessCheckTests`: every verb against every class and writable value.
- `TerraformCommandsTests`: every output enumerated, none with a forbidden form; quoting of `aws_instance.web["a b"]`; the agent's `-lock-timeout=0s`.
- `TerraformEnvironmentTests`: a hostile environment in, none of 4.5's names out; the guarded environment carries no credential name; validate's carries none either.
- `TerraformCommandLineTests`: `env TF_WORKSPACE=prod terraform -chdir=envs/prod apply`, `sudo`, pipelines, `terragrunt run --all apply`, `run-all`.
- `TerraformPromptTests`: Terraform's two prompts; Claude Code's and Codex's permission prompts naming `terraform apply` (fixtures from their real screens, stage 1c).
- `TerraformCloseGuardTests`: the decision per operation and per close path.
- `TerraformRunRisksTests`, `TerraformAgentGuardTests`, `TerraformPlanZipTests` (lineage, serial and lock hash from a real plan zip).
- `SyntaxDocumentTests` gains hcl, its `comment` injection included.

**The recording wrapper.** `OVERTERM_TERRAFORM` names a small script the test writes: it appends argv, cwd and the environment's **names** (plus the values of the `TF_*` Overterm sets) to a JSON-lines file, then `exec`s the real terraform. That is what asserts the hostile-environment and argv rules against real runs.

**`FakeTerraformBackend`** (SwiftNIO, in the test process, 127.0.0.1, a random port, like `FakeKubeAPI`): an `http` state backend with GET/POST/DELETE, LOCK/UNLOCK (423 with the lock JSON; the empty-bodied force UNLOCK), `holdLock(who:)`, `failCredentials`, every request recorded. With it the real terraform shows a lock held by `ci@globex-runner-7`, a remote identity, and two "worktrees" on one state.

**Scenarios** (`E2ERunner+Terraform.swift`, in the scenario table), with the real terraform when `make e2e` finds one, through the wrapper, under `guardsTerraform`, proxies pointed at a dead port, a temporary git checkout written by the scenario (`envs/dev`, `envs/prod`, `modules/acme-net`, a `globex-sandbox` local root, `terraform_data` only):
- the panel lists the roots and the module; `envs/prod` red; it reads nothing while hidden (the wrapper records no call);
- a pane running `terraform apply` gets the header; closing it asks; Interrupt leaves the resource tainted and the lock free (SIGINT, never SIGHUP first);
- a plan in the slot, the sentinel absent from every view and the accessibility text; the cause chain to the tfvars line; `.terraform`'s writes don't recount the changes pane;
- a missing workspace refused before any run; a second worktree's "no state here" and "creates everything";
- the lock from `FakeTerraformBackend` named; the probe used for force unlock, never `plan`;
- apply on `envs/prod` refused, then with the switch asks for the name; a hostile `TF_CLI_ARGS_apply` never reaches the run;
- an apply survives the scenario killing the app's run record and is reattached (the detached pid found);
- `tf_plan_summary` and `tf_outputs` return no sensitive value; pane A's token is refused on B's tag;
- an agent tab's launch command carries the deny flags, recorded, not run.

When no terraform is found, the Terraform scenarios are reported as skipped, loudly, never silently passed.

**The opt-in suite** (`OVERTERM_TF_TESTS=1`): the fixture generator `Scripts/terraform-fixtures.sh` and the JSON shapes against the installed version. The script creates its own temp folder and refuses to run anywhere else; refuses when **any** `AWS_*`, `GOOGLE_*`, `ARM_*`, `TF_TOKEN_*`, `TF_CLOUD_*`, `KUBECONFIG` or `TF_REATTACH_PROVIDERS` is set (rather than unsetting them); after init, asserts the lock file's providers are a subset of `null`, `random`, `local`, `terraform`; uses no `local-exec` beyond `sleep` and `echo` inside the folder. Providers come from a filesystem mirror with `direct { exclude = ["*/*"] }`, so a provider missing from the mirror fails instead of being fetched. CI's unit tests need no terraform at all.

## 12. Risks

| Risk | Mitigation |
|---|---|
| A guard in Overterm's process is mistaken for a guard on the user's terraform | 5.2's table in the help; the pane header says "notice" by its wording, never "protected" |
| Prompt fatigue turns confirmations into habit | Typed names only where 5.4 says; `tf_plan` asked once per root and session; the risk list asks only when it lists something |
| The agent guard is circumvented (`bash -c`, `make apply`) | Said in the setting's help; the header and the Inbox still see the terraform process |
| How agents run commands changes (Claude Code, Codex releases) | Stage 1c's fixtures come from real screens; `TerraformPrompt` keeps unknown shapes as "probably" |
| Terraform's formats move (`ui` 1.3, plan 1.2) | Minor bumps tolerated, majors refused, unknown top-level keys grey Apply |
| Huge plans and schemas | 64 MB cap; schemas only when asked, only without terraform-ls |
| terraform-ls per worktree costs memory | `indexing.ignorePaths`; a decision to keep it to the focused worktree if it shows |
| `fmt` on save fights a team's style | On only where the checkout already passes `fmt -check` |
| The stage-0 LSP change alters gopls' and rust-analyzer's watching | Checked per server in stage 0 |
| CI rebuilds GhosttyKit once when the tree-sitter script changes | Expected, said in the commit |
| The detached apply's pid is reused after a crash | Reattach checks the executable path and start time |

## 13. Decisions

### Taken here, with the reason

- **D-1. Overterm's own processes; applies detached in the plan's environment** (option C, Section 4). Typing the apply into a tab loses the environment, `-lock=true` and graceful stops [verified].
- **D-2. Rail panel and right slot first; the page in stage 3.** A root belongs to a checkout; the page across checkouts has little to list without a backend API.
- **D-3. Stop = one SIGINT to the group**, as Ctrl-C does; pid-only behaves the same [verified]. A second, confirmed Stop sends another.
- **D-4. No `TF_WORKSPACE` pins on terminal tabs; every Overterm run checks its workspace exists first.**
- **D-5. Plan files: a 0700 per-process folder in `$TMPDIR`, then an fd.** Never the support folder, never kept.
- **D-6. Lock timeouts:** a person's plan 10 s with Wait, an agent's 0 s, an apply 60 s; `-lock=false` never.
- **D-9. Shortcuts:** ⌥⌘E the panel, ⌃⌘E the switcher.
- **D-10. Force unlock in stage 2e**, only from a parsed lock, probed, the root's name typed.
- **D-11. State surgery is never a button**: `removed`, `moved` and `import` blocks through plan and apply.
- **D-13. OpenTofu and Terragrunt in stage 3**, behind a real-binary spike; recognised in the pane header from stage 1b.
- **D-14. No scheduled drift, no automatic plans** of any kind.

### Answered by the user (2026-11-08): the recommended option for each

1. **D-0. The floor:** stage 1 (1a–1d) plans but never applies; apply is stage 2a (**recommended**) / apply in stage 1.
2. **D-7. Security keys edited outside Settings** wait for a banner's confirmation, for Terraform, and the same fix for `kubernetes.*` in its own commit (**recommended**) / Terraform only / neither.
3. **D-8. The agent guard:** `terraform.agentWriteGuard`, per-launch deny flags for agents Overterm starts in a checkout with a production root, on by default (**recommended**) / off by default / a PATH shim refusing writes (strongest, but invasive: it changes the agent's PATH and every terraform there).
4. **D-12. Agent plans and applies:** `tf_plan` offered on non-production roots, the first call per root and session asked; never on production (as built; the session switch this first named is gone); **no `tf_apply` in stages 1–2** (**recommended**) / `tf_plan` only for roots listed in a setting / `tf_apply` in stage 2 for writable non-production roots, each call confirmed.
5. **D-15. The stage-0 per-pane MCP token**, a security fix that also changes the existing Docker, Kubernetes and Database tools (**recommended**) / Terraform's tools only / leave it.
6. **D-16. `terraform.enabled` on by default**, nothing run until the panel opens, as `docker.enabled` and `kubernetes.enabled` (**recommended**) / off until turned on.
7. **D-17. The plugin cache:** offered at the first Init in a window with two worktrees of one repository, for Overterm's runs only (**recommended**) / on by default / never.
8. **D-18. The version guard:** refuse an apply that moves the state to a newer Terraform minor, unless confirmed (**recommended**) / a warning only.
9. **D-19. `terraform test`** in stage 2d with `tf_test` (mocked only) (**recommended**) / in the floor, as the one write-free feedback loop for agents.
10. **D-20. HCP `cloud {}` roots:** guards, editor and a link in stages 1–2; stage 3 tries a saved cloud plan through `show -json`, else the JSON plan API with a token typed into the keychain (**recommended**) / never an HCP API.
11. **D-21. Typed name on every production apply**, not only on destroys (**recommended**) / only when the plan deletes, replaces, forgets or invokes an action.

## 14. Sources

Terraform:
- Machine-readable UI: https://developer.hashicorp.com/terraform/internals/machine-readable-ui
- JSON output format (`*_sensitive`, `replace_paths`, `action_reason`, `importing`, `complete`, `applyable`, optional keys): https://developer.hashicorp.com/terraform/internals/json-format
- `plan` (`-detailed-exitcode`, `-refresh-only`, `-minimal-refresh`, `-target`, `-replace`, `-lock`): https://developer.hashicorp.com/terraform/cli/commands/plan ; `apply`: https://developer.hashicorp.com/terraform/cli/commands/apply
- Environment variables (`TF_CLI_ARGS` and `TF_CLI_ARGS_name`, `TF_WORKSPACE`, `TF_DATA_DIR`, `TF_INPUT`, `TF_IN_AUTOMATION`, `TF_PLUGIN_CACHE_DIR`, `TF_LOG`, `CHECKPOINT_DISABLE`): https://developer.hashicorp.com/terraform/cli/config/environment-variables
- CLI config (plugin cache not concurrency safe, `dev_overrides`, `credentials`, `filesystem_mirror`, `direct { exclude }`): https://developer.hashicorp.com/terraform/cli/config/config-file
- Provider debugging (`TF_REATTACH_PROVIDERS`): https://developer.hashicorp.com/terraform/plugin/debugging
- Sensitive data, ephemeral values, write-only arguments: https://developer.hashicorp.com/terraform/language/state/sensitive-data ; https://developer.hashicorp.com/terraform/language/manage-sensitive-data/ephemeral ; https://developer.hashicorp.com/terraform/language/values/variables#exclude-values-from-state-and-plan-files
- State locking, `force-unlock`: https://developer.hashicorp.com/terraform/language/state/locking ; https://developer.hashicorp.com/terraform/cli/commands/force-unlock
- `state rm` (`-dry-run`; `-backup` local only): https://developer.hashicorp.com/terraform/cli/commands/state/rm
- Backends: local https://developer.hashicorp.com/terraform/language/backend/local ; s3 (`use_lockfile`, DynamoDB deprecated, `workspace_key_prefix`) https://developer.hashicorp.com/terraform/language/backend/s3 ; gcs, azurerm, kubernetes, pg, http under https://developer.hashicorp.com/terraform/language/backend/
- Remote state data source: https://developer.hashicorp.com/terraform/language/state/remote-state-data
- Dependency lock file: https://developer.hashicorp.com/terraform/language/files/dependency-lock
- `removed`, `moved`, `import` blocks: https://developer.hashicorp.com/terraform/language/resources/syntax#removing-resources ; https://developer.hashicorp.com/terraform/language/moved ; https://developer.hashicorp.com/terraform/language/import
- `terraform test` and mocks: https://developer.hashicorp.com/terraform/language/tests ; https://developer.hashicorp.com/terraform/language/tests/mocking
- `terraform login`: https://developer.hashicorp.com/terraform/cli/commands/login
- Saved cloud plans: https://developer.hashicorp.com/terraform/cli/cloud/run#saved-cloud-plans ; HCP JSON plan API: https://developer.hashicorp.com/terraform/cloud-docs/api-docs/plans#retrieve-the-json-execution-plan
- The `local` provider's `local_command`: https://registry.terraform.io/providers/hashicorp/local/latest/docs/data-sources/command
- Releases (1.14 actions and query, 1.17): https://github.com/hashicorp/terraform/releases

Editor:
- Helix 25.07.1 `languages.toml` (the hcl grammar pin, terraform-ls): https://github.com/helix-editor/helix/blob/25.07.1/languages.toml ; queries: https://github.com/helix-editor/helix/tree/25.07.1/runtime/queries/hcl
- tree-sitter-hcl at the pin: https://github.com/tree-sitter-grammars/tree-sitter-hcl/tree/9e3ec9848f28d26845ba300fd73c740459b83e9b
- terraform-ls settings, commands, changelog (#953 client-side watching, #790): https://github.com/hashicorp/terraform-ls/blob/main/docs/SETTINGS.md ; https://github.com/hashicorp/terraform-ls/blob/main/docs/commands.md ; https://github.com/hashicorp/terraform-ls/blob/main/CHANGELOG.md
- Zed's terraform extension: https://github.com/zed-extensions/terraform/blob/main/src/terraform.rs

The landscape:
- HashiCorp's MCP server: https://developer.hashicorp.com/terraform/mcp-server/reference
- VS Code extension: https://github.com/hashicorp/vscode-terraform
- Atlantis, including its security page: https://www.runatlantis.io/docs/ ; https://www.runatlantis.io/docs/security
- Spacelift drift detection: https://docs.spacelift.io/concepts/stack/drift-detection ; Scalr reports: https://docs.scalr.io/docs/reports ; smart plan outputs: https://www.scalr.com/blog/smart-plan-outputs
- tf-summarize: https://github.com/dineshba/tf-summarize
- Infracost: https://infracost.io/docs/features/cli_commands
- The DataTalks.Club incident: https://rootly.com/humans-of-reliability/hey-claude-wheres-my-database-alexey-grigorev ; https://gruntwork.io/blog/thinking-of-using-ai-with-terraform
- Version mismatch: https://discuss.hashicorp.com/t/terraform-error-refreshing-state-state-snapshot/31788
- Claude Code CLI (`--disallowedTools`): https://docs.anthropic.com/en/docs/claude-code/cli-reference

OpenTofu and Terragrunt (per docs, unverified here):
- OpenTofu state encryption: https://opentofu.org/docs/language/state/encryption/ ; removing resources: https://opentofu.org/docs/language/resources/syntax/#removing-resources
- Terragrunt `run` and the run queue: https://docs.terragrunt.com/reference/cli/commands/run ; https://terragrunt.gruntwork.io/docs/features/run-queue ; 1.0: https://www.gruntwork.io/blog/terragrunt-1-0-released

Evidence (scratchpad `terraform/`): `samples/` (every JSON shape named here), `sandbox-safety/exp1–16.sh`, `sandbox-analysis/FINDINGS.txt`, `sandbox-review0/`, `sandbox-review1/` (R1–R7), `sandbox-review3/`, `sandbox-revise/FINDINGS.txt`.

Overterm (read only, branch `kubernetes`): CLAUDE.md; `docs/design/kubernetes/analysis.md` §5, §9, §13; the files named in Section 8.

## 15. What the review changed

`analysis.md` did not exist when the four reviews ran; each reviewed the five research notes it was to be built from, and each said where the analysis would inherit a problem. This analysis was written with them. Every issue below was taken unless it says otherwise.

**Review 0, feasibility.**
- A1 (an apply in a tab gives no stream): taken, but its recommendation, typing the apply into a tab for stage 1, is **rejected**: review 1's B1, B2 and B4 show a tab changes the target, lets `-lock=false` through, and dies by SIGHUP. Overterm's own detached apply instead (D-1).
- A2 (the lost pin creates a workspace): taken and widened. A new sandbox run showed `.terraform/environment` naming a missing workspace does the same (spike 14), so every run checks its workspace (4.9). Tab pins are dropped altogether rather than fixed with `TF_DATA_DIR=/dev/null`.
- A3 (four close paths, "Interrupt and Wait" needs async machinery): the four paths are taken (4.8). The waiting is **not** built: Overterm's applies are detached, so they need no wait, and for terraform typed in a pane, Interrupt sends SIGINT and cancels the close, keeping every path synchronous. Also corrected: `ManagedProcess.closeAll` sends SIGTERM at grace 0; `KubeProcessRun.stopAll` is the `killpg(SIGKILL)`.
- A4 (`isSecret` masks `key`): taken: the allow-list for the backend, `TerraformSecretNames` for attributes (4.11, 5.6).
- A5 (no per-child umask; a blanket sweep): taken: the per-pid folder after `KubeSocketFolder`, the `sh -c umask` launcher (4.4).
- B1 (stage order, MINOR for the editor, extractions after the Kubernetes work): taken (9).
- B2 (no `zedExtension` candidate; watched files need per-file events, globs, registration; `Hashable` options): taken (4.14).
- B3 (CI cache key, `make treesitter`, the `comment` injection): taken (4.14).
- B4 (`tools/list` gating, a settings snapshot, long plans in one request): taken: both halves, `tf_run_status` (5.10).
- B5 (init state isn't `.terraform/`): taken (4.12).
- B6 (the real binary offline; FakeTerraform only for what it can't do): taken, further: the fake is a recording wrapper plus `FakeTerraformBackend` (11).
- B7 (`RightPane.Mode` and its sticky flag): taken (6.1). B8 (`toggleKey`, the default): taken, default on (D-16). B9 (one shortcut pair, the Ghostty check): taken, ⌥⌘E/⌃⌘E, checked against the vendored `Config.zig` (7). B10 (leave `KubeProcessRun` alone): taken (4.1). B11 (the SHA in the tab shape): moot, since nothing is applied from a tab; the fd replaces the path (4.4).
- C (DiffModel noise, the header from live pids, the session format, `Text(verbatim:)`, the Inbox flag, the study's shape): taken. The session gains no pin fields, since tabs aren't pinned.

**Review 1, safety.**
- B1 (a saved plan doesn't pin the environment): taken; the decisive finding. One recorded environment from plan to apply (4.6). The fingerprint hash it proposed is unnecessary once the apply runs in the recorded environment itself; its test (plan and apply environments equal; a changed `AWS_PROFILE` refused) is kept.
- B2 (`-lock=false` through `TF_CLI_ARGS_apply`): taken, and the fix verified: an explicit `-lock=true` after the env args wins (spike 8).
- B3 (the SHA race; 0700 doesn't stop agents; no umask): taken: the fd-held plan [verified for `show` too], the residual stated (4.4, 5.12).
- B4 (an apply dies with the app by SIGPIPE or SIGHUP): taken: detached, files, reattach (4.7).
- B5 ("Local" isn't local): taken (5.1). B6 (agents' reads run code outside their sandbox): taken (5.9, 5.10). B7 (one MCP token for every pane): taken as stage 0, for every feature's tools (D-15). B8 (the lost pin creates): taken (4.9).
- M1 (actions), M2 (typed name on every production apply), M3 (agent-writable settings), M5 (environment additions), M6 (scrollback, runs log, PR text), M7 (allow-list decode), M8 (planning others' code), M10 (agents' arguments): taken.
- M4 (production holes): taken, except **the branch as a signal**, rejected: branches name the work, and a `fix/prod-logging` branch would make a staging root production (5.1).
- M9 (force unlock): taken with review 3's probe, verified on local only.
- M11 (tests): taken (11). M12 (verify pid-only SIGINT): done by review 0's sandbox: the same as the group's, so the group, as Ctrl-C (D-3).
- m1–m6: taken (5.6 rule 9, 5.4's escaping, 3.2's "notice" and "probably", 5.13 rule 11, 5.7's new tab, 5.12).
- Conflicts C1–C9: settled as recommended, except C2 (lock timeouts), where review 3's split (an agent's plan 0 s) is taken over a flat 10 s, and C8 (plugin cache), where the cache is offered at the first Init rather than off, once its path goes through `AppEnvironment` (D-17).

**Review 2, user value and scope.**
- C1 (rail and slot first), C2 (a child process), C3 (no agent apply in the floor), C5 (no scheduled drift), C6 (plan files), C8 (group SIGINT), C11 (enabled by default): taken.
- C4 and V3 (agents' plans default off loses the safer channel): taken in part. `tf_plan` is offered by default, but its first call per root and session is asked (review 1's B5–B6: a plan runs the agent's code with the user's credentials); production never offers it (D-12).
- C7 (pin or not): settled by not pinning tabs (D-4). C9 (saved cloud plans): stage 3, unverified (D-20). C10 and V5 (plugin cache in the floor): taken in part: Init and the cache offer are in 1d, the cache is not on by default.
- V1 (guard the path agents take): taken, all four points, with one correction found while writing: agents run commands as their own children, without the pane's tty, so Terraform's prompt rarely reaches the screen; the agent's own permission prompt is the moment to read, and the header looks in the pane's whole tree (3.2, 3.3). The Claude Code flag's syntax and its hold under `--dangerously-skip-permissions`, and Codex's lever, are verified in stage 1c.
- V2 (the cause chain in the floor, replace and delete only), V4 (version safety), V6 (say who it is for): taken (3.1, 3.8, 2.10).
- M1 (shared modules → roots), M3 (missing variables), M4 (×N), M5 (Copy summary; Post later), M6 (stale "applied elsewhere" banner), M7 (the comparison table): taken. M2 (`terraform test`): stage 2d, left for the user (D-19).
- O1–O9 (over-built): taken: the page in stage 3, the filter cut to text and chips, `loudTypes` cut, validate on demand, docs only without terraform-ls, runs in memory, no dependency view, five settings in the floor, progress simplified.

**Review 3, Terraform correctness.**
- A1 (SIGINT to the group, SIGHUP on close), A2 (`TF_WORKSPACE` creates; refuse on a miss; the empty-prior-state guard), A3 (ephemeral variables through `TF_VAR_`), A4 (the same absolute binary), A5 (the lock only from the diagnostic; `Info`; no `.lock.info`), A6 (the probe), A7 (`-backup` is local only: the verb isn't built), A8 (no `-auto-approve`), A9 (the resource list from `show -json`), A10 (`operation: apply`), A11 (absent keys), A12 (`-minimal-refresh` out), A13 (`-detailed-exitcode`): taken.
- B1–B6: settled (4.3, 4.9, 4.10, 5.3, 4.2). B2: `-lock=false` is never used, since there are no scheduled scans to tolerate it.
- C1–C5 (OpenTofu), D1–D6 (workspaces, backend layouts, worktrees, inherited `TF_DATA_DIR`, HCP, inputs that change a plan), E1–E3 (init writes the lock file, the cache's precedence without reading `~/.terraformrc`, the lock-file check), F1–F4 (Terragrunt), G (`complete: false` deliberate, `snippet.values`, provisioners don't prompt, the lock's two time formats, no `state show -json`, sensitive outputs in the stream, `init -json` from 1.9): taken. The domain note's doubtful OpenTofu rows are not relied on.
- H (ten checks): all in Section 11.

**Rejected outright:** none of the four reviews' blockers. Rejected recommendations, each above with its reason: typing the apply into a tab (review 0, A1); "Interrupt and Wait" with `.terminateLater` (review 0, A3); `TF_DATA_DIR=/dev/null` as a lost pin (review 0, A2; review 1, B8), unneeded without pins; the environment fingerprint hash (review 1, B1), unneeded with the recorded environment; the branch as a production signal (review 1, M4); `tf_plan` on by default with no question (review 2, V3); the plugin cache on in the floor (review 2, V5).
