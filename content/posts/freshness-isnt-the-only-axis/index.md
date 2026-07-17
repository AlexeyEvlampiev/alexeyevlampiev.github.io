---
title: "Freshness Isn't the Only Axis: APIs, Projections, and Federated Queries"
date: 2026-07-17
draft: true
tags: ["Data Architecture", "Software Architecture", "Data Mesh", "Event-Driven Architecture", "Microservices", "API Design"]
summary: "Freshness is one requirement. Evaluate calls, projections, and federated queries across eight dimensions, including coherence, semantics, authority, and recovery."
cover:
  image: social-card.drawio.png
  alt: "Freshness is one requirement: time, semantics, runtime, change coupling, reasoning capacity, authority, consequence & recovery, lifecycle cost — the eight review dimensions of the call-versus-projection-versus-federation decision"
  relative: true
  hidden: true
ShowToc: true
TocOpen: false
---

*Part 2 of a series on data-first architecture. Part 1,
[Your Operational Data Is Someone Else's Reference Data](/posts/your-operational-data-is-someone-elses-reference-data/),
introduced role reversal: publish your reality, project theirs, join
locally. This essay turns that principle into a decision instrument.*

## Abstract

Freshness alone cannot determine an integration design. A fresh API response
may lack history, cross-source coherence, runtime independence, or the
authority required by the decision. This article defines an admissibility
gate and eight evaluation dimensions for calls, projections, federation, and
hybrid designs. It applies the instrument to a payments case that requires
three domains and twelve months of history. The result is hybrid: projections
support screening; an owner-controlled command performs the authoritative
action. The article also separates data age from temporal coherence and
defines **reasoning capacity** as the questions a design can answer without
an upstream contract change.

## The problem

Architecture reviews often reject a local projection with one sentence:
*"The copy will be stale. The API gives us current truth."*

This assumes that the owner's read path is current. It may use a replica,
cache, index, or materialized view. It also assumes that several calls
describe one coherent moment. Three fresh calls may describe three different
instants.

An API is often fresher fact by fact. That is one part of one dimension. This
essay defines the other dimensions and turns them into a review instrument.

## The question with no per-call answer

Keep the account-and-plan example from Part 1. Move the decision to payments.

The payments team must flag unusual spending. The rule compares this week
with a twelve-month baseline. It also considers recent account-state changes
and the applicable plan tier. The evidence spans three domains: transactions,
account standing, and plan catalog.

The per-entity implementation is a distributed query engine assembled from
meetings. Page through accounts. Call the standing service. Call the plan
service. Join the results in application code.

Each call may be fresh. The design still fails at large fan-out and during a
dependency outage.

It also fails when the question changes. Replace "current plan" with "plan at
the time of each transaction." Or ask whether standing changed twice in 90
days. A current-state endpoint cannot answer either question. The evidence is
historical, but the contract exposes only current state.

With projections, the decision becomes one SQL query over three tables. Two
are maintained from governed feeds. Both retain **effective-dated history**.
Plan-at-transaction-time becomes a historical join.

**The unit of design is the decision, not the transport.** Define its
evidence and the cost of being wrong. Freshness is then one requirement among
several.

## Four candidate types

The comparison uses four archetypes:

- **Call / composition** — retrieve evidence from the owners at decision
  time.
- **Projection** — maintain a consumer-queryable representation ahead of
  decision time.
- **Federation** — query owner-controlled sources through a shared query
  engine, without maintaining a consumer copy.
- **Hybrid** — different mechanisms for different stages of the same
  decision.

Bulk APIs, provider aggregates, caches, and shared-storage views may fall
between these types. Evaluate a concrete design. Do not score an integration
style in the abstract.

## Gate zero, then eight dimensions

Admissibility is a gate, not a trade-off. Apply it **to each candidate**.
Query, persist, derive, and retain are different permissions. A policy may
allow a call but prohibit a copy. It may allow seven days of retention but
prohibit historical reconstruction. It may allow a raw fact but prohibit a
derived risk class.

> **Gate zero — admissibility.** For this candidate: may the consumer query,
> persist, derive from, and retain the required data, at the proposed
> granularity, for the stated purpose? Consider residency, purpose
> limitation, tenant isolation, retention and erasure, and sensitive
> attributes.

The result is not always binary. A candidate may be inadmissible, admissible
with constraints, limited to an owner-mediated or federated read, or allowed
only as a minimized derived product.

After the gate, state the requirement for each dimension. Then record
evidence for every surviving candidate. The ADR template appears below.

| Dimension | The question to ask out loud | What to record |
|---|---|---|
| **Time** *(temporal fidelity)* | What maximum age, lag, and cross-source skew are acceptable? Is a coherent snapshot or causal order required — and how is it *produced*? | Max age / lag SLO, `as_of` visibility, coherence mechanism (completeness frontier, skew bound, snapshot token — see below) |
| **Semantics** *(semantic fidelity)* | Does the representation preserve the meaning, identity, completeness, and precision this decision requires? | Semantic owner, identifier mapping, units, completeness SLO, correction and deletion behavior |
| **Runtime** | What response latency, throughput, and availability does the decision need — and what must be healthy when it executes? | p95/p99 target, fan-out, dependency set, degraded behavior |
| **Change coupling** | Which upstream schema or semantic changes require coordinated work — and who coordinates? | Versioning policy, blast radius of a breaking change, teams and contracts affected |
| **Reasoning capacity** | Which decision-relevant question classes can this candidate answer from its data, history, and query contracts — without an upstream contract change? | Joinable dimensions and keys, granularity, history depth, past-state reconstruction; contract changes required for a new question |
| **Authority** | Who validates and commits the authoritative state transition? | The invariant's owner and the owner-mediated command path |
| **Consequence & recovery** | If stale, incomplete, or incoherent knowledge produces a wrong decision, what does it cost, what detects it, and what corrects it? | Revalidate-before-acting, compensation, human review; whether the action is advisory or an authoritative external transition |
| **Lifecycle cost** | What is the total lifecycle cost of this candidate, honestly counted? | Calls, egress, storage, pipelines, replay and divergence repair, observability, on-call |

![Freshness is one requirement — the eight review dimensions: time, semantics, runtime, change coupling, reasoning capacity, authority, consequence & recovery, lifecycle cost, behind the per-candidate gate-zero admissibility question.](social-card.drawio.svg)

**The dimensions are not votes.** A candidate meets a requirement, meets it
with a control, fails it, or is vetoed. Record decisive differences. Do not
count wins.

**Semantics asks whether an answer means the right thing. Reasoning capacity
asks whether the answer can be computed at all.**

If `active` means different things in two domains, semantics fail. If current
state is clear but history is absent, reasoning capacity is limited. If
identifiers are incompatible, both fail because the join is unavailable.

**Reasoning capacity is not intelligence or compute power.** It is the set of
questions supported by the available data and query contracts. A rich owner
API may provide high reasoning capacity without a local row.

## How to use it

1. Name the decision and its consequences.
2. Describe concrete candidate designs — not integration styles.
3. Apply the admissibility gate to each candidate.
4. State every requirement before assessing any candidate.
5. Record evidence, named controls, and failures per candidate.
6. Select by decisive differences, not vote count. Hybrid is a valid result.

## Apply it to the payments case

The payments case has three candidates:

- **API candidate:** the owners' existing current-state per-account
  endpoints; no bulk export, no history, no snapshot token.
- **Projection candidate:** effective-dated feeds from both owners onto the
  team's existing data platform; contracted lag ≤ 5 minutes, monitored.
- **Federation candidate:** live queries through a shared engine across
  three separately operated catalogs.

State the requirements before scoring. Evidence may be at most **5 minutes
old**. Frontier skew may not exceed **60 seconds**. The design must reconstruct
a historical cut and screen **all active accounts** during provider deploys.
It must retain **12 months** of standing and plan history. A flag is advisory
and reversible. An account freeze requires owner-side revalidation.

Apply gate zero to each candidate. The API needs query permission. Granted.
The projection needs persistence, derivation, and twelve-month retention.
Granted with row-level entitlement and retention clauses. Federation needs
query rights across three catalogs. Granted conditionally.

All three survive the gate. The decision's need for history does not itself
authorize a candidate to retain it.

| Dimension | Required here | API / composition | Projection | Federation |
|---|---|---|---|---|
| Time | Age ≤ 5 min; skew ≤ 60 s; coherent historical cut | Fresh current state; **no historical cut** | Meets: contracted, monitored age ≤ 5 min, skew ≤ 60 s, reconstructable cuts | Current reads; **no cross-source cut** |
| Semantics | Standing states mapped to review taxonomy | Owner-defined; consumer maps to taxonomy | Mapping recorded in the contract; corrections propagate | Owner-defined per source; consumer reconciles across catalogs |
| Runtime | Full fan-out screening during provider deploy windows | **Fails** availability at fan-out | Meets — local batch query | Needs every source + engine healthy |
| Change coupling | Survive upstream schema evolution | Shape insulated by endpoint; semantic changes still couple | Versioned feed + semantic contract; 90-day overlap | Source schemas and semantics exposed to the query |
| Reasoning capacity | Reconstruct 12 months of standing & plan history across 3 domains | **Requires two new contracts** | Already available | Only if sources expose history |
| Authority | Freezing must commit against the owner's invariant | Command path exists | Read-only — freeze goes via owner path | Read-only |
| Consequence & recovery | Flag reversible via review; freeze owner-revalidated | Human review; freeze via owner path | Flag on ≤ 5-min evidence acceptable; freeze via owner path | Human review; capture the evidence cut; freeze via owner path |
| Lifecycle cost | Recurring high-fan-out workload; decision logic changes quarterly | Call volume, rate limits, provider capacity | Feed, storage, replay, reconciliation, monitoring — on the existing platform | Engine + connector operation, egress, source load |

These results apply only to the candidates described above. An API with bulk
history or snapshot tokens would score differently. Governed federated views
would change the semantics result. Another projection could fail at runtime.
Always score concrete designs.

**The selected design is hybrid: projections for screening and an
owner-mediated command for action.** Reasoning capacity selects the read
path. Consequence and authority select the action path. Minutes-old evidence
is acceptable for a reversible flag. It is not acceptable for an account
freeze.

### Why this result is not doctrine

Change the decision and the result changes. A single-account invariant check
needs current state, low fan-out, and no history. Use the owner's API. A
quarterly investigation can wait for source recovery. Federation avoids a
dedicated pipeline.

This case selected a projection because it needed fan-out, history, and
availability during provider deploys. It did not select a projection because
copies are preferred.

**Lifecycle cost.** The result assumes an existing feed platform, high
fan-out, and quarterly logic changes. With one monthly consumer and no
platform, calls cost less.

**Authority.** A command path is a coordination requirement, not a transport.
It may be a synchronous API, queued command, or owner-mediated saga step. The
owner must validate and commit against its current invariant.

Federation is limited by connectors and pushdown. Under current [Trino
rules](https://trino.io/docs/current/optimizer/pushdown.html), a cross-catalog
join cannot be pushed into either source. The engine retrieves source results
and performs the join. This works for occasional, freshness-sensitive
analysis. It does not work for an always-on path that must survive source
outages.

## Age is not coherence

The framework is complete. The next sections explain time and reasoning
capacity. Skip to [the instrument](#the-instrument-ready-to-copy) if you only
need the template.

Staleness discussions often mix three guarantees: source age, cross-source
coherence, and proof of what a decision included.

A local transaction sees *one committed state of the projection*. It does
not guarantee one business instant. Account standing may be from 10:03 and
plan tier from 10:07. Reading both in one transaction does not align them.
An `as_of` column exposes the mismatch but does not remove it. Coherence needs
an explicit rule:

```text
decision_cutoff = min(transaction_frontier,
                      standing_frontier,
                      plan_frontier)
maximum permitted frontier skew: 60 seconds
```

Each source must state: *"I have delivered everything originally observed up
to 10:03."* This is a **completeness frontier**. It is a contract that no
future delivery will extend the original event stream at or before *t*.

A correction tomorrow is a new record-time fact about an earlier effective
state. It does not change what the system knew yesterday. The term comes from
[dataflow systems](https://timelydataflow.github.io/timely-dataflow/chapter_2/chapter_2_4.html),
where a frontier constrains future timestamps. This differs from estimated
[watermarks](https://beam.apache.org/documentation/basics/) such as Beam's.

Two practical warnings:

- `max(event_time)` is an observation, not a completeness frontier —
  treating it as one manufactures false coherence.
- The `min` of several frontiers is meaningful only when the sources share
  a time domain and equivalent completeness semantics.

The *common cut* is the minimum frontier. It makes a coherent read
reconstructable. Its age defines freshness. The difference between frontiers
defines skew. A cut can be coherent and still be too old.

A coherent cut is not necessarily a *reproducible decision*. Effective time
records what we now believe was true at *t*. Record time captures what the
decision knew when it acted. A later correction may change a reconstructed
answer.

For defensible decisions, retain both dimensions as [bitemporal
history](https://martinfowler.com/articles/bitemporal-history.html), or store
the exact evidence used. This connects time with consequence and recovery.

A current-state projection cannot reconstruct a prior cut. Without
coordinated ingestion, it also cannot prove a coherent current cut.

APIs can provide coherence through snapshot tokens, versioned reads, or
provider-side composition. The question is not API versus projection. The
question is whether the design has an explicit coherence mechanism. Most
per-call compositions do not.

A change feed is not that mechanism by itself. It moves changes and may
expose order. It does not align several sources, preserve required history,
align meaning, or establish admissibility.

## Reasoning capacity

**Can this design answer tomorrow's question without an upstream interface
change?** Reasoning capacity is the set of decision-relevant questions
supported by the available data, history, and query contracts.

The definition is neutral across candidates. Locality is not part of it.
Measure available fields, keys, grain, history, and reconstructability. Also
count upstream contract changes per new question. Latency, availability, and
cost remain separate dimensions.

A call may make a question expressible but operationally impractical.
Federation exposes exactly what connected sources provide. It may be broad
for current state and empty for history. A projection can make more questions
available without contract changes. With effective-dated data, plan at
transaction time can be answered immediately.

Without an expressive data or query contract, the consumer can ask only what
the provider anticipated.

The diagram shows the **projection case**. It places reference knowledge and
operational reality in one computational boundary:

![The local intersection — the projection case: reference knowledge (green, left — other domains' published state, shared facts, classifications, aggregates, policies) and operational reality (amber, right — transactions, events, measurements, workflow state) both flow into a central box — the local intersection, the consumer's reasoning capacity — where joins, aggregation, inference, screening, optimization and prediction happen, inside one computational boundary.](local-intersection.drawio.svg)

## The instrument, ready to copy

"The copy will be stale" is one row in the decision. Paste this template into
the ADR:

```text
Integration decision:
Candidate designs:         [ call | projection | federation | hybrid ]
                           (describe each concretely — not as a style)

FOR EACH CANDIDATE:
    Admissibility gate:    may this consumer query / persist / derive from /
                           retain the data? (granularity, purpose, residency,
                           retention, entitlement)
    Evidence by dimension:
        Time:                  age, lag, skew; coherence mechanism
                               (completeness frontier / skew bound / token);
                               effective vs record time if corrections occur
        Semantics:             meaning, identity mapping, units, completeness;
                               corrections & deletions; semantic owner
        Runtime:               p95/p99, throughput, fan-out; dependency set;
                               degraded behavior
        Change coupling:       versioning policy; blast radius of upstream change
        Reasoning capacity:    question classes answerable without upstream
                               change; history depth, joinable keys & grain
        Authority:             who commits, via which owner-mediated path
        Consequence &          cost of a wrong decision; detection; correction
        recovery:              (revalidate / compensate / review); advisory vs
                               authoritative action
        Lifecycle cost:        calls, egress, storage, pipelines, replay,
                               divergence repair, observability, on-call
    Unmet requirements:
    Required controls:
    Vetoed by:

Chosen design (may be hybrid — read path and action path can differ):
Decisive differences (not vote counts):
Assumptions to verify:
```

## Prior work

Three references carry most of the lineage. Pat Helland defined the temporal
boundary in [2005](https://www.cidrdb.org/cidr2005/papers/P12.pdf): data that
crosses a service boundary is from the past. Joining another service's
transaction also gives up independence.

The local read model appears in CQRS, Fowler's [event-carried state
transfer](https://martinfowler.com/articles/201701-event-driven.html), and
Chris Richardson's [command-side
replica](https://microservices.io/patterns/data/command-side-replica.html).
Richardson separates runtime from design-time coupling. This instrument keeps
that distinction.

Reasoning capacity is often missing from review templates. [Azure's data
guidance](https://learn.microsoft.com/en-us/azure/architecture/microservices/design/data-considerations)
discusses query-shaped materialized views and different query requirements.
It does not name the range of future questions available without upstream
change as a separate dimension. The same omission appears in many reviews.

**Further reading:** Kleppmann's
[inside-out architecture](https://martin.kleppmann.com/2015/11/05/database-inside-out-at-oredev.html) ·
the [unbundled database](https://www.confluent.io/blog/leveraging-power-database-unbundled/) ·
Denning's [locality principle](https://denninginstitute.com/pjd/PUBS/CACMcols/cacmJul05.pdf) ·
[Lakebase](https://docs.databricks.com/aws/en/oltp/) synced tables. Products
can address some dimensions. Semantics, authority, recovery, and admissibility
remain architecture decisions.

## Conclusion

Freshness measures evidence age. It does not establish meaning, coherence,
reasoning capacity, availability, authority, or recoverability. A fresher
candidate can still be the wrong design.

Evaluate concrete candidates against explicit requirements. Apply
admissibility first. Then record evidence for all eight dimensions. Choose
the evidence path and the action path separately. In the payments example,
projections support broad historical screening. An owner-controlled command
protects the authoritative transition.

Test the instrument against your last ten integration redesigns. Name the
requirement that the original review missed. If it maps to a dimension here,
the instrument had a place to expose it. If it does not, the framework is
missing a dimension.

---

*This is Part 2 of a series on data-first architecture. [Part
1](/posts/your-operational-data-is-someone-elses-reference-data/) introduced
role reversal. Later essays cover composite products, models as executable
knowledge, and AI agents that consume governed context.*

Which dimension is missing from your review template? What did the omission
cost? I am especially interested in cases where a projection was wrong.
