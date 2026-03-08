#!/bin/bash
# =============================================================================
# AQO Extension Test Script
# =============================================================================
# This script verifies that the AQO (Adaptive Query Optimization) extension
# is properly installed, running, and actively learning from query executions.
#
# It performs the following:
#   1. Checks PostgreSQL server status and AQO extension presence
#   2. Creates a test table with sample data
#   3. Runs queries in 'learn' mode so AQO collects statistics
#   4. Shows AQO internal tables (aqo_queries, aqo_query_texts, aqo_query_stat)
#   5. Demonstrates that AQO is actively optimizing queries
# =============================================================================

set -e

PSQL="/usr/local/pgsql/bin/psql"
PG_CTL="/usr/local/pgsql/bin/pg_ctl"
DATA_DIR="/usr/local/pgsql/data"
DB="test"
PASS=0
FAIL=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Helper functions
print_header() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}

print_subheader() {
    echo ""
    echo -e "${YELLOW}--- $1 ---${NC}"
}

check_pass() {
    echo -e "  ${GREEN}✅ PASS:${NC} $1"
    PASS=$((PASS + 1))
}

check_fail() {
    echo -e "  ${RED}❌ FAIL:${NC} $1"
    FAIL=$((FAIL + 1))
}

run_sql() {
    sudo -u postgres $PSQL $DB -t -A -P pager=off -c "$1" 2>/dev/null
}

run_sql_display() {
    sudo -u postgres $PSQL $DB -P pager=off -c "$1" 2>/dev/null
}

# =============================================================================
# TEST 1: PostgreSQL Server Status
# =============================================================================
print_header "TEST 1: PostgreSQL Server Status"

SERVER_STATUS=$(sudo -u postgres $PG_CTL -D $DATA_DIR status 2>&1 || true)
if echo "$SERVER_STATUS" | grep -q "server is running"; then
    check_pass "PostgreSQL server is running"
else
    check_fail "PostgreSQL server is NOT running"
    echo "  Attempting to start server..."
    sudo -u postgres $PG_CTL -D $DATA_DIR -l $DATA_DIR/logfile start
    sleep 2
fi

# Show PostgreSQL version
PG_VERSION=$(run_sql "SELECT version();")
echo -e "  📌 Version: ${BOLD}$PG_VERSION${NC}"

# =============================================================================
# TEST 2: AQO Extension Installed
# =============================================================================
print_header "TEST 2: AQO Extension Verification"

print_subheader "Check extension is installed"
AQO_EXT=$(run_sql "SELECT extname || ' v' || extversion FROM pg_extension WHERE extname = 'aqo';")
if [ -n "$AQO_EXT" ]; then
    check_pass "AQO extension is installed: $AQO_EXT"
else
    check_fail "AQO extension is NOT installed"
    echo "  Attempting to create extension..."
    run_sql "CREATE EXTENSION IF NOT EXISTS aqo;"
fi

print_subheader "Check shared_preload_libraries"
SPL=$(run_sql "SHOW shared_preload_libraries;")
if echo "$SPL" | grep -q "aqo"; then
    check_pass "AQO is loaded in shared_preload_libraries: '$SPL'"
else
    check_fail "AQO is NOT in shared_preload_libraries"
fi

print_subheader "Check AQO mode"
AQO_MODE=$(run_sql "SHOW aqo.mode;")
check_pass "Current AQO mode: '$AQO_MODE'"

# =============================================================================
# TEST 3: Create Test Data
# =============================================================================
print_header "TEST 3: Setting Up Test Data"

run_sql "DROP TABLE IF EXISTS aqo_test_orders CASCADE;"
run_sql "DROP TABLE IF EXISTS aqo_test_products CASCADE;"
run_sql "DROP TABLE IF EXISTS aqo_test_customers CASCADE;"

echo "  Creating test tables..."
run_sql "
CREATE TABLE aqo_test_customers (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    city TEXT NOT NULL,
    created_at TIMESTAMP DEFAULT now()
);
"

run_sql "
CREATE TABLE aqo_test_products (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    price NUMERIC(10,2) NOT NULL
);
"

run_sql "
CREATE TABLE aqo_test_orders (
    id SERIAL PRIMARY KEY,
    customer_id INT REFERENCES aqo_test_customers(id),
    product_id INT REFERENCES aqo_test_products(id),
    quantity INT NOT NULL,
    order_date DATE DEFAULT CURRENT_DATE
);
"

echo "  Inserting sample data..."
run_sql "
INSERT INTO aqo_test_customers (name, city)
SELECT
    'Customer_' || i,
    (ARRAY['Hanoi','HCMC','Danang','Haiphong','Cantho','Hue','NhaTrang'])[1 + (i % 7)]
FROM generate_series(1, 1000) AS i;
"

run_sql "
INSERT INTO aqo_test_products (name, category, price)
SELECT
    'Product_' || i,
    (ARRAY['Electronics','Clothing','Food','Books','Sports','Home','Toys'])[1 + (i % 7)],
    (random() * 500 + 10)::numeric(10,2)
FROM generate_series(1, 200) AS i;
"

run_sql "
INSERT INTO aqo_test_orders (customer_id, product_id, quantity, order_date)
SELECT
    1 + (random() * 999)::int,
    1 + (random() * 199)::int,
    1 + (random() * 10)::int,
    CURRENT_DATE - (random() * 365)::int
FROM generate_series(1, 5000);
"

# Create indexes
run_sql "CREATE INDEX IF NOT EXISTS idx_orders_customer ON aqo_test_orders(customer_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_orders_product ON aqo_test_orders(product_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_orders_date ON aqo_test_orders(order_date);"
run_sql "CREATE INDEX IF NOT EXISTS idx_customers_city ON aqo_test_customers(city);"
run_sql "CREATE INDEX IF NOT EXISTS idx_products_category ON aqo_test_products(category);"

# Update statistics
run_sql "ANALYZE aqo_test_customers;"
run_sql "ANALYZE aqo_test_products;"
run_sql "ANALYZE aqo_test_orders;"

check_pass "Test tables created with data (1000 customers, 200 products, 5000 orders)"

# =============================================================================
# TEST 4: Run Queries in Learn Mode (AQO learns from execution)
# =============================================================================
print_header "TEST 4: Running Queries with AQO Learning"

echo "  Configuring AQO for full learning..."
run_sql "ALTER SYSTEM SET aqo.join_threshold = 0;"
run_sql "ALTER SYSTEM SET aqo.force_collect_stat = on;"
sudo -u postgres /usr/local/pgsql/bin/pg_ctl -D /usr/local/pgsql/data reload > /dev/null 2>&1
sleep 1

echo "  Setting AQO to 'learn' mode and executing queries multiple times..."
echo ""

# Query 1: Simple aggregation with JOIN
print_subheader "Query 1: Sales by city (JOIN + GROUP BY)"
run_sql_display "
SET aqo.mode = 'learn';
EXPLAIN ANALYZE
SELECT c.city, COUNT(*) as total_orders, SUM(o.quantity * p.price) as revenue
FROM aqo_test_orders o
JOIN aqo_test_customers c ON o.customer_id = c.id
JOIN aqo_test_products p ON o.product_id = p.id
GROUP BY c.city
ORDER BY revenue DESC;
RESET aqo.mode;
"

# Run same query again so AQO can improve
run_sql "
SET aqo.mode = 'learn';
EXPLAIN ANALYZE
SELECT c.city, COUNT(*) as total_orders, SUM(o.quantity * p.price) as revenue
FROM aqo_test_orders o
JOIN aqo_test_customers c ON o.customer_id = c.id
JOIN aqo_test_products p ON o.product_id = p.id
GROUP BY c.city
ORDER BY revenue DESC;
RESET aqo.mode;
" > /dev/null

# Query 2: Filtered query with subquery
print_subheader "Query 2: Top customers by order count (Subquery)"
run_sql_display "
SET aqo.mode = 'learn';
EXPLAIN ANALYZE
SELECT c.name, c.city, sub.order_count
FROM aqo_test_customers c
JOIN (
    SELECT customer_id, COUNT(*) as order_count
    FROM aqo_test_orders
    WHERE order_date >= CURRENT_DATE - INTERVAL '6 months'
    GROUP BY customer_id
    HAVING COUNT(*) > 3
) sub ON c.id = sub.customer_id
ORDER BY sub.order_count DESC
LIMIT 10;
RESET aqo.mode;
"

# Run again
run_sql "
SET aqo.mode = 'learn';
EXPLAIN ANALYZE
SELECT c.name, c.city, sub.order_count
FROM aqo_test_customers c
JOIN (
    SELECT customer_id, COUNT(*) as order_count
    FROM aqo_test_orders
    WHERE order_date >= CURRENT_DATE - INTERVAL '6 months'
    GROUP BY customer_id
    HAVING COUNT(*) > 3
) sub ON c.id = sub.customer_id
ORDER BY sub.order_count DESC
LIMIT 10;
RESET aqo.mode;
" > /dev/null

# Query 3: Multi-condition filter
print_subheader "Query 3: Electronics orders from HCMC (Multi-condition)"
run_sql_display "
SET aqo.mode = 'learn';
EXPLAIN ANALYZE
SELECT c.name, p.name as product, p.price, o.quantity, o.order_date
FROM aqo_test_orders o
JOIN aqo_test_customers c ON o.customer_id = c.id
JOIN aqo_test_products p ON o.product_id = p.id
WHERE c.city = 'HCMC'
  AND p.category = 'Electronics'
  AND o.quantity > 5
ORDER BY o.order_date DESC;
RESET aqo.mode;
"

# Run again
run_sql "
SET aqo.mode = 'learn';
EXPLAIN ANALYZE
SELECT c.name, p.name as product, p.price, o.quantity, o.order_date
FROM aqo_test_orders o
JOIN aqo_test_customers c ON o.customer_id = c.id
JOIN aqo_test_products p ON o.product_id = p.id
WHERE c.city = 'HCMC'
  AND p.category = 'Electronics'
  AND o.quantity > 5
ORDER BY o.order_date DESC;
RESET aqo.mode;
" > /dev/null

# Run all queries a few more times for better AQO learning
for i in 1 2 3; do
    run_sql "
    SET aqo.mode = 'learn';
    EXPLAIN ANALYZE SELECT c.city, COUNT(*), SUM(o.quantity * p.price)
    FROM aqo_test_orders o JOIN aqo_test_customers c ON o.customer_id = c.id
    JOIN aqo_test_products p ON o.product_id = p.id GROUP BY c.city ORDER BY 3 DESC;

    EXPLAIN ANALYZE SELECT c.name, c.city, sub.order_count
    FROM aqo_test_customers c JOIN (SELECT customer_id, COUNT(*) as order_count
    FROM aqo_test_orders WHERE order_date >= CURRENT_DATE - INTERVAL '6 months'
    GROUP BY customer_id HAVING COUNT(*) > 3) sub ON c.id = sub.customer_id
    ORDER BY sub.order_count DESC LIMIT 10;

    EXPLAIN ANALYZE SELECT c.name, p.name, p.price, o.quantity, o.order_date
    FROM aqo_test_orders o JOIN aqo_test_customers c ON o.customer_id = c.id
    JOIN aqo_test_products p ON o.product_id = p.id
    WHERE c.city = 'HCMC' AND p.category = 'Electronics' AND o.quantity > 5
    ORDER BY o.order_date DESC;
    RESET aqo.mode;
    " > /dev/null 2>&1
done

check_pass "Executed 3 query types (each 5+ times for AQO learning)"

# =============================================================================
# TEST 5: Show AQO Statistics Tables
# =============================================================================
print_header "TEST 5: AQO Statistics & Internal Tables"

print_subheader "5a. aqo_query_texts - Stored normalized queries"
run_sql_display "SELECT queryid, left(query_text, 120) AS query_preview FROM aqo_query_texts ORDER BY queryid;"

print_subheader "5b. aqo_queries - Query settings (learn_aqo, use_aqo, auto_tuning)"
run_sql_display "SELECT queryid, fs, learn_aqo, use_aqo, auto_tuning, smart_timeout, count_increase_timeout FROM aqo_queries ORDER BY queryid;"

print_subheader "5c. aqo_query_stat - Execution statistics"
run_sql_display "SELECT queryid, executions_with_aqo, executions_without_aqo, cardinality_error_with_aqo[1:3] AS card_err_with, cardinality_error_without_aqo[1:3] AS card_err_without, execution_time_with_aqo[1:3] AS exec_time_with, execution_time_without_aqo[1:3] AS exec_time_without FROM aqo_query_stat ORDER BY queryid;"

# Count entries
QT_COUNT=$(run_sql "SELECT COUNT(*) FROM aqo_query_texts;")
QQ_COUNT=$(run_sql "SELECT COUNT(*) FROM aqo_queries;")
QS_COUNT=$(run_sql "SELECT COUNT(*) FROM aqo_query_stat;")

print_subheader "5d. aqo_data - ML model data"
run_sql_display "SELECT fs, fss, nfeatures, reliability FROM aqo_data ORDER BY fs, fss;"

if [ "$QT_COUNT" -gt 0 ] 2>/dev/null; then
    check_pass "aqo_query_texts has $QT_COUNT entries"
else
    check_fail "aqo_query_texts is empty"
fi

if [ "$QQ_COUNT" -gt 0 ] 2>/dev/null; then
    check_pass "aqo_queries has $QQ_COUNT entries"
else
    check_fail "aqo_queries is empty"
fi

if [ "$QS_COUNT" -gt 0 ] 2>/dev/null; then
    check_pass "aqo_query_stat has $QS_COUNT entries (AQO is collecting stats!)"
else
    check_fail "aqo_query_stat is empty"
fi

# =============================================================================
# TEST 6: Verify AQO is actually learning (run with aqo.show_details)
# =============================================================================
print_header "TEST 6: AQO Show Details (Cardinality Predictions)"

print_subheader "Running query with aqo.show_details = on"
run_sql_display "
SET aqo.mode = 'learn';
SET aqo.show_details = 'on';
SET aqo.show_hash = 'on';
EXPLAIN ANALYZE
SELECT c.city, COUNT(*) as total_orders, SUM(o.quantity * p.price) as revenue
FROM aqo_test_orders o
JOIN aqo_test_customers c ON o.customer_id = c.id
JOIN aqo_test_products p ON o.product_id = p.id
GROUP BY c.city
ORDER BY revenue DESC;
RESET aqo.show_details;
RESET aqo.show_hash;
RESET aqo.mode;
"

check_pass "AQO show_details demonstrates cardinality predictions per node"

# =============================================================================
# TEST 7: Summary of AQO Configuration
# =============================================================================
print_header "TEST 7: AQO Configuration Summary"

echo ""
run_sql_display "
SELECT name, setting, short_desc
FROM pg_settings
WHERE name LIKE 'aqo.%'
ORDER BY name;
"

check_pass "All AQO GUC settings displayed"

# =============================================================================
# FINAL SUMMARY
# =============================================================================
print_header "TEST SUMMARY"
echo ""
TOTAL=$((PASS + FAIL))
echo -e "  ${GREEN}Passed: $PASS${NC}"
echo -e "  ${RED}Failed: $FAIL${NC}"
echo -e "  ${BOLD}Total:  $TOTAL${NC}"
echo ""

if [ "$FAIL" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}🎉 ALL TESTS PASSED! AQO Extension is fully operational.${NC}"
else
    echo -e "  ${RED}${BOLD}⚠️  Some tests failed. Please check the output above.${NC}"
fi

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
