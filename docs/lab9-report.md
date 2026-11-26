# Lab 9: One project, two clouds. Report

**Route: without a Google Cloud account.** The Free Trial signup for this project's Google account
was refused by Google Payments on 25 November 2026 ("For your protection, a Google Cloud signup was
denied"), so the lab's no-account route is used. Everything that does not need a bill is real:
- the `gcp/` Terraform configuration (`init` and `validate`);
- the app as Cloud Run runs it;
- the Colab demos;
- the Looker Studio dashboard;
- the cost table, which comes from public price lists.

| Item | Where |
| --- | --- |
| `gcp/` Terraform + ADR | `gcp/` (Cloud SQL, Cloud Run, Firebase Hosting, Artifact Registry, Secret Manager, service accounts, Workload Identity Federation, budget); [ADR 0008](adr/0008-google-cloud.md); `terraform init` / `validate` output: [`lab9-runs/terraform-init-validate.txt`](lab9-runs/terraform-init-validate.txt) |
| The app, ready for Cloud Run, running locally | [`lab9-runs/local-cloud-run.png`](lab9-runs/local-cloud-run.png) and [`.txt`](lab9-runs/local-cloud-run.txt) |
| Cost table | [below](#part-3-the-minimal-setup-on-both-clouds-and-what-it-costs) |
| Colab notebook (demos 1, 3, 4, 5) | https://colab.research.google.com/drive/1sYtCrVnhcsJD41YcL8m_Kqh2s8V3wRq7 (anyone with the link can view; Run all on the free CPU runtime, outputs saved) |
| Looker Studio dashboard | https://lookerstudio.google.com/reporting/a98a21ff-fa56-427f-a99b-02ff9ca379f3 (anyone with the link can view); screenshot: [`lab9-runs/looker-studio.png`](lab9-runs/looker-studio.png) |

## Part 0: a project you can automate

Everything Part 0 asks for is in `gcp/` and would be created with one apply:
- **APIs**: enabled from Terraform (`google_project_service`): Run, SQL Admin, Artifact Registry,
  Secret Manager, IAM, STS, Firebase, Billing Budgets…
- **Budget**: `google_billing_budget`, $5 a month, alerts at 50, 90 and 100%.
- **Service accounts, one per program**:
  - `meetings-api` runs Cloud Run. It holds only `roles/cloudsql.client` and access to the one
    secret it reads.
  - `meetings-deployer` is the CI identity.
  - The default compute account (Editor) is not used.
- **No keys.**
  - On a laptop: application default credentials (`gcloud auth application-default login`).
  - In CI: Workload Identity Federation (`gcp/wif.tf`). This is a pool, an OIDC provider for
    `token.actions.githubusercontent.com`, and an attribute condition on the **numeric**
    `repository_id` (1394976249) and `repository_owner_id` (246989247) and `ref == refs/heads/main`.
    `roles/iam.workloadIdentityUser` on the deployer is granted to
    `principalSet://…/attribute.repository_id/1394976249`. Lab 7 taught why IDs are used instead
    of names: GitHub's AWS tokens carry them too.

## Part 1: a service for every piece of Spry

See [ADR 0008](adr/0008-google-cloud.md).
- **Database:** Cloud SQL, stopped when unused. Spry is relational, so Firestore would mean rewriting
  the data layer. A cross-cloud Aurora adds 20–60 ms per query and needs a public database.
- **E-mail:** keep SES, with the key in Secret Manager.
- **Not moved:**
  - the agenda parser, which calls the OpenAI API;
  - sign-in, until the Cognito users can be migrated;
  - the weekly report, five AWS services of glue with no user-visible gain.

## Part 2: the core on Google Cloud (no-account route)

- **`gcp/` configuration.**
  - Its own state: key `gcp/terraform.tfstate` in the project's S3 state bucket, so it cannot share
    a plan with `infra/`.
  - Cloud SQL PostgreSQL 16, db-f1-micro, 10 GB SSD. It has a public IP with no authorized networks,
    so only the Cloud SQL connector reaches it and no VPC connector bills by the hour.
    `activation_policy` follows `db_running`, which is how the instance is stopped.
  - The password comes from `random_password` into Secret Manager.
  - Cloud Run runs the backend image with min 0 and max 2 instances and request-based billing. It
    mounts the Cloud SQL socket and reads the password secret. It runs as `meetings-api` and is public,
    because the API verifies Cognito tokens itself.
  - Firebase Hosting rewrites `/api/**` to the Cloud Run service (`gcp/firebase.json`): one origin and
    no CORS, as CloudFront did.
  - `terraform validate` passes without Google credentials.
- **The app as Cloud Run runs it.**
  - `back/Dockerfile`, the Docker Compose image, now listens on `${PORT:-8000}` and trusts the proxy
    headers. Nothing else was needed: the Lambda image and Mangum are simply not used.
  - Run with `docker run -e PORT=8080 -p 8080:8080` next to `postgres:16-alpine`:
    - migrations and seeding ran on start, which is what loading the data means here (the Aurora
      data cannot be dumped: Aurora sits in a private VPC);
    - `/api/health` answers `{"status":"ok"}` (a `SELECT 1`);
    - the SPA built with `VITE_API_URL=http://localhost:8080` shows a meeting read from the database
      (`lab9-runs/local-cloud-run.png`).
- **With a billing account** the remaining steps would be:
  1. `gcloud auth application-default login`;
  2. `terraform -chdir=gcp apply -var project_id=spry-… -var cognito_user_pool_id=… -var cognito_client_id=…`;
  3. `docker push` to Artifact Registry;
  4. `firebase deploy --only hosting` from `gcp/`;
  5. add `https://<project>.web.app` to the Cognito callback URLs (`infra/`, Lab 7 pipeline).

## Part 3: the minimal setup on both clouds, and what it costs

List prices from the lab (5 November 2026), us-east-1 and us-central1, 730 h a month, no tax.

**This project's AWS core** (Lab 4):
- CloudFront on the Free plan: $0.
- Lambda: free tier up to 1M requests.
- Aurora Serverless v2, 0–1 ACU, pausing after 300 s idle. Awake ≈ 0.5 ACU × $0.12 = $0.06 an hour.
- 1 GB storage: $0.10.
- Secrets Manager for the DB password: $0.40.
- ECR and logs: ≈ $0.05.

**Google Cloud** (this lab's `gcp/`):
- Firebase Hosting: $0.
- Cloud Run: free tier 2M requests and 180,000 vCPU-s.
- Cloud SQL db-f1-micro: $0.0105 an hour while running.
- 10 GB SSD: $1.70 a month, also while stopped.
- Secret Manager, Artifact Registry and logs: within the free tier.

The four traffic profiles from Lab 4. Database hours awake: nobody 0; class demos 10 × 2 h (+5 min
pause delay each) ≈ 21 h; office hours 8 h × 22 days ≈ 178 h; busy 730 h:

| Profile | AWS: Aurora (pauses) | GCP: Cloud SQL always on | GCP: Cloud SQL started only when used | GCP: Firestore |
| --- | --- | --- | --- | --- |
| Nobody | **≈ $0.55** (storage $0.10 + secret $0.40 + ECR) | $9.37 ($7.67 + $1.70) | **$1.70** (storage only) | **$0** |
| Class demos (10 × 2 h) | **≈ $1.81** (21 h × $0.06 + $0.55) | $9.37 | ≈ $1.92 (20 h × $0.0105 + $1.70) | $0 |
| Office hours (8 h × 22 days) | ≈ $11.23 (178 h × $0.06 + $0.55) | **$9.37** | **≈ $3.55** (176 h × $0.0105 + $1.70) | $0 (within 50,000 reads a day) |
| Busy, around the clock | ≈ $44.70 ($43.80 + $0.55 + Lambda ≈ $0.35 over 1M requests) | **≈ $9.61** ($9.37 + Cloud Run ≈ $0.24 over 2M requests) | the same, it never stops | reads beyond the free quota: ≈ $3–10, depending on reads per page |

**Which cloud is cheaper, and which line decides.** The **database compute line** decides every
profile; the rest is free tier on both sides.
- Nobody and class demos: **AWS**. Aurora pauses to $0 compute, while a Cloud SQL instance bills
  every hour it exists unless someone stops it.
- Office hours: **GCP**, $9.37 against $11.23, or $3.55 if the instance is started only for them.
- Busy around the clock: **GCP** by far, $9.61 against $44.70. But db-f1-micro is a shared core with
  0.6 GB, and 0.5 ACU is ~1 GiB with a real vCPU share. A fairer pair is db-g1-small ($0.035/h →
  $25.55 + $1.70) at about $27: still cheaper than Aurora at 0.5 ACU.

**The trap on the GCP side** (Lab 4's "something keeps Aurora awake"):
- On GCP it is the reverse: **nothing ever puts Cloud SQL to sleep**. An instance someone forgot
  bills $9.37 a month for nobody. Stopping it still bills the 10 GB disk.
- The quieter traps around Cloud Run:
  - `min_instance_count = 1`, or "CPU always allocated", turns a $0 service into a 24/7 bill;
  - a **Serverless VPC Access connector** (needed for a private-IP Cloud SQL) bills two e2-micro
    instances around the clock (~$12/month). That is why `gcp/` uses the public-IP Cloud SQL
    connector with no authorized networks instead.
- A health check every minute is harmless on Cloud Run (request-based), but it is exactly what kept
  Aurora awake in Lab 4.

## Part 4: what else Google Cloud is good at

The Colab notebook (https://colab.research.google.com/drive/1sYtCrVnhcsJD41YcL8m_Kqh2s8V3wRq7, Run all on the free CPU runtime, outputs saved) contains:
1. **SQL over a public dataset** (DuckDB over the NYC taxi Parquet, instead of BigQuery): trips and
   average fare by hour.
2. **OCR** with Tesseract and EasyOCR on the test receipt, with word boxes (instead of Vision API).
3. **Document parsing**: Qwen3-VL 2B through Ollama turns the scanned invoice into Markdown (instead
   of Document AI).
4. **My prompt**, an LLM as a form parser: JSON with 9 fields, run on the Markdown (A) and on the image (B).

Results of the run (25 November 2026, free **CPU** runtime, no GPU):
- **OCR.** Tesseract (`ukr+eng`) read the tilted receipt fully, both Cyrillic and Latin: "КАВ'ЯРНЯ «СПРАЙ»
  … РАЗОМ 203.00 грн … Дякуємо! Thank you!". EasyOCR found the same lines with boxes.
- **Document parsing.** Qwen3-VL 2B turned the scanned invoice into Markdown in **158 s**. Labels stayed
  next to their values, and the items became a Markdown table. One error: the street name
  "Kozelnytska" came out as "Kozelny**s**ka".
- **My prompt** (in the notebook, cell `MY_PROMPT`). It defines each field by its label on the page,
  says that Subtotal, VAT and Total are not items, asks for `unit_price` from the Unit price column
  and not Amount, asks for plain numbers, and asks to copy text exactly and to invent nothing.
  - A (Markdown): **8 of 9 fields** in **58 s**.
  - B (image): **8 of 9 fields** in **48 s**.

  Both missed only `seller`, with the same "Kozelnyska" letter drop. Every number, date, item and
  the buyer is right. This matches the reference result in the notebook (8 of 9 for A and B).
  A stricter wording about transliterated names did not fix it and made B worse: on the image it
  merged the buyer into the seller. So the first, simpler prompt is kept.

**Three sentences.** **The Markdown and the image worked equally well (8 of 9 each).** The one wrong field is the same
misread street name. On the Markdown the model copies the error the parser already made. On the
image it makes the same mistake itself, because both steps are the same 2B model looking at the same
pixels. The Markdown input is more stable: with a stricter prompt the image run merged two fields,
while the Markdown run stayed at 8/9. On the free Colab **CPU** runtime, section 4 (page to Markdown)
took **158 s** and section 5 took **58 s (A) + 48 s (B)**. On a T4 these would be about 30 s and 2–3 s.
**I would pay for Document AI** when there are thousands of invoices a month (OCR $1.50 per 1,000
pages is cheaper than a GPU, and much faster than this), when every letter of a name or IBAN must be
right and come with a confidence score for review, when tables span pages, and when the documents
may not leave a certified environment. An open model is fine for a few documents, for drafts a
person checks, or when the data may not go to any cloud at all.

**Looker Studio** (https://lookerstudio.google.com/reporting/a98a21ff-fa56-427f-a99b-02ff9ca379f3). The source is a Google Sheet with the Our World in Data CO₂ table,
1950–2025 (19,613 rows: country, iso_code, year, population, gdp, co2, co2_per_capita, coal, oil and
gas CO₂). The report has four parts:
- a line chart of world emissions by year (`country = World`);
- a geo chart of CO₂ per person in 2023 (`iso_code` as a country code);
- a top-10 bar chart for 2023 (rows without `iso_code`, such as World or Europe, are filtered out);
- a drop-down control on `country`.

What it shows:
- World emissions grew from 5.9 Gt in 1950 to 38.1 Gt in 2023, about 6.4 times. The line falls only in
  crisis years: the oil shocks (1974–75, 1980–82), the collapse of the USSR (1992), 2009 and 2020.
- Ten countries emit 69% of the total. China (12.3 Gt) emits more than the next three together
  (United States 4.9, India 3.0, Russia 1.7).
- The map tells a different story from the bar chart. Per person, the leaders are the Gulf states
  (Qatar 32.8 t, Kuwait 22.1 t), then the United States (14.3 t). China is at 8.6 t and India at
  2.1 t, against a world average of 4.7 t.
- The drop-down narrows the bar chart and the map to the chosen countries. For Ukraine the same
  Sheet gives 707 Mt in 1990 and 140 Mt in 2023.

No bill and no Cloud project were needed: Looker Studio reads the Sheet with the Google account alone.

**Document AI against a general model (the Lab 6 question).**
- A specialised service wins when:
  - the documents are many and similar (invoices, IDs, bank statements);
  - the same answer every time matters more than flexibility;
  - tables span pages, or the scans are poor or handwritten;
  - you need confidence scores and bounding boxes for review;
  - the documents may not leave a certified environment.

  At $1.50 per 1,000 pages for OCR it is cheaper than any LLM per page.
- A general model wins when:
  - the input is free text with no layout (the Lab 6 agenda);
  - the fields change every week;
  - there are too few documents to train a custom extractor;
  - the answer needs reasoning ("by Friday" → a date).

**Lab 8 on Google Cloud.**
- **BigQuery** replaces Athena, the Glue Data Catalog and the CTAS step. You load or stream the JSON
  into a table once, and it is stored columnar. There is no SerDe, no partition repair and no
  Parquet copy to manage. The price is per byte scanned, as in Athena ($6.25 per TiB, the first 1 TiB
  a month free).
- **Dataflow (Apache Beam)** replaces Glue jobs, Firehose and Kinesis Data Analytics or Flink. The
  same pipeline code runs batch over the month or streaming from **Pub/Sub** (instead of Kinesis).
  Windowing, watermarks and late data are part of the model, which is exactly what our Lambda
  tumbling window lacked.
- **Looker Studio** replaces QuickSight (free).
- What you no longer manage: the partition layout, the file format, the crawler and schema drift,
  and the shard count. What you still manage: the schema, and the cost of what you scan.

## Part 5: certifications

The most useful next step after this course is **Associate Cloud Engineer** ($125). It is exactly
Parts 0–2 of this lab: projects, IAM and service accounts, Cloud Run, Cloud SQL, Terraform. The
data path (Lab 8 and Part 4) leads to **Associate Data Practitioner**. On the AWS side, Labs 2–8
cover most of **Solutions Architect – Associate**. The free one on the course Bonus list is the
**OCI Multicloud Architect Associate** (the Oracle Bridge program).

## What we discuss in class

**Lock-in. Which parts moved unchanged, which had to be rewritten, and where is the lock-in?**
- Moved unchanged:
  - the **compute**: the same image, one line for `$PORT`;
  - the **data**: PostgreSQL to PostgreSQL, the same Alembic migrations;
  - the **frontend**: a static build.
- Rewritten:
  - the deployment (Terraform `google` instead of `aws`);
  - the IAM model (service accounts and WIF instead of roles and OIDC);
  - the CDN configuration (Firebase rewrites instead of CloudFront behaviours).
- The lock-in sits in the **managed services around** the core: Cognito, SES, SQS, EventBridge
  Scheduler, S3 events, Bedrock. And in the data gravity of everything already stored on one side.

**Multicloud: a good idea, or only a migration state?** Splitting one request path across clouds
is a migration state:
- every query to a database in the other cloud costs 20–60 ms, multiplied by the queries per request;
- egress is $0.08–0.12 per GB each way;
- there are two IAM models, two bills and two on-call runbooks.

Multicloud by **workload** is reasonable: analytics in BigQuery, the app on AWS; or a second cloud
for one service it does best, such as e-mail on SES from GCP. Keep each request's path in one cloud.

**Scale to zero: when is giving up SQL worth ~$9 a month?**
- It is worth it when the data is naturally a set of documents read by key: user settings, a cache
  of parsed agendas, events.
- It is a bad trade for Spry. Meetings, participants and owners are relations with joins and
  constraints. Rewriting the data layer and losing transactions across tables costs far more than
  $9 a month of a student's time. Stopping the instance gets most of the saving ($1.70 instead of
  $9.37) for free.

**Choosing a cloud: what actually decides?** When both host an API equally well, price differences
are a few dollars either way. The deciding factors are:
1. what the team already knows and runs (IAM, Terraform modules, on-call experience);
2. the **data and AI services** the product will need (BigQuery and Vertex AI against Redshift,
   Athena and Bedrock), and where the data already lives;
3. credits and enterprise agreements, which for a startup can be $100k and decide by themselves.

This course shows a fourth one: **account trust**. AWS kept this account's Bedrock quotas at 0
(Lab 6), and Google refused this account's billing signup (Lab 9). Having a second provider ready
(the provider-neutral parser in Lab 6, `gcp/` here) is cheap insurance.

## Clean up

Locally: `docker rm -f lab9-api lab9-db`. Nothing was created on Google Cloud. The Google Sheet with
the CO₂ data and the notebook copy stay in Drive for the review.
