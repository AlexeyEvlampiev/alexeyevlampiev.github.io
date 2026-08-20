-- Companion appendix to "Data Platforms Keep Adding Postgres. Don't Collapse the Boundary."
-- Verified 2026-08-16 on PostgreSQL 18.4 (postgres:18 Docker image, default configuration).
-- Requires PostgreSQL 15+ (assumes CREATE on schema public is revoked from PUBLIC,
-- as it is from 15 on; SECURITY DEFINER functions here rely on that).
--
-- One-command reproduction:
--   docker run --name ctx-demo -d -e POSTGRES_PASSWORD=demo postgres:18
--   docker cp decision-context-demo.sql ctx-demo:/tmp/
--   docker exec ctx-demo psql -U postgres -v ON_ERROR_STOP=1 -f /tmp/decision-context-demo.sql
--
-- Expects an empty database; creates all objects it uses, plus three NOLOGIN
-- roles (cluster-level): projection_writer, release_operator, app_execution.
--
-- This implements the immutable-release projection contract end to end,
-- ENFORCED at two levels:
--   * Triggers constrain every role, including the table owner: a release is
--     born 'staged' (INSERT cannot choose a status); lifecycle transitions
--     form a state machine (staged->active, staged->rejected,
--     active->superseded, superseded->active — nothing returns to 'staged');
--     once a release leaves staging its manifest fields are immutable; facts
--     can neither be edited in a sealed release nor moved out of one, and
--     the seal cannot race a concurrent activation; decision evidence
--     rejects UPDATE, DELETE, and TRUNCATE; the payment state machine
--     rejects illegal transitions.
--   * Privileges constrain the application-facing roles: projection_writer
--     stages manifests (a column-restricted INSERT — it cannot choose a
--     status even at insert time) and facts, and stamps the content hash;
--     release_operator activates through SECURITY DEFINER lifecycle
--     functions but holds no direct write on anything; app_execution holds
--     NO direct write on operational state at all — it may only execute the
--     two SECURITY DEFINER business executions, the transactional-API
--     discipline the article describes. Every bypass is proven to fail.
--   Database ownership remains an administrative trust boundary: an owner
--   can disable triggers, and this demo does not pretend otherwise.
--
-- The contract itself:
--   * The dataset registry's active pointer is DATASET-SCOPED by a composite
--     foreign key: a dataset cannot point at another dataset's release.
--   * All lifecycle changes go through functions that lock the DATASET row
--     first — one lock order for all three, so they cannot deadlock each
--     other: activate_release (validates schema version, lineage continuity,
--     row count, content checksum — distinct recorded rejection reason
--     each), switch_active (rollback / roll-forward; re-checks the schema
--     contract), deactivate_release. Competing activators serialize and
--     lose deterministically.
--   * The business execution binds facts to the active release IN the
--     constraint's own index (the release predicate is part of the Index
--     Cond, not a post-join filter), enforces the freshness budget against
--     the release watermark clamped by local activation time, transitions
--     state, and records append-only evidence with policy version and
--     reason code.
--   * held is durable but not terminal: reconsider_payment re-evaluates
--     transactions held for TECHNICAL reasons (projection_absent,
--     projection_stale) once context recovers; business holds stay put. It
--     locks the transaction row BEFORE reading the prior verdict, so two
--     concurrent reconsiderations cannot both append — an unchanged verdict
--     appends nothing, under any interleaving.
--   * Staleness is demonstrated by activating a release whose source
--     watermark is honestly old — never by editing a sealed manifest.
--
-- An appendix at the end of this file contains the exact two-session scripts
-- for the concurrency experiments referenced by the article.

CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ---------------------------------------------------------------------------
-- The dataset registry and the projection manifest. The dataset row is the
-- serialization point for all lifecycle operations and the authoritative
-- active pointer; the partial unique index is a consistency backstop.
-- ---------------------------------------------------------------------------
CREATE TABLE context_dataset (
    dataset_id        text PRIMARY KEY,
    schema_version    text NOT NULL,
    active_release_id text
);

CREATE TABLE context_release (
    release_id       text        PRIMARY KEY,
    dataset_id       text        NOT NULL REFERENCES context_dataset,
    predecessor_id   text        REFERENCES context_release,
    schema_version   text        NOT NULL,
    source_watermark timestamptz NOT NULL,
    published_at     timestamptz NOT NULL,
    activated_at     timestamptz,          -- FIRST activation; pointer switches do not restamp it
    row_count        bigint      NOT NULL,
    content_hash     text,
    status           text        NOT NULL DEFAULT 'staged'
        CHECK (status IN ('staged', 'rejected', 'active', 'superseded')),
    rejection_reason text,
    UNIQUE (dataset_id, release_id)
);

-- The active pointer is dataset-scoped: it can only reference a release that
-- belongs to the same dataset. MATCH SIMPLE semantics are load-bearing: a
-- NULL active_release_id satisfies the constraint, which is what makes
-- deactivation legal by construction.
ALTER TABLE context_dataset
    ADD FOREIGN KEY (dataset_id, active_release_id)
    REFERENCES context_release (dataset_id, release_id);

CREATE UNIQUE INDEX context_release_one_active
    ON context_release (dataset_id)
 WHERE status = 'active';

-- Lifecycle is a constraint, not a convention, on BOTH paths in:
--   INSERT: a release is born 'staged' — no role, including the owner,
--   inserts a manifest row that skips the lifecycle.
--   UPDATE: legal transitions only, and no path leads back to 'staged', so
--   sealing is irreversible. Once a release leaves staging, every manifest
--   field is frozen — a release id names the same manifest forever.
--   (activated_at and rejection_reason are stamped by the staged->active and
--   staged->rejected transitions, while OLD.status is still 'staged'.)
CREATE FUNCTION enforce_release_lifecycle() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status IS DISTINCT FROM 'staged' THEN
            RAISE EXCEPTION 'release % must be born staged, not %',
                NEW.release_id, NEW.status
                USING ERRCODE = 'integrity_constraint_violation';
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status
       AND (OLD.status, NEW.status) NOT IN
           (('staged', 'active'), ('staged', 'rejected'),
            ('active', 'superseded'), ('superseded', 'active')) THEN
        RAISE EXCEPTION 'illegal release lifecycle transition: % -> %',
            OLD.status, NEW.status
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF OLD.status <> 'staged' AND
       (NEW.release_id, NEW.dataset_id, NEW.predecessor_id, NEW.schema_version,
        NEW.source_watermark, NEW.published_at, NEW.activated_at, NEW.row_count,
        NEW.content_hash, NEW.rejection_reason)
       IS DISTINCT FROM
       (OLD.release_id, OLD.dataset_id, OLD.predecessor_id, OLD.schema_version,
        OLD.source_watermark, OLD.published_at, OLD.activated_at, OLD.row_count,
        OLD.content_hash, OLD.rejection_reason) THEN
        RAISE EXCEPTION 'release % has left staging; its manifest is immutable',
            OLD.release_id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER context_release_lifecycle
BEFORE INSERT OR UPDATE ON context_release
FOR EACH ROW EXECUTE FUNCTION enforce_release_lifecycle();

-- ---------------------------------------------------------------------------
-- The projected decision-context table, stored RELEASE-SCOPED: the temporal
-- invariant (no overlapping standing per counterparty and jurisdiction) holds
-- within each release, so releases N and N+1 can coexist in the table.
-- The constraint's own index serves the decision lookup.
--
-- Production notes this demo does not implement: a logical-replication
-- transport would want a key (REPLICA IDENTITY); retention is a policy —
-- retired and rejected releases' facts stay until the owner removes them,
-- and partitioning BY release turns retirement into DETACH instead of a
-- mass DELETE (check exclusion-constraint support on partitioned tables for
-- your PostgreSQL version).
-- ---------------------------------------------------------------------------
CREATE TABLE counterparty_standing (
    release_id         text        NOT NULL REFERENCES context_release,
    counterparty_id    bigint      NOT NULL,
    jurisdiction       text        NOT NULL CHECK (char_length(jurisdiction) = 2),
    standing           text        NOT NULL,
    legal_name         text        NOT NULL,
    valid              tstzrange   NOT NULL CHECK (NOT isempty(valid)),
    source             text        NOT NULL,
    source_observed_at timestamptz NOT NULL,
    EXCLUDE USING gist (
        release_id      WITH =,
        counterparty_id WITH =,
        jurisdiction    WITH =,
        valid           WITH &&
    )
);

CREATE INDEX counterparty_standing_by_name
    ON counterparty_standing
 USING gin (legal_name gin_trgm_ops);

-- Facts are writable only while their release is 'staged'. Both sides of a
-- mutation are checked: a row can neither be edited inside a sealed release
-- nor MOVED out of one into a staged release. The FOR SHARE lock makes the
-- check race-free against a concurrent activation BY CONSTRUCTION: FOR SHARE
-- conflicts with both FOR UPDATE (which activate_release takes) and FOR NO
-- KEY UPDATE (which any plain UPDATE of the manifest takes) — FOR KEY SHARE
-- would only conflict with the former, leaving the seal dependent on a
-- coincidence of lock strength. SECURITY DEFINER supplies the lock
-- privilege; EXECUTE is revoked from PUBLIC below (a callable FOR SHARE on
-- an arbitrary release row would otherwise be a lock-based denial of
-- service on the lifecycle) and granted to the staging role the seal
-- trigger runs as.
CREATE FUNCTION assert_release_open(p_release text) RETURNS void AS $$
DECLARE
    v_status text;
BEGIN
    SELECT status INTO v_status FROM context_release
     WHERE release_id = p_release
       FOR SHARE;
    IF v_status IS DISTINCT FROM 'staged' THEN
        RAISE EXCEPTION 'release % is sealed (status %); publish a successor release instead',
            p_release, v_status
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
END $$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE FUNCTION forbid_sealed_mutation() RETURNS trigger AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        PERFORM assert_release_open(OLD.release_id);
    END IF;
    IF TG_OP = 'INSERT'
       OR (TG_OP = 'UPDATE' AND NEW.release_id IS DISTINCT FROM OLD.release_id) THEN
        PERFORM assert_release_open(NEW.release_id);
    END IF;
    RETURN COALESCE(NEW, OLD);
END $$ LANGUAGE plpgsql;

CREATE TRIGGER counterparty_standing_sealed
BEFORE INSERT OR UPDATE OR DELETE ON counterparty_standing
FOR EACH ROW EXECUTE FUNCTION forbid_sealed_mutation();

-- Row triggers do not fire on TRUNCATE; the guard must say so explicitly.
CREATE FUNCTION forbid_truncate() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'TRUNCATE is not part of the lifecycle of %', TG_TABLE_NAME
        USING ERRCODE = 'integrity_constraint_violation';
END $$ LANGUAGE plpgsql;

CREATE TRIGGER counterparty_standing_no_truncate
BEFORE TRUNCATE ON counterparty_standing
FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();

-- ---------------------------------------------------------------------------
-- Operational state and the decision's evidence. The payment state machine
-- is itself trigger-enforced: pending -> approved | held, held -> approved |
-- held (reconsideration), approved terminal. Evidence is APPEND-ONLY
-- history, by trigger, not convention — a reconsidered transaction gains a
-- second row; the first is never rewritten. decided_at is stamped with
-- clock_timestamp() AT APPEND TIME; because every append for one
-- transaction happens under that transaction's row lock, appends are
-- serialized and decided_at order equals append order — a now() stamp
-- (transaction start) could invert it for a caller that blocked.
-- ---------------------------------------------------------------------------
CREATE TABLE pending_transaction (
    transaction_id  bigint      PRIMARY KEY,
    counterparty_id bigint      NOT NULL,
    jurisdiction    text        NOT NULL,
    received_at     timestamptz NOT NULL,
    status          text        NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'approved', 'held'))
);

CREATE FUNCTION enforce_payment_transition() RETURNS trigger AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status
       AND (OLD.status, NEW.status) NOT IN
           (('pending', 'approved'), ('pending', 'held'), ('held', 'approved')) THEN
        RAISE EXCEPTION 'illegal payment transition: % -> %', OLD.status, NEW.status
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END $$ LANGUAGE plpgsql;

CREATE TRIGGER pending_transaction_transitions
BEFORE UPDATE ON pending_transaction
FOR EACH ROW EXECUTE FUNCTION enforce_payment_transition();

CREATE TABLE payment_decision (
    transaction_id     bigint      NOT NULL REFERENCES pending_transaction,
    decided_at         timestamptz NOT NULL,
    decision           text        NOT NULL,
    policy_id          text        NOT NULL,
    policy_version     int         NOT NULL,
    reason             text        NOT NULL,
    standing           text,
    context_valid      tstzrange,
    context_source     text,
    source_observed_at timestamptz,
    active_release     text,
    release_watermark  timestamptz,
    PRIMARY KEY (transaction_id, decided_at)
);

CREATE FUNCTION forbid_evidence_rewrite() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION 'decision evidence is append-only'
        USING ERRCODE = 'integrity_constraint_violation';
END $$ LANGUAGE plpgsql;

CREATE TRIGGER payment_decision_append_only
BEFORE UPDATE OR DELETE ON payment_decision
FOR EACH ROW EXECUTE FUNCTION forbid_evidence_rewrite();

CREATE TRIGGER payment_decision_no_truncate
BEFORE TRUNCATE ON payment_decision
FOR EACH STATEMENT EXECUTE FUNCTION forbid_truncate();

CREATE TABLE payment_outbox (
    outbox_id    bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    topic        text        NOT NULL,
    payload      jsonb       NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz
);

-- ---------------------------------------------------------------------------
-- Staging: load one complete 200,000-row release, tagged with its release_id,
-- with realistic name diversity for the trigram demonstration.
-- ---------------------------------------------------------------------------
CREATE FUNCTION stage_counterparty_release(p_release text) RETURNS bigint AS $fn$
    INSERT INTO counterparty_standing
    SELECT p_release,
           g,
           (ARRAY['NL','DE','FR','GB','US'])[1 + g % 5],
           (ARRAY['good','under_review','restricted'])[1 + g % 3],
           (ARRAY['Aurora','Brightwater','Corvus','Delta Ridge','Eastgate','Fenwick',
                  'Granite Bay','Harlow','Ironvale','Juniper','Kestrel','Lindenau',
                  'Meridian','Northcliff','Orchid','Pallas','Quarry Hill','Rosewood',
                  'Stonebridge','Thornfield'])[1 + (g*7)%20]
           || ' ' ||
           (ARRAY['Capital','Logistics','Maritime','Chemicals','Foods','Energy',
                  'Textiles','Pharma','Robotics','Ceramics','Timber','Insurance',
                  'Shipping','Analytics'])[1 + (g*13)%14]
           || ' ' ||
           (ARRAY['B.V.','N.V.','GmbH','S.A.','Ltd','PLC','AB','Oy'])[1 + (g*3)%8]
           || ' ' || (g % 9999),
           tstzrange(now() - ((g % 900) || ' days')::interval,
                     now() - ((g % 900) || ' days')::interval + interval '400 days', '[)'),
           'eu-registry-feed',
           now() - interval '2 hours'
      FROM generate_series(1, 200000) g;
    SELECT count(*) FROM counterparty_standing WHERE release_id = p_release;
$fn$ LANGUAGE sql;

-- Two counterparties the demo tracks across releases: 12345 (good in release
-- A, restricted from release B on) and 33330 / 22220 (good throughout).
CREATE FUNCTION arrange_demo_facts(p_release text, p_12345_standing text) RETURNS void AS $fn$
    UPDATE counterparty_standing
       SET valid = tstzrange(now() - interval '30 days', now() + interval '30 days', '[)'),
           standing = p_12345_standing
     WHERE release_id = p_release AND counterparty_id = 12345 AND jurisdiction = 'NL';
    UPDATE counterparty_standing
       SET valid = tstzrange(now() - interval '30 days', now() + interval '30 days', '[)'),
           standing = 'good'
     WHERE release_id = p_release AND counterparty_id = 33330 AND jurisdiction = 'NL';
$fn$ LANGUAGE sql;

-- The demo plays the publisher: it stamps the content hash after arranging
-- the rows. NOTE: this database-local aggregate hash makes completeness
-- executable in a demo, and it works here only because publisher and
-- validator are the same session — the row-to-text rendering it hashes
-- depends on session settings (TimeZone, DateStyle), so across systems the
-- digest is not even deterministic. A production publisher ships a
-- canonical manifest — a DEFINED serialization (that is the load-bearing
-- part), typically partitioned hashes or a Merkle structure, with a modern
-- digest, authenticated — and the cell compares its independently computed
-- value. A matching hash proves transport completeness, not semantic
-- correctness of the source.
CREATE FUNCTION publish_content_hash(p_release text) RETURNS void AS $fn$
    UPDATE context_release r
       SET content_hash = (
           SELECT md5(string_agg(
                      md5((s.counterparty_id, s.jurisdiction, s.standing, s.legal_name,
                           s.valid, s.source, s.source_observed_at)::text),
                      '' ORDER BY s.counterparty_id, s.jurisdiction, lower(s.valid)))
             FROM counterparty_standing s
            WHERE s.release_id = r.release_id)
     WHERE r.release_id = p_release;
$fn$ LANGUAGE sql;

-- ---------------------------------------------------------------------------
-- Lifecycle operations. All three lock the DATASET row first — one lock
-- order, so lifecycle operations cannot deadlock each other — then take
-- their own preconditions under that lock. SECURITY DEFINER + REVOKE below
-- make these functions the ONLY lifecycle path available to non-owner
-- roles. (Production would add lock_timeout / statement_timeout around
-- activation: validation scans the full release while the dataset row is
-- held, which is the price of a serialized lifecycle.)
-- ---------------------------------------------------------------------------
CREATE FUNCTION activate_release(p_release text)
RETURNS TABLE (outcome text, reason text) AS $$
DECLARE
    r         context_release%ROWTYPE;
    d         context_dataset%ROWTYPE;
    v_dataset text;
    v_count   bigint;
    v_hash    text;
    v_reason  text;
BEGIN
    SELECT c.dataset_id INTO v_dataset FROM context_release c
     WHERE c.release_id = p_release;
    IF NOT FOUND THEN
        RETURN;                                   -- unknown release: nothing to do
    END IF;

    SELECT * INTO d FROM context_dataset c
     WHERE c.dataset_id = v_dataset
       FOR UPDATE;                                -- dataset first, always

    SELECT * INTO r FROM context_release c
     WHERE c.release_id = p_release AND c.status = 'staged'
       FOR UPDATE;                                -- re-checked under the dataset lock
    IF NOT FOUND THEN
        RETURN;                                   -- not staged (anymore): nothing to do
    END IF;

    IF r.schema_version IS DISTINCT FROM d.schema_version THEN
        v_reason := 'schema_unsupported';
    ELSIF r.predecessor_id IS DISTINCT FROM d.active_release_id THEN
        v_reason := 'continuity_violation';       -- a gap is detectable, not silent
    ELSE
        SELECT count(*),
               md5(string_agg(
                   md5((s.counterparty_id, s.jurisdiction, s.standing, s.legal_name,
                        s.valid, s.source, s.source_observed_at)::text),
                   '' ORDER BY s.counterparty_id, s.jurisdiction, lower(s.valid)))
          INTO v_count, v_hash
          FROM counterparty_standing s
         WHERE s.release_id = r.release_id;
        IF v_count IS DISTINCT FROM r.row_count THEN
            v_reason := 'row_count_mismatch';
        ELSIF v_hash IS DISTINCT FROM r.content_hash THEN
            v_reason := 'checksum_mismatch';
        END IF;
    END IF;

    IF v_reason IS NOT NULL THEN
        UPDATE context_release c
           SET status = 'rejected', rejection_reason = v_reason
         WHERE c.release_id = p_release;
        RETURN QUERY SELECT 'rejected'::text, v_reason;
        RETURN;
    END IF;

    UPDATE context_release c SET status = 'superseded'
     WHERE c.release_id = d.active_release_id;
    UPDATE context_release c SET status = 'active', activated_at = now()
     WHERE c.release_id = p_release;
    UPDATE context_dataset c SET active_release_id = p_release
     WHERE c.dataset_id = v_dataset;
    RETURN QUERY SELECT 'active'::text, NULL::text;
END $$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- Rollback and roll-forward: point the dataset at a retained, previously
-- validated release. Only 'superseded' releases whose schema version still
-- matches the dataset's contract qualify — a rejected or staged release can
-- never become active through this path, and neither can a release the
-- current consumer contract no longer admits.
CREATE FUNCTION switch_active(p_dataset text, p_release text) RETURNS text AS $$
DECLARE
    d context_dataset%ROWTYPE;
BEGIN
    SELECT * INTO d FROM context_dataset c
     WHERE c.dataset_id = p_dataset FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'unknown dataset %', p_dataset;
    END IF;
    PERFORM 1 FROM context_release c
     WHERE c.release_id = p_release AND c.dataset_id = p_dataset
       AND c.status = 'superseded'
       AND c.schema_version = d.schema_version
       FOR UPDATE;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    UPDATE context_release c SET status = 'superseded'
     WHERE c.release_id = d.active_release_id;
    UPDATE context_release c SET status = 'active'
     WHERE c.release_id = p_release;
    UPDATE context_dataset c SET active_release_id = p_release
     WHERE c.dataset_id = p_dataset;
    RETURN 'active';
END $$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

CREATE FUNCTION deactivate_release(p_dataset text) RETURNS text AS $$
DECLARE
    d context_dataset%ROWTYPE;
BEGIN
    SELECT * INTO d FROM context_dataset c
     WHERE c.dataset_id = p_dataset FOR UPDATE;
    IF d.active_release_id IS NULL THEN
        RETURN NULL;
    END IF;
    UPDATE context_dataset c SET active_release_id = NULL
     WHERE c.dataset_id = p_dataset;
    UPDATE context_release c SET status = 'superseded'
     WHERE c.release_id = d.active_release_id;
    RETURN 'deactivated';
END $$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- The policy, factored once and shared by both executions below — including
-- its identity: the policy id and version live HERE, next to the rule they
-- describe, so evidence cannot drift from the policy that produced it.
-- Policy: counterparty-standing-gate, version 3.
--
-- Two deliberate shapes:
--   * The fact join binds release_id through a scalar subquery on the
--     active pointer. When this function inlines into a caller's plan, that
--     shape puts the release predicate INTO the exclusion-constraint
--     index's Index Cond (an InitPlan) — a join through the manifest leaves
--     it as a post-join filter that discards one candidate row per retained
--     release. Section 13 shows the plan of this actual read path.
--   * Freshness compares against least(source_watermark, activated_at):
--     the watermark is stamped by the PUBLISHER's clock, activation by the
--     local one; the clamp keeps a publisher clock running ahead from
--     making stale context look fresh. (now() is transaction-start time —
--     a long-running decision evaluates its budget as of its start.)
-- ---------------------------------------------------------------------------
CREATE FUNCTION standing_verdict(p_counterparty bigint, p_jurisdiction text,
                                 p_received timestamptz)
RETURNS TABLE (decision text, reason text, standing text, context_valid tstzrange,
               context_source text, source_observed_at timestamptz,
               active_release text, release_watermark timestamptz,
               policy_id text, policy_version int) AS $fn$
    SELECT CASE WHEN rc.reason = 'standing_good' THEN 'approved' ELSE 'held' END,
           rc.reason, s.standing, s.valid, s.source, s.source_observed_at,
           c.release_id, c.source_watermark,
           'counterparty-standing-gate', 3
      FROM (SELECT 1) one
      LEFT JOIN (SELECT r.release_id, r.source_watermark, r.activated_at
                   FROM context_dataset d
                   JOIN context_release r ON r.release_id = d.active_release_id
                  WHERE d.dataset_id = 'counterparty-standing') c ON true
      LEFT JOIN counterparty_standing s
        ON s.release_id = (SELECT d2.active_release_id FROM context_dataset d2
                            WHERE d2.dataset_id = 'counterparty-standing')
       AND s.counterparty_id = p_counterparty
       AND s.jurisdiction    = p_jurisdiction
       AND s.valid          @> p_received
     CROSS JOIN LATERAL (
        SELECT CASE
            WHEN c.release_id IS NULL                             THEN 'projection_absent'
            WHEN least(c.source_watermark, c.activated_at)
                 < now() - interval '24 hours'                    THEN 'projection_stale'
            WHEN s.counterparty_id IS NULL                        THEN 'context_absent'
            WHEN s.standing = 'good'                              THEN 'standing_good'
            ELSE 'standing_' || s.standing
        END AS reason) rc;
$fn$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------------
-- Execution 1: decide a pending payment. One statement, one snapshot, one
-- commit: precondition + row lock, release-bound context read, versioned
-- policy with reason codes, state transition, evidence, outbox. SECURITY
-- DEFINER: the application role executes the command; it holds no direct
-- write on any of the tables the command touches.
-- ---------------------------------------------------------------------------
CREATE FUNCTION decide_payment(p_transaction_id bigint)
RETURNS TABLE (transaction_id bigint, decision text, reason text) AS $fn$
    WITH verdict AS (
        SELECT t.transaction_id, v.*
          FROM pending_transaction t
         CROSS JOIN LATERAL standing_verdict(t.counterparty_id, t.jurisdiction,
                                             t.received_at) v
         WHERE t.transaction_id = p_transaction_id
           AND t.status = 'pending'
           FOR UPDATE OF t
    ),
    transition AS (
        UPDATE pending_transaction t
           SET status = v.decision
          FROM verdict v
         WHERE t.transaction_id = v.transaction_id
    ),
    evidence AS (
        INSERT INTO payment_decision
                (transaction_id, decided_at, decision,
                 policy_id, policy_version, reason,
                 standing, context_valid, context_source, source_observed_at,
                 active_release, release_watermark)
        SELECT v.transaction_id, clock_timestamp(), v.decision,
               v.policy_id, v.policy_version, v.reason,
               v.standing, v.context_valid, v.context_source, v.source_observed_at,
               v.active_release, v.release_watermark
          FROM verdict v
    )
    INSERT INTO payment_outbox (topic, payload)
    SELECT 'payment.decided',
           jsonb_build_object('transaction_id', v.transaction_id,
                              'decision',       v.decision,
                              'reason',         v.reason,
                              'active_release', v.active_release)
      FROM verdict v
    RETURNING (payload->>'transaction_id')::bigint,
              payload->>'decision', payload->>'reason';
$fn$ LANGUAGE sql SECURITY DEFINER SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- Execution 2: reconsider a payment held for a TECHNICAL reason. 'held' is
-- durable, not terminal: once the projection recovers, transactions held on
-- projection_absent or projection_stale are re-evaluated under the same
-- policy. Business holds (standing_*) are not touched by this execution.
--
-- Idempotency contract: evidence is appended ONLY when the verdict changes.
-- The ORDER of operations is the enforcement: the transaction row is locked
-- FIRST, and the prior verdict is read AFTER the lock, in a fresh statement
-- snapshot — so a rival reconsideration that already appended is visible,
-- and two concurrent calls cannot both append the same verdict. (A single
-- SQL statement cannot get this right: its prior-verdict read would come
-- from the statement snapshot, which the READ COMMITTED recheck does not
-- refresh — only the locked row is re-evaluated. That defect was found by
-- an adversarial review of this very file and is proven closed in
-- experiment 4 of the appendix.)
-- ---------------------------------------------------------------------------
CREATE FUNCTION reconsider_payment(p_transaction_id bigint)
RETURNS TABLE (transaction_id bigint, decision text, reason text) AS $$
DECLARE
    t        pending_transaction%ROWTYPE;
    v        record;
    v_latest text;
BEGIN
    SELECT * INTO t FROM pending_transaction pt
     WHERE pt.transaction_id = p_transaction_id AND pt.status = 'held'
       FOR UPDATE;                    -- lock FIRST: rival reconsiderers serialize here
    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT pd.reason INTO v_latest    -- read AFTER the lock: sees a rival's committed append
      FROM payment_decision pd
     WHERE pd.transaction_id = p_transaction_id
     ORDER BY pd.decided_at DESC
     LIMIT 1;
    IF v_latest NOT IN ('projection_absent', 'projection_stale') THEN
        RETURN;                       -- business hold: not this execution's to touch
    END IF;

    SELECT * INTO v
      FROM standing_verdict(t.counterparty_id, t.jurisdiction, t.received_at);
    IF (v.decision, v.reason) IS NOT DISTINCT FROM ('held', v_latest) THEN
        RETURN;                       -- unchanged verdict: not an event
    END IF;

    UPDATE pending_transaction pt SET status = v.decision
     WHERE pt.transaction_id = p_transaction_id;

    INSERT INTO payment_decision
            (transaction_id, decided_at, decision,
             policy_id, policy_version, reason,
             standing, context_valid, context_source, source_observed_at,
             active_release, release_watermark)
    VALUES (p_transaction_id, clock_timestamp(), v.decision,
            v.policy_id, v.policy_version, v.reason,
            v.standing, v.context_valid, v.context_source, v.source_observed_at,
            v.active_release, v.release_watermark);

    INSERT INTO payment_outbox (topic, payload)
    VALUES ('payment.reconsidered',
            jsonb_build_object('transaction_id', p_transaction_id,
                               'decision',       v.decision,
                               'reason',         v.reason,
                               'active_release', v.active_release));

    RETURN QUERY SELECT p_transaction_id, v.decision, v.reason;
END $$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp;

-- ---------------------------------------------------------------------------
-- The privilege boundary. Three roles, one per responsibility:
--   projection_writer stages manifests — a COLUMN-RESTRICTED insert, so it
--     cannot choose a status even at insert time — and facts, and may stamp
--     the content hash; it cannot touch lifecycle status.
--   release_operator activates, switches, deactivates — through the
--     SECURITY DEFINER lifecycle functions only.
--   app_execution holds NO direct write on operational state: it inserts
--     intake rows, reads, and executes the two business commands. The
--     transition, the evidence, and the event happen inside the commands.
-- ---------------------------------------------------------------------------
CREATE ROLE projection_writer NOLOGIN;
CREATE ROLE release_operator  NOLOGIN;
CREATE ROLE app_execution     NOLOGIN;

GRANT SELECT ON context_dataset, context_release, counterparty_standing
   TO projection_writer, release_operator, app_execution;

GRANT INSERT (release_id, dataset_id, predecessor_id, schema_version,
              source_watermark, published_at, row_count, content_hash)
   ON context_release TO projection_writer;
GRANT UPDATE (content_hash) ON context_release TO projection_writer;
GRANT INSERT, UPDATE, DELETE ON counterparty_standing TO projection_writer;

GRANT SELECT, INSERT ON pending_transaction TO app_execution;
GRANT SELECT ON payment_decision, payment_outbox TO app_execution;

-- PostgreSQL grants EXECUTE to PUBLIC by default; for every function that
-- is an enforcement primitive or a privileged command, that default is
-- exactly wrong.
REVOKE EXECUTE ON FUNCTION activate_release(text), switch_active(text, text),
                           deactivate_release(text), assert_release_open(text),
                           decide_payment(bigint), reconsider_payment(bigint)
  FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION activate_release(text), switch_active(text, text),
                           deactivate_release(text) TO release_operator;
GRANT  EXECUTE ON FUNCTION assert_release_open(text) TO projection_writer;
GRANT  EXECUTE ON FUNCTION decide_payment(bigint), reconsider_payment(bigint)
    TO app_execution;

-- ===========================================================================
-- Release A: staged, arranged, hashed, validated, activated.
-- ===========================================================================
INSERT INTO context_dataset VALUES ('counterparty-standing', '1', NULL);

INSERT INTO context_release
        (release_id, dataset_id, predecessor_id, schema_version,
         source_watermark, published_at, row_count)
VALUES ('2026-08-16.1', 'counterparty-standing', NULL, '1',
        now() - interval '2 hours', now() - interval '90 minutes', 200000);

SELECT stage_counterparty_release('2026-08-16.1');
SELECT arrange_demo_facts('2026-08-16.1', 'good');

-- A fact last observed 3 days ago, carried unchanged into a CURRENT release:
-- row age is not freshness; the release watermark is.
UPDATE counterparty_standing
   SET valid = tstzrange(now() - interval '30 days', now() + interval '30 days', '[)'),
       standing = 'good',
       source_observed_at = now() - interval '3 days'
 WHERE release_id = '2026-08-16.1' AND counterparty_id = 22220 AND jurisdiction = 'NL';

-- ---------------------------------------------------------------------------
-- 1. The temporal invariant fires while staging: an overlapping standing is
--    rejected at write time, before validation can even begin.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  INSERT INTO counterparty_standing VALUES
    ('2026-08-16.1', 12345, 'NL', 'restricted', 'Alpha Holding B.V.',
     tstzrange(now() - interval '5 days', now() + interval '5 days', '[)'),
     'eu-registry-feed', now());
  RAISE EXCEPTION 'exclusion constraint did NOT fire';
EXCEPTION WHEN exclusion_violation THEN
  RAISE NOTICE 'OK: overlapping standing rejected with exclusion_violation';
END $$;

SELECT publish_content_hash('2026-08-16.1');
SELECT * FROM activate_release('2026-08-16.1');   -- Expected: active

ANALYZE;

-- ---------------------------------------------------------------------------
-- 2. Sealed means sealed — five ways, all enforced against the OWNER, by
--    trigger and constraint, before privileges even enter the picture.
--    Each test asserts on the specific error message, not only the error
--    class, so it cannot pass for the wrong reason.
--    a. The activated release's facts reject mutation.
--    b. Its status cannot be moved back to 'staged' to reopen the seal.
--    c. Its manifest fields are frozen: the watermark of an accepted release
--       cannot be edited.
--    d. A release cannot be INSERTED in any state but 'staged'.
--    e. A dataset cannot point at another dataset's release.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  UPDATE counterparty_standing SET standing = 'restricted'
   WHERE release_id = '2026-08-16.1' AND counterparty_id = 12345 AND jurisdiction = 'NL';
  RAISE EXCEPTION 'sealed release accepted a mutation';
EXCEPTION WHEN integrity_constraint_violation THEN
  ASSERT SQLERRM LIKE '%is sealed%', SQLERRM;
  RAISE NOTICE 'OK: sealed release rejected the mutation';
END $$;

DO $$
BEGIN
  UPDATE context_release SET status = 'staged' WHERE release_id = '2026-08-16.1';
  RAISE EXCEPTION 'release was unsealed';
EXCEPTION WHEN integrity_constraint_violation THEN
  ASSERT SQLERRM LIKE '%lifecycle transition%', SQLERRM;
  RAISE NOTICE 'OK: active -> staged transition rejected; sealing is irreversible';
END $$;

DO $$
BEGIN
  UPDATE context_release SET source_watermark = now()
   WHERE release_id = '2026-08-16.1';
  RAISE EXCEPTION 'sealed manifest accepted an edit';
EXCEPTION WHEN integrity_constraint_violation THEN
  ASSERT SQLERRM LIKE '%immutable%', SQLERRM;
  RAISE NOTICE 'OK: manifest of an accepted release is immutable';
END $$;

DO $$
BEGIN
  INSERT INTO context_release
          (release_id, dataset_id, predecessor_id, schema_version,
           source_watermark, published_at, row_count, status)
  VALUES ('R-fake', 'counterparty-standing', NULL, '1', now(), now(), 0, 'superseded');
  RAISE EXCEPTION 'a release was born unsealed';
EXCEPTION WHEN integrity_constraint_violation THEN
  ASSERT SQLERRM LIKE '%born staged%', SQLERRM;
  RAISE NOTICE 'OK: a release cannot be inserted in any state but staged';
END $$;

INSERT INTO context_dataset VALUES ('other-dataset', '1', NULL);
DO $$
BEGIN
  UPDATE context_dataset SET active_release_id = '2026-08-16.1'
   WHERE dataset_id = 'other-dataset';
  RAISE EXCEPTION 'cross-dataset pointer accepted';
EXCEPTION WHEN foreign_key_violation THEN
  RAISE NOTICE 'OK: cross-dataset active pointer rejected by composite FK';
END $$;

-- ---------------------------------------------------------------------------
-- 3. The privilege boundary, hostile-tested per role: every direct-update
--    bypass of the lifecycle and execution protocol is refused before
--    triggers even fire.
-- ---------------------------------------------------------------------------
SET ROLE app_execution;

DO $$
BEGIN
  UPDATE context_release SET status = 'superseded' WHERE release_id = '2026-08-16.1';
  RAISE EXCEPTION 'app role changed a release status directly';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'OK: app_execution cannot write the release manifest';
END $$;

DO $$
BEGIN
  UPDATE counterparty_standing SET standing = 'good' WHERE counterparty_id = 12345;
  RAISE EXCEPTION 'app role edited projected facts';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'OK: app_execution cannot write projected facts';
END $$;

DO $$
BEGIN
  UPDATE pending_transaction SET status = 'approved' WHERE transaction_id = 0;
  RAISE EXCEPTION 'app role transitioned a payment without the execution';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'OK: app_execution cannot transition payments outside the command';
END $$;

DO $$
BEGIN
  DELETE FROM payment_decision WHERE transaction_id = 0;
  RAISE EXCEPTION 'app role deleted evidence';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'OK: app_execution cannot delete evidence';
END $$;

DO $$
BEGIN
  PERFORM * FROM activate_release('2026-08-16.1');
  RAISE EXCEPTION 'app role ran a lifecycle function';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'OK: app_execution cannot execute lifecycle functions';
END $$;

DO $$
BEGIN
  PERFORM assert_release_open('2026-08-16.1');
  RAISE EXCEPTION 'app role took a lifecycle lock';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'OK: app_execution cannot lock release rows via the seal primitive';
END $$;

RESET ROLE;
SET ROLE projection_writer;

DO $$
BEGIN
  UPDATE context_release SET status = 'active' WHERE release_id = '2026-08-16.1';
  RAISE EXCEPTION 'staging role changed a release status directly';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'OK: projection_writer can stamp content_hash but not status';
END $$;

DO $$
BEGIN
  INSERT INTO context_release
          (release_id, dataset_id, predecessor_id, schema_version,
           source_watermark, published_at, row_count, status)
  VALUES ('R-fake2', 'counterparty-standing', NULL, '1', now(), now(), 0, 'superseded');
  RAISE EXCEPTION 'staging role inserted a release with a chosen status';
EXCEPTION WHEN insufficient_privilege THEN
  RAISE NOTICE 'OK: projection_writer cannot choose a status at insert time either';
END $$;

RESET ROLE;

-- And the owner-path guards for the operational tables:
DO $$
BEGIN
  TRUNCATE payment_decision;
  RAISE EXCEPTION 'evidence was truncated';
EXCEPTION WHEN integrity_constraint_violation THEN
  ASSERT SQLERRM LIKE '%TRUNCATE%', SQLERRM;
  RAISE NOTICE 'OK: TRUNCATE of evidence rejected (row triggers alone would not fire)';
END $$;

-- ---------------------------------------------------------------------------
-- 4. Decisions under release A (watermark 2 hours old), executed AS the
--    application role — the positive path through the same boundary: the
--    role that cannot UPDATE anything decides payments through the command.
-- ---------------------------------------------------------------------------
SET ROLE app_execution;

INSERT INTO pending_transaction (transaction_id, counterparty_id, jurisdiction, received_at) VALUES
  (1, 12345,  'NL', now() - interval '3 hours'),
  (2, 999999, 'NL', now() - interval '3 hours'),
  (3, 22220,  'NL', now() - interval '3 hours');

SELECT * FROM decide_payment(1);   -- Expected: approved | standing_good
SELECT * FROM decide_payment(2);   -- Expected: held     | context_absent
SELECT * FROM decide_payment(3);   -- Expected: approved | standing_good (old fact, current release)

-- ---------------------------------------------------------------------------
-- 5. Idempotency: transaction 1 is no longer 'pending'; re-deciding it is a
--    no-op — no double transition, no duplicate evidence, no second event.
-- ---------------------------------------------------------------------------
SELECT * FROM decide_payment(1);   -- Expected: zero rows

DO $$
BEGIN
  ASSERT (SELECT count(*) FROM payment_decision WHERE transaction_id = 1) = 1;
  ASSERT (SELECT count(*) FROM payment_outbox) = 3;
  ASSERT (SELECT status FROM pending_transaction WHERE transaction_id = 1) = 'approved';
  RAISE NOTICE 'OK: re-deciding a decided transaction changed nothing';
END $$;

RESET ROLE;

-- Evidence and the payment state machine reject rewriting even on the owner
-- path: the trigger, not the privilege, is the last line.
DO $$
BEGIN
  UPDATE payment_decision SET decision = 'approved' WHERE transaction_id = 2;
  RAISE EXCEPTION 'evidence row was rewritten';
EXCEPTION WHEN integrity_constraint_violation THEN
  ASSERT SQLERRM LIKE '%append-only%', SQLERRM;
  RAISE NOTICE 'OK: evidence is append-only, by trigger';
END $$;

DO $$
BEGIN
  UPDATE pending_transaction SET status = 'pending' WHERE transaction_id = 1;
  RAISE EXCEPTION 'an approved payment went back to pending';
EXCEPTION WHEN integrity_constraint_violation THEN
  ASSERT SQLERRM LIKE '%payment transition%', SQLERRM;
  RAISE NOTICE 'OK: approved is terminal; the payment state machine is schema-enforced';
END $$;

-- ===========================================================================
-- Release B: a complete replacement staged WHILE A stays active and retained,
-- BY the staging role; activated BY the operator role. The release-scoped
-- constraint is what makes this staging legal. In B, counterparty 12345 has
-- become restricted.
-- ===========================================================================
SET ROLE projection_writer;

INSERT INTO context_release
        (release_id, dataset_id, predecessor_id, schema_version,
         source_watermark, published_at, row_count)
VALUES ('2026-08-16.2', 'counterparty-standing', '2026-08-16.1', '1',
        now() - interval '5 minutes', now() - interval '3 minutes', 200000);

SELECT stage_counterparty_release('2026-08-16.2');
SELECT arrange_demo_facts('2026-08-16.2', 'restricted');
SELECT publish_content_hash('2026-08-16.2');

RESET ROLE;

-- ---------------------------------------------------------------------------
-- 6. A sealed row cannot be MOVED into a staged release: the seal checks the
--    source release of a mutation, not only its destination.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  UPDATE counterparty_standing SET release_id = '2026-08-16.2'
   WHERE release_id = '2026-08-16.1' AND counterparty_id = 12345 AND jurisdiction = 'NL';
  RAISE EXCEPTION 'a sealed row was moved into a staged release';
EXCEPTION WHEN integrity_constraint_violation THEN
  ASSERT SQLERRM LIKE '%is sealed%', SQLERRM;
  RAISE NOTICE 'OK: moving a row out of a sealed release is rejected';
END $$;

SET ROLE release_operator;
SELECT * FROM activate_release('2026-08-16.2');   -- Expected: active
RESET ROLE;

DO $$
BEGIN
  ASSERT (SELECT status FROM context_release WHERE release_id = '2026-08-16.1') = 'superseded';
  ASSERT (SELECT active_release_id FROM context_dataset
           WHERE dataset_id = 'counterparty-standing') = '2026-08-16.2';
  RAISE NOTICE 'OK: B active, A superseded and retained';
END $$;

ANALYZE;

-- ---------------------------------------------------------------------------
-- 7. The new release changes FUTURE decisions; it cannot rewrite past ones.
--    Transaction 1's evidence still says approved under release A.
-- ---------------------------------------------------------------------------
INSERT INTO pending_transaction (transaction_id, counterparty_id, jurisdiction, received_at)
VALUES (4, 12345, 'NL', now() - interval '10 minutes');

SET ROLE app_execution;
SELECT * FROM decide_payment(4);   -- Expected: held | standing_restricted
RESET ROLE;

-- ---------------------------------------------------------------------------
-- 8. Rollback is a serialized lifecycle operation on the retained
--    predecessor. The same counterparty approves again; then roll forward.
-- ---------------------------------------------------------------------------
SELECT switch_active('counterparty-standing', '2026-08-16.1');   -- Expected: active

INSERT INTO pending_transaction (transaction_id, counterparty_id, jurisdiction, received_at)
VALUES (5, 12345, 'NL', now() - interval '10 minutes');

SET ROLE app_execution;
SELECT * FROM decide_payment(5);   -- Expected: approved | standing_good (under release A)
RESET ROLE;

SELECT switch_active('counterparty-standing', '2026-08-16.2');   -- Expected: active

-- ---------------------------------------------------------------------------
-- 9. Zero active releases: the schema guarantees at most one; when there is
--    none, the execution fails closed with an explicit reason.
-- ---------------------------------------------------------------------------
SELECT deactivate_release('counterparty-standing');              -- Expected: deactivated

INSERT INTO pending_transaction (transaction_id, counterparty_id, jurisdiction, received_at)
VALUES (6, 12345, 'NL', now() - interval '10 minutes');

SET ROLE app_execution;
SELECT * FROM decide_payment(6);   -- Expected: held | projection_absent
RESET ROLE;

SELECT switch_active('counterparty-standing', '2026-08-16.2');   -- Expected: active

-- ---------------------------------------------------------------------------
-- 10. Validation rejects, with recorded reasons; the active release is
--     untouched each time.
--     Release C claims 200,000 rows but ships 5          → row_count_mismatch.
--     Release D ships 5 rows honestly, with a wrong hash → checksum_mismatch.
-- ---------------------------------------------------------------------------
INSERT INTO context_release
        (release_id, dataset_id, predecessor_id, schema_version,
         source_watermark, published_at, row_count)
VALUES ('2026-08-16.3', 'counterparty-standing', '2026-08-16.2', '1',
        now(), now(), 200000);

INSERT INTO counterparty_standing
SELECT '2026-08-16.3', counterparty_id, jurisdiction, standing, legal_name,
       valid, source, source_observed_at
  FROM counterparty_standing
 WHERE release_id = '2026-08-16.2' AND counterparty_id <= 5;

SELECT publish_content_hash('2026-08-16.3');
SELECT * FROM activate_release('2026-08-16.3');   -- Expected: rejected | row_count_mismatch

INSERT INTO context_release
        (release_id, dataset_id, predecessor_id, schema_version,
         source_watermark, published_at, row_count, content_hash)
VALUES ('2026-08-16.4', 'counterparty-standing', '2026-08-16.2', '1',
        now(), now(), 5, 'deadbeef');

INSERT INTO counterparty_standing
SELECT '2026-08-16.4', counterparty_id, jurisdiction, standing, legal_name,
       valid, source, source_observed_at
  FROM counterparty_standing
 WHERE release_id = '2026-08-16.2' AND counterparty_id <= 5;

SELECT * FROM activate_release('2026-08-16.4');   -- Expected: rejected | checksum_mismatch

DO $$
BEGIN
  ASSERT (SELECT rejection_reason FROM context_release
           WHERE release_id = '2026-08-16.3') = 'row_count_mismatch';
  ASSERT (SELECT rejection_reason FROM context_release
           WHERE release_id = '2026-08-16.4') = 'checksum_mismatch';
  ASSERT (SELECT active_release_id FROM context_dataset
           WHERE dataset_id = 'counterparty-standing') = '2026-08-16.2';
  RAISE NOTICE 'OK: both malformed releases rejected with reasons; active untouched';
END $$;

-- ---------------------------------------------------------------------------
-- 11. The failure model, live. The analytical plane has been down; the first
--     release it publishes on recovery was cut from a source snapshot taken
--     before the outage, and its watermark says so honestly. Integrity
--     validation passes — validation checks completeness, not business
--     freshness — and the freshness budget then holds the execution.
--     (In production the same held state arises with NO new release at all,
--     once the active watermark ages past the budget; a demo cannot wait 24
--     hours, so it activates a release that is already old. No sealed
--     manifest is edited to simulate anything.)
-- ---------------------------------------------------------------------------
INSERT INTO context_release
        (release_id, dataset_id, predecessor_id, schema_version,
         source_watermark, published_at, row_count)
VALUES ('2026-08-16.5', 'counterparty-standing', '2026-08-16.2', '1',
        now() - interval '3 days', now(), 200000);

SELECT stage_counterparty_release('2026-08-16.5');
SELECT arrange_demo_facts('2026-08-16.5', 'restricted');
SELECT publish_content_hash('2026-08-16.5');
SELECT * FROM activate_release('2026-08-16.5');   -- Expected: active

INSERT INTO pending_transaction (transaction_id, counterparty_id, jurisdiction, received_at)
VALUES (7, 33330, 'NL', now() - interval '10 minutes');

SET ROLE app_execution;
SELECT * FROM decide_payment(7);   -- Expected: held | projection_stale

-- ---------------------------------------------------------------------------
-- 12. held is durable, not terminal — for TECHNICAL holds only — and
--     reconsideration is idempotent.
--     a. A business hold (standing_restricted) is not reconsiderable.
--     b. Reconsidering while the projection is STILL stale appends nothing:
--        an unchanged verdict is not an event.
--     c. Once a fresh release activates, the technically held transaction is
--        re-evaluated under the same policy and approves. Evidence is
--        appended: the projection_stale row remains forever.
-- ---------------------------------------------------------------------------
SELECT * FROM reconsider_payment(4);   -- Expected: zero rows (business hold)
SELECT * FROM reconsider_payment(7);   -- Expected: zero rows (still stale, unchanged verdict)

DO $$
BEGIN
  ASSERT (SELECT count(*) FROM payment_decision WHERE transaction_id = 7) = 1;
  RAISE NOTICE 'OK: reconsideration against an unchanged projection appended nothing';
END $$;

RESET ROLE;

-- The projection recovers: a successor release with a fresh watermark
-- validates and activates.
INSERT INTO context_release
        (release_id, dataset_id, predecessor_id, schema_version,
         source_watermark, published_at, row_count)
VALUES ('2026-08-16.6', 'counterparty-standing', '2026-08-16.5', '1',
        now() - interval '10 minutes', now(), 200000);

SELECT stage_counterparty_release('2026-08-16.6');
SELECT arrange_demo_facts('2026-08-16.6', 'restricted');
SELECT publish_content_hash('2026-08-16.6');
SELECT * FROM activate_release('2026-08-16.6');   -- Expected: active

SET ROLE app_execution;
SELECT * FROM reconsider_payment(7);   -- Expected: approved | standing_good
RESET ROLE;

DO $$
BEGIN
  ASSERT (SELECT status FROM pending_transaction WHERE transaction_id = 4) = 'held';
  ASSERT (SELECT status FROM pending_transaction WHERE transaction_id = 7) = 'approved';
  ASSERT (SELECT count(*) FROM payment_decision WHERE transaction_id = 7) = 2;
  ASSERT (SELECT reason FROM payment_decision WHERE transaction_id = 7
           ORDER BY decided_at LIMIT 1) = 'projection_stale';
  ASSERT (SELECT count(*) FROM payment_outbox WHERE topic = 'payment.reconsidered') = 1;
  RAISE NOTICE 'OK: technical hold recovered with appended evidence; business hold untouched';
END $$;

ANALYZE;

-- Every verdict, distinguishable from the durable record alone.
SELECT transaction_id, decision, reason, policy_version, active_release
  FROM payment_decision
 ORDER BY transaction_id, decided_at;

-- ---------------------------------------------------------------------------
-- 13. The plan property, measured on the EXECUTION'S OWN READ PATH — not a
--     hand-written probe. standing_verdict is a STABLE single-SELECT SQL
--     function, so it inlines into the caller's plan; its scalar-subquery
--     release binding lands all four predicates — release binding included —
--     inside the index the exclusion constraint built for its own
--     enforcement. (A join through the manifest instead leaves the release
--     as a post-join filter that discards one candidate row per retained
--     release — this demo's earlier revision had exactly that plan.)
-- ---------------------------------------------------------------------------
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT t.transaction_id, v.decision, v.reason
  FROM pending_transaction t
 CROSS JOIN LATERAL standing_verdict(t.counterparty_id, t.jurisdiction,
                                     t.received_at) v
 WHERE t.transaction_id = 1;

-- ---------------------------------------------------------------------------
-- 14. The unanticipated question: fuzzy name match via the trigram index.
--     Note the honest limit: the GIN index spans every retained release, so
--     candidates are release-wide and the active-release join filters
--     afterward — retention widens this search. A production design scopes
--     it (partial index, btree_gin composite, or partition by release).
-- ---------------------------------------------------------------------------
SELECT s.counterparty_id, s.legal_name,
       round(similarity(s.legal_name, 'Stonebrige Maritme B.V. 4471')::numeric, 3) AS sim
  FROM counterparty_standing s
  JOIN context_dataset d
    ON d.dataset_id = 'counterparty-standing' AND s.release_id = d.active_release_id
 WHERE s.legal_name % 'Stonebrige Maritme B.V. 4471'
 ORDER BY sim DESC
 LIMIT 3;

-- ===========================================================================
-- Appendix: two-session concurrency experiments — exact reproduction scripts.
-- Run these AFTER the single-session script above completes, from two
-- terminals against the same container. Timings are approximate; the
-- blocking behavior is not.
--
-- Experiment 1 — decision race: the same transaction decided twice.
--   Setup:
--     docker exec ctx-demo psql -U postgres -c "INSERT INTO pending_transaction
--       (transaction_id, counterparty_id, jurisdiction, received_at)
--       VALUES (100, 33330, 'NL', now())"
--   Session A:
--     docker exec ctx-demo psql -U postgres -c "BEGIN;
--       SELECT * FROM decide_payment(100); SELECT pg_sleep(10); COMMIT;"
--   Session B (start while A sleeps):
--     docker exec ctx-demo psql -U postgres -c "SELECT * FROM decide_payment(100);"
--   Observed: B blocks on A's row lock until A commits, then returns ZERO
--   rows — the READ COMMITTED recheck (EvalPlanQual) re-evaluates the
--   precondition against the updated row and finds status <> 'pending'.
--   One decision, one evidence row, one outbox event.
--
-- Experiment 2 — two-writer activation race: competing activators serialize
-- on the dataset row; the loser is rejected with a recorded reason.
--   Setup: stage TWO candidate releases, both citing the current active
--   release as predecessor — repeat the Release B staging pattern with ids
--   '2026-08-16.7' and '2026-08-16.8', predecessor_id '2026-08-16.6'.
--   Session A:
--     docker exec ctx-demo psql -U postgres -c "BEGIN;
--       SELECT * FROM activate_release('2026-08-16.7'); SELECT pg_sleep(10); COMMIT;"
--   Session B (start while A sleeps):
--     docker exec ctx-demo psql -U postgres -c "SELECT * FROM activate_release('2026-08-16.8');"
--   Observed: B blocks on the dataset row until A commits, then returns
--   rejected | continuity_violation — its predecessor no longer matches the
--   active release. The rejection is durable in the manifest.
--   Visibility check (run while A sleeps, and again after it commits):
--     docker exec ctx-demo psql -U postgres -c "SELECT active_release_id
--       FROM context_dataset WHERE dataset_id = 'counterparty-standing';"
--   Observed: exactly the predecessor before A's commit, exactly the
--   successor after it — never zero active releases, never two.
--
-- Experiment 3 — fact write racing activation: the seal is race-free.
--   Setup: stage release '2026-08-16.9' (predecessor = the current active
--   release), publish its hash, do not activate yet.
--   Session A:
--     docker exec ctx-demo psql -U postgres -c "BEGIN;
--       SELECT * FROM activate_release('2026-08-16.9'); SELECT pg_sleep(10); COMMIT;"
--   Session B (start while A sleeps):
--     docker exec ctx-demo psql -U postgres -c "UPDATE counterparty_standing
--       SET standing = 'good'
--       WHERE release_id = '2026-08-16.9' AND counterparty_id = 1 AND jurisdiction = 'DE';"
--   Observed: B's seal check blocks behind the activation's lock on the
--   release row, then fails with 'release 2026-08-16.9 is sealed (status
--   active)'. A writer cannot slip a fact into a release while it is being
--   sealed.
--
-- Experiment 4 — reconsideration race: the idempotency contract holds under
-- concurrency, across the hard case — a held -> held transition where only
-- the REASON changes. (A single-statement implementation fails this test:
-- its prior-verdict read comes from the statement snapshot, which the READ
-- COMMITTED recheck does not refresh. The lock-first plpgsql implementation
-- above was adopted after an adversarial review demonstrated exactly that
-- duplicate append.)
--   Setup — drive one transaction into a held-absent state, then make the
--   verdict change to held-stale:
--     docker exec ctx-demo psql -U postgres -c "
--       INSERT INTO pending_transaction (transaction_id, counterparty_id, jurisdiction, received_at)
--       VALUES (200, 33330, 'NL', now());
--       SELECT deactivate_release('counterparty-standing');
--       SELECT * FROM decide_payment(200);                          -- held | projection_absent
--       SELECT switch_active('counterparty-standing', '2026-08-16.9');"
--     (with '2026-08-16.9' the current active from experiment 3; then stage
--     and activate a release '2026-08-16.10', predecessor '2026-08-16.9',
--     with source_watermark now() - interval '3 days' — the verdict for
--     transaction 200 becomes held | projection_stale.)
--   Session A:
--     docker exec ctx-demo psql -U postgres -c "BEGIN;
--       SELECT * FROM reconsider_payment(200); SELECT pg_sleep(10); COMMIT;"
--   Session B (start while A sleeps):
--     docker exec ctx-demo psql -U postgres -c "SELECT * FROM reconsider_payment(200);"
--   Observed: A appends the reason change (held | projection_stale). B
--   blocks on A's row lock, then returns ZERO rows: it re-reads the prior
--   verdict AFTER acquiring the lock, sees A's append, and finds its own
--   verdict unchanged. Exactly TWO evidence rows for transaction 200
--   (projection_absent, projection_stale), exactly one 'payment.reconsidered'
--   event for the change.
-- ===========================================================================
