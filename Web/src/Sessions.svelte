<script lang="ts">
  import { onMount } from "svelte";
  import { api, listing } from "./api";
  import { preview } from "./markdown";
  let {space}: {space: string} = $props();
  type Harness = {id: string; name: string; capabilities: Record<string, boolean>};
  type Session = {id: string; status: string; connection: string; initiator: string; task?: string; repo?: string; conversation: {role: string; text: string; created: string}[]};
  let harnesses = $state<Harness[]>([]), sessions = $state<Session[]>([]);
  let selected = $state<Session>(), connection = $state(""), message = $state(""), task = $state(""), repo = $state("");
  type Review = {head: string; base: string; diff: string};
  let review = $state<Review>();
  async function gitAction(action: string) {
    if (!selected) return;
    error = ""; busy = true;
    try {
      const path = base()+`executions/${selected.id}/`;
      if (action === "review") review = await api(path+action);
      else if (action === "worktree") { await api(path+action, "POST"); review = await api(path+"review"); }
      else if (review) review = await api(path+action, "POST", {approve:true, head:review.head, base:review.base});
    } catch(e) {error = String(e);} finally {busy = false;}
  }
  let error = $state(""), loading = $state(true), busy = $state(false);
  const base = () => `spaces/${space}/`;
  async function load() {
    try {
      harnesses = (await api<{harnesses: Harness[]}>(base()+"harnesses")).harnesses;
      connection ||= harnesses[0]?.id ?? "";
      sessions = await listing(base()+"executions", "sessions");
    } catch(e) {error = String(e);} finally {loading = false;}
  }
  async function send(event: SubmitEvent) {
    event.preventDefault(); busy = true; error = "";
    try {
      selected = await api(selected ? base()+`executions/${selected.id}/messages` : base()+"executions", "POST",
        selected ? {message} : {connection, message, task: task || null, repo: repo || null});
      message = ""; await load();
    } catch(e) {error = String(e);} finally {busy = false;}
  }
  async function finish() {
    try {selected = await api(base()+`executions/${selected!.id}/finish`, "POST"); await load();}
    catch(e) {error = String(e);}
  }
  onMount(load);
</script>
<h2>Agent sessions</h2>
{#if error}<p role="alert">{error}</p>{/if}
{#if loading}<p>Loading…</p>{:else if !harnesses.length}<p>No execution connection authorized for you in this space. Space membership alone does not grant execution access.</p>{/if}
<p>Structured conversation is saved by Tefter. This adapter sends the transcript on each turn; harness resume, live streaming, cancellation and TTY are unavailable. Each turn has a two-minute deadline.</p>
<button disabled={busy} onclick={() => {selected = undefined; review = undefined;}}>New session</button>
{#each sessions as session (session.id)}<button disabled={busy} onclick={() => {selected = session; review = undefined;}}>{session.id.slice(0,8)} · {session.status}</button>{/each}
{#if selected}
  <p>Status: {selected.status} · Initiator: {selected.initiator}</p>
  {#each selected.conversation as turn}<article><strong>{turn.role}</strong> <time>{turn.created}</time><div class="markdown">{@html preview(turn.text)}</div></article>{/each}
  {#if selected.repo}
    <p>Linked Repo: {selected.repo}. Worktrees are separate editing directories; they do not provide a security sandbox.</p>
    <button disabled={busy} onclick={() => gitAction("worktree")}>Create session branch and worktree</button>
    <button disabled={busy} onclick={() => gitAction("review")}>Review committed diff</button>
    {#if review}
      <p>Base: {review.base} · Reviewed commit: {review.head}</p><pre>{review.diff || "No committed changes"}</pre>
      <button disabled={busy} onclick={() => gitAction("merge")}>Approve fast-forward merge of reviewed commit (space owner)</button>
      <button disabled={busy} onclick={() => gitAction("push")}>Approve push of reviewed session branch (space owner)</button>
    {/if}
  {/if}
  <button disabled={busy || selected.status === "running" || selected.status === "finished"} onclick={finish}>Finish session</button>
{/if}
<form onsubmit={send}>
  {#if !selected}
    <label>Connection <select bind:value={connection}>{#each harnesses as harness}<option value={harness.id}>{harness.name}</option>{/each}</select></label>
    <label>Task ID (optional) <input bind:value={task} /></label>
    <label>Repo ID (optional) <input bind:value={repo} /></label>
  {/if}
  <label>Message <textarea bind:value={message} required maxlength="16384" disabled={busy}></textarea></label>
  <button disabled={busy || !connection || selected?.status === "finished"}>{busy ? "Running…" : selected ? "Send" : "Start session"}</button>
</form>
