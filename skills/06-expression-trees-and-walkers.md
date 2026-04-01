# Skill: Expression Tree Walking

PG represents query clauses as expression trees (`Node *`). Extensions often need to walk or rewrite these trees.

## Tree Mutator (Rewriting Nodes)

Use `expression_tree_mutator` to replace specific node types:

```c
static Node *
subplan_hunter(Node *node, void *context)
{
    if (node == NULL)
        return NULL;         // continue recursion

    if (IsA(node, SubPlan))
        return (Node *) create_my_replacement_node();

    // Recurse into children:
    return expression_tree_mutator(node, subplan_hunter, context);
}

// Usage:
rinfo->clause = (Expr *) expression_tree_mutator(
    (Node *) rinfo->clause, subplan_hunter, (void *) root);
```

## Plan State Tree Walker (Execution Trees)

Use `planstate_tree_walker` for post-execution inspection:

```c
static bool
count_joins(PlanState *p, void *context)
{
    int *njoins = (int *) context;

    // Process children first:
    planstate_tree_walker(p, count_joins, context);

    // Then process this node:
    if (nodeTag(p->plan) == T_NestLoop ||
        nodeTag(p->plan) == T_HashJoin ||
        nodeTag(p->plan) == T_MergeJoin)
        (*njoins)++;

    return false;  // false = continue walking
}
```

## Path Tree Recursion (Planner Paths)

Walk path trees via switch on `path->type`:

```c
static List *
get_path_clauses(Path *path, PlannerInfo *root)
{
    switch (path->type)
    {
        case T_NestPath:
        case T_MergePath:
        case T_HashPath:
        {
            JoinPath *jp = (JoinPath *) path;
            List *cur    = jp->joinrestrictinfo;
            List *outer  = get_path_clauses(jp->outerjoinpath, root);
            List *inner  = get_path_clauses(jp->innerjoinpath, root);
            return list_concat(cur, list_concat(outer, inner));
        }

        case T_SortPath:
            return get_path_clauses(((SortPath *)path)->subpath, root);

        // ... handle 20+ path types ...

        default:
            // Leaf: base relation restrictions
            return list_copy(path->parent->baserestrictinfo);
    }
}
```

## Safe Custom Expression Deparser

When `deparse_expression()` can fail on internal node types, build a custom walker:

```c
static void
safe_deparse(Node *node, StringInfo buf)
{
    if (node == NULL) return;

    switch (nodeTag(node))
    {
        case T_Var:
        {
            char *attname = get_attname(var->varno, var->varattno, false);
            appendStringInfoString(buf, attname);
            break;
        }
        case T_OpExpr:
        {
            char *opname = get_opname(((OpExpr *)node)->opno);
            safe_deparse(linitial(((OpExpr *)node)->args), buf);
            appendStringInfo(buf, " %s ", opname);
            safe_deparse(lsecond(((OpExpr *)node)->args), buf);
            break;
        }
        case T_Const:
            appendStringInfoString(buf, "<CONST>");  // mask literal
            break;
        default:
            appendStringInfoString(buf, "<EXPR>");   // safe fallback
            break;
    }
}
```

## Useful Node Inspection Macros

```c
IsA(node, SubPlan)           // type check
nodeTag(node)                // get NodeTag enum value
castNode(OpExpr, node)       // cast with Assert in debug builds

// List iteration:
ListCell *lc;
foreach(lc, clause_list)
{
    RestrictInfo *rinfo = lfirst_node(RestrictInfo, lc);
    // ...
}

// Bitmap set iteration (relids):
int index = -1;
while ((index = bms_next_member(relids, index)) >= 0)
{
    RangeTblEntry *rte = planner_rt_fetch(index, root);
    // ...
}
```

## Catalog Lookups (Resolve Names)

```c
// Get column name:
char *attname = get_attname(relid, attnum, false);

// Get operator name:
char *opname = get_opname(opno);

// Get function name:
char *funcname = get_func_name(funcid);

// Get relation name (with proper cache release):
HeapTuple htup = SearchSysCache1(RELOID, ObjectIdGetDatum(relid));
Form_pg_class classForm = (Form_pg_class) GETSTRUCT(htup);
char *relname = pstrdup(NameStr(classForm->relname));  // copy BEFORE release!
ReleaseSysCache(htup);
```
