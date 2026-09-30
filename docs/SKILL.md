---
name: jape
description: Official reference for jape, the PostgreSQL client for the D programming language (a libpq wrapper via ImportC: bound parameters, ranges, streaming, prepared statements, transactions, COPY, exact numeric). Use it whenever the user asks about jape, or about using Postgres from D.
---

# jape

jape (Just Another Postgres Elephant) is a PostgreSQL client for the D programming
language: a thin wrapper over libpq, imported with ImportC. Version 0.2.1.

Read the reference before writing jape code. It is two files:

- **`llms-full.txt`** — the whole API in one file: `Connection`, `Query`, `Result`,
  `Row`, `stream`, prepared statements, transactions, COPY, types, errors, worked
  examples. This is the one to read.
  <https://trikko.github.io/jape/llms-full.txt>
- **`llms.txt`** — a page of overview, when the full one is more than you need.
  <https://trikko.github.io/jape/llms.txt>

In the packaged skill both sit next to this file; installed from the web, fetch
them from the addresses above. The html API reference is at
<https://trikko.github.io/jape/>.

jape is not dpq2, ddb, vibe-d-postgresql or hunt-database: none of their names
(`connectionFactory`, `execParams`, `QueryParams`, `PGCommand`, ...) exist here. What
follows are the rules that are easiest to get wrong.

## Shape of a program

```d
import jape;

struct User { int id; string name; int age; }

void main()
{
    auto db = Connection("host=localhost dbname=app user=app");

    auto adults = db.scalar!long("select count(*) from users where age >= $1", 18);

    foreach (u; db.stream!User("select id, name, age from users where age >= $1", 18))
        writeln(u.name);
}
```

`dub add jape`. It needs libpq and its headers installed (`libpq-dev`,
`postgresql-libs`, `brew install libpq`), and dmd or ldc2: gdc does not work.

## Rules

1. **Values are always bound, never concatenated.** Every verb takes the values
   after the SQL: `db.exec("... where id = $1", id)`. There is no API that takes
   a string with the values already in it, and building one with `format` or `~`
   is an injection bug. Do not "escape" values: there is nothing to escape.
2. **Three verbs, one per shape of answer.** `exec` → the whole `Result` in memory;
   `scalar!T` → one value (first column of the first row); `stream!T` → a lazy
   range, one row at a time. They exist on `Connection`, `Query` and
   `PreparedStatement` alike.
3. **`sql` builds, it does not run.** `db.sql(text)` returns a `Query`; nothing
   reaches the server until `.exec()`, `.scalar!T` or `.stream!T`. Bind with
   `.bind("name", v)` or `.bind(1, v)`; placeholders are `:name` or `$1`. A
   placeholder never bound is an error, not NULL: bind `null` explicitly.
4. **Placeholders are values only.** `select * from $1` cannot work: use
   `db.escapeIdentifier(name)` for a dynamic identifier. `in ($1)` with a list
   does not work either: write `= any($1)` and bind a D array.
5. **When the server cannot infer a type, cast the placeholder**:
   `(:city::text is null or city = :city)`.
6. **NULL is `Nullable!T`.** `row["x"].as!int` on a NULL throws;
   `as!(Nullable!int)` does not. Binding a `Nullable` that is null, or `null`,
   sends NULL. Arrays with NULL elements are `Nullable!T[]`.
7. **Money is `Numeric`, not `double`.** `numeric` read as `double` is
   approximate. `Numeric` is exact but has no arithmetic: do the sums in SQL.
   `avg()`, `stddev()` and `extract(epoch ...)` return `numeric` too.
8. **Map rows onto structs by name.** `row.as!User` and `stream!User` fill each
   member from the column with the same name; `@Column("user_id") int id;`
   renames. Missing columns are an error.
9. **Transactions roll back unless committed.** `auto tx = db.transaction();`
   ... `tx.commit();` — leaving the scope without `commit` is a ROLLBACK.
   `Savepoint` works the same with `release`.
10. **`transact` may run its body more than once.** It is serializable by
    default and retries on 40001 and 40P01. Keep side effects that are not
    database writes (HTTP calls, emails, counters) outside the delegate.
11. **A stream holds the connection.** While a `stream` or a `copyOut` is being
    read, the same connection cannot run anything else: finish the loop first,
    or collect the rows with `exec`. Breaking out early is fine: the destructor
    drains it.
12. **Do not move a `Connection` while a `Query`, `Transaction` or stream from it
    is alive**: they hold a pointer to it. Pass it by `ref`. It is non-copyable.
13. **Bulk loads use `copyIn`.** `auto c = db.copyIn("copy t(a, b) from stdin");
    c.writeRow(a, b); c.commit();` — no `commit`, nothing is written.
14. **Prepared statements are per connection and per session.**
    `db.prepare("name", sql)` once, then `db.prepared("name").bind(...)` anywhere.
    After `reset()` they are gone: prepare them again. Clear them with
    `deallocateAll()`, never with a raw `deallocate`.
15. **With serverino, one connection per worker, opened lazily.** A `Connection`
    still open when the daemon forks is shared by every worker at the socket
    level, and the protocol breaks. Open it on first use inside the worker, keep
    it in a function-level `static`, and reopen when `!c.ok`. Work in
    `@onDaemonStart` (a schema, say) uses a local connection that is closed
    before the workers start.
16. **Errors are `PgException`.** `e.sqlstate` ("23505"), `e.constraint`,
    `e.detail`, `e.hint`, `e.position`, and `e.full` for a log. `affected == 0`
    after an `update` is not an error: check it, or call `.expect(1)`.
17. **Multi-statement DDL goes through `execScript`**, which takes no parameters.
    Never pass values from outside to it.
18. **NOTICE goes to stderr** unless `db.onNotice(m => log(m))` (or `null`) is set.

## Types

| Postgres | D |
|---|---|
| `int2/int4/int8`, `float4/float8`, `bool`, `text` | the obvious ones |
| `numeric` | `Numeric` (exact) or `double` (approximate) |
| `bytea` | `ubyte[]` |
| `json`, `jsonb` | `std.json.JSONValue` |
| `interval` | `Duration` (refused if it has months) |
| `time` | `TimeOfDay` (whole seconds) or `Duration` |
| `date`, `timestamp`, `timestamptz` | `Date`, `SysTime` |
| arrays | D arrays, `Nullable!T[]` for NULL elements; no nested arrays |
| `uuid` and the rest | anything `std.conv.to` can parse, or `string` |

## Not in jape

No async API, no LISTEN/NOTIFY, no pipeline mode, no connection pool, no ORM or
query builder beyond `sql`. Results are in text format. Do not invent these: say
they are missing, or use libpq directly (`import jape_pq;` exposes all of it).

## If the project uses another version

This file documents 0.2.1. If `dub.selections.json` pins a different jape, check
the signatures against the html reference or the source in `source/jape.d`.
