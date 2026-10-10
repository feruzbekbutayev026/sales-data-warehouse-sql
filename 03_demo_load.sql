-- =====================================================================
-- Demo: two ETL batches with dirty data and a customer attribute change
-- =====================================================================
SELECT setseed(0.7);

INSERT INTO dw.dim_store (store_code, region) VALUES
  ('TAS-01', 'Tashkent'), ('TAS-02', 'Tashkent'), ('SAM-01', 'Samarkand'),
  ('BUK-01', 'Bukhara'),  ('FER-01', 'Fergana'),  ('ONLINE', 'Online');

-- ------------------------- Batch 1 (as of 2025-01-01) -----------------
INSERT INTO stg.customers_raw (customer_code, full_name, city, segment, extracted_at)
SELECT ' c' || lpad(g::text, 4, '0') || ' ',                       -- messy whitespace / case
       lower('customer ' || g),
       (ARRAY['tashkent','samarkand','bukhara','fergana','namangan'])[1 + g % 5],
       (ARRAY['retail','retail','wholesale','vip',''])[1 + g % 5],
       '2025-01-01'
FROM generate_series(1, 500) g;

INSERT INTO stg.products_raw (sku, product_name, category, brand, list_price, extracted_at)
SELECT 'sku-' || g, 'Product ' || g,
       (ARRAY['beverages','snacks','dairy','household','electronics'])[1 + g % 5],
       (ARRAY['Alpha','Beta','Gamma',''])[1 + g % 4],
       CASE WHEN g % 50 = 0 THEN 'n/a' ELSE (1 + g % 97)::text || '.99' END,
       '2025-01-01'
FROM generate_series(1, 120) g;

INSERT INTO stg.sales_raw
SELECT 'INV-' || inv, ln::text,
       CASE WHEN random() < 0.01 THEN '31/02/2025' ELSE d::text END,  -- 1% bad dates
       'C' || lpad((1 + floor(random() * 520))::text, 4, '0'),          -- some unknown customers
       'SKU-' || (1 + floor(random() * 120))::int,
       (ARRAY['TAS-01','TAS-02','SAM-01','BUK-01','FER-01','ONLINE'])[1 + floor(random() * 6)::int],
       CASE WHEN random() < 0.005 THEN '-1' ELSE (1 + floor(random() * 5))::text END,
       (1 + floor(random() * 97))::text || '.99',
       (ARRAY['0','0','0','5','10','15'])[1 + floor(random() * 6)::int],
       1
FROM (SELECT g AS inv, DATE '2025-01-01' + (g % 365) AS d, 1 + floor(random() * 4)::int AS n_lines
      FROM generate_series(1, 6000) g) i
CROSS JOIN LATERAL generate_series(1, i.n_lines) ln;

CALL dw.run_etl(1, '2025-01-01');

-- ------------------------- Batch 2 (as of 2026-01-01) -----------------
-- 40 customers move city / change segment -> SCD2 creates new versions
TRUNCATE stg.customers_raw;
INSERT INTO stg.customers_raw (customer_code, full_name, city, segment, extracted_at)
SELECT 'C' || lpad(g::text, 4, '0'), 'Customer ' || g,
       CASE WHEN g <= 40 THEN 'Tashkent' ELSE (ARRAY['tashkent','samarkand','bukhara','fergana','namangan'])[1 + g % 5] END,
       CASE WHEN g <= 40 THEN 'vip'      ELSE (ARRAY['retail','retail','wholesale','vip',''])[1 + g % 5] END,
       '2026-01-01'
FROM generate_series(1, 520) g;                                          -- 20 brand-new customers

INSERT INTO stg.sales_raw
SELECT 'INV-' || inv, ln::text, d::text,
       'C' || lpad((1 + floor(random() * 520))::text, 4, '0'),
       'SKU-' || (1 + floor(random() * 120))::int,
       (ARRAY['TAS-01','TAS-02','SAM-01','BUK-01','FER-01','ONLINE'])[1 + floor(random() * 6)::int],
       (1 + floor(random() * 5))::text,
       (1 + floor(random() * 97))::text || '.99',
       (ARRAY['0','0','5','10'])[1 + floor(random() * 4)::int],
       2
FROM (SELECT g AS inv, DATE '2026-01-01' + (g % 270) AS d, 1 + floor(random() * 4)::int AS n_lines
      FROM generate_series(6001, 13000) g) i
CROSS JOIN LATERAL generate_series(1, i.n_lines) ln;

CALL dw.run_etl(2, '2026-01-01');

-- Re-running a batch is safe (idempotent fact load)
CALL dw.run_etl(2, '2026-01-01');

SELECT batch_id, status, rows_loaded, rows_rejected FROM dw.etl_batches ORDER BY batch_id;
SELECT reason, count(*) FROM stg.rejected_rows GROUP BY reason ORDER BY 2 DESC;
