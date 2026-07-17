---
title: "Your Operational Data Is Someone Else's Reference Data"
date: 2026-07-17
draft: true
tags: ["Data Architecture", "Software Architecture", "Data Mesh", "Event-Driven Architecture", "Microservices", "Data Products"]
summary: "Data is operational to its owner and reference to everyone else. Governed consumer-oriented projections let services answer new cross-domain questions without synchronous API choreography."
cover:
  image: social-card.drawio.png
  alt: "The same dataset, two roles: account state as amber operational reality in the account service and as a green local projection in the usage service, exchanged through a shared knowledge substrate"
  relative: true
  hidden: true
ShowToc: true
TocOpen: false
---

*Part 1 of a series on data-first architecture. Part 2,
[Freshness Isn't the Only Axis: APIs, Projections, and Federated Queries](/posts/freshness-isnt-the-only-axis/),
turns the principle introduced here into an eight-dimension decision
instrument.*

## Abstract

Operational and reference data are not fixed categories. They are roles
relative to producer and consumer. This article defines **role reversal**: a
domain publishes governed operational facts; another domain projects them as
reference knowledge and computes them with its own data. An account-and-usage
example shows why this supports questions that per-call APIs cannot answer
without new contracts. The pattern increases reasoning capacity and reduces
request-path dependence. It also adds storage, pipeline, and reconciliation
cost. It applies only when persistence is admissible. Authoritative state
changes remain on an owner-controlled command path.

## The problem

A usage service meters calls, clicks, deliveries, or energy.
It must price usage and predict when an account will exhaust its balance.
That requires account state and price-plan data. Another team owns both.

The standard answer is an API call. It works for one question: *what is this
account's balance now?*

Now ask which accounts will exhaust their balance within a week. The answer
requires a month of usage events and the current state of every active
account. No endpoint provides it.

The usage team requests another endpoint or a bulk export. Or it pages
through the API at 2 a.m. and builds an undocumented copy. The same process
repeats for the next question.

The provider's contract limits which questions the consumer can ask. A new
question requires a new negotiation. The decision path also inherits the
provider's release schedule, rate limits, and latency.

The API is not the problem. The problem is the assumption that another
domain's data may be queried but never held. Policy sometimes requires this.
Privacy, residency, erasure, or tenant-isolation rules may prohibit a copy.
When a governed copy is admissible, per-call access should not be the only
candidate.

## Every cross-domain decision combines two roles of data

Every cross-domain decision uses two roles of data.

**Operational reality** is what the deciding application observes and
produces: transactions, events, measurements, state transitions, and
decisions. Usage events are operational reality for the usage service. It
owns them.

**Reference knowledge** is data the application uses but another domain
owns. This definition is broader than conventional reference data. It
includes code sets and taxonomies, but also account balances, inventory,
device status, historical aggregates, and policies.

Reference knowledge is consumer-relative. It may be volatile upstream. It
may also be corrected or deleted. The product contract must cover both.

The central observation is simple: **operational and reference are roles,
not properties.**

A balance change is operational inside the account service. Once published
to the usage service, it becomes reference knowledge. Usage events reverse
the roles. They are operational for usage and reference for billing,
forecasting, and refill logic.

I call this **role reversal**. It turns independent applications into an
information ecosystem rather than a call graph.

The principle has two boundaries.

First, holding a projection must be *admissible*. Some data may be queried
but not persisted, derived, or retained. Check this per product.

Second, projections do not transfer authority. State changes remain on an
owner-controlled command path unless authority is explicitly delegated.

Within these boundaries, projection should be a first-class candidate. It is
not a universal replacement for calls. A narrow, low-volume read may be
better as a call. Federation may support cross-domain reads without a
consumer copy. Architecture reviews often consider both and overlook the
projection. Part 2 compares all three.

![Role reversal: two services above a shared knowledge substrate. The same dataset — account state — appears as amber operational reality inside the account service and as a green local projection inside the usage service; usage and charge facts mirror the pattern in the opposite direction, each side publishing to and projecting from governed data products.](role-reversal.drawio.svg)

Two applications are the simplest case. A governed product may combine many
domains. The result may be a classification, aggregate, index, or model. It
need not copy any producer's table. This essay uses projections because they
show the principle directly.

## The mechanism: publish, refine, project, join locally

Role reversal does not mean replicating everything everywhere. It defines a
four-step contract between producer, platform, and consumer.

**1. Publish.** The account service publishes balance and state changes. It
may use change data capture, events, or batch snapshots. Publication is part
of the service contract.

**2. Refine and govern.** The stream becomes a governed product. Its
semantics are explicit. Ownership is split:

- The platform owns the mechanism: ingestion, normalization, transport,
  delivery, policy enforcement.
- The producer approves anything that changes meaning — units, keys, null
  semantics, temporal interpretation — exactly as it would a schema change.
- A consumer-specific derivation is a *new* product with its own owner, not
  a mutation of this one.

Without this split, the platform becomes a central team that owns every
domain's semantics. A product contract might look like this:

```yaml
product: account-state
owner: account-control domain        # owns semantics; platform enforces policy
schema: v3 (additive changes only; breaking change = new major, 90-day overlap)
keys: [account_id, valid_from]
attributes: [account_state, plan_id, balance_remaining, valid_from, valid_to, as_of]
history: "effective-dated — every state or plan change closes an interval and opens
          a new one; 13 months retained"
freshness: "≤ 60 seconds via change feed; as_of carries observation time"
corrections: "republished under the same key and interval; consumers upsert"
deletes: "tombstone records; consumers must process removals, not just upserts"
entitlement: "row-level — a consumer sees only its own tenant's accounts;
              persistence and retention permitted for billing purposes"
```

A `price-plan` product publishes effective-dated prices under the same
rules. The `history` and `freshness` clauses make two risks explicit. A
reviewer can accept or reject them.

A production contract needs more: ordering, idempotency, bootstrap, replay,
event-time semantics, and a reconciliation SLO. These are owned obligations.
They are not incident-time discoveries.

**3. Project.** The usage service imports the product as a **projection**. It
is shaped for this consumer and maintained before the decision. The usage
service can query and index it. The account service still owns the truth.

The bytes need not live in the service database. A governed materialized view
on shared storage is still a projection if it is maintained before the
decision. A query composed against source systems at decision time is
federation. Part 2 treats it as a separate candidate.

Shared storage gives local query semantics, but not a separate failure
domain. If the storage fails, the read fails. Review query locality and
failure locality separately.

**4. Join locally.** The week-to-exhaustion question now becomes one query
inside the usage boundary:

```sql
SELECT *
FROM  (
    SELECT u.account_id,
           cur.balance_remaining,
           sum(u.units * p.unit_price) / 30.0          AS daily_burn,
           cur.balance_remaining
             / nullif(sum(u.units * p.unit_price) / 30.0, 0) AS days_left
    FROM   usage_event       u                  -- operational: owned here
    JOIN   ref_account_state s                  -- projected: effective-dated
      ON   s.account_id = u.account_id
     AND   u.recorded_at >= s.valid_from
     AND   u.recorded_at <  coalesce(s.valid_to, 'infinity')
    JOIN   ref_price_plan    p                  -- projected: effective-dated
      ON   p.plan_id = s.plan_id
     AND   u.recorded_at >= p.valid_from
     AND   u.recorded_at <  coalesce(p.valid_to, 'infinity')
    JOIN   ref_account_state cur                -- current interval: the balance
      ON   cur.account_id = u.account_id
     AND   cur.valid_to IS NULL
    WHERE  u.recorded_at >= now() - interval '30 days'
      AND  s.account_state = 'active'
    GROUP  BY u.account_id, cur.balance_remaining
    HAVING sum(u.units * p.unit_price) > 0
) burn
WHERE  days_left <= 7
ORDER  BY days_left;
```

The intervals make the query correct. Each event uses the plan and price that
applied when it occurred. Events from suspended periods do not enter the burn
rate.

A current-state projection would reprice the month at today's plan. The data
would be fresher and the answer would be wrong. The query has one print
simplification: production code should divide by observed days rather than a
fixed 30-day window.

The projection also defines a boundary. It supports segmentation by plan,
historical repricing, and alerts that combine state changes with usage. It
cannot correlate burn with device type because no product supplies device
attributes.

The available fields, grain, history, semantics, and entitlements determine
which questions are possible. Part 2 calls this *reasoning capacity*.

Coordination does not disappear. Schema, meaning, entitlement, and freshness
still require agreement. A new use may require purpose or retention approval.

The gain is specific: **a question compatible with the product no longer
requires an upstream interface change or producer release.** This can be
measured.

The loop then closes. The usage service publishes usage and charge facts.
The account service consumes them as reference knowledge for balances and
refill signals.

The services are *request-path independent, asynchronously coupled, and
semantically bound by the contract*.

The consumer still depends on publication and delivery. It also depends on
the projection meeting its freshness contract. During a producer outage,
local reads continue but grow older. Independence is bounded by the maximum
age the decision accepts. It is not absolute.

## Where it does not apply, and what it costs

**Some projections are inadmissible.** Check whether the consumer may query,
persist, derive, and retain each product. If the contract prohibits a use,
the projection is not a candidate.

**Projection does not transfer authority.** Inventory reservations and
payments must satisfy the owner's current invariant. They stay on an
owner-controlled command path unless authority is explicitly delegated.
Role reversal applies to knowledge, not authority.

**Narrow reads are cheaper as calls.** A projection is an operated pipeline.
For one current plan lookup at signup, a call costs less. Projection earns
its cost when questions fan out, require joins, or change often.

**Federation is a real alternative.** It queries owner-controlled sources at
decision time and keeps no consumer copy. Its freshness, coupling, and
failure properties differ from a projection. They are not always worse.

**Storage and pipeline duplication.** Projections copy data and require
pipelines. A systematic review of data-mesh literature ([ACM Computing
Surveys 57(1)](https://arxiv.org/abs/2304.01062)) identifies both data and
effort duplication as practitioner concerns. Compare these costs with calls,
bespoke endpoints, and shadow extracts. Do not compare copies with an
imaginary zero-cost alternative.

**Reconciliation becomes explicit.** A projection can differ from its source
between refreshes. Late changes, corrections, and deletions will arrive. The
contract must define how consumers process them.

**The mechanism assumes a platform.** Someone must provide ingestion,
replay, tombstones, and entitlement enforcement. Without shared capability,
each consumer builds its own pipeline.

Use this decision rule:

- **Reach for a projection** when questions have high fan-out or need joins,
  evolve unpredictably, tolerate bounded staleness, and must survive the
  provider's outages.
- **Reach for an owner-controlled command path** when the operation changes
  authoritative state, must validate against a current invariant, or cannot
  tolerate stale authorization or availability information.

The same data may use several access modes. Screen from a projection. Explore
in an analytical store. Commit through the owner's command path. Each mode
serves a different decision.

## The role-reversal review

A principle must work in a review. Paste this block into the ADR:

```text
Decision this integration serves:
Operational reality owned here:
External knowledge required:
For each external product:
    Semantic owner:
    Admissibility — query / persist / derive / retain:
    Grain and history depth:
    Freshness and completeness contract:
    Corrections, deletions, replay:
    Query locality / failure locality:
Authoritative actions that must return to the owner:
Knowledge this application publishes in return:
```

Reviews often omit the last line. That line makes the relationship
reciprocal. Part 2 adds a per-candidate ADR template. This card is enough to
expose a missing part of the loop.

## Measuring it

The central claim is measurable: **producer-side changes per new cross-domain
question.** Count endpoint additions, export requests, and producer releases
before and after governed projections. Compare one team over time. A
cross-team comparison will be distorted by platform maturity.

You can also review the last ten cross-domain questions. Record the source of
each answer: endpoint, export, undocumented extract, or local join. Then count
the required producer changes. An undocumented extract is an unmanaged
projection. Role reversal already exists; the contract does not.

## Prior work

The ingredients are established. The synthesis is the contribution.

**The temporal semantics** come from Pat Helland. ["Data on the Outside
versus Data on the Inside"](https://www.cidrdb.org/cidr2005/papers/P12.pdf)
(CIDR 2005) distinguishes data inside a service from data outside it. Outside
data is unlocked, uncertain, and stale. Helland also describes reference data
with one publisher and consumers that accept versioned, outdated snapshots.

**The movement** is event-carried state transfer. Martin Fowler's [2017
taxonomy](https://martinfowler.com/articles/201701-event-driven.html)
describes a recipient keeping a copy so it can work without calling the
source system.

**The read model** is CQRS: derived state shaped for queries and separated
from the write path. **The ownership model** comes from data products.

The missing obligation is *reciprocity*. Each application publishes its own
reality and consumes reality published by others. "Operational" and
"reference" name the two ends of the exchange.

Event-carried state transfer explains movement. CQRS explains the read model.
Helland explains time. Data products explain ownership. Role reversal puts
them into one reviewable loop.

## Why now

Data mesh recognized the return path but scoped its architecture around the
analytical plane. Zhamak Dehghani's
[2020 formulation](https://martinfowler.com/articles/data-mesh-principles.html)
names the flow from operational to analytical systems and back. It then
recommends keeping the concerns separate "for now." Many implementations
therefore stop at lakes, models, and dashboards.

In [January
2025](https://www.nextdata.com/our-pov/the-data-mesh-challenge-how-to-close-the-gap-between-inception-and-operation-at-scale),
Dehghani described data mesh as a closed loop between operational and
analytical systems. She also said that very few organizations had implemented
it. The intent was clear. Operational re-entry remained underspecified.

Products now implement parts of the mechanism. Databricks
[Lakebase](https://docs.databricks.com/aws/en/oltp/) places managed Postgres
inside the lakehouse. Its public-preview [change data
feed](https://docs.databricks.com/aws/en/oltp/projects/lakebase-cdf) captures
inserts, updates, and deletes from the write-ahead log into governed Delta
tables. Delta also provides a [change data
feed](https://docs.delta.io/delta-change-data-feed/) between table versions.

These feeds solve row-level change capture. They do not define semantic
ownership, effective time, entitlement, retention, completeness, correction,
or the consumer projection. **A feed moves changes. A product contract makes
them usable as knowledge.**

A product feature is not the principle. The principle is vendor-neutral:
*applications publish their reality; governed knowledge returns to the
decision boundary; the two are computed together.* A lakehouse, stream,
logical replication, or nightly batch can implement it. Review the loop and
its governance, not the vendor.

## Conclusion

Role reversal moves part of integration from request time to publication
time. The producer publishes governed reality. The consumer projects the
facts it needs and computes them with local reality. A new question that fits
the product contract no longer requires a new provider interface or release.

This does not eliminate calls. Use an owner-controlled command path for
authoritative state changes. Use calls for narrow current-state reads when a
projection costs more than it returns. Use federation when query-time access
is acceptable and a consumer copy is not.

The architecture review therefore needs four questions: What reality does
the application own? What does it publish? Whose reality does it project?
Can it compute the two together? These questions turn a call graph into a
reviewable information ecosystem.

---

*This is Part 1 of a series on data-first architecture. [Part
2](/posts/freshness-isnt-the-only-axis/) defines an eight-dimension decision
instrument. Later essays cover composite products, models as executable
knowledge, and the return of decisions and outcomes.*

Where did a projection help? Where did its staleness cost more than the API
dependency? I am interested in counterexamples.
