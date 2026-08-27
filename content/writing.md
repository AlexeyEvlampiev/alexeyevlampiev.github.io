---
title: "Writing"
layout: "single"
ShowToc: false
ShowBreadCrumbs: false
summary: "Everything I've published, in one place — essays on this site and articles on the pgmi project blog."
description: "A complete index of Alexey Evlampiev's writing on PostgreSQL, data architecture, deployment engineering, and AI systems."
---

Everything I've published, in one place. Posts on this site appear in the
[archives](/archives/) and in the [RSS feed](/index.xml); the rest lives on
project sites and is indexed here so nothing gets lost between platforms.

Most of it argues one thing from different directions:
[a decision belongs where its authority already lives](/locality-of-authority/).

## Essays — data and systems architecture

On this site. Browse the [archives](/archives/) for the full list.

- [The Lakehouse Publishes. Applications Decide Locally.](/posts/lakehouse-publishes-applications-decide-locally/)
  — August 2026. A shared lakehouse masters and publishes governed context
  asynchronously; each application accepts the subset it needs into its own
  boundary and decides locally against operational state and accepted context
  together. An upstream outage becomes bounded freshness lag instead of an
  outage of your own.
- [Operational and Analytical Are Not Separate Architectures](/posts/operational-and-analytical-are-not-separate-architectures/)
  — July 2026. The operational/analytical split organizes teams but
  misdescribes the system: applications observe and act, a shared substrate
  remembers and synthesizes, and knowledge returns to change the next decision.
  The complete unit of architecture is the information ecosystem.
- [Decoupling Compute and Storage in Postgres: The Architectural Implications of Databricks Lakebase](/posts/decoupling-compute-storage-postgres-lakebase/)
  — February 2026. What compute–storage separation changes about what a
  PostgreSQL database *is*, and what that means for anyone who deploys to one.
- [Why We Are Still Getting Database Deployments Wrong in 2026: The Limits of External State Management](/posts/database-deployments-wrong-2026/)
  — February 2026. Why a migration tool standing outside the database cannot
  hold an accurate model of what happened inside it, and what the alternative
  looks like.

## Articles — PostgreSQL deployment engineering

On the [pgmi project blog](https://vvka-141.github.io/pgmi/articles/), written
around [pgmi](https://github.com/AlexeyEvlampiev/pgmi), an open-source
PostgreSQL-native execution fabric I build and maintain. Every example is
verified against a live PostgreSQL instance.

- [Your Deployment Is a PostgreSQL Program](https://vvka-141.github.io/pgmi/articles/deployment-is-a-postgresql-program/)
  — August 2026. Every migration tool is a program that executes your SQL.
  Invert the control flow and deployment policy becomes SQL the project owns,
  while the tool keeps only a narrow execution mechanism.
- [Scenario-Tree Testing in PostgreSQL: Every Authored Branch, Shared History, Before COMMIT](https://vvka-141.github.io/pgmi/articles/test-every-branch-before-commit/)
  — August 2026. Express branching business scenarios as a directory tree and
  walk it with savepoints, so each branch inherits its history instead of
  rebuilding it — and let the walk decide whether the deployment commits.
- [The Request Becomes a Transaction](https://vvka-141.github.io/pgmi/articles/request-becomes-a-transaction/)
  — August 2026. A transactional API has two halves. Keep the network edge at
  the edge; give the transactional operation to PostgreSQL, where its authority
  already lives. Every declared outcome then becomes provable in the same
  transaction.
- [Your ALTER TABLE Is Fast. The Queue Behind It Is Not.](https://vvka-141.github.io/pgmi/articles/lock-queue-fast-is-not-safe/)
  — August 2026. How a PostgreSQL lock queue turns a six-millisecond schema
  change into a sixteen-second outage, and the two moves that bound the damage.
- [Your Transaction Boundary Belongs in the Program, Not the Filename](https://vvka-141.github.io/pgmi/articles/transaction-boundary-in-the-program/)
  — August 2026. A phased schema change spans transactional and
  non-transactional work. Most tools express that as metadata; it belongs in
  the SQL program itself.
- [Your Migration Numbers Are a Distributed Counter Without Coordination](https://vvka-141.github.io/pgmi/articles/migration-numbers-distributed-counter/)
  — July 2026. What migration-number collisions reveal about identity,
  ordering, and where the resulting invariants get enforced.
- [From Seed Scripts to Desired-State Reference Data in PostgreSQL](https://vvka-141.github.io/pgmi/articles/desired-state-reference-data-postgresql/)
  — July 2026. Version the catalog that should exist, not the procedure that
  inserts it — and validate, diff, load, and reconcile it inside one
  transaction.
- [AI agents write PostgreSQL like Python](https://vvka-141.github.io/pgmi/articles/ai-agents-write-postgresql-like-python/)
  — July 2026. Field notes from a production review of an AI-written PostgreSQL
  backend: exceptions as control flow, casts that turn bad requests into 500s,
  and the handler discipline that contains them.
- [Test PostgreSQL migrations before COMMIT](https://vvka-141.github.io/pgmi/articles/test-postgresql-migrations-before-commit/)
  — July 2026. PostgreSQL's transactional DDL lets you assert against the
  migrated schema inside the deployment transaction, so a failing check means
  the deployment never happened.

Elsewhere: [GitHub](https://github.com/AlexeyEvlampiev) ·
[LinkedIn](https://www.linkedin.com/in/alexey-evlampiev-09572921/)
