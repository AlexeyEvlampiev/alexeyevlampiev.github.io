---
title: "Freshness Isn't the Only Axis: Choosing Between APIs and Local Projections"
date: 2026-07-17
draft: true
tags: ["Data Architecture", "Software Architecture", "Data Mesh", "Event-Driven Architecture", "Microservices", "API Design"]
summary: "Choosing between an API, a local projection, or a federated query takes more than freshness. A permission gate and six explicit forces make the trade-off reviewable."
cover:
  image: social-card.drawio.png
  alt: "Freshness is one requirement: time, runtime and change coupling, question space, authority, recoverability, lifecycle cost — the six axes of the API-versus-projection decision"
  relative: true
  hidden: true
ShowToc: true
TocOpen: false
---

<!-- STATUS: draft R3 (2026-07-17) — third review round applied in full:
     snapshot/coherence/as_of distinction corrected (watermark rule added);
     permission gate applied per-option with graded outcomes; coupling
     expanded to runtime+change; reversibility split from projection
     reconciliation ("decision consequence & recoverability"); reasoning
     capacity made orthogonal (budgets moved to their rows); walkthrough
     reformatted as table + result sentence; economics tempered with stated
     assumptions; federation wording precise (per-source query interface,
     cross-catalog pushdown, reproducibility-without-captured-cut, engine
     added to dependency set); lineage merged into one section; hypothesis
     operationalized vs team's historical rate; title extended for standalone
     clarity; social-card labels precise; diagram center reinforces
     reasoning capacity. LinkedIn alt headline for channel kit: "Your API is
     fresh. Your decision may still be incoherent."
     MANDATORY before publication: Essay-1-reception revision round.
     TODO: final date; series taxonomy after AGP-7; LTAP/Lakebase + Trino
     pushdown re-check at publication; optional re-verify empirical papers. -->

Every architecture review of a data integration reaches the same moment.
Someone proposes keeping a local copy of another domain's data, and someone
else says the sentence that ends the discussion: *"But the copy will be
stale. The API gives us the current truth."*

The sentence sounds rigorous, and it smuggles in two assumptions. First,
that the owner's read path is itself current — when it may serve from a read
replica, a cache, an asynchronously updated index, or a materialized view of
its own. Second, that facts returned by several owners describe a coherent
moment — when three sequential calls can each be individually fresh while
describing three incompatible instants. Neither follows merely from making
the calls *now*. Grant the API its usual advantage — it is often fresher,
fact by fact — and the sentence still covers one component of one dimension
of the decision.

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
old. Nobody at the review said out loud that the choice was between
*fresh-per-call-but-narrow* and *minutes-old-but-able to answer the
unanticipated questions the projected schema and history permit*. Freshness
got a sentence; the rest of the decision got none.

## Gate zero, then six axes

Before any trade-off, one question is a gate, not an axis — and it must be
asked **separately for each candidate design**, because "query," "persist,"
"derive," and "retain" are materially different permissions. A policy may
permit an API call while prohibiting a durable copy; it may allow a
projection with a seven-day retention limit while prohibiting historical
reconstruction; it may allow holding a raw fact but not the derived risk
classification.

> **Gate zero — admissibility.** For this option: may the consumer query,
> persist, derive from, and retain the required data, at the proposed
> granularity, for the stated purpose? Consider residency, purpose
> limitation, tenant isolation, retention and erasure, and sensitive
> attributes.

The outcome is not merely yes or no. A design can be *inadmissible*;
*admissible with constraints* (retention limits, minimized columns,
row-level entitlement written into the product contract — the first essay's
example contract carried exactly such a clause); *admissible only through an
owner-mediated or federated read*; or *admissible as a derived, minimized
product* rather than the raw data.

Past the gate, six axes. For each integration, ask six questions and record
six answers:

| Axis | The question to ask out loud | What to record |
|---|---|---|
| **Temporal fidelity** | What maximum age, lag, and cross-source skew are acceptable? Is a coherent snapshot or causal order required — and how is it *produced*? | Max age / lag SLO, `as_of` visibility, coherence mechanism (watermark, skew bound, snapshot token) |
| **Runtime & change coupling** | What must be available at decision time — and which schema or semantic changes upstream require coordinated work? | Availability target during provider failure; teams and contracts affected by a breaking change |
| **Reasoning capacity** | Which questions and derivations are supported by the data, history, and contracts already available — without an upstream contract change? | Locally joinable dimensions, history depth, past-state reconstruction, lead time to a new production answer |
| **Authority** | Who validates and commits the authoritative state transition? | The invariant's owner and the owner-mediated command path |
| **Decision consequence & recoverability** | If stale, incomplete, or incoherent knowledge produces a wrong decision, what does it cost, what detects it, and what corrects it? | Revalidate-before-acting, compensation, human review, or irreversible external effect |
| **Economics & operability** | What is the total lifecycle cost of each design, honestly counted? | Calls, egress, storage, pipelines, replay and divergence repair, observability, on-call |

And one instruction for using the table: **the axes are not votes.** Do not
count which option wins the most rows. Admissibility and authority can veto
a design outright; the other rows optimize among the designs that remain
feasible. The table is a set of questions that must be answered on the
record — not a scorecard.

## Temporal fidelity: age is not coherence

The first row deserves its own paragraph, because it hides the subtlest
distinction in the whole decision — and the first essay's shorthand,
"freshness," covered only part of it.

Three different guarantees get conflated in every staleness argument. A
transaction over a local projection guarantees that the query sees *one
committed state of the projection*. It does not guarantee that every fact in
that state describes *the same business instant*: if account standing was
observed at 10:03 and plan tier at 10:07, querying both in one local
transaction does not make them temporally coherent. An `as_of` column makes
the mismatch *visible*; it does not eliminate it. Coherence requires an
additional, explicit rule — a common source watermark, a bounded maximum
skew, a shared snapshot token, or causal metadata. For the payments case,
the rule fits in four lines:

```text
decision_cutoff = min(transaction_watermark,
                      standing_watermark,
                      plan_watermark)
maximum permitted source skew: 60 seconds
```

If the projections retain history, the query can select each source *as of*
the common cutoff. If they hold only current-state upserts, no coherent
earlier cut can be reconstructed — a direct link between this row and the
reasoning-capacity row: history is what turns visibility into coherence.

The same honesty cuts the other way: APIs can support coherence too, through
snapshot tokens, version-bound reads, or provider-side composition. The
trade is not "API incoherent, projection coherent." It is whether the chosen
design *has an explicit coherence mechanism* — most per-call compositions
silently have none.

## Reasoning capacity

**Reasoning capacity is the set of questions and derivations supported by
the data, history, and contracts already available to the consumer — without
an upstream contract change.**

Latency, availability, and cost all constrain what is practical — but those
constraints live in their own rows. This axis measures the question space
itself, and it is measurable: how many dimensions are locally joinable;
how deep the history is, and whether past state can be reconstructed;
whether hypothetical scenarios can be evaluated against it; how many
upstream contract changes a new question requires; and the lead time from a
new question to a first production answer.

The contrast with the per-call design is then precise: **a call can make a
question logically expressible while the composition needed to answer it is
operationally out of reach; a projection expands the set of questions
answerable without renegotiating any upstream contract.** When the relevant
projections are local, the application can join months of its own events
with other domains' published state and answer next week's question the same
afternoon. When they are not, the feasible-question set collapses to what
some provider anticipated when the contract was written.

![The local intersection: reference knowledge (green, left — other domains' published state, shared facts, classifications, aggregates, policies) and operational reality (amber, right — transactions, events, measurements, workflow state) both flow into a central box — the local intersection, the consumer's reasoning capacity — where joins, aggregation, inference, screening, optimization and prediction happen, inside one computational boundary.](local-intersection.drawio.png)

## Walking the table

Run the payments example through the gate and the six axes — in the shape
the review record should take:

| Row | Evidence | Effect on the decision |
|---|---|---|
| Admissibility | Standing may be retained at account granularity for fraud-adjacent review, tenant-isolated, per the feed contract | Projection feasible, with constraints on the record |
| Temporal fidelity | Minutes-old acceptable (baseline is twelve months deep); common watermark + 60s skew bound adopted | Projection feasible — coherence mechanism named |
| Runtime coupling | Screening must run during the standing service's deploy window | Favors projection |
| Change coupling | Standing schema versioned, additive changes, 90-day overlap on breaking ones | Projection risk manageable — and on the record |
| Reasoning capacity | Query reshaped quarterly; needs 12 months of history and three-domain joins | Strongly favors projection |
| Authority | Flagging commits nothing against anyone's invariant | Projection permitted for the *read* |
| Consequence & recoverability | A flag is reviewable and reversible — human review detects and corrects; freezing or debiting would be irreversible | Projection for flagging; owner-mediated command path for freezing |
| Economics & operability | Existing governed-feed platform; recurring high-fan-out query; quarterly reshaping | Favors projection *under these assumptions* |

Then say the result out loud, because it demonstrates why the rows are not
votes: **reasoning capacity selected the read design; decision consequence
selected the action boundary.** The same minutes-old data is acceptable for
the reversible decision and would be unacceptable for the irreversible one.

The economics row deserves its assumptions stated, because they can flip it:
given an existing feed platform, quarterly query changes, and high fan-out,
the projection has the lower expected lifecycle cost — before provider
incidents are priced in. Make this the *only* consumer, run the query
monthly, remove the platform, or hand the provider an efficient bulk
endpoint, and the call side can win the row honestly.

The instrument also works in reverse. Reserve inventory? Authority requires
the owner-mediated command path — synchronous API, command queue, or saga is
transport detail; the requirement is that the owning domain validates and
commits against its current invariant. Display a customer's balance?
Temporal fidelity dominates, and the answer is an owner-governed current
read path — which might be the owner's API, or a projection with guarantees
strong enough to be designated exactly that. The table is not a projection
advocacy device; it is what keeps every side honest.

## The third option, on the same axes

Federated query engines — Trino, Starburst, the data-virtualization family —
promise the tempting middle: cross-domain joins with no persistent local
copies. The instrument prices the promise like everything else.

**Temporal fidelity:** each fact is retrieved from the source's current
query interface at execution time — which is not the same as authoritative
live state (sources themselves serve replicas, caches, snapshots), and
coherence across sources is exactly what federation does not universally
provide. **Runtime coupling:** the decision path is coupled to every queried
source *and* to the federation engine itself — the dependency set grows.
**Change coupling:** every source schema is now part of the consumer's query
surface. **Reasoning capacity:** broad, bounded by connector coverage and
pushdown — under current
[Trino rules](https://trino.io/docs/current/optimizer/pushdown.html), a
cross-catalog join cannot be pushed into either source, so the engine
retrieves source-side results and joins them itself. **Authority:**
unchanged — federation reads; it commits nothing. **Consequence &
recoverability:** without source snapshot identifiers, watermarks, or
retained query inputs, the same federated query may not be reproducible
later — decisions taken on it need a correction story just as projections
do. **Economics:** per-query and conditional — "often" a cost reduction, say
the vendors' own docs, choosing the adverb carefully. **And the gate:**
policy and identity must translate across every federated source, which is
its own project.

Run it through the table and federation earns its place for interactive,
occasional, freshness-hungry analysis — and loses it for the always-on
decision path that must survive a provider's bad day. The instrument doesn't
pick sides; it prices them.

## Whose shoulders, briefly

None of the mechanisms here are new, and several axes are inherited with
their citations. Pat Helland fixed the temporal endpoints in
[2005](https://www.cidrdb.org/cidr2005/papers/P12.pdf): data crossing a
service boundary "is always from the past," and joining another system's
transaction is "a serious ceding of independence." Daniel Abadi's
[PACELC](https://www.cs.umd.edu/~abadi/papers/abadi-pacelc.pdf) made the
replication half formal: "as soon as a DDBS replicates data, a tradeoff
between consistency and latency arises" — present at all times.
[Azure's guidance](https://learn.microsoft.com/en-us/azure/architecture/microservices/design/data-considerations)
names the authority axis outright — one service is "the source of truth for
a given entity" — and gestures at query capability as a benefit. CQRS
maintains query-shaped read models; Fowler's
[event-carried state transfer](https://martinfowler.com/articles/201701-event-driven.html)
moves state so recipients need not call the source; Kleppmann's inside-out
architecture supplies the log-and-derived-views machinery; the
[unbundled-database literature](https://www.confluent.io/blog/leveraging-power-database-unbundled/)
placed materialized views inside consumers in 2017; Denning's
[locality principle](https://denninginstitute.com/pjd/PUBS/CACMcols/cacmJul05.pdf)
is the deepest root of bring-data-close. Closest of all, Chris Richardson's
[command-side replica](https://microservices.io/patterns/data/command-side-replica.html)
weighs ten named forces — including, notably, both runtime *and* design-time
coupling.

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
and no platform answers authority, recoverability, or the admissibility gate
for you. The axes are how you evaluate the slide.

## One hypothesis, one exercise

The falsifiable version of this essay: **for integrations reviewed with this
template, the twelve-month rate of material redesign caused by an omitted
requirement should be lower than the team's historical rate for comparable
integrations.** "Material redesign" means the integration needed a new:
integration mode, persisted copy (or removal of one), upstream contract,
authority path, consistency mechanism, or privacy/retention model. Normalize
per reviewed integration, and note which axis the original review failed to
discuss; my prediction is that the missing axis predicts the failure class.

To be explicit about the evidence base: I have not found verified empirical
work scoring integration rework against the axis the review skipped. That
absence is why this is a hypothesis and not a finding.

The retrospective you can run today is stronger than the hypothesis: take
your last ten integration redesigns and, for each, name the requirement that
was absent from the original review. If it maps to an axis here, the
instrument would have caught it. If it doesn't map to any axis — that is
evidence this framework is missing one, and that is precisely what I want to
hear about.

## The instrument, ready to copy

"But the copy will be stale" is one row of a gated, six-row decision. Here
is the review template — paste it into the ADR:

```text
Integration decision:
Options considered:        [ call | projection | federation | hybrid ]

Admissibility gate (PER OPTION):
    may this consumer query / persist / derive from / retain the data?
    (granularity, purpose, residency, retention, entitlement)
Temporal fidelity:         max age, lag, cross-source skew;
                           coherence mechanism (watermark / skew bound / token)
Runtime & change coupling: behavior during provider failure;
                           blast radius of upstream schema/semantic change
Reasoning capacity:        questions answerable without upstream change;
                           history depth, joinable dimensions, lead time
Authority:                 who commits, via which owner-mediated path
Decision consequence &     cost of a wrong decision; detection;
recoverability:            correction (revalidate / compensate / review)
Economics & operability:   lifecycle cost of BOTH designs, incl. replay,
                           divergence repair, observability, on-call

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
