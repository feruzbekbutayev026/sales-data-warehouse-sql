-- =====================================================================
-- OLAP queries on the star schema
-- =====================================================================

-- 1. ROLLUP: revenue by year > quarter with subtotals and grand total
SELECT coalesce(d.year::text, 'TOTAL')      AS year,
       coalesce('Q' || d.quarter, '—')      AS quarter,
       sum(f.net_amount)                    AS net_revenue,
       count(DISTINCT f.invoice_no)         AS invoices
FROM dw.fact_sales f JOIN dw.dim_date d USING (date_key)
GROUP BY ROLLUP (d.year, d.quarter)
ORDER BY d.year NULLS LAST, d.quarter NULLS LAST;

-- 2. CUBE: region × category, with GROUPING() to label subtotal rows
SELECT CASE WHEN GROUPING(s.region)   = 1 THEN 'ALL REGIONS'    ELSE s.region   END AS region,
       CASE WHEN GROUPING(p.category) = 1 THEN 'ALL CATEGORIES' ELSE p.category END AS category,
       sum(f.net_amount) AS net_revenue
FROM dw.fact_sales f
JOIN dw.dim_store s   USING (store_key)
JOIN dw.dim_product p USING (product_key)
WHERE f.date_key BETWEEN 20260101 AND 20261231            -- partition pruning
GROUP BY CUBE (s.region, p.category)
ORDER BY GROUPING(s.region), region, GROUPING(p.category), net_revenue DESC;

-- 3. SCD2 in action: revenue by the customer's segment AT THE TIME of sale
--    vs. their CURRENT segment
SELECT hist.segment                              AS segment_at_sale,
       cur.segment                               AS current_segment,
       count(DISTINCT hist.customer_code)        AS customers,
       sum(f.net_amount)                         AS net_revenue
FROM dw.fact_sales f
JOIN dw.dim_customer hist ON hist.customer_key = f.customer_key
JOIN dw.dim_customer cur  ON cur.customer_code = hist.customer_code AND cur.is_current
WHERE hist.segment <> cur.segment
GROUP BY 1, 2;

-- 4. Same-store year-over-year growth (Jan–Sep), pivoted with FILTER
WITH s AS (
    SELECT st.store_code, d.year, sum(f.net_amount) AS rev
    FROM dw.fact_sales f
    JOIN dw.dim_date d   USING (date_key)
    JOIN dw.dim_store st USING (store_key)
    WHERE d.month BETWEEN 1 AND 9
    GROUP BY st.store_code, d.year
)
SELECT store_code,
       sum(rev) FILTER (WHERE year = 2025) AS rev_2025,
       sum(rev) FILTER (WHERE year = 2026) AS rev_2026,
       round(100 * (sum(rev) FILTER (WHERE year = 2026) / sum(rev) FILTER (WHERE year = 2025) - 1), 1) AS yoy_pct
FROM s GROUP BY store_code ORDER BY yoy_pct DESC;

-- 5. Weekend vs weekday basket size per region
SELECT s.region,
       round(avg(inv.basket) FILTER (WHERE inv.is_weekend), 2)     AS weekend_basket,
       round(avg(inv.basket) FILTER (WHERE NOT inv.is_weekend), 2) AS weekday_basket
FROM (
    SELECT f.invoice_no, f.store_key, d.is_weekend, sum(f.net_amount) AS basket
    FROM dw.fact_sales f JOIN dw.dim_date d USING (date_key)
    GROUP BY f.invoice_no, f.store_key, d.is_weekend
) inv
JOIN dw.dim_store s USING (store_key)
GROUP BY s.region ORDER BY s.region;

-- 6. Market-basket analysis: product pairs most often bought together
SELECT pa.product_name AS product_a, pb.product_name AS product_b, count(*) AS together
FROM dw.fact_sales a
JOIN dw.fact_sales b ON a.invoice_no = b.invoice_no AND a.product_key < b.product_key
JOIN dw.dim_product pa ON pa.product_key = a.product_key
JOIN dw.dim_product pb ON pb.product_key = b.product_key
GROUP BY 1, 2
HAVING count(*) >= 3
ORDER BY together DESC
LIMIT 10;

-- 7. Data quality checks (all should return 0)
SELECT 'customers with >1 current version' AS check, count(*) FROM (
    SELECT customer_code FROM dw.dim_customer WHERE is_current GROUP BY 1 HAVING count(*) > 1) x
UNION ALL
SELECT 'overlapping SCD2 ranges', count(*) FROM dw.dim_customer a
    JOIN dw.dim_customer b ON a.customer_code = b.customer_code AND a.customer_key < b.customer_key
     AND daterange(a.valid_from, a.valid_to, '[]') && daterange(b.valid_from, b.valid_to, '[]')
UNION ALL
SELECT 'rows in default partition', count(*) FROM dw.fact_sales_default
UNION ALL
SELECT 'net > gross', count(*) FROM dw.fact_sales WHERE net_amount > gross_amount;
