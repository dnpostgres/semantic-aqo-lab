#!/bin/bash
# =============================================================================
# AQO Test Data Cleanup Script
# =============================================================================
# This script removes all test tables created by 01-testing-aqo-and-view.sh
# Run this after you're done inspecting the test data manually.
#
# Usage: bash scripts/tests/cleanup.sh
# =============================================================================

PSQL="/usr/local/pgsql/bin/psql"
DB="test"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

run_sql() {
    sudo -u postgres $PSQL $DB -t -A -P pager=off -c "$1" 2>/dev/null
}

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  AQO Test Data Cleanup${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""

echo "  Dropping test tables..."
run_sql "DROP TABLE IF EXISTS aqo_test_orders CASCADE;"
run_sql "DROP TABLE IF EXISTS aqo_test_products CASCADE;"
run_sql "DROP TABLE IF EXISTS aqo_test_customers CASCADE;"

echo -e "  ${GREEN}✅ Test tables cleaned up (aqo_test_orders, aqo_test_products, aqo_test_customers)${NC}"

echo ""
echo "  Verifying cleanup..."
REMAINING=$(run_sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_name LIKE 'aqo_test_%';")
if [ "$REMAINING" -eq 0 ] 2>/dev/null; then
    echo -e "  ${GREEN}✅ All test tables removed successfully.${NC}"
else
    echo -e "  ${RED}⚠️  $REMAINING test table(s) still remain.${NC}"
fi

echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
