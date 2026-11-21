# Audio Comms evaluation and proposed exception

Status: maintainer approved the documented audio deferral on 2026-11-22 (“Approve documented audio deferral”). Audio is not implemented; the Stage 3 audio gate uses this reviewed exception. Video remains future-only.

## Required contract

A room belongs to one existing space/channel. Authenticated human members can join/leave, mute/unmute their microphone, and see current participants. A working implementation must exchange actual audio between browsers, handle disconnect/reconnect and membership/session revocation, and avoid recording audio. Agent Comms bearer tokens must not imply microphone or execution privilege.

Signaling must authenticate the same-origin session, validate CSRF on actions, check current channel access for every join/signal, bound room size and messages, and remove participants on disconnect or revocation. Media must use a maintained WebRTC implementation, with encrypted transport; no custom media protocol. HTTPS, microphone permission, working ICE connectivity, and a tested browser audio path are prerequisites.

## Evaluated options

1. Browser-native WebRTC mesh with Tefter WebSocket signaling. This reuses a maintained browser media stack and avoids a media server on directly reachable LANs. Reliable internet connectivity still requires STUN and a TURN relay where direct ICE paths fail. A LAN-only demonstration would not establish a general self-hosted deployment contract. Room membership revocation also needs existing peers to close media connections, beyond simply rejecting signaling.
2. An optional self-hosted media component such as LiveKit, with Tefter-issued short-lived room tokens. This provides established room/media behavior but requires another executable/service, signing credentials, public addressing, TLS/DNS and media/TURN firewall configuration. A complete implementation must also revoke room access and actively disconnect revoked members, not merely let tokens expire. Operating and testing that service is materially beyond the present single HTTP-server deployment.

Sources reviewed 2026-11-22:

- [WebRTC peer connections](https://webrtc.org/getting-started/peer-connections): application signaling is separate from WebRTC; ICE exchanges candidates using STUN/TURN as applicable.
- [LiveKit deployment](https://docs.livekit.io/transport/self-hosting/deployment/): public addressing, trusted TLS and TURN deployment prerequisites.
- [LiveKit ports/firewall](https://docs.livekit.io/transport/self-hosting/ports-firewall/): separate media and optional TURN ingress requirements.

## Approved reviewed exception

The maintainer approved deferring audio from this Stage 3 acceptance gate. Keep the requirement recorded, expose no join/mute/participant controls that suggest working media, and add no mandatory service. This is an explicit maintainer-approved product exception, not a change to the original audio requirement. Approval was supplied in the task conversation after review of this document.

If the maintainer prefers implementation now, approve an optional maintained external media component and supply a reachable deployment/test endpoint or authorize provisioning and credential configuration separately. Acceptance must include two authenticated browsers exchanging audio, join/leave/mute/participant behavior, disconnect and revoked-member eviction, denied cross-space joins, and a relay-only network test. A fake microphone source is acceptable as deterministic test input only if actual WebRTC media bytes are transmitted and received.
