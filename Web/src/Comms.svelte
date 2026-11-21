<script lang="ts">
  import { onMount } from "svelte";
  import { api, listing } from "./api";
  import { preview } from "./markdown";
  let {
    space,
    people,
    documents,
    openEntity,
    promote,
  }: {
    space: string;
    people: { id: string; name: string }[];
    documents: { id?: string; path: string; title: string }[];
    openEntity: (path: string) => void;
    promote: (body: string, task: boolean) => void;
  } = $props();
  type Message = {
    id: string;
    sequence: number;
    author: string;
    authorKind: string;
    created: string;
    body: string;
    nonce: string;
  };
  let channels = $state<{ id: string; name: string }[]>([]);
  let channel = $state("");
  let messages = $state<Message[]>([]);
  let agents = $state<{ id: string; name: string }[]>([]);
  let name = $state(""),
    body = $state(""),
    error = $state(""),
    connection = $state("Loading…"),
    busy = $state(false);
  let identified = $state<{ id?: string; path: string; title: string }[]>([]);
  const entities = $derived([
    ...new Map([...documents, ...identified].map((d) => [d.path, d])).values(),
  ]);
  async function reference(path: string) {
    if (!path) return;
    try {
      const file = await api<{
        document: { id: string; path: string; title: string };
      }>(base() + "identify", "POST", { path });
      identified = [
        ...identified.filter((d) => d.path !== path),
        file.document,
      ];
      body += " [[" + file.document.id + "]]";
    } catch (e) {
      error = String(e);
    }
  }
  let pending: { body: string; nonce: string } | undefined;
  const base = () => `spaces/${space}/`;
  const participants = $derived([
    ...new Map([...people, ...agents].map((p) => [p.id, p])).values(),
  ]);
  const authorName = (id: string) =>
    participants.find((p) => p.id === id)?.name ?? id;
  onMount(() => {
    let stopped = false;
    async function load() {
      try {
        channels = (
          await api<{ channels: typeof channels }>(base() + "channels")
        ).channels;
        agents = await listing(base() + "agents", "agents");
        if (!stopped) channel = channels[0]?.id ?? "";
      } catch (e) {
        error = String(e);
      }
    }
    load();
    return () => {
      stopped = true;
    };
  });
  $effect(() => {
    const id = channel;
    if (!id) return;
    let stopped = false,
      socket: WebSocket | undefined,
      retry: ReturnType<typeof setTimeout> | undefined;
    messages = [];
    let cursor = 0;
    function connect() {
      connection = "Connecting…";
      const url = new URL(
        `/api/v1/${base()}channels/${id}/live?after=${cursor}`,
        location.href,
      );
      url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
      socket = new WebSocket(url);
      socket.onopen = () => {
        connection = "Live";
        error = "";
      };
      socket.onmessage = (event) => {
        if (stopped) return;
        const message: Message = JSON.parse(event.data);
        if (message.sequence <= cursor) return;
        cursor = message.sequence;
        messages = [...messages, message].slice(-500);
      };
      socket.onclose = async () => {
        if (stopped) return;
        connection = "Disconnected; reconnecting…";
        try {
          await api(base() + `channels/${id}/messages?after=${cursor}`);
          if (!stopped) retry = setTimeout(connect, 1500);
        } catch (e) {
          messages = [];
          connection = "Access unavailable";
          error = String(e);
        }
      };
    }
    connect();
    return () => {
      stopped = true;
      socket?.close();
      if (retry) clearTimeout(retry);
    };
  });
  async function send(e: SubmitEvent) {
    e.preventDefault();
    busy = true;
    error = "";
    if (!pending || pending.body !== body)
      pending = { body, nonce: crypto.randomUUID() };
    try {
      await api(base() + `channels/${channel}/messages`, "POST", pending);
      pending = undefined;
      body = "";
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }
  function refs(text: string) {
    const ids = [...text.matchAll(/\[\[([0-9a-f-]{36})\]\]/gi)].map((m) =>
      m[1].toLowerCase(),
    );
    return entities.filter((d) => d.id && ids.includes(d.id.toLowerCase()));
  }
</script>

<section aria-label="Comms">
  <h2>Comms</h2>
  <p>
    Channel messages expire after the configured retention period. Promote
    lasting decisions to documents or tasks.
  </p>
  {#if error}<p role="alert">{error}</p>{/if}
  <label for="comms-channel">Channel</label><select
    id="comms-channel"
    bind:value={channel}
  >
    {#each channels as item}<option value={item.id}>#{item.name}</option>{/each}
  </select>
  <form
    onsubmit={async (e) => {
      e.preventDefault();
      try {
        channels = (
          await api<{ channels: typeof channels }>(
            base() + "channels",
            "POST",
            { name },
          )
        ).channels;
        channel = channels[channels.length - 1].id;
        name = "";
        error = "";
      } catch (e) {
        error = String(e);
      }
    }}
  >
    <label>
      New channel <input
        bind:value={name}
        pattern={"[a-z0-9][a-z0-9_\\-]{0,63}"}
        required
      />
    </label><button>Create channel</button>
  </form>
  <p role="status">{connection}</p>
  <ol aria-label="Channel messages">
    {#each messages as message (message.id)}
      <li>
        <p>
          <strong>{authorName(message.author)}</strong>
          {message.authorKind === "agent" ? "(agent)" : ""}
          <time datetime={message.created}>
            {new Date(message.created).toLocaleString()}
          </time>
        </p>
        <article>{@html preview(message.body)}</article>
        {#each participants.filter( (p) => message.body.includes("@" + p.id) ) as mentioned}<span>
            Mention: {mentioned.name}
          </span>{/each}
        {#each refs(message.body) as doc}<button
            onclick={() => openEntity(doc.path)}
          >
            Open {doc.title}
          </button>{/each}
        <button
          onclick={() =>
            promote(
              `From Comms #${channels.find((c) => c.id === channel)?.name} · ${authorName(message.author)} · ${message.created}\nMessage ${message.id}\n\n${message.body}`,
              false,
            )}
        >
          Promote to document
        </button>
        <button
          onclick={() =>
            promote(
              `From Comms · ${authorName(message.author)} · ${message.created}\nMessage ${message.id}\n\n${message.body}`,
              true,
            )}
        >
          Promote to task
        </button>
      </li>
    {:else}<li>No messages yet.</li>{/each}
  </ol>
  <form onsubmit={send}>
    <label>
      Message <textarea bind:value={body} maxlength="16384" required rows="4"
      ></textarea>
    </label>
    <label>
      Mention <select
        value=""
        onchange={(e) => {
          if (e.currentTarget.value) body += " @" + e.currentTarget.value;
        }}
      >
        <option value="">
          Choose a participant
        </option>{#each participants as person}<option value={person.id}>
            {person.name}
          </option>{/each}
      </select>
    </label>
    <label>
      Entity reference <select
        value=""
        onchange={(e) => reference(e.currentTarget.value)}
      >
        <option value="">Choose a document</option>
        {#each entities as doc}<option value={doc.path}>
            {doc.title}
          </option>{/each}
      </select>
    </label>
    <button disabled={busy || !channel || !body.trim()}>Send message</button>
  </form>
</section>

<style>
  form {
    display: flex;
    flex-wrap: wrap;
    align-items: end;
    gap: 0.6rem;
    margin: 1rem 0;
  }
  label {
    display: grid;
    gap: 0.3rem;
  }
  textarea {
    width: min(38rem, 80vw);
  }
  li {
    border-bottom: 1px solid #b7c7bf;
    padding: 0.7rem 0;
  }
  ol {
    list-style: none;
    padding: 0;
    max-height: 32rem;
    overflow: auto;
  }
  article {
    overflow-wrap: anywhere;
  }
  button,
  input,
  select,
  textarea {
    font: inherit;
    padding: 0.4rem;
  }
</style>
