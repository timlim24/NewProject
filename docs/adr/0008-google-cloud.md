# ADR 0008: Running Spry's core on Google Cloud

## Status
Accepted (Google Cloud lab). The AWS deployment stays the primary one; the Google Cloud copy runs the core
of the app next to it.

## Context
Spry runs on AWS and is described in Terraform ([ADR 0007](0007-terraform.md)). We want to know
what it takes to run the same system on Google Cloud and what it costs. The core is the part
that makes the app usable: the React frontend, the FastAPI API and its PostgreSQL database.
Sign-in, the weekly report and the agenda parser are optional for this move.

Constraints that shaped the decisions:
- The API is one container (FastAPI + SQLAlchemy/asyncpg + Alembic) that already runs locally,
  on Lambda (through the Lambda Web Adapter) and in Docker Compose.
- The data model is relational: users own meetings, and meetings and participants are linked
  many-to-many. The data access layer is SQLAlchemy throughout.
- Infrastructure goes through HCP Terraform with no long-lived cloud keys (ADR 0007).
- Student budget: the $300 trial credit, then the always-free tier. Idle cost matters more than
  peak cost.

## Decision: a GCP service for every piece of Spry

| Spry on AWS | On Google Cloud | Decision | Why |
|---|---|---|---|
| S3 + CloudFront + WAF, static frontend | Firebase Hosting | **Replace** (the AWS copy stays) | CDN and HTTPS included, free plan. Rewrites `/api/**` to Cloud Run, so the frontend and API share one origin: no CORS and no API URL in the bundle, as CloudFront did. |
| Lambda + function URL, FastAPI | Cloud Run | **Replace** | Runs the same image with no adapter (`docker build --target app`). Scales to zero, so an idle month is $0, and there is no 15-minute limit. |
| ECR | Artifact Registry | **Replace** | One Docker repository; a cleanup policy keeps the newest 3 images to stay near the 0.5 GB free tier. |
| Aurora Serverless v2 (0–1 ACU, pauses) | Cloud SQL for PostgreSQL 17, `db-f1-micro`, 10 GB SSD | **Replace** | See *The database* below. |
| DynamoDB | Firestore | **Drop** (not used) | Spry never moved off SQL. |
| Cognito user pool + Google | Identity Platform | **Keep on AWS** | See *What we do not move*. The API on Cloud Run verifies Cognito ID tokens: it downloads the pool's signing keys over the internet, which Cloud Run has. |
| EventBridge Scheduler | Cloud Scheduler | **Keep on AWS** | Weekly report stays on AWS. |
| SQS | Pub/Sub / Cloud Tasks | **Keep on AWS** | As above. Cloud Tasks would be the closer match (a work queue with retries). |
| S3 event → Lambda | Cloud Storage + Eventarc → Cloud Run | **Keep on AWS** | As above. |
| SES | no Google service | **Keep SES** | See *E-mail*. |
| Bedrock (Nova Lite / Claude) | Vertex AI (Gemini, Claude through Model Garden) | **Keep on AWS** | The parser is its own Lambda with a function URL; the frontend calls it directly and it accepts the same Cognito token. The trial credit does not pay for Claude on Vertex. Gemini is the stretch comparison. |
| SSM Parameter Store / Secrets Manager | Secret Manager | **Replace** | One secret: the database URL with a password Terraform generates. Only the API's service account can read it. |
| CloudWatch Logs | Cloud Logging | **Replace** (automatic) | Cloud Run sends stdout to Cloud Logging with no setup; 50 GiB a month is free. |
| IAM roles | Service accounts + IAM roles | **Replace** | One account per program: `terraform` (HCP Terraform), `new-project-api` (the API at runtime), `deployer` (GitHub Actions, stretch). No Owner or Editor roles, and no keys: Workload Identity Federation. |
| Terraform `aws` provider | Terraform `google` provider | **Replace** | `gcp/` with its own HCP Terraform workspace (`new-project-gcp`) and state. One plan cannot touch both clouds. |
| VPC, subnets, S3 gateway endpoint | none | **Drop** | Cloud Run reaches Cloud SQL through the built-in Cloud SQL connection: an IAM-checked, encrypted tunnel to an instance with no authorised networks. There is no VPC, connector or NAT to pay for. |

### The database
Options, from what each does to latency, the bill and the code:

| Option | Latency | Bill (idle month) | Code |
|---|---|---|---|
| Cloud SQL 24/7 | Same region as Cloud Run, ~1 ms per query | $7.67 compute + $1.70 storage ≈ **$9.40** | None: same PostgreSQL, same migrations |
| Cloud SQL, stopped when not in use | Same; the first request after `make gcp-db-start` waits about a minute for the start | **$1.70** storage, plus the public IP if Google bills it while stopped (see answers, Part 3) | None |
| Firestore | Single-digit ms per document read | **$0** at student traffic | Rewrite models, queries, migrations and the many-to-many join as documents; every list page is billed per document read |
| Keep Aurora on AWS, call it across clouds | us-central1 ↔ us-east-1 is ~30–40 ms per round trip, and a list request makes several queries. Aurora's 15 s resume becomes a Cloud Run cold start | Aurora as today plus egress (~$0.09/GB out of AWS) | Aurora is in private subnets with no public access, so it needs a public endpoint or a VPN, which undoes Lab 4's network design |

**Decision: Cloud SQL `db-f1-micro`, stopped when not in use.** It is the only option that moves
the core unchanged. The relational model and the migrations are the most valuable code in the
backend; giving them up to save ~$8 a month is the wrong trade for a project of this size.
The schema comes from running the existing Alembic migrations against the empty database
(the container runs `alembic upgrade head` on start). Lab data is not copied from Aurora:
Aurora is private, and users and meetings are recreated through the app.
Terraform creates the instance running and then ignores `activation_policy`, so
`make gcp-db-stop` is not undone by the next apply.

### E-mail
**Keep Amazon SES.** Google has no e-mail service, and the weekly report (the only sender) stays
on AWS. The mailer Lambda already sends with its IAM role, so there is no API key to store.

When the report moves to Google Cloud, it keeps SES and still uses no key. The Cloud Run job
gets a Google-signed ID token for its own service account. It exchanges that for AWS
credentials with `AssumeRoleWithWebIdentity`, against an IAM role that trusts
`accounts.google.com` for that one service account. This is workload identity federation in
the other direction. A provider such as Mailgun or SendGrid is the fallback. Its API key would
go in Secret Manager (`new-project-mail-api-key`), readable only by the report job's service
account, and never in the repository or Terraform variables.

### What we do not move, and why
- **Sign-in (Cognito).** Cognito cannot export password hashes, so moving users to Identity
  Platform means a forced password reset or a lazy migration through a Cognito trigger. Users
  and their `cognito_sub` are already in the database. Identity Platform's larger free tier
  (50,000 MAU against 10,000) does not matter at our size. Cross-cloud cost is one key download
  per Cloud Run instance.
- **The weekly report (EventBridge, SQS, S3, two Lambdas, SES).** It works, it costs $0, and
  moving it means rewriting the glue (SQS records, S3 events, Lambda handlers) for no new
  capability.
- **The agenda parser (Bedrock).** Nova Lite costs fractions of a cent per parse; the trial
  credit does not cover Claude on Vertex AI. It is the stretch comparison with Gemini, not a
  reason to move.

## Consequences

### Positive
- The backend image runs on Cloud Run unchanged. The only Lambda-specific parts were the
  adapter (now a separate `lambda` build stage) and the `/events` route for non-HTTP events
  (now registered only when `AWS_LAMBDA_FUNCTION_NAME` is set).
- No long-lived keys on either cloud: HCP Terraform reaches Google through Workload Identity
  Federation, admitting only our organisation and workspace by ID.
- A fresh project is reproducible: `gcp/bootstrap/` (once, by the owner) and then `gcp/`.

### Negative and mitigations
- **Cloud SQL does not scale to zero.** Mitigation: `make gcp-db-stop`, a budget alert, and
  `terraform destroy` of the workspace after the lab.
- **The system now spans two clouds.** Sign-in and the parser are on AWS, so an AWS outage
  takes down sign-in on the GCP copy too. Cognito must list the Firebase origins
  (`app_urls` in `infra/terraform.tfvars`) for the Google redirect and the parser's CORS.
- **`db-f1-micro` is shared-core with 0.6 GB of memory and no SLA.** Fine for a demo. A real
  deployment would use `db-g1-small` or a dedicated-core tier, at 3–5 times the price.
- **The database password is in Terraform state** (encrypted in HCP Terraform, as in ADR 0007).
  Write-only arguments with an ephemeral password would keep it out of state; not worth the
  rotation complexity for a lab.
