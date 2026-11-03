-- =====================================================================
-- BUS 450 Final Year Project - Pham Thuy Huyen 
-- SQL PIPELINE: DataCo Smart Supply Chain star schema for Power BI
-- PostgreSQL | Database: supply_chain_analytics | Schema: supply_chain
--
-- What this file does, in run order:
--   Step 1  Create the schema
--   Step 2  Create the six dimension tables (primary keys)
--   Step 3  Create the fact table (primary key, unique key, checks and
--           the seven foreign keys that define the relationships)
--   Step 4  Load the seven CSV files (dimensions first, fact last)
--   Step 5  Create indexes on the fact table keys
--   Step 6  Check the loaded data
--   Step 7  Create the summary views
--   Step 8  Notes for connecting Power BI
--
-- The result is a database that Power BI can import directly: the keys
-- and relationships are defined here, not built by hand in Power BI.
--
-- Input: the seven CSV files written by the cleaning notebook
-- (folder star_schema). Run this file on an EMPTY database. It contains
-- no DROP, DELETE or TRUNCATE statement. If the tables already hold
-- data, Step 4 stops with a duplicate-key error instead of loading the
-- rows twice.
--
-- Steps 1-3 and 5 are the same SQL as "create schema.sql" and
-- "create index.sql". IF NOT EXISTS is added so the steps can be run
-- again safely.
-- =====================================================================


-- =====================================================================
-- STEP 1. SCHEMA
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS supply_chain;
SET search_path TO supply_chain;


-- =====================================================================
-- STEP 2. DIMENSION TABLES
-- One row per member. Each table has a surrogate key (*_key) as its
-- primary key; the fact table refers to these keys.
-- =====================================================================

-- 2.1 Shipping mode (4 rows)
CREATE TABLE IF NOT EXISTS supply_chain.dim_shipping (
    shipping_key INTEGER PRIMARY KEY,
    shipping_mode VARCHAR(50) NOT NULL
);

-- 2.2 Product, category and department (118 rows)
CREATE TABLE IF NOT EXISTS supply_chain.dim_product (
    product_key INTEGER PRIMARY KEY,
    product_card_id INTEGER NOT NULL,
    product_name VARCHAR(255),
    product_status INTEGER,
    product_category_id INTEGER,
    category_name VARCHAR(255),
    department_id INTEGER,
    department_name VARCHAR(255)
);

-- 2.3 Customer (20,652 rows)
CREATE TABLE IF NOT EXISTS supply_chain.dim_customer (
    customer_key INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL,
    customer_segment VARCHAR(100),
    customer_city VARCHAR(255),
    customer_state VARCHAR(255),
    customer_country VARCHAR(255)
);

-- 2.4 Calendar (1,133 rows). date_key has the form YYYYMMDD.
-- Used twice by the fact table: order date and shipping date.
CREATE TABLE IF NOT EXISTS supply_chain.dim_date (
    date_key INTEGER PRIMARY KEY,
    full_date DATE NOT NULL,
    year INTEGER NOT NULL,
    quarter INTEGER NOT NULL,
    month_number INTEGER NOT NULL,
    month_name VARCHAR(20) NOT NULL,
    year_month VARCHAR(7) NOT NULL,
    week_of_year INTEGER NOT NULL,
    day_of_month INTEGER,
    day_of_week INTEGER,
    day_name VARCHAR(20),
    is_weekend BOOLEAN
);

-- 2.5 Order destination: market, region, country, state, city (3,772 rows)
CREATE TABLE IF NOT EXISTS supply_chain.dim_geography (
    geography_key INTEGER PRIMARY KEY,
    market VARCHAR(100),
    order_region VARCHAR(255),
    order_country VARCHAR(255),
    order_state VARCHAR(255),
    order_city VARCHAR(255)
);

-- 2.6 Payment type, order status and delivery status combinations (23 rows)
CREATE TABLE IF NOT EXISTS supply_chain.dim_order_profile (
    order_profile_key INTEGER PRIMARY KEY,
    payment_type VARCHAR(50),
    order_status VARCHAR(100),
    delivery_status VARCHAR(100)
);


-- =====================================================================
-- STEP 3. FACT TABLE
-- Grain: one row per order item (180,519 rows).
-- The seven FOREIGN KEY constraints are the relationships of the star
-- schema: each one links a fact column to the primary key of a dimension.
-- =====================================================================

CREATE TABLE IF NOT EXISTS supply_chain.fact_order_items (
    fact_key BIGINT PRIMARY KEY,

    -- Business and degenerate keys
    order_item_id BIGINT NOT NULL,
    order_id BIGINT NOT NULL,

    -- Foreign keys
    order_date_key INTEGER NOT NULL,
    shipping_date_key INTEGER NOT NULL,
    product_key INTEGER NOT NULL,
    customer_key INTEGER NOT NULL,
    geography_key INTEGER NOT NULL,
    shipping_key INTEGER NOT NULL,
    order_profile_key INTEGER NOT NULL,

    -- Demand and sales measures
    quantity INTEGER NOT NULL,
    unit_price NUMERIC(14, 2),
    discount_amount NUMERIC(14, 2),
    discount_rate NUMERIC(10, 6),
    gross_sales NUMERIC(14, 2),
    net_revenue NUMERIC(14, 2),

    -- Profitability measures
    profit_amount NUMERIC(14, 2),
    profit_ratio NUMERIC(10, 6),

    -- Logistics measures
    scheduled_shipping_days INTEGER,
    actual_shipping_days INTEGER,
    shipping_delay_days INTEGER,
    late_delivery_risk INTEGER,
    is_late BOOLEAN,

    -- Business key constraint
    CONSTRAINT uq_fact_order_item
        UNIQUE (order_item_id),

    -- Foreign-key constraints (relationships)
    CONSTRAINT fk_fact_order_date
        FOREIGN KEY (order_date_key)
        REFERENCES supply_chain.dim_date(date_key),

    CONSTRAINT fk_fact_shipping_date
        FOREIGN KEY (shipping_date_key)
        REFERENCES supply_chain.dim_date(date_key),

    CONSTRAINT fk_fact_product
        FOREIGN KEY (product_key)
        REFERENCES supply_chain.dim_product(product_key),

    CONSTRAINT fk_fact_customer
        FOREIGN KEY (customer_key)
        REFERENCES supply_chain.dim_customer(customer_key),

    CONSTRAINT fk_fact_geography
        FOREIGN KEY (geography_key)
        REFERENCES supply_chain.dim_geography(geography_key),

    CONSTRAINT fk_fact_shipping
        FOREIGN KEY (shipping_key)
        REFERENCES supply_chain.dim_shipping(shipping_key),

    CONSTRAINT fk_fact_order_profile
        FOREIGN KEY (order_profile_key)
        REFERENCES supply_chain.dim_order_profile(order_profile_key),

    -- Data-quality constraints
    CONSTRAINT chk_quantity_positive
        CHECK (quantity > 0),

    CONSTRAINT chk_late_delivery_risk
        CHECK (late_delivery_risk IN (0, 1)),

    CONSTRAINT chk_shipping_days
        CHECK (
            scheduled_shipping_days >= 0
            AND actual_shipping_days >= 0
        )
);


-- =====================================================================
-- STEP 4. LOAD THE CSV FILES
-- Dimensions are loaded before the fact table, because every fact row
-- must find its dimension rows (foreign keys).
--
-- Option A: pgAdmin Import/Export dialog.
--   Right-click each table > Import/Export Data > Import, choose the
--   CSV file, Format csv, Header ON, Delimiter ",", Encoding UTF8.
--   Use the same order as the COPY statements below.
--
-- Option B: the COPY statements below. Replace <folder> with the full
--   path of the star_schema folder. COPY reads the file on the database
--   server, so the server must be allowed to read that folder (the
--   user needs the pg_read_server_files role). If it gives a
--   "permission denied" error, use Option A.
--
-- Notes on the CSV files:
--   - COPY matches columns by position, not by header name. In
--     dim_order_profile.csv the first data column is called "type";
--     it is loaded into payment_type.
--   - is_weekend and is_late are written as True/False; PostgreSQL
--     reads these as BOOLEAN.
-- =====================================================================

/*
COPY supply_chain.dim_shipping (shipping_key, shipping_mode)
FROM '<folder>/dim_shipping.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

COPY supply_chain.dim_product (product_key, product_card_id, product_name, product_status,
    product_category_id, category_name, department_id, department_name)
FROM '<folder>/dim_product.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

COPY supply_chain.dim_customer (customer_key, customer_id, customer_segment,
    customer_city, customer_state, customer_country)
FROM '<folder>/dim_customer.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

COPY supply_chain.dim_date (date_key, full_date, year, quarter, month_number, month_name,
    year_month, week_of_year, day_of_month, day_of_week, day_name, is_weekend)
FROM '<folder>/dim_date.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

COPY supply_chain.dim_geography (geography_key, market, order_region,
    order_country, order_state, order_city)
FROM '<folder>/dim_geography.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

COPY supply_chain.dim_order_profile (order_profile_key, payment_type, order_status, delivery_status)
FROM '<folder>/dim_order_profile.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

COPY supply_chain.fact_order_items (fact_key, order_item_id, order_id, order_date_key,
    shipping_date_key, product_key, customer_key, geography_key, shipping_key,
    order_profile_key, quantity, unit_price, discount_amount, discount_rate,
    gross_sales, net_revenue, profit_amount, profit_ratio, scheduled_shipping_days,
    actual_shipping_days, shipping_delay_days, late_delivery_risk, is_late)
FROM '<folder>/fact_order_items.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');
*/


-- =====================================================================
-- STEP 5. INDEXES
-- PostgreSQL already creates an index for every primary key and for
-- the unique key. These eight indexes cover the fact table columns
-- used in joins and filters, which speeds up the joins with the
-- dimensions and the Power BI refresh.
-- Total after this step: 7 (primary keys) + 1 (unique) + 8 = 16 indexes.
-- =====================================================================

CREATE INDEX IF NOT EXISTS idx_fact_order_id
ON supply_chain.fact_order_items(order_id);

CREATE INDEX IF NOT EXISTS idx_fact_order_date
ON supply_chain.fact_order_items(order_date_key);

CREATE INDEX IF NOT EXISTS idx_fact_shipping_date
ON supply_chain.fact_order_items(shipping_date_key);

CREATE INDEX IF NOT EXISTS idx_fact_product
ON supply_chain.fact_order_items(product_key);

CREATE INDEX IF NOT EXISTS idx_fact_customer
ON supply_chain.fact_order_items(customer_key);

CREATE INDEX IF NOT EXISTS idx_fact_geography
ON supply_chain.fact_order_items(geography_key);

CREATE INDEX IF NOT EXISTS idx_fact_shipping
ON supply_chain.fact_order_items(shipping_key);

CREATE INDEX IF NOT EXISTS idx_fact_order_profile
ON supply_chain.fact_order_items(order_profile_key);

-- Update the planner statistics after a large load
ANALYZE supply_chain.fact_order_items;


-- =====================================================================
-- STEP 6. CHECK THE LOADED DATA (read only)
-- Expected values were confirmed in this database on 2026-11-03.
-- =====================================================================

-- 6.1 Row counts
-- Expected: dim_date 1,133 | dim_product 118 | dim_customer 20,652 |
--           dim_geography 3,772 | dim_shipping 4 | dim_order_profile 23 |
--           fact_order_items 180,519 (same as the cleaned CSV)
SELECT 'dim_date' AS table_name, COUNT(*) AS row_count FROM supply_chain.dim_date
UNION ALL SELECT 'dim_product', COUNT(*) FROM supply_chain.dim_product
UNION ALL SELECT 'dim_customer', COUNT(*) FROM supply_chain.dim_customer
UNION ALL SELECT 'dim_geography', COUNT(*) FROM supply_chain.dim_geography
UNION ALL SELECT 'dim_shipping', COUNT(*) FROM supply_chain.dim_shipping
UNION ALL SELECT 'dim_order_profile', COUNT(*) FROM supply_chain.dim_order_profile
UNION ALL SELECT 'fact_order_items', COUNT(*) FROM supply_chain.fact_order_items;

-- 6.2 Keys, relationships and indexes in the schema
-- Expected: 7 base tables, 3 views (after Step 7), 7 primary keys,
--           7 foreign keys, 1 unique key, 3 check constraints, 16 indexes
SELECT 'object' AS kind, table_type AS detail, COUNT(*) AS n
FROM information_schema.tables
WHERE table_schema = 'supply_chain'
GROUP BY table_type
UNION ALL
SELECT 'constraint', constraint_type, COUNT(*)
FROM information_schema.table_constraints
WHERE table_schema = 'supply_chain'
  AND constraint_type IN ('PRIMARY KEY', 'FOREIGN KEY', 'UNIQUE')
GROUP BY constraint_type
UNION ALL
SELECT 'check', 'CHECK (excluding NOT NULL)', COUNT(*)
FROM pg_constraint AS c
JOIN pg_namespace AS s ON s.oid = c.connamespace
WHERE s.nspname = 'supply_chain' AND c.contype = 'c'
UNION ALL
SELECT 'index', 'all indexes', COUNT(*)
FROM pg_indexes
WHERE schemaname = 'supply_chain';

-- 6.3 Each relationship: fact column -> dimension key
-- Expected: 7 rows, one per foreign key
SELECT
    tc.constraint_name,
    kcu.column_name AS fact_column,
    ccu.table_name AS dimension_table,
    ccu.column_name AS dimension_key
FROM information_schema.table_constraints AS tc
JOIN information_schema.key_column_usage AS kcu
    ON tc.constraint_name = kcu.constraint_name
   AND tc.table_schema = kcu.table_schema
JOIN information_schema.constraint_column_usage AS ccu
    ON tc.constraint_name = ccu.constraint_name
   AND tc.table_schema = ccu.table_schema
WHERE tc.table_schema = 'supply_chain'
  AND tc.constraint_type = 'FOREIGN KEY'
ORDER BY tc.constraint_name;

-- 6.4 Join check: the fact table joins to all six dimensions
-- (same query as fact.sql). Expected: 20 rows with no empty dimension
-- columns.
SELECT
    f.order_id,
    f.order_item_id,
    od.full_date AS order_date,
    sd.full_date AS shipping_date,
    p.product_name,
    p.category_name,
    c.customer_segment,
    g.market,
    g.order_region,
    s.shipping_mode,
    op.payment_type,
    op.order_status,
    op.delivery_status,
    f.quantity,
    f.net_revenue,
    f.profit_amount,
    f.shipping_delay_days,
    f.is_late
FROM supply_chain.fact_order_items AS f
JOIN supply_chain.dim_date AS od ON f.order_date_key = od.date_key
JOIN supply_chain.dim_date AS sd ON f.shipping_date_key = sd.date_key
JOIN supply_chain.dim_product AS p ON f.product_key = p.product_key
JOIN supply_chain.dim_customer AS c ON f.customer_key = c.customer_key
JOIN supply_chain.dim_geography AS g ON f.geography_key = g.geography_key
JOIN supply_chain.dim_shipping AS s ON f.shipping_key = s.shipping_key
JOIN supply_chain.dim_order_profile AS op ON f.order_profile_key = op.order_profile_key
LIMIT 20;

-- 6.5 Inner joins keep every fact row (no row is lost in the model)
-- Expected: 180,519
SELECT COUNT(*) AS joined_rows
FROM supply_chain.fact_order_items AS f
JOIN supply_chain.dim_date AS od ON f.order_date_key = od.date_key
JOIN supply_chain.dim_date AS sd ON f.shipping_date_key = sd.date_key
JOIN supply_chain.dim_product AS p ON f.product_key = p.product_key
JOIN supply_chain.dim_customer AS c ON f.customer_key = c.customer_key
JOIN supply_chain.dim_geography AS g ON f.geography_key = g.geography_key
JOIN supply_chain.dim_shipping AS s ON f.shipping_key = s.shipping_key
JOIN supply_chain.dim_order_profile AS op ON f.order_profile_key = op.order_profile_key;

-- 6.6 KPI reconciliation with the Power BI dashboard
-- The dashboard covers orders from 2015-01-01 to 2017-09-30
-- (report filter Month Start < 2017-10-01).
-- Expected: 57,349 orders | 375,287 units | 30,774,233.58 revenue |
--           3,685,985.03 profit | 31,412 late orders | 54.77% late
SELECT
    COUNT(DISTINCT f.order_id) AS total_orders,
    SUM(f.quantity) AS total_units,
    ROUND(SUM(f.net_revenue), 2) AS total_revenue,
    ROUND(SUM(f.profit_amount), 2) AS total_profit,
    COUNT(DISTINCT f.order_id) FILTER (WHERE f.is_late) AS late_orders,
    ROUND(100.0 * COUNT(DISTINCT f.order_id) FILTER (WHERE f.is_late)
          / COUNT(DISTINCT f.order_id), 2) AS late_delivery_pct
FROM supply_chain.fact_order_items AS f
JOIN supply_chain.dim_date AS d ON f.order_date_key = d.date_key
WHERE d.full_date < DATE '2017-10-01';


-- =====================================================================
-- STEP 7. SUMMARY VIEWS
-- These are the three views that are in the database now (created
-- 2026-08-11). They cover the whole data period, including
-- 2017-10 to 2018-01, and their late_delivery_rate is the share of
-- order ITEMS that are late. The dashboard instead uses 2015-01 to
-- 2017-09 and the share of ORDERS, so the view figures differ slightly
-- from the dashboard. Power BI imports the tables, not these views.
-- A version filtered to 2017-09 and counted per order is in
-- supply_chain_queries.sql, section 6 (not run).
-- =====================================================================

CREATE OR REPLACE VIEW supply_chain.vw_monthly_performance AS
SELECT
    d.year,
    d.month_number,
    d.month_name,
    d.year_month,
    COUNT(DISTINCT f.order_id) AS total_orders,
    SUM(f.quantity) AS total_quantity,
    ROUND(SUM(f.net_revenue), 2) AS total_revenue,
    ROUND(SUM(f.profit_amount), 2) AS total_profit,
    ROUND(AVG(f.late_delivery_risk::NUMERIC) * 100, 2) AS late_delivery_rate
FROM supply_chain.fact_order_items AS f
JOIN supply_chain.dim_date AS d
    ON f.order_date_key = d.date_key
GROUP BY d.year, d.month_number, d.month_name, d.year_month;

CREATE OR REPLACE VIEW supply_chain.vw_product_performance AS
SELECT
    p.department_name,
    p.category_name,
    p.product_name,
    COUNT(DISTINCT f.order_id) AS total_orders,
    SUM(f.quantity) AS total_quantity,
    ROUND(SUM(f.net_revenue), 2) AS total_revenue,
    ROUND(SUM(f.profit_amount), 2) AS total_profit
FROM supply_chain.fact_order_items AS f
JOIN supply_chain.dim_product AS p
    ON f.product_key = p.product_key
GROUP BY p.department_name, p.category_name, p.product_name;

CREATE OR REPLACE VIEW supply_chain.vw_delivery_performance AS
SELECT
    s.shipping_mode,
    g.market,
    g.order_region,
    COUNT(DISTINCT f.order_id) AS total_orders,
    ROUND(AVG(f.actual_shipping_days::NUMERIC), 2) AS average_shipping_days,
    ROUND(AVG(f.shipping_delay_days::NUMERIC), 2) AS average_shipping_delay,
    ROUND(AVG(f.late_delivery_risk::NUMERIC) * 100, 2) AS late_delivery_rate
FROM supply_chain.fact_order_items AS f
JOIN supply_chain.dim_shipping AS s
    ON f.shipping_key = s.shipping_key
JOIN supply_chain.dim_geography AS g
    ON f.geography_key = g.geography_key
GROUP BY s.shipping_mode, g.market, g.order_region;


-- =====================================================================
-- STEP 8. CONNECTING POWER BI (notes, nothing to run)
--
-- 1. Power BI Desktop > Get Data > PostgreSQL database.
--    Server: localhost (port 5432 unless changed),
--    Database: supply_chain_analytics, Data Connectivity mode: Import.
-- 2. In the Navigator select the seven tables of schema supply_chain:
--    fact_order_items and the six dim_ tables.
-- 3. Relationships. Before loading, File > Options and settings >
--    Options > Current File > Data Load > "Import relationships from
--    data sources" lets Power BI read the foreign keys above. Check
--    the result in Model view: there should be seven one-to-many
--    relationships, dimension (1) -> fact_order_items (*), single
--    direction. If any is missing, the foreign keys in Step 3 show
--    exactly which columns to link.
-- 4. dim_date is linked twice (order_date_key and shipping_date_key).
--    Power BI keeps only one active relationship between two tables:
--    order_date_key -> dim_date is active and is used by all pages;
--    shipping_date_key -> dim_date is inactive and is only used with
--    USERELATIONSHIP in a DAX measure.
-- 5. Mark dim_date as the date table (column full_date).
-- 6. The report filter Month Start < 2017-10-01 limits the dashboard
--    to 2015-01 to 2017-09; the KPI query in 6.6 gives the same totals.
-- =====================================================================
