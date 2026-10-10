# Sales Data Warehouse in SQL

A complete mini data warehouse in **PostgreSQL**: a raw staging layer, a Kimball-style star schema, re-runnable ETL procedures with data validation, **Slowly Changing Dimensions (Type 1 & Type 2)**, a partitioned fact table and OLAP reporting queries.

## Architecture

```
 source files / systems
          │
          ▼
 ┌──────────────────┐   validate, clean, type-cast    ┌──────────────────────────┐
 │  stg.*_raw (TEXT)│ ─────────────────────────────▶ │  dw (star schema)         │
 │  stg.rejected_rows│ ◀── invalid rows + reason      │                          │
 └──────────────────┘                                 │   dim_date               │
                                                      │   dim_customer  (SCD2)   │
                                                      │   dim_product   (SCD1)   │
                                                      │   dim_store              │
                                                      │        ▲                 │
                                                      │   fact_sales (partitioned│
                                                      │   by year)               │
                                                      └──────────────────────────┘
```

## Highlights

- **SCD Type 2** customer dimension — change detection with `md5` row hashes, `valid_from / valid_to / is_current`, partial unique index guaranteeing one current version.
- **Point-in-time lookups** — each sale joins to the customer version valid on the sale date.
- **SCD Type 1** product dimension via `INSERT ... ON CONFLICT DO UPDATE ... WHERE IS DISTINCT FROM` (no-op updates skipped).
- **Data validation** — bad dates, quantities, prices, unknown keys go to `stg.rejected_rows` as JSONB with a reason.
- **Idempotent ETL** — batches can be re-run safely; run log in `dw.etl_batches`.
- **Declarative partitioning** of `fact_sales` by year with partition pruning.
- **OLAP** — `ROLLUP`, `CUBE`, `GROUPING()`, `FILTER` pivots, YoY growth, market-basket pairs, and data-quality checks using range overlap (`daterange &&`).

## Structure

```
01_staging_and_dw.sql  -- schemas, staging, dimensions, partitioned fact, date dimension
02_etl.sql             -- load_dim_customer (SCD2), load_dim_product (SCD1), load_fact_sales, run_etl
03_demo_load.sql       -- two batches of messy demo data + a re-run
04_olap_queries.sql    -- reporting and data-quality queries
```

## Run it

```bash
createdb dwh
for f in 0*.sql; do psql -d dwh -v ON_ERROR_STOP=1 -f "$f"; done
```

## Sample results

ETL run log:

| batch_id | status | rows_loaded | rows_rejected |
|---|---|---|---|
| 1 | success | 13929 | 805 |
| 2 | success | 17522 | 0 |

Rejected rows by reason: unknown customer 571, invalid date 164, invalid quantity 70.

Data-quality checks (all `0`): duplicate current versions, overlapping SCD2 ranges, rows in default partition, net > gross.

Requires PostgreSQL 14+ (tested on 16).
