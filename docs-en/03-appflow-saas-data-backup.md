# Amazon AppFlow & Backing Up SaaS Data

Vietnamese version: [`docs/03-Amazon-AppFlow-Backup-du-lieu-SaaS.md`](../docs/03-Amazon-AppFlow-Backup-du-lieu-SaaS.md)

---

## 1. What AppFlow is

A managed service for moving data between SaaS applications and AWS. Salesforce,
Zendesk, ServiceNow, Slack and similar on one side; S3, Redshift and Snowflake
(via S3) on the other.

Flows are configured in the console — source, destination, field mapping,
filters, schedule — with little or no code. The typical motivation is
consolidating data into AWS for analytics, machine learning, long-term
retention or compliance.

**SaaS data** here means the records living inside those applications: leads,
tickets, issues, merge requests, users, events, logs.

---

## 2. What "backup" does and does not mean here

AppFlow exports data. That gives you real benefits:

- **Ownership** — a copy under your control, not the vendor's.
- **Analytics** — join SaaS data with other sources in a data lake.
- **Compliance** — an audit trail retained for years.
- **Partial recovery** — restore specific records after an accident.

But it is worth being precise about the limits, because "backup" invites the
wrong expectation:

> AppFlow is **not** a full backup and restore tool in the sense a database
> backup is.

Specifically, it does not give you:

- **Point-in-time recovery** of an entire application.
- **Application logic** — workflows, automation rules, permissions, custom
  fields and layouts are configuration, not records, and AppFlow does not
  capture them.
- **Referential integrity on restore.** Some connectors write back to the SaaS
  application, so you can re-import records, but you have to design the
  recovery yourself: field mapping, ID reconciliation, conflict handling,
  ordering between related objects.

The honest framing: AppFlow gives you a **data copy**, not a **system restore**.
For many compliance requirements a data copy is exactly what is being asked
for. For "the vendor lost our tenant, make us whole", it is not.

---

## 3. Output formats

Writing to **S3**, you can choose:

- **CSV** — easy to inspect, weak typing.
- **JSON** — preserves nesting.
- **Parquet** — columnar, compressed, the right default for anything that will
  be queried at scale by Athena, Redshift Spectrum or Spark.

You also control how records are split across files and how folders are laid
out — commonly partitioned by date.

Writing to **Redshift** loads into tables, not files. Writing to another SaaS
application calls its API; there is no intermediate file you can keep.

---

## 4. Worked example: backing up GitLab to S3

### 4.1. The connector problem

AppFlow has **no native GitLab connector**. That constraint shapes everything
else, so establish it first.

Two viable approaches:

1. **Lambda + GitLab API + S3.** A scheduled function calls the GitLab REST
   API, paginates, writes to S3. Straightforward, well understood, easy to
   debug.
2. **An AppFlow custom connector** wrapping the GitLab API. More work up front,
   worth it only if you already run AppFlow and want GitLab managed through the
   same interface, with the same scheduling and monitoring.

> "Use AppFlow to back up GitLab" always means one of these underneath. AppFlow
> cannot call an arbitrary API with just a token — a connector has to exist
> first.

For most teams, option 1 is the right answer and option 2 is only justified by
an existing investment in AppFlow.

### 4.2. What to extract

Projects, issues, merge requests, commit metadata, users and members.

Note what is *not* on that list: **repository contents**. Git data is not
covered by the API-export approach and needs a different mechanism entirely
(mirroring, or GitLab's own backup tooling). Saying this out loud early avoids
a bad surprise later.

### 4.3. Example records

**Issues (JSON):**

```json
[
  {
    "id": 12345,
    "iid": 7,
    "project_id": 42,
    "title": "API endpoint returns 500",
    "state": "opened",
    "labels": ["bug", "high-priority"],
    "assignee": { "id": 101, "username": "jdoe" },
    "created_at": "2026-04-15T10:23:45Z",
    "web_url": "https://gitlab.example.com/group/project/-/issues/7"
  }
]
```

**Merge requests (CSV):**

```csv
id,iid,project_id,title,state,author_username,created_at,merged_at
9876,15,42,"Add user audit log","merged","alice","2026-04-10T09:00:00Z","2026-04-11T14:20:30Z"
9877,16,42,"Refactor auth module","opened","jdoe","2026-04-12T07:15:00Z",
```

### 4.4. S3 layout

Simple, date-based:

```text
s3://<bucket>/gitlab/issues/2026-04-16/issues.json
s3://<bucket>/gitlab/merge_requests/2026-04-16/merge_requests.csv
```

Hive-style partitioning, if you intend to query with Athena:

```text
gitlab/issues/year=2026/month=04/day=16/issues.parquet
```

Choose the second if there is any chance of querying later. Athena reads
`year=`/`month=`/`day=` partitions natively and will scan far less data — which
is what you actually pay for. Reorganising an S3 layout after the fact is
tedious.

---

## 5. Summary

**AppFlow** is a data integration service for pulling SaaS data into AWS for
analytics. It produces copies and snapshots, not application-level restores.

**For GitLab**, there is no native connector, so you either write a Lambda
against the GitLab API or build a custom connector. Store the output as JSON,
CSV or Parquet in S3, partitioned if you plan to query it — and remember that
repository contents need a separate strategy.

---

## Practice

### Read

| Page title | URL |
|------------|-----|
| *What is Amazon AppFlow?* | https://docs.aws.amazon.com/appflow/latest/userguide/what-is-appflow.html |
| *Supported source and destination applications* | https://docs.aws.amazon.com/appflow/latest/userguide/app-specific.html |
| *Custom connectors* | https://docs.aws.amazon.com/appflow/latest/userguide/custom-connectors.html |

Skim the supported-applications page rather than reading it. The skill being
practised is scanning a long reference page for one fact — "is GitLab on this
list?" — which is most of what real documentation reading actually is.

### Key phrases

This document is about **stating limitations**, which is delicate. You need to
be clear that something will not work without sounding negative or
obstructive — a genuinely useful register at work.

| Phrase | Used like this |
|--------|----------------|
| **to be precise about** | "It's worth being precise about what 'backup' means here." |
| **to invite the wrong expectation** | "Calling it a backup invites the wrong expectation." |
| **in the sense that** | "It's not a backup tool in the sense a database backup is." |
| **to fall outside the scope of** | "Repository contents fall outside the scope of this approach." |
| **to be covered by** | "Custom fields aren't covered by the export." |
| **to shape everything else** | "That constraint shapes everything else." |
| **to establish something first** | "Establish that constraint first." |
| **to be justified by** | "Option 2 is only justified by an existing AppFlow investment." |
| **up front** | "More work up front, less later." |
| **to reconcile** | "You have to reconcile IDs on restore." |
| **to make someone whole** | "'The vendor lost our tenant, make us whole' — that's not this." |
| **the honest framing** | "The honest framing is: a data copy, not a system restore." |
| **to avoid a bad surprise** | "Saying it early avoids a bad surprise later." |
| **after the fact** | "Reorganising an S3 layout after the fact is tedious." |
| **to be tedious** | "It's tedious rather than hard." |

The pattern **"X is not Y in the sense that Z is"** is worth memorising
outright. It lets you deny something precisely instead of flatly, and it is the
difference between sounding careful and sounding unhelpful.

Also note **"up front"** (two words, adverbial: *more work up front*) versus
**"upfront"** (one word, adjective: *an upfront cost*).

### Write

Write **5–8 sentences**, using **at least 3** phrases from the table.

Prompt: *Your compliance team asks whether AppFlow can "back up Salesforce so
we can restore it if something goes wrong." Write your answer.*

The difficulty is tone. Say no to the literal question, yes to the underlying
need, and propose what would actually meet it. Do not simply list what AppFlow
cannot do — that is accurate and useless.

### Speak

**Drill A — 2-minute explainer.** Explain **what AppFlow is and what it is not**
to a project manager who has heard it will "solve our backup problem."

1. What it genuinely does well
2. How it works
3. Where the expectation is wrong — and be specific: workflows, permissions,
   point-in-time
4. What you would recommend instead

Watch your tone. The PM is not wrong to ask; they were told something
inaccurate. Practise correcting the premise without making them defensive —
"that's close, but the important distinction is…" is a useful opener.

**Drill B — elimination.**

> A company must retain three years of Zendesk ticket data for compliance
> auditing, queryable on demand, at the lowest cost. Which approach fits best?
>
> A. AppFlow scheduled to S3 as Parquet, queried with Athena
> B. AppFlow to Redshift, kept in a provisioned cluster
> C. A Lambda calling the Zendesk API, writing JSON to S3 Glacier Deep Archive
> D. Zendesk's own export, downloaded monthly and stored on-premises

Say out loud why each wrong option fails. Two words in the question are doing
the work — *queryable on demand* and *lowest cost*. Name them before you
evaluate, and say which option each one rules out.

Model answers: [`practice/elimination-drills.md`](practice/elimination-drills.md)
