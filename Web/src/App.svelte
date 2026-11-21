<script lang="ts">
  import { onMount } from "svelte";
  import Account from "./Account.svelte";
  import Workspace from "./Workspace.svelte";
  import { api, listing } from "./api";
  type Space = { id: string; name: string; role: string };
  let spaces = $state<Space[]>([]);
  let selected = $state("");
  let user = $state(""),
    recovery = $state("");
  let email = $state("");
  let password = $state("");
  let error = $state("");
  let busy = $state(true);
  let signedIn = $state(false);

  async function load() {
    user = (await api<{ user: string }>("session")).user;
    spaces = await listing<Space>("spaces", "spaces");
    if (!spaces.some((s) => s.id === selected)) selected = spaces[0]?.id ?? "";
    signedIn = true;
  }
  onMount(async () => {
    if (location.hash.startsWith("#recover=")) {
      recovery = location.hash.slice(9);
      history.replaceState(null, "", location.pathname);
      busy = false;
      return;
    }
    try {
      await load();
    } catch (e) {
      if (!String(e).includes("(401)")) error = String(e);
    } finally {
      busy = false;
    }
  });
  async function login(e: SubmitEvent) {
    e.preventDefault();
    busy = true;
    error = "";
    try {
      await api("login", "POST", { email, password });
      password = "";
      await load();
    } catch (e) {
      error = String(e);
    } finally {
      busy = false;
    }
  }
  async function logout() {
    try {
      await api("logout", "POST");
      signedIn = false;
      spaces = [];
      selected = "";
      error = "";
    } catch (e) {
      error = String(e);
    }
  }
</script>

<header>
  <h1>Tefter</h1>
  {#if signedIn}<button onclick={logout}>Sign out</button>{/if}
</header>
{#if error}<p role="alert">{error}</p>{/if}
{#if busy}<p role="status">Loading…</p>
{:else if recovery}
  <form
    onsubmit={async (e) => {
      e.preventDefault();
      try {
        await api("recovery/redeem", "POST", { token: recovery, password });
        password = "";
        recovery = "";
        error = "";
      } catch (e) {
        error = String(e);
      }
    }}
  >
    <label>
      New password <input
        type="password"
        minlength="12"
        required
        bind:value={password}
        autocomplete="new-password"
      />
    </label><button>Set password</button>
  </form>
{:else if !signedIn}
  <form onsubmit={login}>
    <label>
      Email <input
        type="email"
        bind:value={email}
        required
        autocomplete="username"
      />
    </label>
    <label>
      Password <input
        type="password"
        bind:value={password}
        required
        autocomplete="current-password"
      />
    </label>
    <button>Sign in</button>
  </form>
{:else}
  <Account
    {user}
    {spaces}
    reload={load}
    signedOut={() => {
      signedIn = false;
      spaces = [];
      selected = "";
    }}
  />
  <label>
    Space <select bind:value={selected}>
      {#each spaces as space}<option value={space.id}>
          {space.name}
        </option>{/each}
    </select>
  </label>
  {#if selected}{#key selected}<Workspace space={selected} />{/key}{/if}
{/if}

<style>
  :global(body) {
    font:
      1rem/1.5 system-ui,
      sans-serif;
    color: #202d2b;
    margin: 0;
    background: #f9faf7;
  }
  :global(main) {
    max-width: 78rem;
    margin: auto;
    padding: clamp(1rem, 4vw, 3rem);
  }
  header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-bottom: 1px solid #b7c7bf;
    margin-bottom: 1.5rem;
  }
  form,
  label {
    display: grid;
    gap: 0.4rem;
  }
  form {
    max-width: 22rem;
    gap: 1rem;
  }
  button,
  input,
  select {
    font: inherit;
    padding: 0.45rem 0.75rem;
  }
  button {
    cursor: pointer;
  }
</style>
