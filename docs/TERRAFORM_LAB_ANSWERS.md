# Lab 7: CloudFormation to Terraform Migration & HCP Terraform — Answers & Discussion

---

## Part 2, Step 7: Think It Through

### 1. After Step 3, how many resources did you import, and how many did you let Terraform re-create? Why was each re-creation safe?
- **Imported: 15 stateful & core resources:**
  1. `aws_cognito_user_pool.main` (`us-east-1_rKwoqaQL8`)
  2. `aws_cognito_user_pool_client.main` (`4qu2pkacbb1r6c1vgeu6q6kfc8`)
  3. `aws_cognito_user_pool_domain.main` (`new-project-852064978718`)
  4. `aws_cognito_identity_provider.google[0]` (`us-east-1_rKwoqaQL8:Google`)
  5. `aws_s3_bucket.reports` (`new-project-reports-852064978718`)
  6. `aws_s3_bucket_public_access_block.reports`
  7. `aws_s3_bucket_lifecycle_configuration.reports`
  8. `aws_lambda_function.ai_parser` (`new-project-agenda-parser`)
  9. `aws_iam_role.ai_parser` (`new-project-ai-ParserRole-Tc9aEaWSpEFu`)
  10. `aws_iam_role_policy.ai_parser_bedrock`
  11. `aws_iam_role_policy_attachment.ai_parser_basic`
  12. `aws_cloudwatch_log_group.ai_parser` (`/new-project/agenda-parser`)
  13. `aws_lambda_function_url.ai_parser`
  14. `aws_lambda_permission.ai_parser_url`
  15. `aws_lambda_permission.ai_parser_invoke`
- **Re-created (added fresh): 21 stateless resources:**
  - Reports Lambdas (`aws_lambda_function.builder`, `aws_lambda_function.mailer`)
  - SQS queues (`aws_sqs_queue.reports`, `aws_sqs_queue.reports_dlq`)
  - EventBridge Scheduler (`aws_scheduler_schedule.weekly_report`)
  - Event source mappings & S3 bucket notifications
  - Gateway VPC endpoint for S3 (`aws_vpc_endpoint.s3`)
  - IAM roles & policies for builder, mailer, and scheduler
  - CloudWatch log groups for builder and mailer
- **Why each re-creation was safe:**
  Prior to deleting the CloudFormation stacks, `DeletionPolicy: Retain` was attached to `ReportsBucket` and `UserPool`. When CloudFormation deleted `new-project-reports`, the persistent S3 bucket containing historical CSV files (`2026-W40.csv`, `2026-W41.csv`) was retained unharmed. The queues, Lambdas, and schedules are purely stateless compute and plumbing components with zero persistent data. Re-creating them via Terraform HCL restored identical configurations, ARNs, triggers, and permissions without downtime or data loss.

---

### 2. Find one attribute in your Terraform code that forces replacement of the user pool or the reports bucket if you change it. What would happen to the users or the reports?
- **Cognito User Pool:** Changing the `name` attribute (`name = "${var.project_name}-users"`) or changing `username_attributes` forces a new resource (`forces replacement`).
  - **Impact on Users:** AWS Cognito does not permit renaming user pools. Terraform would delete the existing pool and create a new one. **All user accounts, password hashes, verified email flags, and authentication tokens would be permanently destroyed.** Users would be completely locked out.
- **S3 Reports Bucket:** Changing the `bucket` attribute (`bucket = "${var.project_name}-reports-${data.aws_caller_identity.current.account_id}"`) forces replacement.
  - **Impact on Reports:** S3 bucket names are globally immutable. Terraform would attempt to create the new bucket and delete the old one. If `force_destroy = false` (the default), apply fails because the bucket is non-empty. If forced, **all historical weekly meeting CSV reports would be irrevocably deleted.**

---

### 3. Your Google client secret is `sensitive = true`. List every place it is stored or shown now. Which of them could leak it, and to whom?
- **Where it is stored:**
  1. **HCP Terraform Workspace Variable Store:** Stored encrypted as a sensitive environment/workspace variable.
  2. **Terraform Remote State File:** Stored in plaintext inside the remote state JSON (`aws_cognito_identity_provider.google[0].provider_details.client_secret`).
  3. **AWS Cognito Service:** Stored in the AWS Cognito IdP backend configuration in `us-east-1`.
  4. **Local developer `.env` file:** Stored uncommitted on the developer's laptop from earlier lab setups.
- **Where it is masked:**
  - Masked in `terraform plan` / `terraform apply` terminal outputs (`(sensitive value)`).
  - Masked in HCP Terraform UI run execution logs.
- **Potential leak vectors:**
  - **HCP Terraform Workspace Administrators:** Anyone with admin access to the HCP Terraform workspace or API token can download or read the raw state file and extract the plaintext secret.
  - **AWS IAM Administrators:** Users with `cognito-idp:DescribeUserPoolIdentityProvider` permission can view provider configuration.
  - **Local Developer Machine:** If `.env` is accidentally committed to Git, published in logs, or shared in chat.

---

### 4. Two students in one team run `terraform apply` from their laptops at the same moment with remote state. What prevents the damage? What would happen with a local `terraform.tfstate` in Git?
- **With HCP Terraform Remote State:**
  HCP Terraform automatically acquires an **exclusive distributed lock** on the workspace before any plan or apply phase begins. The first run locks the state. The second run immediately fails or queues with:
  `Error: Error acquiring the state lock: Workspace is locked by another run`.
  This guarantees mutual exclusion and prevents conflicting resource modifications or race conditions.
- **With local `terraform.tfstate` in Git:**
  Git has **no runtime lock**. Both students would read the same base state, apply divergent changes to AWS simultaneously, and both write their own version of `terraform.tfstate` locally. When pushing, Git triggers merge conflicts on the state JSON. State files cannot be safely resolved with manual 3-way text merges. Furthermore, the student whose push lands last would cause Terraform to lose track of resources created by the first student, resulting in orphaned resources and silent infrastructure drift.

---

### 5. The bootstrap role has `AdministratorAccess`, and its trust allows any workspace of your organization. Write the narrower trust condition for one workspace, and name three managed policies or actions that your workspace actually needs.
- **Narrower IAM Trust Policy Condition:**
  Restrict the subject claim (`sub`) to only allow the specific workspace `new-project-dev` within project `default-project`:
  ```json
  "Condition": {
    "StringEquals": {
      "app.terraform.io:aud": "aws.workload.identity"
    },
    "StringLike": {
      "app.terraform.io:sub": "organization:ooad-timlim:project:default-project:workspace:new-project-dev:run_phase:*"
    }
  }
  ```
- **Three scoped IAM Policies instead of `AdministratorAccess`:**
  1. `AmazonCognitoPowerUser` (or scoped `cognito-idp:*` for UserPool, Client, IdP, Domain).
  2. `AWSLambda_FullAccess` (or scoped `lambda:*` for builder, mailer, agenda parser, Function URLs, event mappings).
  3. Scoped policy granting `s3:*` (on `arn:aws:s3:::new-project-reports-*`), `sqs:*` (on `arn:aws:sqs:us-east-1:*:new-project-*`), `logs:*`, and `scheduler:*`.

---

### 6. Claude Code is asked to "add a staging environment". What should it produce, and which of its actions would you not allow it to take on its own?
- **What it should produce:**
  1. Parameterized Terraform modules (e.g. `modules/auth`, `modules/reports`, `modules/ai`) or separate `.tfvars` files (`staging.tfvars`).
  2. Declarative naming using `var.environment` (e.g. `name = "${var.project_name}-${var.environment}-users"`).
  3. A new HCP Terraform workspace configuration for `new-project-staging` with its own isolated state file and variables.
- **What actions should NOT be allowed autonomously:**
  1. **Direct `terraform apply` on AWS:** The AI must never apply changes directly to cloud environments without human review of the plan.
  2. **Modifying or escalating IAM permissions:** The AI should not alter IAM trust policies or grant `AdministratorAccess`.
  3. **Mutating production state or resources:** The AI must not touch production workspaces or modify production state.
  4. **Unreviewed Pull Request Merges:** Applying to `main` must require human sign-off on GitHub.

---

## In-Class Discussion Topics

### The Need
- **Artur's hand-made Lambda found six months later:**
  - *Three options:*
    1. Import it into Terraform (`import {}` block) to bring it under version control and GitOps.
    2. Leave it unmanaged in the AWS console.
    3. Delete it from AWS.
  - *Choice:* **Import it into Terraform.** If the Lambda is active, importing makes its code, IAM permissions, and costs visible and auditable in Git. If obsolete, importing and destroying it through Terraform guarantees that all associated triggers, log groups, and IAM policies are cleanly removed without leaving orphaned resources.
- **Console fix at 23:00 before launch:**
  - *What happens at next apply:* Terraform detects drift during the refresh stage and plans to revert the security group back to the configuration in Git, removing the emergency fix and potentially causing an outage.
  - *Process to make it survive:* The engineer who made the hotfix must immediately submit a pull request updating the Terraform code in Git to reflect the new security group rule. Once merged, the code matches reality, and subsequent applies preserve the fix.

### State
- **CloudFormation vs. Terraform State:**
  - *CloudFormation advantage:* State is fully managed by AWS behind the scenes; developers never have to manage storage buckets, locking mechanisms, state migrations, or state file backups.
  - *Terraform advantage:* State is explicit, cross-provider (multi-cloud), and customizable. It supports advanced operations like `terraform import`, `moved {}` refactoring blocks, and state manipulation without needing to recreate resources.
- **Lost State File:**
  - *What is lost:* The mapping linking Terraform resource addresses to real AWS physical IDs and ARNs, along with cached attributes and metadata.
  - *What is NOT lost:* The actual live infrastructure in AWS (running databases, Lambdas, S3 buckets, Cognito users).
  - *Recovery:* Restore from HCP Terraform's automated versioned state backups. If no backup exists, use declarative `import {}` blocks to re-map existing AWS resource IDs back into state.
- **Why "State in Git" is dangerous:**
  1. **Plaintext Secrets Exposure:** State files store sensitive values (passwords, tokens, client secrets) in plaintext JSON, exposing them to anyone with repository read access and permanently baking them into Git history.
  2. **No Concurrency Lock:** Git lacks a real-time distributed locking mechanism, leading to race conditions, merge conflicts, and state corruption when multiple applies run concurrently.

### Workflow
- **Review the Plan, Not the Code:**
  - *Example:* Changing `name = "${var.project_name}-users"`. In Git, the diff is a harmless 1-character string change. In the `terraform plan`, however, the action is marked `- / + (forces replacement)`. The plan warns that the existing Cognito User Pool will be **destroyed and recreated**, which would wipe out all user accounts. The code diff hides the danger; the plan exposes it.
- **`-target` and `terraform state rm` Emergencies:**
  - *`-target`:* An urgent production incident requires modifying a single resource (e.g. increasing Lambda timeout or modifying a security group) while several other unrelated changes in the branch are unfinished or broken.
  - *`terraform state rm`:* A resource was manually deleted in AWS or has an API bug preventing the provider from destroying it. Removing it from state unblocks Terraform runs without modifying real infrastructure.
- **Automation Boundaries in CI/CD:**
  - *Automate:* Code generation, linting, formatting (`terraform fmt`), syntax validation, speculative plan generation on pull requests, and automated apply upon merging.
  - *NEVER automate:* Human review and sign-off on the speculative `terraform plan`, particularly any plan that indicates resource destruction (`-`) or replacement (`-/+`).

### Architecture
- **White-label customer (`prod · rozetka`):**
  - *What changes:* A dedicated HCP Terraform workspace `new-project-rozetka`, a customer-specific `.tfvars` file (`domain = "rozetka.example.com"`, custom branding variables, custom AWS account ID via OIDC).
  - *What stays the same:* The underlying reusable Terraform modules (`infra/auth.tf`, `infra/reports.tf`, `infra/ai.tf`), application source code, Docker build pipelines, and database schemas.
- **Failed run halfway through 10 resources:**
  - *State of the world:* Resources 1 through 5 are provisioned in AWS; resources 6 through 10 do not exist.
  - *State file:* HCP Terraform saves state incrementally: resources 1 through 5 are recorded in state.
  - *Code:* The code contains declarations for all 10 resources.
  - *Action:* Resolve the failure cause (e.g. adjust IAM role permissions or quota limits) and re-trigger `terraform apply`. Terraform will identify that resources 1 through 5 already exist and resume provisioning resources 6 through 10 idempotently.
