<script lang="ts">
  import Comments from "./Comments.svelte";
  import { onMount } from "svelte";
  import { api } from "./api";
  let { space, user, people }: { space: string; user: string; people: {id: string; name: string}[] } = $props();
  let commentRepo = $state("");
  type Repo = { id: string; space?: string; name: string; location: string; description: string };
  let repos = $state<Repo[]>([]), error = $state(""), loading = $state(true);
  let status = $state<Record<string, {available: boolean; branch?: string; head?: string; status?: string; commits?: string}>>({});
  async function inspect(id: string, clone = false) {
    error = "";
    try { status[id] = await api(`spaces/${space}/repos/${id}/${clone ? "checkout" : "status"}`, clone ? "POST" : "GET"); }
    catch(e) { error = String(e); }
  }
  let name = $state(""), location = $state(""), description = $state("");
  async function load() {
    try {
      const result: Repo[] = [];
      let offset: number | undefined = 0;
      while (offset !== undefined) {
        const page: {repos: Repo[]; next?: number} = await api(`repos?space=${space}&offset=${offset}`);
        result.push(...page.repos); offset = page.next;
      }
      repos = result;
    } catch (e) { error = String(e); }
    finally { loading = false; }
  }
  async function create(event: SubmitEvent) {
    event.preventDefault(); error = "";
    try { await api("repos", "POST", {space, name, location, description}); name = location = description = ""; await load(); }
    catch (e) { error = String(e); }
  }
  onMount(load);
</script>
<h2>Repos</h2>
{#if error}<p role="alert">{error}</p>{/if}
{#if loading}<p>Loading repositories…</p>{:else if !repos.length}<p>No repositories registered or granted to this space.</p>{/if}
{#each repos as repo (repo.id)}
  <article><h3>{repo.name}</h3><p>{repo.description}</p><code>{repo.location}</code>
    <p>{repo.space ? "Owned by this space" : "Installation repository · explicitly granted"}</p>
    <small>Reference: {repo.id}</small>
    <button onclick={() => commentRepo = commentRepo === repo.id ? "" : repo.id}>Comments</button>
    {#if commentRepo === repo.id}{#key repo.id}<Comments base={`spaces/${space}/repos/${repo.id}/`} path="" {user} {people} />{/key}{/if}
    <button onclick={() => inspect(repo.id)}>Status and commits</button>
    <button onclick={() => inspect(repo.id, true)}>Create separate checkout (installation admin)</button>
    {#if status[repo.id]}{#if status[repo.id].available}
      <p>Branch: {status[repo.id].branch} · Commit: {status[repo.id].head}</p>
      <pre>{status[repo.id].status || "Clean checkout"}</pre><pre>{status[repo.id].commits}</pre>
    {:else}<p>No checkout available.</p>{/if}{/if}
  </article>
{/each}
<form onsubmit={create}>
  <h3>Register a space repository</h3>
  <p>Requires space owner or admin. Checkouts and credentials are configured separately.</p>
  <label>Name <input bind:value={name} required maxlength="200" /></label>
  <label>Credential-free URL or absolute local path <input bind:value={location} required maxlength="2048" /></label>
  <label>Description <input bind:value={description} maxlength="4096" /></label>
  <button>Register Repo</button>
</form>
