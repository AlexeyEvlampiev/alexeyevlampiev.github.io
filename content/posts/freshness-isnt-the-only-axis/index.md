---
title: "Freshness Isn't the Only Axis"
date: 2026-07-17
draft: true
tags: ["Data Architecture", "Software Architecture", "Data Mesh", "Event-Driven Architecture", "Microservices", "API Design"]
summary: "Staleness is one part of the API-versus-projection decision. A permission gate and six axes — temporal fidelity, coupling, reasoning capacity, authority, reversibility, economics — turn the argument into an instrument."
cover:
  image: social-card.drawio.png
  alt: "Freshness is one requirement: time, coupling, reasoning, authority, reversibility, economics — the six axes of the API-versus-projection decision"
  relative: true
  hidden: true
ShowToc: true
TocOpen: false
---

<!-- STATUS: draft R2 (2026-07-17) — second-opinion review applied in full:
     temporal fidelity replaces freshness; gate-zero permission added;
     reasoning capacity operationalized; reversibility added to reconciliation;
     owner-mediated-path phrasing; API side de-straw-manned; prior-art halved
     and moved after walkthrough; why-now compressed; LLM analogy REMOVED and
     relocated to Essay 3 (AGP-5); review template added; hypothesis made
     measurable; diagram wording fixed; six-axis social card created.
     MANDATORY before publication: revision round folding in Essay 1's launch
     reception. TODO: final date, series taxonomy after AGP-7 naming gate,
     LTAP/Lakebase + Trino pushdown re-check at publication (version-sensitive).
     Optional: re-verify empirical papers 2302.01894/1908.04101 (hedged now). -->

Every architecture review of a data integration reaches the same moment.
Someone proposes keeping a local copy of another domain's data, and someone
else says the sentence that ends the discussion: *"But the copy will be
stale. The API gives us the current truth."*

The sentence sounds rigorous, and it smuggles in two assumptions. First,
that the owner's read path is itself current — when it may serve from a read
replica, a cache, an asynchronously updated index, or a materialized view of
its own. Second, that facts returned by several owners describe a coherent
moment — when three sequential calls can each be individually fresh while
describing three incompatible instants. A five-minute-old projection can be
internally snapshot-consistent; the "fresh" composition never was. Grant the
API its usual advantage — it is often fresher — and the sentence is still
only one component of one dimension of the decision.

This essay names the other dimensions. It is the second in a series; the
[first](/posts/your-operational-data-is-someone-elses-reference-data/) argued
that operational and reference are roles a dataset plays, not properties, and
that the publish → refine → project → join-locally loop deserves first-class
status. This one takes the trade at the center of that loop and turns it into
an instrument you can put on the table at Monday's review.

## The question with no per-call answer

A payments team is asked to flag accounts whose spending pattern this week
diverges from their twelve-month baseline *and* whose account standing
changed recently *and* whose plan tier makes the divergence commercially
significant. Three domains: transactions (theirs), account standing (another
team's), plan catalog (a third team's).

The naïve per-entity composition version of this feature is a distributed
query engine assembled from meetings: page through accounts, call standing
for each, call the plan service, join in application code. Each call is
fresh — and the whole is operationally poor at large fan-out, unrunnable
during a dependency's incident, and frozen the moment the product manager
changes "twelve-month baseline" to "same-quarter-last-year baseline,"
because that is a different endpoint conversation.

There are better API-side designs, and each is a different position in the
trade space this essay maps: a bulk endpoint improves the economics but not
the space of askable questions; a provider-side query endpoint moves the
computation without freeing it from the provider's contract; a purpose-built
aggregate answers exactly one anticipated question well; a cached composition
buys latency at the price of the very staleness the API was chosen to avoid.

The projection version is one SQL query over three local tables, two of them
maintained by governed feeds from the owning domains. Its facts are minutes
old, and internally coherent. Nobody at the review said out loud that the
choice was between *fresh-per-call-but-narrow* and *minutes-old-but-able to
answer the unanticipated questions the projected schema and history permit*.
Freshness got a sentence; the rest of the decision got none.

## Gate zero, then six axes

Before any trade-off, one question is a gate, not an axis: **may this
consumer receive or query this data at all** — at the required granularity,
for this purpose? Residency, purpose limitation, tenant isolation, retention
and erasure, sensitive attributes. If the answer is no, neither reasoning
capacity nor economics can make the projection admissible. If the answer is
"yes, with row-level entitlement," that entitlement becomes a clause in the
product contract — the first essay's example contract carried exactly such a
clause.

Past the gate, six axes. For each integration, ask six questions and record
six answers:

| Axis | The question to ask out loud | What to record |
|---|---|---|
| **Temporal fidelity** | How old may each fact be — and must facts from different domains describe a coherent snapshot or causal order? | Max age / lag SLO, `as_of` visibility, cross-source coherence requirement |
| **Coupling** | Must the consumer keep working when the producer or the network is degraded? | Availability target during provider failure; a failure-mode test |
| **Reasoning capacity** | Which questions are feasible without an upstream contract change — within what latency, cost, and availability budgets? | Locally joinable dimensions, history depth, fan-out budget, time-to-answer for a new question |
| **Authority** | Who validates and commits the decision against the current invariant? | The invariant's owner and the owner-mediated command path |
| **Reversibility & reconciliation** | If stale or incoherent knowledge produces a wrong decision, how cheaply is it corrected — and what detects the conflict? | Correction mechanism: revalidation, compensation, human review |
| **Economics** | What is the total lifecycle cost, both designs counted honestly? | Calls, egress, storage, pipelines, on-call |

Note that the first row is *temporal fidelity*, not freshness. The first
essay called this requirement freshness, and freshness — maximum observation
age — is its headline component. But the full requirement also covers update
lag, whether `as_of` times are visible to the decision, and whether facts
drawn from several domains must describe one coherent moment or respect a
causal order. A projection with an explicit `as_of` can satisfy a coherence
requirement that a fan of individually fresh calls silently violates.

And one instruction for using the table: **the axes are not votes.** Do not
count which option wins the most rows. Permission and authority can veto a
design outright; temporal fidelity, coupling, reasoning capacity, and
economics optimize among the designs that remain feasible. The table is a
set of questions that must be answered on the record — not a scorecard.

Several axes have distinguished ancestry, and they are inherited here, not
discovered. Pat Helland fixed the temporal endpoints in
[2005](https://www.cidrdb.org/cidr2005/papers/P12.pdf): data crossing a
service boundary "is always from the past," and participating in another
system's transaction means holding its locks — "a serious ceding of
independence." Daniel Abadi's
[PACELC](https://www.cs.umd.edu/~abadi/papers/abadi-pacelc.pdf) made the
replication half formal in 2012: "as soon as a DDBS replicates data, a
tradeoff between consistency and latency arises" — present at all times.
[Azure's integration guidance](https://learn.microsoft.com/en-us/azure/architecture/microservices/design/data-considerations)
names the authority axis outright: one service is "the source of truth for a
given entity"; others hold eventually consistent copies.

What none of that lineage carries as a *decision axis* is the third row —
and it is the one that decided the payments example.

## Reasoning capacity, operationally

**Reasoning capacity is the set of questions and decisions a consumer can
compute, using contracts already available to it, within stated latency,
cost, availability, and coordination budgets.**

Not "able to compute" in the theoretical sense — with enough calls, retries,
and meetings, remote APIs can be composed into almost any computation.
Feasibility within budgets is the point, and it is measurable: how many
dimensions are locally joinable; whether history is deep enough to recompute
and backtest; what fan-out the latency and cost envelope tolerates; and,
above all, the lead time from a new question to a production answer — and
whether that path crosses another team's roadmap.

The contrast with the API is then precise: **a call can make a question
logically expressible yet operationally infeasible; a projection expands the
set of questions that are feasible without changing any upstream contract.**
When the relevant projections are local, the application can join months of
its own events with other domains' published state and answer next week's
question the same afternoon. When they are not, its feasible-question set
collapses to what some provider anticipated when the contract was written —
plus whatever can be assembled within the budgets, which is usually far less
than what is expressible.

![The local intersection: reference knowledge (green, left — other domains' published state, shared facts, classifications, aggregates, policies) and operational reality (amber, right — transactions, events, measurements, workflow state) both flow into a central box, the local intersection, where joins, aggregation, inference, screening, optimization and prediction happen — where cross-domain decisions become locally computable, inside one computational boundary.](local-intersection.drawio.png)

## Walking the table

Run the payments example through the gate and the six axes:

**Permission:** the payments team may hold account standing at
account-level granularity for fraud-adjacent purposes — with row-level
tenant entitlement written into the feed's contract. Gate passed, on the
record. **Temporal fidelity:** the divergence analysis tolerates minutes-old
standing data — the baseline itself is twelve months deep — and the
projection's `as_of` column makes the observation time visible to the
decision. **Coupling:** the flagging job must run during the standing
service's deploy window; the projection answers from the last accepted
state. **Reasoning capacity:** the query joins three domains and will be
reshaped every quarter; lead time for a new question must not include
another team's sprint. **Authority:** flagging an account for review
commits nothing against anyone's invariant — but the *follow-up* action,
freezing the account, goes through the owner-mediated command path, full
stop. **Reversibility:** this is the row that quietly decides the design. A
flag is cheap to revoke: a human review detects and corrects it. Freezing
or debiting on the same minutes-old data would be a materially different
answer in this row — the same temporal fidelity can be acceptable for the
reversible decision and unacceptable for the irreversible one.
**Economics:** two governed feeds versus a bespoke fan-out client and its
rate-limit negotiations; the feeds win before the first incident is counted.

One gate, six rows, one paragraph — and the decision explains itself to the
next reviewer.

The same instrument works in reverse. Reserve inventory? Authority requires
the owner-mediated command path — whether that is a synchronous API, a
command queue, or a saga is transport detail; the requirement is that the
owning domain validates and commits against its current invariant, and no
amount of reasoning-capacity enthusiasm overrides it. Display a customer's
current balance? Temporal fidelity dominates, and the answer is an
owner-governed current read path — which might be the owner's API, or might
be a projection with guarantees strong enough to be designated exactly that.
The table is not a projection advocacy device; it is what keeps every side
honest.

## The third option, on the same axes

Federated query engines — Trino, Starburst, the data-virtualization family —
promise the tempting middle: cross-domain joins with no local copies. The
promise is real, and the instrument prices it like everything else.

**Temporal fidelity:** each fact is read live — but coherence across sources
is exactly what federation does not universally guarantee; two connectors
are observed at two moments. **Coupling:** inverts — the decision now
requires every source system *and* the engine healthy at query time, the
projection's failure profile turned inside out. **Reasoning capacity:**
broad, bounded by connector coverage and pushdown:
[join pushdown requires the joined tables to share a catalog](https://trino.io/docs/current/optimizer/pushdown.html),
so the genuinely cross-domain join executes by pulling data into the engine
at query time. **Authority:** unchanged — federation reads; it commits
nothing. **Reversibility:** results can differ between runs, so decisions
taken on federated reads need the same correction story as projections.
**Economics:** per-query and conditional — "often" a cost reduction, say the
vendors' own docs, choosing the adverb carefully. **And the gate:** policy
and identity must translate across every federated source, which is its own
project.

Run it through the table and federation earns its place for interactive,
occasional, freshness-hungry analysis — and loses it for the always-on
decision path that must survive a provider's bad day. The instrument doesn't
pick sides; it prices them.

## Whose shoulders, briefly

None of the mechanisms here are new. CQRS maintains query-shaped read
models; Fowler's
[event-carried state transfer](https://martinfowler.com/articles/201701-event-driven.html)
moves state so recipients need not call the source; Kleppmann's inside-out
architecture supplies the log-and-derived-views machinery; the
[unbundled-database literature](https://www.confluent.io/blog/leveraging-power-database-unbundled/)
placed materialized views inside consuming services in 2017; and Peter
Denning's [locality principle](https://denninginstitute.com/pjd/PUBS/CACMcols/cacmJul05.pdf)
is the deepest root of bring-data-close-to-the-process. Pattern guidance
distributes the decision across benefit lists and force lists — Chris
Richardson's
[command-side replica](https://microservices.io/patterns/data/command-side-replica.html)
comes particularly close, weighing ten named forces.

What I have not found is a compact instrument for comparing calls,
projections, and federation in which *the set of questions feasible without
upstream change* is itself named and evaluated. Whether or not this table is
the first hardly matters; what matters is whether putting that row on the
review changes decisions. There is respectable precedent for the complaint
itself: Abadi built PACELC on the observation that CAP "does not constrain
any system capabilities during normal operation" — a famous framework,
missing the axis that operates all the time.

## Why now, in one paragraph

The projection step is being productized: Databricks'
[Lakebase](https://docs.databricks.com/aws/en/oltp/) ships governed synced
tables into a managed Postgres (freshness floor around fifteen seconds), and
its [LTAP announcement](https://www.databricks.com/company/newsroom/press-releases/databricks-launches-ltap-first-lake-transactionalanalytical)
promises transactions and analytics on a single copy of storage — coming
soon. Every vendor pitch is implicitly a position on these axes: sync
latency is a temporal-fidelity row, single-copy claims target economics —
and no platform answers authority, reversibility, or the permission gate for
you. The axes are how you evaluate the slide.

## One hypothesis, one exercise

The falsifiable version of this essay: **within twelve months of approval,
the proportion of integrations requiring material redesign — because the
original review omitted a requirement that maps to one of these axes — will
be lower for teams that put the gate and six axes on the record than for
teams whose reviews argued freshness alone.** Normalize by reviewed
integration, and note which axis the original review failed to discuss; my
prediction is that the missing axis predicts the failure class.

To be explicit about the evidence base: I have not found verified empirical
work scoring integration rework against the axis the review skipped. That
absence is why this is a hypothesis and not a finding.

There is also a retrospective you can run today: take your last ten
integration redesigns and, for each, name the requirement that was absent
from the original review. If it maps to an axis here, the instrument would
have caught it. If it doesn't map to any axis — that is evidence this
framework is missing one, and that is precisely what I want to hear about.

## The instrument, ready to copy

"But the copy will be stale" is one row of a gated, six-row decision. Here
is the review template — paste it into the ADR:

```text
Integration decision:
Options considered:        [ call | projection | federation | hybrid ]

Permission gate:           may this consumer hold/query this data?
                           (entitlement, residency, purpose, retention)
Temporal fidelity:         max age, coherence across sources, as_of visibility
Runtime coupling:          required behavior during provider failure
Reasoning capacity:        questions feasible without upstream change;
                           latency/cost/availability budgets
Authority:                 who commits, via which owner-mediated path
Reversibility & reconciliation:  correction cost, conflict detection, compensator
Economics & operability:   lifecycle cost of BOTH designs

Chosen design:
Rejected alternatives (and the row that decided):
Assumptions to verify:
```

*This is the second essay in a series on data-first architecture. The
[first](/posts/your-operational-data-is-someone-elses-reference-data/)
introduced role reversal — publish your reality, project theirs, join
locally. The next one asks what happens when the consumer doing the
reasoning is not a team but an AI agent.*

Which axis is missing from your architecture-review template — and what did
its absence cost you? Real stories, especially ones where a projection was
the wrong call, are exactly what I'm collecting.
