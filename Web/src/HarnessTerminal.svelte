<script lang="ts">
  import { onMount } from "svelte";
  import { Terminal } from "@xterm/xterm";
  import { FitAddon } from "@xterm/addon-fit";
  import "@xterm/xterm/css/xterm.css";
  import { api } from "./api";

  let { path, onclose }: { path: string; onclose: () => void } = $props();
  let surface: HTMLDivElement;
  let status = $state("Connecting…");

  onMount(() => {
    const emulator = new Terminal({ fontSize: 14, screenReaderMode: true });
    const fit = new FitAddon();
    emulator.loadAddon(fit);
    emulator.open(surface);
    let socket: WebSocket | undefined;
    let disposed = false;
    function resize() {
      const size = fit.proposeDimensions();
      if (!size) return;
      const cols = Math.max(2, Math.min(500, size.cols));
      const rows = Math.max(2, Math.min(300, size.rows));
      emulator.resize(cols, rows);
      if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({cols, rows}));
    }
    const observer = new ResizeObserver(resize);
    observer.observe(surface);
    function send(bytes: Uint8Array) {
      if (socket?.readyState !== WebSocket.OPEN) return;
      for (let i = 0; i < bytes.length; i += 65536) socket.send(bytes.slice(i, i + 65536));
    }
    emulator.onData(text => send(new TextEncoder().encode(text)));
    emulator.onBinary(text => send(Uint8Array.from(text, c => c.charCodeAt(0))));
    async function connect() {
      try {
        const {ticket} = await api<{ticket: string}>(path, "POST");
        if (disposed) return;
        const url = new URL("/api/v1/" + path + "/" + ticket, location.href);
        url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
        socket = new WebSocket(url);
        socket.binaryType = "arraybuffer";
        socket.onopen = () => { status = "Connected"; resize(); emulator.focus(); };
        socket.onmessage = event => { if (!disposed) emulator.write(new Uint8Array(event.data)); };
        socket.onclose = () => { status = "Disconnected"; };
      } catch (error) { if (!disposed) status = String(error); }
    }
    void connect();
    return () => { disposed = true; socket?.close(); observer.disconnect(); emulator.dispose(); };
  });
</script>
<section aria-label="Harness terminal">
  <p role="status">{status}</p>
  <div class="terminal" bind:this={surface}></div>
  <button onclick={onclose}>Close terminal</button>
</section>

<style>
  .terminal { height: min(55vh, 32rem); min-height: 10rem; background: #000; padding: .5rem; }
</style>
