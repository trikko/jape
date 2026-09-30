/**
 * Example program. It needs a Postgres reachable on 127.0.0.1:55432 (see the
 * README: `docker run -d --name pqtest -e POSTGRES_PASSWORD=secret
 *  -p 55432:5432 docker.io/library/postgres:16-alpine`).
 * Override the connection with the JAPE_CONNINFO environment variable.
 *
 * It creates and drops the `users` table in the `postgres` database: point it
 * at a throwaway instance, not at anything you care about.
 */
module app;

import jape;

import std;

// ────────────────────────────── one connection per process (serverino style) ─

enum DEFAULT_CONNINFO = "host=127.0.0.1 port=55432 user=postgres password=secret dbname=postgres";

string conninfo() { return environment.get("JAPE_CONNINFO", DEFAULT_CONNINFO); }

private void prepareAll(ref Connection c)
{
    // In a real deployment the schema already exists when the worker connects;
    // this example creates the tables afterwards, so only prepare if there is
    // something to prepare against.
    if (c.scalar!string("select coalesce(to_regclass('users')::text, '')").length == 0)
        return;
    // This example drops and recreates its own table, so plans made against the
    // previous one have to go. A normal application would not need this.
    c.deallocateAll();
    c.prepare("find_by_age", "select id, name, age from users where age >= :age order by id");
}

/**
 * Under serverino every worker is a separate PROCESS serving one request at a
 * time, so a pool buys nothing: what you want is a single connection, per
 * process, that survives from one request to the next.
 *
 * Two constraints are encoded here:
 *  - it opens lazily, NEVER before fork(): a PGconn inherited from the parent
 *    shares its socket with every child and corrupts the protocol;
 *  - it reopens itself if the database restarts — and after PQreset the
 *    prepared statements must be redone, because they lived in the session
 *    that just died.
 */
ref Connection db()
{
    static Connection c;        // in D a function-level static is thread-local, which is what we want
    static bool opened;

    if (!opened)
    {
        c = Connection(conninfo);
        prepareAll(c);
        opened = true;
    }
    else if (!c.ok)
    {
        c.reset();
        prepareAll(c);
    }
    return c;
}

// ─────────────────────────────────────────────────────────────────── demo ───

struct User
{
    int id;
    string name;
    int age;
}

struct FullUser
{
    int id;
    string name;
    Nullable!string city;                  // a column that may be NULL
    @Column("created_at") SysTime createdAt;   // snake_case column, camelCase member
}

private void section(string title)
{
    auto app = appender!string();
    // the size_t subtraction has to be guarded: a title longer than the rule
    // would make this loop run 2^64 times
    immutable dashes = title.length >= 58 ? 3 : 58 - title.length;
    foreach (_; 0 .. dashes) app ~= "─";
    writeln();
    writeln("── ", title, " ", app.data);
}

void main()
{
    auto c = &db();
    writefln("connected, server version %d", c.serverVersion);

    // ─── schema ────────────────────────────────────────────────────────────
    section("DDL through execScript (multi-statement, no parameters)");
    c.execScript(`
        drop table if exists users;
        create table users (
            id         serial primary key,
            name       text not null unique,
            age        int  not null,
            city       text,
            version    int  not null default 1,
            created_at timestamptz not null default now()
        );
    `);
    prepareAll(*c);     // the schema exists now, so the session statements can be prepared
    writeln("table created");

    // ─── insert + returning ────────────────────────────────────────────────
    section("insert ... returning: how you find the row you just wrote");

    auto adaId = c.sql("insert into users(name, age, city) values(:name, :age, :city) returning id")
                  .bind("name", "Ada").bind("age", 36).bind("city", "Turin")
                  .scalar!int;
    writefln("generated id: %d", adaId);
    assert(adaId > 0);

    // server-filled columns come back in the same round-trip
    {
        auto r = c.exec("insert into users(name, age) values($1, $2) returning id, created_at",
                        "Grace", 45);
        auto row = r.front;
        writefln("Grace → id=%d created_at=%s", row["id"].as!int, row["created_at"].as!SysTime);
    }

    // multi-row insert: one id per inserted row
    {
        auto r = c.exec("insert into users(name, age, city) values($1,$2,$3),($4,$5,$6),($7,$8,$9)
                         returning id",
                        "Alan", 41, "London", "Edsger", 72, null, "Barbara", 33, "Turin");
        writefln("multi-row insert: %d rows, ids = %s", r.affected, r.rows.map!(x => x[0].as!int).array);
        assert(r.affected == 3);
    }

    // ─── commands and checking the outcome ─────────────────────────────────
    section("update/delete: how many rows did I really touch?");

    {
        auto r = c.exec("update users set age = age + 1 where city = $1", "Turin");
        writefln("update: affected=%d, cmdStatus=%s", r.affected, r.cmdStatus);
        assert(r.affected == 2);
    }

    // THE COUNTERINTUITIVE BIT: touching zero rows is not an error.
    {
        auto r = c.exec("update users set age = 99 where id = $1", 999_999);
        writefln("update on a missing id: no exception, affected=%d", r.affected);
        assert(r.affected == 0);
    }

    // ...unless you make it one
    {
        bool threw = false;
        try
            c.sql("update users set age = :age where id = :id")
             .bind("age", 99).bind("id", 999_999)
             .exec.expect(1);
        catch (PgException e) { threw = true; writeln("expect(1) threw: ", e.msg); }
        assert(threw);
    }

    // optimistic locking: the second update loses the race and notices
    {
        auto st = c.prepare("optimistic_update",
            "update users set age = :age, version = version + 1 where id = :id and version = :v");

        auto first = st.bind("age", 37).bind("id", adaId).bind("v", 1).exec;
        auto second = st.bind("age", 38).bind("id", adaId).bind("v", 1).exec;
        writefln("optimistic locking: first=%d rows, second=%d rows (conflict)",
                 first.affected, second.affected);
        assert(first.affected == 1 && second.affected == 0);
    }

    // delete ... returning: not just how many, but which ones
    {
        c.exec("insert into users(name, age) values($1,$2),($3,$4)", "Tmp1", 10, "Tmp2", 11);
        auto r = c.exec("delete from users where age < $1 returning id, name", 18);
        writefln("deleted %d rows: %s", r.affected, r.rows.map!(x => x["name"].as!string).array);
        assert(r.affected == 2);
    }

    // ─── transactions ──────────────────────────────────────────────────────
    section("transactions: rollback is the default");

    {
        auto tx = c.transaction();
        c.exec("insert into users(name, age) values($1,$2)", "Committed", 50);
        tx.commit();
    }
    assert(c.scalar!long("select count(*) from users where name = $1", "Committed") == 1);
    writeln("committed: the row is there");

    {
        auto tx = c.transaction();
        c.exec("insert into users(name, age) values($1,$2)", "Ghost", 50);
        // no commit: the destructor rolls back
    }
    assert(c.scalar!long("select count(*) from users where name = $1", "Ghost") == 0);
    writeln("no commit: the row is not there");

    // aborted transaction, and recovery through a savepoint
    {
        auto tx = c.transaction();
        auto sp = tx.savepoint();
        bool sawError = false;
        try c.exec("insert into users(name, age) values($1,$2)", "Ada", 1);  // duplicate name
        catch (PgException e) { sawError = true; }
        assert(sawError && c.inErrorState);
        writeln("inside the transaction the error aborted everything, inErrorState=", c.inErrorState);

        sp.rollback();                       // rewind to the savepoint
        assert(!c.inErrorState);
        c.exec("insert into users(name, age) values($1,$2)", "After the savepoint", 20);
        tx.commit();
        writeln("recovered through the savepoint, transaction committed");
    }

    // ─── queries, mapping, eager ranges ────────────────────────────────────
    section("eager select: a composable RandomAccessRange");

    {
        auto r = c.exec("select id, name, age from users where age >= $1 order by id", 30);
        writefln("%d rows, the third one is %s", r.length, r[2]);

        auto names = r.rows.map!(row => row.as!User).filter!(u => u.age > 40).map!(u => u.name).array;
        writeln("over 40: ", names);
        assert(r.length > 0);
    }

    section("incremental binding: values arrive from different places");

    {
        auto q = c.sql("select id, name, age from users
                          where age >= :age and (:city::text is null or city = :city) order by id");
        q.bind("age", 18);

        // an optional filter: bind NULL, do not leave the parameter unbound
        bool filterByCity = true;
        q.bind("city", filterByCity ? Nullable!string("Turin") : Nullable!string.init);

        auto r = q.exec();
        writefln("with the city filter: %d rows", r.length);

        // the same Query reused with other values
        auto r2 = q.reset().bind("age", 18).bind("city", null).exec();
        writefln("without the city filter: %d rows", r2.length);
        assert(r2.length > r.length);
    }

    {
        // positional binding works the same way, chained
        auto n = c.sql("select count(*) from users where age between $1 and $2")
                  .bind(1, 30).bind(2, 50)
                  .scalar!long;
        writefln("between 30 and 50: %d", n);
    }

    {
        // a forgotten parameter is an explicit error, not a silent NULL
        bool threw = false;
        try c.sql("select * from users where age > :age and city = :city").bind("age", 18).exec();
        catch (PgException e) { threw = true; writeln("missing binding → ", e.msg); }
        assert(threw);
    }

    // ─── NULL when reading ─────────────────────────────────────────────────
    section("NULL: Nullable when reading, and struct mapping");

    {
        auto r = c.exec("select id, name, city, created_at from users order by id limit 3");
        foreach (u; r.rows.map!(row => row.as!FullUser))
            writefln("  %-20s city=%-10s created=%s",
                     u.name, u.city.isNull ? "NULL" : u.city.get, u.createdAt.toISOExtString[0 .. 19]);

        // reading a NULL into a non-nullable type is an error, not a silent zero
        bool threw = false;
        auto row = c.exec("select city from users where city is null limit 1");
        try cast(void) row.front[0].as!string;
        catch (PgException e) { threw = true; writeln("NULL into a non-nullable type → ", e.msg); }
        assert(threw);
    }

    // ─── SQLSTATE ──────────────────────────────────────────────────────────
    section("errors: SQLSTATE kept apart from the message");

    {
        bool seen = false;
        try c.exec("insert into users(name, age) values($1,$2)", "Ada", 1);
        catch (PgException e)
        {
            seen = e.sqlstate == "23505";
            writefln("unique violation: sqlstate=%s msg=%s", e.sqlstate, e.msg);
            // the server said much more than the message: which constraint was
            // broken, on which table, and with which value
            writefln("  severity=%s table=%s constraint=%s", e.severity, e.table, e.constraint);
            writefln("  detail=%s", e.detail);
            writefln("  full()  %s", e.full);
            assert(e.constraint == "users_name_key" && e.table == "users");
            assert(e.detail.canFind("Ada"));
        }
        assert(seen);
    }

    {
        // a syntax error points at the character it choked on
        bool seen = false;
        try c.exec("select nonexistent_column from users");
        catch (PgException e)
        {
            seen = true;
            writefln("bad column: sqlstate=%s position=%d msg=%s", e.sqlstate, e.position, e.msg);
            assert(e.sqlstate == "42703" && e.position > 0);
        }
        assert(seen);
    }

    // ─── notices ───────────────────────────────────────────────────────────
    section("notices: NOTICE and WARNING go where you send them");

    {
        string[] heard;
        c.onNotice((m) { heard ~= m; });
        c.execScript("drop table if exists never_existed");
        c.execScript("do $$ begin raise notice 'from the server'; end $$");
        writefln("captured %d: %s", heard.length, heard);
        assert(heard.length == 2 && heard[1].canFind("from the server"));

        // a handler that throws must not fail the statement that produced it
        c.onNotice((m) { throw new Exception("boom"); });
        c.execScript("drop table if exists never_existed");
        assert(c.scalar!int("select 1") == 1);

        c.onNotice(null);            // and null drops them
        c.execScript("drop table if exists never_existed");
        writeln("handler that throws, then silenced: connection still fine");
    }

    // ─── arrays ────────────────────────────────────────────────────────────
    section("arrays: one parameter for a whole list");

    {
        // `in ($1)` cannot work — one parameter is one value — so Postgres
        // spells it `= any($1)`, and an array goes in as a single parameter.
        auto picked = c.sql("select name from users where id = any(:ids) order by id")
                       .bind("ids", [adaId, adaId + 1]).exec;
        writeln("  id = any([...]) → ", picked.rows.map!(r => r[0].as!string).array);
        assert(picked.length == 2);

        // the empty list, which `in ()` cannot even express
        auto none = c.sql("select id from users where id = any(:ids)")
                     .bind("ids", cast(int[]) []).exec;
        writefln("  the empty list matches %d rows", none.length);
        assert(none.length == 0);

        // round trip, with every element that needs quoting
        immutable awkward = ["plain", "with space", "with,comma", `with "quotes"`,
                             `back\slash`, "", "NULL"];
        auto back = c.sql("select :tags::text[]").bind("tags", awkward).scalar!(string[]);
        writefln("  %d awkward strings survived the round trip", back.length);
        assert(back == awkward);

        // NULL elements need a nullable element type, and say so otherwise
        auto holes = c.scalar!(Nullable!string[])("select '{a,NULL,c}'::text[]");
        assert(holes.length == 3 && holes[1].isNull);
        writeln("  {a,NULL,c} → ", holes);

        bool threw = false;
        try c.scalar!(string[])("select '{a,NULL}'::text[]");
        catch (PgException e) { threw = true; writeln("  NULL into string[] → ", e.msg); }
        assert(threw);
    }

    // ─── numeric ───────────────────────────────────────────────────────────
    section("numeric: exact, because double is not");

    {
        c.execScript("drop table if exists amounts; create table amounts(v numeric)");
        c.exec("insert into amounts values($1)", Numeric("1234567.89"));

        auto exact = c.scalar!Numeric("select v from amounts");
        writefln("  stored %s, read back %s, equal: %s",
                 "1234567.89", exact, exact == Numeric("1234567.89"));
        assert(exact == Numeric("1234567.89"));
        writefln("  the same value through double: %.17g", exact.toDouble);

        // 1.10 and 1.1 are the same number but not the same text, as in SQL
        assert(Numeric("1.10") == Numeric("1.1"));
        assert(Numeric("1.10").toString == "1.10");

        writefln("  a thousand times 0.01 = %s", c.scalar!Numeric(
            "select sum(0.01) from generate_series(1,1000)"));

        // the same column as a double still works: the type you ask for is the
        // choice you are making. It just is not the same number any more.
        immutable approx = c.scalar!double("select v from amounts");
        writefln("  the same column as double: %.17g", approx);
        assert(approx != 1234567.89L);
        assert(exact.toDouble == approx);        // and toDouble agrees with it

        c.execScript("drop table amounts");
    }

    // ─── COPY ──────────────────────────────────────────────────────────────
    section("COPY: the fast way in, and the safe way out of a failed one");

    {
        c.execScript("drop table if exists bulk; create table bulk(id int, name text, v numeric)");

        {
            auto copy = c.copyIn("copy bulk from stdin");
            foreach (i; 0 .. 10_000)
                copy.writeRow(i, "name\twith\ttabs", Numeric("0.01"));
            immutable taken = copy.commit();
            writefln("  copied %d rows", taken);
            assert(taken == 10_000);
        }
        assert(c.scalar!long("select count(*) from bulk") == 10_000);
        assert(c.scalar!string("select name from bulk limit 1") == "name\twith\ttabs");

        // an abandoned copy writes nothing at all
        {
            auto copy = c.copyIn("copy bulk from stdin");
            copy.writeRow(1, "never", Numeric("1"));
        }   // no commit
        assert(c.scalar!long("select count(*) from bulk") == 10_000);
        writeln("  a copy dropped without commit left nothing behind");

        // NULL goes in as either null or an empty Nullable
        {
            auto copy = c.copyIn("copy bulk from stdin");
            copy.writeRow(1, null, Nullable!Numeric.init);
            copy.commit();
        }
        assert(c.scalar!long("select count(*) from bulk where name is null and v is null") == 1);

        // and out again, lazily, with an early break the connection survives
        int seen;
        foreach (line; c.copyOut("copy bulk to stdout"))
            if (++seen == 5) break;
        writefln("  read %d lines then broke out; connection still answers %d",
                 seen, c.scalar!long("select count(*) from bulk"));

        // a COPY to a server-side file is an ordinary statement, and says so
        bool threw = false;
        try c.copyOut("copy bulk to '/tmp/jape-integration.csv'");
        catch (PgException e) { threw = true; writeln("  ", e.msg); }
        assert(threw);

        c.execScript("drop table bulk");
    }

    // ─── bytea, json, interval, time ───────────────────────────────────────
    section("the other types an application actually stores");

    {
        c.execScript("drop table if exists bits;
                      create table bits(b bytea, j jsonb, iv interval, tm time)");

        immutable ubyte[] blob = [0, 1, 2, 255, 'h', 'i'];
        c.exec("insert into bits(b) values($1)", blob);
        assert(c.scalar!(ubyte[])("select b from bits where b is not null") == blob);
        writefln("  bytea: %s ↔ %s", blob,
                 c.scalar!string("select b::text from bits where b is not null"));

        auto doc = parseJSON(`{"name":"Ada","tags":[1,2,3]}`);
        c.exec("insert into bits(j) values($1)", doc);
        auto read = c.scalar!JSONValue("select j from bits where j is not null");
        assert(read.type == JSONType.object && read["name"].str == "Ada");
        writefln("  jsonb: an object, not a string of one — name=%s, and the server agrees: %s",
                 read["name"], c.scalar!string("select j->>'name' from bits where j is not null"));

        assert(c.scalar!Duration("select '1 day 02:30:00'::interval") == 1.days + 2.hours + 30.minutes);
        assert(c.scalar!Duration("select '-00:00:01.25'::interval") == -(1.seconds + 250_000.usecs));
        c.exec("insert into bits(iv, tm) values($1, $2)", 90.minutes, TimeOfDay(14, 30, 0));
        assert(c.scalar!Duration("select iv from bits where iv is not null") == 90.minutes);
        assert(c.scalar!TimeOfDay("select tm from bits where tm is not null") == TimeOfDay(14, 30, 0));
        writeln("  interval and time round trip");

        // a month is not a fixed length of time, so it is refused
        bool threw = false;
        try c.scalar!Duration("select '1 mon'::interval");
        catch (PgException e) { threw = true; writeln("  ", e.msg); }
        assert(threw);

        // and a fractional second cannot fit in a TimeOfDay
        threw = false;
        try c.scalar!TimeOfDay("select '14:30:00.5'::time");
        catch (PgException e) { threw = true; writeln("  ", e.msg); }
        assert(threw);
        assert(c.scalar!Duration("select '14:30:00.5'::time") == 14.hours + 30.minutes + 500.msecs);

        c.execScript("drop table bits");
    }

    // ─── isolation and retry ───────────────────────────────────────────────
    section("isolation levels, and being told to try again");

    {
        {
            auto tx = c.transaction(Isolation.serializable, Access.readOnly);
            assert(c.scalar!string("select current_setting('transaction_isolation')") == "serializable");

            bool threw = false;
            try c.exec("insert into users(name, age) values($1,$2)", "nope", 1);
            catch (PgException e) { threw = true; writefln("  read only: %s (%s)", e.msg, e.sqlstate); }
            assert(threw);
        }
        assert(c.scalar!int("select 1") == 1);   // rolled back, connection fine

        assert(isRetryable("40001") && isRetryable("40P01") && !isRetryable("23505"));

        // transact runs the body again when the server says the transaction
        // lost a race. Here the 40001 is simulated so the test is not a race.
        int calls;
        immutable answer = c.transact({
            ++calls;
            if (calls < 3) throw new PgException("simulated conflict", "40001");
            return c.scalar!int("select 42");
        });
        writefln("  transact: body ran %d times, returned %d", calls, answer);
        assert(calls == 3 && answer == 42);

        // and it gives up on an error that retrying cannot fix
        bool gaveUp = false;
        try c.transact({ c.exec("insert into users(name, age) values($1,$2)", "Ada", 1); });
        catch (PgException e) { gaveUp = e.sqlstate == "23505"; }
        assert(gaveUp);
        writeln("  a unique violation is not retried, it is rethrown");
    }

    // ─── lazy streaming ────────────────────────────────────────────────────
    section("lazy stream: single-row mode, constant memory");

    enum BULK_ROWS = 2000;
    c.execScript("insert into users(name, age)
                  select 'bulk_' || g, 18 + (g % 60) from generate_series(1, "
                  ~ BULK_ROWS.to!string ~ ") g");

    {
        int seen = 0;
        foreach (u; c.stream!User("select id, name, age from users order by id"))
        {
            ++seen;
            if (seen == 5) break;      // early exit: the destructor drains the rest
        }
        writefln("stopped after %d rows", seen);

        // the connection is usable again: proof that the drain happened
        auto total = c.scalar!long("select count(*) from users");
        writefln("the connection is clean: count = %d", total);
        assert(total > BULK_ROWS);
    }

    {
        // a lazy chain: with T = struct every element is owned, so .array is safe
        auto firstThree = c.stream!User("select id, name, age from users order by id")
                           .filter!(u => u.age > 70)
                           .map!(u => u.name)
                           .take(3)
                           .array;
        writeln("first 3 over 70 (lazy): ", firstThree);
        assert(firstThree.length == 3);
    }

    {
        // The error can show up part-way through a stream instead of at the
        // start — and how many rows you get first depends on the chunk size,
        // because libpq only hands a chunk over once it is complete. The query
        // below dies on row 50 of 100.
        writefln("chunked rows available in this libpq: %s", hasChunkedRows);

        foreach (chunk; [1, 256])
        {
            int before = 0;
            bool blewUp = false;
            try
            {
                foreach (row; c.sql("select g, case when g = 50 then 1/(g-50) else g end
                                       from generate_series(1, 100) g").stream(chunk))
                    ++before;
            }
            catch (PgException e)
            {
                blewUp = true;
                writefln("  chunk=%-3d → %2d rows delivered, then sqlstate=%s (%s)",
                         chunk, before, e.sqlstate, e.msg);
            }
            assert(blewUp);
        }
        assert(c.scalar!int("select 1") == 1);   // and the connection is still healthy
    }

    // ─── prepared statements ───────────────────────────────────────────────
    section("prepared statement: parse once, run many times");

    {
        auto find = c.prepare("find_exact_age", "select count(*) from users where age = :age");
        foreach (age; [30, 40, 50])
            writefln("  age=%d → %d users", age, find.bind("age", age).scalar!long);

        // find_by_age was prepared back in prepareAll(), and nobody carried the
        // PreparedStatement around: it comes back by name.
        writefln("  prepared on this connection: %s", c.preparedNames);
        assert(c.isPrepared("find_by_age") && !c.isPrepared("never_prepared"));

        auto byAge = c.prepared("find_by_age");
        writefln("  find_by_age, recovered by name → %d rows", byAge.bind("age", 70).exec.length);

        bool threw = false;
        try c.prepared("never_prepared");
        catch (PgException e) { threw = true; writeln("  unknown name → ", e.msg); }
        assert(threw);
    }

    // ─── dynamic identifiers ───────────────────────────────────────────────
    section("identifiers: $n cannot stand in for one, use escapeIdentifier");

    {
        auto table = c.escapeIdentifier("users");
        writefln("quoted identifier: %s", table);
        auto n = c.scalar!long("select count(*) from " ~ table ~ " where age > $1", 18);
        writefln("rows: %d", n);
    }

    section("done");
    writeln("every assert passed");
}
