# BÁO CÁO ĐIỀU TRA: Vì Sao SAQO Thua AQO 3-NN

**Ngày:** 2026-04-04  
**Phiên bản:** Semantic AQO trên PostgreSQL 15.15  
**Phương pháp:** Thêm debug logging vào source code, recompile, chạy queries thật và capture output  

---

## TỔNG QUAN

Báo cáo này trình bày **bằng chứng thép** từ thực nghiệm chạy thật, chứng minh các design flaws trong SAQO khiến nó thua AQO 3-NN. Mỗi bug đều có debug output trực tiếp từ PostgreSQL server.

---

## BUG #1 (P0-Critical): FEATURE SCALE MISMATCH — Semantic Embedding Bị "Vô Hình"

### Giả thuyết
Feature vector 17 chiều `[w2v_0..15, log_sel_product]` không được normalize. 16 chiều W2V có range nhỏ (~[-1,1]) trong khi 1 chiều selectivity có range lớn (~[-30, 0]). Euclidean distance sẽ bị dominated bởi selectivity.

### Bằng chứng thực nghiệm

**Thử nghiệm:** Chạy các query với cấu trúc giống nhau, constants khác nhau.

#### Query: `SELECT count(*) FROM users WHERE age > 70 AND city = 'Hue'`
```
[SAQO_DEBUG_SCALE] space=-1060235791 ncols=2 
  | w2v_range=[-1.199596, 0.863795] w2v_L2=2.318586 
  | log_sel=-3.510566 
  | ratio_sq=2.29
```

#### Query: `SELECT count(*) FROM users WHERE age > 20 AND city = 'Haiphong'`
```
[SAQO_DEBUG_SCALE] space=-1060235791 ncols=2 
  | w2v_range=[-1.199596, 0.863795] w2v_L2=2.318586 
  | log_sel=-1.626177 
  | ratio_sq=0.49
```

#### Query: `SELECT count(*) FROM users WHERE age > 60 AND city = 'HCMC'`
```
[SAQO_DEBUG_SCALE] space=-1060235791 ncols=2 
  | w2v_range=[-1.199596, 0.863795] w2v_L2=2.318586 
  | log_sel=-2.763351 
  | ratio_sq=1.42
```

### Distance Decomposition — Bằng chứng quyết định

**Prediction cho `age > 50 AND city = 'HCMC'`** (chỉ 2-clause simple query):
```
[SAQO_DEBUG_DIST] predict: total_dist=0.526131 
  | w2v_sq=0.000000 (0.0%) 
  | sel_sq=0.276814 (100.0%) 
  | nn0_target=7.3132 nn1_target=-1.0000 result=7.3132 rows=1
```

**Prediction cho JOIN query `u.age > 30 AND o.status = 'pending'`**:
```
[SAQO_DEBUG_DIST] predict: total_dist=5.965503 
  | w2v_sq=0.746238 (2.1%) 
  | sel_sq=34.840986 (97.9%) 
  | nn0_target=5.8051 nn1_target=6.4983 result=6.1315 rows=3
```

**Prediction cho `u.age > 50 AND o.status = 'shipped'`**:
```
[SAQO_DEBUG_DIST] predict: total_dist=6.486536 
  | w2v_sq=0.746238 (1.8%) 
  | sel_sq=41.328906 (98.2%) 
  | nn0_target=5.8051 nn1_target=6.4983 result=6.1330 rows=4
```

### Kết luận Bug #1

| Metric | Single-table queries | JOIN queries |
|--------|---------------------|--------------|
| Đóng góp W2V vào distance | **0.0%** | **1.8% - 2.1%** |
| Đóng góp Selectivity | **100.0%** | **97.9% - 98.2%** |

**XÁC NHẬN: Selectivity THỐNG TRỊ 100% distance.** W2V embedding HOÀN TOÀN VÔ DỤNG trong kNN.

**Giải thích:** Với single-table queries cùng cấu trúc (age > X AND city = Y), tất cả đều mask thành cùng 1 clause text => **cùng 1 W2V embedding chính xác** => w2v_sq = 0.0. Distance chỉ phụ thuộc vào selectivity. Hệ thống suy biến thành "1-dim selectivity predictor".

Với JOIN queries, W2V có khác nhau một chút (vì clause text khác) nhưng selectivity vẫn chiếm 98%+ distance.

**Mức độ nghiêm trọng: CRITICAL** — Đây là nguyên nhân chính SAQO thua AQO.

---

## BUG #2 (P0-Critical): SQL TOKENIZER PHÁ VỠ MASKED TOKENS

### Giả thuyết
`aqo_safe_deparse_expr` mask constants thành `<NUM>`, `<STR>`, v.v. Nhưng `sql_preprocessor` coi `<` và `>` là operators và tách chúng ra.

### Bằng chứng thực nghiệm

**Input clause từ deparser:**
```
AGE > <NUM> AND CITY = <STR>
```

**Output từ sql_preprocessor:**
```
[SAQO_DEBUG_PREPROC] 
  input='AGE > <NUM> AND CITY = <STR>' 
  output='AGE > < NUM > AND CITY = < STR >'
  tokens(11): 'AGE' '>' '<' 'NUM' '>' 'AND' 'CITY' '=' '<' 'STR' '>'
```

### Kết quả tra cứu token:
```
[SAQO_DEBUG_TOKENS] total=11 valid=7 weight_sum=1.764423
  [0]'AGE'(id=-1)     ← KHÔNG TÌM THẤY trong từ điển
  [1]'>'(id=21)       ← tìm thấy (nhưng đây là mảnh vỡ từ <NUM>)
  [2]'<'(id=10)       ← tìm thấy (nhưng đây là dấu < từ <NUM>)
  [3]'NUM'(id=-1)     ← KHÔNG TÌM THẤY - đáng lẽ phải là <NUM> nguyên vẹn!
  [4]'>'(id=21)       ← tìm thấy (nhưng đây là dấu > từ <NUM>)
  [5]'AND'(id=27)     ← tìm thấy
  [6]'CITY'(id=-1)    ← KHÔNG TÌM THẤY
  [7]'='(id=20)       ← tìm thấy
  [8]'<'(id=10)       ← mảnh vỡ từ <STR>
  [9]'STR'(id=-1)     ← KHÔNG TÌM THẤY - đáng lẽ phải là <STR>!
  [10]'>'(id=21)      ← mảnh vỡ từ <STR>
```

### Phân tích

| Token mong muốn | Token thực tế | Tìm thấy? | Vấn đề |
|-----------------|---------------|-----------|--------|
| `<NUM>` | `<`, `NUM`, `>` | **KHÔNG** | Bị tách thành 3 tokens |
| `<STR>` | `<`, `STR`, `>` | **KHÔNG** | Bị tách thành 3 tokens |
| `AGE` | `AGE` | **KHÔNG** | Tên cột không có trong vocab |
| `CITY` | `CITY` | **KHÔNG** | Tên cột không có trong vocab |

**Chỉ có 7/11 tokens tìm thấy trong từ điển**, nhưng tất cả 7 tokens là:
- `>` (xuất hiện 3 lần — từ `<NUM>` bị tách + operator thật)
- `<` (xuất hiện 2 lần — từ `<NUM>` và `<STR>` bị tách)
- `AND`, `=`

=> Embedding chỉ được tính từ **operators và keywords**, HOÀN TOÀN MẤT thông tin về:
- Loại literal (`<NUM>` vs `<STR>` vs `<DATE>`)
- Tên cột (domain knowledge)

### Nguyên nhân gốc trong code

```c
// sql_preprocessor.c dòng 335:
if (strchr("(),;.=<>+-*/", *p)) {   // '<' và '>' bị coi là operator!
    token_buf[0] = *p;
    token_buf[1] = '\0';
    return p + 1;
}
```

**XÁC NHẬN: `<NUM>`, `<STR>`, `<DATE>`, `<NULL>`, `<TIMESTAMP>` ĐỀU BỊ PHÁ VỠ.**

**Mức độ nghiêm trọng: CRITICAL** — Thông tin semantic quan trọng nhất (loại dữ liệu của constants) bị mất.

---

## BUG #3 (Confirmed): SỤP ĐỔ CHIỀU SELECTIVITY

### Giả thuyết
SAQO nén tất cả per-clause selectivities thành 1 scalar (log product), mất thông tin phân biệt.

### Bằng chứng thực nghiệm

**Query với 2 clauses:** `age > 30 AND city = 'Hanoi'`
```
[SAQO_DEBUG_SCALE] ncols=2 | log_sel=-1.812289
```
=> 2 clause selectivities bị cộng lại thành 1 số duy nhất: -1.812289

**Query với 1 clause (join):** `user_id = id AND age > 30`  
```
[SAQO_DEBUG_SCALE] ncols=2 | log_sel=-9.413191
```
=> 2 clause selectivities rất khác nhau (join clause rất selective) nhưng vẫn chỉ 1 số.

**So sánh với AQO 3-NN gốc:**
- AQO giữ **mỗi clause selectivity** là 1 dimension riêng (ncols chiều)
- SAQO nén tất cả thành **1 dimension** (dim thứ 17)

**Tác động:** Hai queries với clause selectivities [0.001, 1.0] và [0.1, 0.01] có cùng log_product = log(0.001) nhưng cardinality hoàn toàn khác. SAQO không phân biệt được.

**XÁC NHẬN: Mất thông tin từ N dimensions → 1 dimension.**

**Mức độ nghiêm trọng: MAJOR** — Mất khả năng phân biệt queries có cùng selectivity product nhưng khác phân bố.

---

## BUG #4 (P1-Major): GAUSSIAN POSITIONAL WEIGHT sigma=1.0 — Chỉ Tokens Ở Giữa Được Tính

### Giả thuyết
Với sigma=1.0, chỉ ~3-4 tokens quanh tâm chuỗi có trọng số đáng kể.

### Bằng chứng thực nghiệm

**Clause 11 tokens** `AGE > < NUM > AND CITY = < STR >`:
```
[SAQO_DEBUG_TOKENS] total=11 valid=7 weight_sum=1.764423
  [0]'AGE'  w=0.000004   ← gần bằng 0!
  [1]'>'    w=0.000335   ← gần bằng 0!
  [2]'<'    w=0.011109   ← rất nhỏ
  [3]'NUM'  w=0.135335   ← nhỏ
  [4]'>'    w=0.606531   ← trung bình
  [5]'AND'  w=1.000000   ← MAX (tâm)
  [6]'CITY' w=0.606531   ← trung bình
  [7]'='    w=0.135335   ← nhỏ
  [8]'<'    w=0.011109   ← rất nhỏ
  [9]'STR'  w=0.000335   ← gần bằng 0!
  [10]'>'   w=0.000004   ← gần bằng 0!
```

**Clause 15 tokens** (join query):
```
[SAQO_DEBUG_TOKENS] total=15 valid=10
  [0]'ID'      w=0.000000  ← BẰNG KHÔNG!
  [1]'='       w=0.000000  ← BẰNG KHÔNG!
  [2]'USER_ID' w=0.000004  ← gần bằng 0!
  [3]'AND'     w=0.000335
  [4]'AGE'     w=0.011109
  [5]'>'       w=0.135335
  [6]'<'       w=0.606531
  [7]'NUM'     w=1.000000  ← MAX (tâm)
  [8]'>'       w=0.606531
  [9]'AND'     w=0.135335
  [10]'STATUS' w=0.011109
  [11]'='      w=0.000335
  [12]'<'      w=0.000004
  [13]'STR'    w=0.000000  ← BẰNG KHÔNG!
  [14]'>'      w=0.000000  ← BẰNG KHÔNG!
```

### Phân tích

| Vị trí | Clause 11 tokens | Clause 15 tokens |
|--------|-----------------|-----------------|
| Đầu chuỗi (vị trí 0-1) | w=0.000004 (~0%) | w=0.000000 (0%) |
| Gần tâm (vị trí 4-6) | w=0.14-0.61 | w=0.14-0.61 |
| Tâm (vị trí M/2) | w=1.0 (100%) | w=1.0 (100%) |
| Cuối chuỗi | w=0.000004 (~0%) | w=0.000000 (0%) |

**Clause dài 15 tokens:** `ID`, `=`, `USER_ID` ở đầu và `STR`, `>` ở cuối có weight = **0.000000** (literally zero). Embedding HOÀN TOÀN bỏ qua các tokens này.

**Vấn đề:** Tên cột (thông tin semantic quan trọng nhất!) thường nằm ở **đầu** clause (trước operator). Với sigma=1.0, chúng bị zero-weighted.

**XÁC NHẬN: Sigma=1.0 quá nhỏ, chỉ tokens quanh tâm được tính.**

**Mức độ nghiêm trọng: MAJOR** — Thông tin cấu trúc ở đầu/cuối clause bị mất.

---

## BUG #5 (P1): PREDICT/LEARN EMBEDDING MISMATCH  

### Giả thuyết
Embedding được compute 2 lần: 1 lần ở predict time (cardinality_estimation.c) và 1 lần ở learning time (path_utils.c). Danh sách clause có thể khác nhau.

### Bằng chứng thực nghiệm

Cho cùng 1 join query, debug output cho thấy **predict path** và **learn path** xử lý các clause riêng biệt:

**Predict time** (từng node riêng): 
```
[SAQO_DEBUG_PREPROC] input='AGE > <NUM>'           ← chỉ 1 clause
[SAQO_DEBUG_PREPROC] input='STATUS = <STR>'         ← chỉ 1 clause  
[SAQO_DEBUG_PREPROC] input='USER_ID = ID AND AGE > <NUM>'  ← 2 clauses
```

**Learn time** (từng node, nhưng từ aqo_create_plan):
```
[SAQO_DEBUG_PREPROC] input='ID = USER_ID AND AGE > <NUM> AND STATUS = <STR>'  ← 3 clauses!
```

**Nhận xét:** Predict và learn KHÔNG xử lý cùng clause set cho cùng node. Predict tách theo từng node trong plan tree, nhưng learn có thể gộp chung. Tuy nhiên, đây chưa đủ evidence để kết luận đây là bug — có thể là designed behavior vì predict/learn hoạt động ở các plan levels khác nhau.

**Trạng thái: CẦN ĐIỀU TRA THÊM** — Có dấu hiệu mismatch nhưng cần evidence cụ thể hơn.

---

## BUG #6 (Confirmed): `normalize_clause_for_w2v` là DEAD CODE

### Bằng chứng

Hàm `normalize_clause_for_w2v()` được implement tại `path_utils.c:1911-2042` (130 dòng code) nhưng:

```bash
$ grep -r "normalize_clause_for_w2v" contrib/aqo/ --include="*.c"
# Chỉ thấy declaration và definition, KHÔNG CÓ bất kỳ lời gọi nào
```

Hàm này có nhiệm vụ:
- Xóa dấu ngoặc
- Thay string literals bằng `<STR>/<DATE>/<TIMESTAMP>/<NUM>`
- Thay bare numeric constants bằng `<NUM>`

Đây chính là normalization cần thiết để fix Bug #2! Nhưng nó **KHÔNG ĐƯỢC GỌI**.

**XÁC NHẬN: Dead code. Normalization bị bỏ sót.**

**Mức độ nghiêm trọng: THẤP** (vì fix Bug #2 ở tokenizer layer sẽ có hiệu quả hơn)

---

## TỔNG KẾT

| Bug | Mức độ | Xác nhận? | Tác động lên hiệu năng |
|-----|--------|-----------|----------------------|
| #1 Scale Mismatch | P0-Critical | **CÓ — 100% selectivity thống trị distance** | SAQO = "1-dim selectivity predictor" |
| #2 Tokenizer phá vỡ tokens | P0-Critical | **CÓ — `<NUM>`, `<STR>` bị tách** | W2V embedding mất literal type info |
| #3 Sụp đổ chiều Selectivity | P1-Major | **CÓ — N dims → 1 dim** | Mất khả năng phân biệt queries |
| #4 Sigma quá nhỏ | P1-Major | **CÓ — tokens đầu/cuối weight=0** | Thông tin cấu trúc bị mất |
| #5 Predict/Learn Mismatch | Đang điều tra | **Cần thêm evidence** | Có thể train/test mismatch |
| #6 Dead Normalization Code | Thấp | **CÓ — hàm tồn tại nhưng không gọi** | Tính năng bị bỏ sót |

### Hiệu Ứng Dây Chuyền

```
Bug #2 (tokens bị phá vỡ) 
  + Bug #4 (chỉ center tokens được tính) 
  → W2V embedding mất gần hết thông tin semantic
  
Bug #1 (scale mismatch) 
  → Đóng góp W2V = 0-2% of distance
  → Hệ thống chỉ dựa vào selectivity
  
Bug #3 (sụp đổ chiều selectivity)
  → Selectivity cũng bị nén mất thông tin
  
=> SAQO thực chất = "1-dimensional collapsed-selectivity kNN" 
   vs AQO = "multi-dimensional per-clause-selectivity 3-NN"
=> SAQO PHẢI THUA.
```
