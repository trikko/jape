// The whole interface. It talks to three shapes of one endpoint:
//
//   GET    /api/notes?q=&since=   -> { total, worker, notes: [...] }
//   POST   /api/notes             -> { id }            (form-encoded)
//   DELETE /api/notes?id=         -> { deleted }
//
// Postgres does the filtering; this file only draws the answer.

const $ = (id) => document.getElementById(id);

// Wraps every occurrence of `term` in a <mark>. Built as nodes, never as HTML,
// so a note containing tags is still just text.
function highlighted(text, term) {
  const out = document.createDocumentFragment();
  if (!term) {
    out.append(text);
    return out;
  }

  const haystack = text.toLowerCase();
  const needle = term.toLowerCase();
  let from = 0, at;

  while ((at = haystack.indexOf(needle, from)) !== -1) {
    if (at > from) out.append(text.slice(from, at));
    const mark = document.createElement("mark");
    mark.textContent = text.slice(at, at + needle.length);
    out.append(mark);
    from = at + needle.length;
  }
  out.append(text.slice(from));
  return out;
}

function say(text, kind) {
  const box = $("message");
  box.textContent = text;
  box.className = "note-flash " + kind;
  box.hidden = false;
  clearTimeout(say.timer);
  say.timer = setTimeout(() => { box.hidden = true; }, 4000);
}

async function api(path, options) {
  const response = await fetch(path, options);
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || response.statusText);
  return payload;
}

function filters() {
  const form = $("filters");
  return {
    q: form.q.value.trim(),
    since: form.since.value,
  };
}

function noteCard(note, term) {
  const card = document.createElement("article");
  card.className = "card note";

  const head = document.createElement("div");
  head.className = "note-head";

  const title = document.createElement("h2");
  title.append(highlighted(note.title, term));

  const del = document.createElement("button");
  del.className = "danger";
  del.title = "Delete";
  del.textContent = "×";
  del.onclick = () => remove(note.id);

  head.append(title, del);
  card.append(head);

  if (note.body) {
    const body = document.createElement("p");
    body.append(highlighted(note.body, term));
    card.append(body);
  }

  const foot = document.createElement("footer");
  const id = document.createElement("span");
  id.className = "id";
  id.textContent = "#" + note.id;
  const when = document.createElement("time");
  when.dateTime = note.created_at;
  when.textContent = note.created_at.slice(0, 16).replace("T", " ");
  foot.append(id, when);
  card.append(foot);

  return card;
}

async function refresh() {
  const { q, since } = filters();
  const query = new URLSearchParams({ q, since });

  const data = await api("/api/notes?" + query);
  const filtering = q !== "" || since !== "";

  $("meta").textContent = filtering
    ? `${data.notes.length} of ${data.total} notes match`
    : `${data.total} notes`;

  $("reset").hidden = !filtering;
  $("worker").textContent = data.worker;
  $("json").href = "/api/notes?" + query;

  const list = $("list");
  list.replaceChildren();

  if (data.notes.length === 0) {
    const empty = document.createElement("p");
    empty.className = "empty";
    empty.textContent = filtering
      ? "Nothing matches those filters."
      : "No notes yet. Write the first one.";
    list.append(empty);
    return;
  }

  for (const note of data.notes) list.append(noteCard(note, q));
}

async function remove(id) {
  try {
    const { deleted } = await api("/api/notes?id=" + id, { method: "DELETE" });
    // Deleting a row that is not there is not an error for Postgres, so the
    // answer is a count rather than a status.
    say(deleted ? "Note deleted" : "That note was already gone", deleted ? "ok" : "err");
    await refresh();
  } catch (e) {
    say(e.message, "err");
  }
}

$("compose").onsubmit = async (event) => {
  event.preventDefault();
  const form = event.target;

  try {
    const { id } = await api("/api/notes", {
      method: "POST",
      body: new URLSearchParams({ title: form.title.value, body: form.body.value }),
    });
    say("Added note #" + id, "ok");
    form.reset();
    form.title.focus();
    await refresh();
  } catch (e) {
    say(e.message, "err");
  }
};

$("filters").onsubmit = (event) => { event.preventDefault(); refresh(); };

$("reset").onclick = (event) => {
  event.preventDefault();
  $("filters").reset();
  refresh();
};

refresh().catch((e) => say(e.message, "err"));
