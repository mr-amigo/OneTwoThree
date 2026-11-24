# 0007. Terraform for the infrastructure added in Labs 4–6

Status: accepted, 2026-11-24

## Context
Labs 4, 5 and 6 added three CloudFormation stacks: `meetings-cognito` (user pool, Google, app client, managed
login), `meetings-reports` (scheduler, SQS + DLQ, two Lambdas, S3, SES, S3 gateway endpoint) and `meetings-ai`
(agenda parser, function URL, budget). They worked, but:

- The project already reaches outside AWS: the Google OAuth client, the GitHub repository, the OpenAI project.
  CloudFormation stops at the edge of one AWS account.
- Changes were deployed from a laptop (`make aws-*-stack`) with administrator keys. Nothing reviewed them, and
  nothing showed the effect before it happened.
- A second environment (stage) and a white-label copy are the next steps, so one description must give several.
- The user pool holds every account since Lab 4 and the bucket every weekly report. The migration must not
  re-create either.

## Decision
- **Terraform** (1.17, AWS provider 6.x) for the three stacks: `infra/auth.tf`, `reports.tf`, `ai.tf`, one root module,
  one state. Names and settings are exactly those of the stacks, so every resource was **imported, not re-created**.
- **The older stacks stay CloudFormation** (network + API + Aurora, ECR, site). Terraform reads their outputs
  with `data "aws_cloudformation_stack"`. Moving them is a later, separate migration.
- **State in S3** (`meetings-tfstate-<account>`: versioned, encrypted, public access blocked), locked with an S3
  lock file (`use_lockfile`, no DynamoDB table).
- **GitHub Actions runs Terraform** (`.github/workflows/infra.yml`): on a pull request, `fmt`, `validate` and `plan`
  with a read-only role, and the plan is posted on the pull request; after a merge to `main`, plan and apply with the
  apply role. Both roles are assumed through GitHub's OIDC token. The Makefile has no `terraform apply`.
- **HCP Terraform was the first choice and is not used.** On 2026-11-24 it refused to create an organization for
  this course: "Free tier organizations created by user limit reached", for a personal and for a business
  organization, with a plain HCP Terraform account and with an HCP account (screenshots submitted with the lab).
  The lab names this road itself (Part 0, step 11: "CI runs it … GitHub Actions runs plan on the pull request and
  apply on merge, with OIDC"). Moving to HCP Terraform later is a `cloud` block instead of the `backend "s3"` block,
  `terraform init -migrate-state`, and a workspace with `TFC_AWS_PROVIDER_AUTH`.
- **Least privilege instead of AdministratorAccess.** The apply role may manage only the services this
  configuration uses, and where the ARN carries a name, only `meetings-*` resources. It cannot touch the other
  project in the same account, or edit its own role (`github-terraform-*`). The plan role is `ReadOnlyAccess`
  plus the state and the secrets, because a pull request can change the workflow file.
- **Secrets** (Google client secret, OpenAI key, email addresses) are SecureString parameters in SSM Parameter
  Store, written once by `make infra-secrets`. Terraform reads them with data sources, so they are not in the
  repository, the tfvars, GitHub secrets or the logs.
- **Safety rails:** `prevent_destroy` on the user pool and the reports bucket. Image functions have
  `ignore_changes = [image_uri]`, because the application road (`make aws-lambda-images`) deploys new images.

## Alternatives considered
- **Stay on CloudFormation.** AWS keeps the state and rolls back failed changes. But it covers AWS only, change sets
  are optional, and there is no shared review step. It remains right for the stacks that were not moved.
- **AWS CDK.** It is CloudFormation underneath, with the same AWS-only limit and the same state model. It adds a
  programming language and a synth step to a project that does not need loops over resources.
- **OpenTofu.** The same language and the same files (`tofu` instead of `terraform`), with an open-source licence
  instead of the BSL. A good choice too. Terraform was taken because the course and HCP Terraform use it, and
  switching later is a binary change, not a rewrite.
- **HCP Terraform with VCS-driven runs.** Preferred, because it gives remote runs, a run history, locking and dynamic
  credentials without our own bucket and roles. It was not available (see Decision).
- **Delete the stacks and apply fresh.** Simple for stateless Lambdas, but it deletes every user and every report.
  Rejected.

## Consequences
- **Who changes the infrastructure, and how.** Anyone with write access opens a pull request. The plan appears on it,
  a person reviews the plan (not only the HCL), and the merge applies it. Laptops can run `make infra-plan`.
  Applying from a laptop needs an administrator's keys and is for emergencies (for example a broken pipeline).
- **Where secrets end up.** In SSM (encrypted with KMS), in the Terraform state (the Google secret in the identity
  provider, the OpenAI key and the database password in Lambda environments, the emails), and in the Lambda and
  Cognito configuration, as before. `sensitive` hides them in plans, not in the state. The state bucket is therefore
  private, encrypted and versioned, and only the two pipeline roles and administrators can read it. Old state versions
  expire after 90 days. Moving the Lambda secrets to runtime reads from SSM would take them out of the state.
- **If GitHub Actions or S3 is down,** nothing running is affected: the infrastructure does not depend on its pipeline.
  Changes wait, or in an emergency an administrator applies from a laptop with the same state and lock.
  (With HCP Terraform the answer would be the same.)
- **Drift is visible.** Every plan compares with the real resources. A manual "Run workflow" with apply off is a
  drift check. A console fix at 23:00 shows up in the next plan, and the next apply reverts it unless it was written
  into the code (see `docs/lab7-report.md`).
- **No automatic rollback.** A failed apply stops halfway: the state records what was created, and the fix is a new
  commit and apply. The S3 bucket keeps every state version.
- **Bootstrap.** `infra/bootstrap/` (state bucket, OIDC provider, roles) has a local state and is applied once by an
  administrator. It is the one piece the pipeline cannot create for itself.
