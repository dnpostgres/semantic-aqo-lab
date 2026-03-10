#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# AQO Testing and Data Display Script
# Tests AQO functionality and shows data from AQO tables
# =============================================================================

PSQL="sudo -u postgres /usr/local/pgsql/bin/psql"
DB="test"
LIMIT=15

echo ""
echo "=============================================="
echo "       AQO Testing and Data Display"
echo "=============================================="

# ----- Step 1: Check AQO Extension -----
echo ""
echo "📦 Step 1: Checking AQO extension..."
$PSQL $DB -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'aqo';"

# ----- Step 2: Create test table if not exists -----
echo ""
echo "📝 Step 2: Creating test data..."
$PSQL $DB << 'EOF'
-- Create test table
DROP TABLE IF EXISTS aqo_test_orders CASCADE;
CREATE TABLE aqo_test_orders (
    id SERIAL PRIMARY KEY,
    customer_id INT,
    product_id INT,
    quantity INT,
    price DECIMAL(10,2),
    order_date DATE,
    status VARCHAR(20)
);

-- Insert sample data
INSERT INTO aqo_test_orders (customer_id, product_id, quantity, price, order_date, status)
SELECT 
    (random() * 100)::int,
    (random() * 50)::int,
    (random() * 10 + 1)::int,
    (random() * 1000)::decimal(10,2),
    CURRENT_DATE - (random() * 365)::int,
    CASE (random() * 3)::int 
        WHEN 0 THEN 'pending'
        WHEN 1 THEN 'completed'
        ELSE 'cancelled'
    END
FROM generate_series(1, 1000);

-- Create index
CREATE INDEX IF NOT EXISTS idx_orders_customer ON aqo_test_orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_orders_date ON aqo_test_orders(order_date);

-- Update statistics
ANALYZE aqo_test_orders;
EOF
echo "✅ Test table created with 1000 rows"

# ----- Step 3: Enable AQO learning mode -----
echo ""
echo "🎓 Step 3: Enabling AQO learning mode and running test queries..."
$PSQL $DB << 'EOF'
SET aqo.mode = 'learn';
SET aqo.show_details = 'on';
SET aqo.join_threshold = 0;

-- Run various test queries multiple times for AQO to learn
-- Query 1: Simple filter
EXPLAIN ANALYZE SELECT * FROM aqo_test_orders WHERE customer_id = 10;
EXPLAIN ANALYZE SELECT * FROM aqo_test_orders WHERE customer_id = 10;
EXPLAIN ANALYZE SELECT * FROM aqo_test_orders WHERE customer_id = 10;

-- Query 2: Range query
EXPLAIN ANALYZE SELECT * FROM aqo_test_orders WHERE price > 500 AND quantity > 5;
EXPLAIN ANALYZE SELECT * FROM aqo_test_orders WHERE price > 500 AND quantity > 5;
EXPLAIN ANALYZE SELECT * FROM aqo_test_orders WHERE price > 500 AND quantity > 5;

-- Query 3: Aggregation
EXPLAIN ANALYZE SELECT customer_id, SUM(price) as total FROM aqo_test_orders GROUP BY customer_id HAVING SUM(price) > 1000;
EXPLAIN ANALYZE SELECT customer_id, SUM(price) as total FROM aqo_test_orders GROUP BY customer_id HAVING SUM(price) > 1000;

-- Query 4: Date range
EXPLAIN ANALYZE SELECT * FROM aqo_test_orders WHERE order_date > CURRENT_DATE - 30 AND status = 'completed';
EXPLAIN ANALYZE SELECT * FROM aqo_test_orders WHERE order_date > CURRENT_DATE - 30 AND status = 'completed';

-- Query 5: Complex filter
EXPLAIN ANALYZE SELECT * FROM aqo_test_orders WHERE (customer_id BETWEEN 20 AND 40) AND (product_id < 25 OR price > 800);
EXPLAIN ANALYZE SELECT * FROM aqo_test_orders WHERE (customer_id BETWEEN 20 AND 40) AND (product_id < 25 OR price > 800);
EOF
echo "✅ Test queries executed"

# ----- Step 4: Show AQO Data Tables -----
echo ""
echo "=============================================="
echo "         AQO DATA TABLES DISPLAY"
echo "=============================================="

echo ""
echo "📊 Table: aqo_queries (Query configurations)"
echo "----------------------------------------------"
$PSQL $DB -c "SELECT queryid, fs, learn_aqo, use_aqo, auto_tuning, smart_timeout FROM aqo_queries ORDER BY queryid LIMIT $LIMIT;"

echo ""
echo "📊 Table: aqo_query_texts (Query texts)"
echo "----------------------------------------------"
$PSQL $DB -c "SELECT queryid, LEFT(query_text, 80) as query_text_preview FROM aqo_query_texts ORDER BY queryid LIMIT $LIMIT;"

echo ""
echo "📊 Table: aqo_query_stat (Execution statistics)"
echo "----------------------------------------------"
$PSQL $DB -c "
SELECT 
    queryid,
    execution_time_with_aqo,
    execution_time_without_aqo,
    cardinality_error_with_aqo,
    cardinality_error_without_aqo,
    executions_with_aqo as execs_with,
    executions_without_aqo as execs_without
FROM aqo_query_stat 
ORDER BY queryid 
LIMIT $LIMIT;
"

echo ""
echo "📊 Table: aqo_data (Feature space data)"
echo "----------------------------------------------"
$PSQL $DB -c "
SELECT 
    fs,
    fss,
    nfeatures,
    ARRAY_LENGTH(features, 1) as features_count,
    ARRAY_LENGTH(targets, 1) as targets_count
FROM aqo_data 
ORDER BY fs 
LIMIT $LIMIT;
" 2>/dev/null || echo "(No data in aqo_data yet)"

echo ""
echo "📊 Summary Statistics"
echo "----------------------------------------------"
$PSQL $DB << 'EOF'
SELECT 
    'aqo_queries' as table_name, COUNT(*) as row_count FROM aqo_queries
UNION ALL
SELECT 
    'aqo_query_texts', COUNT(*) FROM aqo_query_texts
UNION ALL
SELECT 
    'aqo_query_stat', COUNT(*) FROM aqo_query_stat
UNION ALL
SELECT 
    'aqo_data', COUNT(*) FROM aqo_data
UNION ALL
SELECT 
    'aqo_node_context', COUNT(*) FROM aqo_node_context;
EOF

echo ""
echo "=============================================="
echo "              TEST COMPLETE"
echo "=============================================="
