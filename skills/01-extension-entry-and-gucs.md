# Skill: Extension Entry Point & GUC Registration

## `_PG_init` — The Extension Bootstrap

Every PG extension **must** declare the magic block and export `_PG_init`:

```c
#include "postgres.h"
PG_MODULE_MAGIC;

void _PG_init(void);
```

### Guard Against Non-Preload

Extensions requiring shared memory **must** be loaded via `shared_preload_libraries`:

```c
void _PG_init(void)
{
    if (!process_shared_preload_libraries_in_progress)
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("My extension could be loaded only on startup."),
                 errdetail("Add 'myext' into the shared_preload_libraries list.")));
}
```

### Canonical Init Order

```c
void _PG_init(void)
{
    // 1. Guard check (shared_preload_libraries)
    // 2. EnableQueryId()  — opt into query_id if needed
    // 3. GUC registration (DefineCustomXxxVariable)
    // 4. Shared memory hooks (shmem_request + shmem_startup)
    // 5. Planner / Executor hooks
    // 6. Memory contexts
    // 7. Resource release callbacks
    // 8. Custom node registration
    // 9. MarkGUCPrefixReserved("myext")
}
```

### Reserve GUC Prefix

Always call at end of `_PG_init` to prevent namespace collisions:

```c
MarkGUCPrefixReserved("aqo");
```

---

## GUC Registration

### Enum GUC

```c
static const struct config_enum_entry format_options[] = {
    {"intelligent", AQO_MODE_INTELLIGENT, false},
    {"forced",      AQO_MODE_FORCED,      false},
    {"controlled",  AQO_MODE_CONTROLLED,  false},
    {NULL, 0, false}   // <-- sentinel REQUIRED
};

DefineCustomEnumVariable("aqo.mode",
    "Mode of aqo usage.",         // short desc
    NULL,                         // long desc (nullable)
    &aqo_mode,                    // pointer to C variable
    AQO_MODE_CONTROLLED,          // default
    format_options,               // enum table
    PGC_USERSET,                  // context (who can SET)
    0,                            // flags
    NULL, NULL, NULL);            // check, assign, show hooks
```

### Bool GUC

```c
DefineCustomBoolVariable("aqo.show_hash",
    "Show query and node hash on explain.",
    NULL,
    &aqo_show_hash,
    false,             // default
    PGC_USERSET,
    0,
    NULL, NULL, NULL);
```

### Int GUC with Bounds and Units

```c
DefineCustomIntVariable("aqo.dsm_size_max",
    "Maximum size of dynamic shared memory.",
    NULL,
    &dsm_size_max,
    100,              // default
    0, INT_MAX,       // min, max
    PGC_POSTMASTER,   // can only be set at startup
    GUC_UNIT_MB,      // automatic MB unit handling
    NULL, NULL, NULL);
```

### Context Levels

| Level | Who Can Set | When |
|-------|-------------|------|
| `PGC_POSTMASTER` | postgresql.conf only | Before startup (shared memory sizes) |
| `PGC_SIGHUP` | postgresql.conf | Reload via SIGHUP |
| `PGC_SUSET` | Superuser only | Runtime `SET` |
| `PGC_USERSET` | Any user | Runtime `SET` |
