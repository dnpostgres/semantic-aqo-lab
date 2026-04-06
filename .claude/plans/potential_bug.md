# Task: Investigate Why SAQO Underperforms AQO 3-NN

## Status: NOT STARTED

## Problem Statement

Across all three benchmarks, Semantic AQO consistently produces **worse cardinality estimates** than the standard AQO 3-NN, despite having a theoretically richer feature representation (17-dim semantic + selectivity vs pure statistical features):

| Benchmark | SAQO Q-error | AQO 3-NN Q-error | Gap |
|-----------|-------------|-------------------|-----|
| JOB | ~2.5–3.0 | ~1.8 | +39–67% worse |
| STATS | ~1.8 | ~1.2 | +50% worse |
| TPC-H | ~2.5 | ~2.0 | +25% worse |

Additionally, SAQO exhibits **violent execution time spikes** (JOB iter 8: ~4000ms, iter 11: ~1900ms) that AQO 3-NN does not, suggesting the predictions occasionally go catastrophically wrong.

The report attributes this to surface-level factors (O(n) token search, butterfly effect, feature fragmentation). But these explain **latency**, not **accuracy**. Something deeper in the estimation logic is wrong. The task is to find it.

## Investigation Scope

### 1. 2-NN Prediction Logic (`machine_learning.c`)
- Is the distance-weighted interpolation formula correct? Edge cases when both neighbors are equidistant or one is at distance zero?
- Does k=2 create instability compared to k=3? Does the system degrade when the two neighbors are on opposite sides of a caterpillar vs the same side?
- Is the distance metric appropriate for a space where 16 dims are semantic and 1 dim is log-selectivity? The scales may be completely different, causing the selectivity dimension to be dominated or dominating.
- How does the merge threshold (0.6) interact with the prediction? Are near-duplicate points being merged too aggressively, destroying useful interpolation anchors?
- Learning rate (0.01) for EMA merge — is this too conservative, causing the system to adapt too slowly to data drift?

### 2. Feature Vector Construction (`cardinality_estimation.c`)
- The 17-dim vector is `[16-dim W2V embedding || log(product of selectivities)]`. Is the concatenation balanced? If the W2V dimensions are in range [-1, 1] but log-selectivity spans [-20, 0], the distance metric is completely dominated by selectivity — making the semantic embedding useless.
- Is there a normalization step? If not, this is likely **the primary bug**.
- How is selectivity computed for multi-clause nodes? Product of individual selectivities still assumes independence — the same flaw SAQO claims to fix.
- What happens when selectivity is 0 or 1? `log(0) = -inf` would corrupt the entire feature vector.

### 3. W2V Embedding Quality (`w2v_embedding_extractor.c`, `w2v_inference.c`)
- The positional weighting uses Gaussian centered at sequence midpoint. Is this correct for SQL? The most important tokens (column names, operators) may not be centered.
- What happens when a token is not found in `token_embeddings`? Is it silently skipped (shrinking the effective sequence) or replaced with a zero vector (pulling the embedding toward origin)?
- The O(n) linear search for token lookup — beyond latency, does this introduce any ordering bias or early-termination bugs?
- Are the embeddings loaded once and cached correctly, or is there a race condition on first use across backends?

### 4. SQL Preprocessing & Normalization (`sql_preprocessor.c`, `node_context.c`)
- Does the 3-stage normalization pipeline produce consistent output? Are there edge cases where the same logical query produces different masked strings (leading to different embeddings, breaking the caterpillar assumption)?
- Type cast stripping (`::text`, `::integer`) — does this ever remove structurally meaningful information?
- Parenthesis removal — could this change operator precedence semantics?
- Are there SQL patterns in JOB/STATS/TPC-H that the tokenizer doesn't handle, producing garbage tokens that poison the embedding?

### 5. Space Routing & Hash (`node_context.c`, `hash.c`)
- `space_hash` is based on sorted relation OIDs. Are there cases where the same logical query gets routed to different spaces (e.g., due to view expansion, CTEs, or subquery flattening)?
- Could space fragmentation cause some spaces to have too few data points for meaningful 2-NN, while others are overcrowded?
- The wide-search fallback — when it triggers, does borrowing from a neighboring space inject misleading data points?

### 6. Expression Deparsing (`path_utils.c`)
- The safe deparser (`aqo_safe_deparse_expr`) uses `<EXPR>` as a catch-all for unknown node types. If many clauses hit this fallback, structurally different queries would produce identical embeddings, collapsing the caterpillar into a single point.
- Operator mapping (e.g., `~~` → `LIKE`) — are all PG internal operators covered? Missing ones would produce raw operator names that don't match the W2V vocabulary.
- SubPlan replacement — does replacing subplans with a constant lose structural information that AQO 3-NN retains?

### 7. Feedback Loop & Learning (`postprocessing.c`, `storage.c`)
- When is learning skipped? Are there conditions (nested queries, parallel workers, timeouts) where the executor hook doesn't fire, creating gaps in the historical data?
- Storage capacity limits — when `aqo_data` is full, what gets evicted? If older but important data points are lost, the caterpillar trajectories become sparse.
- Is there a mismatch between what the planner hook collects (estimated cardinality) and what the executor hook stores (true cardinality)? If they correspond to different nodes, the 2-NN trains on wrong labels.

### 8. The "Butterfly Effect" — Root Cause Analysis
- The report mentions that correcting a local estimate can trigger a globally worse plan. But is this inherent to the approach, or is it because SAQO's corrections are **slightly wrong** (biased) in a way that consistently misleads the planner?
- Compare: AQO 3-NN also corrects local estimates but doesn't exhibit these spikes. What makes its corrections more stable?

## Deliverables

1. **List of confirmed bugs** with code references, root cause, and severity rating
2. **List of design-level logic mismatches** that are not bugs but architectural decisions that hurt accuracy
3. **Prioritized fix plan** — which fixes would yield the biggest accuracy improvement with the least effort
4. **Reproducible test cases** — specific queries from JOB/STATS/TPC-H that trigger each identified issue

## Files to Examine

| Priority | File | What to Look For |
|----------|------|------------------|
| P0 | `cardinality_estimation.c` | Feature vector construction, normalization (or lack of), selectivity edge cases |
| P0 | `machine_learning.c/h` | 2-NN distance formula, interpolation, merge logic, numerical stability |
| P0 | `w2v_embedding_extractor.c/h` | Positional weighting, unknown token handling, aggregation correctness |
| P1 | `w2v_inference.c/h` | Token lookup, missing token behavior, initialization race |
| P1 | `node_context.c/h` | Normalization consistency, space_hash correctness |
| P1 | `sql_preprocessor.c/h` | Tokenization edge cases, masking completeness |
| P1 | `path_utils.c/h` | Deparse coverage, `<EXPR>` fallback frequency, operator mapping |
| P2 | `postprocessing.c` | Learning skip conditions, feedback data correctness |
| P2 | `storage.c/h` | Capacity limits, eviction, data integrity |
| P2 | `cardinality_hooks.c` | Selectivity computation, clause passing |
| P3 | `hash.c/h` | Hash collision probability |
| P3 | `selectivity_cache.c` | Cache staleness |

## Hypothesis (To Be Validated)

The most likely root cause is a **feature scale mismatch** in the 17-dim vector: 16 W2V dimensions in a small range vs 1 log-selectivity dimension in a large range, making Euclidean distance in 2-NN effectively ignore the semantic embedding. If true, this would explain why SAQO degrades to a "selectivity-only" predictor that's strictly worse than AQO 3-NN's multi-feature statistical approach.
