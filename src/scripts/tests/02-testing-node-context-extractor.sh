#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Node Context Extractor Testing and Data Display Script
# Tests node context extraction functionality and shows collected data
# =============================================================================

PSQL="sudo -u postgres /usr/local/pgsql/bin/psql"
DB="test"
LIMIT=10

echo ""
echo "=============================================="
echo "   Node Context Extractor Testing & Display"
echo "=============================================="

# ----- Step 1: Check AQO Extension -----
echo ""
echo "📦 Step 1: Checking AQO extension and node context table..."
$PSQL $DB -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'aqo';"
$PSQL $DB -c "\d aqo_node_context" | head -20

# ----- Step 2: Create test tables with relationships -----
echo ""
echo "📝 Step 2: Creating test tables for JOIN operations..."
$PSQL $DB << 'EOF'
-- Drop existing test tables
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS customers CASCADE;
DROP TABLE IF EXISTS products CASCADE;

-- Create customers table
CREATE TABLE customers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    email VARCHAR(100),
    city VARCHAR(50),
    created_at TIMESTAMP DEFAULT NOW()
);

-- Create products table
CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    category VARCHAR(50),
    price DECIMAL(10,2),
    stock INT
);

-- Create orders table
CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    customer_id INT REFERENCES customers(id),
    product_id INT REFERENCES products(id),
    quantity INT,
    total_price DECIMAL(10,2),
    order_date DATE,
    status VARCHAR(20)
);

-- Insert sample data
INSERT INTO customers (name, email, city)
SELECT 
    'Customer_' || i,
    'customer' || i || '@example.com',
    (ARRAY['Hanoi', 'HCMC', 'Danang', 'Haiphong', 'Cantho'])[1 + (random() * 4)::int]
FROM generate_series(1, 100) i;

INSERT INTO products (name, category, price, stock)
SELECT 
    'Product_' || i,
    (ARRAY['Electronics', 'Clothing', 'Food', 'Books', 'Sports'])[1 + (random() * 4)::int],
    (random() * 1000 + 10)::decimal(10,2),
    (random() * 100)::int
FROM generate_series(1, 50) i;

INSERT INTO orders (customer_id, product_id, quantity, total_price, order_date, status)
SELECT 
    (random() * 99 + 1)::int,
    (random() * 49 + 1)::int,
    (random() * 10 + 1)::int,
    (random() * 5000)::decimal(10,2),
    CURRENT_DATE - (random() * 365)::int,
    (ARRAY['pending', 'completed', 'shipped', 'cancelled'])[1 + (random() * 3)::int]
FROM generate_series(1, 500);

-- Create indexes
CREATE INDEX idx_orders_customer ON orders(customer_id);
CREATE INDEX idx_orders_product ON orders(product_id);
CREATE INDEX idx_orders_date ON orders(order_date);
CREATE INDEX idx_customers_city ON customers(city);
CREATE INDEX idx_products_category ON products(category);

-- Analyze tables
ANALYZE customers;
ANALYZE products;
ANALYZE orders;
EOF
echo "✅ Test tables created"

# ----- Step 3: Clear existing node context data -----
echo ""
echo "🧹 Step 3: Clearing previous node context data..."
$PSQL $DB -c "DELETE FROM aqo_node_context WHERE query_hash != 0;" 2>/dev/null || true
echo "✅ Previous data cleared"

# ----- Step 4: Run queries to collect node context -----
echo ""
echo "🎓 Step 4: Running test queries to collect node context..."
$PSQL $DB << 'EOF'
SET aqo.mode = 'learn';
SET aqo.show_details = 'on';
SET aqo.join_threshold = 0;
SET aqo.nce_enabled = 'on';  -- Enable Node Context Extractor

-- Query 1: Simple JOIN
EXPLAIN ANALYZE 
SELECT c.name, o.total_price, o.order_date
FROM orders o
JOIN customers c ON o.customer_id = c.id
WHERE o.status = 'completed';

-- Query 2: Multiple JOINs
EXPLAIN ANALYZE
SELECT c.name, p.name as product, o.quantity, o.total_price
FROM orders o
JOIN customers c ON o.customer_id = c.id
JOIN products p ON o.product_id = p.id
WHERE c.city = 'Hanoi' AND p.category = 'Electronics';

-- Query 3: Aggregation with JOIN
EXPLAIN ANALYZE
SELECT c.city, COUNT(*) as order_count, SUM(o.total_price) as total_revenue
FROM orders o
JOIN customers c ON o.customer_id = c.id
WHERE o.order_date > CURRENT_DATE - 90
GROUP BY c.city;

-- Query 4: Subquery
EXPLAIN ANALYZE
SELECT * FROM customers c
WHERE c.id IN (
    SELECT customer_id FROM orders 
    WHERE total_price > 1000
);

-- Query 5: Complex JOIN with filters
EXPLAIN ANALYZE
SELECT c.name, p.category, SUM(o.quantity) as total_qty
FROM orders o
JOIN customers c ON o.customer_id = c.id
JOIN products p ON o.product_id = p.id
WHERE o.order_date BETWEEN CURRENT_DATE - 180 AND CURRENT_DATE
AND p.price > 100
GROUP BY c.name, p.category
HAVING SUM(o.quantity) > 5;

-- Run again for more learning samples
EXPLAIN ANALYZE 
SELECT c.name, o.total_price FROM orders o JOIN customers c ON o.customer_id = c.id WHERE o.total_price > 500;

EXPLAIN ANALYZE
SELECT p.category, AVG(o.total_price) FROM orders o JOIN products p ON o.product_id = p.id GROUP BY p.category;
EOF
echo "✅ Test queries executed"

# ----- Step 5: Display Node Context Data -----
echo ""
echo "=============================================="
echo "       NODE CONTEXT DATA DISPLAY"
echo "=============================================="

echo ""
echo "📊 Table: aqo_node_context (All columns)"
echo "----------------------------------------------"
$PSQL $DB -c "
SELECT *
FROM aqo_node_context 
LIMIT $LIMIT;
"

echo ""
echo "📊 Summary Statistics"
echo "----------------------------------------------"
$PSQL $DB << 'EOF'
SELECT 
    'Total node contexts' as metric, COUNT(*)::text as value FROM aqo_node_context
UNION ALL
SELECT 
    'Distinct query hashes', COUNT(DISTINCT query_hash)::text FROM aqo_node_context
UNION ALL
SELECT 
    'Distinct space hashes', COUNT(DISTINCT space_hash)::text FROM aqo_node_context
UNION ALL
SELECT 
    'Node types', COUNT(DISTINCT node_type)::text FROM aqo_node_context
UNION ALL
SELECT 
    'With join_type', COUNT(*)::text FROM aqo_node_context WHERE join_type IS NOT NULL
UNION ALL
SELECT 
    'With relations', COUNT(*)::text FROM aqo_node_context WHERE relations IS NOT NULL;
EOF

echo ""
echo "=============================================="
echo "              TEST COMPLETE"
echo "=============================================="
echo ""
echo "💡 Tips:"
echo "   - Run more queries to collect more node context data"
echo "   - Check cardinality ratio: values close to 1.0 = good estimation"
echo "   - Node context data is used by AQO ML for cardinality prediction"
