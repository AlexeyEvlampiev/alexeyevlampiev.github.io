---
title: "Freshness Isn't the Only Axis"
date: 2026-07-17
draft: true
tags: ["Data Architecture", "Software Architecture", "Data Mesh", "Event-Driven Architecture", "Microservices", "API Design"]
summary: "Every projection-versus-API debate fixates on staleness. Six axes actually decide the outcome — and the one that decides the most, reasoning capacity, is the one nobody puts on the whiteboard."
ShowToc: true
TocOpen: false
---

<!-- STATUS: draft R1 (2026-07-17) — dedicated research audit applied (run
     wf_942899a7-681 + manual Richardson check; report:
     pgmi repo .private/research/essay2-trade-space-2026-07-17.md). Claims
     narrowed per verdict; PACELC/Denning/Azure/Richardson/federation/arXiv
     citations installed. MANDATORY before publication: revision round folding
     in Essay 1's launch reception. TODO: re-verify session-limit casualties
     (arXiv 2604.00715 sub-claims; empirical rework papers 2302.01894 +
     1908.04101) OR keep hypothesis hedged as-is; social card; diagram DONE;
     final date; series taxonomy after AGP-7 naming gate; LTAP/Lakebase +
     Trino-pushdown status re-check at publication (version-sensitive). -->

Every architecture review of a data integration reaches the same moment.
Someone proposes keeping a local copy of another domain's data, and someone
else says the sentence that ends the discussion: *"But the copy will be
stale. The API gives us the current truth."*

The sentence is true. It is also one-sixth of the decision, and usually the
least important sixth. Freshness is simply the axis that is easiest to say
out loud — it fits in one sentence and sounds like rigor. The axes that
actually decide whether the system can do its job get no airtime, because
they don't have a one-word name on the whiteboard.

This essay gives them names. It is the second in a series; the
[first](/posts/your-operational-data-is-someone-elses-reference-data/) argued
that operational and reference are roles a dataset plays, not properties, and
that the publish → refine → project → join-locally loop deserves first-class
status. This one takes the trade at the center of that loop and makes it
explicit — all six axes of it.

## The question that has no fresh answer

Start with why "the API gives us current truth" so often wins the argument
and loses the system.

A payments team is asked to flag accounts whose spending pattern this week
diverges from their twelve-month baseline *and* whose account standing
changed recently *and* whose plan tier makes the divergence commercially
significant. Three domains: transactions (theirs), account standing
(another team's), plan catalog (a third team's).

The API-first version of this feature is a distributed query engine
assembled from meetings: page through accounts, call standing for each, call
the plan service, join in application code, hope the rate limiter is
generous. It is fresh — every fact is seconds old — and it is unbuildable
past a few thousand accounts, unrunnable during a dependency's incident, and
frozen the moment the product manager changes "twelve-month baseline" to
"same-quarter-last-year baseline," because that's a different endpoint
conversation.

The projection version is one SQL query over three local tables, two of them
maintained by governed feeds from the owning domains. Its facts are minutes
old. Nobody at the review said out loud that the choice was between
*fresh-and-unable-to-answer* and *minutes-old-and-able to answer anything in
the joined space*. Freshness got a sentence; the reasoning space got none.

## The six axes

The manifesto behind this series states the trade as a table, and the table
is the practical takeaway of this essay — the thing to bring to Monday's
review. For each integration, ask six questions:

| Axis | The question to ask out loud |
|---|---|
| **Freshness** | How current must this data be *for this decision*? Seconds, minutes, hours, and days are all legitimate answers with different costs. |
| **Coupling** | Must the consumer keep working when the producer or the network is degraded? A projection keeps answering from the last accepted state; a call chain does not. |
| **Reasoning capacity** | Does the consumer need a point answer to an anticipated question, or the ability to join, aggregate, and infer over a multidimensional space — including for questions nobody has asked yet? |
| **Authority** | May this decision act on a projection, or must it be committed against the owner's current invariant? Reserving stock is not the same as analyzing stock levels. |
| **Reconciliation risk** | When a stale projection produces a decision the source's later state contradicts, what corrects it — compensation, revalidation, tolerance? If the answer is "that can't happen," the design isn't finished. |
| **Economics** | Is continuous replication and storage cheaper than repeated remote computation, bespoke endpoints, and the engineering time of request choreography? Count all of it, both sides. |

Several of these axes have distinguished ancestry — they are inherited, not
discovered here. Pat Helland established the endpoints of the freshness axis
in [2005](https://www.cidrdb.org/cidr2005/papers/P12.pdf): any data that
crosses a service boundary "is always from the past" — the only choice is how
far past, and whether the bound is explicit. He also grounded the coupling
axis: participating in another system's transaction means holding its locks,
"a serious ceding of independence." Daniel Abadi's
[PACELC](https://www.cs.umd.edu/~abadi/papers/abadi-pacelc.pdf) made the
replication half formal in 2012: "as soon as a DDBS replicates data, a
tradeoff between consistency and latency arises" — present at all times,
partition or no partition. And mainstream vendor guidance names the authority
axis outright:
[Azure's integration guidance](https://learn.microsoft.com/en-us/azure/architecture/microservices/design/data-considerations)
describes one service as "the source of truth for a given entity" while
others hold eventually consistent copies.

What none of that lineage carries as a *decision axis* is the third row of
the table — and it is the one that decided the payments example.

## Reasoning capacity, defined

Reasoning capacity is the range of distinctions, inferences, and products an
application can construct from the knowledge available inside its own
boundary. It is a property of the *data plane*, not the code: given what
this application can join, aggregate, index, and iterate over locally, what
questions is it physically able to answer?

The local intersection — reference knowledge and operational reality,
jointly queryable inside one boundary — is where that capacity lives. When
the relevant projections are local, the application can join months of its
own events with other domains' published state, build intermediate results,
and answer next week's question without another team's roadmap being
involved. When they are not, its reasoning space collapses to the questions
some provider anticipated when the contract was written.

![The local intersection: reference knowledge (green, left — other domains' published state, shared facts, classifications, aggregates, policies) and operational reality (amber, right — transactions, events, measurements, workflow state) both flow into a central box, the local intersection, where joins, aggregation, inference, validation, optimization and prediction happen — the primary locus of application value, inside one computational boundary.](local-intersection.drawio.png)

An analogy I find clarifying, offered as an analogy and nothing more: a
large language model's weights are not a database, but they are a local
knowledge space, and the model's capacity to draw distinctions is a function
of what that space contains. A model with no parameters can produce only
constants. An application stripped of locally computable reference knowledge
is in a similar position: it can echo what it observes, and it can relay
point answers it was anticipated to need — but it cannot *conclude* anything
that requires the intersection.

The analogy has recently acquired a formal cousin: an April 2026
[preprint](https://arxiv.org/abs/2604.00715) fits scaling laws for exactly
this split in ML systems — knowledge held in model weights versus knowledge
retrieved at inference time, competing under a fixed budget. Transferring
that axis to integration decisions is my own move; but the trade itself is
no longer merely rhetorical.

That is why the decision rule from the first essay put "questions evolve
unpredictably" on the projection side. Unpredictable questions are not an
edge case; they are what product development *is*. An axis that measures the
ability to answer them belongs in the review, with a name, next to
freshness — not smuggled in later as "flexibility."

## What this is not claiming

The mechanism here is old, and pretending otherwise would be both wrong and
unnecessary. Maintaining query-shaped derived state near the consumer is
CQRS's read model; moving state to recipients so they need not call the
source is Fowler's
[event-carried state transfer](https://martinfowler.com/articles/201701-event-driven.html);
by [2017 the "unbundled database" literature](https://www.confluent.io/blog/leveraging-power-database-unbundled/)
was explicitly placing continuously updated materialized views inside
consuming services — "materialised views can be placed anywhere." Martin
Kleppmann, whose
["turning the database inside out"](https://martin.kleppmann.com/2015/11/05/database-inside-out-at-oredev.html)
popularized log-plus-derived-views, himself framed the whole family as
continuous with event sourcing and CQRS — different fields using different
vocabulary for the same thing.

So the claim is emphatically not "local derived state is new." The claim is
narrower, and I checked it against the places a decision framework would
actually live.
[Azure's data-considerations guidance](https://learn.microsoft.com/en-us/azure/architecture/microservices/design/data-considerations)
opens with "No single approach works for all cases" and offers guideline
prose; its one gesture at query capability — build "a materialized view of
the data that's more suitable for querying" — appears as a benefit sentence,
never as something to weigh. Chris Richardson's
[command-side-replica pattern](https://microservices.io/patterns/data/command-side-replica.html)
goes furthest: he evaluates it against his named "dark energy / dark matter"
forces — ten of them, from team autonomy to runtime coupling — genuine
structured evaluation, applied to one pattern in isolation, with no
replica-versus-query matrix and nothing resembling reasoning capacity among
the forces. Kleppmann's talk enumerates overlapping *benefits*: simpler code,
scalability, robustness, latency, flexibility. Even Peter Denning's
[locality principle](https://denninginstitute.com/pjd/PUBS/CACMcols/cacmJul05.pdf)
— the deepest root of "bring data close to the process" — is deliberately a
one-axis rule.

The pattern across all of them: the axes exist *scattered* — as guideline
bullets, force lists, and benefit sentences — and no source I have checked
assembles them into one instrument for this decision, with reasoning
capacity weighed as a first-class axis. There is respectable precedent for
exactly this kind of complaint: Abadi built PACELC on the observation that
CAP "does not constrain any system capabilities during normal operation" — a
famous framework, missing the axis that operates all the time. That is the
shape of what I am claiming about the projection-versus-API debate: the
operative axis is missing from the force lists.

Six questions, asked explicitly, produce a defensible decision. One
question, asked rhetorically, produces whatever the loudest person already
wanted.

## Walking the table

Run the payments example through all six axes, quickly:

**Freshness:** the divergence analysis tolerates minutes-old standing data —
the baseline itself is twelve months deep. *Projection is fine; say the
bound out loud and write it in the contract.* **Coupling:** the flagging job
must run during the standing service's deploy window. *Projection.*
**Reasoning capacity:** the query joins three domains and will be reshaped
every quarter. *Projection, decisively.* **Authority:** flagging an account
for review commits nothing against another domain's invariant. *No API
needed for the analysis* — though the follow-up action (freezing an account)
absolutely goes through the owner's API. **Reconciliation:** an account
flagged on stale standing gets unflagged at review time; the correction path
is cheap and human. **Economics:** two governed feeds versus a bespoke
fan-out client plus its rate-limit negotiations — the feeds win before the
first incident is counted.

Six axes, one paragraph, and the decision explains itself to the next
reviewer. That is the entire proposal: not a new mechanism, a named trade
space — so the argument happens on the record instead of by slogan.

The same instrument works in reverse. Reserve inventory? Authority says API,
full stop, and no amount of reasoning-capacity enthusiasm overrides it.
Display a customer's current balance in their banking app? Freshness
dominates and the owner's read API is exactly right. The table is not a
projection advocacy device; it is what keeps *both* sides honest.

## The third option, on the same axes

Federated query engines — Trino, Starburst, the data-virtualization family —
promise the tempting middle: cross-domain joins with no local copies. The
promise is real, and so are its documented terms: predicate pushdown is
connector-specific, and
[join pushdown requires the joined tables to share a catalog](https://trino.io/docs/current/optimizer/pushdown.html)
— which means the genuinely cross-domain join, the one this essay cares
about, executes by pulling data into the engine at query time. Federation
doesn't escape the trade space; it takes its own position in it. Freshness:
excellent — facts are read live. Reasoning capacity: good — SQL over
everything the connectors reach. But the coupling row *inverts*: the decision
now requires every source system healthy at query time, which is the
projection's coupling profile turned inside out. And economics become
per-query and conditional — "often" a cost reduction, say the vendors'
own docs, choosing the adverb carefully.

Run federation through the six questions and it earns its place for
interactive, occasional, freshness-hungry analysis — and loses it for the
always-on decision path that must survive a provider's bad day. The
instrument doesn't pick sides; it prices them.

## Why this is worth naming now

The projection step is being productized aggressively. Databricks'
[Lakebase](https://docs.databricks.com/aws/en/oltp/) ships governed synced
tables into a managed Postgres (freshness floor around fifteen seconds —
low-latency reads, not real-time data), and its
["LTAP" announcement](https://www.databricks.com/company/newsroom/press-releases/databricks-launches-ltap-first-lake-transactionalanalytical)
promises transactions and analytics "on a single copy of storage" — coming
soon, category first, product second. Snowflake's sharing is zero-copy
within a region. Every one of these pitches is, implicitly, a position on
the six axes — single-copy claims target the economics row; sync latencies
are the freshness row; none of them can answer the authority or
reconciliation rows for you.

Which is precisely why the trade space needs to live in *your* review
template rather than in a vendor's slide: the axes are how you evaluate the
slide.

## One hypothesis

The falsifiable version of this essay: **teams that score integrations
against an explicit multi-axis trade space will show a lower rate of
integration-regret rework** — projections torn out for reconciliation
surprises, API choreographies rebuilt as projections after the third
unanswerable question — **than teams whose reviews argue freshness alone.**
Measure reworked integrations per year and which axis the original review
failed to discuss. My prediction is that the missing axis predicts the
failure class.

To be explicit about the evidence base: I have not found verified empirical
work that scores integration rework against the axis the review skipped.
That absence is why this is a hypothesis and not a finding — and why real
counterexamples are worth more to me than agreement.

## The one-line version

"But the copy will be stale" is one row of a six-row decision. Put freshness,
coupling, reasoning capacity, authority, reconciliation, and economics on the
whiteboard by name, and the projection-versus-API argument turns from a
slogan contest into an engineering decision.

*This is the second essay in a series on data-first architecture. The
[first](/posts/your-operational-data-is-someone-elses-reference-data/)
introduced role reversal — publish your reality, project theirs, join
locally. The next one asks what happens when the consumer doing the
reasoning is not a team but an AI agent.*

Which axis is missing from your architecture-review template — and what did
its absence cost you? Real stories, especially ones where a projection was
the wrong call, are exactly what I'm collecting.
