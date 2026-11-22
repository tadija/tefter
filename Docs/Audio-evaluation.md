# Audio Comms

Channel audio rooms use native browser WebRTC for media and Tefter's authenticated WebSocket connection for signaling. No media service is required for directly reachable peers. Video is not implemented.

## Using a room

Open **Comms**, select a channel and choose **Join audio**. Allow microphone access. Up to six browser participants can join each channel; the participant list shows people and their microphone state. **Mute microphone** disables the outgoing audio track; **Unmute microphone** enables it again. Incoming audio has playback controls if browser autoplay policy requires interaction.

**Leave audio**, changing channels/spaces or navigating away closes peer connections and stops microphone capture. On disconnection or access revocation the client stops media and shows a rejoin action. Rejoining establishes new media connections; there is no hidden background call or automatic microphone restart. Audio is not recorded and participant/signaling state is memory-only. Restarting the server ends rooms.

## Connectivity and deployment

Microphone capture requires HTTPS, except for browser-supported localhost development origins, and user permission. Keep the existing same-origin WebSocket proxy configuration. Media is encrypted browser WebRTC traffic between participants; it does not travel through the HTTP server. Direct connectivity depends on network reachability and firewalls. A browser's native maintained WebRTC stack handles ICE, DTLS and SRTP; Tefter does not implement media transport.

No public STUN/TURN provider is contacted by default. For networks that need discovery/relaying, an operator can configure an existing trusted STUN/TURN service using `$TEFTER_HOME/secrets/audio-ice.json` with mode **0600**:

```json
[
  {"urls":["stun:relay.example.org:3478"]},
  {"urls":["turn:relay.example.org:3478?transport=udp","turns:relay.example.org:5349?transport=tcp"],"username":"PROVISIONED-USERNAME","credential":"PROVISIONED-CREDENTIAL"}
]
```

The service must have the required reachable media/relay ports, trusted TLS where applicable, and independently provisioned credentials. Prefer dedicated restricted/expiring relay credentials and rotate them according to the relay's policy. ICE configuration is read on join and returned only to authenticated human channel members, because browsers need these values to establish media. It is not included in profiles, space exports, audit text or browser bundles. Protect full-instance backups because they include the secrets directory. No external service is provisioned or managed by Tefter.

A failed media connection displays a TURN/connectivity error; leave and rejoin after correcting network configuration. A directly connected local test does not prove remote NAT traversal. Validate a relay-only path and representative remote browsers on the actual deployment before relying on audio across restrictive networks. No live external TURN service or relay-only path was tested in this implementation session.

## Authorization and bounds

- Signaling endpoint: `/api/v1/spaces/SPACE/channels/CHANNEL/audio/live`. Cookie sessions, configured same-origin handshake, current space/channel access and CSRF on each action are required. Agent Comms bearer tokens cannot join audio.
- `GET .../audio` returns current ICE configuration to authorized humans. Cross-space reads and unauthorized configuration access fail.
- Server-generated connection IDs are scoped to the exact room. Offer/answer/ICE forwarding requires joined sender and recipient in that room; knowing a peer ID from another room confers no routing access.
- Participants and queued signals are checked against current authorization. The server polls every 250 ms and clients close removed peers. A three-second roster lease stops all local media if signaling becomes unavailable. Normal browser clients enforce removal; as with any peer-to-peer system, Tefter cannot prevent people from communicating independently outside the application or recall already delivered media.
- At most six connections per room, two per human and 64 across the installation; unjoined reservations expire after ten seconds. Frames are capped at 32 KiB, signal payloads at 24 KiB, queued signals at 64 per recipient and actions at 80 per connection per second. Overflow or invalid actions disconnect the client. SDP/ICE and media are not logged or persisted; audit records contain join attribution only.

<details>
<summary>Validation and decision history</summary>

## Verified behavior

`python3 -m unittest discover -s Tests -p audio.py` tests real HTTP/WebSockets for session/membership/origin/CSRF isolation, denied cross-channel forwarding, human-only access, logout eviction and protected ICE configuration.

`node Web/tests/audio.mjs` launches **two independent Chrome processes** with synthetic microphone input. It requires actual connected peer connections, received audio RTP bytes and nonzero received audio energy in both directions. It tests join/leave, participant lists, microphone track mute/unmute, rejoin, revoked-member eviction, stopped capture tracks and media shutdown when the server is paused. Synthetic input is used for reproducibility; the WebRTC transport is real. The test requests no video tracks. Browser hardware, acoustic quality and external TURN connectivity remain deployment checks.

## Decision history

Audio was initially deferred with explicit maintainer approval after evaluating signaling, TURN and an external component such as LiveKit. The maintainer subsequently requested implementation if feasible within remaining usage. This bounded browser-native implementation supplies working audio without introducing mandatory media infrastructure; the earlier deferral is historical rather than the current implementation status. Historical acceptance reports remain in the implementation logs.

Sources used in the deployment evaluation:

- [WebRTC peer connections](https://webrtc.org/getting-started/peer-connections): signaling and ICE/STUN/TURN requirements.
- [LiveKit deployment](https://docs.livekit.io/transport/self-hosting/deployment/) and [ports/firewall](https://docs.livekit.io/transport/self-hosting/ports-firewall/): the evaluated external-media alternative and its operational prerequisites. LiveKit is not a dependency of this implementation.

</details>

