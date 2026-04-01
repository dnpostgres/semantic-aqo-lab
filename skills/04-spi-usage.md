# Skill: SPI (Server Programming Interface)

SPI lets your C extension execute SQL queries against the database.

## Basic SPI Write (INSERT)

```c
void my_flush_to_table(void)
{
    int ret;

    ret = SPI_connect();
    if (ret != SPI_OK_CONNECT) {
        elog(WARNING, "SPI_connect failed: %d", ret);
        return;
    }
    PushActiveSnapshot(GetTransactionSnapshot());

    // Build SQL with StringInfo
    StringInfoData buf;
    initStringInfo(&buf);
    appendStringInfo(&buf,
        "INSERT INTO my_table (id, name) VALUES (%d, ",
        entry->id);

    // ALWAYS escape strings to prevent SQL injection
    char *escaped = quote_literal_cstr(entry->name);
    appendStringInfoString(&buf, escaped);
    pfree(escaped);

    appendStringInfoChar(&buf, ')');

    ret = SPI_execute(buf.data, false, 0);  // false = not read-only
    if (ret != SPI_OK_INSERT)
        elog(WARNING, "INSERT failed: %d", ret);

    PopActiveSnapshot();
    SPI_finish();
}
```

## SPI Read (SELECT) with Result Processing

```c
bool load_embeddings(void)
{
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());

    int ret = SPI_execute(
        "SELECT token, embedding FROM token_embeddings ORDER BY id",
        true, 0);   // true = read-only

    uint64 nrows = SPI_processed;

    for (uint64 i = 0; i < nrows; i++)
    {
        HeapTuple  tuple   = SPI_tuptable->vals[i];
        TupleDesc  tupdesc = SPI_tuptable->tupdesc;
        bool       isnull;

        // Get text column:
        Datum val = SPI_getbinval(tuple, tupdesc, 1, &isnull);
        char *text = TextDatumGetCString(val);

        // Get array column:
        val = SPI_getbinval(tuple, tupdesc, 2, &isnull);
        ArrayType *arr = DatumGetArrayTypeP(val);
        int ndim = ArrayGetNItems(ARR_NDIM(arr), ARR_DIMS(arr));
        float *src = (float *) ARR_DATA_PTR(arr);
        memcpy(dest, src, ndim * sizeof(float));
    }

    PopActiveSnapshot();
    SPI_finish();
    return true;
}
```

## SPI Re-Entrancy Guard

When SPI runs from a planner hook, the SPI query itself triggers hooks again. Protect against infinite recursion:

```c
// Global flag
bool my_internal_spi_active = false;

// In your hook function — short-circuit if we triggered it:
if (my_internal_spi_active)
    return default_behavior();

// Before SPI:
my_internal_spi_active = true;
QueryContextData saved_ctx;
memcpy(&saved_ctx, &query_context, sizeof(QueryContextData));

// ... SPI calls ...

// After SPI:
my_internal_spi_active = false;
memcpy(&query_context, &saved_ctx, sizeof(QueryContextData));
```

## SPI with PG_TRY/PG_CATCH (Graceful Failure)

Never let SPI failures crash the main query:

```c
PG_TRY();
{
    SPI_connect();
    PushActiveSnapshot(GetTransactionSnapshot());
    // ... work ...
    PopActiveSnapshot();
    SPI_finish();
}
PG_CATCH();
{
    EmitErrorReport();
    FlushErrorState();
    PG_TRY();
    {
        PopActiveSnapshot();
        SPI_finish();
    }
    PG_CATCH();
    {
        FlushErrorState();
    }
    PG_END_TRY();
}
PG_END_TRY();
```

## Check Table Existence Without SPI

Before calling SPI, verify the table exists to avoid transaction corruption:

```c
Oid relid = RangeVarGetRelid(
    makeRangeVar(NULL, "my_table", -1),
    NoLock,
    true);       // true = missing_ok (don't ERROR)

if (!OidIsValid(relid))
    return false;  // table doesn't exist yet
```
