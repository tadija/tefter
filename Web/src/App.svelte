<script lang="ts">
  import { onMount } from 'svelte'
  let status = $state('Connecting…')
  onMount(async () => {
    try {
      const response = await fetch('/api/v1/health')
      status = response.ok && (await response.json()).status === 'ok' ? 'Connected' : 'Server unavailable'
    } catch {
      status = 'Server unavailable'
    }
  })
</script>

<h1>Tefter</h1>
<p role="status">{status}</p>
