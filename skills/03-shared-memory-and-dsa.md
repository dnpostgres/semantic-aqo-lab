# Skill: Shared Memory & DSA (Dynamic Shared Area)

## Two-Hook Architecture (PG15+)

PG15 split shared memory into **request** (calculate size) and **startup** (initialize):

```c
static shmem_startup_hook_type  prev_startup = NULL;
static shmem_request_hook_type  prev_request = NULL;

void my_shmem_init(void)
{
    prev_startup = shmem_startup_hook;
    shmem_startup_hook = my_shmem_startup;
    prev_request = shmem_request_hook;
    shmem_request_hook = my_shmem_request;
}
```

## Request Hook — Calculate & Request Size

```c
static void my_shmem_request(void)
{
    Size size;

    if (prev_request) (*prev_request)();  // chain

    size = MAXALIGN(sizeof(MySharedState));
    size = add_size(size, hash_estimate_size(max_items, sizeof(MyEntry)));
    RequestAddinShmemSpace(size);
}
```

Key functions: `MAXALIGN()`, `add_size()`, `hash_estimate_size()`, `RequestAddinShmemSpace()`.

## Startup Hook — Initialize Shared Memory

```c
static void my_shmem_startup(void)
{
    bool    found;
    HASHCTL info;

    if (prev_startup) (*prev_startup)();  // chain

    // 1. Acquire global init lock
    LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

    // 2. Get (or create) the shared state struct
    my_state = ShmemInitStruct("MyExt", sizeof(MySharedState), &found);
    if (!found)
    {
        LWLockInitialize(&my_state->lock, LWLockNewTrancheId());
        // ... more initialization ...
    }

    // 3. Create shared hash tables
    info.keysize   = sizeof(uint64);
    info.entrysize = sizeof(MyEntry);
    my_htab = ShmemInitHash("MyExt HTAB",
                            max_items, max_items,
                            &info, HASH_ELEM | HASH_BLOBS);

    // 4. Release lock, register tranche names
    LWLockRelease(AddinShmemInitLock);
    LWLockRegisterTranche(my_state->lock.tranche, "MyExt");

    // 5. Load persisted data + register shutdown callback
    if (!IsUnderPostmaster && !found)
    {
        before_shmem_exit(on_shutdown, (Datum) 0);
        load_persisted_data();
    }
}
```

## Shared State Struct Pattern

```c
typedef struct MySharedState
{
    LWLock  lock;           // general mutex
    LWLock  data_lock;      // per-table lock
    bool    data_changed;   // dirty flag for flush-on-shutdown
    dsa_handle data_dsa_handler;
} MySharedState;
```

## Shared Hash Table CRUD

```c
// INSERT or FIND
LWLockAcquire(&my_state->lock, LW_EXCLUSIVE);
entry = hash_search(my_htab, &key, HASH_ENTER, &found);
if (!found) { /* init new entry */ }
LWLockRelease(&my_state->lock);

// FIND (read-only)
LWLockAcquire(&my_state->lock, LW_SHARED);
entry = hash_search(my_htab, &key, HASH_FIND, &found);
LWLockRelease(&my_state->lock);

// REMOVE
hash_search(my_htab, &key, HASH_REMOVE, NULL);

// ITERATE
HASH_SEQ_STATUS seq;
hash_seq_init(&seq, my_htab);
while ((entry = hash_seq_search(&seq)) != NULL) { ... }
```

**Critical rule**: Hash entry key **must** be the first field in the struct:

```c
typedef struct MyEntry
{
    uint64  key;      // <-- MUST be first
    int     data;
    double  value;
} MyEntry;
```

## DSA for Variable-Length Shared Data

For strings, matrices, or anything that doesn't fit in a fixed-size entry:

```c
typedef struct TextEntry
{
    uint64      key;
    dsa_pointer text_dp;   // pointer into DSA area
} TextEntry;

// Allocate:
entry->text_dp = dsa_allocate_extended(my_dsa, len,
                                       DSA_ALLOC_NO_OOM | DSA_ALLOC_ZERO);
if (!DsaPointerIsValid(entry->text_dp))
    { /* handle OOM */ }

// Access:
char *str = (char *) dsa_get_address(my_dsa, entry->text_dp);
```

## File-Based Persistence (Crash-Safe)

Write to `.tmp`, then atomic rename:

```c
char *tmpfile = psprintf("%s.tmp", filename);
FILE *file = AllocateFile(tmpfile, PG_BINARY_W);

fwrite(&header, sizeof(uint32), 1, file);
fwrite(&nrecs, sizeof(long), 1, file);
// ... write records ...

FreeFile(file);
durable_rename(tmpfile, filename, PANIC);  // atomic rename
```

## Shutdown Callback

```c
static void on_shutdown(int code, Datum arg)
{
    Assert(!IsUnderPostmaster);
    flush_data_to_disk();
}

// Registered in shmem_startup:
before_shmem_exit(on_shutdown, (Datum) 0);
```
