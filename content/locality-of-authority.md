---
title: "A Decision Belongs Where Its Authority Lives"
layout: "single"
ShowToc: false
ShowBreadCrumbs: false
summary: "Separate a decision from the state it has to change, and the missing transaction comes back as retries, reconciliation, and shared outages."
description: "Separate a decision from the state it has to change, and the missing transaction comes back as retries, reconciliation, and shared outages."
---

Most architecture arguments are placement arguments wearing a disguise. Which
service owns this rule. Where validation goes. Whether the logic belongs in the
application tier or the database. Whether the check happens before the queue or
after it. These get settled by team boundaries, framework convention, or
whoever is most tired — as though placement were a matter of taste.

It is not. Placement decides what a system is capable of being correct about.

## What authority means

A system has authority over some state when it can decide what happens to that
state and commit the change without another system having to approve or correct
the result afterwards.

A transaction is the clearest case. If it reads a credit balance and deducts
ten credits, the system that commits that deduction holds authority over the
balance. Nothing downstream gets a vote.

Authority is not ownership on a diagram. A service called `billing` does not
hold authority over a balance because of its name. It holds it when it can read
the balance and change it without anyone else's cooperation, and is bound by
the result the moment it commits.

## The search that stopped for two days

The clearest case I encountered was a pilot already designed this way. I have
removed identifying details.

The operation was an image search: given a query image, return visually similar
images taken near a location, restricted to what the requesting user was
permitted to see, and paid for from that customer's prepaid credits.

Four systems supplied four parts of the decision. Visual similarity in a vector
index. Geography in another service. Permissions in a third. The credit balance
in a fourth. The application had to combine all four to decide whether the
search could proceed. But no system could evaluate the whole decision and
commit its state change as one operation.

For the retrieval part, the join moved into application memory. The similarity
index returned a large candidate set and the application filtered it — an ad hoc distributed
query planner with no shared statistics, no common snapshot, and no index
spanning the predicate. Its memory was now sized for datasets nobody intended
to materialise.

The credit balance was the sharpest edge. It was read synchronously, so when
the credits service stopped answering, search stopped with it — for about two
days. A healthy retrieval capability held hostage by a billing lookup, while
retries asked an unavailable system the same question. And because the
deduction lived elsewhere, charging for the search and recording that the search
was authorised could never be one transaction. They were two independently
committed outcomes, so every design had to coordinate or compensate for the gap
between them.

## What was actually missing

No single place had both things the decision needed. The application could not
evaluate its full predicate there, and it could not commit the credit change
there either. The first problem was that the facts could not be queried
together. The second was that the state change lived somewhere else.

That difference matters, because it rules out the obvious fix. Search had no
business becoming the source of truth for geography, permissions, or the
similarity model. Most decisions depend on facts whose source they do not
control — a sanctions list, an exchange rate, a risk score computed elsewhere.
Those are **decision context**. What search needed was not authority over them,
but a locally accepted, versioned representation that it could query together
with everything else.

So a decision needs one place where it can finish. That place needs authority
over what the decision changes, and local access to what the decision needs to
know. Without both, there is nowhere the decision can be evaluated against a
coherent set of facts and its change committed together.

Call it **locality of authority**.

## The machinery that fills the gap

Once a decision is separated from its authority, the gap acquires machinery.
It accumulates caches and shadow copies. It retries. It reconciles overnight.
It grows reservations, idempotency keys, timeout policy, duplicate suppression,
and a second copy of the rules that has to evolve in lockstep with the first.

When the distance is self-inflicted, much of that machinery exists only to
manage the separation. It is not resilience added to the capability. It is the
interest payment on a placement mistake.

None of it appears on the architecture diagram either. The diagram shows boxes
and arrows, and the boxes look fine.

## The rule

Move the decision to the authority, or move the authority to the decision. Do
not leave them apart and manage the gap.

In practice: make the decision where its state change becomes final, and bring
the context it needs there as an accepted, versioned copy — rather than
fetching it mid-transaction from a system that can be down.

## Where this shows up

The essays on this site are all instances of it, approached from different
directions.

[Operational and Analytical Are Not Separate
Architectures](/posts/operational-and-analytical-are-not-separate-architectures/)
— analytical knowledge has value only when it can return to the place where
decisions consume it.

[The Lakehouse Publishes. Applications Decide
Locally.](/posts/lakehouse-publishes-applications-decide-locally/) — external
knowledge becomes usable context only once an application has accepted it
locally.

[Why We Are Still Getting Database Deployments Wrong in
2026](/posts/database-deployments-wrong-2026/) — the database, not an external
tool, is authoritative for what committed.

[Decoupling Compute and Storage in
Postgres](/posts/decoupling-compute-storage-postgres-lakebase/) — what the
platform shift changes about where authority can sit at all.

The same principle drives [pgmi](https://vvka-141.github.io/pgmi/articles/):
the part of an API that decides and commits database state belongs inside the
database that state lives in.

Everything I have published is indexed on the [writing](/writing/) page.

## What this is not

Not an argument for one big system. Distribution is often right — it just has
to follow real transaction boundaries, instead of scattering one decision's
state and context across systems that cannot act together.

Not an argument that every fact belongs in a database. Authority can belong to
a ledger, a device that is authoritative for its own state, or any other system
able to make a state change final. The claim is only that the state-changing
part of the decision should commit where authority over that state lives.

And not a claim that the components are individually wrong. Every service can
behave exactly to its own contract while the decision they add up to has
nowhere it can be made consistently. Local correctness does not add up to
decision correctness.
