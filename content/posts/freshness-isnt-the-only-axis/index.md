---
title: "Freshness Isn't the Only Axis: Choosing Between APIs and Local Projections"
date: 2026-07-17
draft: true
tags: ["Data Architecture", "Software Architecture", "Data Mesh", "Event-Driven Architecture", "Microservices", "API Design"]
summary: "Choosing between an API, a local projection, or a federated query takes more than freshness. A per-option admissibility gate and seven explicit forces make the trade-off reviewable."
cover:
  image: social-card.drawio.png
  alt: "Freshness is one requirement: time, semantics, runtime and change coupling, reasoning capacity, authority, recoverability, lifecycle cost — the axes of the API-versus-projection decision"
  relative: true
  hidden: true
ShowToc: true
TocOpen: false
---

<!-- STATUS: draft R4 (2026-07-17) — fourth review round applied: baseline-change
     example fixed (now requires provider HISTORY — plan-tier-at-transaction-time;
     feeds stated as effective-dated); SEMANTIC FIDELITY added as 7th axis
     (table, walkthrough, template, social card); runtime row captures
     decision-time performance; saga wording corrected; retrospective causal
     claim weakened + hypothesis reframed as prospective operational test;
     reasoning capacity intrinsic (lead time out of definition, contract-changes
     in); "collapses" sentence conditioned on contract expressiveness;
     coherence/history sentence made necessary-not-sufficient + watermark
     defined; federation conclusion made contextual ("in this example");
     lineage compressed to 3 core refs + further-lineage note; why-now folded
     to 2 sentences; template callout added after table; diagram title
     "Cross-domain value…"; card = 7 pills + per-option gate wording.
     MANDATORY before publication: Essay-1-reception revision round.
     TODO: final date; series taxonomy after AGP-7; LTAP/Lakebase + Trino
     re-check at publication; optional re-verify empirical papers.
     Channel-kit note: LinkedIn alt headline "Your API is fresh. Your decision
     may still be incoherent." -->

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
changes "current plan tier" to "**plan tier at the time of each
transaction**" — or asks whether an account's standing changed twice in the
preceding ninety days. No current-state endpoint can answer either question,
however fresh: the answers live in the *history* of another domain's data,
and the provider's interface never promised history.

There are better API-side designs, and each is a different position in the
trade space this essay maps: a bulk endpoint improves the economics but not
the space of askable questions; a provider-side query endpoint moves the
computation without freeing it from the provider's contract; a purpose-built
aggregate answers exactly one anticipated question well; a cached composition
buys latency at the price of the very staleness the API was chosen to avoid.

The projection version is one SQL query over three local tables, two of them
maintained by governed feeds from the owning domains — feeds that retain
standing and plan changes as **effective-dated history**, not only
current-state upserts. Plan-tier-at-transaction-time becomes a join against
that history. Nobody at the review said out loud that the choice was between
*fresh-per-call-but-narrow* and *minutes-old-but-able to answer the
unanticipated questions the projected schema and history permit*. Freshness
got a sentence; the rest of the decision got none.

## Gate zero, then seven axes

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

Past the gate, seven axes. For each integration, ask seven questions and
record seven answers. (A complete, copyable ADR template appears at the end
of this essay.)

| Axis | The question to ask out loud | What to record |
|---|---|---|
| **Temporal fidelity** | What maximum age, lag, and cross-source skew are acceptable? Is a coherent snapshot or causal order required — and how is it *produced*? | Max age / lag SLO, `as_of` visibility, coherence mechanism (watermark, skew bound, snapshot token) |
| **Semantic fidelity** | Does the representation preserve the meaning, identity, completeness, and precision this decision requires? | Semantic owner, identifier mapping, units, completeness/quality SLO, correction and deletion behavior |
| **Runtime behavior & change coupling** | What response latency, throughput, and availability does the decision need — what must be healthy at decision time — and which upstream schema or semantic changes require coordinated work? | p95/p99 target, fan-out, dependency set, degraded behavior; teams and contracts affected by a breaking change |
| **Reasoning capacity** | Which questions and derivations are supported by the data, history, and contracts already available — without an upstream contract change? | Joinable dimensions and keys, granularity, history depth, past-state reconstruction; upstream contract changes required for a new question |
| **Authority** | Who validates and commits the authoritative state transition? | The invariant's owner and the owner-mediated command path |
| **Decision consequence & recoverability** | If stale, incomplete, or incoherent knowledge produces a wrong decision, what does it cost, what detects it, and what corrects it? | Revalidate-before-acting, compensation, human review, or irreversible external effect |
| **Economics & operability** | What is the total lifecycle cost of each design, honestly counted? | Calls, egress, storage, pipelines, replay and divergence repair, observability, on-call |

And one instruction for using the table: **the axes are not votes.** Do not
count which option wins the most rows. Admissibility and authority can veto
a design outright; the other rows optimize among the designs that remain
feasible. The table is a set of questions that must be answered on the
record — not a scorecard.

Semantic fidelity earns its row for an uncomfortable reason: a fact can be
fresh, coherent, admissible, and locally joinable — and still wrong for the
decision, because `active` means different things in two domains, because
keys identify accounts at different levels, because a transformation dropped
a distinction the decision needed, or because deletions never arrived. A
coherent snapshot of semantically incompatible data is *coherently wrong* —
and the first essay's rule that the producing domain owns the semantics is
what this row enforces at review time.

## Temporal fidelity: age is not coherence

The first row hides the subtlest distinction in the whole decision — and the
first essay's shorthand, "freshness," covered only part of it.

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

A watermark here is a *source progress guarantee* — a statement of how far
the source's event-time history is complete, subject to the contract's
late-correction policy. It is not merely the latest timestamp observed;
`max(event_time)` is not a watermark, and treating it as one manufactures
false coherence.

Retained history makes an earlier coherent cut *reconstructable* — but only
when combined with those progress guarantees, effective-time semantics, and
an explicit correction policy. Projections holding only current-state
upserts cannot reconstruct any earlier cut at all — a direct link between
this row and reasoning capacity.

The same honesty cuts the other way: APIs can support coherence too, through
snapshot tokens, version-bound reads, or provider-side composition. The
trade is not "API incoherent, projection coherent." It is whether the chosen
design *has an explicit coherence mechanism* — most per-call compositions
silently have none.

## Reasoning capacity

**Reasoning capacity is the set of questions and derivations supported by
the data, history, and contracts already available to the consumer — without
an upstream contract change.**

It is a property of the available information space, and it is measurable on
its own terms: which fields and dimensions are present; which join keys and
identifiers are compatible; at what granularity; how deep the history is,
and whether past state can be reconstructed; which transformations are
permitted; and — the operational tell — how many upstream contract changes a
new question requires. Latency, availability, and cost constrain what is
*practical*; they live in their own rows. Lead time from a new question to a
production answer is then an observed *consequence* of reasoning capacity
and change coupling together — worth tracking, but not part of the
definition.

The contrast with the per-call design is then precise: **a call can make a
question logically expressible while the composition needed to answer it is
operationally out of reach; a projection expands the set of questions
answerable without renegotiating any upstream contract.** When the relevant
projections are local — with their history — the application can answer
plan-tier-at-transaction-time the same afternoon it is asked. Without a
sufficiently expressive data or query contract, the feasible-question set
collapses to what the provider anticipated when the interface was designed.

![The local intersection: reference knowledge (green, left — other domains' published state, shared facts, classifications, aggregates, policies) and operational reality (amber, right — transactions, events, measurements, workflow state) both flow into a central box — the local intersection, the consumer's reasoning capacity — where joins, aggregation, inference, screening, optimization and prediction happen, inside one computational boundary.](local-intersection.drawio.png)

## Walking the table

Run the payments example through the gate and the seven axes — in the shape
the review record should take:

| Row | Evidence | Effect on the decision |
|---|---|---|
| Admissibility | Standing may be retained at account granularity for fraud-adjacent review, tenant-isolated, per the feed contract | Projection feasible, with constraints on the record |
| Temporal fidelity | Minutes-old acceptable (baseline is twelve months deep); common watermark + 60s skew bound adopted | Projection feasible — coherence mechanism named |
| Semantic fidelity | Standing states mapped to the review taxonomy by the owning domain; shared account identifiers; corrections and deletions flow through the feed | Projection feasible — semantics owned upstream, per contract |
| Runtime behavior | Screening is a batch path — minutes-scale latency acceptable at full fan-out; must run during the standing service's deploy window | Favors projection |
| Change coupling | Standing schema versioned, additive changes, 90-day overlap on breaking ones | Manageable projection risk — on the record |
| Reasoning capacity | Query reshaped quarterly; needs effective-dated standing and plan history joined across three domains | Strongly favors projection |
| Authority | Flagging commits nothing against anyone's invariant | Projection permitted for the *read* |
| Consequence & recoverability | A flag is reviewable and reversible — human review detects and corrects; freezing or debiting would be irreversible | Projection for flagging; owner-mediated path for freezing |
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
the owner-mediated command path — the coordination mechanism may be a
synchronous API, a queued command, or an owner-mediated step within a saga;
the architectural requirement is that the owning domain validates and
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
provide. **Semantic fidelity:** the engine joins whatever the connectors
expose; identifier and unit mismatches between sources become the
consumer's silent problem. **Runtime behavior:** the decision path is
coupled to every queried source *and* to the federation engine itself — the
dependency set grows, and so does tail latency. **Change coupling:** every
source schema is now part of the consumer's query surface.
**Reasoning capacity:** broad, bounded by connector coverage and pushdown —
under current
[Trino rules](https://trino.io/docs/current/optimizer/pushdown.html), a
cross-catalog join cannot be pushed into either source, so the engine
retrieves source-side results and joins them itself. **Authority:**
unchanged — federation reads; it commits nothing. **Consequence &
recoverability:** without source snapshot identifiers, watermarks, or
retained query inputs, the same federated query may not be reproducible
later. **Economics:** per-query and conditional — "often" a cost reduction,
say the vendors' own docs, choosing the adverb carefully. **And the gate:**
policy and identity must translate across every federated source.

In this example, federation earns its place for interactive, occasional,
freshness-hungry analysis — and loses it for an always-on path required to
survive provider outages. Under different requirements the rows can land
differently; that is the instrument producing a contextual conclusion
rather than a doctrine.

## Whose shoulders, briefly

Three references carry most of the lineage. Pat Helland fixed the temporal
endpoints in [2005](https://www.cidrdb.org/cidr2005/papers/P12.pdf): data
crossing a service boundary "is always from the past," and joining another
system's transaction is "a serious ceding of independence." The local read
model itself is well-trodden — CQRS, Fowler's
[event-carried state transfer](https://martinfowler.com/articles/201701-event-driven.html),
and, closest of all, Chris Richardson's
[command-side replica](https://microservices.io/patterns/data/command-side-replica.html),
which weighs ten named forces including both runtime *and* design-time
coupling. And Daniel Abadi's
[PACELC](https://www.cs.umd.edu/~abadi/papers/abadi-pacelc.pdf) is the
precedent for this essay's whole move: he extended CAP because it "does not
constrain any system capabilities during normal operation" — a famous
framework, missing the axis that operates all the time.

What I have not found — in those sources, in
[Azure's data guidance](https://learn.microsoft.com/en-us/azure/architecture/microservices/design/data-considerations)
("no single approach works for all cases," with query capability appearing
only as a benefit sentence), or elsewhere I have checked — is a compact
instrument for comparing calls, projections, and federation in which *the
set of questions feasible without upstream change* is itself named and
evaluated. Whether this table is the first hardly matters; what matters is
whether putting that row on the review changes decisions. (Further lineage,
for the curious: Kleppmann's
[inside-out architecture](https://martin.kleppmann.com/2015/11/05/database-inside-out-at-oredev.html),
the [unbundled-database](https://www.confluent.io/blog/leveraging-power-database-unbundled/)
materialized-views-everywhere argument, and Denning's
[locality principle](https://denninginstitute.com/pjd/PUBS/CACMcols/cacmJul05.pdf).)

Vendors, meanwhile, are productizing the projection step — Databricks'
[Lakebase](https://docs.databricks.com/aws/en/oltp/) synced tables, an
announced "[LTAP](https://www.databricks.com/company/newsroom/press-releases/databricks-launches-ltap-first-lake-transactionalanalytical)"
category promising single-copy transactions and analytics, coming soon.
Every such pitch is implicitly a position on a few of these axes; none
answers semantics, authority, recoverability, or the gate for you.

## One prospective test, one retrospective exercise

The falsifiable version of this essay is a **prospective operational test**,
not a claim a retrospective can settle: record assumptions and unresolved
risks in each new integration ADR; follow each integration for twelve
months; record material redesigns — where "material" means the integration
needed a new integration mode, persisted copy (or removal of one), upstream
contract, authority path, consistency mechanism, or privacy/retention
model; map each redesign to the omitted, misunderstood, or changed
requirement; and compare against a defined class of the team's historical
integrations. My prediction: the reviewed cohort shows a lower rate, and
the axis missing from the original review predicts the failure class. To be
explicit about the evidence base: I have not found verified empirical work
on this question — which is why it is a hypothesis and not a finding.

The retrospective you can run today is humbler but immediate: take your
last ten integration redesigns and, for each, name the requirement that was
absent from the original review. If it maps to an axis here, the instrument
had an explicit place where that requirement could have been raised. If it
doesn't map to any axis — that is evidence this framework is missing one,
and that is precisely what I want to hear about.

## The instrument, ready to copy

"But the copy will be stale" is one row of a gated, seven-row decision.
Here is the review template — paste it into the ADR:

```text
Integration decision:
Options considered:        [ call | projection | federation | hybrid ]

Admissibility gate (PER OPTION):
    may this consumer query / persist / derive from / retain the data?
    (granularity, purpose, residency, retention, entitlement)
Temporal fidelity:         max age, lag, cross-source skew;
                           coherence mechanism (watermark / skew bound / token)
Semantic fidelity:         meaning, identity mapping, units, completeness;
                           correction & deletion behavior; semantic owner
Runtime behavior &         p95/p99, throughput, fan-out; dependency set and
change coupling:           degraded behavior; blast radius of upstream change
Reasoning capacity:        questions answerable without upstream change;
                           history depth, joinable dimensions & keys
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
