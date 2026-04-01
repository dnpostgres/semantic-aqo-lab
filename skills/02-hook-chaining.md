# Skill: Hook Chaining

The fundamental cooperation pattern for PG extensions. Every hook follows the **save → install → chain** idiom.

## The Core Pattern

```c
// 1. File-scoped static to save the previous hook
static ExecutorEnd_hook_type aqo_ExecutorEnd_next = NULL;

// 2. Your replacement hook function
static void
aqo_ExecutorEnd(QueryDesc *queryDesc)
{
    // ... your logic BEFORE ...

    // Chain to previous hook (or standard function)
    (*aqo_ExecutorEnd_next)(queryDesc);

    // ... your logic AFTER ...
}

// 3. Installation (called from _PG_init or init sub-function)
void
my_init(void)
{
    aqo_ExecutorEnd_next = ExecutorEnd_hook
                           ? ExecutorEnd_hook
                           : standard_ExecutorEnd;
    ExecutorEnd_hook = aqo_ExecutorEnd;
}
```

## Variant: Hooks Without a Standard Fallback

Some hooks (Explain, etc.) can be `NULL` — check before calling:

```c
aqo_ExplainOnePlan_next = ExplainOnePlan_hook;  // may be NULL
ExplainOnePlan_hook     = print_into_explain;

// In the hook:
if (aqo_ExplainOnePlan_next)
    (*aqo_ExplainOnePlan_next)(plannedstmt, into, es, ...);
```

## Variant: Exclusive Hooks (Conflict Detection)

Some hooks should not be shared. Detect conflicts at install time:

```c
void aqo_cardinality_hooks_init(void)
{
    if (set_baserel_rows_estimate_hook ||
        get_parameterized_baserel_size_hook)
        elog(ERROR, "AQO estimation hooks shouldn't be intercepted");

    aqo_set_baserel_rows_estimate_next = set_baserel_rows_estimate_standard;
    set_baserel_rows_estimate_hook     = aqo_set_baserel_rows_estimate;
}
```

Detect post-install tampering at runtime:

```c
if (set_baserel_rows_estimate_hook != aqo_set_baserel_rows_estimate)
    elog(WARNING, "AQO is in the middle of the estimation chain");
```

## Complete Hook Catalog (Used in SAQO)

| Hook Variable | Phase | Purpose |
|---|---|---|
| `shmem_request_hook` | Startup | Request shared memory size |
| `shmem_startup_hook` | Startup | Initialize shared memory |
| `ExecutorStart_hook` | Executor | Set up instrumentation |
| `ExecutorRun_hook` | Executor | Timeout management |
| `ExecutorEnd_hook` | Executor | Learning after execution |
| `ExplainOnePlan_hook` | Explain | Custom EXPLAIN output |
| `ExplainOneNode_hook` | Explain | Per-node EXPLAIN output |
| `set_baserel_rows_estimate_hook` | Planner | Override base-rel cardinality |
| `get_parameterized_baserel_size_hook` | Planner | Override parameterized base-rel |
| `set_joinrel_size_estimates_hook` | Planner | Override join cardinality |
| `get_parameterized_joinrel_size_hook` | Planner | Override parameterized join |
| `parampathinfo_postinit_hook` | Planner | Attach prediction to ParamPathInfo |
| `estimate_num_groups_hook` | Planner | Override GROUP BY estimate |
| `create_plan_hook` | Planner | Attach custom data to plan nodes |
