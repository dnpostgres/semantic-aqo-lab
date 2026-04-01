# Skill: Memory Context Patterns

PostgreSQL uses hierarchical memory contexts instead of raw `malloc`/`free`. Understanding these is critical for extension development.

## Hierarchical Context Tree

```
TopMemoryContext                     (lives forever)
  └── MyExtTopMemCtx                 (long-lived, extension top)
       ├── MyCacheMemCtx             (transaction-scoped, reset on resource release)
       ├── MyPredictMemCtx           (planning-scoped, reset after each prediction)
       ├── MyLearnMemCtx             (learning-scoped, reset after ExecutorEnd)
       └── MyStorageMemCtx           (I/O-scoped, reset after each flush/load)
```

## Creating Contexts

```c
// In _PG_init:
MyExtTopMemCtx = AllocSetContextCreate(TopMemoryContext,
                                       "MyExtTopMemoryContext",
                                       ALLOCSET_DEFAULT_SIZES);

MyCacheMemCtx = AllocSetContextCreate(MyExtTopMemCtx,
                                      "MyCacheMemCtx",
                                      ALLOCSET_DEFAULT_SIZES);
```

## Switch-Work-Switch-Reset Pattern

The most common pattern — work in a temporary context, then bulk-free:

```c
MemoryContext old_ctx = MemoryContextSwitchTo(MyPredictMemCtx);

// ... do work that allocates memory (palloc, pstrdup, etc.) ...

MemoryContextSwitchTo(old_ctx);          // restore caller's context
MemoryContextReset(MyPredictMemCtx);     // bulk-free ALL allocations
```

## Cross-Phase Survival (Planning → Execution)

When data must survive from planning to execution (different memory contexts), allocate in `TopMemoryContext`:

```c
MemoryContext oldctx = MemoryContextSwitchTo(TopMemoryContext);
entry = (MyNode *) palloc0(sizeof(MyNode));
entry->text = pstrdup(some_string);     // copy the string too!
MemoryContextSwitchTo(oldctx);
```

## Resource Release Callback (Transaction Cleanup)

Reset caches at transaction boundary:

```c
static void
my_free_callback(ResourceReleasePhase phase,
                 bool isCommit, bool isTopLevel, void *arg)
{
    if (phase != RESOURCE_RELEASE_AFTER_LOCKS)
        return;
    if (isTopLevel)
    {
        MemoryContextReset(MyCacheMemCtx);
        my_cached_list = NIL;
    }
}

// Register in _PG_init:
RegisterResourceReleaseCallback(my_free_callback, NULL);
```

## Key Rules

1. **Always use `palloc`/`pfree`** instead of `malloc`/`free` — PG tracks allocations per context
2. **`pstrdup()` copies strings** into the current context — essential when the source may be freed
3. **`MemoryContextReset()`** frees everything in the context without destroying it — reuse the context
4. **`MemoryContextDelete()`** destroys the context and all children — use only for cleanup
5. **Never hold pointers across a `MemoryContextReset()`** — they become dangling
6. **Allocate in the right context** — planning data in planner context, execution data in executor context
