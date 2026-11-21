<script lang="ts">
  import {onMount} from "svelte";
  import {api} from "./api";
  let {space, channel, people}: {space: string; channel: string; people: {id: string; name: string}[]} = $props();
  type Participant = {id: string; user: string; muted: boolean};
  type Event = {type: string; id?: string; participants?: Participant[]; from?: string; payload?: string};
  type Peer = {pc: RTCPeerConnection; candidates: RTCIceCandidateInit[]; audio: HTMLAudioElement};
  let participants = $state<Participant[]>([]), joined = $state(false), joining = $state(false), muted = $state(false), error = $state("");
  let own = $state("");
  let generation = 0, csrf = "", socket: WebSocket | undefined, stream: MediaStream | undefined;
  let timer: ReturnType<typeof setInterval> | undefined, lastRoster = 0;
  let iceServers: RTCIceServer[] = [];
  const peers = new Map<string, Peer>();
  let mediaRoot: HTMLDivElement;
  function send(type: string, target?: string, payload?: unknown) {
    if (socket?.readyState !== WebSocket.OPEN) throw new Error("Audio signaling is disconnected");
    socket.send(JSON.stringify({type, csrf, target, payload: payload === undefined ? undefined : JSON.stringify(payload), muted}));
  }
  function removePeer(id: string) {
    const peer = peers.get(id);
    if (peer) {peer.pc.close(); peer.audio.pause(); peer.audio.srcObject = null; peer.audio.remove(); peers.delete(id);}
  }
  function leave() {
    generation++; joining = false; joined = false;
    if (timer) clearInterval(timer); timer = undefined;
    socket?.close(); socket = undefined;
    stream?.getTracks().forEach(track => track.stop()); stream = undefined;
    for (const id of peers.keys()) removePeer(id);
    participants = []; own = ""; muted = false;
  }
  function peerFor(id: string): Peer {
    let peer = peers.get(id);
    if (peer) return peer;
    if (!stream || !participants.some(p => p.id === id)) throw new Error("Unknown audio participant");
    const pc = new RTCPeerConnection({iceServers});
    const audio = document.createElement("audio"); audio.autoplay = true; audio.controls = true;
    audio.setAttribute("aria-label", "Incoming audio " + id); mediaRoot.append(audio);
    peer = {pc, candidates:[], audio}; peers.set(id, peer);
    for (const track of stream.getAudioTracks()) pc.addTrack(track, stream);
    pc.onicecandidate = event => {if (event.candidate && peers.has(id)) {try {send("ice", id, event.candidate.toJSON());} catch {}}};
    pc.ontrack = event => {
      audio.srcObject = event.streams[0] ?? new MediaStream([event.track]);
      audio.play().catch(() => {error = "Browser blocked playback. Use the incoming audio play control.";});
    };
    pc.onconnectionstatechange = () => {
      if (pc.connectionState === "failed") error = "Audio connection failed. Leave and rejoin; this network may require a configured TURN relay.";
    };
    return peer;
  }
  async function receive(event: Event) {
    if (event.type === "participants") {
      lastRoster = Date.now(); own = event.id!; participants = event.participants ?? [];
      const active = new Set(participants.map(p => p.id));
      for (const id of peers.keys()) if (!active.has(id)) removePeer(id);
      if (!active.has(own)) return;
      joined = true; joining = false;
      for (const participant of participants) {
        if (participant.id === own || peers.has(participant.id)) continue;
        const peer = peerFor(participant.id);
        // One deterministic offerer avoids glare when two clients join together.
        if (own < participant.id) {
          await peer.pc.setLocalDescription(await peer.pc.createOffer());
          if (peers.has(participant.id)) send("offer", participant.id, peer.pc.localDescription);
        }
      }
    } else if (event.from && participants.some(p => p.id === event.from)) {
      const peer = peerFor(event.from), payload = JSON.parse(event.payload!);
      if (event.type === "ice") {
        if (peer.pc.remoteDescription) await peer.pc.addIceCandidate(payload);
        else peer.candidates.push(payload);
      } else if (event.type === "offer" || event.type === "answer") {
        await peer.pc.setRemoteDescription(payload);
        for (const candidate of peer.candidates.splice(0)) await peer.pc.addIceCandidate(candidate);
        if (event.type === "offer") {
          await peer.pc.setLocalDescription(await peer.pc.createAnswer());
          if (peers.has(event.from)) send("answer", event.from, peer.pc.localDescription);
        }
      }
    }
  }
  async function join() {
    if (joining || joined) return;
    error = ""; joining = true; const token = ++generation;
    try {
      if (!window.isSecureContext || !navigator.mediaDevices?.getUserMedia) throw new Error("Audio requires HTTPS (or localhost) and microphone permission.");
      const config = await api<{iceServers: RTCIceServer[]}>(`spaces/${space}/channels/${channel}/audio`);
      const session = await api<{csrf: string}>("session");
      if (token !== generation) return;
      iceServers = config.iceServers; csrf = session.csrf;
      const microphone = await navigator.mediaDevices.getUserMedia({audio: true, video: false});
      if (token !== generation) {microphone.getTracks().forEach(track => track.stop()); return;}
      stream = microphone;
      const url = new URL(`/api/v1/spaces/${space}/channels/${channel}/audio/live`,location.href);
      url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
      const ws = new WebSocket(url); socket = ws; lastRoster = Date.now();
      let pending = Promise.resolve();
      ws.onopen = () => {if (token === generation) send("join");};
      ws.onmessage = message => {
        pending = pending.then(async () => {if (token === generation) await receive(JSON.parse(message.data));}).catch(e => {
          if (token === generation) {leave(); error = "Audio negotiation failed: " + String(e);}
        });
      };
      ws.onclose = () => {if (token === generation) {leave(); error = "Audio disconnected. Join again to reconnect.";}};
      timer = setInterval(() => {
        if (Date.now()-lastRoster > 3000) {leave(); error = "Audio signaling lost. Media stopped; join again to reconnect.";}
      },500);
    } catch(e) {if (token === generation) {leave(); error = String(e);}}
  }
  function toggleMute() {
    muted = !muted; stream?.getAudioTracks().forEach(track => track.enabled = !muted);
    try {send("mute");} catch(e) {leave(); error = String(e);}
  }
  onMount(() => () => leave());
</script>
<section aria-label="Channel audio">
  <h3>Audio room</h3>
  <p>Up to six participants. Audio uses browser WebRTC and is not recorded. Some networks require an administrator-configured TURN relay.</p>
  {#if error}<p role="alert">{error}</p>{/if}
  {#if joined || joining}<button onclick={leave}>Leave audio</button>{:else}<button onclick={join}>Join audio</button>{/if}
  {#if joining}<p role="status">Connecting microphone…</p>{/if}
  {#if joined}
    <button onclick={toggleMute}>{muted ? "Unmute microphone" : "Mute microphone"}</button>
    <ul aria-label="Audio participants">{#each participants as person (person.id)}<li>{people.find(p => p.id === person.user)?.name ?? person.user}{person.id === own ? " (you)" : ""} · {person.muted ? "muted" : "microphone on"}</li>{/each}</ul>
  {/if}
  <div bind:this={mediaRoot}></div>
</section>
