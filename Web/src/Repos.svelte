<script lang="ts">
  import { onMount } from "svelte";
  import { api } from "./api";
  let { space }: { space: string } = $props();
  type Repo = { id: string; space?: string; name: string; location: string; description: string };
  let repos = $state<Repo[]>([]), error = $state(""), loading = $state(true);
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
