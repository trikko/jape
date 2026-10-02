<img align="left" alt="jape logo" width="100" height="100" src="https://trikko.github.io/jape/logo.svg">

# jape

[![CI](https://github.com/trikko/jape/actions/workflows/ci.yml/badge.svg)](https://github.com/trikko/jape/actions/workflows/ci.yml)
[![DUB](https://img.shields.io/dub/v/jape)](https://code.dlang.org/packages/jape)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**J**ust **A**nother **P**ostgres **E**lephant — a thin, idiomatic D wrapper over
**libpq**, imported with **ImportC**. There are no hand-written bindings: the
library includes `libpq-fe.h` directly.

**Documentation:** [API reference](https://trikko.github.io/jape/) ·
[for AI agents](#using-jape-with-an-ai-agent) · `dub add jape`

## Running a statement

Three verbs, one per shape of answer. Each takes the SQL and its values, and the
values are sent separately from the SQL text, as bound parameters: they can
never be mistaken for SQL, so injection is not possible.

```d
auto db = Connection("host=localhost dbname=app user=app");

// exec — the whole result, in memory, a RandomAccessRange of rows
auto rows = db.exec("select id, name, age from users where age > $1", 18);
writeln(rows.length, " rows, the first is ", rows[0]["name"].as!string);

// scalar — one value, the first column of the first row
auto total = db.scalar!long("select count(*) from users where age > $1", 18);

// stream — one row at a time, constant memory whatever the size of the result
foreach (u; db.stream!User("select id, name, age from users where age > $1", 18))
    process(u);
```

## Binding the values yourself: `sql`

The three above want every value on the spot. When the values come from
different places — an optional filter, a branch, a function called further down
— `sql` names the statement without running it and hands you a `Query` to fill
in. The same three verbs then finish the job:

```d
auto q = db.sql("select id, name, age from users
                 where age > :age and (:city::text is null or city = :city)");

q.bind("age", 18);
if (filterByCity) q.bind("city", city);
else              q.bind("city", null);

auto rows = q.exec();                    // …or
foreach (u; q.stream!User) { }           // …one at a time

// scalar plugs in exactly the same way
auto total = db.sql("select count(*) from users where age > :age")
               .bind("age", 18).scalar!long;
```

Placeholders are `:name` or `$1`, values are bound by either, and a parameter
you declared but never bound is an error rather than a silent NULL. Nothing
reaches the server until one of the three verbs is called — `db.sql("delete
from users")` on its own does nothing at all.

The shortcut and the builder are the same machine: `db.exec(text, a, b)` is
`db.sql(text).bind(1, a).bind(2, b).exec()`.

## `sql` or `prepare`

Both hand you a `Query`; everything downstream is identical. What differs is
who parses the statement, and how often.

```
db.sql("select … :age")                  ─┐
                                          ├─→ Query ─→ .bind(…) ─→ .exec()
db.prepare("by_age", "select … :age")     │                        .scalar!T
        └─→ PreparedStatement ─→ .bind(…) ─┘                        .stream!T
```

```d
// one-shot: the server parses, plans and runs it, every single time
db.sql("select count(*) from users where age >= :age")
  .bind("age", 30).scalar!long;

// reused: the server parses and plans once, then only the values travel
auto byAge = db.prepare("by_age", "select count(*) from users where age >= :age");
foreach (age; [18, 30, 65])
    writeln(byAge.bind("age", age).scalar!long);
```

Same placeholder syntax, same `bind`, same verbs. `prepare` asks for a name
because the plan is stored under it, server-side, and it costs a round-trip
right away even if you never run the statement. So reach for it when the same
statement runs many times over the life of one connection — which, in a
serverino worker, is most of them — and use `sql` for everything else.

They are two entrances to the same pipeline, not layers, so there is nothing to
nest: pick one.

The name is not only for the server. A statement prepared earlier comes back
from it, so nothing has to carry a `PreparedStatement` around — prepare
everything once when the connection opens, and ask for what you need where you
need it:

```d
db.prepare("by_age", "select … where age >= :age");   // at connection setup
…
db.prepared("by_age").bind("age", 30).stream!User;    // anywhere afterwards

db.isPrepared("by_age");    // true
db.preparedNames;           // ["by_age", …]
```

Only names this connection prepared are known, because `:name` placeholders are
translated on this side and the server only ever sees `$1 … $n`: it could give
back the number of parameters but never their names. Preparing the same name
with the same text again is a no-op, so a "prepare everything" routine is safe
to call twice; the same name with different text is an error.

A prepared statement lives in the *session*, so it does not survive a
`PQreset` — which is why `reset` forgets them here too, and why the worker in
[one connection per process](#one-connection-per-process) prepares again after
reconnecting. To clear them deliberately use `deallocateAll`, rather than
sending `deallocate` yourself, which would leave the server and this side out of
step.

## Money, and other exact decimals

`double` cannot hold a decimal fraction. Read `0.1` out of a `numeric` column
into one and it becomes `0.10000000000000001`; add `0.01` a thousand times and
you land on `9.99999999999983` instead of `10`. On a column of money that is a
bug you do not see until you do.

Both readings are available, and the type you ask for is the choice you are
making:

```d
db.scalar!double("select amount from invoices");   // 1234567.8899999999
db.scalar!Numeric("select amount from invoices");  // 1234567.89, exactly
```

`Numeric` carries the value, compares it and hands it back untouched. It has no
arithmetic on purpose: the database it came from already has exact operators and
knows how to round, so `sum`, `*` and `/` belong in the statement. `toDouble` is
there for when the approximation is what you want.

Worth knowing about where `numeric` turns up: it is not only money columns.
`avg()` over integers is `numeric`, and so are `stddev()`, `extract(epoch …)`
and anything multiplied by a decimal literal. `sum()` over integers and
`count(*)` are `bigint`.

Comparison is by value and formatting is by fidelity, the way SQL has it:
`Numeric("1.10") == Numeric("1.1")` is true, while their `toString` differ. NaN
follows Postgres rather than IEEE — it equals itself and sorts above everything,
`Infinity` included.

## Bulk loading

`COPY ... FROM STDIN` is not a statement that returns a result: the server
answers it by turning the connection into a data channel, which is why it has
its own type instead of coming out of `exec`. (A `COPY` from a *server-side
file* is an ordinary statement — `exec` runs it, and `copyIn` tells you so if
you pass it one by mistake.)

```d
{
    auto copy = db.copyIn("copy notes(title, body) from stdin");
    foreach (n; notes)
        copy.writeRow(n.title, n.body);     // tabs, newlines and NULL handled
    writeln(copy.commit(), " rows");
}   // without commit() the destructor fails the copy: nothing is written
```

Rollback-by-default, as with `Transaction`: a load that dies halfway leaves no
half-dataset behind. Measured on 100k rows of three columns:

| | |
|---|---|
| one INSERT per row, autocommit | 130,941 ms |
| one INSERT per row, single transaction | 3,133 ms |
| multi-row INSERT, batches of 1000 | 489 ms |
| `COPY FROM STDIN` | 84 ms |

Out is a lazy range, drained by its destructor like `stream`, so breaking out
early leaves the connection usable:

```d
foreach (line; db.copyOut("copy notes to stdout with (format csv)"))
    process(line);      // a view over libpq's buffer: copy it to keep it
```

## Types

Beyond the obvious ones, these map to something D already has:

| Postgres | D |
|---|---|
| `numeric` | `Numeric` (or `double`, see above) |
| `bytea` | `ubyte[]` |
| `json`, `jsonb` | `std.json.JSONValue`, parsed — not a string holding the text |
| `interval` | `Duration` |
| `time` | `TimeOfDay`, or `Duration` since midnight |
| `date`, `timestamp`, `timestamptz` | `Date`, `SysTime` |
| any `T[]` | the matching D array, `Nullable!T[]` when elements can be null |
| `uuid` | `std.uuid.UUID` works through `to`, as does anything else `to!T` can parse |

Two of them refuse rather than approximate, for the same reason `Numeric` exists:

* **`interval` with months.** `1 mon` has no `Duration`: a month is 28 to 31
  days depending on which one. Read it as a string, or have the server resolve
  it against a date.
* **`time` with a fractional second.** `TimeOfDay` has no room for it, so
  `14:30:00.5` asks you for a `Duration` instead. A whole second is fine.

## Transactions

`Transaction` rolls back unless you commit, and takes an isolation level:

```d
{
    auto tx = db.transaction(Isolation.serializable, Access.readOnly);
    …
}   // no commit() → ROLLBACK
```

Under `serializable` the server is allowed to abort a transaction it cannot
serialise (SQLSTATE `40001`), and a deadlock (`40P01`) ends the same way. Both
mean *nothing happened, try again* — so retrying is not an optimisation, it is
the other half of the contract. `transact` is that half:

```d
auto total = db.transact({
    auto seen = db.scalar!long("select count(*) from dots where colour = 'white'");
    db.exec("insert into dots(colour) values('black')");
    return seen;
});                                   // serializable by default
```

It commits when the body returns, rolls back when it throws, and runs the body
again — with a short uneven backoff, so two deadlocked transactions do not
deadlock again in lockstep — when the failure is one of those two. Anything else
is rethrown untouched: a unique violation is not going to go away on a second
try. The body may run more than once, so anything in it that is not a database
write should live outside.

## When it goes wrong

The server sends far more than a message, and all of it survives the throw:

```d
try db.exec("insert into users(email) values($1)", email);
catch (PgException e)
{
    e.sqlstate;     // "23505"
    e.constraint;   // "users_email_key"  ← which rule was broken
    e.table;        // "users"
    e.detail;       // "Key (email)=(ada@example.com) already exists."
    e.hint;         // what the server suggests, when it has an opinion
    e.position;     // 1-based character in the statement, for syntax errors
    e.context;      // the call stack, when the error came from a trigger
    e.full;         // all of the above on one line, for a log
}
```

`constraint` is what turns "duplicate key value violates unique constraint" into
a sentence a user can act on, and `position` is the character the parser choked
on. Both are empty when the server did not send them — most errors fill in only
a few fields.

NOTICE and WARNING are a separate channel, and by default they are libpq's
problem, which means stderr: `create table if not exists` on a table that exists
is enough to produce one, so a server that never says otherwise ends up with
someone else's lines in its log.

```d
db.onNotice(m => info(m));   // into your logger
db.onNotice(null);           // or dropped
```

The handler runs inside the call that produced the message, and anything it
throws is swallowed — a notice can never fail the query that caused it.

## What is in the box

| | |
|---|---|
| `Connection` | owns the `PGconn`, non-copyable, `~this` → `PQfinish` |
| `Query` | builder: `:name` or `$n` placeholders, incremental binding, arrays, unbound-parameter check |
| `Result` / `Rows` | owner plus view: a `RandomAccessRange` of `Row` |
| `Row` / `Field` | access by index or name, `as!T`, compile-time mapping onto a struct (`@Column` to rename) |
| `RowStream` | lazy `InputRange` over `PQsetSingleRowMode`, drained by its destructor |
| `Transaction` | RAII: no `commit()` means `ROLLBACK`. Isolation levels, `savepoint()` |
| `transact` | runs a body in a transaction and runs it again when the server says to |
| `PreparedStatement` | `PQprepare` + `PQexecPrepared`, same binding API |
| `Numeric` | an exact decimal, because `double` cannot hold one |
| `CopyIn` / `CopyOut` | bulk load and unload, RAII: no `commit` means nothing is written |
| `PgException` | SQLSTATE, constraint, detail, hint, position… everything the server sent |

## Using jape with an AI agent

jape is new, so it is not in the training data of the models: a model left to
guess writes code for another Postgres library, or invents one. Give it the
reference instead:

* [SKILL.md](https://trikko.github.io/jape/SKILL.md): the rules that are easiest
  to get wrong, as a skill. [AGENTS.md](https://trikko.github.io/jape/AGENTS.md)
  is the same text without the front matter, for tools that want a rules file
  (`AGENTS.md`, `CLAUDE.md`, `.cursorrules`, ...).
* [llms-full.txt](https://trikko.github.io/jape/llms-full.txt): the whole API;
  [llms.txt](https://trikko.github.io/jape/llms.txt): a short overview.

The easiest way: ask your agent to do it.

> Install the skill at https://trikko.github.io/jape/SKILL.md. It is the
> reference for jape, the D PostgreSQL client I am using.

Or by hand: a skill is a folder with `SKILL.md` in it (`llms-full.txt` next to
it saves a download).

| Tool | For all projects | For one project |
|---|---|---|
| Claude Code | `~/.claude/skills/jape/` | `.claude/skills/jape/` |
| Antigravity (IDE, 2.0) | `~/.gemini/config/skills/jape/` | `.agents/skills/jape/` |
| Antigravity CLI | `~/.gemini/antigravity-cli/skills/jape/` | `.agents/skills/jape/` |
| Gemini CLI | `~/.gemini/skills/jape/` | `.gemini/skills/jape/` |
| Codex | `~/.agents/skills/jape/` | `.agents/skills/jape/` |

For example, for Claude Code:

```sh
mkdir -p ~/.claude/skills/jape && cd ~/.claude/skills/jape
curl -fsSLO https://trikko.github.io/jape/SKILL.md
curl -fsSLO https://trikko.github.io/jape/llms-full.txt
```

The skill is loaded when the task is about jape or Postgres in D; in Claude Code
you can also call it with `/jape`.

## Requirements

libpq and its development headers, installed system-wide:

```bash
pacman -S postgresql-libs        # Arch
apt install libpq-dev            # Debian/Ubuntu
brew install libpq               # macOS
```

The build needs `libpq-fe.h` on the preprocessor's include path and `libpq.so`
on the linker's. `dub.json` already looks where the common distributions put
them — `/usr/include/postgresql` on Debian and Ubuntu, Homebrew's `libpq`
prefix on macOS, the default paths on Arch and Fedora — so a plain
`dub add jape` is enough there. Anywhere else, ask
`pg_config --includedir --libdir` and pass the answer through `DFLAGS`:

```bash
DFLAGS="-P=-I$(pg_config --includedir) -L-L$(pg_config --libdir)" dub build
```

Supported compilers are **dmd** and **ldc2**, which both compile the ImportC
file. gdc does not work: dub cannot hand it a C source alongside the D ones.

## Building

```bash
dub build     # the library
dub test      # unit tests; those needing a server are skipped
JAPE_TEST_CONNINFO="host=127.0.0.1 port=55432 user=postgres password=secret" dub test
```

The html reference in `docs/`, served by GitHub Pages, is generated from the
comments in the source with `tools/docs.sh` (ddox with the scod skin).
`docs/AGENTS.md`, `docs/llms.txt` and `docs/llms-full.txt` are written by hand;
`docs/SKILL.md` is generated from `AGENTS.md`.

## A database to try it against

Everything below wants a Postgres. A throwaway one in a container will do:

```bash
docker run -d --name pqtest -e POSTGRES_PASSWORD=secret \
    -p 55432:5432 docker.io/library/postgres:16-alpine
```

That is the connection the examples default to. Point them somewhere else with
the `JAPE_CONNINFO` environment variable — but at something disposable, since
they create and drop their own tables:

```bash
JAPE_CONNINFO="host=localhost dbname=scratch user=me" dub run
```

## Examples

Each one is its own dub package, so it also shows what depending on jape looks
like from the outside.

| | |
|---|---|
| [`example/01_helloworld`](example/01_helloworld) | Twelve lines: connect, `scalar`, `stream`. Start here. |
| [`example/02_web_crud`](example/02_web_crud) | A notes app on [serverino](https://github.com/trikko/serverino): add, search, delete. |

```bash
cd example/01_helloworld && dub run
cd example/02_web_crud   && dub run     # then open http://127.0.0.1:8080
```

The second one is the showcase. Its interface lives in `public/` and is served
as static files, so `source/app.d` is almost entirely database code: a JSON
endpoint, a connection, and the SQL. What it demonstrates:

* **One connection per worker.** Serverino workers are separate processes. The
  schema is created in the daemon through a connection that is closed before any
  worker is forked; each worker then opens its own, lazily, on first use, and
  re-prepares its statements if the database restarts under it.
* **Filtering that happens in the database.** A case-insensitive search and a
  time window, both optional, in a single statement: an empty search becomes
  `'%%'` and matches everything, a null interval makes its own condition true.
  That is what the `sql` builder is for — no branching to assemble the query,
  and no second statement.
* **Both ways of making a statement.** Prepared for the fixed ones, retrieved by
  name in the endpoints; the builder for the listing, whose filters come and go.
* **A struct straight out of a row.** `row.as!Note` fills the members by column
  name at compile time; `@Column("…")` covers the cases where the two names
  cannot match.

There is also `test/integration`, a single program that exercises every part of
the library against a real database and asserts the results. It is a test
wearing an example's clothes; run it the same way.

## Cleaning up

```bash
docker rm -f pqtest     # the container and everything in it
```

The data lives in the container, so removing it removes the database too. To
keep the container and drop only what the examples made:

```bash
docker exec -it pqtest psql -U postgres -c 'drop table if exists notes, users'
```

## How ImportC is used here

`source/jape_pq.c` is a single line:

```c
#include <libpq-fe.h>
```

`dub.json` hands it to dmd alongside the D sources through `sourceFiles`. Dmd
preprocesses and compiles that file as a D module named after it, `jape_pq` —
prefixed, because module names are global and a bare `pq` could clash with
another package. `import jape_pq;` gives access to every libpq function, struct
and enum — including unqualified enum members (`CONNECTION_OK`, `PGRES_TUPLES_OK`) and
simple object-like macros turned into manifest constants (`PG_DIAG_SQLSTATE`).

## Design notes

### Owner and view are different types

A D range has to be copyable (`map` and `filter` take it by value); a handle
owning a C resource wants to be freed exactly once. The two are reconciled by
reference counting (`std.typecons.RefCounted`): `Result`, the `Rows` view over
it, and every `Row` and `Field` taken from them share one count on the
`PGresult`, which is cleared when the last of them goes. Nothing handed out can
outlive the memory it points at, so views over temporaries are safe:

```d
foreach (row; db.exec("select …")) { }                    // safe, straight iteration
auto names = db.exec("select …").rows.map!(…).array;      // safe, the view keeps the memory alive
Row first = db.exec("select …").front;                    // safe, the Row keeps it alive too
```

A `Row` kept in GC memory (an array, a closure) holds its whole result until the
GC collects it, and the GC cannot see how big that is, since libpq allocates
with malloc. For large results keep the values, not the rows.

### Values never go through the SQL parser

There is no overload taking a string with the values already concatenated into
it: parameters always travel in the separate array `PQexecParams` expects. The
server parses the SQL — already complete — and only *then* binds the values into
the placeholders, so a value can never be mistaken for SQL, whatever it
contains. This is not escaping: the SQL and the values are sent separately.

A declared-but-unbound parameter raises instead of silently passing as NULL,
which is what catches a mistyped `:city`.

Two limits of placeholders, which surprise everyone at least once:

* `$n` stands in for **values** only, never identifiers: `select * from $1` does
  not work. For a dynamic table name there is `escapeIdentifier`.
* `where id in ($1)` does not do what it looks like — one parameter is one
  value. Postgres spells it `= any($1)`, and a D array binds straight into it:

  ```d
  db.sql("select * from users where id = any(:ids)").bind("ids", [2, 5, 9]);
  db.sql("select * from users where id = any(:ids)").bind("ids", cast(int[]) []);
  ```

  The second one is the empty list, which `in ()` cannot even be written for.
  Arrays come back too — `row["tags"].as!(string[])`, or as a member of a struct
  you map a row onto. Quoting, commas, backslashes and the literal string
  `"NULL"` all survive the round trip; a real NULL element needs a nullable
  element type (`Nullable!string[]`) and says so if you forget. Nested arrays
  are not supported.

Sometimes the server cannot infer a placeholder's type (typically
`(:x is null or col = :x)`); annotate it: `(:x::text is null or col = :x)`.

### Touching zero rows is not an error

An `update ... where id = 999` against a missing id succeeds with
`affected == 0`. If you expected to change something you have to check, and
`expect(n)` makes that explicit. It is also the mechanism behind optimistic
locking: `update ... where version = :v` with `affected == 0` means somebody
else wrote in the meantime.

To find the row you just inserted, use `returning` (OIDs are gone since PG 12):
it takes any column, including the ones the server filled in, works on
multi-row inserts, and applies to `update` and `delete` too.

### Lazy streaming and the element type

`stream!T` with `T` a struct materialises an owned value on every `popFront`, so
it composes with all of std.algorithm, `.array` included. Left to its default,
`T` is `Row` and no struct is needed at all; each `Row` keeps its own chunk of
the result alive, so it stays valid after `popFront` too — but keeping every row
of a big stream keeps all of it in memory, which is what streaming is meant to
avoid.

```d
foreach (u; db.stream!User("select id, name, age from users")) …  // owned values
foreach (r; db.stream("select id, name, age from users")) …       // rows, consumed on the spot
```

Copies of a stream share one cursor: advancing any of them advances all.

Three things the range destructor guarantees:

* **draining**: until the trailing `null` is read the connection stays busy, so
  a `break` halfway through a `foreach` would leave it unusable. The destructor
  handles it.
* **exactly once**: the state lives in a `RefCounted`, so `map` and `filter` can
  copy the range while the drain still happens at the last reference.
* **the error can arrive last**: a query that blows up on row 500,000 delivers
  the rows first and the failure afterwards, so every result is checked, not
  just the first one.

`exec` holds the whole result set in memory; `stream` holds one row at a time,
whatever the size of the result.

### Chunked rows

libpq 17 added `PQsetChunkedRowsMode`, which hands back several rows per
`PGresult` instead of one. `stream` takes the chunk size as an argument, and
defaults to `1`:

```d
foreach (u; db.sql("select ...").stream!User(256))
    process(u);
```

It changes nothing about the API: the range still yields one row at a time, and
memory stays bounded either way. What it changes is when rows reach you, since
libpq only releases a chunk once it has filled it — visible when a query fails
part-way through:

```
chunk=1   → 49 rows delivered, then sqlstate=22012 (division by zero)
chunk=256 →  0 rows delivered, then sqlstate=22012 (division by zero)
```

### Building against libpq older than 17

`PQsetChunkedRowsMode` and `PGRES_TUPLES_CHUNK` do not exist before libpq 17,
and referencing either would break the build. libpq publishes feature-detection
macros for exactly this, and ImportC turns them into manifest constants, so the
whole thing is a compile-time branch with no version arithmetic and no runtime
probing:

```d
enum hasChunkedRows = __traits(compiles, LIBPQ_HAS_CHUNK_MODE);
```

Against an older libpq the chunked branch is never compiled, the symbol is
never referenced, the chunk-size argument is ignored, and `stream` uses
single-row mode. `hasChunkedRows` is public, so your own code can check it too.

Note that this is compile-time compatibility, which is what a source library
needs: everyone builds against the libpq they have. It is not enough if you
ship a *binary* built against libpq 17+ and run it on an older one — that would
need a `dlsym` lookup instead, which is not done here.

### One connection per process

Under [serverino](https://github.com/trikko/serverino) every worker is a
separate **process** serving one request at a time: a pool buys nothing, what
you want is a single connection surviving from one request to the next.
`test/integration/source/app.d` shows the pattern in `db()`, and
`example/02_web_crud` uses it under a real serverino. It encodes two
constraints:

* it opens **lazily, never before `fork()`**: a `PGconn` inherited from the
  parent shares its socket with every child and corrupts the protocol;
* it reopens itself if the database restarts — and after `PQreset` the prepared
  statements have to be redone, because they lived in the session that just
  died.

## Declared limits

* **Text format only.** Dates, numerics and timestamps arrive as strings and go
  through `to!T`: correct, but not free. Binary format would need per-OID
  decoding and care with endianness.
* **No async API.** `PQsocket`/`PQconsumeInput`/`PQisBusy` are all there in the
  header and would allow hooking into an event loop, but that is another project.
* **No LISTEN/NOTIFY, no pipeline mode.**
* `Query` and `Transaction` hold a `Connection*`: keep the connection still
  (pass it by `ref`) while queries are alive, do not move it.
* At very large volumes a server-side cursor (`DECLARE`/`FETCH 1000`) is worth
  considering; it is not implemented here.

## About the name

The Postgres binding space is crowded — `dpq`, `dpq2`, `derelict-pq`, `pgator`,
`pgsql-lited`, `vibe-d-postgresql` — and anything else shaped like `pq` would
have been born confusing. Hence an acronym that is also a word:
**J**ust **A**nother **P**ostgres **E**lephant. A *jape* is a jest, which seems
about right for the umpteenth wrapper, and one more elephant in an already
crowded herd is exactly what this is.

*Postgres* and *PostgreSQL* are both registered trademarks, and the short form
is the only one an acronym can use.

---

Postgres, PostgreSQL and the Slonik Logo are trademarks or registered trademarks
of the PostgreSQL Community Association of Canada, and used with their
permission.
