---
title: "Your Operational Data Is Someone Else's Reference Data"
date: 2026-07-17
draft: true
tags: ["Data Architecture", "Software Architecture", "Data Products", "Integration", "PostgreSQL"]
summary: "Operational and reference are roles a dataset plays relative to a consumer, not properties of the data. Treating that role reversal as a designed mechanism — publish, refine, project, join locally — changes how systems integrate."
ShowToc: true
TocOpen: false
---

<!-- STATUS: draft R0 (2026-07-17). Review rounds pending. TODO before publication:
     - verify Dehghani Nextdata (Jan 30, 2025) article URL and exact framing
     - diagram gate: DONE 2026-07-17 — role-reversal.drawio(.png), visually verified, 1 iteration
     - re-verify Lakebase/LTAP feature status at publication date
     - set og:image/cover for social previews at publication
     - set final date; decide series taxonomy AFTER naming gate (AGP-7) -->

Somewhere in your organization, a team is building a usage service — metering
API calls, clicks, deliveries, kilowatt-hours, whatever your business counts.
To price a unit of usage, it needs to know things it does not own: the
account's remaining balance, its commercial state, its price plan. Another
team owns those facts.

The standard answer is: call their API. And for the first question — *what is
this account's balance right now?* — the API works. Then the product asks a
second question: *which accounts will exhaust their balance within a week at
their current usage trend?* That is a join between a month of usage events
(yours) and account state (theirs), across every active account. No endpoint
answers it. So you negotiate a new endpoint, or a bulk export, or you page
through the API at 2 a.m. and rebuild their dataset on your side — badly,
without a contract, without anyone admitting that this is what happened.

Each new question repeats the cycle. The provider's contract defines the
questions you are allowed to ask; anything unanticipated becomes a
cross-team negotiation. Meanwhile your decision path now includes their
deployment schedule, their rate limits, and their p99.

The root problem is not the API. It is a category error about the data: we
treat "their data" as something we may only *ask about*, never *hold*. That
error has a name worth introducing, because once you see it, you see it
everywhere.

## Every application acts on two datasets

Look inside any non-trivial operational application and you find two classes
of data with different origins and different lifecycles.

**Operational reality** is what the application itself observes and produces:
its transactions, events, measurements, state transitions, decisions. The
usage service's operational reality is the stream of usage events. This data
is born here; this application is its source of truth.

**Reference knowledge** is everything the application imports in order to make
sense of its own observations. This is broader than the classic "master data"
category. It includes taxonomies and price plans, yes — but also *current
states published by other applications* (account balance, inventory position,
device status), historical aggregates, classifications, policy tables. The
usage service cannot price a single event without reference knowledge it does
not own.

Here is the observation that carries the rest of this essay: **operational and
reference are roles, not properties.** The same dataset plays both. A balance
change is operational reality inside the account service — it happens there,
under that team's invariants. The moment it is published and lands in the
usage service's database, it is reference knowledge: trusted, imported
context for someone else's decisions. Usage events flow the other way: they
are operational for the usage service, and they become reference for billing,
forecasting, and the account service's own refill logic.

Call this **role reversal**. It is the mechanism by which independent
applications become an ecosystem instead of a call graph.

![Role reversal: two services above a shared knowledge substrate. The same dataset — account state — appears as amber operational reality inside the account service and as a green projected reference copy inside the usage service; usage and charge facts mirror the pattern in the opposite direction, each side publishing to and projecting from governed data products.](role-reversal.drawio.png)

## Standing on Helland's shoulders — and taking one more step

None of the raw ingredients here are new, and it matters to say whose they
are. In 2005, Pat Helland's ["Data on the Outside versus Data on the
Inside"](https://www.cidrdb.org/cidr2005/papers/P12.pdf) established that data
crossing a service boundary is categorically different from data inside one:
it is unlocked, uncertain, and temporally stale — "The contents of a message
are always from the past!" — and he described *reference data* with exactly
one publishing service per dataset, consumed as versioned snapshots that are
deliberately, admittedly out of date. Two decades later, that paper still
settles arguments: any data you receive from another system is from the past;
the only choice you have is how far past, and whether that bound is explicit.

What Helland described is a dichotomy and a set of publication semantics:
inside versus outside, publisher and consumers. What he did not do — what
nobody in the canonical literature quite does — is treat the *swap itself* as
the first-class design principle: the expectation that every application is
simultaneously a publisher of its operational reality and a consumer of
others', with a governed refinement step in the middle, and that
architectures should be reviewed on the completeness of that loop. That is
the step this essay argues for.

## The mechanism: publish, refine, project, join locally

Role reversal is not "replicate everything everywhere." It is a specific
four-step contract between a producing domain, a shared platform, and a
consuming domain.

**1. Publish.** The account service publishes balance and account-state
changes — through change data capture, an event stream, or batch snapshots.
Publication is part of the application's job, not an afterthought for the
analytics team.

**2. Refine and govern.** The platform normalizes the stream into a governed
product with explicit semantics. Concretely, a product definition looks like
this:

```yaml
product: account-state
owner: account-control domain
keys: [account_id]
attributes: [account_state, balance_remaining, plan_id, as_of]
freshness: "≤ 60 seconds via change feed; as_of carries observation time"
corrections: "late corrections republished under the same key; consumers upsert"
entitlement: "row-level — a consumer sees only its own tenant's accounts"
```

Note the `as_of` column and the freshness clause. Helland's "always from the
past" stops being an ambient hazard and becomes a stated, contracted property
that a reviewer can accept or reject.

**3. Project.** The usage service imports the product into its own database
as a local table — a *projection*. It is reference knowledge now: the usage
service can read, index, and join it, but the account service remains the
only writer of the underlying truth.

**4. Join locally.** And this is where the payoff lives. The week-to-exhaustion
question that had no endpoint becomes one query inside the usage service's
own boundary:

```sql
SELECT a.account_id,
       a.balance_remaining,
       sum(u.units * p.unit_price) / 30.0          AS daily_burn,
       a.balance_remaining
         / nullif(sum(u.units * p.unit_price) / 30.0, 0) AS days_left
FROM   ref_account_state a                      -- projected: owned elsewhere
JOIN   ref_price_plan    p USING (plan_id)      -- projected: owned elsewhere
JOIN   usage_event       u USING (account_id)   -- operational: owned here
WHERE  u.recorded_at >= now() - interval '30 days'
  AND  a.account_state = 'active'
GROUP  BY a.account_id, a.balance_remaining
HAVING sum(u.units * p.unit_price) > 0
ORDER  BY days_left;
```

No cross-team negotiation, no request choreography, no 2 a.m. paging job.
The next unanticipated question — segment by plan, correlate with device
type, backtest a pricing change — is another local query, not another
endpoint.

Then the loop closes. The usage service publishes its computed usage and
charge facts as its own product. Inside the account service's database they
arrive as reference knowledge feeding balance dynamics and refill signals.
Each side remains operationally independent; each side reasons over the
other's published reality. That is role reversal completing its cycle.

## What it costs, honestly

This design has real costs, and the literature has already documented them —
which is useful, because it means they are known quantities rather than
surprises.

**Storage and pipeline duplication.** Data is copied; pipelines must exist
and be operated. The systematic review of the data-mesh literature ([ACM
Computing Surveys 57(1)](https://arxiv.org/abs/2304.01062)) records data
duplication and effort duplication as documented practitioner concerns —
alongside their standard mitigations. The honest comparison is not "copies
versus no copies"; it is copies with contracts versus the repeated network
calls, bespoke endpoints, and undocumented shadow extracts that grow anyway.

**Reconciliation is now your explicit job.** A projection can disagree with
the source between refreshes. The contract's correction clause exists
precisely because late and corrected observations *will* arrive. Systems that
pretend otherwise still have the inconsistency — they just discover it in an
incident review instead of a design review.

**Not everything reverses.** Commands do not: reserving inventory, committing
a payment, any action that must be checked against the owner's *current*
invariant belongs behind the owner's API, where locks and validation live.
Role reversal is a default for *knowledge* exchange, not a replacement for
authoritative behavior. Choosing between a projection and a call — the
freshness, coupling, and reasoning-capacity trade — deserves its own
treatment, and it will get its own essay.

## Why this is surfacing now

For most of the 2010s, the industry's official position was that this loop is
two separate worlds. Data mesh — the most influential data-architecture
formulation of the decade — explicitly preserved the split: operational data
serves the running business, analytical data serves learning and reporting,
and in Zhamak Dehghani's own words, "I suggest we keep their concerns
separate." Consumption of analytical products was expected to end at training
sets and dashboards. The return path — refined knowledge flowing back into
operational decisions as a designed mechanism — was not part of the canonical
formulation, and the academic survey of its literature shows the traffic
running one way. (Dehghani herself has since reframed the intent: in a
January 2025 essay she describes the goal as a closed loop between
operational and analytical systems, while acknowledging that few
implementations got there.)

The vendors are less patient than the literature. In February 2026,
Databricks made [Lakebase](https://docs.databricks.com/aws/en/oltp/) generally
available: a managed Postgres inside the lakehouse, with governed synced
tables flowing analytics-to-operational (freshness floor of about fifteen
seconds — low-latency reads, not real-time data) and change capture flowing
back. In June, the company [declared a new category, "LTAP"](https://www.databricks.com/company/newsroom/press-releases/databricks-launches-ltap-first-lake-transactionalanalytical),
claiming to unify transactional and analytical processing on a single copy of
data. Whatever one thinks of category launches, the direction is unambiguous:
the role reversal loop is being productized.

A product feature, however, is not a principle. Lakebase gives one platform's
mechanism for the projection step. The principle is vendor-neutral and older
than any of these products: *applications publish their reality; refined,
governed knowledge returns to where decisions are made; the local
intersection of the two is where the interesting questions get answered.*
You can implement it with a lakehouse, a stream, logical replication, or a
nightly batch — the architecture review question is whether the loop exists
and is governed, not which vendor closes it.

## Three predictions

Principles should pay rent in falsifiable claims. Here are three this one
makes:

1. For cross-domain questions requiring large joins or unanticipated
   analysis, teams with governed local projections will ship answers with
   less latency and less cross-team coordination than teams composing
   synchronous APIs.
2. Applications designed as both producers and consumers of published data
   will exhibit measurably better failure isolation — a producer's outage
   degrades freshness, not availability.
3. Making freshness a contract property will move staleness disputes from
   incident reviews to design reviews, where they are cheaper.

If your experience contradicts these, that is genuinely interesting — it
means the boundary conditions are tighter than argued here, and I would like
to hear about it.

## The one-line version

Stop asking only "what API does this system expose?" Ask: *what reality does
this application own, what does it publish, whose published reality does it
project — and can it join the two locally?* When the answer to the last part
is yes, integration stops being a call graph and starts being an ecosystem.

*This is the first essay in a series on data-first architecture — how
applications inherit knowledge, act on local reality, and return what they
learn. The next one takes the trade at the center of this design — freshness,
coupling, and reasoning capacity — and makes it explicit.*
