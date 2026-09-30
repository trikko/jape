/**
 * A notes app on serverino — add, search, delete — as a showcase for jape.
 *
 *   docker run -d --name pqtest -e POSTGRES_PASSWORD=secret \
 *       -p 55432:5432 docker.io/library/postgres:16-alpine
 *   dub run
 *   $BROWSER http://127.0.0.1:8080
 *
 * The interface is in public/, served as static files, so this is database code
 * and a JSON endpoint. Override the connection with JAPE_CONNINFO.
 */
module app;

import jape;
import serverino;

import std;

mixin ServerinoMain;

@onServerInit
ServerinoConfig configure()
{
    return ServerinoConfig.create().addListener("127.0.0.1", 8080).setWorkers(4);
}

/**
 * The schema, created once in the daemon before any worker exists.
 *
 * The connection is a local, so its destructor closes it before the daemon
 * forks: a PGconn inherited across fork() is shared at the socket level by
 * every child and the protocol falls apart. Which is why db() opens lazily.
 */
@onDaemonStart
void createSchema()
{
    auto db = Connection(conninfo);

    // Without this, `create table if not exists` on an existing table prints
    // NOTICE straight to stderr, in the middle of serverino's own log.
    db.onNotice(m => info(m));

    db.execScript(`
        create table if not exists notes (
            id         serial primary key,
            title      text not null,
            body       text not null default '',
            created_at timestamptz not null default now()
        );
    `);
}

string conninfo() { return environment.get("JAPE_CONNINFO",
    "host=127.0.0.1 port=55432 user=postgres password=secret dbname=postgres"); }

/**
 * One connection per worker, opened on first use and kept across requests.
 *
 * Workers are processes, so a pool would buy nothing: each one wants exactly
 * one connection. A function-level static is thread-local, which is what that
 * means here. `ok` is false both before the first call and after the database
 * has gone away, so this reconnects by itself — and prepares again, because
 * prepared statements live in the session that just died.
 */
ref Connection db()
{
    static Connection c;

    if (!c.ok)
    {
        c = Connection(conninfo);
        c.onNotice(m => info(m));
        c.prepare("add",   "insert into notes(title, body) values(:title, :body) returning id");
        c.prepare("del",   "delete from notes where id = :id");
        c.prepare("count", "select count(*) from notes");
    }
    return c;
}

struct Note
{
    int id;
    string title;
    string body;
    SysTime created_at;
}

/*
 * Both filters neutralise themselves when empty, which is what the builder is
 * for: an empty search becomes '%%' and matches everything, a null interval
 * makes its condition true. One statement instead of four.
 *
 * `:q` appears twice and `:since` twice, but each is one parameter bound once:
 * that is what named placeholders buy over $1.
 */
enum LIST_SQL = "
    select id, title, body, created_at
    from notes
    where (title ilike '%' || :q || '%' or body ilike '%' || :q || '%')
      and (:since::interval is null or created_at >= now() - :since::interval)
    order by id desc";

// ─────────────────────────────────────────────────────────────── endpoints ──

@endpoint @route!(r => r.path == "/api/notes" && r.method == Request.Method.Get)
void listNotes(Request request, Output output)
{
    immutable q = request.get.read("q", "").strip;
    immutable since = request.get.read("since", "");

    // The interval is a bound parameter like every other value, so nothing can
    // be injected through it. The whitelist is not about safety: an arbitrary
    // string would fail the cast to interval and come back as a 500.
    auto window = ["1 day", "7 days", "30 days"].canFind(since)
                ? Nullable!string(since) : Nullable!string.init;

    // The Result has to outlive the loop: `rows` is a view into the PGresult
    // it owns, so iterating a temporary would read memory already freed.
    auto found = db.sql(LIST_SQL).bind("q", q).bind("since", window).exec();

    JSONValue[] notes;
    foreach (row; found.rows)
    {
        auto n = row.as!Note;
        notes ~= JSONValue([
            "id":         JSONValue(n.id),
            "title":      JSONValue(n.title),
            "body":       JSONValue(n.body),
            "created_at": JSONValue(n.created_at.toISOExtString),
        ]);
    }

    output.addHeader("content-type", "application/json");
    output ~= JSONValue([
        "total":  JSONValue(db.prepared("count").scalar!long),
        "worker": JSONValue(request.worker.to!string),
        "notes":  JSONValue(notes),
    ]).toString;
}

@endpoint @route!(r => r.path == "/api/notes" && r.method == Request.Method.Post)
void addNote(Request request, Output output)
{
    output.addHeader("content-type", "application/json");

    immutable title = request.post.read("title", "").strip;
    if (title.length == 0)
    {
        output.status = 422;
        output ~= `{"error":"a note needs a title"}`;
        return;
    }

    // `returning id` gives back the generated key in the same round-trip.
    immutable id = db.prepared("add")
                     .bind("title", title)
                     .bind("body", request.post.read("body", "").strip)
                     .scalar!int;

    output ~= format!`{"id":%d}`(id);
}

@endpoint @route!(r => r.path == "/api/notes" && r.method == Request.Method.Delete)
void deleteNote(Request request, Output output)
{
    output.addHeader("content-type", "application/json");

    // Deleting a row that is not there is not an error for Postgres: it
    // succeeds, having touched nothing. If that matters, you have to look.
    immutable gone = db.prepared("del")
                       .bind("id", request.get.read("id", "0").to!int)
                       .exec.affected;

    output ~= format!`{"deleted":%d}`(gone);
}

/// Everything else is the interface, straight off the disk.
@endpoint @route!(r => r.path == "/" || r.path.startsWith("/static/"))
void ui(Request request, Output output)
{
    // request.path is normalized by serverino and must not be decoded. The
    // result is confined to public/ anyway, so nothing built from it escapes.
    immutable root = buildNormalizedPath(dirName(thisExePath), "public") ~ "/";
    immutable file = request.path == "/"
                   ? root ~ "index.html"
                   : buildNormalizedPath(root, request.path["/static/".length .. $]);

    if (!file.startsWith(root)) output.status = 403;
    else if (!output.serveFile(file)) output.status = 404;
}

/// Anything thrown by an endpoint, a PgException included, comes out as JSON.
@onWorkerException
bool onError(Request request, Output output, Exception e)
{
    output.status = 500;
    output.addHeader("content-type", "application/json");

    auto pg = cast(PgException) e;
    if (pg) error(pg.full);            // every field the server sent, in the log
    else    error(e.msg);

    output ~= JSONValue([
        "error":      JSONValue(e.msg),
        "sqlstate":   JSONValue(pg ? pg.sqlstate : ""),
        // what the user can act on: which constraint, and what the server suggests
        "constraint": JSONValue(pg ? pg.constraint : ""),
        "detail":     JSONValue(pg ? pg.detail : ""),
        "hint":       JSONValue(pg ? pg.hint : ""),
    ]).toString;

    return true;   // handled; do not rethrow
}
