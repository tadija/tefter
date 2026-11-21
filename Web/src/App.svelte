<script lang="ts">
  import { onMount } from 'svelte'
  import { api } from './api'
  type Space = { id: string; name: string; role: string }
  let spaces = $state<Space[]>([])
  let selected = $state('')
  let email = $state('')
  let password = $state('')
  let error = $state('')
  let busy = $state(true)
  let signedIn = $state(false)

  async function load() {
    spaces = (await api<{ spaces: Space[] }>('spaces')).spaces
    selected = spaces[0]?.id ?? ''
    signedIn = true
  }
  onMount(async () => {
    try { await api('session'); await load() }
    catch (e) { if (!String(e).includes('(401)')) error = String(e) }
    finally { busy = false }
  })
  async function login(e: SubmitEvent) {
    e.preventDefault()
    busy = true
    error = ''
    try { await api('login', 'POST', {email, password}); password = ''; await load() }
    catch (e) { error = String(e) }
    finally { busy = false }
  }
  async function logout() {
    try { await api('logout', 'POST'); signedIn = false; spaces = []; selected = ''; error = '' }
    catch (e) { error = String(e) }
  }
</script>

<header><h1>Tefter</h1>{#if signedIn}<button onclick={logout}>Sign out</button>{/if}</header>
{#if error}<p role="alert">{error}</p>{/if}
{#if busy}<p role="status">Loading…</p>
{:else if !signedIn}
  <form onsubmit={login}>
    <label>Email <input type="email" bind:value={email} required autocomplete="username"/></label>
    <label>Password <input type="password" bind:value={password} required autocomplete="current-password"/></label>
    <button>Sign in</button>
  </form>
{:else}
  <label>Space <select bind:value={selected}>{#each spaces as space}<option value={space.id}>{space.name}</option>{/each}</select></label>
{/if}

<style>
  :global(body) { font: 1rem/1.5 system-ui,sans-serif; color: #202d2b; margin: 0; background: #f9faf7 }
  :global(main) { max-width: 78rem; margin: auto; padding: clamp(1rem,4vw,3rem) }
  header { display:flex; justify-content:space-between; align-items:center; border-bottom:1px solid #b7c7bf; margin-bottom:1.5rem }
  form,label { display:grid; gap:.4rem } form { max-width:22rem; gap:1rem }
  button,input,select { font:inherit; padding:.45rem .75rem } button { cursor:pointer }
</style>
