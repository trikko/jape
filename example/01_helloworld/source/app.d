/**
 * The smallest useful jape program.
 *
 * Needs a Postgres to talk to. Anything will do, including a throwaway one:
 *
 *   docker run -d --name pqtest -e POSTGRES_PASSWORD=secret \
 *       -p 55432:5432 docker.io/library/postgres:16-alpine
 *
 * Override the connection with the JAPE_CONNINFO environment variable.
 */
module app;

import jape;

import std;

enum DEFAULT_CONNINFO =
    "host=127.0.0.1 port=55432 user=postgres password=secret dbname=postgres";

void main()
{
    // The destructor closes the connection: no finally, no close() to forget.
    auto db = Connection(environment.get("JAPE_CONNINFO", DEFAULT_CONNINFO));

    // scalar: one value out of one query
    writeln(db.scalar!string("select 'Hello, ' || $1 || '!'", "world"));
    writefln("server version %d", db.serverVersion);

    // stream: one row at a time, and the values never touch the SQL text
    foreach (row; db.stream("select n, n * n as square from generate_series(1, $1) n", 5))
        writefln("  %d² = %d", row["n"].as!int, row["square"].as!int);
}
