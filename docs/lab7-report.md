# Lab 7: The cloud as code. Migration log and answers

Three CloudFormation stacks (`meetings-cognito`, `meetings-reports`, `meetings-ai`) became Terraform in `infra/`
without losing a user, a report or a URL. Decision record: [ADR 0007](adr/0007-terraform.md). Files of every run:
[`docs/lab7-runs/`](lab7-runs/).

## What is submitted

| Item | Where |
| --- | --- |
| 1. Commit / merged pull request | PR [#2](https://github.com/mr-amigo/OneTwoThree/pull/2) (migration: `auth.tf`, `reports.tf`, `ai.tf`, Makefile, README, ADR 0007; the three `.yml` templates deleted) and PR [#3](https://github.com/mr-amigo/OneTwoThree/pull/3) (`imports.tf` deleted, one small change through the pipeline) |
| 2. A run that finished applying, started by a merge, not from a laptop | Run [#7](https://github.com/mr-amigo/OneTwoThree/actions/runs/45484424000): *Triggered via push* (merge of PR #3) → `Apply complete! Resources: 0 added, 18 changed, 0 destroyed.` Screenshots `lab7-runs/05-…`, `06-…`. The migration itself: run [#5](https://github.com/mr-amigo/OneTwoThree/actions/runs/45481452381) → `Apply complete! Resources: 39 imported, 0 added, 8 changed, 0 destroyed.` |
| 3. `terraform plan` right after the migration | [`lab7-runs/03-plan-after-migration.txt`](lab7-runs/03-plan-after-migration.txt), ending in `No changes. Your infrastructure matches the configuration.` |

**HCP Terraform → GitHub Actions.** The lab asks for an HCP Terraform run. On 2026-11-24 HCP Terraform refused to
create any organization for this course: *"Free tier organizations created by user limit reached"*. The same error came
for a personal and for a business organization, for a plain HCP Terraform account and for an HCP account (through the
web form and through the API). The screenshots are attached to the submission. So the runs use the road the lab lists itself in
Part 0, step 11, *"CI runs it: GitHub Actions runs plan on the pull request and apply on merge, with OIDC"*, with
the state in S3 and an S3 lock file (Part 0, step 10). Everything HCP Terraform would have given is here too:
- a remote, locked, versioned state;
- a plan on every pull request;
- an apply only after a merge;
- short-lived credentials through OIDC;
- no keys anywhere.

Moving to HCP Terraform later is a `cloud` block instead of `backend "s3"` and `terraform init -migrate-state`.

## How the migration went

**Translate (Step 2).** I drafted `auth.tf`, `reports.tf`, `ai.tf`, `variables.tf`, `outputs.tf` and `data.tf` with
Claude Code. I checked them against the templates:
- every resource is there, plus the parts CloudFormation hid inside one resource: S3 sub-resources, IAM inline
  policies and attachments;
- names are unchanged, including the role names CloudFormation generated (`meetings-ai-ParserRole-aZ8vbBGKtxUo`);
- there are no secrets in the files;
- Lab 5's bucket ↔ permission ↔ notification cycle is gone, because they are three resources and Terraform orders them
  by their references.

The mailer's inline code is a file now (`lambda/report_mailer/index.py`), byte-for-byte the code that was deployed.
The stacks that were not moved (network + API + Aurora, ECR, site) are read with `aws_cloudformation_stack`.

**Adopt, do not re-create (Step 3).**
1. *3a.* `DeletionPolicy: Retain` and `UpdateReplacePolicy: Retain` on all 28 resources of the templates (27 existed:
   the second SES identity is conditional), deployed once (commit `0de0e6b`), then the three stacks were deleted. CloudFormation reported `DELETE_SKIPPED` for each resource. The user pool,
   the bucket and the rest stayed, owned by nobody.
2. *3b.* `imports.tf`: 39 `import` blocks. CloudFormation's 27 resources become 39 in Terraform, because a bucket is six
   resources and a role with inline and managed policies is three. The SES identity's ID is an email address, so
   `imports.tf` read it from SSM (`id = nonsensitive(local.secret["report_sender_email"])`) and no personal address
   went into Git.
3. *3c.* Plan until it says nothing. The first plan wanted to **replace three resources**. I fixed the HCL, not the
   resources:

   | `-/+` or `~` in the first plan | Cause | Fix in HCL |
   | --- | --- | --- |
   | `aws_cognito_user_pool_client.web` must be replaced (`generate_secret = false # forces replacement`) | The argument was set, the imported client has none | Leave `generate_secret` unset |
   | `aws_cognito_managed_login_branding.main` must be replaced | It follows the client's ID | Gone with the fix above |
   | `aws_lambda_permission.report_mailer_s3` must be replaced | `function_name` was the ARN, the real permission uses the name | Use `function_name` |
   | SQS `max_message_size` 1048576 → 262144 | The AWS default is now 1 MiB, the provider's default still 256 KiB | Set `max_message_size = 1048576` |
   | Scheduler `input` changes | `jsonencode` reorders the keys | The exact string the queue has always received |

   Final migration plan (run #5): **`Plan: 39 to import, 0 to add, 8 to change, 0 to destroy`**. No resource is
   created, replaced or destroyed. The 8 in-place changes:
   - **3 resources get their `PROJECT_NAME` tag back:** the VPC endpoint, the event source mapping and the budget. They
     carried it only as a stack tag, and CloudFormation removed it when the stack was deleted.
   - **4 changes are state-only, no API call changes a value:** "the value is unchanged, it will be marked as sensitive".
     These are the Google client secret, the OpenAI key, the DB password and the sender address. They were imported
     without the sensitive mark.
   - **1 is the mailer re-uploaded** from `index.py`: the same code in a new zip, a stateless function. A test report
     after the migration went through SQS → builder → S3 → mailer → SES (`status=sent week=2026-W47`).
   - Imported: 39. Re-created: **0**. Child resources (permissions, notification, policy attachments) were imported
     too, because their IDs were known.

**The road (Step 4).**
- The Makefile reads `terraform output -raw …` instead of stack outputs.
- `make infra-plan` plans from a laptop, and there is no `terraform apply` in the Makefile.
- New image tags go to the Lambdas with `make aws-lambda-images`, which is why `image_uri` is in `ignore_changes`.
- Proof that the road works: PR #3 adds a `ManagedBy = "terraform"` tag. The plan was posted on the pull request (`0 to add, 18 to change, 0 to destroy`,
  screenshot `04-…`). After the merge, run #7 applied it: *Triggered via push, Success, Apply complete! Resources: 0 added,
  18 changed, 0 destroyed* (`05-…`, `06-…`).

*Which road first when a change needs both*, for example a new environment variable: infrastructure first, application second.
In this project the variable is part of the Lambda in Terraform. The infra pull request adds it, and old code
ignores an unknown variable. Then the new code that reads it is deployed. Removal goes the other way: first the code
stops reading it, then the infra pull request removes it. Each step works with the version before it.

**Drift (Step 5).** The parser's timeout was changed by hand from 30 to 45 seconds (`aws lambda
update-function-configuration`). A manual run with apply off (run #8, plan only) found it:
`~ timeout = 45 -> 30`, `Plan: 0 to add, 1 to change, 0 to destroy` (`07-…`). A manual run with apply on (run #9)
put it back. The parser has `Timeout: 30` again, and the next plan says `No changes`.

*If that had been a real 23:00 fix,* the next apply would have undone it, silently, maybe days later in an unrelated
merge. The team should have made the fix through the code: a one-line pull request (`timeout = 45` in `ai.tf`),
planned, reviewed by whoever is awake, merged, applied. If the console really was the only way in time, a pull request with the same
change must follow the same night. Then the code agrees with the world again, and the next plan shows `No changes`
instead of a revert. The fix lives in `infra/ai.tf`. The `ManagedBy = terraform` tag tells everyone in the console
that a change there is temporary.

**Problems on the way, and what they taught.**
- HCP Terraform had no free organization to give. This is described above.
- *GitHub's OIDC subject changed format.* The first pull request plan was refused by STS. CloudTrail showed the token's
  subject as `repo:mr-amigo@246989247/OneTwoThree@1394976249:pull_request`: GitHub now includes the owner's and the
  repository's IDs, and the trust policy expected `repo:mr-amigo/OneTwoThree:…`. The trust now matches the IDs. That
  is also safer: a repository deleted and re-created under the same name by someone else gets nothing.
- *Least privilege costs one iteration.* The apply role, unlike the read-only plan role, lacked
  `cloudformation:GetTemplate`, which the `aws_cloudformation_stack` data source calls. Run #5 failed in its plan step,
  before anything was applied. The state stayed empty. After the fix, the same push-triggered run was re-run.
- *The repository is public, so are its Actions logs.* Values from SSM are masked with `::add-mask::`. The plan that is
  posted on the pull request is redacted before posting, because masking does not apply to comments and the SES identity's ID
  is an email address. The plan role is read-only, because a pull request can change the workflow file itself.

## Step 7: questions

**1. How many imported, how many re-created, and why was each re-creation safe?** 39 imported, 0 re-created (see
above). Nothing needed re-creating: even the child resources that the lab allows to re-create (`aws_lambda_permission`,
`aws_s3_bucket_notification`) had known import IDs. The only real write was the mailer's code, re-uploaded unchanged.

**2. An attribute that forces replacement of the user pool or the bucket.** Checked with a real plan
([`09-prevent-destroy-check.txt`](lab7-runs/09-prevent-destroy-check.txt)):
- For the pool, `username_configuration.case_sensitive = true` gives `# forces replacement`. The same is true for
  `username_attributes` and changes to `schema`. A new pool has a new ID and **no users**: everyone since Lab 4 would
  have to sign up again, Google users would get new `sub`s, so the API's `users` rows and their meetings would be
  orphaned, and the client ID in the frontend would change.
- For the bucket, `bucket` (the name) gives `# forces replacement`. The new bucket is empty, every weekly report is gone,
  and the destroy of the old one fails anyway unless it is empty.

Both resources have `lifecycle { prevent_destroy = true }`. The same plan stops with *"Instance cannot be destroyed"*,
so such a change cannot even reach the apply.

**3. Where is the Google client secret now, and who could leak it?**
- `.env` on the laptop: anyone with the laptop. It is git-ignored.
- SSM Parameter Store `/meetings/terraform/google_client_secret`, a SecureString under the AWS-managed KMS key: any principal with
  `ssm:GetParameter` on it. That is administrators and the two pipeline roles.
- The Terraform state in S3: in `aws_cognito_identity_provider.google.provider_details` and in the
  `data.aws_ssm_parameter` entry. `sensitive` hides it in plans, not in the state. Readers: administrators and both
  pipeline roles. This is the weakest point, because the plan role runs for pull requests, and someone with write
  access could change the workflow in a pull request to print the state. Forks get no OIDC token, so outsiders cannot.
- Cognito itself: `DescribeIdentityProvider` returns it to anyone with `cognito-idp` read access.
- The GitHub runner's memory during a run. It is masked in the logs and gone after the job.
- Not in Git, the tfvars, GitHub secrets, plan output, PR comments or the frontend build.
- Old copies: S3 keeps previous state versions for 90 days. Rotating the secret means a new value in SSM and an apply.

**4. Two students apply at the same moment with remote state.** The S3 backend's lock file
(`terraform.tfstate.tflock`, `use_lockfile = true`) is created with a conditional write. The second apply fails with
*"Error acquiring the state lock"* and changes nothing. In the pipeline, the workflow's `concurrency` group also queues
runs. With a local `terraform.tfstate` in Git there is no lock. Each student applies from their own copy. The second
one does not know what the first created and tries to create it again: name conflicts, or duplicates when names are
random. Then their two state files conflict in a JSON merge, and the secrets in them go into Git history.

**5. A narrower trust and the permissions this workspace needs.**
- The bootstrap here is already narrower than the course's example. The apply role trusts exactly
  `repo:mr-amigo@246989247/OneTwoThree@1394976249:ref:refs/heads/main`, and the plan role trusts the same plus
  `…:pull_request`.
- For HCP Terraform the equivalent for one workspace is
  `"app.terraform.io:sub" = "organization:ooad-mr-amigo:project:Default Project:workspace:meetings-dev:run_phase:*"`,
  or two roles split by `run_phase:plan` and `run_phase:apply`.
- Instead of AdministratorAccess, the actions the workspace needs:
  - `lambda:*` on `function:meetings-*`;
  - `iam:PassRole` (and the role and policy actions) on `role/meetings-*`;
  - `cognito-idp:*` for the pool;
  - `sqs:*` on `meetings-*`;
  - `s3:*` on `meetings-reports-*`;
  - `scheduler:*`, `budgets:*`, `logs:*` on the project's names;
  - read-only `cloudformation:DescribeStacks` and `GetTemplate` on `stack/meetings-*`;
  - `ssm:GetParameter` on `/meetings/terraform/*`.

  As managed policies, this would be roughly `AWSLambda_FullAccess`, `AmazonCognitoPowerUser` and `AmazonSQSFullAccess`, but
  the inline policy in `infra/bootstrap/main.tf` scopes them to this project's names. The apply role cannot edit its own
  role, which is named `github-terraform-*`.

**6. "Claude Code, add a staging environment."**

What it should produce, as one pull request:
- the resources moved into a module, or an `env` variable with names like `meetings-stage-…`;
- `stage.tfvars`;
- its own state key (`meetings/stage/terraform.tfstate`);
- `moved` blocks so prod's addresses do not change;
- staging copies of the CloudFormation stacks it reads;
- a workflow job that plans stage on pull requests.

It runs `terraform plan` for both environments and shows that prod says **`No changes`** and stage only adds.

What I would not let it do on its own:
- `terraform apply`, or holding the apply role at all;
- `terraform state rm`, `mv` or `import` against prod;
- touching the bootstrap roles, the trust policies or SSM secrets;
- deleting anything;
- merging its own pull request.

## Discussed in class

**The need**
- *Artur's Lambda found six months later.*
  - The options: (1) import it: write the HCL and an `import` block, then it is reviewed, tagged and updated like
    everything else; (2) delete it; (3) leave it and write it down as unmanaged.
  - I would first find out whether anything uses it: CloudTrail, invocation metrics, its URL in logs and code.
  - If it is used, import it. If not, delete it through a reviewed change and keep a note. Option 3 only postpones the problem.
- *A 23:00 console fix to a security group.* The next apply reverts it, because Terraform sees it as drift. The process that
  makes it survive is to make the fix through the code (an emergency pull request), or, if the console really was
  the only way, a pull request with the same change before the end of the incident. A scheduled drift check (the manual
  plan-only run, on a timer) catches the cases nobody wrote down.

**State**
- *What is better because each tool keeps the state differently.* With CloudFormation there is nothing to store or lose, and a failed
  change rolls back by itself. With Terraform the state is a file you can read, move (`moved`, `state mv`), import into and
  back up, it covers any provider, and every plan compares it with the real world.
- *If the state file is deleted*, what is lost is the mapping from addresses (`aws_s3_bucket.reports`) to real IDs, the
  cached attributes and dependencies, and the outputs. What is not lost: every real resource, and the code. How to recover:
  restore the previous object version from the versioned bucket (one command here), or, without it, re-adopt everything
  with `import` blocks, as this migration did. A plan without the state would try to create everything again.
- *Why the state in Git is a bad idea even in a private repository.*
  - It holds secrets in plain text forever: here the DB password, the Google secret and the OpenAI key, and everyone
    with read access gets them, as does every clone.
  - There is no locking. Copies go stale and two people apply from different versions, and the JSON merge conflicts
    end in lost resources.

**Workflow**
- *An HCL diff that looks harmless while the plan is dangerous.*
  - Renaming a resource label (`aws_s3_bucket.reports` → `aws_s3_bucket.report`) without a `moved` block: one line in
    the diff, and in the plan the bucket with all reports is destroyed and an empty one created.
  - Changing `username_configuration` on the pool (shown above).
  - Our own migration had a quieter one: the provider's default `max_message_size` (256 KiB) would have shrunk the
    queues with no line about it in the HCL.
- *Emergency tools.*
  - `-target`: one resource must change now (for example a security group fix, or a function rolled back), while an
    unrelated resource in the same plan fails on a provider bug. Apply just that one, then fix the rest.
  - `terraform state rm`: a resource is handed over to another stack or team, or its API was removed so the provider can
    no longer read it and every plan fails. Remove it from the state without deleting it.
- *Automate more and never.*
  - More automation: policy checks on the plan (no `-/+` on stateful resources, tags present, no public buckets), cost
    estimates, a scheduled drift check, and an agent that drafts the change and the pull request.
  - Never automated: a human approving the plan, and the decision to destroy or replace anything that holds data. The
    agent never gets the apply role.

**Architecture**
- *White-label prod · rozetka.*
  - What changes:
    - the current resources become a module (`modules/meetings`) with inputs `brand`, `domain`, `env`;
    - each environment is a small root with its own backend key and its own `provider "aws"` that assumes a role in that
      environment's AWS account (`envs/dev`, `envs/prod`, `envs/prod-rozetka`);
    - the `rozetka.tfvars` file holds the logo, domain and names;
    - the new account gets its own bootstrap (OIDC trust, state bucket or key) and its own Google OAuth client and DNS
      records;
    - the workflow gets one more job or matrix entry, with its own approval.
  - What stays the same: the module code, the pipeline, the review process. A change to the module reaches every brand the same way.
- *A run fails halfway through ten resources.*
  - The world has, say, four new resources.
  - The state records exactly those four: Terraform writes the state as it goes.
  - The code still describes ten.
  - Nothing rolls back. Read the error, fix its cause (code, permission, quota), plan again: it shows the remaining six,
    and apply. If the half-built state is harmful, revert the commit and apply: the plan removes the four.
  - This lab had the gentle version of this: run #5 failed in the plan step, before any change, so the state stayed
    empty and the fix was one permission and a re-run.

## Part 1 (the walkthrough)

Part 1 is done in class with a throwaway project and is not handed in. Its pieces appear here on the real project:
- variables and `default_tags`;
- `init`, `fmt`, `validate`, `plan`, saved-plan `apply`;
- reading the state (`state list`);
- drift (Step 5) and a deleted resource (the plan would add it back);
- the state moved off the laptop (S3 + lock instead of HCP Terraform, see above);
- a bootstrap with OIDC credentials (`infra/bootstrap`);
- plans on pull requests and applies on merge.

Step 8 (Google Cloud in the same plan) needs a Google Cloud provider login and has no counterpart in this project's
infrastructure. Step 5's three environments are answered in question 6 above.
