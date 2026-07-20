---
title: "Decoupling Compute and Storage in Postgres: The Architectural Implications of Databricks Lakebase"
date: 2026-02-26
draft: false
tags: ["PostgreSQL", "Databricks", "Serverless", "Database Architecture", "Cloud"]
summary: "A vendor-neutral analysis of how Databricks Lakebase and the broader serverless PostgreSQL convergence fundamentally change what we can assume about database deployments."
cover:
  image: lakebase-ecosystem-integration-flow.drawio.png
  alt: "Databricks Lakebase ecosystem integration: bidirectional data flow between PostgreSQL, Unity Catalog, and Delta Lake"
  relative: true
  hiddenInList: true
  hiddenInSingle: true
ShowToc: true
TocOpen: false
---

On February 3, 2026, Databricks announced the [general availability of Lakebase on AWS](https://www.databricks.com/blog/databricks-lakebase-generally-available) — a serverless PostgreSQL database built on Neon's compute-storage separation architecture, integrated with Unity Catalog governance and the Databricks analytics platform. Azure followed in beta. Thousands of companies are already running production workloads.

This is not a minor product launch. Databricks — valued at $134 billion after its December 2025 Series L, with revenue [past a $5.4 billion annual run rate](https://www.databricks.com/company/newsroom/press-releases/databricks-grows-65-yoy-surpasses-5-4-billion-revenue-run-rate) in January 2026 — is making a structural bet that PostgreSQL is the operational counterpart to the lakehouse. Snowflake made a parallel move, [acquiring Crunchy Data for ~$250 million](https://www.cnbc.com/2025/06/02/snowflake-to-buy-crunchy-data-250-million.html). The two largest analytical platforms on earth are converging on the same conclusion: operational data belongs in PostgreSQL.

The architectural implications of Lakebase extend far beyond the Databricks ecosystem. What Lakebase represents — and what it shares with Neon, Aurora Serverless, AlloyDB, and now Microsoft's Azure HorizonDB — is a fundamental rethinking of what a PostgreSQL database *is*. Compute is no longer a server. It is a process that appears, executes, and disappears. Storage is no longer a local filesystem. It is a distributed, durable layer that outlives any single compute instance.

For anyone who deploys to PostgreSQL, this changes the rules.

## What Lakebase Actually Is

Lakebase is built on [Neon's open-source architecture](https://neon.com/docs/introduction/architecture-overview), which Databricks [acquired for approximately $1 billion](https://www.databricks.com/company/newsroom/press-releases/databricks-agrees-acquire-neon-help-developers-deliver-ai-systems) in May 2025. The core innovation is splitting PostgreSQL into two fully independent layers connected only over the network: compute streams its Write-Ahead Log (WAL) down to storage and requests data pages back from it, and never touches durable storage directly.

![Lakebase compute-storage separation architecture: stateless PostgreSQL compute streams WAL to a distributed storage layer of safekeepers, pageservers, and S3](lakebase-compute-storage-architecture.drawio.svg)

**The compute layer** runs standard PostgreSQL — version 16, 17, or 18, with [more than 50 supported extensions](https://docs.databricks.com/aws/en/oltp/projects/compatibility) including pgvector, PostGIS, PL/pgSQL, and pg_stat_statements. From the perspective of a connected client, this is a PostgreSQL database. The wire protocol is standard: psql, pgAdmin, pgx, and SQLAlchemy connect and query normally. What does *not* carry over is anything that reaches past the wire protocol — superuser access, tablespaces, native logical replication, direct server-log access — so tools that depend on those need adaptation.

What changes is that this compute process owns no durable state. Instead of flushing WAL to a local filesystem, it streams WAL records over the network to the storage layer.

**The storage layer** has three tiers:

- **Safekeepers** receive WAL from compute and store it durably using a Paxos-based quorum consensus. A transaction is committed once a majority of safekeepers acknowledge the WAL record. This provides the durability guarantee.

- **Pageservers** materialize data pages by combining previously stored base pages with committed WAL records. When compute needs a page it doesn't have cached locally, it requests it from the pageserver, which reconstructs it on demand.

- **Object storage (S3)** is the ultimate source of truth. Pageservers periodically upload materialized data to S3 for long-term durability. Compute never reads S3 directly — the pageserver mediates every remote read, fetching from object storage on a cache miss and serving warm pages from its own tiers otherwise.

This architecture means WAL is how compute *writes* to storage, and a page-service request is how it *reads* — two network interfaces where there used to be a local disk. Once both cross a network rather than a filesystem, compute becomes stateless and replaceable.

**Lakebase adds three capabilities on top of Neon's foundation:**

Unity Catalog registration brings the operational database under lakehouse governance: the Postgres database surfaces as a read-only catalog with audit logging and lineage tracking, and Unity Catalog policies — row-level filters, column masking — govern access to that data through Databricks query surfaces. One boundary worth knowing: direct Postgres connections are still governed by Postgres roles, not Unity Catalog. The two systems share one catalog and one audit trail; they are aligned, not merged.

The [Lakebase change data feed](https://docs.databricks.com/aws/en/oltp/projects/lakebase-cdf) (in public preview as of mid-2026), built on the `wal2delta` extension from the [Mooncake Labs acquisition](https://www.databricks.com/blog/mooncake-labs-joins-databricks-accelerate-vision-lakebase) (October 2025), streams committed changes from Lakebase into Unity Catalog managed Delta tables in roughly 15-second batches. It does not eliminate ETL so much as remove the need to *operate* a separate CDC stack — the pipeline is the feed.

Synced Tables provide the reverse direction — Unity Catalog gold-layer tables replicated into Lakebase as read-only PostgreSQL tables, with configurable refresh modes from snapshot to continuous streaming.

![Databricks Lakebase ecosystem integration: Synced Tables replicate gold-layer data into Lakebase, while the Lakebase change data feed streams changes out to Unity Catalog managed Delta tables in ~15-second batches, with Unity Catalog governance spanning both sides](lakebase-ecosystem-integration-flow.drawio.svg)

## Scale to Zero and the Death of Assumed State

Lakebase Autoscaling supports true [scale-to-zero](https://docs.databricks.com/aws/en/oltp/projects/scale-to-zero). After a configurable period of inactivity — anywhere from 60 seconds to 7 days; the default is 24 hours — the compute layer suspends entirely. Reactivation takes a few hundred milliseconds. Data remains safely in object storage.

This is where the architectural implications become concrete. When compute suspends and reactivates, every form of session state is destroyed:

- **Temporary tables**: gone.
- **Prepared statements**: gone.
- **Advisory locks**: gone — the connection that held them no longer exists.
- **Session variables** (`SET` parameters): gone.
- **In-memory statistics and buffer cache**: cold.
- **Active transactions**: aborted.

The data is safe. The schema is intact. But the *execution environment* — everything that existed in the compute process's memory — has been wiped.

This is not a Lakebase-specific limitation. It is a structural consequence of disaggregating compute from storage. Neon (standalone) behaves identically — default suspension after five minutes of inactivity, ~500ms cold start. [Aurora Serverless v2](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.how-it-works.html) exhibits the same pattern at a larger time scale: suspension after 5 minutes to 24 hours of inactivity, with cold start times of approximately 15 seconds (rising to 30+ seconds after extended suspension). Even [AlloyDB](https://docs.cloud.google.com/alloydb/docs/overview), which does not scale to zero, disaggregates storage in a way that makes read replicas share data without owning it.

## The Convergence

Lakebase is not an isolated product decision. It is [one instance of an industry-wide architectural convergence](https://www.infoq.com/news/2026/02/databricks-lakebase-postgresql/).

There are really two axes here, and it is worth keeping them apart. One is **disaggregation**: whether storage is separated from compute so that a compute node owns no durable state. The other is **ephemerality**: whether the compute — and therefore the *session* — is transient. Disaggregation makes compute *replaceable*; it does not by itself make sessions disappear. The platforms below have converged on the first axis while spreading across the second.

| Platform | Compute Model | Storage Model | Session Scope | Cold Start |
|:---------|:-------------|:-------------|:-------------|:----------|
| **Lakebase** (Databricks) | Stateless Postgres (Neon) | Safekeepers + Pageserver + S3 | Suspends after idle (60 s – 7 d, default 24 h) | ~500ms |
| **Neon** (standalone) | Stateless Postgres | Same architecture (Neon origin) | Suspends after idle (5 min) | ~500ms |
| **Aurora Serverless v2** (AWS) | ACU-based Postgres | Aurora distributed storage | Pauses after idle, only with no open connections (5 min – 24 h) | ~15-30s |
| **AlloyDB** (Google Cloud) | Primary + read pool VMs | Log Storage + LPS + Block Storage | Provisioned (always-on) | N/A |
| **HorizonDB** (Microsoft Azure) | Stateless scale-out Postgres | Durable WAL service + sharded storage + Blob | Provisioned (always-on) | N/A |
| **Aurora DSQL** (AWS) | Query processor per connection | Distributed journal | Per-connection | Serverless |

Every platform here separates compute from storage at the WAL boundary — that is the settled part. Where they differ is on the second axis. Neon and Lakebase pursue ephemerality hardest: sub-second cold starts and true scale-to-zero, so an idle database has *no* running session. Aurora Serverless is more conservative and, crucially, only pauses when there are no open connections. AlloyDB and Microsoft's [Azure HorizonDB](https://learn.microsoft.com/en-us/azure/horizondb/overview) — unveiled at Ignite in late 2025 and in [public preview since mid-2026](https://learn.microsoft.com/en-us/azure/horizondb/release-notes/release-notes) — disaggregate storage fully but keep compute provisioned; they demonstrate that separation makes compute replaceable without making it transient. HorizonDB is worth naming precisely: its writes flow through a durable WAL service, but storage also includes a sharded data fleet and Azure Blob durability, and it does not scale to zero. [Aurora DSQL](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/working-with-postgresql-compatibility-migration-guide.html) sits at its own corner — a dedicated query processor per connection, no shared session pool — so its compute is serverless yet still connection-scoped.

The trajectory on the first axis is clear: PostgreSQL compute is being separated from storage everywhere. Ephemerality is the *additional* property some of these platforms layer on top — and it is the one that changes what deployment tooling can assume.

## What This Breaks

Traditional database deployment tools were designed for a world where the database server is always running, a connection is available immediately, and session state persists for the duration of the migration.

Transient sessions — from scale-to-zero, failover, restarts, or transaction pooling — invalidate all three. Note the trigger is the transient *session*, not disaggregation itself: an always-on HorizonDB or AlloyDB breaks none of these assumptions, and even scale-to-zero platforms suspend only when idle. The failure modes below appear when a session ends underneath an active deployment.

**The database may not be running when the pipeline connects.** A CI/CD runner that triggers a deployment against an idle, suspended Lakebase or Neon instance may face a 500ms wake-up delay. Against a paused Aurora Serverless cluster, 15-30 seconds. Driver and pooler connection timeouts are commonly configured in the 5-10 second range — shorter than Aurora's cold start; AWS itself recommends raising client timeouts above 15 seconds for auto-paused clusters. Set them too low and the migration tool gives up before the database finishes waking.

**Session state may not survive.** Migration tools that acquire advisory locks to prevent concurrent deployments (`SELECT pg_advisory_lock(...)`) rely on the lock persisting for the duration of the migration session. If the underlying connection is recycled by a pooler or interrupted by a compute scaling event, the lock disappears silently. Another deployment instance may proceed concurrently, corrupting state.

**Connection poolers break session assumptions — independently of scale-to-zero.** Neon includes built-in PgBouncer in transaction mode. Transaction-mode pooling returns the connection to the pool after each transaction, so `SET` parameters, temporary tables, and prepared statements do not persist between transactions. A migration tool that sets `search_path` once and creates temporary tracking state across several transactions will silently see it vanish. This is a pooling hazard, not a suspension one — and the two can even pull in opposite directions: an associated RDS Proxy keeps a connection open to Aurora Serverless, which *prevents* it from auto-pausing.

**Feature availability varies wildly.** Aurora DSQL claims PostgreSQL compatibility but still lacks PL/pgSQL, temporary tables, triggers, and foreign keys (it has been closing gaps fast — [JSONB landed in June 2026](https://docs.aws.amazon.com/aurora-dsql/latest/userguide/release-notes.html), so a compatibility list written six months ago is already stale). It limits transactions to 3,000 modified rows and one DDL statement each. A migration script that creates a table and inserts seed data in the same transaction will fail; any tool that generates `DO $$ ... $$` blocks is incompatible. The PostgreSQL on the other side of the wire is not always the PostgreSQL you expect — and the target list is moving, so pin your assumptions to today's docs, not last release's.

## The Deployment Question

Lakebase itself provides some answers. Copy-on-write branching enables CI/CD patterns: create a branch, deploy schema changes, validate, merge back. Branches can be given a TTL — from one hour up to 30 days — so a CI branch cleans itself up after the pipeline completes. Synced Tables handle the analytical-to-operational data flow. Moonlink handles the reverse.

But branching does not solve the deployment orchestration problem — it replicates it. Each branch is a separate PostgreSQL endpoint that may or may not have active compute. The migration tool still needs to connect, manage state, and execute changes. With up to 10 unarchived branches per project (500 in total), the deployment target is no longer a single database but a tree of ephemeral instances.

The deeper question is architectural. If the session can end mid-deployment, what may deployment logic safely depend on?

The tempting answer — "put everything in one session so it's atomic" — is too strong, in two ways. First, a single session does *not* guarantee atomicity: the operations that matter most under load, `CREATE INDEX CONCURRENTLY` and `VACUUM`, cannot run inside a transaction block at all, so a real migration spans multiple commits by necessity. Second, durable coordination state is not the liability it is sometimes made out to be. A migration-history table lives in the same durable storage as your application tables; it survives scale-to-zero exactly as they do. The problem was never that state is persisted — it is that state is persisted in *two* places, an external binary *and* the database, which can then diverge when the binary crashes ([a failure mode I explored separately](/posts/database-deployments-wrong-2026/)).

What genuinely does not survive a suspend-and-resume is anything scoped to the *connection*: advisory locks, temporary tables, `SET` parameters, an open transaction. So the property to design for is narrower and more precise than "one session." Deployment tooling for these platforms should:

- **Tolerate cold starts and reconnects** — generous connection timeouts, retry with backoff, no assumption the endpoint is warm.
- **Not depend on session state surviving a reconnect** — no cross-transaction advisory locks or temp-table coordination; if a lock is needed, back it with a durable row, not `pg_advisory_lock`.
- **Persist enough durable coordination state to resume safely** — and make each step idempotent and resumable, so re-running after an interrupted attempt converges rather than corrupts.

PostgreSQL supplies the raw materials for exactly this: transactional DDL for the steps that *can* be atomic, savepoints for nested isolation within a transaction, system catalogs for querying ground-truth state instead of trusting an external changelog, and durable tables for coordination that has to outlive a connection. All of it lives in the storage layer, so all of it survives the compute going away.

As Data Platform Architects, we have spent years assuming the database is a persistent server holding a stable session. Disaggregation is removing the second half of that assumption — the session, not the data. The data is as durable as ever; it is the connection that has become disposable. Deployment logic needs to know which is which.
