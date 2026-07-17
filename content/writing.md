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

## On this site

Analysis and essays on data architecture, PostgreSQL, and deployment
engineering — browse the [archives](/archives/) for the full list.

- [Decoupling Compute and Storage in Postgres: The Architectural Implications of Databricks Lakebase](/posts/decoupling-compute-storage-postgres-lakebase/) — February 2026
- [Why We Are Still Getting Database Deployments Wrong in 2026: The Limits of External State Management](/posts/database-deployments-wrong-2026/) — February 2026

## On the pgmi project blog

Hands-on PostgreSQL deployment engineering, written around
[pgmi](https://github.com/AlexeyEvlampiev/pgmi) — an open-source
PostgreSQL-native deployment tool I build and maintain. Examples in these
articles are verified against live PostgreSQL instances.

- [AI agents write PostgreSQL like Python](https://vvka-141.github.io/pgmi/articles/ai-agents-write-postgresql-like-python/) — July 2026. Defensive SQL patterns for code that AI agents write: input materialization, safe casting, and why exception-driven control flow doesn't translate to the database.
- [Test PostgreSQL migrations before COMMIT](https://vvka-141.github.io/pgmi/articles/test-postgresql-migrations-before-commit/) — July 2026. Running assertions inside the deployment transaction, so a failed check rolls back the whole deployment instead of leaving it half-applied.

Elsewhere: [GitHub](https://github.com/AlexeyEvlampiev) ·
[LinkedIn](https://www.linkedin.com/in/alexey-evlampiev-09572921/)
