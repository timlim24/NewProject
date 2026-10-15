# Weekly Meetings Report — Event-Driven Architecture on AWS

## Overview & Architecture

This lab implements an automated weekly meetings report on AWS using an asynchronous, event-driven pattern:
1. **EventBridge Scheduler**: Fires every Monday at 07:00 (`Europe/Kyiv` timezone) and publishes a command `{"week": null, "source": "schedule"}` into **Amazon SQS** (`new-project-report-requests`).
2. **On-Demand Report**: Running `make report-now WEEK=2026-W41` sends an on-demand command `{"week": "2026-W41", "source": "manual"}` into the same SQS queue.
3. **Report Builder Lambda** (`new-project-report-builder`):
   - Runs in the private VPC subnets with Aurora PostgreSQL access and no NAT gateway.
   - Polled by Lambda service via EventSourceMapping (BatchSize: 1).
   - Reuses the backend container image with command `app.reports.lambda_handler.handler`.
   - Queries Aurora for the specified week's metrics, delta comparison with previous week, top 5 longest meetings, and per-organizer breakdown.
   - Generates CSV report (`reports/{week}.csv`) and uploads it to private S3 bucket (`new-project-reports-<account-id>`) via the **S3 Gateway VPC Endpoint**.
4. **Report Mailer Lambda** (`new-project-report-mailer`):
   - Runs outside the VPC with direct internet connectivity to SES.
   - Triggered automatically by S3 `s3:ObjectCreated:*` notifications on `reports/*.csv`.
   - Reads CSV from S3, composes a MIME email with the CSV attachment using `email.message.EmailMessage`, and sends it to the verified recipient inbox via **Amazon SESv2**.

---

## Answers to Part 3, Step 7

### 1. Handling Duplicate S3 ObjectCreated Events (Idempotency in Mailer)
**Question:** The mailer got the same `ObjectCreated` event twice, and the person got two identical emails. Where would you store "this report was already sent", and what would the key be?

**Answer:**
We should store the deduplication state in a fast, atomic key-value store such as **Amazon DynamoDB** (or a dedicated `sent_reports` table in PostgreSQL).
- **Partition Key:** `report_id = "report#" + week` (e.g. `report#2026-W41`) or the exact S3 object ETag/version ID.
- **Mechanism:** Before sending the email, the mailer performs an atomic conditional write:
  `PutItem(TableName="sent_reports", Item={"report_id": "report#2026-W41", "sent_at": timestamp}, ConditionExpression="attribute_not_exists(report_id)")`.
  If the item already exists, DynamoDB throws `ConditionalCheckFailedException`, and the mailer quietly exits without sending a second email. A DynamoDB TTL (e.g. 90 days) can automatically clean up old records.

---

### 2. VPC Connectivity to SES & Cost Trade-offs
**Question:** The builder in the VPC could not reach SES. List three ways to fix that, with their monthly cost: a NAT gateway, a VPC interface endpoint for SES, and the split you built. Which would you choose with ten more emails a week? With a million?

**Answer:**
1. **NAT Gateway:**
   - **Cost:** ~$0.045/hour (~$32.40/month) + $0.045 per GB of data processed.
   - Allows all outbound internet traffic from private subnets.
2. **VPC Interface Endpoint (AWS PrivateLink) for SES (`email-smtp` / `com.amazonaws.<region>.email`):**
   - **Cost:** ~$0.01/hour per AZ (~$7.20/month per AZ, or ~$14.40/month across 2 AZs) + $0.01 per GB processed.
   - Keeps traffic entirely within AWS private network.
3. **The Split Architecture (Builder in VPC -> S3 Gateway Endpoint -> Mailer Lambda outside VPC):**
   - **Cost:** **$0.00/month** in fixed charges.
   - S3 Gateway VPC endpoints are completely free. Lambda and S3 events fall well within the free tier. Amazon SES charges $0.10 per 1,000 emails.

**Selection:**
- **For 10 more emails a week:** Choose the **Split Architecture**. Fixed charges of $14.40 or $32.40/month for a handful of emails are wasteful; the event-driven split has $0 fixed overhead.
- **For a million emails a week:** The **Split Architecture** remains superior because it decouples heavy database queries from high-volume email delivery, avoiding long-held connections and database bottlenecks. If synchronous in-VPC sending is strictly required, choose the **VPC Interface Endpoint** (~$14.40/month), which is less than half the cost of a NAT Gateway.

---

### 3. Long-Lived S3 Links vs Attachments
**Question:** You could send a presigned S3 link instead of an attachment. A presigned URL signed with a Lambda role's temporary credentials stops working when those credentials expire, often within hours. How would you send a link that works for a week?

**Answer:**
Presigned S3 URLs generated with IAM role / STS temporary credentials are bound by the token lifetime (maximum 1 to 12 hours). To generate a link valid for 7 days:
1. **Amazon CloudFront Signed URLs (Recommended):** Distribute reports via CloudFront with an Origin Access Control (OAC) to the private S3 bucket. Sign the URLs with a CloudFront Key Pair / Trusted Key Group using RSA private keys. CloudFront signed URLs do not rely on STS temporary tokens and can be set to expire at any arbitrary timestamp in the future (e.g. `now() + 7 days`).
2. **Authenticated Web App Proxy:** Send a permanent link to your web app (`https://app.your-domain.com/reports/2026-W41`), where user authentication validates the request and either streams the file or generates a fresh short-lived presigned URL on demand.

---

## Class Discussion Questions

### The Pattern
1. **Cake shop command vs event:**
   - **Command:** The order slip pinned to the rail ("Bake Napoleon cake, 8 portions"). In the lab: the message pushed to SQS (`{"week": "2026-W41", "source": "schedule"}`).
   - **Event:** "Your order is ready" / cake placed on shelf. In the lab: S3 `ObjectCreated` event emitted when `reports/2026-W41.csv` is uploaded.
2. **Receipt numbers & HTTP 202 Accepted:**
   - While running, the UI should show a non-blocking in-progress indicator ("Your report is being generated, job #...").
   - On failure, show an informative error message ("Report generation failed: ...") with an action to retry.
3. **Idempotency ("At least once" delivery):**
   - Writing `reports/2026-W40.csv` to S3 is **idempotent**: rewriting the exact same S3 key produces the exact same result with no side effects.
   - Sending the email via SES is **not idempotent**: calling SES `SendEmail` multiple times sends multiple duplicate emails to the inbox.
4. **Point-in-time snapshot vs eventual consistency:**
   - The report reflects the database state at exactly 07:00:00 UTC. An edit at 07:01 does not make the report incorrect for its intended 07:00 snapshot.
   - Eventual consistency means all distributed components converge over time. For Spry ("recomputed within 5 minutes of a change"), an event-driven hook on meeting mutation should trigger recalculation.
5. **Adding a Slack notification:**
   - Change in builder: **Nothing**. In event-driven design, the builder merely publishes an event (creates an S3 object). A new subscriber Lambda or SNS topic listens to the S3 event and posts to Slack independently.

### Self-Hosted Alternatives
6. **Payment events: Redis vs RabbitMQ:**
   - **RabbitMQ**: It offers AMQP explicit consumer acknowledgments, durable queues, and persistent disk writes. Redis lists lose messages if a worker pops a task and crashes mid-execution.
7. **RQ pickled jobs & schema evolution:**
   - If the task function is renamed, unpickling queued jobs raises `AttributeError`/`ModuleNotFoundError`.
   - Message payloads across services must use language-agnostic, backward-compatible serialized formats like JSON or Protobuf.
8. **Celery beat redundancy:**
   - Running two instances of Celery beat results in duplicate task dispatch.
   - The AWS equivalent is **EventBridge Scheduler**, which is distributed and highly available, guaranteeing schedule execution without running duplicate worker processes.

### AWS Infrastructure
9. **EventBridge Scheduler -> SQS vs direct Lambda invocation:**
   - SQS provides buffering, concurrency capping, automatic retries with visibility timeout backoff, and dead-letter queues. Direct invocation is only suitable for simple synchronous pings where failures do not require retry queues.
10. **SQS visibility timeout vs Lambda timeout:**
    - If visibility timeout is shorter than function timeout, a message will become visible to another worker while the first execution is still active, causing duplicate runs and race conditions.
11. **DLQ Alarms on Sunday night:**
    - Create a CloudWatch Alarm on metric `ApproximateNumberOfMessagesVisible > 0` on `new-project-report-requests-dlq` evaluating over 1 minute, notifying an Amazon SNS topic linked to email/SMS/PagerDuty.
12. **Aurora Serverless v2 Wake-up costs:**
    - Monday wake-up: ~6 minutes active (0.1 hours) per week * 4 weeks = 0.4 hours/month * 0.5 ACU * $0.06/ACU-hr = **~$0.012/month**.
    - Every 5 minutes: With 5-minute auto-pause, Aurora would never pause, running 24/7 (730 hours * 0.5 ACU * $0.06 = **~$21.90/month**).
13. **Cost emergence at scale:**
    - Initially, Aurora ACU and storage dominate. At high volume (millions of reports), SES ($0.10/1,000 emails) and Lambda compute dominate.
