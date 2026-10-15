# Lab Answers — Part 3, Step 7

## Question 1
> **The mailer got the same `ObjectCreated` event twice, and the person got two identical emails. Where would you store "this report was already sent", and what would the key be?**

### Answer:
To make the mailer idempotent and prevent sending duplicate emails, the delivery state should be stored in a distributed, atomic key-value store such as **Amazon DynamoDB** (or a dedicated `sent_reports` table in PostgreSQL).

1. **Storage Choice:** 
   - **Amazon DynamoDB** is ideal because it is serverless, low-latency (<10ms), and supports atomic conditional writes (`attribute_not_exists`).
2. **Key Design:**
   - **Partition Key (`PK`):** `report#<week>` (e.g., `report#2026-W41`) or the exact S3 object key (`reports/2026-W41.csv`), optionally combined with recipient email: `report#2026-W41#<recipient_email>` if sent per user.
3. **Idempotency Mechanism:**
   - Before sending the email via SES, the mailer executes a conditional write:
     ```python
     dynamodb.put_item(
         TableName="sent_reports",
         Item={
             "report_id": {"S": f"report#{week}"},
             "sent_at": {"S": datetime.now(timezone.utc).isoformat()},
             "ttl": {"N": str(int(time.time()) + 90 * 86400)},  # 90-day TTL
         },
         ConditionExpression="attribute_not_exists(report_id)",
     )
     ```
   - If the key already exists, DynamoDB raises `ConditionalCheckFailedException`, and the mailer quietly terminates with success (`200 OK`) without sending a duplicate email.
   - DynamoDB's built-in **TTL (Time to Live)** automatically cleans up old entries after 90 days at zero cost.

---

## Question 2
> **The builder in the VPC could not reach SES. List three ways to fix that, with their monthly cost: a NAT gateway, a VPC interface endpoint for SES, and the split you built. Which would you choose with ten more emails a week? With a million?**

### Answer:

### Three Ways to Solve VPC-to-SES Connectivity:

1. **NAT Gateway:**
   - **How it works:** Place an AWS NAT Gateway in a public subnet, add an Internet Gateway to the VPC, and route outbound internet traffic `0.0.0.0/0` from private subnets through the NAT Gateway. The builder Lambda can then call SES over the public internet.
   - **Monthly Cost:**
     - Hourly rate: $0.045/hour $\times$ 730 hours $\approx$ **$32.85/month** (per AZ).
     - Data processing: $0.045 per GB transferred.
     - Total: **~$33/month fixed cost** regardless of whether traffic is sent.

2. **VPC Interface Endpoint for SES (AWS PrivateLink):**
   - **How it works:** Create an Interface VPC Endpoint (`com.amazonaws.<region>.email-smtp` or SES API) directly inside the private subnets. Traffic remains inside the AWS backbone network without needing internet access.
   - **Monthly Cost:**
     - Hourly rate: $0.01/hour per AZ $\times$ 2 AZs $\times$ 730 hours $\approx$ **$14.60/month**.
     - Data processing: $0.01 per GB.
     - Total: **~$14.60/month fixed cost**.

3. **The Split Architecture (Builder in VPC $\to$ S3 Gateway Endpoint $\to$ Mailer outside VPC):**
   - **How it works:** The builder Lambda stays inside the VPC, writes the CSV to S3 via an **S3 Gateway VPC Endpoint** (which is free). An S3 `ObjectCreated` event triggers the mailer Lambda, which runs outside the VPC with direct, native internet access to SES.
   - **Monthly Cost:**
     - S3 Gateway Endpoint: **$0.00** (free).
     - S3 Storage & Events: negligible / within Free Tier ($0.023/GB-month).
     - Lambda Invocations: well within the monthly 1,000,000 free requests.
     - Total fixed cost: **$0.00/month**.

### Which to choose?
- **With 10 more emails a week:**
  - **Choose the Split Architecture ($0/month).** Paying $14.60/month or $33/month in standing infrastructure fees for 10 emails a week is financially inefficient and unjustifiable.
- **With a million emails a week:**
  - **Choose the Split Architecture.** At high scale, decoupling heavy database queries from high-volume email dispatch prevents Lambda concurrency exhaustion and eliminates database connection pooling pressure. The mailer can scale independently, retry failed emails without re-running expensive SQL queries, and buffer requests. If a synchronous in-VPC call was strictly mandatory, the **VPC Interface Endpoint (~$14.60/mo)** would be preferred over a NAT Gateway (~$33/mo) for cost and security.

---

## Question 3
> **You could send a presigned S3 link instead of an attachment. A presigned URL signed with a Lambda role's temporary credentials stops working when those credentials expire, often within hours. How would you send a link that works for a week?**

### Answer:
Presigned URLs signed using STS temporary credentials (such as an IAM role assigned to Lambda) are strictly capped by the maximum lifetime of that temporary session (typically 1 hour, or at most 12 hours). When the temporary credentials expire, the URL returns `AccessDenied`, even if `ExpiresIn=604800` (7 days) was specified in the `generate_presigned_url` call.

To provide a download link valid for a week:

1. **Amazon CloudFront Signed URLs with a Trusted Key Group (Recommended AWS Production Solution):**
   - Place an Amazon CloudFront distribution in front of the private S3 bucket using Origin Access Control (OAC).
   - Generate an RSA key pair and upload the public key to a **CloudFront Key Group**.
   - Use the private key to generate a **CloudFront Signed URL**:
     ```python
     from botocore.signers import CloudFrontSigner

     signer = CloudFrontSigner(key_id, rsa_signer)
     signed_url = signer.generate_presigned_url(
         f"https://reports.yourdomain.com/reports/{week}.csv",
         date_less_than=datetime.now(timezone.utc) + timedelta(days=7),
     )
     ```
   - **Why this works:** CloudFront signed URLs do **not** depend on temporary IAM/STS tokens; they are cryptographically validated by CloudFront against the public key and can remain valid for days, months, or years.

2. **Web Application Proxy Endpoint:**
   - Instead of linking directly to S3, send a link to an authenticated web application endpoint: `https://app.yourdomain.com/api/reports/2026-W41`.
   - When the user clicks the link, the backend authenticates the user, generates a fresh short-lived presigned URL (valid for 15 minutes) on the fly, and returns an HTTP 302 redirect to S3.

3. **Long-term IAM User Credentials (Alternative, less secure):**
   - Sign the S3 presigned URL using permanent IAM user Access Key / Secret Key credentials (which do not use STS temporary tokens). In this case, `boto3` allows `ExpiresIn=604800` (7 days). However, this requires managing long-lived static credentials, making CloudFront Signed URLs the cleaner and safer choice.
