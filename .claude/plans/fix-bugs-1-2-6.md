# Plan: Revert Recent Changes + Fix Bugs #1, #2, #6 in Semantic AQO

## Context

The `semantic-aqo-main` extension (branch `fix/saqo-5bugs-pipeline`) has 3 recent commits from 2026-04-04 that attempted bug fixes but were experimental/debug-heavy. The user wants to:
1. **Revert** all 3 commits back to clean base (`d76d541`)
2. **Fix Bug #1** (P0): Feature Scale Mismatch — selectivity dominates 97-100% of kNN distance
3. **Fix Bug #2** (P0): Tokenizer breaks masked tokens (`<NUM>` → `<`, `NUM`, `>`)
4. **Fix Bug #6** (Low): Dead normalization code — `normalize_clause_for_w2v()` never called

Bug #6 depends on Bug #2 being fixed first (tokenizer must preserve `<NUM>` tokens).

**Extension path:** `src/semantic-aqo-main/extension/` (symlinked from `src/postgresql-15.15/contrib/aqo/`)

---

## Step 0: Revert to Clean Base

```bash
cd src/semantic-aqo-main
git reset --hard d76d541
```

This removes commits `092eae4`, `af5b4f8`, `b7e3aa3` (debug code, broken 3-dim expansion, adaptive sigma).

---

## Step 1: Fix Bug #2 — Tokenizer Breaks Masked Tokens

**File:** `extension/sql_preprocessor.c`

**Problem:** Line 335 `strchr("(),;.=<>+-*/", *p)` treats `<` and `>` as operators, splitting `<NUM>` into 3 tokens.

**Fix:** Add `detect_masked_token()` helper and check it in `extract_token()` **before** the operator checks.

Add before `extract_token()` (~line 265):
```c
static int
detect_masked_token(const char *p)
{
    const char *inner;
    if (*p != '<') return 0;
    inner = p + 1;
    if (!(*inner >= 'A' && *inner <= 'Z')) return 0;
    while (*inner >= 'A' && *inner <= 'Z' || *inner == '_') inner++;
    if (*inner != '>') return 0;
    return (int)(inner - p + 1);
}
```

Insert in `extract_token()` just before the multi-char operator block (`if (*p == '<' && *(p+1) == '=')`):
```c
{
    int masked_len = detect_masked_token(p);
    if (masked_len > 0 && (size_t)masked_len < buf_size) {
        memcpy(token_buf, p, masked_len);
        token_buf[masked_len] = '\0';
        return p + masked_len;
    }
}
```

---

## Step 2: Fix Bug #6 — Wire `normalize_clause_for_w2v()` into Pipeline

**File:** `extension/path_utils.c`

**Problem:** The function exists at line ~1912 but is never called. The pipeline goes `deparse -> tokenize -> embed` but should be `deparse -> normalize -> tokenize -> embed`.

**Fix:** Insert call at both call sites:

1. **`aqo_create_plan()`** (~line 1370): Before `w2v_extract_sql_embedding()`:
```c
safe_copy = pstrdup(clause_buf.data);
/* Normalize before embedding: strip parens, casts, mask literals */
{
    char *normalized = normalize_clause_for_w2v(safe_copy);
    pfree(safe_copy);
    safe_copy = normalized;
}
emb_result = w2v_extract_sql_embedding(safe_copy, 1.0f);
```

2. **`aqo_compute_embedding()`** (~line 1844): Same pattern before `w2v_extract_sql_embedding()`:
```c
safe_copy = pstrdup(clause_buf.data);
{
    char *normalized = normalize_clause_for_w2v(safe_copy);
    pfree(safe_copy);
    safe_copy = normalized;
}
emb_result = w2v_extract_sql_embedding(safe_copy, 1.0f);
```

---

## Step 3: Fix Bug #1 — Feature Scale Mismatch

**Problem:** The 17-dim feature vector `[w2v[0..15], log_sel_product]` has unbalanced scales. W2V dims ~[-1,1] vs log_sel_product ~[-30, 0]. Euclidean distance is 97-100% dominated by selectivity, making W2V useless.

**Fix:** Scale the single selectivity dimension down to match W2V range. Stays at 17 dimensions (no structural change).

### 3a. `extension/machine_learning.h`

Add a scaling constant (no dimension change — stays at 17):
```c
/* Scaling factor: bring log_sel_product into ~[-3, 0] range to match W2V ~[-1, 1] */
#define AQO_SCALE_LOG_SEL  10.0
```

### 3b. `extension/cardinality_estimation.c` :: `predict_for_relation()`

After computing `log_sel_product`, scale it before storing:
```c
semantic_features[AQO_EMBEDDING_DIM] = log_sel_product / AQO_SCALE_LOG_SEL;
```

### 3c. `extension/postprocessing.c` :: `learn_sample()`

Same scaling in the learn path:
```c
semantic_features[AQO_EMBEDDING_DIM] = log_sel_product / AQO_SCALE_LOG_SEL;
```

**Scaling rationale:**
- W2V norms: ~2.3 across 16 dims -> per-dim ~[-1, 1]
- `log_sel_product / 10`: range [-30, 0] -> [-3, 0]
- Result: selectivity contributes ~50-60% of L2 distance (vs. previously ~99%)
- No dimension change -> no data incompatibility

---

## Step 4: Recompile + Test

```bash
cd src/scripts
bash 03-recompile-extensions.sh --quick
```

Then reset aqo data (existing data has unscaled selectivity):
```bash
sudo -u postgres psql test -c "SELECT aqo_reset();"
```

Run tests:
```bash
cd src/postgresql-15.15/contrib/aqo && make check
```

---

## Files Modified

| File | Changes |
|------|---------|
| `extension/sql_preprocessor.c` | Add `detect_masked_token()`, insert check before operator handling |
| `extension/path_utils.c` | Wire `normalize_clause_for_w2v()` at 2 call sites |
| `extension/machine_learning.h` | Add `AQO_SCALE_LOG_SEL` constant |
| `extension/cardinality_estimation.c` | Scale log_sel_product by `AQO_SCALE_LOG_SEL` |
| `extension/postprocessing.c` | Same scaling in learn path |

---

## Risks

1. **Data reset needed**: Old `aqo_data` has unscaled selectivity values. Must run `SELECT aqo_reset()` after recompile.
2. **Test expectations**: `make check` `.out` files may need updates if output changes.
3. **Double masking**: `aqo_safe_deparse_expr` already masks some constants -> `normalize_clause_for_w2v` may re-mask. This is benign (already-masked tokens like `<NUM>` pass through unchanged).

---

## Verification

1. `make check` passes in `contrib/aqo`
2. Run a simple query with `EXPLAIN (ANALYZE)` and verify no crashes
3. Verify tokenizer preserves `<NUM>`, `<STR>` tokens (check server logs with debug)
4. Run a few JOB queries to confirm predictions are generated without errors
