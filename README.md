# 🎯 PostgreSQL Performance Lab — Report

CRM/e-commerce schema under simulated load [script generate normal load + row/tbl locks + deadlocks] `\` goal: find bottlenecks → fix → measure gain

---

## 1. Detection Toolkit

- `pg_stat_statements` — rank queries by `total_exec_time` ⇒ priority list for analysis below
- `EXPLAIN ANALYZE` — real plan + actual rows/time/buffers, not just estimate
- `pg_stat_activity` + `pg_blocking_pids()` — live blocked/blocking session chains
- `pg_locks` / `wait_event_type='Lock'` — sessions currently stuck

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SELECT query, calls, total_exec_time, mean_exec_time, rows
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 100;
```
→ output order = issue order below [worst tot_exec_time 1st]

---

## 2. Issues + Fixes (ranked by tot_exec_time)

### 2.1 🛠️ Autovacuum too lax on hot tbl `customers`
- `customers` hammered by hot-row workers [`row_lock_holder`/`conflicting_update`] ⇒ #dead_tuple pile up fast
- detected: `EXPLAIN ANALYZE` estimated rows ≠ actual rows ← stale planner stats <= default `autovacuum_vacuum_scale_factor=0.2` [wait til 20% dead b4 vacuum, too slow for this tbl]
- fix: lower threshold per-tbl
```sql
ALTER TABLE customers SET (autovacuum_vacuum_scale_factor = 0.05);
```
- result: vacuum trigger >frequently [5% vs 20%] ⇒ stats stay current ⇒ planner pick correct join/scan strategy

---

### 2.2 📉 `items_products_join` — full re-agg evr call
- query: revenue by category `\` `JOIN order_items+products` + `GROUP BY`, no real-time need
```sql
SELECT
    p.category,
    COUNT(*) AS items_sold,
    SUM(oi.quantity * oi.unit_price) AS revenue
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
GROUP BY p.category
ORDER BY revenue DESC;
```
- before
```
Hash Join (actual time=0.766..47.156 rows=179965 loops=2)
Buffers: shared hit=2335
```
- fix: pre-agg, refresh 2x/day [no l-t value lost, biz dont need live #]
```sql
CREATE MATERIALIZED VIEW products_category_stat as
SELECT
    p.category,
    COUNT(*) AS items_sold,
    SUM(oi.quantity * oi.unit_price) AS revenue
FROM order_items oi
JOIN products p ON oi.product_id = p.product_id
GROUP BY p.category
ORDER BY revenue DESC;
```
- after
```
Seq Scan on products_category_stat (actual time=0.015..0.016 rows=5 loops=1)
```
- `47.2ms → 0.02ms` ⇒ `>2000x` `\` tradeoff: data up to 12h stale [acceptable here]

---

### 2.3 ⚠️ Wide tbl `customer_events_wide` — 24 cols, low selectivity
- 1 tbl mix campaign+session+event attrs ⇒ wide rows, redundant utm/device data repeated evr event row
- detected via `events_aggregation`+`cartesian_pressure` [both forced to scan whole wide tbl]
- fix: normalize → `campaigns` [utm + jsonb attrs]  +  `sessions` [device/browser/os, FK campaign]  +  `events` [slim, FK session]  +  `events` partitioned by month [`event_time` range]
```sql
CREATE TABLE events (...) PARTITION BY RANGE (event_time);
CREATE TABLE events_2026_06 PARTITION OF events
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
```
- +idx: composite `(customer_id,event_type)` `\` `session_id`

| query | before | after |
| --- | --- | --- |
| events_aggregation | 374.3ms `\` hit=7744 read=1714 | 337.9ms `\` hit=2509 read=0 |
| cartesian_pressure | 250.9ms `\` hit=9329 read=2090 | 140.5ms `\` hit=3490 read=0 |

- `read=0` after ⇒ no disk fetch, all served from buffer cache `\` partition pruning skip irrelevant months + narrower rows = >rows/page

---

### 2.4 🐢 `heavy_join` — Seq Scan, low-selectivity filter
- `status='active'` removes 13258/20000 rows via Seq Scan ⇒ wasted scan of whole tbl
```sql
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
```
- before
```
Seq Scan on customers c (actual time=0.010..2.143 rows=6742)
Rows Removed by Filter: 13258
```
- fix: partial idx [only index matching rows + `INCLUDE` covers query, no heap hit needed]
```sql
CREATE INDEX idx_customers_active_partial ON customers(customer_id)
INCLUDE(full_name) WHERE status='active';
```
- after
```
Index Only Scan using idx_customers_active_partial (actual time=0.011..0.527 rows=6742)
Heap Fetches: 0  \\ Buffers: shared hit=34
```
- `2.1ms → 0.5ms` `\` `Heap Fetches:0` ⇒ idx alone satisfy query

---

### 2.5 🐢 `orders_by_city_and_status` — `LIKE '%a%'` + Seq Scan
- `LIKE '%pattern%'` not sargable[no prefix match for btree] ⇒ forced Seq Scan, 97580 rows removed by filter
```sql
SELECT *
FROM orders
WHERE delivery_city LIKE '%a%'
  AND status = 'paid';
```
- before
```
Seq Scan on orders (actual time=0.040..74.861 rows=22420)
Rows Removed by Filter: 97580
```
- fix: partial idx [idx itself store only matching rows]
```sql
CREATE INDEX idx_orders_by_city_status ON orders(order_id)
WHERE status='paid' AND delivery_city LIKE '%a%';
```
- after
```
Index Scan using idx_orders_by_city_status (actual time=0.019..8.804 rows=22465)
Buffers: shared hit=3398
```
- `74.9ms → 8.8ms` ⇒ `~8.5x` `\` gain come from skip non-matching rows entirely, not from faster pattern match itself

---

### 2.6 ✅ `search_customer_by_email` — false alarm
- `WHERE email LIKE '%gmail%'` ⇒ 0 rows match [fake data domains ≠ gmail] ⇒ already <5ms
```sql
SELECT *
FROM customers
WHERE email LIKE '%gmail%';
```
- conclusion: no fix applied ← always check actual selectivity 1st [`EXPLAIN ANALYZE`], dont optimize off assumption

---

## 3. Locking / Blocking / Deadlocks

### 3.1 🔒 Detecting blocked ↔ blocking sessions
```sql
SELECT blocked.pid blocked_pid, blocked.query blocked_query,
       blocking.pid blocking_pid, blocking.query blocking_query,
       blocked.wait_event_type, blocked.wait_event
FROM pg_stat_activity blocked
JOIN pg_stat_activity blocking ON blocking.pid = ANY(pg_blocking_pids(blocked.pid));
```
- live chain captured during run [3 wait types observed]:
    - `phone` update wait on `status` update ← `wait_event=transactionid` [same row, diff tx, waiting on commit]
    - `city` update wait on `phone` update ← `wait_event=tuple` [row-lvl]
    - `orders.status` update wait on `LOCK TABLE orders SHARE ROW EXCLUSIVE` ← `wait_event=relation` [tbl-lvl]
- `wait_event` tell lock granularity: `tuple`=row `\` `transactionid`=waiting other tx finish `\` `relation`=whole tbl

### 3.2 ⚠️ Reproduced intentional deadlock
- tx1 lock cust2 → cust1 [`city`] `\` tx2 lock cust2 → cust1 too, but real conflict version [in script] lock cust1→cust2 vs cust2→cust1 [opposite order]
- result: Postgres detect lock cycle [`deadlock_timeout`] → 1 tx get `deadlock_detected` error + auto-rollback

### 3.3 🛠️ Fix — consistent lock order
- root cause: 2 tx acquire same rows in **diff order** ⇒ circular wait possible ← not "too much locking", just "inconsistent order"
- fix: force same acquisition order evrtime via explicit `FOR UPDATE` pre-lock, sorted by pk
```sql
WITH lock_order AS (
  SELECT customer_id FROM customers WHERE customer_id IN(1,2)
  ORDER BY customer_id FOR UPDATE  -- r1 locked b4 r2, always
)
UPDATE customers SET city=city WHERE customer_id IN(SELECT customer_id FROM lock_order);
```
- before: deadlock error ⇒ tx abort, app must retry
- after: tx2 simply **wait** for tx1 commit → proceeds normally, 0 errors [serialized not cancelled]

### 3.4 🎯 General tx hygiene
- commit asap `\` split long tx → smaller tx w/ multiple commits `\` move non-essential work outside tx ⇒ <lock hold time

---

## 4. Before/After Summary

| issue | before | after | fix applied |
| --- | --- | --- | --- |
| items_products_join | 47.2ms | 0.02ms | materialized view |
| events_aggregation | 374.3ms `\` read=1714 | 337.9ms `\` read=0 | normalize + partition + idx |
| cartesian_pressure | 250.9ms `\` read=2090 | 140.5ms `\` read=0 | normalize + partition + idx |
| heavy_join | 2.1ms `\` Seq Scan | 0.5ms `\` Idx Only Scan | partial idx |
| orders_by_city_and_status | 74.9ms `\` Seq Scan | 8.8ms `\` Idx Scan | partial idx |
| search_customer_by_email | <5ms | <5ms[no change] | n/a, already optimal |
| customers deadlock(1,2) | tx abort w/ error | tx serialize, 0 error | ordered locking [`FOR UPDATE`+sort] |
| customers autovacuum | stale stats, est≠actual | stats stay current | `autovacuum_vacuum_scale_factor=0.05` |

---

## 📎 References

- [Claude.ai](https://claude.ai/share/65e4af13-ab68-4fee-88fe-4a0c1f4b40cd)
