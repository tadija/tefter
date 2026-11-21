<script lang="ts">
  import { onMount } from "svelte";
  import { preview } from "./markdown";
  import { api } from "./api";
  let {
    base,
    path,
    user,
    people,
  }: {
    base: string;
    path: string;
    user: string;
    people: { id: string; name: string }[];
  } = $props();
  type Comment = {
    id: string;
    author: string;
    parent?: string;
    body: string;
    deleted: boolean;
    created: string;
  };
  type Thread = { revision: string; comments: Comment[]; next?: number };
  let thread = $state<Thread>(),
    body = $state(""),
    parent = $state<string>(),
    edit = $state<string>(),
    error = $state("");
  onMount(async () => {
    try {
      thread = await api(base + "comments?path=" + encodeURIComponent(path));
    } catch (e) {
      error = String(e);
    }
  });
  async function more() {
    if (!thread || thread.next === undefined) return;
    try {
      const page = await api<Thread>(
        base +
          "comments?path=" +
          encodeURIComponent(path) +
          "&offset=" +
          thread.next,
      );
      if (thread.revision !== page.revision) {
        thread = await api(base + "comments?path=" + encodeURIComponent(path));
        return;
      }
      thread = { ...page, comments: [...thread.comments, ...page.comments] };
    } catch (e) {
      error = String(e);
    }
  }
  async function submit(remove = false) {
    try {
      thread = await api(base + "comments", "POST", {
        path,
        revision: thread?.revision,
        body: remove ? undefined : body,
        parent,
        id: edit,
      });
      parent = undefined;
      edit = undefined;
      body = "";
      error = "";
    } catch (e) {
      error = String(e);
    }
  }
</script>

<h3>Comments</h3>
{#if error}<p role="alert">{error}</p>{/if}
{#if thread}
  {#each thread.comments as c}
    <div style:margin-left={c.parent ? "1.5rem" : "0"}>
      <small>
        {people.find((p) => p.id === c.author)?.name ?? c.author} · {c.created}
      </small>
      {#if c.deleted}<p>Deleted comment</p>{:else}<div>
          {@html preview(c.body)}
        </div>{/if}
      {#if !c.deleted}{#if !c.parent}<button
            onclick={() => {
              parent = c.id;
              edit = undefined;
              body = "";
            }}
          >
            Reply
          </button>{/if}
        {#if c.author === user}<button
            onclick={() => {
              edit = c.id;
              parent = undefined;
              body = c.body;
            }}
          >
            Edit
          </button>
          <button
            onclick={() => {
              if (confirm("Delete this comment?")) {
                edit = c.id;
                submit(true);
              }
            }}
          >
            Delete
          </button>{/if}{/if}
    </div>
  {:else}<p>No comments yet.</p>{/each}
  {#if thread.next !== undefined}<button onclick={more}>
      More comments
    </button>{/if}
  <label>
    {edit ? "Edit comment" : parent ? "Reply" : "New comment"}
    <textarea bind:value={body}></textarea>
  </label>
  <button disabled={!body.trim()} onclick={() => submit()}>Save comment</button>
  {#if edit || parent}<button
      onclick={() => {
        edit = undefined;
        parent = undefined;
        body = "";
      }}
    >
      Cancel
    </button>{/if}
{/if}
