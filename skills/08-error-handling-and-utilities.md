# Skill: Error Handling & Common Utilities

## Error Reporting with `ereport`

```c
// Fatal error (aborts transaction)
ereport(ERROR,
        (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
         errmsg("My extension requires shared_preload_libraries."),
         errdetail("Add 'myext' into shared_preload_libraries."),
         errhint("Edit postgresql.conf and restart.")));

// Warning (continues execution)
ereport(WARNING,
        (errmsg("[MyExt] Storage is full, skipping insert.")));

// Log message (goes to server log only)
ereport(LOG,
        (errmsg("[MyExt] Loaded %d embeddings from table.", count)));

// Simple shortcuts:
elog(ERROR, "unexpected state: %d", state);
elog(WARNING, "fallback to default estimate");
elog(LOG, "extension initialized");
```

## PG_TRY / PG_CATCH / PG_FINALLY

Non-fatal error recovery — never let extension errors crash the main query:

```c
PG_TRY();
{
    // risky operation ...
    result = do_something();
}
PG_CATCH();
{
    EmitErrorReport();      // log the error
    FlushErrorState();      // clear error state, continue execution
    result = fallback_value;
}
PG_END_TRY();

// With FINALLY (cleanup regardless of error):
PG_TRY();
{
    resource = acquire_resource();
    do_work(resource);
}
PG_FINALLY();
{
    release_resource(resource);  // always runs
}
PG_END_TRY();
```

## StringInfo (Dynamic String Building)

```c
StringInfoData buf;
initStringInfo(&buf);

appendStringInfo(&buf, "SELECT * FROM %s WHERE id = %d", table, id);
appendStringInfoString(&buf, " ORDER BY name");
appendStringInfoChar(&buf, ';');

// Use buf.data as C string
SPI_execute(buf.data, true, 0);

pfree(buf.data);
```

## List Operations (PG's `List` type)

```c
// Iteration:
ListCell *lc;
foreach(lc, my_list)
{
    MyStruct *item = (MyStruct *) lfirst(lc);
    // or: int val = lfirst_int(lc);
}

// Typed iteration:
RestrictInfo *rinfo = lfirst_node(RestrictInfo, lc);

// Parallel iteration of two lists:
forboth(l1, list_a, l2, list_b)
{
    Expr *expr = (Expr *) lfirst(l1);
    double sel = *((double *) lfirst(l2));
}

// Build:
List *result = NIL;
result = lappend(result, item);
result = list_concat(result, other_list);
```

## C Array ↔ PG ArrayType Conversion

```c
// C array → PG ArrayType
static ArrayType *
form_vector(double *vector, int nrows)
{
    Datum *elems = palloc(sizeof(*elems) * nrows);
    for (int i = 0; i < nrows; i++)
        elems[i] = Float8GetDatum(vector[i]);

    int dims[1] = {nrows};
    int lbs[1]  = {1};
    return construct_md_array(elems, NULL, 1, dims, lbs,
                              FLOAT8OID, 8, FLOAT8PASSBYVAL, 'd');
}

// PG ArrayType → C array
ArrayType *arr = DatumGetArrayTypeP(datum);
int n = ArrayGetNItems(ARR_NDIM(arr), ARR_DIMS(arr));
float *data = (float *) ARR_DATA_PTR(arr);
```

## Catalog Lookups

```c
// Get column name:
char *attname = get_attname(relid, attnum, false);

// Get operator name:
char *opname = get_opname(opno);

// System cache lookup (with proper release):
HeapTuple htup = SearchSysCache1(RELOID, ObjectIdGetDatum(relid));
if (!HeapTupleIsValid(htup))
    elog(ERROR, "cache lookup failed for reloid %u", relid);

Form_pg_class form = (Form_pg_class) GETSTRUCT(htup);
char *name = pstrdup(NameStr(form->relname));  // copy BEFORE release!
ReleaseSysCache(htup);
```

## SQL-Callable Functions (SRF Pattern)

```c
PG_FUNCTION_INFO_V1(my_function);

Datum
my_function(PG_FUNCTION_ARGS)
{
    ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    TupleDesc      tupDesc;
    Tuplestorestate *tupstore;

    MemoryContext per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    MemoryContext oldctx = MemoryContextSwitchTo(per_query_ctx);

    if (get_call_result_type(fcinfo, NULL, &tupDesc) != TYPEFUNC_COMPOSITE)
        elog(ERROR, "return type must be a row type");

    tupstore = tuplestore_begin_heap(true, false, work_mem);
    rsinfo->returnMode = SFRM_Materialize;
    rsinfo->setResult  = tupstore;
    rsinfo->setDesc    = tupDesc;
    MemoryContextSwitchTo(oldctx);

    // Fill tuples:
    Datum values[N]; bool nulls[N];
    memset(nulls, 0, sizeof(nulls));

    values[0] = Int64GetDatum(my_id);
    values[1] = CStringGetTextDatum(my_string);
    tuplestore_putvalues(tupstore, tupDesc, values, nulls);

    tuplestore_donestoring(tupstore);
    return (Datum) 0;
}
```

## EphemeralNamedRelation (Cross-Phase Data Passing)

Pass data from ExecutorStart to ExecutorEnd through `queryDesc->queryEnv`:

```c
// Store:
if (queryDesc->queryEnv == NULL)
    queryDesc->queryEnv = create_queryEnv();

EphemeralNamedRelation enr = palloc0(sizeof(EphemeralNamedRelationData));
enr->reldata = palloc0(sizeof(MyData));
memcpy(enr->reldata, &my_data, sizeof(MyData));
register_ENR(queryDesc->queryEnv, enr);

// Retrieve:
EphemeralNamedRelation enr = get_ENR(queryDesc->queryEnv, "MyPrivateData");
if (enr != NULL)
    memcpy(&my_data, enr->reldata, sizeof(MyData));
```
