-- =====================================================================
-- Sales Data Warehouse — staging area + star schema
-- PostgreSQL 14+
-- =====================================================================
DROP SCHEMA IF EXISTS stg CASCADE;
DROP SCHEMA IF EXISTS dw  CASCADE;
CREATE SCHEMA stg;   -- raw data as it arrives from source systems
CREATE SCHEMA dw;    -- cleaned, modelled star schema

-- ---------------------------------------------------------------------
-- Staging (loose types on purpose: source data is messy)
-- ---------------------------------------------------------------------
CREATE TABLE stg.customers_raw (
    customer_code TEXT, full_name TEXT, city TEXT, segment TEXT,
    extracted_at  TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE stg.products_raw (
    sku TEXT, product_name TEXT, category TEXT, brand TEXT, list_price TEXT,
    extracted_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE stg.sales_raw (
    invoice_no TEXT, line_no TEXT, sold_at TEXT, customer_code TEXT,
    sku TEXT, store_code TEXT, qty TEXT, unit_price TEXT, discount_pct TEXT,
    batch_id BIGINT
);

CREATE TABLE stg.rejected_rows (
    source     TEXT, payload JSONB, reason TEXT,
    batch_id   BIGINT, rejected_at TIMESTAMPTZ DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Dimensions
-- ---------------------------------------------------------------------
CREATE TABLE dw.dim_date (
    date_key      INT PRIMARY KEY,          -- yyyymmdd
    full_date     DATE NOT NULL UNIQUE,
    year          SMALLINT, quarter SMALLINT, month SMALLINT, month_name TEXT,
    week_of_year  SMALLINT, day_of_week SMALLINT, day_name TEXT,
    is_weekend    BOOLEAN
);

-- SCD Type 2: history of customer attribute changes
CREATE TABLE dw.dim_customer (
    customer_key  BIGSERIAL PRIMARY KEY,    -- surrogate key
    customer_code TEXT    NOT NULL,         -- natural / business key
    full_name     TEXT    NOT NULL,
    city          TEXT,
    segment       TEXT,
    row_hash      TEXT    NOT NULL,         -- md5 of tracked attributes
    valid_from    DATE    NOT NULL,
    valid_to      DATE    NOT NULL DEFAULT DATE '9999-12-31',
    is_current    BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE UNIQUE INDEX ux_dim_customer_current ON dw.dim_customer (customer_code) WHERE is_current;

-- SCD Type 1: overwrite in place
CREATE TABLE dw.dim_product (
    product_key   BIGSERIAL PRIMARY KEY,
    sku           TEXT NOT NULL UNIQUE,
    product_name  TEXT NOT NULL,
    category      TEXT NOT NULL,
    brand         TEXT,
    list_price    NUMERIC(12,2)
);

CREATE TABLE dw.dim_store (
    store_key     SERIAL PRIMARY KEY,
    store_code    TEXT NOT NULL UNIQUE,
    region        TEXT NOT NULL
);

-- ---------------------------------------------------------------------
-- Fact table (grain: one invoice line), partitioned by year
-- ---------------------------------------------------------------------
CREATE TABLE dw.fact_sales (
    date_key      INT    NOT NULL REFERENCES dw.dim_date(date_key),
    customer_key  BIGINT NOT NULL REFERENCES dw.dim_customer(customer_key),
    product_key   BIGINT NOT NULL REFERENCES dw.dim_product(product_key),
    store_key     INT    NOT NULL REFERENCES dw.dim_store(store_key),
    invoice_no    TEXT   NOT NULL,
    line_no       INT    NOT NULL,
    quantity      INT    NOT NULL,
    gross_amount  NUMERIC(14,2) NOT NULL,
    discount_amt  NUMERIC(14,2) NOT NULL,
    net_amount    NUMERIC(14,2) NOT NULL,
    batch_id      BIGINT NOT NULL,
    PRIMARY KEY (date_key, invoice_no, line_no)
) PARTITION BY RANGE (date_key);

CREATE TABLE dw.fact_sales_2025 PARTITION OF dw.fact_sales FOR VALUES FROM (20250101) TO (20260101);
CREATE TABLE dw.fact_sales_2026 PARTITION OF dw.fact_sales FOR VALUES FROM (20260101) TO (20270101);
CREATE TABLE dw.fact_sales_default PARTITION OF dw.fact_sales DEFAULT;

CREATE INDEX ON dw.fact_sales (customer_key);
CREATE INDEX ON dw.fact_sales (product_key);

-- ETL run log
CREATE TABLE dw.etl_batches (
    batch_id     BIGSERIAL PRIMARY KEY,
    started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at  TIMESTAMPTZ,
    rows_loaded  INT, rows_rejected INT,
    status       TEXT NOT NULL DEFAULT 'running'
);

-- Populate the date dimension 2024–2027
INSERT INTO dw.dim_date
SELECT to_char(d, 'YYYYMMDD')::int, d,
       extract(year FROM d), extract(quarter FROM d), extract(month FROM d), to_char(d, 'Mon'),
       extract(week FROM d), extract(isodow FROM d), to_char(d, 'Dy'),
       extract(isodow FROM d) IN (6, 7)
FROM generate_series(DATE '2024-01-01', DATE '2027-12-31', INTERVAL '1 day') d;
