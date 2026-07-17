---
title: "Freshness Isn't the Only Axis"
date: 2026-07-17
draft: true
tags: ["Data Architecture", "Software Architecture", "Data Mesh", "Event-Driven Architecture", "Microservices", "API Design"]
summary: "Every projection-versus-API debate fixates on staleness. Six axes actually decide the outcome — and the one that decides the most, reasoning capacity, is the one nobody puts on the whiteboard."
ShowToc: true
TocOpen: false
---

<!-- STATUS: draft R0 (2026-07-17). Essay 2 of the series (AGP-4). Review rounds
     pending. MANDATORY before publication: revision round folding in Essay 1's
     launch reception (reader counterexamples feed this essay's trade-space
     treatment directly — user accepted early drafting on this condition).
     TODO: diagram gate (three-box intersection, purpose-built, essay-1 palette);
     social card; Essay 1 canonical link verify; final date; series taxonomy
     after AGP-7 naming gate; LTAP/Lakebase status re-check at publication. -->

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

Two of these axes have distinguished ancestry. Pat Helland established the
endpoints of the freshness axis in
[2005](https://www.cidrdb.org/cidr2005/papers/P12.pdf): any data that crosses
a service boundary "is always from the past" — the only choice is how far
past, and whether the bound is explicit. He also grounded the coupling axis:
participating in another system's transaction means holding its locks, "a
serious ceding of independence." Every projection-versus-API argument since
has been a negotiation between those two poles.

What the literature does not carry as a decision axis is the third one — and
it is the one that decided the payments example.

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
narrower and, I think, more useful: the literature hands us the *mechanism*
and a list of overlapping *benefits* — Kleppmann's talk enumerates simpler
code, scalability, robustness, latency, flexibility — but not the *decision
instrument*. Benefits lists tell you what you gain; they don't weigh what
you trade. Helland gives two axes with endpoints; the practitioners' debate
collapsed to one ("but staleness"); and reasoning capacity — the axis that
measures whether the system can answer the questions the business hasn't
asked yet — appears in none of them as something to score a design against.

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
