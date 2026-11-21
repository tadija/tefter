<script lang="ts">
  import { onMount } from "svelte";
  import { api, listing } from "./api";
  import { preview } from "./markdown";
  let {
    space,
    selectedReference = "",
  }: { space: string; selectedReference?: string } = $props();
  type Ref = { id: string; source: string; entity: string; target: string };
  type View = {
    reference: Ref;
    available: boolean;
    document?: { title: string; path: string };
    allowExport: boolean;
  };
  type Grant = {
    id: string;
    entity: string;
    target: string;
    allowExport: boolean;
  };
  type Shared = {
    reference: Ref;
    file: { text: string; document: { title: string } };
    comments: {
      comments: {
        id: string;
        author: string;
        body: string;
        deleted: boolean;
      }[];
      next?: number;
    };
  };
  let refs = $state<View[]>([]),
    grants = $state<Grant[]>([]);
  let owner = $state(false),
    loading = $state(true),
    error = $state("");
  let path = $state(""),
    target = $state(""),
    allowExport = $state(false),
    grant = $state("");
  let commentOffset = $state(0);
  let selected = $state(""),
    shared = $state<Shared>();
  let agentName = $state(""),
    agentID = $state(""),
    agentToken = $state("");
  let agents = $state<{ id: string; name: string }[]>([]);
  const base = () => `spaces/${space}/`;
  async function refresh() {
    refs = await listing(base() + "references", "references");
    if (owner) grants = await listing(base() + "shares", "grants");
    agents = await listing(base() + "agents", "agents");
    if (selected) {
      try {
        shared = await api<Shared>(
          base() + "references/" + selected + "?offset=" + commentOffset,
        );
      } catch {
        shared = undefined;
        selected = "";
        error = "Shared content is unavailable.";
      }
    }
  }
  async function run(work: () => Promise<void>) {
    error = "";
    try {
      await work();
      await refresh();
    } catch (e) {
      error = String(e);
    }
  }
  onMount(() => {
    let active = true;
    (async () => {
      try {
        const spaces = listing<{ id: string; role: string }>(
          "spaces",
          "spaces",
        );
        owner = (await spaces).find((s) => s.id === space)?.role === "owner";
        if (active) {
          selected = selectedReference;
          await refresh();
        }
      } catch (e) {
        error = String(e);
      } finally {
        loading = false;
      }
    })();
    const timer = setInterval(() => {
      if (active)
        refresh().catch((e) => {
          shared = undefined;
          refs = [];
          error = String(e);
        });
    }, 2000);
    return () => {
      active = false;
      clearInterval(timer);
      agentToken = "";
      shared = undefined;
    };
  });
</script>

<section aria-label="Sharing">
  <h2>Sharing</h2>
  <p>Space ID: <code>{space}</code></p>
  <p>
    Shared content stays in its source space. The source owner can revoke access
    or permission to export copies.
  </p>
  {#if error}<p role="alert">{error}</p>{/if}
  {#if loading}<p role="status">Loading shared references…</p>{/if}
  <form
    onsubmit={(e) => {
      e.preventDefault();
      run(async () => {
        await api(base() + "references", "POST", { grant });
        grant = "";
      });
    }}
  >
    <label>Grant ID <input bind:value={grant} required /></label><button>
      Add shared reference
    </button>
  </form>
  {#each refs as ref}
    <p>
      {#if ref.available}<button
          onclick={() =>
            run(async () => {
              selected = ref.reference.id;
              commentOffset = 0;
              shared = undefined;
            })}
        >
          {ref.document?.title}
        </button>
      {:else}<span>Shared content unavailable</span>{/if}
      <span>
        · Source {ref.reference.source} · Entity {ref.reference.entity}
      </span>
      <button
        onclick={() =>
          run(async () => {
            await api(base() + "references/" + ref.reference.id, "DELETE");
            if (selected === ref.reference.id) {
              selected = "";
              shared = undefined;
            }
          })}
      >
        Remove reference
      </button>
    </p>
  {:else}<p>No shared references.</p>{/each}
  {#if shared}
    <article aria-label="Shared preview">
      <h3>{shared.file.document.title}</h3>
      <p>
        Read-only · Source {shared.reference.source} · Entity {shared.reference
          .entity}
      </p>
      {@html preview(shared.file.text)}
    </article>
    <h4>Shared comments</h4>
    {#each shared.comments.comments.filter((c) => !c.deleted) as comment}<article>
        <p>Author {comment.author}</p>
        {@html preview(comment.body)}
      </article>{/each}
    {#if commentOffset > 0}<button
        onclick={() =>
          run(async () => {
            commentOffset = Math.max(0, commentOffset - 100);
          })}
      >
        Previous shared comments
      </button>{/if}
    {#if shared.comments.next !== undefined}<button
        onclick={() =>
          run(async () => {
            commentOffset = shared!.comments.next!;
          })}
      >
        More shared comments
      </button>{/if}
  {/if}
  <p>
    <a href={"/api/v1/" + base() + "export"} download>Export with references</a>
    ·
    <a href={"/api/v1/" + base() + "export?includeShared=true"} download>
      Export with owner-approved shared copies
    </a>
  </p>
  {#if owner}
    <h3>Source-owner grants</h3>
    <form
      onsubmit={(e) => {
        e.preventDefault();
        run(async () => {
          const value = await api<Grant>(base() + "shares", "POST", {
            path,
            target,
            allowExport,
          });
          grant = value.id;
        });
      }}
    >
      <label>Source file path <input bind:value={path} required /></label>
      <label>Destination space ID <input bind:value={target} required /></label>
      <label>
        <input type="checkbox" bind:checked={allowExport} /> Allow exported copies,
        including comments and attribution
      </label>
      <button>Grant sharing</button>
    </form>
    <p>
      Give the grant ID to a member of the destination space to add the
      reference.
    </p>
    {#each grants as item}<p>
        Grant <code>{item.id}</code> → {item.target} · copies {item.allowExport
          ? "allowed"
          : "denied"}
        <button
          onclick={() =>
            run(async () => {
              await api(base() + "shares/" + item.id, "DELETE");
            })}
        >
          Revoke grant
        </button>
      </p>{/each}
  {/if}
  <details>
    <summary>Agent participation</summary>
    <p>
      Installation admins register persistent agents. Space owners and admins
      grant Comms access. A token authorizes messaging only.
    </p>
    <form
      onsubmit={(e) => {
        e.preventDefault();
        run(async () => {
          const result = await api<{ id: string; token: string }>(
            "agents",
            "POST",
            { name: agentName },
          );
          agentID = result.id;
          agentToken = result.token;
          agentName = "";
        });
      }}
    >
      <label>
        Agent name <input bind:value={agentName} required />
      </label><button>Register agent</button>
    </form>
    {#if agentToken}<p>Save this credential securely; it is shown once.</p>
      <label>
        Agent bearer token <input readonly value={agentToken} />
      </label><button onclick={() => (agentToken = "")}>Hide token</button>{/if}
    <form
      onsubmit={(e) => {
        e.preventDefault();
        run(async () => {
          await api(base() + "agents", "PUT", { id: agentID });
          agentID = "";
        });
      }}
    >
      <label>Agent ID <input bind:value={agentID} required /></label><button>
        Grant Comms access
      </button>
    </form>
    {#each agents as agent}<p>
        {agent.name} · {agent.id}
        <button
          onclick={() =>
            run(async () => {
              await api(base() + "agents", "DELETE", { id: agent.id });
            })}
        >
          Revoke agent
        </button>
      </p>{/each}
  </details>
</section>

<style>
  form {
    display: flex;
    flex-wrap: wrap;
    gap: 0.6rem;
    align-items: end;
    margin: 1rem 0;
  }
  label {
    display: grid;
    gap: 0.3rem;
  }
  button,
  input {
    font: inherit;
    padding: 0.4rem;
  }
  article,
  p {
    overflow-wrap: anywhere;
  }
  article {
    padding: 1rem;
    border: 1px solid #b7c7bf;
  }
</style>
