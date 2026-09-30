/**
 * jape — Just Another Postgres Elephant.
 *
 * A thin, idiomatic D wrapper over libpq, imported with ImportC
 * (`import jape_pq;` → jape_pq.c → libpq-fe.h). No hand-written bindings.
 *
 * Core idea: separate WHO OWNS from WHO ITERATES.
 *   - types that own a session resource (Connection, Transaction, CopyIn) are
 *     non-copyable and release it in their destructor;
 *   - a result is reference-counted: Result, its Rows and every Row and Field
 *     taken from them share it, so ranges stay lightweight, copyable views
 *     and std.algorithm and std.range compose without friction.
 *
 * Declared limits: text format only (no binary), no async API,
 * no LISTEN/NOTIFY, no pipeline mode.
 *
 * Caveat: Query and Transaction hold a Connection* — keep the connection
 * still (pass it by ref) while queries are alive, do not move it.
 *
 * Example:
 * ---
 * struct User { int id; string name; int age; }
 *
 * auto db = Connection("host=localhost dbname=app user=app");
 *
 * db.exec("insert into users(name, age) values($1, $2)", "Ada", 36);
 * auto adults = db.scalar!long("select count(*) from users where age >= $1", 18);
 *
 * foreach (u; db.stream!User("select id, name, age from users order by id"))
 *     writeln(u.name);
 * ---
 *
 * See_Also:
 *   $(LINK2 https://github.com/trikko/jape, the README) for a guided tour,
 *   $(LINK2 https://trikko.github.io/jape/llms-full.txt, llms-full.txt) for
 *   the whole API in one file.
 */
module jape;

import jape_pq;

import std.algorithm;
import std.array;
import std.ascii : isAlpha, isAlphaNum, isDigit, isWhite;
import std.bigint;
import std.conv;
import std.datetime;
import std.exception;
import std.format;
import std.json;
import std.range;
import std.string;
import std.traits;
import std.typecons;
import std.uni : sicmp;

// On some platforms (macOS) the C headers declare their own size_t, which pq
// re-exports and which then clashes with D's: the local alias settles it.
private alias size_t = object.size_t;

// ImportC turns simple object-like macros into manifest constants; should that
// ever stop being true, these fallbacks keep the module compiling.
static if (!__traits(compiles, PG_DIAG_SQLSTATE))
{
    enum PG_DIAG_SEVERITY_NONLOCALIZED = 'V';
    enum PG_DIAG_SEVERITY = 'S';
    enum PG_DIAG_SQLSTATE = 'C';
    enum PG_DIAG_MESSAGE_PRIMARY = 'M';
    enum PG_DIAG_MESSAGE_DETAIL = 'D';
    enum PG_DIAG_MESSAGE_HINT = 'H';
    enum PG_DIAG_STATEMENT_POSITION = 'P';
    enum PG_DIAG_CONTEXT = 'W';
    enum PG_DIAG_SCHEMA_NAME = 's';
    enum PG_DIAG_TABLE_NAME = 't';
    enum PG_DIAG_COLUMN_NAME = 'c';
    enum PG_DIAG_DATATYPE_NAME = 'd';
    enum PG_DIAG_CONSTRAINT_NAME = 'n';
}

/**
 * True when the libpq headers this was compiled against provide
 * PQsetChunkedRowsMode and PGRES_TUPLES_CHUNK, i.e. libpq 17 or newer.
 *
 * libpq publishes its own feature-detection macros, so this needs no version
 * arithmetic and no runtime probing: against an older libpq the whole chunked
 * path is simply not compiled, the symbol is never referenced, and `stream`
 * falls back to single-row mode on its own.
 */
enum hasChunkedRows = __traits(compiles, LIBPQ_HAS_CHUNK_MODE);

/// Rows per chunk when `stream` is called without an explicit size: single-row mode.
enum defaultChunkSize = 1;

// ──────────────────────────────────────────────────────────────── errors ────

/**
 * What the server said, taken apart.
 *
 * `msg` is the one-line primary message. Everything else Postgres bothered to
 * send comes with it, and the fields it did not send are empty — most errors
 * fill in only a few. `constraint` is what turns "duplicate key value violates
 * unique constraint" into a message your users can act on, and `position` is
 * the character in the statement the server choked on.
 */
class PgException : Exception
{
    /// Five-character SQLSTATE (e.g. "23505" unique_violation), empty if unavailable.
    string sqlstate;

    string severity;    /// ERROR, FATAL, PANIC, WARNING… always in English.
    string detail;      /// A second, more specific line. Often names the offending value.
    string hint;        /// What the server suggests doing about it.
    string context;     /// The call stack, when the error came from a function or trigger.
    // Schema, table, column, constraint and data type involved, as far as the
    // server chose to identify them: filled in mostly by integrity-constraint errors.
    string schema;      /// The schema of the object involved.
    string table;       /// The table involved.
    string column;      /// The column involved.
    string constraint;  /// The constraint that was broken, e.g. "users_email_key".
    string dataType;    /// The data type involved.

    /// 1-based character offset into the statement, 0 when the server gave none.
    int position;

    /// Errors from the server are built by jape; this is here for your own.
    this(string msg, string sqlstate = null, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line);
        this.sqlstate = sqlstate;
    }

    /// Every field the server filled in, on one line, for a log.
    string full() const
    {
        auto app = appender!string();
        app ~= severity.length ? severity : "ERROR";
        if (sqlstate.length) { app ~= " ["; app ~= sqlstate; app ~= "]"; }
        app ~= ": ";
        app ~= msg;

        void add(string label, string value)
        {
            if (value.length) { app ~= " | "; app ~= label; app ~= "="; app ~= value; }
        }

        add("detail", detail);
        add("hint", hint);
        add("schema", schema);
        add("table", table);
        add("column", column);
        add("constraint", constraint);
        add("type", dataType);
        add("context", context);
        if (position) { app ~= " | position="; app ~= position.to!string; }

        return app.data;
    }
}

private void pgEnforce(bool condition, lazy string msg)
{
    if (!condition) throw new PgException(msg);
}

private string lastError(PGconn* conn)
{
    auto p = PQerrorMessage(conn);
    auto s = p ? p.fromStringz.idup.strip : null;
    return s.length ? s : "unknown error";
}

private string errorField(PGresult* res, int code)
{
    auto p = PQresultErrorField(res, code);
    return p ? p.fromStringz.idup : null;
}

/// Takes a failed result apart into an exception, and clears it.
private PgException errorFrom(PGconn* conn, PGresult* res)
{
    string field(int code) { return errorField(res, code); }

    auto msg = field(PG_DIAG_MESSAGE_PRIMARY);
    if (msg.length == 0) msg = lastError(conn);

    auto e = new PgException(msg, field(PG_DIAG_SQLSTATE));

    // SEVERITY is translated when the server speaks another language;
    // SEVERITY_NONLOCALIZED never is, so prefer it when present.
    e.severity   = field(PG_DIAG_SEVERITY_NONLOCALIZED);
    if (e.severity.length == 0) e.severity = field(PG_DIAG_SEVERITY);

    e.detail     = field(PG_DIAG_MESSAGE_DETAIL);
    e.hint       = field(PG_DIAG_MESSAGE_HINT);
    e.context    = field(PG_DIAG_CONTEXT);
    e.schema     = field(PG_DIAG_SCHEMA_NAME);
    e.table      = field(PG_DIAG_TABLE_NAME);
    e.column     = field(PG_DIAG_COLUMN_NAME);
    e.constraint = field(PG_DIAG_CONSTRAINT_NAME);
    e.dataType   = field(PG_DIAG_DATATYPE_NAME);

    auto at = field(PG_DIAG_STATEMENT_POSITION);
    if (at.length) e.position = at.to!int;

    PQclear(res);
    return e;
}

/// Throws unless the result is a success. Consumes (PQclear) a failed result.
private void checkResult(PGconn* conn, PGresult* res)
{
    if (res is null)
        throw new PgException("libpq: " ~ lastError(conn));

    switch (PQresultStatus(res))
    {
        // COMMAND_OK = insert/update/delete/DDL; TUPLES_OK = select, or ... returning
        case PGRES_COMMAND_OK, PGRES_TUPLES_OK, PGRES_SINGLE_TUPLE:
            return;

        // A COPY that reaches exec has already switched the connection into a
        // data channel; left there, every later call fails. Close it first.
        case PGRES_COPY_IN, PGRES_COPY_BOTH:
            PQclear(res);
            PQputCopyEnd(conn, "COPY ... FROM STDIN is not supported through exec");
            drainResults(conn);
            throw new PgException("COPY ... FROM STDIN cannot run through exec: use copyIn");

        case PGRES_COPY_OUT:
            PQclear(res);
            char* chunk;
            while (PQgetCopyData(conn, &chunk, 0) > 0) PQfreemem(chunk);
            drainResults(conn);
            throw new PgException("COPY ... TO STDOUT cannot run through exec: use copyOut");

        case PGRES_EMPTY_QUERY:
            PQclear(res);
            throw new PgException("empty statement: there was nothing to run");

        default:
            throw errorFrom(conn, res);
    }
}

// ───────────────────────────────────────────────────────────────── Field ────

/// UDA mapping a member onto a differently named column: @Column("user_id") int id;
struct Column { string name; }

/// One cell. A copyable value that keeps its PGresult alive for as long as it exists.
struct Field
{
    private ResultRef owner;   // the reference that keeps `res` alive
    private PGresult* res;
    private int row, col;

    private this(ResultRef owner, int row, int col)
    {
        this.owner = owner;
        this.res = owner.res;
        this.row = row;
        this.col = col;
    }

    /// Whether the value is SQL NULL.
    @property bool isNull() { return PQgetisnull(res, row, col) != 0; }

    /// A NON-owning view over the result bytes. Does not outlive the PGresult.
    @property const(char)[] raw()
    {
        auto p = PQgetvalue(res, row, col);
        return p[0 .. PQgetlength(res, row, col)];
    }

    /// The OID of the column's type, as in `pg_type`.
    @property uint typeOid() { return PQftype(res, col); }
    /// The name of the column.
    @property string name() { return PQfname(res, col).fromStringz.idup; }

    /// Typed conversion. as!string COPIES; as!(Nullable!T) accepts NULL.
    T as(T)()
    {
        static if (isInstanceOf!(Nullable, T))
        {
            alias U = TemplateArgsOf!T[0];
            if (isNull) return T.init;
            return T(fromText!U(raw));
        }
        else
        {
            if (isNull)
                throw new PgException("column '" ~ name ~ "' is NULL: use Nullable!" ~ T.stringof);
            return fromText!T(raw);
        }
    }

    /// The text the server sent, or "NULL".
    string toString() { return isNull ? "NULL" : raw.idup; }
}

private T fromText(T)(const(char)[] s)
{
    static if (is(T == string))          return s.idup;
    else static if (is(T == bool))       return s == "t" || s == "true" || s == "1";
    else static if (is(T == Date))       return Date.fromISOExtString(s);
    else static if (is(T == SysTime))    return parseTimestamp(s);
    else static if (is(T == Numeric))    return Numeric.parse(s);
    else static if (is(T == JSONValue))  return parseJSON(s);
    else static if (is(T == TimeOfDay))  return parseTimeOfDay(s);
    else static if (is(T == Duration))   return parseInterval(s);
    else static if (is(T == ubyte[]))    return parseBytea(s);
    else static if (isDynamicArray!T && !isSomeString!T)
    {
        alias E = ElementType!T;
        T result;
        foreach (item; arrayElements(s))
        {
            static if (isInstanceOf!(Nullable, E))
            {
                if (item.isNull) result ~= E.init;
                else result ~= E(fromText!(TemplateArgsOf!E[0])(item.get));
            }
            else
            {
                pgEnforce(!item.isNull,
                          "NULL inside a " ~ T.stringof ~ ": read it as Nullable!"
                          ~ E.stringof ~ "[] instead");
                result ~= fromText!E(item.get);
            }
        }
        return result;
    }
    else                                 return s.to!T;
}

// ─────────────────────────────────────────────────────────────── numeric ────

/**
 * An exact decimal, the way Postgres `numeric` is exact.
 *
 * It exists because `double` cannot hold a decimal fraction: 0.1 read into a
 * double and written back comes out as 0.10000000000000001, and a thousand
 * additions of 0.01 land on 9.99999999999983 instead of 10. On a column of
 * money that is a bug you do not see until you do.
 *
 * This carries the value, compares it and hands it back untouched. It has no
 * arithmetic on purpose: the database it came from already has exact operators
 * and knows how to round, so `sum`, `*` and `/` belong in the statement, not
 * here.
 *
 * Reading the same column as `double` still works — the type you ask for is the
 * choice you are making, and an approximation is often the right one. This is
 * for when it is not.
 */
struct Numeric
{
    private enum Kind : ubyte { finite, nan, posInf, negInf }

    private Kind kind;
    private BigInt digits;   // the value without its decimal point, sign included
    private int scale;       // how many of those digits are after the point

    /// Parses the text form: `1234.50`, `-1e3`, `NaN`, `Infinity`, `-Infinity`.
    this(const(char)[] text) { this = parse(text); }

    /// NaN, which in Postgres equals itself and sorts above everything.
    @property bool isNaN() const { return kind == Kind.nan; }
    /// Infinity or -Infinity.
    @property bool isInfinity() const { return kind == Kind.posInf || kind == Kind.negInf; }
    /// Neither NaN nor an infinity.
    @property bool isFinite() const { return kind == Kind.finite; }

    /// Digits after the decimal point, as the server wrote them: 1.10 keeps two.
    @property int decimals() const { return scale; }

    /// The same as the constructor: throws PgException on malformed text.
    static Numeric parse(const(char)[] source)
    {
        Numeric n;
        auto t = source.strip;
        pgEnforce(t.length > 0, "empty numeric");

        bool negative;
        if (t[0] == '+' || t[0] == '-') { negative = t[0] == '-'; t = t[1 .. $]; }

        if (t.sicmp("nan") == 0)      { n.kind = Kind.nan; return n; }
        if (t.sicmp("infinity") == 0) { n.kind = negative ? Kind.negInf : Kind.posInf; return n; }

        auto mantissa = appender!string();
        size_t i = 0;
        while (i < t.length && t[i].isDigit) mantissa ~= t[i++];

        if (i < t.length && t[i] == '.')
        {
            ++i;
            while (i < t.length && t[i].isDigit) { mantissa ~= t[i++]; ++n.scale; }
        }

        if (i < t.length && (t[i] == 'e' || t[i] == 'E'))
        {
            // Postgres stores at most 131072 digits before the point and 16383
            // after it; an exponent beyond that is garbage, not a request for
            // a gigabyte of zeros.
            enum maxExponent = 131_072 + 16_383;
            auto rest = t[++i .. $];
            auto body_ = rest.length && (rest[0] == '+' || rest[0] == '-') ? rest[1 .. $] : rest;
            pgEnforce(body_.length > 0 && body_.length <= 9 && body_.all!isDigit,
                      "not a number: " ~ source.idup);
            immutable exponent = rest.to!int;
            pgEnforce(exponent >= -maxExponent && exponent <= maxExponent,
                      "numeric exponent out of range: " ~ source.idup);
            n.scale -= exponent;
            i = t.length;
        }

        pgEnforce(i == t.length && mantissa.data.length > 0,
                  "not a number: " ~ source.idup);

        auto text = mantissa.data;
        if (n.scale < 0)                       // 1e3 → 1000 with scale 0
        {
            text ~= "0".replicate(-n.scale);
            n.scale = 0;
        }

        n.digits = BigInt(text);
        if (negative) n.digits = -n.digits;
        return n;
    }

    /// Plain decimal notation, with the digits after the point the value was read with.
    string toString() const
    {
        final switch (kind)
        {
            case Kind.nan:    return "NaN";
            case Kind.posInf: return "Infinity";
            case Kind.negInf: return "-Infinity";
            case Kind.finite: break;
        }

        auto text = digits.to!string;
        immutable negative = text.startsWith("-");
        if (negative) text = text[1 .. $];

        if (scale == 0) return negative ? "-" ~ text : text;

        if (text.length <= scale)              // 0.001: pad up to one leading zero
            text = "0".replicate(scale - text.length + 1) ~ text;

        auto result = text[0 .. $ - scale] ~ "." ~ text[$ - scale .. $];
        return negative ? "-" ~ result : result;
    }

    /// Numeric comparison: 1.10 and 1.1 are the same value, as they are in SQL.
    int opCmp(const Numeric other) const
    {
        if (kind != Kind.finite || other.kind != Kind.finite)
            return rank(kind) - rank(other.kind);

        BigInt a = digits, b = other.digits;    // mutable copies: this method is const
        if (scale < other.scale)      a *= BigInt(10) ^^ (other.scale - scale);
        else if (other.scale < scale) b *= BigInt(10) ^^ (scale - other.scale);
        return a < b ? -1 : (a > b ? 1 : 0);
    }

    /// By value, as SQL has it: 1.10 == 1.1, and NaN == NaN.
    bool opEquals(const Numeric other) const
    {
        if (kind == Kind.nan || other.kind == Kind.nan) return kind == other.kind;
        return opCmp(other) == 0;
    }

    /// Consistent with opEquals: trailing zeros are dropped first, so 1.10 and 1.1 hash alike.
    size_t toHash() const nothrow @trusted
    {
        if (kind != Kind.finite) return hashOf(kind);
        try
        {
            BigInt d = digits;
            int s = scale;
            while (s > 0 && d % 10 == 0) { d /= 10; --s; }
            return hashOf(s, d.toHash);
        }
        catch (Exception) return 0;   // BigInt arithmetic does not actually throw
    }


    private static int rank(Kind k)
    {
        final switch (k)
        {
            case Kind.negInf:  return -2;
            case Kind.finite:  return 0;
            case Kind.posInf:  return 2;
            case Kind.nan:     return 3;   // Postgres sorts NaN above everything,
                                           // Infinity included — verified on the server
        }
    }

    /// The approximation, when an approximation is what you want. Lossy by nature.
    double toDouble() const
    {
        final switch (kind)
        {
            case Kind.nan:    return double.nan;
            case Kind.posInf: return double.infinity;
            case Kind.negInf: return -double.infinity;
            case Kind.finite: return toString().to!double;
        }
    }
}

unittest
{
    // the text the server sent survives untouched, trailing zeros included
    foreach (text; ["0", "1", "-1", "0.1", "1.10", "1234567.89", "-0.001",
                    "123456789012345678901234567890.123", "9007199254740993",
                    "NaN", "Infinity", "-Infinity"])
        assert(Numeric(text).toString == text, text ~ " → " ~ Numeric(text).toString);

    // exponent notation on the way in, plain decimal on the way out
    assert(Numeric("1e3").toString == "1000");
    assert(Numeric("1.5e2").toString == "150");
    assert(Numeric("15e-2").toString == "0.15");
    assert(Numeric("1e+2").toString == "100");

    // malformed text is a PgException like every other parse failure, and an
    // exponent past anything Postgres can store is refused, not allocated
    foreach (bad; ["1e", "1e+", "e5", "1ex", "1e1000000000", "1e-1000000000"])
        assert(collectException!PgException(Numeric(bad)) !is null, bad);

    // comparison is by value, not by text
    assert(Numeric("1.10") == Numeric("1.1"));
    assert(Numeric("1.10").toString != Numeric("1.1").toString);
    assert(Numeric("2") > Numeric("1.999999999999999999999"));
    assert(Numeric("-0.001") < Numeric("0"));
    assert(Numeric("Infinity") > Numeric("999999999999999999999999"));
    // Postgres numeric is not IEEE here: NaN equals NaN and sorts above
    // everything, Infinity included. Checked against the server.
    assert(Numeric("NaN") == Numeric("NaN"));
    assert(Numeric("NaN") > Numeric("Infinity"));
    assert(Numeric("Infinity") > Numeric("1"));
    assert(Numeric("-Infinity") < Numeric("-1e30"));

    // and the loss it exists to avoid
    assert("%.17g".format(Numeric("0.1").toDouble) != "0.1");
    assert(Numeric("9007199254740993").toString != "%.17g".format(Numeric("9007199254740993").toDouble));
}

// ────────────────────────────────────────────── bytea, json, interval, time ─

/// Decodes the `\x…` text Postgres writes for bytea. libpq also understands the
/// older escape format, so the decoding is left to it.
private ubyte[] parseBytea(const(char)[] s)
{
    auto text = s.idup.toStringz;
    size_t length;
    auto decoded = PQunescapeBytea(cast(const(ubyte)*) text, &length);
    pgEnforce(decoded !is null, "bytea: could not decode " ~ s.idup);
    scope(exit) PQfreemem(decoded);
    return decoded[0 .. length].dup;
}

private string byteaLiteral(const(ubyte)[] bytes)
{
    auto app = appender!string();
    app.reserve(2 + bytes.length * 2);
    app ~= `\x`;
    foreach (b; bytes) app ~= format!"%02x"(b);
    return app.data;
}

/**
 * Turns the interval text Postgres writes into a Duration.
 *
 * Years and months are refused on purpose: a month is not a fixed length of
 * time — it is 28 to 31 days depending on which one — so there is no honest
 * Duration for `1 mon`. Read such an interval as a string, or ask the server to
 * resolve it against a date.
 */
private Duration parseInterval(const(char)[] source)
{
    auto text = source.strip;
    pgEnforce(text.length > 0, "empty interval");

    Duration total;
    size_t i;

    // The leading part is "<n> <unit>" repeated: 1 year 2 mons 3 days
    while (i < text.length)
    {
        immutable start = i;
        if (text[i] == '-' || text[i] == '+') ++i;
        while (i < text.length && text[i].isDigit) ++i;
        if (i == start) break;                       // no number here

        // a ':' means we reached the clock part, which is not "<n> <unit>"
        if (i < text.length && text[i] == ':') { i = start; break; }

        immutable amount = text[start .. i].to!long;
        while (i < text.length && text[i] == ' ') ++i;

        immutable unitStart = i;
        while (i < text.length && text[i].isAlpha) ++i;
        const unit = text[unitStart .. i];
        if (unit.length == 0) { i = start; break; }

        switch (unit)
        {
            case "year", "years", "mon", "mons", "month", "months":
                throw new PgException("interval '" ~ source.idup ~ "' counts months, "
                    ~ "which are not a fixed length of time: read it as a string, or "
                    ~ "have the server resolve it against a date");
            case "day", "days":       total += amount.days;    break;
            case "hour", "hours":     total += amount.hours;   break;
            case "min", "mins", "minute", "minutes": total += amount.minutes; break;
            case "sec", "secs", "second", "seconds": total += amount.seconds; break;
            default:
                throw new PgException("interval '" ~ source.idup ~ "': unknown unit '"
                                      ~ unit.idup ~ "'");
        }
        while (i < text.length && text[i] == ' ') ++i;
    }

    // What is left, if anything, is a clock part: [-]HH:MM:SS[.ffffff]
    if (i < text.length)
        total += parseClock(text[i .. $], source);

    return total;
}

/// [-]HH:MM:SS[.ffffff], the tail of an interval and the whole of a `time`.
private Duration parseClock(const(char)[] text, const(char)[] whole)
{
    bool negative;
    if (text.length && (text[0] == '-' || text[0] == '+'))
    {
        negative = text[0] == '-';
        text = text[1 .. $];
    }

    auto parts = text.split(':');
    pgEnforce(parts.length == 3, "cannot read '" ~ whole.idup ~ "' as a time span");

    auto seconds = parts[2].split('.');
    auto span = parts[0].to!long.hours
              + parts[1].to!long.minutes
              + seconds[0].to!long.seconds;

    if (seconds.length > 1)
    {
        // pad or trim to microseconds, which is all Postgres keeps
        auto fraction = seconds[1].idup;
        if (fraction.length < 6) fraction ~= "0".replicate(6 - fraction.length);
        span += fraction[0 .. 6].to!long.usecs;
    }

    return negative ? -span : span;
}

private TimeOfDay parseTimeOfDay(const(char)[] source)
{
    auto parts = source.strip.split('.');
    auto clock = TimeOfDay.fromISOExtString(parts[0]);

    // TimeOfDay has no room for a fraction; dropping a real one silently would
    // be a wrong answer, so say so and point at what can hold it.
    if (parts.length > 1)
        pgEnforce(parts[1].all!(c => c == '0'),
                  "time '" ~ source.idup ~ "' has a fractional second, which TimeOfDay "
                  ~ "cannot hold: read it as a Duration since midnight instead");

    return clock;
}

private string intervalLiteral(Duration d)
{
    // Total microseconds is exact for a Duration and unambiguous for Postgres.
    immutable us = d.total!"usecs";
    return format!"%d microseconds"(us);
}

unittest
{
    assert(parseInterval("3 days") == 3.days);
    assert(parseInterval("1 day 02:30:00") == 1.days + 2.hours + 30.minutes);
    assert(parseInterval("01:30:00") == 90.minutes);
    assert(parseInterval("-00:00:01.25") == -(1.seconds + 250_000.usecs));
    assert(parseInterval("00:00:00.5") == 500_000.usecs);
    assert(parseInterval("2 days -01:00:00") == 2.days - 1.hours);

    // months have no fixed length, so they are refused rather than guessed
    bool threw;
    try parseInterval("1 mon");
    catch (PgException) threw = true;
    assert(threw);

    assert(parseTimeOfDay("14:30:00") == TimeOfDay(14, 30, 0));
    assert(parseTimeOfDay("14:30:00.000") == TimeOfDay(14, 30, 0));
    threw = false;
    try parseTimeOfDay("14:30:00.123456");
    catch (PgException) threw = true;
    assert(threw);

    assert(byteaLiteral([0x63, 0x69, 0x61, 0x6f]) == `\x6369616f`);
    assert(byteaLiteral([]) == `\x`);
}

// ──────────────────────────────────────────────────────────────── arrays ────
//
// Postgres writes an array as {a,b,c}, quoting an element only when it has to:
// when it is empty, contains a brace, comma, quote, backslash or space, or would
// otherwise read as the word NULL. Inside quotes, " and \ are backslash-escaped.
// An unquoted NULL is the null element; a quoted one is the four-letter string.

/// Splits an array literal into its elements. Null elements come back null.
private Nullable!string[] arrayElements(const(char)[] s)
{
    pgEnforce(s.length >= 2 && s[0] == '{' && s[$ - 1] == '}',
              "not a Postgres array literal: " ~ s.idup);

    Nullable!string[] items;
    immutable end = s.length - 1;
    size_t i = 1;

    while (i < end)
    {
        pgEnforce(s[i] != '{', "nested arrays are not supported");

        bool quoted = s[i] == '"';
        string piece;

        if (quoted)
        {
            auto app = appender!string();
            for (++i; i < end && s[i] != '"'; ++i)
            {
                if (s[i] == '\\' && i + 1 < end) ++i;
                app ~= s[i];
            }
            ++i;                          // past the closing quote
            piece = app.data;
        }
        else
        {
            immutable start = i;
            while (i < end && s[i] != ',') ++i;
            piece = s[start .. i].idup;
        }

        items ~= (!quoted && piece == "NULL") ? Nullable!string.init
                                              : Nullable!string(piece);
        if (i < end && s[i] == ',') ++i;
    }
    return items;
}

private string arrayLiteral(T)(T items)
{
    auto app = appender!string();
    app ~= '{';

    foreach (i, item; items)
    {
        if (i) app ~= ',';

        static if (is(typeof(item) == typeof(null)))
            app ~= "NULL";
        else static if (isInstanceOf!(Nullable, typeof(item)))
        {
            if (item.isNull) app ~= "NULL";
            else app ~= quoteElement(toText(item.get));
        }
        else app ~= quoteElement(toText(item));
    }

    app ~= '}';
    return app.data;
}

private string quoteElement(string s)
{
    bool plain = s.length > 0 && s.toUpper != "NULL";
    if (plain)
        foreach (c; s)
            if (c == '{' || c == '}' || c == ',' || c == '"' || c == '\\' || c.isWhite)
            {
                plain = false;
                break;
            }
    if (plain) return s;

    auto app = appender!string();
    app ~= '"';
    foreach (c; s)
    {
        if (c == '"' || c == '\\') app ~= '\\';
        app ~= c;
    }
    app ~= '"';
    return app.data;
}

unittest
{
    // round trip through the literal form, including everything that needs quoting
    assert(arrayLiteral([1, 2, 3]) == "{1,2,3}");
    assert(arrayLiteral(cast(int[]) []) == "{}");
    assert(arrayLiteral(["a", "b"]) == "{a,b}");
    assert(arrayLiteral(["with space"]) == `{"with space"}`);
    assert(arrayLiteral(["with,comma"]) == `{"with,comma"}`);
    assert(arrayLiteral([`say "hi"`]) == `{"say \"hi\""}`);
    assert(arrayLiteral([`back\slash`]) == `{"back\\slash"}`);
    assert(arrayLiteral([""]) == `{""}`);
    assert(arrayLiteral(["NULL"]) == `{"NULL"}`);        // the string, not the null
    assert(arrayLiteral([Nullable!int(1), Nullable!int.init]) == "{1,NULL}");
    assert(arrayLiteral([true, false]) == "{t,f}");

    assert(fromText!(int[])("{1,2,3}") == [1, 2, 3]);
    assert(fromText!(int[])("{}") == []);
    assert(fromText!(string[])("{a,b}") == ["a", "b"]);
    assert(fromText!(string[])(`{"with,comma",plain}`) == ["with,comma", "plain"]);
    assert(fromText!(string[])(`{"say \"hi\"","back\\slash"}`) == [`say "hi"`, `back\slash`]);
    assert(fromText!(string[])(`{""}`) == [""]);
    assert(fromText!(string[])(`{"NULL"}`) == ["NULL"]);

    auto withNulls = fromText!(Nullable!(int)[])("{1,NULL,3}");
    assert(withNulls.length == 3 && withNulls[0].get == 1
           && withNulls[1].isNull && withNulls[2].get == 3);

    // a null element in a non-nullable array is an error, not a zero
    bool threw = false;
    try fromText!(int[])("{1,NULL}");
    catch (PgException) threw = true;
    assert(threw);
}

/**
 * Postgres prints "2026-09-17 14:23:45.12+02", SysTime wants "2026-09-17T14:23:45.12+02:00".
 *
 * A `timestamp without time zone` has no offset to go by and is read as UTC,
 * which is also how a SysTime is written: the round trip holds whatever the
 * time zone of the client or of the session.
 */
private SysTime parseTimestamp(const(char)[] source)
{
    string t = source.idup;
    pgEnforce(!t.endsWith("infinity"),
              "timestamp '" ~ t ~ "' is infinite, which SysTime cannot hold: read it as a string");
    pgEnforce(!t.endsWith(" BC"),
              "timestamp '" ~ t ~ "' is before year 1, which SysTime cannot hold: read it as a string");

    auto space = t.indexOf(' ');
    if (space >= 0) t = t[0 .. space] ~ "T" ~ t[space + 1 .. $];

    foreach_reverse (i; 0 .. t.length)
    {
        if (t[i] == 'T') { t ~= "Z"; break; }    // no offset: timestamp without time zone
        if (t[i] == '+' || t[i] == '-')
        {
            auto width = t.length - i;           // "+02" → 3, "+0200" → 5
            if (width == 3)      t ~= ":00";
            else if (width == 5) t = t[0 .. i + 3] ~ ":" ~ t[i + 3 .. $];
            break;
        }
    }
    return SysTime.fromISOExtString(t);
}

unittest
{
    // A SysTime in local time goes out with an explicit offset; without one the
    // server would read the wall clock in ITS session time zone, not ours.
    auto local = SysTime(DateTime(2026, 1, 1, 12, 0, 0), LocalTime());
    auto text = toText(local);
    assert(text.endsWith("Z") || text[$ - 6] == '+' || text[$ - 6] == '-', text);
    assert(SysTime.fromISOExtString(text) == local);

    // timestamp without time zone is read as UTC, the same on every machine
    auto plain = parseTimestamp("2026-09-17 14:23:45");
    assert(plain.timezone is UTC(), plain.timezone.name);
    assert(plain == SysTime(DateTime(2026, 9, 17, 14, 23, 45), UTC()));

    // with an offset, the offset wins
    assert(parseTimestamp("2026-09-17 14:23:45+02")
           == SysTime(DateTime(2026, 9, 17, 12, 23, 45), UTC()));

    // what SysTime cannot hold is a PgException that says so
    foreach (bad; ["infinity", "-infinity", "0044-03-15 12:00:00 BC"])
        assert(collectException!PgException(parseTimestamp(bad)) !is null, bad);
}

// ─────────────────────────────────────────────────────────────────── Row ────

/**
 * One row. Also a copyable view, and it too keeps its PGresult alive.
 *
 * A Row kept in GC memory — an array, a closure — holds its whole result until
 * the GC collects it, and the GC cannot see how big that is: libpq allocates it
 * with malloc. For large results, keep the values (`as!T`), not the rows.
 */
struct Row
{
    private ResultRef owner;   // the reference that keeps `res` alive
    private PGresult* res;
    private int row;

    private this(ResultRef owner, int row)
    {
        this.owner = owner;
        this.res = owner.res;
        this.row = row;
    }

    /// How many columns the row has.
    @property int length() { return PQnfields(res); }

    /// A column by position, from 0.
    Field opIndex(int col)
    {
        pgEnforce(col >= 0 && col < PQnfields(res),
                  "column " ~ col.to!string ~ " out of range (the result has "
                  ~ PQnfields(res).to!string ~ ")");
        return Field(owner, row, col);
    }

    /// A column by name.
    Field opIndex(string columnName)
    {
        auto col = columnIndex(res, columnName);
        pgEnforce(col >= 0, "no column named '" ~ columnName ~ "' in the result");
        return Field(owner, row, col);
    }

    /// Every column, as a range of `Field`.
    @property auto fields() { return iota(length).map!(i => Field(owner, row, i)); }

    /// Compile-time mapping onto a struct: every member looks up the column of the same name.
    T as(T)() if (is(T == struct) && !is(T == Row) && !is(T == Field))
    {
        T value;
        foreach (i, ref member; value.tupleof)
        {
            enum columnName = columnNameOf!(T, i);
            auto col = columnIndex(res, columnName);
            pgEnforce(col >= 0, "mapping onto " ~ T.stringof ~ ": no column named '"
                                ~ columnName ~ "' in the result");
            member = Field(owner, row, col).as!(typeof(member));
        }
        return value;
    }

    /// `[name: value, ...]`, for debugging.
    string toString()
    {
        auto app = appender!string();
        app ~= "[";
        foreach (i; 0 .. length)
        {
            if (i) app ~= ", ";
            app ~= PQfname(res, i).fromStringz;
            app ~= "=";
            app ~= Field(owner, row, i).toString;
        }
        app ~= "]";
        return app.data;
    }
}

/**
 * The column called exactly `name`, or failing that the one PQfnumber finds.
 *
 * PQfnumber reads its argument as SQL would, folding it to lower case unless
 * it is quoted, so on its own it can never find `as "createdAt"` by that name.
 * Asking for the quoted form first gets the exact match; the plain call after
 * it keeps the case-insensitive lookup working for everything else.
 */
private int columnIndex(PGresult* res, string name)
{
    immutable exact = PQfnumber(res, ('"' ~ name.replace(`"`, `""`) ~ '"').toStringz);
    return exact >= 0 ? exact : PQfnumber(res, name.toStringz);
}

private template columnNameOf(T, size_t i)
{
    alias udas = getUDAs!(T.tupleof[i], Column);
    static if (udas.length) enum columnNameOf = udas[0].name;
    else                    enum columnNameOf = __traits(identifier, T.tupleof[i]);
}

// ──────────────────────────────────────────────────────── Result + Rows ─────

private struct ResultState
{
    PGresult* res;

    // How many PGresults are alive, so the tests can check ownership instead
    // of hoping a use-after-free happens to show.
    version (unittest) static int live;

    this(PGresult* res)
    {
        this.res = res;
        version (unittest) if (res) ++live;
    }

    ~this()
    {
        if (res)
        {
            PQclear(res);
            res = null;
            version (unittest) --live;
        }
    }
}

private alias ResultRef = RefCounted!(ResultState, RefCountedAutoInitialize.no);

/// A copyable view over a result's rows: a full RandomAccessRange.
struct Rows
{
    private ResultRef state;
    private size_t first, last;

    /// Range primitives.
    @property bool empty() { return first >= last; }
    /// ditto
    @property Row front() { return Row(state, cast(int) first); }
    /// ditto
    void popFront() { ++first; }
    /// ditto
    @property Row back() { return Row(state, cast(int)(last - 1)); }
    /// ditto
    void popBack() { --last; }
    /// ditto
    @property Rows save() { return this; }
    /// ditto
    @property size_t length() { return last - first; }
    /// ditto
    Row opIndex(size_t i) { return Row(state, cast(int)(first + i)); }
    /// ditto
    Rows opSlice(size_t a, size_t b) { return Rows(state, first + a, first + b); }
    /// ditto
    alias opDollar = length;
}

/// Owns the PGresult via a reference count, allowing safe use with lazy ranges.
struct Result
{
    private ResultRef state;

    private this(PGresult* res)
    {
        state = ResultRef(res);
    }

    /// The view. `alias rows this` lets the Result itself act as a range.
    @property Rows rows() { return Rows(state, 0, PQntuples(state.res)); }
    alias rows this;

    /**
     * `foreach` straight over the Result. Since `.rows` is now ref-counted, 
     * `foreach (row; conn.exec(…).rows)` is also completely safe.
     */
    int opApply(scope int delegate(Row) dg)
    {
        immutable n = PQntuples(state.res);
        foreach (i; 0 .. n)
            if (auto stop = dg(Row(state, i)))
                return stop;
        return 0;
    }

    /// Rows touched by insert/update/delete. PQcmdTuples yields "" for commands that touch none.
    @property long affected()
    {
        auto s = PQcmdTuples(state.res).fromStringz;
        return s.length ? s.to!long : 0;
    }

    /// The full diagnostic string: "UPDATE 3", "INSERT 0 1", "CREATE TABLE".
    @property string cmdStatus() { return PQcmdStatus(state.res).fromStringz.idup; }

    /// Whether the statement returns rows (a select, or anything with `returning`).
    @property bool hasRows() { return PQresultStatus(state.res) == PGRES_TUPLES_OK; }

    /// Touching zero rows is NOT an error for Postgres; this makes it one.
    ref Result expect(long expected) return
    {
        auto actual = affected;
        pgEnforce(actual == expected, "expected " ~ expected.to!string
                  ~ " modified rows, got " ~ actual.to!string);
        return this;
    }

    /// First column of the first row.
    T scalar(T = string)()
    {
        pgEnforce(PQntuples(state.res) > 0, "scalar: the result has no rows");
        pgEnforce(PQnfields(state.res) > 0, "scalar: the result has no columns");
        return Field(state, 0, 0).as!T;
    }
}

unittest
{
    // A result built by libpq itself, no server needed.
    auto command = Result(PQmakeEmptyPGresult(null, PGRES_COMMAND_OK));
    assert(!command.hasRows);
    assert(command.cmdStatus == "");
    assert(command.affected == 0);

    auto empty = Result(PQmakeEmptyPGresult(null, PGRES_TUPLES_OK));
    assert(empty.hasRows);
    assert(empty.empty);
    assert(collectException!PgException(empty.scalar!int) !is null);
}

// ─────────────────────────────────── placeholder translation :name → $n ─────

private struct TranslatedSql
{
    string sql;
    int[string] names;   // name → 1-based index
    int count;           // number of parameters
}

/**
 * Rewrites named placeholders `:name` into positional `$n`, leaving alone
 * everything else that legitimately contains ':' or '$': string literals,
 * quoted identifiers, dollar quoting, comments, the `::type` cast and the
 * plpgsql `:=` assignment. A repeated name maps to a single $n.
 */
private TranslatedSql translatePlaceholders(string sql)
{
    auto output = appender!string();
    int[string] names;
    int count = 0;
    bool positional;     // a $n was seen
    size_t i = 0;

    while (i < sql.length)
    {
        immutable ch = sql[i];

        // line comment
        if (ch == '-' && i + 1 < sql.length && sql[i + 1] == '-')
        {
            auto nl = sql.indexOf('\n', i);
            immutable stop = nl < 0 ? sql.length : cast(size_t)(nl + 1);
            output ~= sql[i .. stop];
            i = stop;
            continue;
        }

        // block comment (nestable in Postgres)
        if (ch == '/' && i + 1 < sql.length && sql[i + 1] == '*')
        {
            int depth = 0;
            size_t j = i;
            while (j < sql.length)
            {
                if (sql[j] == '/' && j + 1 < sql.length && sql[j + 1] == '*') { ++depth; j += 2; }
                else if (sql[j] == '*' && j + 1 < sql.length && sql[j + 1] == '/')
                {
                    --depth; j += 2;
                    if (depth == 0) break;
                }
                else ++j;
            }
            output ~= sql[i .. j];
            i = j;
            continue;
        }

        // '...' literal with embedded '', and "..." identifier with embedded "".
        // An E'...' string also takes backslash escapes, so \' does not end it.
        if (ch == '\'' || ch == '"')
        {
            immutable escapes = ch == '\'' && i > 0 && (sql[i - 1] == 'E' || sql[i - 1] == 'e')
                                && !(i > 1 && isIdentifierChar(sql[i - 2]));
            size_t j = i + 1;
            while (j < sql.length)
            {
                if (escapes && sql[j] == '\\') j += 2;
                else if (sql[j] == ch)
                {
                    if (j + 1 < sql.length && sql[j + 1] == ch) j += 2;
                    else { ++j; break; }
                }
                else ++j;
            }
            if (j > sql.length) j = sql.length;   // an unterminated E'...\
            output ~= sql[i .. j];
            i = j;
            continue;
        }

        if (ch == '$')
        {
            size_t j = i + 1;
            while (j < sql.length && (sql[j].isAlphaNum || sql[j] == '_')) ++j;
            immutable body_ = sql[i + 1 .. j];
            immutable allDigits = body_.length > 0 && body_.all!isDigit;

            // $tag$ ... $tag$ (and $$ ... $$): skip the whole block
            if (j < sql.length && sql[j] == '$' && !allDigits)
            {
                immutable tag = sql[i .. j + 1];
                auto end = sql.indexOf(tag, j + 1);
                immutable stop = end < 0 ? sql.length : cast(size_t)(end) + tag.length;
                output ~= sql[i .. stop];
                i = stop;
                continue;
            }

            // $1, $2, ...: already positional, just keep count
            if (allDigits)
            {
                positional = true;
                immutable k = body_.to!int;
                if (k > count) count = k;
            }
            output ~= sql[i .. j];
            i = j;
            continue;
        }

        if (ch == ':')
        {
            // ::type cast and plpgsql := assignment
            if (i + 1 < sql.length && (sql[i + 1] == ':' || sql[i + 1] == '='))
            {
                output ~= sql[i .. i + 2];
                i += 2;
                continue;
            }

            // right after a name, a number or a closing bracket, a ':' is an
            // array slice bound — a[lo:hi], a[1:n] — not a parameter
            immutable afterOperand = i > 0 && (isIdentifierChar(sql[i - 1])
                                               || sql[i - 1] == ']' || sql[i - 1] == ')');

            size_t j = i + 1;
            if (!afterOperand && j < sql.length && (sql[j].isAlpha || sql[j] == '_'))
            {
                while (j < sql.length && (sql[j].isAlphaNum || sql[j] == '_')) ++j;
                immutable name = sql[i + 1 .. j];
                int k;
                if (auto found = name in names) k = *found;
                else { k = ++count; names[name] = k; }
                output ~= "$";
                output ~= k.to!string;
                i = j;
                continue;
            }
        }

        output ~= ch;
        ++i;
    }

    // Named ones are numbered from 1 without looking at the positional ones, so
    // "select :x, $1" would silently make :x and $1 the same value.
    pgEnforce(!positional || names.length == 0,
              "mixing :name and $n placeholders in one statement: use one or the other");

    return TranslatedSql(output.data, names, count);
}

private bool isIdentifierChar(char c) { return c.isAlphaNum || c == '_' || c == '$'; }

unittest
{
    // plain named placeholders; a repeated name collapses onto one $n
    auto t = translatePlaceholders("select * from u where a = :x and (b = :y or c = :x)");
    assert(t.sql == "select * from u where a = $1 and (b = $2 or c = $1)");
    assert(t.count == 2 && t.names["x"] == 1 && t.names["y"] == 2);

    // a :: cast is not a parameter
    assert(translatePlaceholders("select :v::int").sql == "select $1::int");
    assert(translatePlaceholders("select 1::int").count == 0);

    // nothing inside a string literal is touched
    assert(translatePlaceholders("select ':not_a_param', :real").sql == "select ':not_a_param', $1");
    assert(translatePlaceholders("select 'it''s 8:30'").count == 0);

    // quoted identifier
    assert(translatePlaceholders(`select "odd:column" from t where x = :v`).sql
           == `select "odd:column" from t where x = $1`);

    // dollar quoting
    assert(translatePlaceholders("do $$ begin raise notice ':nothing'; end $$").count == 0);
    assert(translatePlaceholders("select $tag$ :nothing $tag$, :something").sql
           == "select $tag$ :nothing $tag$, $1");

    // comments
    assert(translatePlaceholders("-- :nothing\nselect :v").sql == "-- :nothing\nselect $1");
    assert(translatePlaceholders("/* :nothing */ select :v").sql == "/* :nothing */ select $1");

    // plpgsql :=
    assert(translatePlaceholders("x := 3; select :v").sql == "x := 3; select $1");

    // already positional
    auto p = translatePlaceholders("select * from u where a = $1 and b = $2");
    assert(p.count == 2 && p.sql == "select * from u where a = $1 and b = $2");

    // :name and $n in the same statement would share slots: refused, in either order
    assert(collectException!PgException(translatePlaceholders("select :x, $1")) !is null);
    assert(collectException!PgException(translatePlaceholders("select $1, :x")) !is null);

    // E'' strings escape with a backslash, so \' does not close them
    assert(translatePlaceholders(`select E'it\'s :x'`).count == 0);
    assert(translatePlaceholders(`select e'a\\', :v`).sql == `select e'a\\', $1`);
    // ...but a plain '' string ending in a backslash is still just a string
    assert(translatePlaceholders(`select 'a\', :v`).sql == `select 'a\', $1`);
    // and an identifier ending in e is not an E'' prefix
    assert(translatePlaceholders(`select name'x\', :v`).count == 1);
    assert(translatePlaceholders(`select E'unterminated\`).count == 0);

    // array slices are not parameters
    assert(translatePlaceholders("select a[lo:hi] from t").sql == "select a[lo:hi] from t");
    assert(translatePlaceholders("select a[1:n], a[:i]").sql == "select a[1:n], a[$1]");
}

// ───────────────────────────────────────────────────────────────── Query ────

private string toText(T)(T value)
{
    static if (is(T : const(char)[]))    return value.idup;
    else static if (is(T == bool))       return value ? "t" : "f";
    else static if (is(T == Date))       return value.toISOExtString;
    else static if (is(T == SysTime))    return value.toUTC.toISOExtString;   // "…Z": no session-zone guessing
    else static if (is(T == Numeric))    return value.toString;
    else static if (is(T == JSONValue))  return value.toString;
    else static if (is(T == TimeOfDay))  return value.toISOExtString;
    else static if (is(T == Duration))   return intervalLiteral(value);
    else static if (is(T == ubyte[]) || is(T == const(ubyte)[]) || is(T == immutable(ubyte)[]))
                                         return byteaLiteral(value);
    else static if (isArray!T)           return arrayLiteral(value);
    else                                 return value.to!string;
}

/**
 * A builder: it accumulates bindings at runtime and only hands everything to
 * libpq on exec(). Values ALWAYS travel outside the SQL text, so they can
 * never turn into syntax.
 */
struct Query
{
    private Connection* conn;
    private string sql;            // already translated to $n
    private string preparedName;   // non-null → PQexecPrepared under this name
    private int[string] names;
    private int count;
    private string[] values;
    private bool[] nulls, bound;

    private this(Connection* conn, string sourceSql)
    {
        this.conn = conn;
        auto t = translatePlaceholders(sourceSql);
        this.sql = t.sql;
        this.names = t.names;
        this.count = t.count;
        allocateSlots();
    }

    private this(Connection* conn, string preparedName, int[string] names, int count)
    {
        this.conn = conn;
        this.preparedName = preparedName;
        this.names = names;
        this.count = count;
        allocateSlots();
    }

    private void allocateSlots()
    {
        values.length = count;
        nulls.length = count;
        bound.length = count;
    }

        // A value travels to libpq as a C string, so a NUL inside it would silently
    // end it early. Text in Postgres cannot hold a NUL anyway: refuse it here.
    private static string parameterText(T)(T value)
    {
        auto text = toText(value);
        pgEnforce(!text.canFind('\0'), "a parameter contains a NUL byte, which Postgres text "
                  ~ "cannot hold: send binary data as ubyte[] (bytea)");
        return text;
    }

    /// Positional binding: .bind(1, 18)
    ref Query bind(T)(int position, T value) return
    {
        pgEnforce(position >= 1 && position <= count,
                  "no parameter $" ~ position.to!string ~ " (this query has "
                  ~ count.to!string ~ ")");
        immutable slot = position - 1;
        bound[slot] = true;

        static if (is(T == typeof(null)))
        {
            nulls[slot] = true;
            values[slot] = null;
        }
        else static if (isInstanceOf!(Nullable, T))
        {
            if (value.isNull) { nulls[slot] = true; values[slot] = null; }
            else              { nulls[slot] = false; values[slot] = parameterText(value.get); }
        }
        else
        {
            nulls[slot] = false;
            values[slot] = parameterText(value);
        }
        return this;
    }

    /// Named binding: .bind("age", 18), .bind(":age", 18), .bind("$1", 18)
    ref Query bind(T)(string placeholder, T value) return
    {
        auto name = placeholder.startsWith(":") ? placeholder[1 .. $] : placeholder;
        if (name.startsWith("$"))
            return bind(name[1 .. $].to!int, value);
        auto slot = name in names;
        pgEnforce(slot !is null, "no parameter ':" ~ name ~ "' in this query");
        return bind(*slot, value);
    }

    /// Clears the bindings so the same Query can be reused with other values.
    ref Query reset() return
    {
        foreach (slot; 0 .. count)
        {
            bound[slot] = false;
            nulls[slot] = false;
            values[slot] = null;
        }
        return this;
    }

    private void checkAllBound()
    {
        foreach (slot; 0 .. count)
            if (!bound[slot])
            {
                string name;
                foreach (candidate, index; names) if (index == slot + 1) name = candidate;
                throw new PgException("parameter $" ~ (slot + 1).to!string
                    ~ (name.length ? " (:" ~ name ~ ")" : "") ~ " was never bound");
            }
    }

    // `keep` holds the NUL-terminated strings alive for the duration of the libpq call.
    private const(char)*[] valuePointers(ref string[] keep)
    {
        keep.length = count;
        auto pointers = new const(char)*[count];
        foreach (slot; 0 .. count)
        {
            if (nulls[slot]) pointers[slot] = null;      // a null pointer means SQL NULL
            else
            {
                keep[slot] = values[slot] ~ "\0";
                pointers[slot] = keep[slot].ptr;
            }
        }
        return pointers;
    }

    /// Runs the query and loads the whole result into memory.
    Result exec()
    {
        checkAllBound();
        conn.ensureIdle();
        string[] keep;
        auto pointers = valuePointers(keep);

        PGresult* res;
        if (preparedName is null)
            res = PQexecParams(conn.handle, sql.toStringz, count, null,
                               count ? pointers.ptr : null, null, null, 0);
        else
            res = PQexecPrepared(conn.handle, preparedName.toStringz, count,
                                 count ? pointers.ptr : null, null, null, 0);

        checkResult(conn.handle, res);
        return Result(res);
    }

    /// Runs the statement and returns the first column of the first row.
    T scalar(T = string)() { return exec().scalar!T; }

    /**
     * Runs the query incrementally: the range yields one row at a time and
     * memory stays bounded, whatever the size of the result set.
     *
     * `chunkSize` is how many rows libpq materialises per round of work, not
     * how many the range hands you at once — that is always one. Larger chunks
     * mean fewer allocations and less per-row overhead, at the cost of holding
     * that many rows at a time. `chunkSize <= 1` asks for strict single-row
     * mode. Against a libpq older than 17 the parameter is ignored and
     * single-row mode is used regardless; see `hasChunkedRows`.
     */
    auto stream(T = Row)(int chunkSize = defaultChunkSize)
    {
        checkAllBound();
        conn.ensureIdle();

        string[] keep;
        auto pointers = valuePointers(keep);

        int sent;
        if (preparedName is null)
            sent = PQsendQueryParams(conn.handle, sql.toStringz, count, null,
                                     count ? pointers.ptr : null, null, null, 0);
        else
            sent = PQsendQueryPrepared(conn.handle, preparedName.toStringz, count,
                                       count ? pointers.ptr : null, null, null, 0);

        pgEnforce(sent == 1, "could not send the query: " ~ lastError(conn.handle));

        bool chunked;
        static if (hasChunkedRows) chunked = chunkSize > 1;

        int modeSet;
        static if (hasChunkedRows)
            modeSet = chunked ? PQsetChunkedRowsMode(conn.handle, chunkSize)
                              : PQsetSingleRowMode(conn.handle);
        else
            modeSet = PQsetSingleRowMode(conn.handle);

        if (modeSet != 1)
        {
            // The query is already on its way: its results have to be read
            // off, or the connection stays stuck behind them.
            auto msg = lastError(conn.handle);
            drainResults(conn.handle);
            throw new PgException("could not enable " ~ (chunked ? "chunked-rows" : "single-row")
                                  ~ " mode: " ~ msg);
        }
        conn.busy = true;

        return RowStream!T(conn);
    }
}

// ─────────────────────────────────────────────────────── lazy streaming ─────

private struct StreamState(T)
{
    Connection* conn;
    ResultRef current;  // ref-counted, so rows handed out can outlive the chunk
    int rowIndex;       // position inside the current chunk
    int rowCount;       // rows the current chunk holds (always 1 in single-row mode)

    // Here and not in RowStream, so that every copy of the range sees the
    // same position: a copy left with its own `front` would hold a row whose
    // PGresult another copy has already freed.
    T value;
    bool done = true;

    @disable this(this);

    this(Connection* conn) { this.conn = conn; }

    ~this() { drain(); }

    /// Until the trailing null is read, the connection stays busy and unusable.
    void drain()
    {
        current = ResultRef.init;
        if (conn !is null && conn.busy)
        {
            PGresult* res;
            while ((res = PQgetResult(conn.handle)) !is null) PQclear(res);
            conn.busy = false;
        }
    }
}

/**
 * A lazy InputRange. Copyable (map/filter need that), but every copy shares
 * one cursor — advancing any of them advances all — and the draining happens
 * exactly once, at the last reference: breaking out of a foreach early still
 * leaves the connection clean.
 *
 * Every element owns what it points at — a Row keeps its chunk of the result
 * alive — so .array and friends are safe with T = Row as well. Keeping every
 * row of a big stream does keep all of it in memory, though, which is the one
 * thing streaming is meant to avoid.
 */
struct RowStream(T)
{
    private RefCounted!(StreamState!T, RefCountedAutoInitialize.no) state;

    private this(Connection* conn)
    {
        state = RefCounted!(StreamState!T, RefCountedAutoInitialize.no)(conn);
        advance();
    }

    /// Range primitives.
    @property bool empty()
    {
        return !state.refCountedStore.isInitialized || state.refCountedPayload.done;
    }

    /// ditto
    @property T front() { return state.refCountedPayload.value; }
    /// ditto
    void popFront() { advance(); }

    private static void take(StreamState!T* s)
    {
        auto row = Row(s.current, s.rowIndex);
        static if (is(T == Row)) s.value = row;
        else                     s.value = row.as!T;
    }

    private void advance()
    {
        auto s = &state.refCountedPayload();

        // Still inside the chunk libpq already handed us: no I/O needed. In
        // single-row mode a chunk is one row, so this never fires.
        if (s.current.refCountedStore.isInitialized && s.rowIndex + 1 < s.rowCount)
        {
            ++s.rowIndex;
            take(s);
            return;
        }

        s.current = ResultRef.init;

        // Once finished, the connection may already be running something
        // else: its results are not ours to read.
        if (s.done && !s.conn.busy) return;

        auto res = PQgetResult(s.conn.handle);
        if (res is null) { s.conn.busy = false; s.done = true; return; }

        // The stream can also END in failure: a query that blows up on row
        // 500,000 delivers the rows first and the error afterwards, so every
        // result gets checked, not just the first one.
        immutable status = PQresultStatus(res);
        bool carriesRows = status == PGRES_SINGLE_TUPLE;
        static if (hasChunkedRows)
            carriesRows = carriesRows || status == PGRES_TUPLES_CHUNK;

        if (!carriesRows && status != PGRES_TUPLES_OK && status != PGRES_COMMAND_OK)
        {
            s.done = true;
            auto e = errorFrom(s.conn.handle, res);   // clears res
            s.drain();
            throw e;
        }

        immutable rows = PQntuples(res);
        if (rows > 0)
        {
            s.current = ResultRef(res);
            s.rowIndex = 0;
            s.rowCount = rows;
            s.done = false;
            take(s);
            return;
        }

        // A zero-row result is the terminator, in both modes.
        PQclear(res);
        s.done = true;
        s.drain();
    }
}

// ────────────────────────────────────────────────────────────────── COPY ────

/**
 * A bulk load in progress.
 *
 * COPY is not a statement that returns a result: the server answers it by
 * switching the connection into a data channel, which is why it needs its own
 * type instead of coming out of `exec`. It is also by far the fastest way to
 * get rows in — around six times a batched multi-row INSERT, and far more than
 * that against inserting one row at a time.
 *
 * RAII, like `Transaction`: without `commit` the destructor tells the server
 * the copy failed, and the server writes nothing at all. A load that dies
 * halfway leaves no half-dataset behind.
 */
struct CopyIn
{
    private Connection* conn;
    private bool settled;

    @disable this(this);

    private this(Connection* conn, string statement)
    {
        this.conn = conn;
        conn.ensureIdle();

        auto res = PQexec(conn.handle, statement.toStringz);
        immutable status = PQresultStatus(res);
        if (status != PGRES_COPY_IN)
        {
            if (status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK)
            {
                PQclear(res);
                throw new PgException("that is not a COPY ... FROM STDIN: a COPY from "
                    ~ "a server-side file is an ordinary statement, run it with exec");
            }
            throw errorFrom(conn.handle, res);
        }
        PQclear(res);
        conn.busy = true;
    }

    ~this() { if (!settled) cast(void) collectException(abort("dropped without commit")); }

    /// One row, tab-separated and escaped for you. `null` and an empty Nullable become NULL.
    void writeRow(Args...)(Args values)
    {
        auto line = appender!string();
        foreach (i, value; values)
        {
            if (i) line ~= '\t';

            static if (is(typeof(value) == typeof(null)))
                line ~= `\N`;
            else static if (isInstanceOf!(Nullable, typeof(value)))
            {
                if (value.isNull) line ~= `\N`;
                else line ~= escapeCopy(toText(value.get));
            }
            else line ~= escapeCopy(toText(value));
        }
        line ~= '\n';
        write(line.data);
    }

    /// Raw bytes, for when you format the rows yourself or use `with (format csv)`.
    void write(const(char)[] data)
    {
        pgEnforce(!settled, "this copy is already finished");
        if (data.length == 0) return;
        pgEnforce(PQputCopyData(conn.handle, data.ptr, cast(int) data.length) == 1,
                  "COPY failed while sending: " ~ lastError(conn.handle));
    }

    /// Ends the copy and returns how many rows the server took.
    long commit()
    {
        pgEnforce(!settled, "this copy is already finished");
        settled = true;

        if (PQputCopyEnd(conn.handle, null) != 1)
        {
            auto msg = lastError(conn.handle);
            conn.busy = false;
            drainResults(conn.handle);
            throw new PgException("COPY failed while finishing: " ~ msg);
        }

        long rows;
        auto res = PQgetResult(conn.handle);
        if (res !is null)
        {
            if (PQresultStatus(res) != PGRES_COMMAND_OK)
            {
                conn.busy = false;
                auto failure = errorFrom(conn.handle, res);   // clears res
                drainResults(conn.handle);
                throw failure;
            }
            auto taken = PQcmdTuples(res).fromStringz;
            if (taken.length) rows = taken.to!long;
            PQclear(res);
        }

        conn.busy = false;
        drainResults(conn.handle);
        return rows;
    }

    /// Throws the copy away. The server writes nothing.
    void abort(string why = "aborted by the client")
    {
        if (settled) return;
        settled = true;

        PQputCopyEnd(conn.handle, why.toStringz);   // a non-null message fails it
        conn.busy = false;
        drainResults(conn.handle);                  // the failure result, discarded
    }
}

/// The two the server raises to mean "nothing happened, try again".
bool isRetryable(string sqlstate)
{
    return sqlstate == "40001"     // serialization_failure
        || sqlstate == "40P01";    // deadlock_detected
}

private void drainResults(PGconn* handle)
{
    PGresult* res;
    while ((res = PQgetResult(handle)) !is null) PQclear(res);
}

/// Text-format COPY escapes exactly these.
private string escapeCopy(string s)
{
    if (!s.canFind('\\') && !s.canFind('\t') && !s.canFind('\n') && !s.canFind('\r'))
        return s;

    auto app = appender!string();
    foreach (c; s)
        switch (c)
        {
            case '\\': app ~= `\\`; break;
            case '\t': app ~= `\t`; break;
            case '\n': app ~= `\n`; break;
            case '\r': app ~= `\r`; break;
            default:   app ~= c;
        }
    return app.data;
}

unittest
{
    assert(escapeCopy("plain") == "plain");
    assert(escapeCopy("a\tb") == `a\tb`);
    assert(escapeCopy("a\nb") == `a\nb`);
    assert(escapeCopy(`a\b`) == `a\\b`);
}

private struct CopyOutState
{
    Connection* conn;
    char* buffer;

    // Shared by every copy of the range, as in StreamState.
    const(char)[] line;
    bool done = true;

    @disable this(this);

    this(Connection* conn) { this.conn = conn; }
    ~this() { finish(); }

    void release() { if (buffer) { PQfreemem(buffer); buffer = null; line = null; } }

    void finish()
    {
        release();
        if (conn is null || !conn.busy) return;

        // An early break leaves the connection mid-copy, and while it is there
        // PQgetResult keeps handing back PGRES_COPY_OUT for ever. The rest of
        // the data has to come off the wire first.
        char* chunk;
        while (PQgetCopyData(conn.handle, &chunk, 0) > 0)
            PQfreemem(chunk);

        // The result that closes the copy carries any error the server hit. A
        // destructor must not throw, so one found here is dropped; one found
        // during iteration is thrown by advance().
        auto res = PQgetResult(conn.handle);
        if (res !is null) PQclear(res);
        drainResults(conn.handle);
        conn.busy = false;
    }
}

/**
 * Rows coming out of a COPY, one line at a time.
 *
 * The line is a view over libpq's own buffer and is freed on the next
 * popFront, so copy it if you mean to keep it. As with `stream`, the destructor
 * drains whatever is left, so the connection stays usable after an early break.
 */
struct CopyOut
{
    private RefCounted!(CopyOutState, RefCountedAutoInitialize.no) state;

    private this(Connection* conn)
    {
        state = RefCounted!(CopyOutState, RefCountedAutoInitialize.no)(conn);
        advance();
    }

    /// Range primitives.
    @property bool empty()
    {
        return !state.refCountedStore.isInitialized || state.refCountedPayload.done;
    }

    /// ditto
    @property const(char)[] front() { return state.refCountedPayload.line; }
    /// ditto
    void popFront() { advance(); }

    private void advance()
    {
        auto s = &state.refCountedPayload();
        s.release();

        // Finished: the connection may already be doing something else.
        if (s.done && !s.conn.busy) return;

        char* buffer;
        immutable n = PQgetCopyData(s.conn.handle, &buffer, 0);

        if (n > 0)
        {
            s.buffer = buffer;
            s.line = buffer[0 .. n];
            s.done = false;
            return;
        }

        s.done = true;
        if (n == -2)                       // -2 is a failure, -1 the clean end
        {
            auto msg = lastError(s.conn.handle);
            s.finish();
            throw new PgException("COPY failed while reading: " ~ msg);
        }
        s.finish();
    }
}

// ─────────────────────────────────────────────────────────── Transaction ────

/**
 * How much the transaction is allowed to see of what others are doing.
 *
 * `serverDefault` is whatever `default_transaction_isolation` says, which out
 * of the box is read committed. `serializable` is the one that makes concurrent
 * transactions behave as if they had run one after another — at the price of
 * being told to try again, which is what `transact` is for.
 */
enum Isolation { serverDefault, readCommitted, repeatableRead, serializable }

/// A read-only transaction is refused any write, and says so if one is attempted.
enum Access { readWrite, readOnly }

/// RAII: if you never call commit(), the destructor issues a ROLLBACK.
struct Transaction
{
    private Connection* conn;
    private bool settled;
    private int savepointCounter;

    @disable this(this);

    private this(Connection* conn, Isolation isolation, Access access)
    {
        this.conn = conn;

        auto statement = appender!string("begin");
        final switch (isolation)
        {
            case Isolation.serverDefault:  break;
            case Isolation.readCommitted:  statement ~= " isolation level read committed";  break;
            case Isolation.repeatableRead: statement ~= " isolation level repeatable read"; break;
            case Isolation.serializable:   statement ~= " isolation level serializable";    break;
        }
        if (access == Access.readOnly) statement ~= " read only";

        conn.execScript(statement.data);
    }

    ~this()
    {
        // A destructor must not throw while another exception is unwinding,
        // so a failure here is swallowed on purpose.
        if (!settled && conn !is null)
            cast(void) collectException(conn.execScript("rollback"));
    }

    /**
     * Makes the work permanent. Throws with SQLSTATE 25P02 when an earlier
     * statement had already failed, since the server rolls back instead.
     */
    void commit()
    {
        immutable tag = conn.execStatus("commit");
        settled = true;

        // A COMMIT on a transaction that already failed is answered with a
        // ROLLBACK and no error at all: nothing was saved, so say so.
        if (tag == "ROLLBACK")
            throw new PgException("commit: the transaction had already failed, "
                                  ~ "so the server rolled it back instead", "25P02");
    }

    /// Throws the work away now, rather than at the end of the scope.
    void rollback() { conn.execScript("rollback"); settled = true; }

    /// A restore point: lets you recover from an error without losing everything.
    Savepoint savepoint()
    {
        auto name = "sp_" ~ (++savepointCounter).to!string;
        return Savepoint(conn, name);
    }
}

/// RAII, like Transaction: if you never call release(), the destructor rolls back to it.
struct Savepoint
{
    private Connection* conn;
    private string name;
    private bool settled;

    @disable this(this);

    private this(Connection* conn, string name)
    {
        this.conn = conn;
        this.name = name;
        conn.execScript("savepoint " ~ name);
    }

    ~this()
    {
        if (!settled && conn !is null)
            cast(void) collectException(conn.execScript("rollback to savepoint " ~ name));
    }

    /// Keeps what was done since the savepoint, as part of the transaction.
    void release()  { conn.execScript("release savepoint " ~ name);     settled = true; }
    /// Undoes what was done since the savepoint; the transaction goes on.
    void rollback() { conn.execScript("rollback to savepoint " ~ name); settled = true; }
}

// ─────────────────────────────────────────────────────── PreparedStatement ──

/// The plan is computed once and reused for the rest of the session.
struct PreparedStatement
{
    private Connection* conn;
    private string name;
    private int[string] names;
    private int count;

    /// A fresh Query over this statement. Bindings never leak between calls.
    private Query fresh() { return Query(conn, name, names, count); }

    /// Starts a fresh Query and binds into it: st.bind("age", 30).exec()
    Query bind(T)(int position, T value) { auto q = fresh(); q.bind(position, value); return q; }
    /// ditto
    Query bind(T)(string placeholder, T value) { auto q = fresh(); q.bind(placeholder, value); return q; }

    /// Runs it with every value on the spot, bound to $1, $2… in order.
    Result exec(Args...)(Args args)
    {
        auto q = fresh();
        foreach (i, arg; args) q.bind(cast(int)(i + 1), arg);
        return q.exec();
    }

    /// ditto
    T scalar(T = string, Args...)(Args args)
    {
        auto q = fresh();
        foreach (i, arg; args) q.bind(cast(int)(i + 1), arg);
        return q.scalar!T;
    }

    /// ditto
    auto stream(T = Row, Args...)(Args args)
    {
        auto q = fresh();
        foreach (i, arg; args) q.bind(cast(int)(i + 1), arg);
        return q.stream!T();
    }
}

// ──────────────────────────────────────────────────────────── Connection ────

// What has to be remembered about a prepared statement. The server only ever
// knows it as $1..$n, so the :name mapping — a product of our own translation —
// has nowhere to live but here. No Connection* is kept: `prepared` re-attaches
// the current one, so nothing dangles if the Connection is moved.
private struct PreparedInfo
{
    string sql;
    int[string] names;
    int count;
}

/**
 * Holds the notice handler on the GC heap rather than inside the Connection.
 *
 * libpq keeps the pointer we hand it for the life of the connection and calls
 * back through it from inside any query, so it has to be an address that does
 * not move when the Connection does.
 */
private final class NoticeSink
{
    void delegate(string) handler;
}

private extern(C) void noticeTrampoline(void* arg, const(char)* message) nothrow
{
    auto sink = cast(NoticeSink) arg;
    if (sink is null || sink.handler is null) return;

    // A notice must never take down the query that produced it.
    try sink.handler(message.fromStringz.idup.strip);
    catch (Exception) {}
}

/// Owns the PGconn. Non-copyable; the destructor calls PQfinish.
struct Connection
{
    private PGconn* handle;
    private bool busy;      // true while a stream is in flight
    private PreparedInfo[string] statements;
    private NoticeSink notices;

    @disable this(this);

    /**
     * Connects, or throws. `conninfo` is libpq's: `"host=… dbname=… user=…"`
     * or a `postgresql://` URI.
     */
    this(string conninfo)
    {
        handle = PQconnectdb(conninfo.toStringz);
        pgEnforce(handle !is null, "PQconnectdb returned null (out of memory?)");
        if (PQstatus(handle) != CONNECTION_OK)
        {
            auto msg = lastError(handle);
            PQfinish(handle);
            handle = null;
            throw new PgException("could not connect: " ~ msg);
        }
    }

    ~this() { if (handle) { PQfinish(handle); handle = null; } }

    /**
     * Where NOTICE and WARNING messages go. Without this they are libpq's
     * problem, which means stderr — `create table if not exists` on an existing
     * table is enough to produce one, so a server that never calls this ends up
     * with someone else's log lines in its own.
     *
     * Passing `null` drops them instead. The handler runs inside the call that
     * produced the message, and anything it throws is swallowed: a notice can
     * never fail the query that caused it.
     *
     * `PQreset` keeps it; building a new Connection does not.
     */
    void onNotice(void delegate(string) handler)
    {
        if (notices is null) notices = new NoticeSink;
        notices.handler = handler;
        PQsetNoticeProcessor(handle, &noticeTrampoline, cast(void*) notices);
    }

    /// Whether the connection is up. False after the server went away: see `reset`.
    @property bool ok() { return handle !is null && PQstatus(handle) == CONNECTION_OK; }

    /// Refuses up front while a stream or a COPY still holds the connection.
    private void ensureIdle()
    {
        pgEnforce(!busy, "the connection is busy with a stream or a COPY in progress: "
                         ~ "consume it, or let it go out of scope, first");
    }

    /// The server version as a number: 160004 for 16.4.
    @property int serverVersion() { return PQserverVersion(handle); }
    /// Inside a transaction that already failed: only a rollback is accepted now.
    @property bool inErrorState() { return PQtransactionStatus(handle) == PQTRANS_INERROR; }

    /**
     * Reconnects with the same parameters. Prepared statements do not survive
     * it, since they lived in the old session: prepare them again afterwards.
     */
    void reset()
    {
        PQreset(handle);
        busy = false;
        // Prepared statements live in the session that just died, so whatever
        // we remembered about them is now a lie.
        statements = null;
        pgEnforce(ok, "reset failed: " ~ lastError(handle));
    }

    /**
     * Names a statement without running it, so its values can be bound one at
     * a time and from different places. Nothing reaches the server until you
     * call `exec`, `scalar` or `stream` on the result.
     */
    Query sql(string text) { return Query(&this, text); }

    /// Shorthand for when every value is available on the spot.
    Result exec(Args...)(string sql, Args args)
    {
        auto q = Query(&this, sql);
        foreach (i, arg; args) q.bind(cast(int)(i + 1), arg);
        return q.exec();
    }

    /// One value: the first column of the first row, converted to `T`.
    T scalar(T = string, Args...)(string sql, Args args)
    {
        return exec(sql, args).scalar!T;
    }

    /**
     * One row at a time, in constant memory: a lazy range of `T`, a struct
     * mapped by column name or `Row` itself. The connection is busy until the
     * range is consumed or dropped.
     */
    auto stream(T = Row, Args...)(string sql, Args args)
    {
        auto q = Query(&this, sql);
        foreach (i, arg; args) q.bind(cast(int)(i + 1), arg);
        return q.stream!T();
    }

    /**
     * Several ';'-separated commands, WITHOUT parameters: PQexecParams accepts
     * only one command per call, so multi-statement has to go through PQexec,
     * which in turn has no binding. Use it for DDL and migrations, never with
     * values coming from outside.
     */
    void execScript(string sql) { cast(void) execStatus(sql); }

    /// execScript, handing back the command tag of the last statement.
    private string execStatus(string sql)
    {
        ensureIdle();
        auto res = PQexec(handle, sql.toStringz);
        checkResult(handle, res);
        scope(exit) PQclear(res);
        return PQcmdStatus(res).fromStringz.idup;
    }

    /**
     * Has the server parse and plan a statement once, under a name, and keeps
     * enough about it that `prepared` can hand it back later.
     *
     * Preparing the same name with the same text again is a no-op that returns
     * the existing statement, so a "prepare everything" routine can be called
     * more than once. The same name with different text is an error.
     */
    PreparedStatement prepare(string name, string text)
    {
        auto t = translatePlaceholders(text);

        if (auto known = name in statements)
        {
            pgEnforce(known.sql == t.sql,
                      "'" ~ name ~ "' is already prepared, with a different statement");
            return PreparedStatement(&this, name, known.names, known.count);
        }

        ensureIdle();
        auto res = PQprepare(handle, name.toStringz, t.sql.toStringz, 0, null);
        checkResult(handle, res);
        PQclear(res);
        statements[name] = PreparedInfo(t.sql, t.names, t.count);
        return PreparedStatement(&this, name, t.names, t.count);
    }

    /**
     * The statement prepared earlier under this name, so it does not have to be
     * carried around. Only names this Connection prepared are known: the `:name`
     * placeholders are a client-side translation, so a statement prepared behind
     * our back — or one from the session before a `reset` — cannot be recovered.
     */
    PreparedStatement prepared(string name)
    {
        auto known = name in statements;
        pgEnforce(known !is null, "no statement prepared as '" ~ name ~ "' on this connection");
        return PreparedStatement(&this, name, known.names, known.count);
    }

    /// Whether `prepared` would find something under this name.
    bool isPrepared(string name) { return (name in statements) !is null; }

    /**
     * Forgets every prepared statement, on the server and here. Use this rather
     * than sending `deallocate` yourself, which would leave the two out of step.
     */
    void deallocateAll()
    {
        execScript("deallocate all");
        statements = null;
    }

    /// The names of every statement prepared on this connection.
    @property string[] preparedNames() { return statements.keys; }

    /**
     * Starts a `COPY ... FROM STDIN`, the fastest way to load rows.
     *
     * A COPY from a server-side file is an ordinary statement and belongs in
     * `exec`; this is for the form that streams the data from here.
     */
    CopyIn copyIn(string statement) { return CopyIn(&this, statement); }

    /// Starts a `COPY ... TO STDOUT` and hands back its lines, lazily.
    CopyOut copyOut(string statement)
    {
        ensureIdle();

        auto res = PQexec(handle, statement.toStringz);
        immutable status = PQresultStatus(res);
        if (status != PGRES_COPY_OUT)
        {
            if (status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK)
            {
                PQclear(res);
                throw new PgException("that is not a COPY ... TO STDOUT: a COPY to "
                    ~ "a server-side file is an ordinary statement, run it with exec");
            }
            throw errorFrom(handle, res);
        }
        PQclear(res);
        busy = true;

        return CopyOut(&this);
    }

    /// Begins a transaction, rolled back at the end of the scope unless committed.
    Transaction transaction(Isolation isolation = Isolation.serverDefault,
                            Access access = Access.readWrite)
    {
        return Transaction(&this, isolation, access);
    }

    /**
     * Runs `work` inside a transaction, committing it if it returns and rolling
     * it back if it throws — and running it again if the server says the
     * transaction lost a race.
     *
     * Under `serializable` that last part is not optional: the server is allowed
     * to abort a transaction it cannot serialise (SQLSTATE 40001), and a
     * deadlock (40P01) is resolved the same way. Both mean "nothing happened,
     * try again", so `work` must be safe to run more than once — keep the
     * side effects that are not database writes outside it.
     */
    auto transact(Work)(scope Work work,
                        Isolation isolation = Isolation.serializable,
                        Access access = Access.readWrite,
                        int attempts = 5)
        if (isCallable!Work)
    {
        import core.thread : Thread;
        import std.random : uniform;

        alias Result = ReturnType!Work;

        foreach (attempt; 0 .. attempts)
        {
            try
            {
                auto tx = transaction(isolation, access);
                static if (is(Result == void))
                {
                    work();
                    tx.commit();
                    return;
                }
                else
                {
                    auto outcome = work();
                    tx.commit();
                    return outcome;
                }
            }
            catch (PgException e)
            {
                // The destructor has already rolled back by the time we are here.
                if (!isRetryable(e.sqlstate) || attempt + 1 == attempts)
                    throw e;

                // Retrying two deadlocked transactions in lockstep just
                // deadlocks them again, so back off a little, and unevenly.
                Thread.sleep(dur!"msecs"((attempt + 1) * 10 + uniform(0, 10)));
            }
        }
        assert(0, "unreachable: the last attempt rethrows");
    }



    /// For dynamic table/column names: $n cannot stand in for an identifier.
    string escapeIdentifier(string s)
    {
        auto p = PQescapeIdentifier(handle, s.ptr, s.length);
        pgEnforce(p !is null, "escapeIdentifier: " ~ lastError(handle));
        scope(exit) PQfreemem(p);
        return p.fromStringz.idup;
    }
}

// ─────────────────────────────────────────────── tests against a server ─────
//
// These run only when JAPE_TEST_CONNINFO names a throwaway database, e.g.
//   JAPE_TEST_CONNINFO="host=127.0.0.1 port=55432 user=postgres ..." dub test
// and are skipped otherwise, so `dub test` works without one.

version (unittest) private string testConninfo()
{
    import std.process : environment;
    return environment.get("JAPE_TEST_CONNINFO");
}

unittest
{
    if (testConninfo is null) return;
    auto c = Connection(testConninfo);
    c.onNotice(null);

    // COMMIT on a failed transaction is answered with ROLLBACK and no error:
    // commit() must not report success for work that was thrown away.
    c.execScript("create temporary table commit_check (n int)");
    {
        auto tx = c.transaction();
        c.exec("insert into commit_check values (1)");
        assert(collectException!PgException(c.exec("select 1/0")) !is null);
        auto e = collectException!PgException(tx.commit());
        assert(e !is null, "commit of an aborted transaction reported success");
        assert(e.sqlstate == "25P02");
    }
    assert(!c.inErrorState);
    assert(c.scalar!long("select count(*) from commit_check") == 0);

    // and a healthy one still commits
    {
        auto tx = c.transaction();
        c.exec("insert into commit_check values (2)");
        tx.commit();
    }
    assert(c.scalar!long("select count(*) from commit_check") == 1);
}

unittest
{
    if (testConninfo is null) return;
    auto c = Connection(testConninfo);

    // Copies of a stream share one cursor: advancing either moves both, and
    // none of them is left holding a row that has already been freed.
    static struct N { int n; }
    {
        auto s = c.stream!N("select generate_series(1, 4) as n");
        auto t = s;
        t.popFront();
        assert(s.front.n == 2);

        int[] rest;
        foreach (x; s) rest ~= x.n;          // foreach works on a copy of s, too
        assert(rest == [2, 3, 4]);
        assert(s.empty && t.empty);
    }
    {
        auto s = c.stream("select generate_series(1, 3) as n");
        auto t = s;
        t.popFront();
        assert(s.front[0].as!int == 2);
    }
    {
        auto s = c.sql("select generate_series(1, 5) as n").stream(2);   // chunked
        auto t = s;
        t.popFront();
        t.popFront();
        assert(s.front[0].as!int == 3);
    }

    // the same for COPY ... TO STDOUT
    {
        auto o = c.copyOut("copy (select generate_series(1, 3)) to stdout");
        auto p = o;
        p.popFront();
        assert(o.front == "2\n");
        string[] rest;
        foreach (line; o) rest ~= line.idup;
        assert(rest == ["2\n", "3\n"]);
        assert(o.empty && p.empty);
    }

    // a default-constructed stream is simply empty
    RowStream!Row none;
    assert(none.empty);
    CopyOut nothing;
    assert(nothing.empty);

    assert(c.scalar!int("select 42") == 42);   // and the connection is still usable
}

unittest
{
    if (testConninfo is null) return;
    auto c = Connection(testConninfo);
    c.execScript("create temporary table copy_misuse (n int)");

    // COPY through exec switches the connection into a data channel that
    // exec cannot serve: it must be refused AND the channel closed again,
    // or the connection is stuck for good.
    auto e = collectException!PgException(c.exec("copy copy_misuse from stdin"));
    assert(e !is null && e.msg.canFind("copyIn"), e is null ? "no exception" : e.msg);
    assert(c.scalar!int("select 1") == 1);

    e = collectException!PgException(c.execScript("copy copy_misuse from stdin"));
    assert(e !is null && e.msg.canFind("copyIn"), e is null ? "no exception" : e.msg);
    assert(c.scalar!int("select 2") == 2);

    c.exec("insert into copy_misuse select generate_series(1, 1000)");
    e = collectException!PgException(c.exec("copy copy_misuse to stdout"));
    assert(e !is null && e.msg.canFind("copyOut"), e is null ? "no exception" : e.msg);
    assert(c.scalar!int("select 3") == 3);

    // nothing was written by the refused COPY FROM
    assert(c.scalar!long("select count(*) from copy_misuse") == 1000);

    // an empty statement says so, instead of "unknown error"
    e = collectException!PgException(c.exec(""));
    assert(e !is null && e.msg.canFind("empty"), e is null ? "no exception" : e.msg);
}

unittest
{
    if (testConninfo is null) return;
    auto c = Connection(testConninfo);
    immutable before = ResultState.live;

    // A Row or a Field keeps its PGresult alive on its own: taking one out of
    // a temporary Result must not leave it pointing at freed memory.
    {
        Row r = c.exec("select 'hello'::text as w, 7 as n").front;
        assert(ResultState.live == before + 1, "the Row does not own its result");
        assert(r["w"].as!string == "hello" && r["n"].as!int == 7);

        Field f = c.exec("select 42").front[0];
        assert(ResultState.live == before + 2, "the Field does not own its result");
        assert(f.as!int == 42);
    }
    assert(ResultState.live == before, "results leaked");

    // The same for rows out of a stream: no longer transient.
    {
        auto s = c.stream("select generate_series(1, 3) as n");
        Row first = s.front;
        s.popFront();
        assert(ResultState.live == before + 2, "a streamed Row does not own its result");
        assert(first["n"].as!int == 1 && s.front["n"].as!int == 2);
    }
    assert(ResultState.live == before, "streamed results leaked");

    // Rows copied into GC memory stay valid too. They are released when the
    // GC collects the array, not at the end of the scope, so no count here.
    auto rows = c.exec("select generate_series(1, 3)").rows.array;
    assert(rows.map!(x => x[0].as!int).equal([1, 2, 3]));

    auto kept = c.stream("select generate_series(1, 3) as n").array;
    assert(kept.map!(x => x["n"].as!int).equal([1, 2, 3]));

    auto chunked = c.sql("select generate_series(1, 5) as n").stream(2).array;
    assert(chunked.map!(x => x["n"].as!int).equal([1, 2, 3, 4, 5]));
}

unittest
{
    if (testConninfo is null) return;
    auto c = Connection(testConninfo);

    // A session time zone that is certainly not the client's: the instant must
    // survive the round trip anyway.
    c.execScript("set time zone 'Pacific/Kiritimati'");   // UTC+14
    auto when = SysTime(DateTime(2026, 1, 1, 12, 0, 0), LocalTime());
    assert(c.scalar!SysTime("select $1::timestamptz", when) == when);

    // and timestamp without time zone round-trips too
    assert(c.scalar!SysTime("select $1::timestamp", when) == when);
}

unittest
{
    if (testConninfo is null) return;
    auto c = Connection(testConninfo);

    // PQfnumber folds an unquoted name to lower case, so a camelCase alias
    // could never be found by the name it was given.
    static struct Camel { int createdAt; string userName; }
    auto r = c.exec(`select 1 as "createdAt", 'ada' as "userName"`);
    assert(r.front["createdAt"].as!int == 1);
    auto v = r.front.as!Camel;
    assert(v.createdAt == 1 && v.userName == "ada");

    // the exact name wins over the folded one
    auto both = c.exec(`select 1 as "Id", 2 as id`);
    assert(both.front["Id"].as!int == 1);
    assert(both.front["id"].as!int == 2);

    // and the old, case-folding lookup still works when there is no exact match
    auto lower = c.exec("select 3 as total");
    assert(lower.front["TOTAL"].as!int == 3);
    static struct Upper { int Total; }
    assert(lower.front.as!Upper.Total == 3);

    // names with a double quote in them
    assert(c.exec(`select 4 as "a""b"`).front[`a"b`].as!int == 4);
}

unittest
{
    if (testConninfo is null) return;
    auto c = Connection(testConninfo);

    // While a stream or a COPY holds the connection, anything else must be
    // refused up front and by name, not with whatever libpq makes of it.
    void refused(lazy void call)
    {
        auto e = collectException!PgException(call);
        assert(e !is null, "not refused");
        assert(e.msg.canFind("busy"), e.msg);
    }

    {
        auto s = c.stream("select generate_series(1, 3) as n");
        refused(c.exec("select 1"));
        refused(c.execScript("select 1"));
        refused(c.transaction());
        refused(c.prepare("busy_check", "select 1"));
        refused(c.stream("select 1"));
        refused(c.copyOut("copy (select 1) to stdout"));

        // and the stream it protected is intact
        assert(s.map!(r => r["n"].as!int).equal([1, 2, 3]));
    }

    c.execScript("create temporary table busy_copy (n int)");
    {
        auto copy = c.copyIn("copy busy_copy from stdin");
        refused(c.exec("select 1"));
        copy.writeRow(1);
        assert(copy.commit() == 1);
    }
    assert(c.scalar!int("select count(*)::int from busy_copy") == 1);
}

unittest
{
    // Equal values hash alike, or an associative array keyed on Numeric
    // loses entries: 1.10 == 1.1, so both must land in the same bucket.
    assert(hashOf(Numeric("1.10")) == hashOf(Numeric("1.1")));
    assert(hashOf(Numeric("0")) == hashOf(Numeric("0.000")));
    assert(hashOf(Numeric("-2.50")) == hashOf(Numeric("-2.5")));
    assert(hashOf(Numeric("NaN")) == hashOf(Numeric("NaN")));

    int[Numeric] byAmount;
    byAmount[Numeric("1.1")] = 1;
    assert(Numeric("1.10") in byAmount);
    assert(Numeric("1.2") !in byAmount);
}

unittest
{
    // A value travels as a C string, so a NUL inside it would cut it short
    // without a word: refused instead. bytea goes out hex-encoded and is fine.
    auto q = Query(null, "select $1");
    assert(collectException!PgException(q.bind(1, "a\0b")) !is null);
    assert(collectException!PgException(q.bind(1, ["ok", "a\0b"])) !is null);
    assert(collectException!PgException(q.bind(1, cast(ubyte[]) [0x61, 0x00, 0x62])) is null);
}
