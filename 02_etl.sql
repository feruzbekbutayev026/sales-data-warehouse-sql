-- =====================================================================
-- ETL procedures: validate → transform → load (SCD1, SCD2, facts)
-- =====================================================================

-- ---------------------------------------------------------------------
-- SCD Type 2 load for customers
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE dw.load_dim_customer(p_as_of DATE)
LANGUAGE plpgsql AS $$
DECLARE v_closed INT; v_inserted INT;
BEGIN
    DROP TABLE IF EXISTS src;
    CREATE TEMP TABLE src ON COMMIT DROP AS
    SELECT DISTINCT ON (upper(trim(customer_code)))
           upper(trim(customer_code))        AS customer_code,
           initcap(trim(full_name))           AS full_name,
           initcap(trim(city))                AS city,
           coalesce(nullif(lower(trim(segment)), ''), 'retail') AS segment,
           md5(concat_ws('|', initcap(trim(full_name)), initcap(trim(city)),
                       coalesce(nullif(lower(trim(segment)), ''), 'retail'))) AS row_hash
    FROM stg.customers_raw
    WHERE nullif(trim(customer_code), '') IS NOT NULL
    ORDER BY upper(trim(customer_code)), extracted_at DESC;

    -- 1) Expire current rows whose attributes changed
    UPDATE dw.dim_customer d
       SET valid_to = p_as_of - 1, is_current = FALSE
      FROM src s
     WHERE d.customer_code = s.customer_code AND d.is_current AND d.row_hash <> s.row_hash;
    GET DIAGNOSTICS v_closed = ROW_COUNT;

    -- 2) Insert new versions (new customers + changed ones)
    INSERT INTO dw.dim_customer (customer_code, full_name, city, segment, row_hash, valid_from)
    SELECT s.customer_code, s.full_name, s.city, s.segment, s.row_hash, p_as_of
    FROM src s
    WHERE NOT EXISTS (SELECT 1 FROM dw.dim_customer d
                      WHERE d.customer_code = s.customer_code AND d.is_current);
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    RAISE NOTICE 'dim_customer: % versions closed, % rows inserted', v_closed, v_inserted;
END $$;

-- ---------------------------------------------------------------------
-- SCD Type 1 upsert for products
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE dw.load_dim_product()
LANGUAGE sql AS $$
    INSERT INTO dw.dim_product (sku, product_name, category, brand, list_price)
    SELECT DISTINCT ON (upper(trim(sku)))
           upper(trim(sku)), trim(product_name), initcap(trim(category)),
           nullif(trim(brand), ''),
           CASE WHEN list_price ~ '^\s*\d+(\.\d+)?\s*$' THEN list_price::numeric END
    FROM stg.products_raw
    WHERE nullif(trim(sku), '') IS NOT NULL
    ORDER BY upper(trim(sku)), extracted_at DESC
    ON CONFLICT (sku) DO UPDATE
       SET product_name = EXCLUDED.product_name,
           category     = EXCLUDED.category,
           brand        = EXCLUDED.brand,
           list_price   = EXCLUDED.list_price
     WHERE (dw.dim_product.product_name, dw.dim_product.category, dw.dim_product.brand, dw.dim_product.list_price)
           IS DISTINCT FROM (EXCLUDED.product_name, EXCLUDED.category, EXCLUDED.brand, EXCLUDED.list_price);
$$;

-- ---------------------------------------------------------------------
-- Fact load with validation, rejects table and point-in-time SCD2 lookup
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE dw.load_fact_sales(p_batch BIGINT)
LANGUAGE plpgsql AS $$
DECLARE v_loaded INT; v_rejected INT;
BEGIN
    DELETE FROM stg.rejected_rows WHERE batch_id = p_batch;   -- re-runs replace old rejects
    DROP TABLE IF EXISTS typed;
    CREATE TEMP TABLE typed ON COMMIT DROP AS
    SELECT r.*,
           CASE WHEN sold_at ~ '^\d{4}-\d{2}-\d{2}' THEN sold_at::date END               AS d,
           CASE WHEN qty ~ '^\d+$' THEN qty::int END                                     AS q,
           CASE WHEN unit_price ~ '^\d+(\.\d+)?$' THEN unit_price::numeric END           AS p,
           coalesce(CASE WHEN discount_pct ~ '^\d+(\.\d+)?$' THEN discount_pct::numeric END, 0) AS disc
    FROM stg.sales_raw r
    WHERE batch_id = p_batch;

    -- Reject invalid rows with a reason
    INSERT INTO stg.rejected_rows (source, payload, reason, batch_id)
    SELECT 'sales_raw', to_jsonb(t) - 'd' - 'q' - 'p' - 'disc',
           CASE
             WHEN t.d IS NULL                 THEN 'invalid date'
             WHEN t.q IS NULL OR t.q = 0      THEN 'invalid quantity'
             WHEN t.p IS NULL                 THEN 'invalid price'
             WHEN t.disc > 100                THEN 'discount > 100%'
             WHEN pr.product_key IS NULL      THEN 'unknown product'
             WHEN st.store_key IS NULL        THEN 'unknown store'
             WHEN c.customer_key IS NULL      THEN 'unknown customer'
           END,
           p_batch
    FROM typed t
    LEFT JOIN dw.dim_product pr ON pr.sku = upper(trim(t.sku))
    LEFT JOIN dw.dim_store   st ON st.store_code = upper(trim(t.store_code))
    LEFT JOIN dw.dim_customer c ON c.customer_code = upper(trim(t.customer_code))
                               AND t.d BETWEEN c.valid_from AND c.valid_to
    WHERE t.d IS NULL OR t.q IS NULL OR t.q = 0 OR t.p IS NULL OR t.disc > 100
       OR pr.product_key IS NULL OR st.store_key IS NULL OR c.customer_key IS NULL;
    GET DIAGNOSTICS v_rejected = ROW_COUNT;

    -- Load valid rows; customer resolved to the version valid on the sale date
    INSERT INTO dw.fact_sales (date_key, customer_key, product_key, store_key, invoice_no, line_no,
                               quantity, gross_amount, discount_amt, net_amount, batch_id)
    SELECT to_char(t.d, 'YYYYMMDD')::int, c.customer_key, pr.product_key, st.store_key,
           trim(t.invoice_no), t.line_no::int, t.q,
           round(t.q * t.p, 2),
           round(t.q * t.p * t.disc / 100, 2),
           round(t.q * t.p * (1 - t.disc / 100), 2),
           p_batch
    FROM typed t
    JOIN dw.dim_product pr ON pr.sku = upper(trim(t.sku))
    JOIN dw.dim_store   st ON st.store_code = upper(trim(t.store_code))
    JOIN dw.dim_customer c ON c.customer_code = upper(trim(t.customer_code))
                          AND t.d BETWEEN c.valid_from AND c.valid_to
    WHERE t.q > 0 AND t.p IS NOT NULL AND t.disc <= 100
    ON CONFLICT (date_key, invoice_no, line_no) DO NOTHING;   -- re-runnable
    GET DIAGNOSTICS v_loaded = ROW_COUNT;

    UPDATE dw.etl_batches
       SET rows_loaded   = (SELECT count(*) FROM dw.fact_sales WHERE batch_id = p_batch),
           rows_rejected = v_rejected
     WHERE batch_id = p_batch;
    RAISE NOTICE 'fact_sales batch %: % loaded, % rejected', p_batch, v_loaded, v_rejected;
END $$;

-- ---------------------------------------------------------------------
-- Orchestrator
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE dw.run_etl(p_batch BIGINT, p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO dw.etl_batches (batch_id) VALUES (p_batch)
    ON CONFLICT (batch_id) DO UPDATE SET started_at = now(), status = 'running';

    CALL dw.load_dim_customer(p_as_of);
    CALL dw.load_dim_product();
    CALL dw.load_fact_sales(p_batch);

    UPDATE dw.etl_batches SET finished_at = now(), status = 'success' WHERE batch_id = p_batch;
EXCEPTION WHEN OTHERS THEN
    -- Partial work is rolled back; only the failure is recorded
    UPDATE dw.etl_batches SET finished_at = now(), status = 'failed: ' || SQLERRM WHERE batch_id = p_batch;
    RAISE WARNING 'ETL batch % failed: %', p_batch, SQLERRM;
END $$;
