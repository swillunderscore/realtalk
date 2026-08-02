# Posting to Nexus

Everything the upload form asks for, and where it already exists here.

## 1. The file

```
./package-release.sh 1.0.0      # -> dist/RealTalk-1.0.0.zip
```

Game-root relative (`r6/…`, `tools/RealTalk/…`), so Vortex/MO2 install it
in one step and a manual drag works too. The packager refuses to build if
game-derived audio, machine-local config, or developer paths are present.

Sanity check before upload: extract the zip over a clean-ish install and
launch once. The compile gate (`./compile-check.sh`) already proves the
scripts compile against the deployed set.

## 2. Form fields

| Field | Use |
|---|---|
| Name | Real Talk |
| Summary | `nexus/summary.txt` |
| Description | `nexus/description.bbcode` (paste as BBCode) |
| Category | Gameplay (Cyberpunk 2077) |
| Version | matches the zip you built |
| Requirements | add each dependency from the README as a linked Nexus mod — this drives the auto-shown dependency list |
| Tags | include the **AI-generated content** tag; then Gameplay / Immersion / Voice-Acting as they fit |
| Donation Points | opt in (pays per engagement, no extra work) |
| Permissions | your call; the code is MIT, so permissive is consistent |

## 3. Images

At least one main image is effectively required — it's the thumbnail
everywhere on the site. 1920×1080 PNG/JPG is a safe, standard choice.

Worth having: the chat panel open on a recognisable character mid-reply
(Misty, Mama Welles), one crowd NPC turned toward the camera mid-gesture,
one Mod Settings screenshot showing the options exist.

## 4. Video

Nexus embeds YouTube links on the mod page. A trailer is the single highest
-leverage thing for this mod, because the pitch is impossible to convey in
text: *the voice is that character's own voice, and it was built on the
player's machine from their own game files.*

A shot list that tells the whole story in about 60 seconds:

1. **Cold open, no captions.** Walk up to Mama Welles, press R, type
   something personal ("you doing okay?"). Let her answer out loud in her
   own voice. Don't explain anything yet — the voice does the selling.
2. **Caption: "Every NPC. No character list."** Cut across three wildly
   different people — a crowd pedestrian who stops and turns to you, a
   vendor stepping out of her stall, a gang member — one short exchange each.
3. **Caption: "Their real voice, built on your PC from your own game files."**
   Show the "learning their voice…" line appearing, then the same character
   speaking a beat later.
4. **Caption: "They remember you."** Reload/return later, reopen a chat, show
   the NPC referring to the earlier conversation.
5. **Caption: "And they can act."** One [FOLLOW] moment, or a direction that
   lands a good animation.
6. **End card:** mod name, "100% local or cloud", Nexus link.

Record at the settings you actually play at; the jank is part of the honest
pitch, and an obviously-real capture ages better than a polished lie.

## Positioning (this is also the takedown shield)

Researched precedent: every AI-voice-mod takedown on record was **distributed
cloned audio**, triggered by an **individual actor's** complaint, honored
reactively by Nexus — never a studio, never the union. The single biggest
trigger was **marketing a specific named performer** (a mod *titled* "Adam
Jensen as V" got the actor to demand removal, twice).

So the framing is a legal shield, not just a pitch:

- **Sell the generality — "talk to *any* NPC."** Named characters (Panam,
  Misty) as *examples* in gameplay are fine; making one performer *the product*
  ("AI Panam", "clone Johnny Silverhand") is the line that got mods pulled.
- **Ship no audio and no trained voice models** — only the pipeline. (Already
  true here; don't add a "Panam voice model" download later.)
- **Keep the AI-generated-content tag on** (§2) — Nexus mandates it; mislabeling
  invites moderation on its own.
- **If a rights holder objects, comply immediately.** Because voice is a toggle
  and no audio ships, the fix is *disable the feature and push an update* — same
  page, same URL. Precedent (Skyrim "Valerica") confirms you keep the mod live
  and only remove the voiced part. You are not forced to pull everything.

CDPR itself is the friendly party here — permissive of non-commercial fan mods,
never pulled an AI voice mod, red line is monetization. Don't sell it and their
involvement is unlikely.

## 5. After posting

The first field reports will name characters and situations. The two logs
that make them diagnosable are already in place: the in-game **Debug Log**
toggle (off by default, users can flip it) and the voice server's own log,
which prints unmatched stage directions (`anim no-match`) — the ready-made
list of the next animation-thesaurus entries.
