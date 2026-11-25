-- ============================================================
-- Olist E-commerce Analysis: SQL queries
-- Database: SQLite (DB Browser for SQLite)
-- Tables: orders, order_items, payments, reviews, customers,
--         products, sellers, category_translation
-- Revenue = item price (order_items.price) for delivered orders,
--           excluding freight. Currency: Brazilian reais (R$).
-- ============================================================


-- ------------------------------------------------------------
-- PART 1: DATA CHECKS
-- ------------------------------------------------------------

-- Check 0: row counts for every table
SELECT 'orders' AS tbl, COUNT(*) AS n FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL SELECT 'payments', COUNT(*) FROM payments
UNION ALL SELECT 'reviews', COUNT(*) FROM reviews
UNION ALL SELECT 'customers', COUNT(*) FROM customers
UNION ALL SELECT 'products', COUNT(*) FROM products
UNION ALL SELECT 'sellers', COUNT(*) FROM sellers
UNION ALL SELECT 'category_translation', COUNT(*) FROM category_translation;

-- Check 1: which order statuses exist?
SELECT order_status, COUNT(*) AS n
FROM orders
GROUP BY order_status
ORDER BY n DESC;

-- Check 2: what dates does the data cover?
SELECT MIN(order_purchase_timestamp), MAX(order_purchase_timestamp)
FROM orders;

-- Check 3: orders missing a delivery date, by status
SELECT order_status, COUNT(*) AS n
FROM orders
WHERE order_delivered_customer_date IS NULL
   OR order_delivered_customer_date = ''
GROUP BY order_status
ORDER BY n DESC;

-- Check 4: repeated order IDs (orders, then reviews)
SELECT COUNT(*) - COUNT(DISTINCT order_id) AS extra_rows FROM orders;
SELECT COUNT(*) - COUNT(DISTINCT order_id) AS extra_rows FROM reviews;

-- Check 5: real customers vs customer IDs
SELECT COUNT(DISTINCT customer_unique_id) AS real_customers,
       COUNT(DISTINCT customer_id)        AS customer_ids
FROM customers;

-- Check 6: products with no category
SELECT COUNT(*) FROM products
WHERE product_category_name IS NULL OR product_category_name = '';


-- ------------------------------------------------------------
-- PART 2: BUSINESS QUESTIONS
-- ------------------------------------------------------------

-- Query 1: headline totals (delivered orders)
SELECT
  COUNT(DISTINCT o.order_id)            AS orders,
  COUNT(DISTINCT c.customer_unique_id)  AS customers,
  ROUND(SUM(oi.price), 2)               AS revenue,
  ROUND(SUM(oi.freight_value), 2)       AS freight
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
JOIN customers c    ON o.customer_id = c.customer_id
WHERE o.order_status = 'delivered';


-- Query 2: revenue by month
SELECT
  strftime('%Y-%m', o.order_purchase_timestamp) AS month,
  COUNT(DISTINCT o.order_id)                    AS orders,
  ROUND(SUM(oi.price), 2)                       AS revenue
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.order_status = 'delivered'
GROUP BY month
ORDER BY month;


-- Query 3: top 10 product categories by revenue
-- LEFT JOIN keeps products with no English category name;
-- COALESCE falls back to the Portuguese name, then 'unknown'.
SELECT
  COALESCE(t.product_category_name_english,
           NULLIF(p.product_category_name, ''),
           'unknown')                  AS category,
  COUNT(*)                             AS items_sold,
  ROUND(SUM(oi.price), 2)              AS revenue
FROM order_items oi
JOIN orders o   ON oi.order_id = o.order_id
JOIN products p ON oi.product_id = p.product_id
LEFT JOIN category_translation t
       ON p.product_category_name = t.product_category_name
WHERE o.order_status = 'delivered'
GROUP BY category
ORDER BY revenue DESC
LIMIT 10;


-- Query 4: top 10 sellers by revenue
SELECT
  oi.seller_id,
  s.seller_state,
  COUNT(DISTINCT oi.order_id) AS orders,
  ROUND(SUM(oi.price), 2)     AS revenue
FROM order_items oi
JOIN orders o  ON oi.order_id = o.order_id
JOIN sellers s ON oi.seller_id = s.seller_id
WHERE o.order_status = 'delivered'
GROUP BY oi.seller_id, s.seller_state
ORDER BY revenue DESC
LIMIT 10;


-- Query 5: delivery time and share of late deliveries
-- 100.0 forces decimal division; the last two WHERE lines remove
-- the 8 delivered orders that have no delivery date.
SELECT
  COUNT(*) AS orders,
  ROUND(AVG(julianday(order_delivered_customer_date)
          - julianday(order_purchase_timestamp)), 1)  AS avg_days_to_deliver,
  ROUND(AVG(julianday(order_estimated_delivery_date)
          - julianday(order_purchase_timestamp)), 1)  AS avg_days_promised,
  ROUND(100.0 * SUM(CASE WHEN order_delivered_customer_date
                              > order_estimated_delivery_date
                         THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_late
FROM orders
WHERE order_status = 'delivered'
  AND order_delivered_customer_date IS NOT NULL
  AND order_delivered_customer_date <> '';


-- Query 6: top 10 customer states by revenue
SELECT
  c.customer_state,
  COUNT(DISTINCT c.customer_unique_id) AS customers,
  COUNT(DISTINCT o.order_id)           AS orders,
  ROUND(SUM(oi.price), 2)              AS revenue
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
JOIN customers c    ON o.customer_id = c.customer_id
WHERE o.order_status = 'delivered'
GROUP BY c.customer_state
ORDER BY revenue DESC
LIMIT 10;


-- Query 7: payment methods
-- SUM(SUM(...)) OVER () is a window function: it gives the grand
-- total on every row so each row can show its share.
-- Payment totals include freight, so they exceed item revenue.
SELECT
  p.payment_type,
  COUNT(DISTINCT p.order_id)  AS orders,
  ROUND(SUM(p.payment_value), 2) AS value,
  ROUND(100.0 * SUM(p.payment_value)
        / SUM(SUM(p.payment_value)) OVER (), 1) AS pct_of_value
FROM payments p
JOIN orders o ON p.order_id = o.order_id
WHERE o.order_status = 'delivered'
GROUP BY p.payment_type
ORDER BY value DESC;


-- Query 8: late deliveries vs review score
-- The subquery reduces reviews to one row per order first, so
-- orders with several reviews are not counted more than once.
SELECT
  CASE WHEN o.order_delivered_customer_date
            > o.order_estimated_delivery_date
       THEN 'Late' ELSE 'On time' END       AS delivery,
  COUNT(*)                                  AS orders,
  ROUND(AVG(r.score), 2)                    AS avg_review_score
FROM orders o
JOIN (SELECT order_id, AVG(review_score) AS score
      FROM reviews
      GROUP BY order_id) r
  ON o.order_id = r.order_id
WHERE o.order_status = 'delivered'
  AND o.order_delivered_customer_date IS NOT NULL
  AND o.order_delivered_customer_date <> ''
GROUP BY delivery;


-- Query 9: repeat customers
-- The inner query counts delivered orders per real person
-- (customer_unique_id); the outer query counts who has more than one.
SELECT
  COUNT(*)                                          AS customers,
  SUM(CASE WHEN n > 1 THEN 1 ELSE 0 END)            AS repeat_customers,
  ROUND(100.0 * SUM(CASE WHEN n > 1 THEN 1 ELSE 0 END)
        / COUNT(*), 1)                              AS pct_repeat
FROM (
  SELECT c.customer_unique_id, COUNT(DISTINCT o.order_id) AS n
  FROM orders o
  JOIN customers c ON o.customer_id = c.customer_id
  WHERE o.order_status = 'delivered'
  GROUP BY c.customer_unique_id
);
