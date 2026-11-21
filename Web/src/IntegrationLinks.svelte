<script lang="ts">
  import {onMount} from "svelte";
  import {api} from "./api";
  let {space, path}: {space: string; path: string} = $props();
  type Item = {link: {id: string; kind: string; target: string}; available: boolean; title?: string};
  type Page = {revision: string; links: Item[]; next?: number};
  let page = $state<Page>(), kind = $state("repo"), target = $state(""), error = $state("");
  const endpoint = () => `spaces/${space}/integration-links`;
  async function load() {
    try {page = await api(endpoint()+"?path="+encodeURIComponent(path));} catch(e) {error=String(e);}
  }
  async function more() {
    if (!page || page.next === undefined) return;
    try {
      const next: Page = await api(endpoint()+"?path="+encodeURIComponent(path)+"&offset="+page.next);
      if (next.revision !== page.revision) {await load(); return;}
      page = {...next, links:[...page.links,...next.links]};
    } catch(e) {error=String(e);}
  }
  async function change(remove?: string) {
    error="";
    try {page = await api(endpoint(),"POST",{path, revision:page?.revision, kind, target, remove}); target="";}
    catch(e) {error=String(e);}
  }
  onMount(load);
</script>
<details><summary>Repo and session references</summary>
{#if error}<p role="alert">{error}</p>{/if}
{#each page?.links ?? [] as item (item.link.id)}<p>{item.title ?? "Unavailable reference"} · {item.link.kind} <code>{item.link.target}</code> <button onclick={() => change(item.link.id)}>Remove reference</button></p>{/each}
{#if page?.next !== undefined}<button onclick={more}>More references</button>{/if}
<form onsubmit={(event) => {event.preventDefault(); change();}}>
  <label>Reference type <select bind:value={kind}><option value="repo">Repo</option><option value="session">Session</option></select></label>
  <label>Target ID <input bind:value={target} required /></label><button disabled={!page}>Attach reference</button>
</form></details>
