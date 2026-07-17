---
title: "Your Operational Data Is Someone Else's Reference Data"
date: 2026-07-17
draft: true
tags: ["Data Architecture", "Software Architecture", "Data Mesh", "Event-Driven Architecture", "Microservices", "Data Products"]
summary: "Data is operational to its owner and reference to everyone else. Governed local projections let services answer new cross-domain questions without synchronous API choreography."
cover:
  image: social-card.drawio.png
  alt: "The same dataset, two roles: account state as amber operational reality in the account service and as a green local projection in the usage service, exchanged through a shared knowledge substrate"
  relative: true
  hidden: true
ShowToc: true
TocOpen: false
---

<!-- STATUS: draft R5 (2026-07-17) — pair-cohesion round (both essays reviewed
     together): projection/federation taxonomy ALIGNED with essay 2 (projection
     = maintained ahead of the decision; federation = retrieved at query time;
     bytes secondary); SQL now filters days_left <= 7 (matches the motivating
     question); terminology defense cut to two sentences; admissibility second
     mention → reminder; vendor chronology replaced with verified CDF passage
     (Lakebase CDF WAL→append-only governed tables; Delta CDF incremental
     propagation; "a feed moves changes; the contract makes them knowledge" —
     both docs fetched + verified this round; LTAP dropped from this essay);
     measurement compressed to one countable claim + retrospective (essay 2
     owns evaluation); tease standardized to "eight dimensions of evaluation".
     Prior R1–R4 verification holds (Fowler ECST, Dehghani quotes, Nextdata;
     social card + diagram gates DONE).
     TODO at publication: re-verify Lakebase CDF status; final date +
     draft: false; series taxonomy after naming gate (AGP-7); /writing/ index
     entry + reciprocal links. -->

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

The root problem is not the API. It is an assumption about the data: we treat
"their data" as something we may only *ask about*, never *hold*. Sometimes
policy requires exactly that — privacy, residency, erasure, or tenant-isolation
obligations can forbid holding a copy, and no architecture argument overrides
them. But when holding a governed copy *is* admissible, treating per-call
access as the only legitimate model is a costly design assumption. That
assumption is worth a name, because once you see it, you see it everywhere.

## Every cross-domain decision combines two roles of data

Look inside any consequential cross-domain decision and you find two kinds of
data with different origins and different lifecycles.

**Operational reality** is what the deciding application itself observes and
produces: its transactions, events, measurements, state transitions,
decisions. The usage service's operational reality is the stream of usage
events. This data is born here; this application is its source of truth.

**Reference knowledge** is everything the application imports in order to
make sense of its own observations. I am using the term deliberately more
broadly than the data-management tradition does: conventional "reference
data" means controlled code sets, taxonomies, and classifications; here,
reference knowledge means *any data a decision references but someone else
owns* — including current states published by other applications (account
balance, inventory position, device status), historical aggregates, and
policy tables. The usage service cannot price a single event without
reference knowledge it does not own.

"Reference knowledge," in short, is consumer-relative: data owned elsewhere
that this decision reads but does not author — however volatile it is
upstream. And it is knowledge under correction, not settled truth, which is
why the contract below spends clauses on corrections and tombstones.

Here is the observation that carries the rest of this essay: **operational
and reference are roles, not properties.** The same dataset plays both. A
balance change is operational reality inside the account service — it happens
there, under that team's invariants. The moment it is published and becomes
available inside the usage service's boundary, it is reference knowledge:
trusted, imported context for someone else's decisions. Usage events flow the
other way: they are operational for the usage service, and they become
reference for billing, forecasting, and the account service's own refill
logic.

Call this **role reversal**. It is the mechanism by which independent
applications become an ecosystem instead of a call graph. The ingredients
are old — the lineage section below names their owners — but the reciprocal
obligation they add up to is worth stating as a principle in its own right.

And the principle needs its boundary attached before any advocacy.
Holding a projection must be *admissible*: some data may be queried but never
persisted, derived from, or retained, and that gate is checked per product,
not assumed. Commands stay owner-mediated: anything that changes
authoritative state goes through the owner's API, where invariants and locks
live. And projection is a strong default for imported *knowledge*, not a
universal replacement for calls — a narrow, low-volume read is often better
as a call, and a federated query can serve cross-domain reads without a
consumer copy. This essay argues the default; the sequel compares the
alternatives as equals.

![Role reversal: two services above a shared knowledge substrate. The same dataset — account state — appears as amber operational reality inside the account service and as a green local projection inside the usage service; usage and charge facts mirror the pattern in the opposite direction, each side publishing to and projecting from governed data products.](role-reversal.drawio.svg)

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
the *producing domain owns the semantics*. It helps to name which
transformations are whose: mechanical work (format, transport, policy
enforcement) is platform-owned; anything that changes meaning (unit
conversion, key mapping, null semantics, temporal interpretation) ships only
with the producer's approval, exactly like a schema change; and a
consumer-specific derivation is a *new* product with its own owner, not a
mutation of this one. Without that split, "shared platform" quietly becomes a
central integration team that owns everyone's semantics. Concretely, a
product definition looks like this:

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

A sibling `price-plan` product publishes effective-dated unit prices under
the same conventions. Note the `history` and `freshness` clauses: staleness
and history depth stop being ambient hazards and become stated, contracted
properties a reviewer can accept or reject. A production-grade contract
carries more than fits in an essay — ordering and idempotency guarantees,
bootstrap and replay procedure, event time versus ingestion time, a
reconciliation SLO. The point is that these are *contract obligations with an
owner*, not tribal knowledge discovered during incidents.

**3. Project.** The usage service imports the product into its own boundary
as a **projection** — a consumer-oriented representation, *maintained ahead
of the decision*, that the service can query, index, and join while the
account service remains the only writer of the underlying truth. Where the
bytes live is secondary: a governed, materialized view on shared storage
that is kept ahead of decision time is still a projection; composing a query
against the owners' sources *at* decision time is not — that is federation,
the sequel's third candidate. One caution about the shared-storage form: it
provides local query semantics without a separate failure domain — when the
shared storage is down, so is your "local" read. The review card at the end
of this essay asks about query locality and failure locality separately,
because designs that provide the first while implying the second are where
outage surprises come from.

**4. Join locally.** And this is where the payoff lives. The
week-to-exhaustion question that had no endpoint becomes one query inside the
usage service's own boundary:

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

Notice what made this correct: the intervals. Each usage event is priced at
the plan and unit price in effect *when it happened*, and usage during
suspended intervals never enters the burn rate. With a current-state-only
projection, the same query silently reprices a month of history at today's
plan — fresher data producing a wronger answer. One simplification survives
for print: the fixed 30-day divisor overstates the runway of accounts younger
than the window; a production report divides by observed days.

The boundary is just as visible as the capability. Segment burn by plan,
recompute last month's charges under a proposed price list, alert when a
state change coincides with a usage spike — all local queries, because the
contract carries effective-dated states and prices. Correlate burn with
*device type*? Not a local question: no product shown here publishes device
attributes. New questions are possible exactly within the projection's
granularity, history depth, semantics, entitlements, and retained fields —
and no further. The sequel gives that boundary a name, *reasoning capacity*,
and makes it one of eight requirements for comparing integration candidates.

To be precise about what was gained: coordination does not disappear —
schema, semantics, entitlement, and freshness still require agreement at the
contract boundary, and a genuinely new *use* of the data may still need
purpose or retention approval. What changes is this: **a new question
compatible with the published product no longer requires an upstream
interface change or a producer release.** That is a narrower claim than
"negotiation disappears," and it is the one you can measure.

Then the loop closes. The usage service publishes its computed usage and
charge facts as its own product; inside the account service's boundary they
arrive as reference knowledge feeding balance dynamics and refill signals.
The two services are *request-path independent, asynchronously coupled, and
semantically bound by the published contract*. Neither waits on the other to
serve a request — but the consumer still depends on the producer publishing
changes, on the delivery pipeline, and on its projection staying within the
contracted freshness. During a producer outage, local reads continue and
grow older; that is degraded independence, bounded by the maximum data age
the decision tolerates, not absolute independence. The bounded form is still
worth a great deal — and it is the honest form.

## Where it does not apply, and what it costs

**Some projections are inadmissible.** The gate from the top of the essay —
may this consumer query, persist, derive from, retain? — is checked per
product, and the contract's entitlement clause is where the answer lives.
Where it says no, nothing below applies to that data.

**Commands do not reverse.** Reserving inventory, committing a payment, any
action that must be checked against the owner's *current* invariant belongs
behind the owner's API, where locks and validation live. Role reversal is a
default for *knowledge* exchange, not a replacement for authoritative
behavior.

**Narrow reads are cheaper as calls.** A projection is a pipeline you
operate. If the question is low-volume, current-state, and shaped exactly
like an existing endpoint — one plan lookup at signup — a call costs less
than a contract, a feed, and a reconciliation job. Projection earns its cost
when questions fan out, need joins, or keep changing.

**Federation is a real alternative.** A federated query engine retrieves
evidence from owner-controlled sources at query time, with no consumer copy
to maintain — occupying different freshness, coupling, and failure-domain
positions, not strictly worse ones. The sequel treats calls, projections,
and federated queries as equal candidates; this essay's claim is only that
the projection option is systematically under-considered.

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

**The mechanism assumes a platform.** Ingestion, replay, tombstone delivery,
entitlement enforcement — where no shared platform provides them, every
consuming team builds its own, and the duplication cost above compounds.
Role reversal without platform maturity is a portfolio of hand-rolled
pipelines.

The boundary can be compressed into a decision rule for tomorrow's
architecture review:

- **Reach for a projection** when questions have high fan-out or need joins,
  evolve unpredictably, tolerate bounded staleness, and must survive the
  provider's outages.
- **Reach for the owner's API** when the operation changes authoritative
  state, must validate against a current invariant, or cannot tolerate stale
  authorization or availability information.

And expect the boundary to move with the stakes: the same account data may be
screened from a projection, explored in an analytical store, and acted on
authoritatively only through the owner's API — one dataset, three access
modes, each correct for its decision.

## The role-reversal review

A principle you cannot run in a review is a slogan. Here is the compact
version — one block to paste into an ADR next to the decision it serves:

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

The last line is the one reviews forget, and it is the reciprocity this essay
exists to argue for. The sequel's per-candidate ADR template goes deeper on
the middle — comparing candidate mechanisms requirement by requirement — but
this card is enough to make the loop, and its gaps, visible.

## Whose shoulders, exactly

None of the raw ingredients here are new, and naming their owners makes the
actual contribution sharper.

**The temporal semantics** are Pat Helland's. ["Data on the Outside versus
Data on the Inside"](https://www.cidrdb.org/cidr2005/papers/P12.pdf) (CIDR
2005) established that data crossing a service boundary is categorically
different from data inside one: unlocked, uncertain, and stale — "The
contents of a message are always from the past!" — and described *reference
data* with exactly one publishing service per dataset, consumed as versioned
snapshots that are deliberately, admittedly out of date. **The movement** is
event-carried state transfer: Martin Fowler's
[2017 taxonomy of event-driven patterns](https://martinfowler.com/articles/201701-event-driven.html)
describes recipients maintaining their own copy of another system's data "so
that it never needs to talk to the main customer system in order to do its
work" — with the same trade-offs this essay carries. **The read model** is
CQRS: query-shaped derived state apart from the write path is a well-worn
pattern. **The ownership and governance** are data products, as data mesh
formulated them.

What none of these foregrounds as a single architecture-review obligation —
and what this essay argues for — is the *reciprocity*: that every application
is simultaneously a publisher of its operational reality and a consumer of
others', with a governed refinement step in the middle; that "operational"
and "reference" name the two ends of one recurring swap; and that an
architecture review should ask for the completeness of that loop the way it
asks for a threat model. Event-carried state transfer explains the movement,
CQRS the read model, Helland the temporal semantics, data products the
ownership. Role reversal treats them as one design obligation — and makes it
reviewable.

## Why this is surfacing now

Data mesh — the most influential data-architecture formulation of the past
decade — knew about the return path and chose not to center it. Zhamak
Dehghani's [2020 formulation](https://martinfowler.com/articles/data-mesh-principles.html)
names the two-way flow as a familiar pain ("flowing data from operational
data plane to the analytical plane, and back to the operational plane")
and then recommends the split anyway: "for now, I suggest we keep their
concerns separate." Implementations followed, tending to stop at lakes,
models, and dashboards. By
[January 2025](https://www.nextdata.com/our-pov/the-data-mesh-challenge-how-to-close-the-gap-between-inception-and-operation-at-scale),
Dehghani was describing data mesh as "a closed loop between operational and
analytical systems" while conceding that "a very few organizations have been
able to implement this closed loop." The loop was the intent; the mechanism
for operational re-entry remained underspecified.

The vendors are now shipping the mechanism's parts. Databricks'
[Lakebase](https://docs.databricks.com/aws/en/oltp/) puts a managed Postgres
inside the lakehouse, and its
[change data feed](https://docs.databricks.com/aws/en/oltp/projects/lakebase-cdf)
makes the publish step concrete: every insert, update, and delete is captured
from the write-ahead log into append-only, governed tables. Delta tables in
turn offer their own
[change data feed](https://docs.delta.io/delta-change-data-feed/) for
incremental propagation between table versions. These feeds solve a real
part of publication — row-level change capture without building an external
CDC stack. What they do not supply is anything the contract above states:
semantic ownership, effective-time meaning, entitlement, retention,
completeness, correction policy, the consumer's projection. **A feed moves
changes; the product contract is what makes those changes usable as
knowledge.**

And a product feature is not a principle. The principle is vendor-neutral
and older than any of these products: *applications publish their reality;
refined, governed knowledge returns to where decisions are made; the local
intersection of the two is where the interesting questions get answered.*
You can implement it with a lakehouse, a stream, logical replication, or a
nightly batch — the architecture review question is whether the loop exists
and is governed, not which vendor closes it.

## Measuring it

The essay's central claim is countable: **producer-side changes per new
cross-domain question.** Count the endpoint additions, bulk-export requests,
and producer releases each new question required, before and after governed
projections — and compare within a team across time, because teams with
mature platforms both project more and ship faster, and a cross-team
comparison flatters the projection.

Or start with a retrospective that needs no infrastructure at all. Take the
last ten cross-domain questions your team answered. For each, record where
the answer actually came from — a new endpoint, a bulk export, an
undocumented extract, a local join — and how many producer-side changes it
took. If undocumented extracts appear on the list, role reversal is already
happening in your organization; it is just happening without a contract.

## The one-line version

Stop asking only "what API does this system expose?" Ask: *what reality does
this application own, what does it publish, whose published reality does it
project — and can it join the two locally?* When the answer to the last part
is yes, integration stops being a call graph and starts being an ecosystem.

*This is the first essay in a series on data-first architecture — how
applications inherit knowledge, act on local reality, and return what they
learn. The next one turns the decision at the center of this design into an
instrument: eight dimensions of evaluation for choosing among API calls,
projections, and federated queries.*

Where has a local projection saved you — and where did its staleness cost
more than the API dependency it replaced? I am especially interested in the
counterexamples.
