---
title: "Your Operational Data Is Someone Else's Reference Data"
date: 2026-07-17
draft: true
tags: ["Data Architecture", "Software Architecture", "Data Mesh", "Event-Driven Architecture", "Microservices", "Data Products"]
summary: "Data is operational to its owner and reference to everyone else. Governed local projections let services answer new cross-domain questions without synchronous API choreography."
cover:
  image: social-card.drawio.png
  alt: "The same dataset, two roles: account state as amber operational reality in the account service and as a green local projection in the usage service, exchanged through a shared knowledge substrate"
  hidden: true
ShowToc: true
TocOpen: false
---

<!-- STATUS: draft R1 (2026-07-17) — second-opinion review applied; all its factual
     claims verified against primary sources (Fowler ECST, Dehghani 2020 "and back",
     LTAP "coming soon", Nextdata URL + quotes). TODO before publication:
     - re-verify Lakebase/LTAP feature status at publication date
     - social card DONE 2026-07-17 (social-card.drawio.png 1198x628, cover.hidden,
       visually verified at thumbnail scale)
     - set final date + draft: false at publication; decide series taxonomy AFTER
       naming gate (AGP-7)
     - diagram gate: DONE — role-reversal.drawio(.png), visually verified -->

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

**Reference knowledge** is everything the application imports in order to
make sense of its own observations. I am using the term deliberately more
broadly than the data-management tradition does: conventional "reference
data" means controlled code sets, taxonomies, and classifications; here,
reference knowledge means *any data a decision references but someone else
owns* — including current states published by other applications (account
balance, inventory position, device status), historical aggregates, and
policy tables. The usage service cannot price a single event without
reference knowledge it does not own.

Here is the observation that carries the rest of this essay: **operational
and reference are roles, not properties.** The same dataset plays both. A
balance change is operational reality inside the account service — it happens
there, under that team's invariants. The moment it is published and becomes
available inside the usage service's boundary, it is reference knowledge: trusted, imported
context for someone else's decisions. Usage events flow the other way: they
are operational for the usage service, and they become reference for billing,
forecasting, and the account service's own refill logic.

Call this **role reversal**. It is the mechanism by which independent
applications become an ecosystem instead of a call graph. The ingredients
are old — the lineage section below names their owners — but the reciprocal
obligation they add up to is worth stating as a principle in its own right.

![Role reversal: two services above a shared knowledge substrate. The same dataset — account state — appears as amber operational reality inside the account service and as a green local projection inside the usage service; usage and charge facts mirror the pattern in the opposite direction, each side publishing to and projecting from governed data products.](role-reversal.drawio.png)

## The mechanism: publish, refine, project, join locally

Role reversal is not "replicate everything everywhere." It is a specific
four-step contract between a producing domain, a shared platform, and a
consuming domain.

**1. Publish.** The account service publishes balance and account-state
changes — through change data capture, an event stream, or batch snapshots.
Publication is part of the application's job, not an afterthought for the
analytics team.

**2. Refine and govern.** The stream becomes a governed product with explicit
semantics. The division of labor matters: the platform supplies the
mechanism — ingestion, normalization, policy enforcement, delivery — while
the *producing domain owns the semantics*: what the fields mean, what the
keys are, what a correction implies. Concretely, a product definition looks
like this:

```yaml
product: account-state
owner: account-control domain        # owns semantics; platform enforces policy
schema: v3 (additive changes only; breaking change = new major, 90-day overlap)
keys: [account_id]
attributes: [account_state, balance_remaining, plan_id, as_of]
freshness: "≤ 60 seconds via change feed; as_of carries observation time"
corrections: "late corrections republished under the same key; consumers upsert"
deletes: "tombstone records; consumers must process removals, not just upserts"
entitlement: "row-level — a consumer sees only its own tenant's accounts"
```

Note the `as_of` column and the freshness clause: staleness stops being an
ambient hazard and becomes a stated, contracted property that a reviewer can
accept or reject. A production-grade contract carries more than fits in an
essay — ordering and idempotency guarantees, bootstrap and replay procedure,
event time versus ingestion time, a reconciliation SLO. The point is that
these are *contract obligations with an owner*, not tribal knowledge
discovered during incidents.

**3. Project.** The usage service imports the product into its own boundary
as a **projection** — a consumer-local read model it can query, index, and
join, while the account service remains the only writer of the underlying
truth. A projection is usually a physical copy in the consumer's database,
but that is an implementation choice, not the definition; a governed view
over shared storage can play the same role. What defines a projection is
locality of *query*, not locality of *bytes*.

**4. Join locally.** And this is where the payoff lives. The
week-to-exhaustion question that had no endpoint becomes one query inside the
usage service's own boundary:

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

To be precise about what was gained: coordination does not disappear —
schema, semantics, entitlement, and freshness still require agreement at the
contract boundary. What disappears is the *per-question* negotiation. Every new
question compatible with the published product — segment by plan, correlate
with device type, backtest a pricing change — is a local query, not another
endpoint, another meeting, another release.

Then the loop closes. The usage service publishes its computed usage and
charge facts as its own product. Inside the account service's boundary they
arrive as reference knowledge feeding balance dynamics and refill signals.
The two services are *runtime-independent but semantically coupled*: neither
waits on the other to serve a request, while both are bound by the contracts
they publish. That is role reversal completing its cycle.

## What it costs, and where it does not apply

This design has real costs, and the literature has already documented them —
which is useful, because it means they are known quantities rather than
surprises.

**Storage and pipeline duplication.** Projections usually mean copied data
and operated pipelines. The systematic review of the data-mesh literature ([ACM
Computing Surveys 57(1)](https://arxiv.org/abs/2304.01062)) records data
duplication and effort duplication as documented practitioner concerns —
alongside their standard mitigations. The honest comparison is not "copies
versus no copies"; it is copies with contracts versus the repeated network
calls, bespoke endpoints, and undocumented shadow extracts that grow anyway.

**Reconciliation is now your explicit job.** A projection can disagree with
the source between refreshes. The contract's correction and tombstone clauses
exist precisely because late, corrected, and deleted observations *will*
arrive. Systems that pretend otherwise still have the inconsistency — they
just discover it in an incident review instead of a design review.

**Commands do not reverse.** Reserving inventory, committing a payment, any
action that must be checked against the owner's *current* invariant belongs
behind the owner's API, where locks and validation live. Role reversal is a
default for *knowledge* exchange, not a replacement for authoritative
behavior.

That boundary can be stated as a decision rule you can apply in tomorrow's
architecture review:

- **Reach for a projection** when questions have high fan-out or need joins,
  evolve unpredictably, tolerate bounded staleness, and must survive the
  provider's outages.
- **Reach for the owner's API** when the operation changes authoritative
  state, must validate against a current invariant, or cannot tolerate stale
  authorization or availability information.

The full trade space behind that rule — freshness, coupling, and what I call
reasoning capacity — deserves its own treatment, and it will get its own
essay.

## Whose shoulders, exactly

None of the raw ingredients here are new, and naming their owners makes the
actual contribution sharper.

**The temporal semantics** are Pat Helland's. ["Data on the Outside versus
Data on the Inside"](https://www.cidrdb.org/cidr2005/papers/P12.pdf) (CIDR
2005) established that data crossing a service boundary is categorically
different from data inside one: unlocked, uncertain, and stale — "The
contents of a message are always from the past!" — and described *reference
data* with exactly one publishing service per dataset, consumed as versioned
snapshots that are deliberately, admittedly out of date. Any data you receive
from another system is from the past; the only choice is how far past, and
whether that bound is explicit.

**The movement** is event-carried state transfer. Martin Fowler's
[2017 taxonomy of event-driven patterns](https://martinfowler.com/articles/201701-event-driven.html)
describes recipients updating their own copy of another system's data "so
that it never needs to talk to the main customer system in order to do its
work" — with the same trade-offs this essay carries: resilience and latency
gained, copies and receiver complexity paid. **The read model** is CQRS:
maintaining query-shaped derived state apart from the write path is a
well-worn pattern. **The ownership and governance** are data products, as
data mesh formulated them.

What none of these foregrounds as a single architecture-review obligation —
and what this essay argues for — is the
*reciprocity*: that every application is simultaneously a publisher
of its operational reality and a consumer of others', with a governed
refinement step in the middle; that "operational" and "reference" name the
two ends of one recurring swap; and that an architecture review should ask
for the completeness of that loop the way it asks for a threat model.
Event-carried state transfer explains the movement, CQRS the read model,
Helland the temporal semantics, data products the ownership. Role reversal
treats them as one design obligation — and makes it reviewable.

## Why this is surfacing now

Data mesh — the most influential data-architecture formulation of the past
decade — knew about the return path and chose not to center it. Zhamak
Dehghani's [2020 formulation](https://martinfowler.com/articles/data-mesh-principles.html)
names the two-way flow as a familiar pain ("flowing data from operational
data plane to the analytical plane, and back to the operational plane")
and then recommends the split anyway: "for now, I suggest we keep their
concerns separate." The canonical model foregrounded analytical products and
left operational re-entry underspecified — and implementations followed,
tending to stop at lakes, models, and dashboards. By
[January 2025](https://www.nextdata.com/our-pov/the-data-mesh-challenge-how-to-close-the-gap-between-inception-and-operation-at-scale),
Dehghani was describing data mesh as "a closed loop between operational and
analytical systems" while conceding that "a very few organizations have been
able to implement this closed loop." The loop was the intent; the mechanism
for operational re-entry remained underspecified.

The vendors are moving to supply the mechanism. In February 2026, Databricks
made [Lakebase](https://docs.databricks.com/aws/en/oltp/) generally
available: a managed Postgres inside the lakehouse, with governed synced
tables flowing analytics-to-operational (freshness floor of about fifteen
seconds — low-latency reads, not real-time data) and change capture flowing
back (in public preview at the time of writing). In June, the company
[announced "LTAP"](https://www.databricks.com/company/newsroom/press-releases/databricks-launches-ltap-first-lake-transactionalanalytical)
— "a new data processing architecture that unifies transactions, analytics,
streaming, and operational data on a single copy of storage in the lake" —
as *coming soon*, category claim first, product second. Shipping features
and announced architecture deserve different verbs; both point the same
direction: the role-reversal loop is being productized.

A product feature, however, is not a principle. Lakebase gives one platform's
mechanism for the projection step. The principle is vendor-neutral and older
than any of these products: *applications publish their reality; refined,
governed knowledge returns to where decisions are made; the local
intersection of the two is where the interesting questions get answered.*
You can implement it with a lakehouse, a stream, logical replication, or a
nightly batch — the architecture review question is whether the loop exists
and is governed, not which vendor closes it.

## Three hypotheses

Principles should pay rent in falsifiable claims. Here are three, with the
measurements that would falsify them:

1. **Lead time.** For cross-domain questions requiring joins or unanticipated
   analysis, teams with governed projections will show shorter lead time
   from question to shipped answer than teams composing synchronous APIs —
   measure the elapsed time and the number of cross-team changes required
   per new question.
2. **Availability.** Consumers reading projections will retain read
   availability during a provider outage; consumers on synchronous calls
   will not — measure consumer error rates during provider incidents.
3. **Failure class.** Making freshness contractual converts a class of
   incidents into design decisions — count incidents caused by stale
   projections versus incidents caused by unavailable or rate-limited
   dependencies, before and after.

## The one-line version

Stop asking only "what API does this system expose?" Ask: *what reality does
this application own, what does it publish, whose published reality does it
project — and can it join the two locally?* When the answer to the last part
is yes, integration stops being a call graph and starts being an ecosystem.

*This is the first essay in a series on data-first architecture — how
applications inherit knowledge, act on local reality, and return what they
learn. The next one takes the trade at the center of this design — freshness,
coupling, and reasoning capacity — and makes it explicit.*

Where has a local projection saved you — and where did its staleness cost
more than the API dependency it replaced? I am especially interested in the
counterexamples.
