-- =============================================================================
-- 03_ref_schema.sql   (run on Azure Database for PostgreSQL, after 02_bootstrap)
-- The `ref` lane: reference & rate-card tables (5.2) + controlled vocabularies (5.3).
-- These are the WRITE TARGETS for the CDC Sync Worker. Read-only to the app.
--
-- DESIGN DECISIONS (see chat for rationale):
--   1. NO foreign keys between ref tables. The worker syncs tables independently
--      and possibly out of order; FKs would cause transient violations and stall
--      the sync. Integrity is guaranteed by the source ERP. We enforce PK,
--      NOT NULL, and cheap CHECKs only.
--   2. Each table's PRIMARY KEY == the source ERP table's PK, so the worker's
--      ON CONFLICT upsert stays correct and idempotent. CONFIRM against the real
--      source PKs before go-live (ties to the unresolved ua_* format blocker).
--   3. Rate cards are versioned (rule 4.4): PK includes `version` WHERE the source
--      keys on it. Where marked TODO, decide: keep in PK (source is versioned) or
--      drop version from the PK and treat it as a plain attribute.
--   4. Money (rule 4.3): numeric(12,4) + explicit currency column. FX via
--      exchange_rates; base VND / presentation USD live in `config`. No hard-coded rates.
--
-- Naming: lower_snake_case, timestamps timestamptz (rule 4.6). ua_* columns carry
-- ERP codes and join to the 5.3 vocabularies (rule 4.1).
-- =============================================================================

SET search_path TO ref, public;

-- ============================================================ 5.2 REFERENCE & RATE-CARD

-- Fabric catalogue.
CREATE TABLE IF NOT EXISTS ref.fabric_master (
    fabric_code          text PRIMARY KEY,
    name                 text,
    ua_fabric_type_code  text,        -- -> fabric_types
    ua_fabric_kind_code  text,        -- -> fabric_kinds
    weight_gsm           numeric(10,2),
    yarn                 text,
    composition          text,
    weave                text,
    colour_type          text,
    ua_unit_code         text,        -- -> units
    active               boolean NOT NULL DEFAULT true
);
COMMENT ON TABLE ref.fabric_master IS 'Fabric catalogue (5.2). Source: FABRIC_MASTER export.';

-- Costed fabric prices (versioned rate card).
CREATE TABLE IF NOT EXISTS ref.fabric_price_master (
    fabric_code     text NOT NULL,
    version         text NOT NULL,               -- TODO confirm source keys on version
    bulk_price_usd  numeric(12,4),
    price_currency  text NOT NULL DEFAULT 'USD',
    supplier_code   text,
    confidence      text,
    source          text,
    apply_date      date,
    updated_at      timestamptz,
    PRIMARY KEY (fabric_code, version)
);
COMMENT ON TABLE ref.fabric_price_master IS 'Fabric prices, versioned (rule 4.4).';

-- Trim unit prices (versioned rate card).
CREATE TABLE IF NOT EXISTS ref.trim_price_master (
    trim_code         text NOT NULL,
    version           text NOT NULL,             -- TODO confirm source keys on version
    unit_price_usd    numeric(12,4),
    price_currency    text NOT NULL DEFAULT 'USD',
    ua_trim_type_code text,                      -- -> trim_types
    confidence        text,
    source            text,
    apply_date        date,
    updated_at        timestamptz,
    PRIMARY KEY (trim_code, version)
);
COMMENT ON TABLE ref.trim_price_master IS 'Trim prices, versioned (rule 4.4).';

-- Trim quantity-per-garment (the rating that multiplies price).
CREATE TABLE IF NOT EXISTS ref.trim_rating (
    trim_code        text NOT NULL,
    ua_category_code text NOT NULL,              -- style / category
    qty              numeric(12,4),
    PRIMARY KEY (trim_code, ua_category_code)
);
COMMENT ON TABLE ref.trim_rating IS 'Trim rating per garment (5.2).';

-- CMP operation timings & consumption.
CREATE TABLE IF NOT EXISTS ref.cmp_timing (
    op_code          text PRIMARY KEY,
    cmp_section      text,                       -- -> cmp_sections
    description      text,
    ua_machine_code  text,                       -- -> machines
    timing_s         numeric(12,4),
    consumption      numeric(12,4)
);
COMMENT ON TABLE ref.cmp_timing IS 'CMP operation timings by machine/section (5.2).';

-- Per-gate seconds matrix. PK is ambiguous in the blueprint:
--   (garment_kind, gate) OR (customer, gate). Defaulting to garment_kind.
-- TODO confirm which key the source uses.
CREATE TABLE IF NOT EXISTS ref.cmp_gate_matrix (
    ua_garment_kind_code text NOT NULL,          -- -> garment_kinds
    gate                 text NOT NULL,
    customer_id          text,                   -- populated when matrix is per-customer
    seconds              numeric(12,4),
    PRIMARY KEY (ua_garment_kind_code, gate)
);
COMMENT ON TABLE ref.cmp_gate_matrix IS 'Per-gate timing matrix (5.2). PK unconfirmed — see TODO.';

-- Fabric consumption benchmarks by garment type & fabric width.
CREATE TABLE IF NOT EXISTS ref.consumption_matrix (
    ua_category_code text NOT NULL,              -- garment / category
    fabric_width_cm  numeric(10,2) NOT NULL,
    consumption      numeric(12,4),
    PRIMARY KEY (ua_category_code, fabric_width_cm)
);
COMMENT ON TABLE ref.consumption_matrix IS 'Fabric consumption benchmarks (5.2).';

-- Shrinkage / wastage %.
CREATE TABLE IF NOT EXISTS ref.wastage (
    name          text NOT NULL,
    type          text NOT NULL,
    shrinkage_pct numeric(6,2),
    wastage_pct   numeric(6,2),
    version       text NOT NULL DEFAULT 'v1',    -- TODO confirm source versioning
    apply_date    date,
    PRIMARY KEY (name, type, version)
);
COMMENT ON TABLE ref.wastage IS 'Shrinkage / wastage % by material/treatment (5.2).';

-- Target and floor margins by customer / product type.
CREATE TABLE IF NOT EXISTS ref.margin_rules (
    rule_id           text PRIMARY KEY,
    customer_id       text,
    ua_category_code  text,
    target_markup_pct numeric(6,2),
    floor_margin_pct  numeric(6,2),
    version           text,
    apply_date        date
);
COMMENT ON TABLE ref.margin_rules IS 'Target/floor margins (5.2).';

-- Versioned CMP factor / SG&A / testing / std qty by tier.
CREATE TABLE IF NOT EXISTS ref.rate_config (
    version      text NOT NULL,
    costing_rate text NOT NULL,                  -- tier, e.g. RATE 1 / 2 / 3
    cmp_factor   numeric(8,4),
    sga_factor   numeric(8,4),
    testing_pct  numeric(6,2),
    standard_qty integer,
    apply_date   date,
    PRIMARY KEY (version, costing_rate)
);
COMMENT ON TABLE ref.rate_config IS 'Versioned rate card by tier (5.2, rule 4.4).';

-- Print size bands for print costing.
CREATE TABLE IF NOT EXISTS ref.print_area_bands (
    band          text PRIMARY KEY,
    area_min_cm2  numeric(10,2),
    area_max_cm2  numeric(10,2),
    rate_usd      numeric(12,4)
);
COMMENT ON TABLE ref.print_area_bands IS 'Print area bands / formula (5.2).';

-- Embroidery rates (versioned).
CREATE TABLE IF NOT EXISTS ref.embroidery_rate (
    rate_key    text NOT NULL,
    version     text NOT NULL DEFAULT 'v1',      -- TODO confirm source versioning
    description text,
    rate_usd    numeric(12,4),
    apply_date  date,
    PRIMARY KEY (rate_key, version)
);
COMMENT ON TABLE ref.embroidery_rate IS 'Embroidery rates (5.2).';

-- Wash / dye treatment rates (versioned).
CREATE TABLE IF NOT EXISTS ref.wash_matrix (
    treatment_key text NOT NULL,
    version       text NOT NULL DEFAULT 'v1',    -- TODO confirm source versioning
    description   text,
    rate_usd      numeric(12,4),
    apply_date    date,
    PRIMARY KEY (treatment_key, version)
);
COMMENT ON TABLE ref.wash_matrix IS 'Wash / dye rates (5.2).';

-- Global settings: base currency (VND), presentation currency (USD), FX source.
CREATE TABLE IF NOT EXISTS ref.config (
    setting_key   text PRIMARY KEY,
    setting_value text,
    description   text
);
COMMENT ON TABLE ref.config IS 'Settings incl. base_currency=VND, presentation_currency=USD, fx_source (5.2).';

-- ============================================================ 5.3 CONTROLLED VOCABULARIES
-- Pattern: code is the key, name is the label. ua_* code columns above join here.

CREATE TABLE IF NOT EXISTS ref.cmp_sections (
    code       text PRIMARY KEY,                 -- C,N,P,S,B,E,P1,F,P2
    name       text,
    sort_order integer
);

CREATE TABLE IF NOT EXISTS ref.units (
    code      text PRIMARY KEY,                  -- KG,M,ROLL,PCS,SET,CONE,YARD...
    name      text,
    dimension text                               -- mass / length / count ...
);

CREATE TABLE IF NOT EXISTS ref.unit_conversions (
    from_unit text NOT NULL,
    to_unit   text NOT NULL,
    factor    numeric(18,8) NOT NULL,
    PRIMARY KEY (from_unit, to_unit),
    CHECK (factor > 0)
);

CREATE TABLE IF NOT EXISTS ref.exchange_rates (
    from_currency text NOT NULL,
    to_currency   text NOT NULL,
    rate          numeric(18,8) NOT NULL,
    apply_date    date NOT NULL,
    PRIMARY KEY (from_currency, to_currency, apply_date),
    CHECK (rate > 0)
);
COMMENT ON TABLE ref.exchange_rates IS 'FX: VND base + EUR/USD to VND (5.3, rule 4.3).';

CREATE TABLE IF NOT EXISTS ref.fabric_kinds    ( code text PRIMARY KEY, name text );
CREATE TABLE IF NOT EXISTS ref.fabric_types    ( code text PRIMARY KEY, name text );
CREATE TABLE IF NOT EXISTS ref.trim_groups     ( code text PRIMARY KEY, name text );
CREATE TABLE IF NOT EXISTS ref.trim_types      ( code text PRIMARY KEY, name text );
CREATE TABLE IF NOT EXISTS ref.treatment_types ( code text PRIMARY KEY, name text, category text );
CREATE TABLE IF NOT EXISTS ref.work_types      ( code text PRIMARY KEY, name text );
CREATE TABLE IF NOT EXISTS ref.style_categories( code text PRIMARY KEY, name text );
CREATE TABLE IF NOT EXISTS ref.garment_kinds   ( code text PRIMARY KEY, name text );

-- Further ERP vocabulary (rule: code -> name).
CREATE TABLE IF NOT EXISTS ref.colours           ( code text PRIMARY KEY, name text );
CREATE TABLE IF NOT EXISTS ref.seasons           ( code text PRIMARY KEY, name text );
CREATE TABLE IF NOT EXISTS ref.artwork_positions ( code text PRIMARY KEY, name text );
CREATE TABLE IF NOT EXISTS ref.machines          ( code text PRIMARY KEY, name text );

-- ============================================================ EXTRA SYNC TARGETS
-- Present in the Base44↔UA alignment workbook (REPLACE/USE UA) but not itemised in
-- PDF 5.2. Added so the worker has a target. Confirm columns against the export.

CREATE TABLE IF NOT EXISTS ref.fabric_rating (
    fabric_code      text NOT NULL,
    ua_category_code text NOT NULL,
    cutting_width_cm numeric(10,2),
    standard_qty     numeric(12,4),
    PRIMARY KEY (fabric_code, ua_category_code)
);
COMMENT ON TABLE ref.fabric_rating IS 'Cutting widths / std qty (FabricRating export). Confirm columns.';

-- Alias / dictionary list (Dictionary export: customer/fabric/wash spellings).
-- Kept in ref as reference; the customer-alias resolution used by the app lives in ops.
CREATE TABLE IF NOT EXISTS ref.dictionary (
    alias_id    bigint PRIMARY KEY,              -- source key
    domain      text,                            -- customer / fabric / wash ...
    alias       text NOT NULL,
    canonical   text
);
COMMENT ON TABLE ref.dictionary IS 'ERP alias/dictionary list (Dictionary export).';

-- NOTE — deliberately NOT created here:
--   * costing        : UA COSTING_SHEET is a benchmark AND the engine generates its
--                      own costings. Two separate tables — handle outside this mirror.
--   * customer/supplier : MERGE tables (UA identity + app fields). Field-level
--                      ownership required — they live in ops, not ref. Handle separately.

-- ============================================================ GRANTS
-- Re-assert grants so tables created by an admin role are reachable by the app roles.
GRANT USAGE ON SCHEMA ref TO sync_writer, app_rw, report_ro;
GRANT INSERT, UPDATE, DELETE, SELECT ON ALL TABLES IN SCHEMA ref TO sync_writer;
GRANT SELECT ON ALL TABLES IN SCHEMA ref TO app_rw, report_ro;
