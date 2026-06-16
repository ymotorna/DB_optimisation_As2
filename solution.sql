CREATE EXTENSION IF NOT EXISTS pg_stat_statements;


-- query history
SELECT
    query,
    calls,
    round(total_exec_time::numeric,2) as tot_exec_time,
    round(mean_exec_time::numeric,2) as avg_exec_time,
    rows
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 100;


--  Identify blocked sessions and their corresponding blocking sessions
SELECT
blocked.pid AS blocked_pid,
blocked.usename AS blocked_user,
blocked.query AS blocked_query,
blocking.pid AS blocking_pid,
blocking.usename AS blocking_user,
blocking.query AS blocking_query,
blocked.wait_event_type,
blocked.wait_event
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking
ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
ORDER BY blocked.pid;


-- Detect long-running transactions that may be causing lock contention
SELECT
pid,
usename,
state,
xact_start,
now() - xact_start AS transaction_duration,
query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY xact_start;


-- List active sessions currently waiting to acquire a lock
SELECT
pid,
usename,
state,
wait_event_type,
wait_event,
query_start,
now() - query_start AS running_for,
query
FROM pg_stat_activity
WHERE wait_event_type = 'Lock';





-- ---------------- listed by pg_stat_statements tot_exec_time desc
-- 1) -------------------------------------------------------------------------------------------
begin;
explain ANALYSE
UPDATE customers
        SET phone = 2 || NOW()::TEXT
        WHERE customer_id = 2022;
ROLLBACK;

UPDATE customers
SET country = country
WHERE customer_id = $1


UPDATE customers
SET city = city
WHERE customer_id = $1

UPDATE customers
SET status = $1
WHERE customer_id = $2



--  query to optimize  --------------------

-- 2) -------------------------------------------------------------------------------------------
-- items_products_join ----------------------------------------------------------------------
explain ANALYSE
SELECT
    p.category,
    COUNT(*) AS items_sold,
    SUM(oi.quantity * oi.unit_price) AS revenue
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
GROUP BY p.category
ORDER BY revenue DESC;

-- problem:     ->  Hash Join  (cost=66.00..5033.19 rows=211724 width=17) (actual time=0.766..47.156 rows=179965.00 loops=2)
--                  Hash Cond: (oi.product_id = p.product_id)
--                  Buffers: shared hit=2335
-- dont think analytics/anybody would need info at real time => can use materialized view + refresh twice a day

create MATERIALIZED VIEW products_category_stat as
SELECT
    p.category,
    COUNT(*) AS items_sold,
    SUM(oi.quantity * oi.unit_price) AS revenue
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
GROUP BY p.category
ORDER BY revenue DESC;

drop MATERIALIZED VIEW prodicts_category_sold;

explain ANALYSE
select * from products_category_stat;
-- result: Seq Scan on products_category_stat  (cost=0.00..18.10 rows=810 width=72) (actual time=0.015..0.016 rows=5.00 loops=1)



-- 3) -------------------------------------------------------------------------------------------
-- divide customer_events_wide -> campaigns, sessions, events (+partitioned) ------------------
CREATE TABLE campaigns (
    campaign_id SERIAL PRIMARY KEY,
    utm_source TEXT,
    utm_medium TEXT,
    utm_campaign TEXT,
    attributes JSONB
);

CREATE TABLE sessions (
    session_id SERIAL PRIMARY KEY,
    customer_id INT,
    campaign_id INT REFERENCES campaigns(campaign_id),
    device TEXT,
    browser TEXT,
    os TEXT,
    source TEXT,
    referrer TEXT
);

-- +partitioned tbl
CREATE TABLE events (
    event_id SERIAL,
    session_id INT REFERENCES sessions(session_id),
    customer_id INT,
    event_type TEXT,
    event_time TIMESTAMP NOT NULL,
    page_url TEXT,
    ip_address TEXT
) PARTITION BY RANGE (event_time);

CREATE TABLE events_2025_12 PARTITION OF events
    FOR VALUES FROM ('2025-12-01') TO ('2026-01-01');

CREATE TABLE events_2026_01 PARTITION OF events
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');

CREATE TABLE events_2026_02 PARTITION OF events
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');

CREATE TABLE events_2026_03 PARTITION OF events
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');

CREATE TABLE events_2026_04 PARTITION OF events
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');

CREATE TABLE events_2026_05 PARTITION OF events
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');

CREATE TABLE events_2026_06 PARTITION OF events
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');

CREATE TABLE events_default PARTITION OF events DEFAULT;


-- +idx
create index idx_events_customer_event_type on events(customer_id, event_type);

create index idx_events_session_id on events(session_id);

create index idx_sessions_customer_id on sessions(customer_id);

create index idx_sessions_campaign_id on sessions(campaign_id);

create index idx_campaigns_attributes on campaigns USING GIN(attributes);




-- data insert
INSERT INTO campaigns (utm_source, utm_medium, utm_campaign, attributes)
SELECT DISTINCT
    utm_source,
    utm_medium,
    utm_campaign,
    jsonb_build_object(
        'attr_01', attr_01, 'attr_02', attr_02,
        'attr_03', attr_03, 'attr_04', attr_04,
        'attr_05', attr_05, 'attr_06', attr_06,
        'attr_07', attr_07, 'attr_08', attr_08,
        'attr_09', attr_09, 'attr_10', attr_10
    )
FROM customer_events_wide;

-- 2. one session per event row — no ambiguous JOIN
-- first add a surrogate key to campaigns to make lookup fast
ALTER TABLE campaigns ADD COLUMN utm_hash TEXT
    GENERATED ALWAYS AS (
        md5(COALESCE(utm_source,'') || utm_medium || utm_campaign)
    ) STORED;

CREATE INDEX idx_campaigns_utm_hash ON campaigns(utm_hash);

INSERT INTO sessions (customer_id, campaign_id, device, browser, os, source, referrer)
SELECT
    w.customer_id,
    c.campaign_id,
    w.device,
    w.browser,
    w.os,
    w.source,
    w.referrer
FROM customer_events_wide w
JOIN campaigns c
    ON c.utm_hash = md5(
        COALESCE(w.utm_source,'') ||
        COALESCE(w.utm_medium,'') ||
        COALESCE(w.utm_campaign,'')
    );

-- 3. events linked to their newly created session
-- row_number() matches each event to its corresponding session in insertion order
WITH ordered_events AS (
    SELECT
        event_id,
        customer_id,
        event_type,
        event_time,
        page_url,
        ip_address,
        ROW_NUMBER() OVER (ORDER BY event_id) AS rn
    FROM customer_events_wide
),
ordered_sessions AS (
    SELECT
        session_id,
        ROW_NUMBER() OVER (ORDER BY session_id) AS rn
    FROM sessions
)
INSERT INTO events (session_id, customer_id, event_type, event_time, page_url, ip_address)
SELECT
    os.session_id,
    oe.customer_id,
    oe.event_type,
    oe.event_time,
    oe.page_url,
    oe.ip_address
FROM ordered_events oe
JOIN ordered_sessions os ON os.rn = oe.rn;

select * from events limit 2;
--  old queries ------------------------------------------------------------
-- events_aggregation ------------------------------
explain ANALYSE
SELECT
    customer_id,
    event_type,
    COUNT(*) AS events_count,
    MAX(event_time) AS last_event_time
FROM customer_events_wide
WHERE event_time >= NOW() - INTERVAL '180 days'
GROUP BY customer_id, event_type
ORDER BY events_count DESC
LIMIT 200;

-- prob;em
-- Limit  (cost=15005.02..15005.52 rows=200 width=27) (actual time=374.252..374.306 rows=200.00 loops=1)
--   Buffers: shared hit=7744 read=1714


-- cartesian_pressure --------------------------------
EXPLAIN ANALYSE
SELECT COUNT(*)
FROM customers c
JOIN orders o ON o.customer_id = c.customer_id
JOIN customer_events_wide e ON e.customer_id = c.customer_id
WHERE c.status IN ('active', 'inactive')
  AND e.event_time >= NOW() - INTERVAL '90 days';
-- problem
-- Finalize Aggregate  (cost=15909.07..15909.08 rows=1 width=8) (actual time=250.899..266.151 rows=1.00 loops=1)
--   Buffers: shared hit=9329 read=2090

-- new queries  ------------------------------------------------------------
-- events_aggregation
EXPLAIN ANALYSE
SELECT
    customer_id,
    event_type,
    COUNT(*) AS events_count,
    MAX(event_time) AS last_event_time
FROM events
WHERE event_time >= NOW() - INTERVAL '180 days'
GROUP BY customer_id, event_type
ORDER BY events_count DESC
LIMIT 200;
-- result
-- Limit  (cost=8548.49..8548.99 rows=200 width=27) (actual time=337.860..337.922 rows=200.00 loops=1)
--   Buffers: shared hit=2509

-- cartesian_pressure
explain ANALYSE
SELECT COUNT(*)
FROM customers c
JOIN orders o ON o.customer_id = c.customer_id
JOIN events e ON e.customer_id = o.customer_id
WHERE c.status IN ('active', 'inactive')
  AND e.event_time >= NOW() - INTERVAL '90 days';

-- result
-- Finalize Aggregate  (cost=9672.53..9672.54 rows=1 width=8) (actual time=140.538..148.046 rows=1.00 loops=1)
--   Buffers: shared hit=3490


-- 4) -------------------------------------------------------------------------------------------
-- heavy_join ---------------------------------------------------------------------------------
vacuum customers;
explain ANALYSE
SELECT
    c.customer_id,
    c.full_name,
    COUNT(o.order_id) AS orders_count,
    SUM(o.total_amount) AS revenue
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id
WHERE c.status = 'active'
GROUP BY c.customer_id, c.full_name
ORDER BY revenue DESC
LIMIT 100;

-- PROBLEM -  remove 13k rows from 20k  => +idx
--                           ->  Seq Scan on customers c  (cost=0.00..610.70 rows=6761 width=18) (actual time=0.010..2.143 rows=6742.00 loops=1)
--                                 Filter: (status = 'active'::text)
--                                 Rows Removed by Filter: 13258

-- drop index idx_customers_active_partial;
create index idx_customers_active_partial on customers(customer_id)
include(full_name)
where status='active';

-- result output
--                               ->  Index Only Scan using idx_customers_active_partial on customers c  (cost=0.28..237.41 rows=6742 width=18) (actual time=0.011..0.527 rows=6742.00 loops=1)
--                                 Heap Fetches: 0
--                                 Index Searches: 1
--                                 Buffers: shared hit=34



-- 5) -------------------------------------------------------------------------------------------
-- orders_by_city_and_status ------------------------------------------------------------------------------------
explain ANALYSE
SELECT *
FROM orders
WHERE delivery_city LIKE '%a%'
  AND status = 'paid';

-- select distinct delivery_city from orders;
-- select distinct status  from orders;

-- problem: 97k rows removed by filter, take much time to process
-- Seq Scan on orders  (cost=0.00..3040.00 rows=16599 width=50) (actual time=0.040..74.861 rows=22420.00 loops=1)
--   Filter: ((delivery_city ~~ '%a%'::text) AND (status = 'paid'::text))
--   Rows Removed by Filter: 97580
--   Buffers: shared hit=1240

-- => partial +idx for pre-filter

-- drop index idx_orders_by_city_status;

create index idx_orders_by_city_status on orders(order_id)
WHERE status='paid'
and delivery_city LIKE '%a%';

-- result
-- Index Scan using idx_orders_by_city_status on orders  (cost=0.29..620.53 rows=16599 width=50) (actual time=0.019..8.804 rows=22465.00 loops=1)
--   Index Searches: 1
--   Buffers: shared hit=3398


-- 6) -------------------------------------------------------------------------------------------
-- search_customer_by_email ----------------------------------------------------------------------------------------------------
explain ANALYSE
SELECT *
FROM customers
WHERE email LIKE '%gmail%';

-- all rows are filtered out
-- takes 5sec


-- 7) -------------------------------------------------------------------------------------------








