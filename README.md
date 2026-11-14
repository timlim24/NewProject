# Meetings App

List, create, and delete meetings with participants. FastAPI + PostgreSQL backend, React + shadcn/ui frontend, all run with Docker Compose. See [SPEC.md](SPEC.md) for the full specification.

## Quick start

Requires Docker.

```sh
make up      # creates .env from .env.example, builds and starts everything
make seed    # optional: sample participants and meetings
```

- App: http://localhost:3000
- API docs: http://localhost:8000/api/docs

If port 5432 is already in use on your machine, set `DB_PORT` in `.env` (e.g. `DB_PORT=5433`).

## Common commands

Run `make` to list all targets. The most used:

| Command | What it does |
|---|---|
| `make up` / `make down` | Start / stop the stack |
| `make logs s=backend` | Follow logs of one service |
| `make test` | Backend tests (in the backend container, against `<db>_test`) |
| `make lint` / `make format` | Ruff + oxlint/Prettier |
| `make migration m="..."` | Autogenerate an Alembic migration |
| `make psql` | Open a psql shell |
| `make clean` | Stop and delete the database volume |
| `make infra-plan` | Run speculative `terraform plan` remotely against HCP Terraform |
| `make infra-fmt` | Check Terraform formatting (`terraform fmt -check`) |
| `make infra-validate` | Validate Terraform syntax and configuration |
| `make report-now WEEK=...` | Trigger weekly report on demand via SQS |

## Local development without rebuilding images

Requires [uv](https://docs.astral.sh/uv/) and Node.js.

```sh
make install        # uv sync + npm install
make dev-backend    # Postgres in Docker, API on :8000 with reload
make dev-frontend   # Vite on :5173, proxies /api to :8000
```

## Infrastructure as Code & Deployment

Infrastructure is split into two roads:

1. **Infrastructure Road (Terraform & HCP Terraform):**
   - Managed in [`infra/`](infra/) with Terraform HCL:
     - `auth.tf`: Amazon Cognito user pool, app client, hosted domain, and Google OAuth IdP.
     - `reports.tf`: S3 reports bucket, SQS request queues & DLQ, EventBridge Scheduler, report-builder Lambda, report-mailer Lambda, and S3 upload notifications.
     - `ai.tf`: Agenda parser Lambda (Claude through Amazon Bedrock), Function URL, and IAM execution roles.
   - Remote execution and state locking run via **HCP Terraform (Terraform Cloud)** in workspace `new-project-dev` (`ooad-timlim`).
   - Dynamic credentials use **AWS IAM OIDC Federation** (`TFC_AWS_PROVIDER_AUTH = true`), eliminating static AWS keys in CI.
   - **No `terraform apply` locally.** Developers preview changes with `make infra-plan`. HCP Terraform runs `apply` automatically upon merging a pull request to `main`.
   - See [ADR 0007](docs/adr/0007-terraform.md) for the architecture decision.

2. **Application Road (Containers & Assets):**
   - **Backend** (`make deploy-backend`): the backend container on AWS Lambda (via Lambda Web Adapter), exposed through a public **Lambda function URL**, and its PostgreSQL 17 database on **Aurora Serverless v2**.
   - **Frontend** (`make deploy-frontend`): the React SPA in a private S3 bucket behind CloudFront on pay-as-you-go pricing, reading Cognito and API endpoints from Terraform outputs.
   - Deploys run either via GitHub Actions CI/CD on push or via `make deploy` (backend, then frontend).

### Custom domain

Once everything is deployed, set the domain in `.env` and attach it:

```sh
DOMAIN_NAME=app.example.com
HOSTED_ZONE_ID=Z0123456789ABC   # optional: only if the domain's DNS is in Route 53
```

```sh
make add-domain
```

This requests an ACM certificate in `us-east-1` (the only region CloudFront accepts), adds the domain to the CloudFront distribution and to the backend's CORS origins. With `HOSTED_ZONE_ID`, the validation and alias records are created in Route 53 for you. Without it, the command prints the validation CNAME to add at your DNS provider, waits for the certificate, and then prints the CNAME that points the domain at CloudFront. Later `make deploy` runs keep the domain. `make remove-domain` detaches it again (to switch domains: `make remove-domain`, change `DOMAIN_NAME`, `make add-domain`).

### Tags

Every AWS resource that supports tags is tagged `PROJECT_NAME=<PROJECT_NAME>` (in the templates as `Key: PROJECT_NAME, Value: !Ref ProjectName`, plus stack tags and tags on the SSM parameter). Find the whole app with Resource Groups & Tag Editor, and split out its costs in Billing once `PROJECT_NAME` is activated as a cost allocation tag. `APP_NAME` in older `.env` files still works as the project name.

## Google Cloud

The core of the app also runs on Google Cloud: the frontend on **Firebase Hosting**, the API on
**Cloud Run**, the database on **Cloud SQL for PostgreSQL** (`db-f1-micro`). The image is the
same as on Lambda, built without the Lambda adapter (`--target app`). Firebase rewrites `/api/**`
to Cloud Run, so the site and the API share one origin. See [ADR 0008](docs/adr/0008-google-cloud.md)
for the service choices and [docs/GCP_LAB_ANSWERS.md](docs/GCP_LAB_ANSWERS.md) for the costs.

**Still on AWS:** sign-in (Cognito; the API on Cloud Run accepts the same ID tokens), the weekly
report (EventBridge, SQS, S3, SES) and the agenda parser (Bedrock). Both deployments run side by
side against their own databases.

Infrastructure is in [`gcp/`](gcp/), separate from `infra/`, with its own HCP Terraform workspace
and state. Nothing uses a service account key: HCP Terraform signs in through Workload Identity
Federation, and you sign in with the gcloud CLI.

### One-time setup

1. **Project:** create the project in the console (the ID is permanent; it is `project_id` in
   `gcp/terraform.tfvars` and `gcp/bootstrap/terraform.tfvars`), link billing, and create a
   budget alert (Billing → Budgets & alerts, e.g. $5/month).
2. **CLI:** install the [gcloud CLI](https://cloud.google.com/sdk/docs/install), then
   `gcloud auth login` and `gcloud auth application-default login`.
3. **HCP Terraform:** create two workspaces in `ooad-timlim`:
   - `new-project-gcp-bootstrap`: CLI-driven, *Settings → General → Execution Mode: Local*.
   - `new-project-gcp`: version-control workflow on this repository, *Terraform Working
     Directory* `gcp`, trigger only on `gcp/**`.
   Put the organization ID (`org-...`) and the ID of `new-project-gcp` (`ws-...`) in
   `gcp/bootstrap/terraform.tfvars`.
4. **Bootstrap** (as the project owner, from your laptop): `cd gcp/bootstrap && terraform init && terraform apply`.
   It creates the `terraform` and `new-project-api` service accounts and the workload identity
   pool. Set its three `TFC_GCP_*` outputs as **environment variables** of the
   `new-project-gcp` workspace.
5. **Infrastructure:** open a pull request that touches `gcp/`. HCP Terraform plans it, and on
   merge it enables the APIs and creates Artifact Registry, Cloud SQL (about 10 minutes),
   the database secret and the Cloud Run service. `make gcp-plan` previews it from your laptop.
6. **Firebase:** `npx firebase-tools@15.34.2 login` and
   `npx firebase-tools@15.34.2 projects:addfirebase <project-id>` (once).

### Deploy

```sh
make gcp-deploy            # gcp-deploy-backend, then gcp-deploy-frontend
```

- `make gcp-deploy-backend` builds the image, pushes it to Artifact Registry and rolls it out
  on Cloud Run. The container runs the migrations against Cloud SQL on start. The service's
  configuration (database, secret, scaling) belongs to Terraform; the script changes only the image.
- `make gcp-deploy-frontend` builds the SPA with the Cognito IDs from `infra/` and deploys it
  to `https://<project-id>.web.app`. For Google sign-in and the parser to work there, the
  Firebase origins must be in `app_urls` in `infra/terraform.tfvars` (they are, for
  `spry-514721`).

### Stop the database

Cloud SQL does not pause like Aurora: it bills $0.0105/h until stopped.

```sh
make gcp-db-stop     # storage still bills ($1.70/month for 10 GB); the API fails until started
make gcp-db-start    # about a minute
make gcp-db-status
```

Terraform creates the instance running and then leaves the on/off switch alone, so an apply does
not restart it. To remove everything, queue a destroy plan for `new-project-gcp` in HCP Terraform
(*Settings → Destruction and Deletion*). Then check *Billing → Reports* a day later.

## Layout

```
backend/    FastAPI app (app/), Alembic migrations (alembic/), tests (tests/)
frontend/   Vite + React + shadcn/ui (src/components/ui is generated by shadcn); firebase.json
infra/      Terraform HCL infrastructure on AWS (auth, reports, ai) and backend/frontend deploy scripts
gcp/        Terraform for Google Cloud (Cloud Run, Cloud SQL, Artifact Registry, Secret Manager),
            gcp/bootstrap/ (service accounts, Workload Identity Federation) and deploy scripts
docs/       Architecture decision records (docs/adr/) and lab answers
```
