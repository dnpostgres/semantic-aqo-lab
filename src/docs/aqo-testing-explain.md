# AQO Extension — Hướng dẫn sử dụng & Giải thích bộ Test

> **Phiên bản**: AQO v1.6 trên PostgreSQL 15.15  
> **Repo**: [vietrion-lab/semantic-aqo-main](https://github.com/vietrion-lab/semantic-aqo-main) (branch `stable15`)  
> **Script test**: `scripts/tests/01-testing-aqo-and-view.sh`

---

## Mục lục

1. [AQO là gì?](#1-aqo-là-gì)
2. [Kiến trúc hoạt động](#2-kiến-trúc-hoạt-động)
3. [Các AQO Modes](#3-các-aqo-modes)
4. [Bảng nội bộ (Internal Views)](#4-bảng-nội-bộ-internal-views)
5. [GUC Parameters (Cấu hình)](#5-guc-parameters-cấu-hình)
6. [Cách sử dụng AQO trong thực tế](#6-cách-sử-dụng-aqo-trong-thực-tế)
7. [Giải thích chi tiết bộ Test Script](#7-giải-thích-chi-tiết-bộ-test-script)
8. [Đọc kết quả EXPLAIN ANALYZE với AQO](#8-đọc-kết-quả-explain-analyze-với-aqo)
9. [Recipes & Best Practices](#9-recipes--best-practices)

---

## 1. AQO là gì?

**AQO (Adaptive Query Optimization)** là extension mở rộng của PostgreSQL optimizer. Nguyên lý cơ bản:

- PostgreSQL optimizer ước lượng **cardinality** (số rows) dựa trên statistics tĩnh (`pg_statistics`)
- Khi ước lượng sai → chọn **execution plan** sai → query chậm
- AQO sử dụng **machine learning** (k-NN) để học từ execution statistics thực tế
- Qua nhiều lần chạy, AQO cải thiện cardinality estimation → plan tốt hơn → query nhanh hơn

### Luồng hoạt động cơ bản

```
Query đến → PostgreSQL Planner ước lượng rows (có thể sai)
                  ↓
         AQO can thiệp: dùng ML model đã học để sửa cardinality
                  ↓
         Chọn execution plan tốt hơn
                  ↓
         Sau khi chạy xong → AQO thu thập actual rows vs estimated → cập nhật model
```

---

## 2. Kiến trúc hoạt động

### 2.1. Normalized Query & Query Hash

AQO làm việc với **normalized queries** — query đã loại bỏ hằng số. Ví dụ:

```sql
-- Query thực tế
SELECT * FROM tbl WHERE a < 25 AND b = 'str';

-- Normalized version
SELECT * FROM tbl WHERE a < CONST AND b = CONST;
```

Mọi query có cùng cấu trúc (chỉ khác hằng số) sẽ có cùng `queryid` (hash). Điều này cho phép AQO học từ một query và áp dụng cho mọi query cùng dạng.

### 2.2. Feature Space (fs) & Feature Subspace (fss)

- **Feature Space (fs)**: Đại diện cho một nhóm query cùng cấu trúc (= `queryid` mặc định)
- **Feature Subspace (fss)**: Đại diện cho từng **node** trong execution plan (Seq Scan, Hash Join, Sort…)

AQO xây dựng ML model riêng cho từng `fss` — nghĩa là nó học cardinality cho từng node riêng biệt.

### 2.3. Machine Learning Model

AQO sử dụng thuật toán **k-Nearest Neighbors (k-NN)**:

- **Features**: Selectivity của các điều kiện (WHERE, JOIN conditions) → vector số thực
- **Target**: Log(actual_rows / estimated_rows) — sai số cardinality
- **Prediction**: Khi query mới đến, tìm k neighbors gần nhất → dự đoán sai số → sửa cardinality

Dữ liệu ML được lưu trong `aqo_data`:

| Cột         | Ý nghĩa                                              |
|-------------|-------------------------------------------------------|
| `fs`        | Feature space (query group)                           |
| `fss`       | Feature subspace (plan node)                          |
| `nfeatures` | Số features (selectivities) cho node này              |
| `features`  | Ma trận features đã học (selectivity vectors)         |
| `targets`   | Giá trị target đã học (cardinality error corrections) |
| `reliability`| Độ tin cậy của mỗi sample                            |
| `oids`      | Object IDs liên quan                                  |

---

## 3. Các AQO Modes

AQO có 5 modes hoạt động, thiết lập qua `aqo.mode`:

### 3.1. `disabled` — Tắt hoàn toàn

```sql
SET aqo.mode = 'disabled';
```

- AQO bị vô hiệu hóa cho mọi query
- PostgreSQL sử dụng optimizer gốc
- **Không xóa** dữ liệu/settings đã thu thập
- Dùng khi cần tạm tắt AQO mà không mất data

### 3.2. `controlled` — Mặc định, dùng cho Production

```sql
SET aqo.mode = 'controlled';
```

- Chỉ tối ưu query **đã biết** (đã có trong `aqo_queries`)
- Bỏ qua hoàn toàn query chưa biết → dùng PostgreSQL optimizer gốc
- An toàn nhất cho production vì không ảnh hưởng query mới

### 3.3. `learn` — Học query mới

```sql
SET aqo.mode = 'learn';
```

- Khi gặp query **mới** (chưa có trong `aqo_queries`): tự động thêm vào với settings mặc định:
  - `learn_aqo = true`
  - `use_aqo = true`
  - `auto_tuning = false`
  - `fs = queryid` (ML model riêng)
- **Không nên** dùng vĩnh viễn cho cả cluster vì gây overhead cho mọi query

**Pattern sử dụng tiêu biểu:**

```sql
BEGIN;
SET aqo.mode = 'learn';
EXPLAIN ANALYZE <query>;        -- Lần 1: AQO ghi nhận query
EXPLAIN ANALYZE <query>;        -- Lần 2: AQO bắt đầu dùng prediction
-- ... chạy cho đến khi plan ổn định
SET aqo.mode = 'controlled';    -- Chuyển về controlled
COMMIT;
```

### 3.4. `intelligent` — Tự động hoàn toàn

```sql
SET aqo.mode = 'intelligent';
-- Hoặc cluster-wide:
ALTER SYSTEM SET aqo.mode = 'intelligent';
```

- Tương tự `learn` nhưng `auto_tuning = true`
- AQO tự quyết định query nào nên dùng ML, query nào không
- Có thể dùng cluster-wide nhưng **không khuyến nghị cho production**

### 3.5. `forced` — Dynamic workload

```sql
SET aqo.mode = 'forced';
```

- Query **không** được thêm vào `aqo_queries`
- Thay vào đó, dùng **COMMON feature space** (`fs=0`)
- Phù hợp cho workload có cấu trúc query thay đổi liên tục
- Tiết kiệm memory nhưng thiếu intelligent tuning

### So sánh tổng hợp

| Mode          | Query mới   | Auto learn | Auto tune | Dùng cho                |
|---------------|-------------|------------|-----------|-------------------------|
| `disabled`    | Bỏ qua      | ✗          | ✗         | Tạm tắt AQO            |
| `controlled`  | Bỏ qua      | ✗          | ✗         | **Production** (mặc định)|
| `learn`       | Thêm + học  | ✓          | ✗         | Học query cụ thể        |
| `intelligent` | Thêm + học  | ✓          | ✓         | Tự động (dev/test)      |
| `forced`      | Dùng COMMON | ✓          | ✗         | Dynamic workload        |

---

## 4. Bảng nội bộ (Internal Views)

AQO tạo 4 views chính trong database:

### 4.1. `aqo_query_texts` — Ánh xạ query hash ↔ query text

```
            View "public.aqo_query_texts"
   Column   |  Type  | Collation | Nullable | Default
------------+--------+-----------+----------+---------
 queryid    | bigint |           |          |
 query_text | text   |           |          |
```

**Ý nghĩa**: Lưu trữ text của mỗi normalized query đã gặp.

```sql
SELECT queryid, left(query_text, 80) AS preview FROM aqo_query_texts;
```

```
       queryid        |                          preview
----------------------+----------------------------------------------------------
                    0 | COMMON feature space (do not delete!)
 -7943805185414767879 | SELECT c.city, COUNT(*) as total_orders, SUM(o.quantity...
  1981686404362911953 | SELECT c.name, c.city, sub.order_count FROM ...
```

> **Lưu ý**: Row `queryid = 0` là **COMMON feature space**, luôn tồn tại và **không được xóa**.

### 4.2. `aqo_queries` — Settings cho mỗi query type

```
                     View "public.aqo_queries"
         Column         |  Type   | Collation | Nullable | Default
------------------------+---------+-----------+----------+---------
 queryid                | bigint  |           |          |
 fs                     | bigint  |           |          |
 learn_aqo              | boolean |           |          |
 use_aqo                | boolean |           |          |
 auto_tuning            | boolean |           |          |
 smart_timeout          | bigint  |           |          |
 count_increase_timeout | bigint  |           |          |
```

**Các cột quan trọng:**

| Cột           | Ý nghĩa                                                        |
|---------------|-----------------------------------------------------------------|
| `queryid`     | Hash định danh query                                            |
| `fs`          | Feature space — nhóm ML model (thường = queryid)               |
| `learn_aqo`   | `true` = AQO thu thập statistics từ lần chạy tiếp              |
| `use_aqo`     | `true` = AQO dùng ML prediction cho query này                  |
| `auto_tuning` | `true` = AQO tự điều chỉnh learn/use settings                  |
| `smart_timeout`| Timeout thông minh cho learning                                |

**Ví dụ output thực tế:**

```
       queryid        |          fs          | learn_aqo | use_aqo | auto_tuning
----------------------+----------------------+-----------+---------+-------------
 -7943805185414767879 | -7943805185414767879 | t         | t       | f
 -2381932317950706631 | -2381932317950706631 | t         | t       | f
                    0 |                    0 | f         | f       | f
  1981686404362911953 |  1981686404362911953 | t         | t       | f
```

**Đọc hiểu**: Query `-794380...` có `learn_aqo=t, use_aqo=t` → AQO đang **vừa học vừa sử dụng** prediction cho query này.

### 4.3. `aqo_query_stat` — Thống kê thực thi

```
                            View "public.aqo_query_stat"
            Column             |        Type        | Collation | Nullable | Default
-------------------------------+--------------------+-----------+----------+---------
 queryid                       | bigint             |           |          |
 execution_time_with_aqo       | double precision[] |           |          |
 execution_time_without_aqo    | double precision[] |           |          |
 planning_time_with_aqo        | double precision[] |           |          |
 planning_time_without_aqo     | double precision[] |           |          |
 cardinality_error_with_aqo    | double precision[] |           |          |
 cardinality_error_without_aqo | double precision[] |           |          |
 executions_with_aqo           | bigint             |           |          |
 executions_without_aqo        | bigint             |           |          |
```

**Ý nghĩa các cột:**

| Cột                              | Ý nghĩa                                              |
|----------------------------------|-------------------------------------------------------|
| `executions_with_aqo`            | Số lần chạy **có** AQO prediction                     |
| `executions_without_aqo`         | Số lần chạy **không** có AQO prediction               |
| `execution_time_with_aqo`        | Mảng thời gian thực thi (ms) khi dùng AQO            |
| `execution_time_without_aqo`     | Mảng thời gian thực thi (ms) khi không dùng AQO      |
| `cardinality_error_with_aqo`     | Mảng sai số cardinality khi dùng AQO                  |
| `cardinality_error_without_aqo`  | Mảng sai số cardinality khi không dùng AQO            |
| `planning_time_with/without_aqo` | Mảng thời gian planning                               |

> **Lưu ý**: Các cột `*_time` và `*_error` là **mảng** (`double precision[]`), lưu lịch sử nhiều lần chạy gần nhất.

**Ví dụ output thực tế:**

```
       queryid        | executions_with_aqo | executions_without_aqo
----------------------+---------------------+------------------------
 -7943805185414767879 |                   6 |                      0
 -2381932317950706631 |                   5 |                      0
  1981686404362911953 |                   5 |                      0
```

**Đọc hiểu**: Query `-794380...` đã chạy 6 lần với AQO, 0 lần không có AQO → AQO đang tích cực sử dụng prediction.

### 4.4. `aqo_data` — Dữ liệu ML model

```
                      View "public.aqo_data"
   Column    |        Type        | Collation | Nullable | Default
-------------+--------------------+-----------+----------+---------
 fs          | bigint             |           |          |
 fss         | integer            |           |          |
 nfeatures   | integer            |           |          |
 features    | double precision[] |           |          |
 targets     | double precision[] |           |          |
 reliability | double precision[] |           |          |
 oids        | oid[]              |           |          |
```

**Ví dụ output thực tế:**

```
          fs          |     fss     | nfeatures
----------------------+-------------+-----------
 -7943805185414767879 | -2029310292 |         0
 -7943805185414767879 | -1504490013 |         2
 -7943805185414767879 |  1740847502 |         1
 -2381932317950706631 |  1643427917 |         3
```

**Đọc hiểu**:
- `fs=-794380...` là feature space của query "Sales by city"
- Mỗi `fss` là một node trong plan (Seq Scan, Hash Join, Sort, ...)
- `nfeatures=2` nghĩa là node đó có 2 selectivity features đang được theo dõi
- `nfeatures=0` nghĩa là node đó không có features (leaf node đơn giản)

---

## 5. GUC Parameters (Cấu hình)

### 5.1. Bảng tổng hợp tất cả GUC settings

| Parameter                         | Default       | Mô tả                                                                         |
|-----------------------------------|---------------|--------------------------------------------------------------------------------|
| `aqo.mode`                        | `controlled`  | Mode hoạt động (disabled/controlled/learn/intelligent/forced)                  |
| `aqo.show_details`                | `off`         | Hiện AQO prediction per node trong EXPLAIN                                     |
| `aqo.show_hash`                   | `off`         | Hiện query hash và node hash trong EXPLAIN                                     |
| `aqo.join_threshold`              | `3`           | Số JOINs tối thiểu để AQO can thiệp                                           |
| `aqo.force_collect_stat`          | `off`         | Thu thập statistics ở mọi mode (kể cả disabled)                               |
| `aqo.fs_max_items`                | `10000`       | Số feature spaces tối đa                                                       |
| `aqo.fss_max_items`               | `100000`      | Số feature subspaces tối đa                                                    |
| `aqo.dsm_size_max`                | `100`         | Dung lượng tối đa dynamic shared memory (MB)                                   |
| `aqo.min_neighbors_for_predicting`| `3`           | Số neighbors tối thiểu cho k-NN prediction                                     |
| `aqo.predict_with_few_neighbors`  | `on`          | Cho phép predict khi ít neighbors hơn min                                      |
| `aqo.wide_search`                 | `off`         | Tìm ML data trong feature spaces lân cận                                       |
| `aqo.querytext_max_size`          | `1000`        | Kích thước tối đa query text lưu trong aqo_query_texts                         |
| `aqo.learn_statement_timeout`     | `off`         | Học từ plan bị ngắt bởi statement_timeout                                      |
| `aqo.statement_timeout`           | `0`           | Giới hạn thời gian cho learning (0 = không giới hạn)                           |

### 5.2. Cách thiết lập

```sql
-- Per-session
SET aqo.mode = 'learn';
SET aqo.show_details = 'on';
SET aqo.join_threshold = 0;

-- Cluster-wide (cần reload)
ALTER SYSTEM SET aqo.mode = 'intelligent';
ALTER SYSTEM SET aqo.join_threshold = 0;
SELECT pg_reload_conf();

-- Hoặc sửa trực tiếp postgresql.conf
-- shared_preload_libraries = 'aqo'
-- aqo.mode = 'intelligent'
```

### 5.3. Quan trọng: `aqo.join_threshold`

Mặc định = `3`, nghĩa là AQO **chỉ can thiệp** cho query có ≥ 3 JOINs. Đặt = `0` để AQO tối ưu mọi query:

```sql
ALTER SYSTEM SET aqo.join_threshold = 0;
SELECT pg_reload_conf();
```

---

## 6. Cách sử dụng AQO trong thực tế

### 6.1. Pattern cơ bản: Tối ưu query cụ thể

```sql
-- Bước 1: Bật learn mode
BEGIN;
SET aqo.mode = 'learn';

-- Bước 2: Chạy EXPLAIN ANALYZE nhiều lần (AQO học mỗi lần)
EXPLAIN ANALYZE <slow_query>;   -- Lần 1: thu thập
EXPLAIN ANALYZE <slow_query>;   -- Lần 2: bắt đầu predict
EXPLAIN ANALYZE <slow_query>;   -- Lần 3: prediction cải thiện
-- ...tiếp tục đến khi plan ổn định

-- Bước 3: Chuyển về controlled
RESET aqo.mode;
COMMIT;
```

### 6.2. Xem AQO đang làm gì

```sql
-- Bật hiển thị chi tiết
SET aqo.show_details = 'on';
SET aqo.show_hash = 'on';

EXPLAIN ANALYZE <query>;
```

Output sẽ có thêm các dòng:

```
 Sort  (cost=208.27..208.29 rows=7 width=46) (actual time=6.505..6.508 rows=7 loops=1)
   AQO not used, fss=0                           ← AQO chưa có data cho node này
   ->  Hash Join  (cost=37.00..145.58 rows=5000 width=17) (actual time=0.324..3.839 rows=5000 loops=1)
         AQO not used, fss=-1504490013            ← Node hash (fss)
         ->  Seq Scan on aqo_test_orders o  (cost=0.00..82.00 rows=5000 width=12) (actual ...)
               AQO not used, fss=1073653271
 ...
 Using aqo: true           ← AQO đang active cho query này
 AQO mode: LEARN           ← Mode hiện tại
 Query hash: 919205639...  ← Query ID (queryid)
 JOINS: 2                  ← Số JOINs detected
```

Sau khi AQO đã học (chạy nhiều lần), output sẽ thay đổi:

```
 Hash Join  (cost=37.00..145.58 rows=5000 ...) (actual time=... rows=5000 ...)
   AQO: rows=5000, error=0%    ← AQO prediction chính xác!
```

### 6.3. Kiểm tra hiệu quả

```sql
-- So sánh cardinality error WITH vs WITHOUT AQO
SELECT
    queryid,
    executions_with_aqo,
    executions_without_aqo,
    cardinality_error_with_aqo[1:3]    AS recent_errors_with,
    cardinality_error_without_aqo[1:3] AS recent_errors_without
FROM aqo_query_stat
ORDER BY queryid;

-- Xem execution time comparison
SELECT
    queryid,
    execution_time_with_aqo[1:3]    AS time_with_aqo,
    execution_time_without_aqo[1:3] AS time_without_aqo
FROM aqo_query_stat
ORDER BY queryid;
```

### 6.4. Freeze/Lock plan (ngừng học)

```sql
-- Ngừng học nhưng vẫn dùng AQO prediction
UPDATE aqo_queries
SET learn_aqo = false, auto_tuning = false
WHERE queryid = <queryid>;

-- Tắt AQO hoàn toàn cho một query cụ thể
UPDATE aqo_queries
SET use_aqo = false, learn_aqo = false, auto_tuning = false
WHERE queryid = <queryid>;
```

---

## 7. Giải thích chi tiết bộ Test Script

File: `scripts/tests/01-testing-aqo-and-view.sh`

### Tổng quan cấu trúc

Script gồm **7 TEST** + Cleanup + Summary, thiết kế để verify từng lớp hoạt động của AQO.

### TEST 1: PostgreSQL Server Status

```bash
SERVER_STATUS=$(sudo -u postgres $PG_CTL -D $DATA_DIR status 2>&1 || true)
if echo "$SERVER_STATUS" | grep -q "server is running"; then
    check_pass "PostgreSQL server is running"
fi
```

**Mục đích**: Kiểm tra PostgreSQL server đang chạy. Nếu không → tự động start.

**Tại sao quan trọng**: AQO hoạt động ở server level (loaded vào shared memory). Server phải chạy để test.

---

### TEST 2: AQO Extension Verification

Gồm 3 sub-checks:

**2a. Extension installed?**
```sql
SELECT extname || ' v' || extversion FROM pg_extension WHERE extname = 'aqo';
```
→ Verify `CREATE EXTENSION aqo` đã thành công → trả về "aqo v1.6"

**2b. shared_preload_libraries?**
```sql
SHOW shared_preload_libraries;
```
→ Verify AQO được load lúc server startup. **Bắt buộc** vì AQO cần hook vào planner ở cluster level.

**2c. AQO mode?**
```sql
SHOW aqo.mode;
```
→ Hiện mode hiện tại (intelligent/controlled/learn/...)

---

### TEST 3: Setting Up Test Data

**Tạo 3 tables mô phỏng hệ thống e-commerce:**

| Table                | Rows | Mô tả                    |
|----------------------|------|---------------------------|
| `aqo_test_customers` | 1000 | Khách hàng ở 7 thành phố |
| `aqo_test_products`  | 200  | Sản phẩm trong 7 danh mục|
| `aqo_test_orders`    | 5000 | Đơn hàng random           |

**Indexes được tạo:**
- `idx_orders_customer` — trên `customer_id`
- `idx_orders_product` — trên `product_id`
- `idx_orders_date` — trên `order_date`
- `idx_customers_city` — trên `city`
- `idx_products_category` — trên `category`

**ANALYZE** chạy sau insert để PostgreSQL optimizer có base statistics.

**Tại sao cần data này**: AQO cần query thực tế với JOINs phức tạp để showcase tối ưu. Data đủ lớn (6000+ rows) để có sự khác biệt đáng kể giữa estimated vs actual rows.

---

### TEST 4: Running Queries with AQO Learning

**Bước chuẩn bị quan trọng:**

```bash
run_sql "ALTER SYSTEM SET aqo.join_threshold = 0;"    # AQO tối ưu mọi query
run_sql "ALTER SYSTEM SET aqo.force_collect_stat = on;" # Luôn thu thập stats
sudo -u postgres pg_ctl -D ... reload                  # Apply config
```

**3 loại query được test:**

#### Query 1: JOIN + GROUP BY + Aggregation

```sql
SELECT c.city, COUNT(*) as total_orders, SUM(o.quantity * p.price) as revenue
FROM aqo_test_orders o
JOIN aqo_test_customers c ON o.customer_id = c.id
JOIN aqo_test_products p ON o.product_id = p.id
GROUP BY c.city
ORDER BY revenue DESC;
```

**Đặc điểm**: 2 JOINs + GROUP BY + ORDER BY. AQO cần ước lượng chính xác rows qua mỗi JOIN để chọn Hash Join vs Nested Loop, sort method, memory allocation.

#### Query 2: Subquery + HAVING + LIMIT

```sql
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
```

**Đặc điểm**: Subquery phức tạp. PostgreSQL thường ước lượng sai số rows sau HAVING filter → AQO học actual number.

#### Query 3: Multi-condition Filter

```sql
SELECT c.name, p.name as product, p.price, o.quantity, o.order_date
FROM aqo_test_orders o
JOIN aqo_test_customers c ON o.customer_id = c.id
JOIN aqo_test_products p ON o.product_id = p.id
WHERE c.city = 'HCMC'
  AND p.category = 'Electronics'
  AND o.quantity > 5
ORDER BY o.order_date DESC;
```

**Đặc điểm**: Multiple WHERE conditions trên nhiều tables. PostgreSQL giả định independence giữa các conditions → thường underestimate. AQO học correlation thực tế.

**Mỗi query chạy 5+ lần** để AQO thu thập đủ data cho ML model hội tụ.

---

### TEST 5: AQO Statistics & Internal Tables

Đây là phần **quan trọng nhất** — chứng minh AQO đang hoạt động:

**5a. `aqo_query_texts`** → Confirm AQO đã nhận diện và lưu mỗi normalized query.

**5b. `aqo_queries`** → Confirm settings cho mỗi query:
- `learn_aqo = true` → đang học
- `use_aqo = true` → đang sử dụng prediction
- `auto_tuning` → có/không tự điều chỉnh

**5c. `aqo_query_stat`** → Thống kê thực thi:
- `executions_with_aqo > 0` → **chứng minh AQO đang active**
- So sánh `cardinality_error_with_aqo` vs `without` → thấy cải thiện
- So sánh `execution_time_with_aqo` vs `without` → thấy tốc độ

**5d. `aqo_data`** → ML model data — nếu có rows → AQO đã xây dựng model.

**Tiêu chí PASS**: Cả 3 bảng phải có `COUNT(*) > 0`.

---

### TEST 6: AQO Show Details

```sql
SET aqo.show_details = 'on';
SET aqo.show_hash = 'on';
EXPLAIN ANALYZE <query>;
```

**Mục đích**: Hiện trực quan AQO prediction per plan node. Output mẫu:

```
 Hash Join  (cost=37.00..145.58 rows=5000 ...) (actual time=... rows=5000 ...)
   AQO not used, fss=-1504490013      ← Lần đầu: chưa có data
   -- Sau nhiều lần chạy:
   AQO: rows=5000, error=0%           ← AQO prediction chính xác!
 ...
 Using aqo: true                       ← Confirm AQO active
 AQO mode: LEARN
 Query hash: 9192056399137691354       ← Unique query identifier
 JOINS: 2                             ← Số JOINs detected
```

**Đọc hiểu**:
- `AQO not used, fss=...` → Node này AQO chưa có đủ data để predict
- `AQO: rows=N, error=X%` → AQO đang predict, error X% so với actual
- `Using aqo: true/false` → AQO có được sử dụng cho query này không
- `JOINS: N` → Phải ≥ `aqo.join_threshold` để AQO can thiệp

---

### TEST 7: AQO Configuration Summary

```sql
SELECT name, setting, short_desc
FROM pg_settings
WHERE name LIKE 'aqo.%'
ORDER BY name;
```

Liệt kê toàn bộ 14 GUC parameters → confirm cấu hình hiện tại.

---

### Cleanup & Summary

- Drop test tables → không để rác trong database
- Tổng hợp PASS/FAIL → kết quả cuối cùng

---

## 8. Đọc kết quả EXPLAIN ANALYZE với AQO

### 8.1. Ví dụ thực tế (từ test run)

```
 Sort  (cost=208.27..208.29 rows=7 width=46) (actual time=5.769..5.772 rows=7 loops=1)
   Sort Key: (sum(((o.quantity)::numeric * p.price))) DESC
   Sort Method: quicksort  Memory: 25kB
   ->  HashAggregate  (cost=208.08..208.17 rows=7 width=46) (actual time=5.717..5.722 rows=7 loops=1)
         Group Key: c.city
         ->  Hash Join  (cost=37.00..145.58 rows=5000 width=17)
               (actual time=0.421..3.475 rows=5000 loops=1)
               Hash Cond: (o.product_id = p.id)
               ->  Hash Join  (cost=30.50..125.68 rows=5000 width=14)
                     (actual time=0.324..2.376 rows=5000 loops=1)
                     Hash Cond: (o.customer_id = c.id)
                     ->  Seq Scan on aqo_test_orders o
                           (cost=0.00..82.00 rows=5000 width=12)
                           (actual time=0.005..0.562 rows=5000 loops=1)
 Planning Time: 2.331 ms
 Execution Time: 6.060 ms
```

### 8.2. Cách đọc

| Thông tin              | Giá trị mẫu | Ý nghĩa                                      |
|------------------------|--------------|-----------------------------------------------|
| `cost=208.27..208.29`  | Ước lượng    | Cost units cho startup..total                  |
| `rows=7`               | **Estimated** | PostgreSQL (hoặc AQO) ước lượng 7 rows output |
| `actual time=5.769`    | Thực tế      | Thời gian thực thi (ms)                        |
| `rows=7` (actual)      | **Actual**   | Thực tế trả về 7 rows                          |
| `width=46`             | Bytes/row    | Kích thước trung bình mỗi row                  |

**Key insight**: So sánh `rows` (estimated) vs `rows` (actual):
- `rows=5000` estimated vs `rows=5000` actual → **cardinality estimation chính xác** ✓
- Nếu estimated = 100 nhưng actual = 50000 → **sai lệch lớn** → optimizer chọn plan sai

### 8.3. Với AQO show_details

```
 Hash Join  (cost=37.00..145.58 rows=5000 ...) (actual time=... rows=5000 ...)
   AQO not used, fss=-1504490013
```

→ Ban đầu AQO chưa can thiệp node này. Sau vài lần learn:

```
 Hash Join  (cost=37.00..145.58 rows=5000 ...) (actual time=... rows=5000 ...)
   AQO: rows=5000, error=0%
```

→ AQO predict 5000 rows, error 0% — prediction hoàn hảo!

---

## 9. Recipes & Best Practices

### 9.1. Workflow cho Production

```sql
-- 1. Mặc định dùng controlled mode
ALTER SYSTEM SET aqo.mode = 'controlled';

-- 2. Khi phát hiện query chậm, bật learn trong session
SET aqo.mode = 'learn';
EXPLAIN ANALYZE <slow_query>;  -- Chạy 5-10 lần
SET aqo.mode = 'controlled';

-- 3. Verify
SET aqo.show_details = 'on';
EXPLAIN ANALYZE <slow_query>;  -- Xem AQO prediction

-- 4. Freeze khi hài lòng
UPDATE aqo_queries SET learn_aqo = false WHERE queryid = <id>;
```

### 9.2. Tắt AQO tạm thời

```sql
-- Per-session
SET aqo.mode = 'disabled';

-- Cluster-wide
ALTER SYSTEM SET aqo.mode = 'disabled';
SELECT pg_reload_conf();
```

### 9.3. Reset/Xóa data AQO

```sql
-- Xóa statistics cho query cụ thể
DELETE FROM aqo_query_stat WHERE queryid = <id>;
DELETE FROM aqo_data WHERE fs = <id>;

-- Xóa toàn bộ (CẢNH BÁO: mất hết data đã học)
DELETE FROM aqo_query_stat;
DELETE FROM aqo_data WHERE fs != 0;
DELETE FROM aqo_queries WHERE queryid != 0;
DELETE FROM aqo_query_texts WHERE queryid != 0;
-- KHÔNG xóa queryid = 0 (COMMON feature space)
```

### 9.4. Monitor AQO health

```sql
-- Xem tổng quan AQO usage
SELECT
    (SELECT COUNT(*) FROM aqo_query_texts) AS known_queries,
    (SELECT COUNT(*) FROM aqo_data) AS ml_models,
    (SELECT SUM(executions_with_aqo) FROM aqo_query_stat) AS total_aqo_executions,
    (SELECT SUM(executions_without_aqo) FROM aqo_query_stat) AS total_normal_executions;
```

### 9.5. Limitations

- **Không hoạt động với temporary objects** (OIDs khác nhau mỗi lần)
- **Không thu thập stats trên replicas** (read-only)
- `learn` và `intelligent` modes không nên dùng cluster-wide với dynamic query structures
- AQO thêm overhead cho planning time (thường 1-5ms) → chỉ đáng cho query phức tạp

---

> **Tài liệu gốc**: [AQO README](https://github.com/vietrion-lab/semantic-aqo-main/blob/master/README.md)  
> **Paper**: [Adaptive Query Optimization (arXiv:1711.08330)](https://arxiv.org/abs/1711.08330)
