<script lang="ts">
  import { onMount } from "svelte";
  import { preview } from "./markdown";
  import Repos from "./Repos.svelte";
  import Comms from "./Comms.svelte";
  import Sharing from "./Sharing.svelte";
  import Links from "./Links.svelte";
  import Comments from "./Comments.svelte";
  import { api, listing } from "./api";
  let {
    space,
    initialPath,
    initialReference = "",
    navigate,
  }: {
    space: string;
    initialPath: string;
    initialReference?: string;
    navigate: (space: string, path: string, reference?: string) => void;
  } = $props();
  type Doc = {
    path: string;
    revision: string;
    id?: string;
    type: string;
    title: string;
    status?: string;
    assignee?: string;
    sprint?: string;
    release?: string;
    url?: string;
    tags?: string[];
    description?: string;
    created?: string;
  };
  type Tree = { directories: string[]; documents: Doc[] };
  let tree = $state<Tree>({ directories: [], documents: [] });
  let path = $state(""),
    body = $state(""),
    revision = $state<string>(),
    selected = $state<Doc>();
  let dest = $state(""),
    folder = $state(""),
    error = $state(""),
    loading = $state(true);
  let kind = $state("doc"),
    title = $state(""),
    url = $state(""),
    status = $state("todo"),
    sprint = $state(""),
    release = $state(""),
    assignee = $state("");
  let mode = $state("Files"),
    read = $state(false),
    filter = $state("");
  let people = $state<{ id: string; name: string; profile: string }[]>([]);
  type Settings = {
    version: number;
    revision: string;
    defaults: Record<string, string>;
    saved: Record<string, string>;
  };
  let settings = $state<Settings>({
    version: 1,
    revision: "initial",
    defaults: {},
    saved: {},
  });
  let scope = $state(""),
    savedName = $state(""),
    tags = $state(""),
    published = $state(""),
    description = $state("");
  let typeFilter = $state(""),
    authorFilter = $state(""),
    since = $state(""),
    until = $state(""),
    dirRev = $state("");
  async function chooseScope(value: string) {
    scope = value;
    mode = settings.defaults[value] ?? "Files";
    dirRev = value
      ? (
          await api<{ id: string }>(
            base() + "directory-revision?path=" + encodeURIComponent(value),
          )
        ).id
      : "";
  }
  async function storeView(defaultView: boolean) {
    const next = structuredClone($state.snapshot(settings));
    if (defaultView) next.defaults[scope] = mode;
    else if (savedName.trim()) next.saved[savedName.trim()] = mode;
    settings = await api(base() + "views", "PUT", next);
  }
  let user = $state(""),
    query = $state(""),
    allSpaces = $state(false),
    searched = $state(false);
  let hits = $state<
    { space: string; path: string; title: string; reference?: string }[]
  >([]);
  let sharedReference = $state("");
  let moreResults = $state(false);
  let searchFilter: Record<string, unknown> = {};
  async function search(more: boolean) {
    if (!more)
      searchFilter = {
        query,
        allSpaces,
        type: typeFilter,
        directory: scope,
        author: authorFilter,
        since,
        until: until ? until + "T23:59:59Z" : "",
      };
    const page = await api<{ hits: typeof hits }>(base() + "search", "POST", {
      ...searchFilter,
      offset: more ? hits.length : 0,
    });
    hits = more ? [...hits, ...page.hits] : page.hits;
    moreResults = page.hits.length === 100;
    searched = true;
  }
  const base = () => "spaces/" + space + "/";
  async function run(work: () => Promise<void>) {
    error = "";
    try {
      await work();
    } catch (e) {
      error = String(e);
    }
  }
  async function refresh() {
    let offset: number | undefined = 0;
    const next: Tree = { directories: [], documents: [] };
    while (offset !== undefined) {
      const page: Tree & { next?: number } = await api(
        base() + "tree?offset=" + offset,
      );
      next.directories.push(...page.directories);
      next.documents.push(...page.documents);
      offset = page.next;
    }
    tree = next;
  }
  onMount(async () => {
    await run(async () => {
      await refresh();
      settings = await api(base() + "views");
      mode = initialReference ? "Sharing" : (settings.defaults[""] ?? "Files");
      sharedReference = initialReference;
      user = (await api<{ user: string }>("session")).user;
      people = await listing(base() + "people", "people");
      const initial = tree.documents.find((doc) => doc.path === initialPath);
      if (initial) await open(initial);
    });
    loading = false;
  });
  function clear() {
    path = "";
    body = "";
    selected = undefined;
    revision = undefined;
    title = "";
    url = "";
    assignee = "";
    sprint = "";
    release = "";
    read = false;
    kind = "doc";
    description = "";
    tags = "";
    published = "";
  }
  async function open(doc: Doc) {
    await run(async () => {
      const file = await api<{ document: Doc; text: string }>(
        base() + "file?path=" + encodeURIComponent(doc.path),
      );
      selected = file.document;
      path = doc.path;
      revision = file.document.revision;
      body = file.text;
      read = true;
    });
  }
  async function save() {
    await run(async () => {
      let text = body;
      if (!selected && kind !== "doc") {
        const fields: Record<string, string> = {
          id: crypto.randomUUID(),
          type: kind,
          title,
        };
        if (kind === "url") {
          Object.assign(fields, {
            url,
            created: new Date().toISOString(),
            description,
          });
          if (published) fields.published = published;
        }
        if (kind === "task") {
          fields.status = status;
          if (sprint) fields.sprint = sprint;
          if (assignee) fields.assignee = assignee;
        }
        if (["task", "sprint"].includes(kind) && release)
          fields.release = release;
        text =
          "---\n" +
          Object.entries(fields)
            .map(([k, v]) => k + ": " + JSON.stringify(v))
            .join("\n") +
          (kind === "url" && tags.trim()
            ? "\ntags: " +
              JSON.stringify(
                tags
                  .split(",")
                  .map((t) => t.trim())
                  .filter(Boolean),
              )
            : "") +
          "\n---\n" +
          body;
      }
      await api(base() + "write", "POST", { path, text, revision });
      await refresh();
      const doc = tree.documents.find((d) => d.path === path);
      if (doc) await open(doc);
    });
  }
  let docs = $derived(
    tree.documents.filter(
      (d) =>
        (!scope || d.path.startsWith(scope + "/")) &&
        (
          d.title +
          " " +
          d.path +
          " " +
          (d.url ?? "") +
          " " +
          (d.description ?? "") +
          " " +
          (d.tags ?? []).join(" ")
        )
          .toLowerCase()
          .includes(filter.toLowerCase()),
    ),
  );
  function progress(doc: Doc) {
    const tasks = tree.documents.filter(
      (d) => d.type === "task" && (d.sprint === doc.id || d.release === doc.id),
    );
    return (
      tasks.filter((d) => d.status === "done").length +
      "/" +
      tasks.length +
      " done"
    );
  }
</script>

{#if error}<p role="alert">{error}</p>{/if}
{#if loading}<p role="status">Loading workspace…</p>{:else}
  <label>
    Directory <select
      value={scope}
      onchange={(e) => run(() => chooseScope(e.currentTarget.value))}
    >
      <option value="">
        Whole space
      </option>{#each tree.directories as dir}<option>{dir}</option>{/each}
    </select>
  </label>
  {#if scope}<a
      href={"/api/v1/" + base() + "export?folder=" + encodeURIComponent(scope)}
      download
    >
      Export directory
    </a>
    <details>
      <summary>Manage directory</summary><label>
        Destination <input bind:value={dest} />
      </label>
      <button
        onclick={() =>
          run(async () => {
            await api(base() + "move-directory", "POST", {
              path: scope,
              revision: dirRev,
              destination: dest,
            });
            await refresh();
            await chooseScope(dest);
          })}
      >
        Move directory
      </button>
      <button
        onclick={() =>
          run(async () => {
            if (confirm("Delete empty directory?")) {
              await api(base() + "delete-directory", "POST", {
                path: scope,
                revision: dirRev,
              });
              await refresh();
              await chooseScope("");
            }
          })}
      >
        Delete empty directory
      </button>
    </details>{/if}
  <nav aria-label="Views">
    {#each ["Files", "Kanban", "Tasks", "Backlog", "Sprints", "Releases", "URLs", "People", "Search", "Comms", "Sharing", "Repos"] as tab}<button
        aria-pressed={mode === tab}
        onclick={() => (mode = tab)}
      >
        {tab}
      </button>{/each}
  </nav>
  <details>
    <summary>Saved views</summary><button
      onclick={() => run(() => storeView(true))}
    >
      Use {mode} as directory default
    </button>
    <label>View name <input bind:value={savedName} /></label><button
      disabled={!savedName.trim()}
      onclick={() => run(() => storeView(false))}
    >
      Save view
    </button>
    {#each Object.entries(settings.saved) as [name, view]}<button
        onclick={() => (mode = view)}
      >
        {name}
      </button>{/each}
  </details>
  {#if mode === "Repos"}<Repos {space} />{:else if mode === "Comms"}<Comms
      {space}
      {people}
      documents={tree.documents}
      openEntity={(p) => {
        mode = "Files";
        const doc = tree.documents.find((d) => d.path === p);
        if (doc) open(doc);
      }}
      promote={(text, task) => {
        clear();
        body = text;
        kind = task ? "task" : "doc";
        mode = "Files";
      }}
    />{:else if mode === "Sharing"}<Sharing
      {space}
      selectedReference={sharedReference}
    />{:else}
    <div class="workspace" class:wide={mode === "Kanban" || mode === "URLs"}>
      <aside>
        {#if mode === "Search"}
          <form
            onsubmit={(e) => {
              e.preventDefault();
              run(() => search(false));
            }}
          >
            <label>
              Search content and comments <input bind:value={query} required />
            </label><label>
              <input type="checkbox" bind:checked={allSpaces} /> All accessible spaces
            </label><label>
              Type <select bind:value={typeFilter}>
                <option value="">
                  All types
                </option>{#each ["doc", "url", "task", "sprint", "release"] as t}<option>
                    {t}
                  </option>{/each}
              </select>
            </label>
            <label>
              Author <select bind:value={authorFilter}>
                <option value="">Any author</option>{#each people as p}<option
                    value={p.id}
                  >
                    {p.name}
                  </option>{/each}
              </select>
            </label>
            <label>From <input type="date" bind:value={since} /></label><label>
              Through <input type="date" bind:value={until} />
            </label><button>Search</button>
          </form>
          {#each hits as hit}<p>
              <button
                onclick={() => {
                  if (hit.reference) {
                    if (hit.space === space) {
                      sharedReference = hit.reference;
                      mode = "Sharing";
                    } else navigate(hit.space, "", hit.reference);
                  } else if (hit.space === space) {
                    const doc = tree.documents.find((d) => d.path === hit.path);
                    if (doc) open(doc);
                  } else navigate(hit.space, hit.path);
                }}
              >
                {hit.title} · {hit.path} · {hit.space}
              </button>
            </p>{:else}{#if searched}<p>No matches.</p>{/if}{/each}
          {#if moreResults}<button onclick={() => run(() => search(true))}>
              More results
            </button>{/if}
        {:else if mode === "People"}<h2>People</h2>
          {#each people as p}<details>
              <summary>{p.name}</summary>
              <article>{@html preview(p.profile)}</article>
            </details>{/each}
        {:else}
          <label>Filter <input bind:value={filter} /></label>
          {#if mode === "Files"}
            <ul>
              {#each [...tree.directories
                  .filter((p) => !scope || p.startsWith(scope + "/"))
                  .map( (p) => ({ path: p, dir: true }) ), ...docs.map( (d) => ({ path: d.path, dir: false }) )].sort( (a, b) => a.path.localeCompare(b.path) ) as item}
                <li
                  style:padding-left={(item.path.split("/").length - 1) * 0.8 +
                    "rem"}
                >
                  {#if item.dir}{item.path.split("/").pop()}/{:else}<button
                      onclick={() =>
                        open(tree.documents.find((d) => d.path === item.path)!)}
                    >
                      {item.path.split("/").pop()}
                    </button>{/if}
                </li>
              {:else}<li>This space is empty.</li>{/each}
            </ul>
            <label>Directory path <input bind:value={folder} /></label><button
              onclick={() =>
                run(async () => {
                  await api(base() + "directory", "POST", { path: folder });
                  folder = "";
                  await refresh();
                })}
            >
              Create directory
            </button>
          {:else if mode === "URLs"}<Links
              docs={docs.filter((d) => d.type === "url")}
              base={base()}
              open={(path) =>
                open(tree.documents.find((d) => d.path === path)!)}
            />
          {:else if mode === "Kanban"}
            <div class="board">
              {#each ["todo", "in-progress", "done"] as column}<section>
                  <h3>{column}</h3>
                  {#each docs.filter((d) => d.type === "task" && d.status === column) as d}<div
                      class="task"
                    >
                      <button onclick={() => open(d)}>{d.title}</button>
                      <select
                        aria-label={"Status for " + d.title}
                        value={d.status}
                        onchange={(e) => {
                          const status = e.currentTarget.value;
                          run(async () => {
                            await api(base() + "task-status", "POST", {
                              path: d.path,
                              revision: d.revision,
                              status,
                            });
                            await refresh();
                            if (selected?.id === d.id) await open(d);
                          });
                        }}
                      >
                        {#each ["todo", "in-progress", "done"] as state}<option>
                            {state}
                          </option>{/each}
                      </select>
                    </div>{/each}
                </section>{/each}
            </div>
          {:else}
            {#each docs.filter( (d) => (mode === "Tasks" || mode === "Backlog" ? d.type === "task" && (mode !== "Backlog" || !d.sprint) : d.type === ({ Sprints: "sprint", Releases: "release", URLs: "url" } as Record<string, string>)[mode]) ) as d}
              <p>
                <button onclick={() => open(d)}>{d.title}</button>
                {["sprint", "release"].includes(d.type)
                  ? progress(d)
                  : (d.url ?? d.status ?? "")}
              </p>
            {:else}<p>No matching items.</p>{/each}
          {/if}{/if}
      </aside>
      <section>
        <button onclick={clear}>New file</button>
        <a href={"/api/v1/" + base() + "export"} download>Export space</a>
        <button
          onclick={() =>
            run(async () => {
              await api(base() + "rescan", "POST");
              await refresh();
            })}
        >
          Rescan
        </button>
        {#if selected}<h2>{selected.title}</h2>
          {#if selected.assignee}<p>
              Assignee · {people.find((p) => p.id === selected?.assignee)
                ?.name ?? "Unavailable"}
            </p>{/if}
          {#each [["Sprint", selected.sprint], ["Release", selected.release]] as [label, ref]}
            {#if ref}{@const target = tree.documents.find((d) => d.id === ref)}
              <p>
                {label} · {#if target}<button onclick={() => open(target)}>
                    {target.title}
                  </button>{:else}Unavailable ({ref}){/if}
              </p>{/if}{/each}
          <button onclick={() => (read = !read)}>
            {read ? "Edit Markdown" : "Preview"}
          </button>{/if}
        {#if selected && read}<article>
            {@html preview(body.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, ""))}
          </article>
        {:else}
          <label>
            File path <input
              bind:value={path}
              disabled={!!selected}
              placeholder="notes/plan.md"
            />
          </label>
          {#if !selected}
            <label>
              Type <select bind:value={kind}>
                {#each ["doc", "task", "sprint", "release", "url"] as k}<option>
                    {k}
                  </option>{/each}
              </select>
            </label>
            {#if kind !== "doc"}<label>
                Title <input bind:value={title} />
              </label>{/if}
            {#if kind === "url"}<label>
                URL <input type="url" bind:value={url} />
              </label><label>
                Description <input bind:value={description} />
              </label><label>
                Tags (comma separated) <input bind:value={tags} />
              </label><label>
                Publication date <input type="date" bind:value={published} />
              </label>{/if}
            {#if kind === "task"}<label>
                Status <select bind:value={status}>
                  {#each ["todo", "in-progress", "done"] as s}<option>
                      {s}
                    </option>{/each}
                </select>
              </label>
              <label>
                Assignee <select bind:value={assignee}>
                  <option value="">Unassigned</option>{#each people as p}<option
                      value={p.id}
                    >
                      {p.name}
                    </option>{/each}
                </select>
              </label>
              <label>
                Sprint <select bind:value={sprint}>
                  <option value="">
                    Unscheduled
                  </option>{#each tree.documents.filter((d) => d.type === "sprint") as d}<option
                      value={d.id}
                    >
                      {d.title}
                    </option>{/each}
                </select>
              </label>{/if}
            {#if ["task", "sprint"].includes(kind)}<label>
                Release <select bind:value={release}>
                  <option value="">
                    None
                  </option>{#each tree.documents.filter((d) => d.type === "release") as d}<option
                      value={d.id}
                    >
                      {d.title}
                    </option>{/each}
                </select>
              </label>{/if}
          {/if}
          <label>
            Markdown <textarea rows="15" bind:value={body}></textarea>
          </label><button onclick={save}>Save</button>
        {/if}
        {#if selected}<details>
            <summary>Move or delete file</summary><label>
              Destination <input bind:value={dest} />
            </label>
            <button
              onclick={() =>
                run(async () => {
                  await api(base() + "move", "POST", {
                    path,
                    revision,
                    destination: dest,
                  });
                  clear();
                  await refresh();
                })}
            >
              Move
            </button>
            <button
              onclick={() =>
                run(async () => {
                  if (confirm("Delete " + path + "?")) {
                    await api(base() + "delete", "POST", { path, revision });
                    clear();
                    await refresh();
                  }
                })}
            >
              Delete
            </button>
          </details>{/if}
        {#if selected}{#key selected.path}<Comments
              {people}
              base={base()}
              path={selected.path}
              {user}
            />{/key}{/if}
      </section>
    </div>{/if}{/if}

<style>
  .workspace.wide {
    grid-template-columns: minmax(0, 3fr) minmax(16rem, 2fr);
  }
  .board {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 0.4rem;
  }
  .task {
    border: 1px solid #b7c7bf;
    padding: 0.4rem;
  }
  .task select,
  .task button {
    max-width: 100%;
  }
  @media (max-width: 700px) {
    .workspace.wide {
      grid-template-columns: 1fr;
    }
  }
  nav {
    display: flex;
    gap: 0.4rem;
    flex-wrap: wrap;
    margin: 1rem 0;
  }
  button,
  input,
  textarea,
  select {
    font: inherit;
    padding: 0.35rem 0.55rem;
  }
  button {
    cursor: pointer;
  }
  button[aria-pressed="true"] {
    background: #214e42;
    color: white;
  }
  .workspace {
    display: grid;
    grid-template-columns: minmax(12rem, 1fr) minmax(0, 3fr);
    gap: 2rem;
  }
  section,
  aside {
    min-width: 0;
  }
  label {
    display: grid;
    margin: 0.6rem 0;
  }
  ul {
    padding: 0;
    list-style: none;
  }
  article {
    overflow-wrap: anywhere;
  }
  textarea {
    font-family: monospace;
  }
  details {
    margin-top: 1rem;
  }
  @media (max-width: 700px) {
    .workspace {
      grid-template-columns: 1fr;
    }
  }
</style>
