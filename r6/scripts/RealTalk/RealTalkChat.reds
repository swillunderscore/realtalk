// ============================================================================
//  STREET TALK - conversation
// ============================================================================
//
//  Talks to any OpenAI-compatible endpoint (llama.cpp, Ollama, LM Studio,
//  KoboldCpp). The endpoint comes from Mod Settings presets so most users
//  never edit a file.
//
//  HARD REQUIREMENT: the game must be launched with -no-tls.
//    RedHttpClient refuses http:// urls outright - it returns null WITHOUT
//    opening a socket, which surfaces as status code 0 and looks exactly like
//    a dead mod. -no-tls permits unencrypted requests to localhost and local
//    network ranges, and it only exists in RedHttpClient 0.7.1+ (0.7.0 has no
//    such flag at all, so the Nexus build may be too old - use GitHub).
//    This cost hours to diagnose once; the README leads with it.
//
//  REASONING MODELS: if the server runs a thinking model, replies come back
//  with an empty `content` and the text in `reasoning_content`. The mod reads
//  `content`, so every message renders blank. Start llama.cpp with
//  --reasoning off, or use a non-reasoning model.
// ============================================================================

module RealTalk

import RedHttpClient.*
import RedData.Json.*
import RedFileSystem.*

// Request shape. Serialised with ToJson(), matching the proven pattern - see
// RealTalkMemory for why we don't build JsonObjects directly.
public class StChatMessageDTO extends IScriptable {
    public let role: String;
    public let content: String;
}

public class StChatRequestDTO extends IScriptable {
    public let model: String;
    public let messages: array<ref<StChatMessageDTO>>;
    public let max_tokens: Int32;
    public let temperature: Float;
    public let stream: Bool;
}

// The second-pass classifier request. Separate DTO so the "grammar" field is
// ONLY sent on classify calls, never on the generation call (which must not be
// constrained). grammar is honoured by llama.cpp and KoboldCpp and ignored by
// other OpenAI-compatible servers; the answer is validated either way.
public class StClassifyRequestDTO extends IScriptable {
    public let model: String;
    public let messages: array<ref<StChatMessageDTO>>;
    public let max_tokens: Int32;
    public let temperature: Float;
    public let stream: Bool;
    public let grammar: String;
}

// On-disk shape for a saved conversation. Field name becomes the JSON key.
public class StChatFileDTO extends IScriptable {
    public let lines: array<ref<StChatMessageDTO>>;
}

// Plays a queued audio chunk at its scheduled moment.
public class StVoicePlayTick extends DelayCallback {
    public let chat: wref<StChat>;
    public let slot: Int32;
    public let gen: Int32;
    public let text: String;
    public let more: Bool;
    public func Call() -> Void {
        if IsDefined(this.chat) {
            this.chat.PlayNow(this.slot, this.gen, this.text, this.more);
        }
    }
}

// Safety net for voice-paced text: whatever happens to the audio chain,
// the full reply text lands on screen.
public class StRevealFlushTick extends DelayCallback {
    public let chat: wref<StChat>;
    public let gen: Int32;
    public func Call() -> Void {
        if IsDefined(this.chat) {
            // ONLY IF IT IS STILL THIS REPLY'S JOB. Without the generation
            // check, a flush left over from an earlier reply fired 25 seconds
            // later and stamped that old text over whatever was newest on
            // screen - which reads as the NPC repeating herself word for word
            // (field report, with a screenshot of the same line twice).
            this.chat.FlushRevealIf(this.gen);
        }
    }
}

// Fires shortly after warm-up starts; if it is still running, the chat gets
// a visible "learning their voice" line instead of just a footer hint.
public class StPrepSlowTick extends DelayCallback {
    public let chat: wref<StChat>;
    public func Call() -> Void {
        if IsDefined(this.chat) {
            this.chat.PrepStillRunning();
        }
    }
}

// Voice warm-up request: resolve (and forge, if needed) the voice at chat
// OPEN, so the first reply never pays for it.
public class StTtsPrepDTO extends IScriptable {
    public let prep: Int32;
    public let voice: String;
    public let voicetag: String;
    public let crowd: Bool;
    public let tts: Int32;
    public let gender: String;
    public let faction: String;
    public let vkey: String;
    public let log: Bool;
    public let wiki: Bool;
    public let cond: Int32;
    // Game-side introspection snapshot, printed by the server's always-on
    // log. Exists because the in-game debug log is opt-in and diagnosis of
    // wrong-voice reports must not depend on a toggle nobody flips.
    public let diag: String;
}

// One chunk of speech, waiting its turn.
public class StQueuedAudio extends IScriptable {
    public let slot: Int32;
    public let durMs: Int64;
    public let text: String;
    public let more: Bool;
}

// A reserved place in the queue: everything one speaker is about to say for
// one turn. Reserved when the message is sent, filled as the audio arrives,
// and closed when the last chunk lands.
public class StVoiceChain extends IScriptable {
    public let isV: Bool;
    public let gen: Int32;
    public let done: Bool;
    public let next: Int32;
    public let chunks: array<ref<StQueuedAudio>>;
}

public class StVoiceQueueTick extends DelayCallback {
    public let chat: wref<StChat>;
    public let gen: Int32;
    public func Call() -> Void {
        if IsDefined(this.chat) {
            this.chat.QueueTick(this.gen);
        }
    }
}

// A reservation whose audio never arrived must not stall the queue forever.
public class StChainTimeout extends DelayCallback {
    public let chat: wref<StChat>;
    public let chain: ref<StVoiceChain>;
    public func Call() -> Void {
        if IsDefined(this.chat) && IsDefined(this.chain) && !this.chain.done {
            StLog("voice: a reservation timed out - letting the queue move on");
            this.chat.CloseChain(this.chain);
        }
    }
}

// Marks the end of a spoken chunk so the next poll may offer a slot.
public class StVoiceIdleTick extends DelayCallback {
    public let chat: wref<StChat>;
    public func Call() -> Void {
        if IsDefined(this.chat) {
            this.chat.VoiceIdle();
        }
    }
}

// Continuation request: fetch the next sentence-chunk of a spoken reply.
public class StTtsNextDTO extends IScriptable {
    public let next: String;   // session id from the previous response
    public let slot: Int32;
}

// V's own line, spoken in V's voice. A separate chain from the NPC's so the
// two never fight over one set of continuation state - V is talking while the
// language model is still thinking, which is the whole point.
public class StVTtsNextTick extends DelayCallback {
    public let chat: wref<StChat>;
    public let id: String;
    public func Call() -> Void {
        if IsDefined(this.chat) {
            this.chat.RequestNextVChunk(this.id);
        }
    }
}

public class StVPlayTick extends DelayCallback {
    public let chat: wref<StChat>;
    public let slot: Int32;
    public let gen: Int32;
    public func Call() -> Void {
        if IsDefined(this.chat) {
            this.chat.PlayVNow(this.slot, this.gen);
        }
    }
}

// Fires when the current chunk has finished playing; asks for the next one.
public class StTtsNextTick extends DelayCallback {
    public let chat: wref<StChat>;
    public let id: String;
    public func Call() -> Void {
        if IsDefined(this.chat) {
            this.chat.RequestNextChunk(this.id);
        }
    }
}

// "Rebuild All Voices".
public class StTtsResetDTO extends IScriptable {
    public let reset_voices: Int32;
}

// Request shape for the TTS server.
public class StTtsRequestDTO extends IScriptable {
    public let text: String;
    public let voice: String;
    public let voicetag: String;   // Character_Record.VoiceTag() - the NPC's
                                   // actual voice bank, e.g. a civ_/gang_ tag
    public let crowd: Bool;        // true = skip the named-character forge
    public let gender: String;     // fallback voices should match at least this
    public let faction: String;    // steers archetype-bank voice assignment
    public let vkey: String;       // per-NPC variety key (appearance name) so
                                   // same-named crowd NPCs don't share a voice
    public let direction: String;  // the reply's stage direction - the server
                                   // matches it against AMM's anim database
    public let held: Bool;         // hands are full: the anim search must not
                                   // pick clapping or prop-holding loops
    public let log: Bool;          // mirror of the in-game Debug Log switch:
                                   // ONE toggle controls both logs
    public let gain: Float;        // output level; V is mixed down because a
                                   // 2D line gets no distance attenuation
    public let wiki: Bool;         // may the server look this character up
                                   // online? Off unless the player says yes
    public let cond: Int32;        // Voice Detail: seconds of real voice the
                                   // model listens to before speaking
    public let slot: Int32;
}

public class StChat extends ScriptableSystem {

    private let busy: Bool;
    private let history: array<ref<StChatMessageDTO>>;
    private let activeId: Uint64;
    private let activeIsCrowd: Bool;
    private let activeNpc: wref<NPCPuppet>;
    private let activeName: String;
    private let actions: ref<StActions>;

    // TTS slot rotation. Four on-demand Audioware slots; replies are strictly
    // sequential (busy flag), so pending never gets trampled in practice.
    private let ttsSlot: Int32;
    private let ttsPendingSlot: Int32;

    // Summarization runs on its own flag so it never blocks a normal send,
    // and captures its target id at request time - the player may already be
    // talking to someone else when the reply lands.
    private let summarizing: Bool;
    private let gistTargetId: Uint64;
    private let gistTargetLines: Int32;

    private func Msg(role: String, content: String) -> ref<StChatMessageDTO> {
        let m = new StChatMessageDTO();
        m.role = role;
        m.content = content;
        return m;
    }

    // Starting a conversation with a different person clears the thread, but
    // returning to the SAME person mid-session resumes it - so stepping out to
    // pick a real dialogue option and coming back doesn't wipe the exchange.
    private let activeVoiceTag: String;

    private let activeGender: String;
    private let activeFaction: String;
    private let activeDiag: String;
    private let activeVkey: String;
    private let talkStopOnIdle: Bool;
    // Per-reply stage direction (the narration the model wrote around its
    // quotes) and the animation the server matched against it.
    private let activeDirection: String;
    private let pendingAnim: CName;
    private let pendingAsk: String;

    // Held between firing the classifier and its reply landing.
    private let pendingClassNpc: wref<NPCPuppet>;
    private let pendingClassBeat: String;
    private let pendingClassSpeech: String;
    private let pendingClassAsked: String;

    // Kept so the character card can be REBUILT the moment a biography
    // arrives - the card is the only thing the model ever sees, so a bio that
    // shows up after the first reply may as well not exist.
    private let activeIdentity: ref<StIdentity>;
    private let activeMemory: ref<StMemoryEntry>;
    private let activeFamiliarity: String;

    // ------------------------------------------------------------------
    //  V SPEAKS TOO. The player's own typed line is synthesised in V's voice
    //  - forged from the 21,000-odd V lines in the player's archives, filtered
    //  to their V's gender - and played from the player, before the NPC
    //  answers. Two wins for one feature: the conversation sounds like a
    //  conversation, and the seconds V spends talking are seconds the NPC's
    //  reply is already synthesising, so the answer lands sooner.
    //
    //  Its own chain state, deliberately: V's chunks and the NPC's chunks are
    //  in flight at the same time, and sharing continuation state would make
    //  each cancel the other. Order between them is the queue's job, not
    //  theirs - see StVoiceChain.
    // ------------------------------------------------------------------
    private let vChainId: String;
    private let vGen: Int32;
    private let vLastSlot: Int32;

    // ONE QUEUE, AND ORDER IS DECIDED WHEN A LINE IS SENT - NOT WHEN ITS
    // AUDIO HAPPENS TO ARRIVE.
    //
    // The old design gave both voices a shared clock and let whichever chunk
    // arrived first take the next place in line. Then it grew a hold to stop
    // the NPC jumping V, and the hold did not cover V's own later chunks, so
    // a long line still came out V, Panam, V (field report, twice). A race
    // patched with a conditional is still a race.
    //
    // So: sending a message RESERVES two places, V's then theirs, in that
    // order, before either has any audio. Chunks fill their own reservation
    // whenever they turn up, and playback walks the queue strictly from the
    // front. Nothing can overtake anything, because arrival time no longer
    // decides anything.
    private let chains: array<ref<StVoiceChain>>;
    private let playing: Bool;
    private let vChain: ref<StVoiceChain>;
    private let npcChain: ref<StVoiceChain>;

    public func ReserveChain(isV: Bool) -> ref<StVoiceChain> {
        let c = new StVoiceChain();
        c.isV = isV;
        c.gen = this.voiceGen;
        ArrayPush(this.chains, c);
        // A reservation nobody ever fills would stall everything behind it.
        let guard = new StChainTimeout();
        guard.chat = this;
        guard.chain = c;
        GameInstance.GetDelaySystem(GetGameInstance()).DelayCallback(guard, 30.0, false);
        return c;
    }

    public func CloseChain(c: ref<StVoiceChain>) -> Void {
        if IsDefined(c) {
            c.done = true;
        }
        this.Pump();
    }

    private func Enqueue(c: ref<StVoiceChain>, slot: Int32, durMs: Int64,
                         text: String, more: Bool) -> Void {
        if !IsDefined(c) || c.gen != this.voiceGen {
            return;   // silenced or superseded
        }
        let a = new StQueuedAudio();
        a.slot = slot;
        a.durMs = durMs;
        a.text = text;
        a.more = more;
        ArrayPush(c.chunks, a);
        this.Pump();
    }

    // Walk the queue from the front. Plays at most one thing at a time, and
    // never looks past a reservation that is still expecting audio.
    public func Pump() -> Void {
        if this.playing {
            return;
        }
        let guard: Int32 = 0;
        while guard < 32 && ArraySize(this.chains) > 0 {
            guard += 1;
            let c = this.chains[0];
            if c.gen != this.voiceGen {
                ArrayErase(this.chains, 0);
            } else {
                if c.next < ArraySize(c.chunks) {
                    let a = c.chunks[c.next];
                    c.next += 1;
                    this.playing = true;
                    if c.isV {
                        this.PlayVNow(a.slot, c.gen);
                    } else {
                        this.PlayNow(a.slot, c.gen, a.text, a.more);
                    }
                    // 0.35s is a spoken period: the silence trim takes the
                    // natural pause off every chunk, so without it sentences
                    // run together.
                    let tick = new StVoiceQueueTick();
                    tick.chat = this;
                    tick.gen = c.gen;
                    GameInstance.GetDelaySystem(GetGameInstance()).DelayCallback(
                        tick, Cast<Float>(a.durMs) / 1000.0 + 0.35, false);
                    return;
                }
                if !c.done {
                    return;   // its audio is still coming - hold the line
                }
                ArrayErase(this.chains, 0);
            }
        }
    }

    public func QueueTick(gen: Int32) -> Void {
        if gen != this.voiceGen {
            return;
        }
        this.playing = false;
        // The chunk that just finished may have been their last word, which
        // is what ends the talking gesture and lets them stand normally.
        this.VoiceIdle();
        this.Pump();
    }

    private func ClearQueue() -> Void {
        ArrayClear(this.chains);
        this.playing = false;
        this.vChain = null;
        this.npcChain = null;
    }

    // ------------------------------------------------------------------
    //  Dialogue duck. NPCs like Garry the Prophet monologue on a loop, and
    //  their game VO talks straight over the TTS reply. There is no API to
    //  pause an NPC's own voice (VO is fire-and-forget, scene dialogue is
    //  the quest system's), but game speech routes through the DialogueVolume
    //  user setting - which Audioware's playback does NOT - so lowering it
    //  while a reply plays quiets THEM without touching OUR voice.
    //  Read/write pattern copied from pocketRadio.swift:93.
    //  The saved value is also written to storage first: if the game dies
    //  mid-duck, next session restores the slider before anything plays.
    // ------------------------------------------------------------------
    private let duckedDialogue: Bool;
    private let duckSaved: Int32;

    private func DuckDialogue() -> Void {
        if this.duckedDialogue {
            return;
        }
        let settings = GameInstance.GetSettingsSystem(GetGameInstance());
        if !IsDefined(settings) || !settings.HasGroup(n"/audio/volume") {
            return;
        }
        let grp = settings.GetGroup(n"/audio/volume");
        if !grp.HasVar(n"DialogueVolume") {
            return;
        }
        let v = grp.GetVar(n"DialogueVolume") as ConfigVarInt;
        if !IsDefined(v) {
            return;
        }
        this.duckSaved = v.GetValue();
        if this.duckSaved <= 20 {
            return;   // already quiet - nothing worth doing, nothing to break
        }
        let fs = RealTalkFS.Get();
        if IsDefined(fs) && IsDefined(fs.Storage()) {
            let mf = fs.Storage().GetFile("duck_marker.txt");
            if IsDefined(mf) {
                mf.WriteText(s"\(this.duckSaved)");
            }
        }
        this.duckedDialogue = true;
        // Down to a tenth, not off: a quest scene starting mid-chat should be
        // quiet, never silent.
        v.SetValue(this.duckSaved / 10);
        // A staged config change does nothing until it is confirmed - which is
        // exactly what the settings menu's Apply button does
        // (settingsMain.swift:795). Nothing in vanilla ever WRITES this value,
        // so there was no example to copy from and the write may have been
        // sitting unapplied.
        if settings.NeedsConfirmation() {
            settings.ConfirmChanges();
        }
        StLog(s"dialogue ducked: \(this.duckSaved) -> \(v.GetValue())");
    }

    private func RestoreDialogue() -> Void {
        if !this.duckedDialogue {
            return;
        }
        this.duckedDialogue = false;
        let settings = GameInstance.GetSettingsSystem(GetGameInstance());
        if IsDefined(settings) && settings.HasGroup(n"/audio/volume") {
            let grp = settings.GetGroup(n"/audio/volume");
            if grp.HasVar(n"DialogueVolume") {
                let v = grp.GetVar(n"DialogueVolume") as ConfigVarInt;
                if IsDefined(v) {
                    v.SetValue(this.duckSaved);
                    if settings.NeedsConfirmation() {
                        settings.ConfirmChanges();
                    }
                }
            }
        }
        let fs = RealTalkFS.Get();
        if IsDefined(fs) && IsDefined(fs.Storage()) {
            let mfc = fs.Storage().GetFile("duck_marker.txt");
            if IsDefined(mfc) {
                mfc.WriteText("");
            }
        }
    }

    public func Begin(identity: ref<StIdentity>, persona: String, npc: ref<NPCPuppet>, displayName: String, voiceTag: String, gender: String, opt memory: ref<StMemoryEntry>, opt familiarity: String) -> Void {
        if !IsDefined(identity) || !identity.valid {
            return;
        }
        this.activeIdentity = identity;
        this.activeMemory = memory;
        this.activeFamiliarity = familiarity;
        this.activeNpc = npc;
        this.activeName = displayName;
        this.activeVoiceTag = voiceTag;
        this.activeGender = gender;
        this.activeFaction = IsDefined(npc) ? npc.GetAffiliation() : "";
        this.activeDiag = IsDefined(npc) ? StGender.Diag(npc) : "";
        this.activeVkey = IsDefined(npc) ? NameToString(npc.GetCurrentAppearanceName()) : "";
        if !IsDefined(this.actions) {
            this.actions = new StActions();
        }
        // Emitter registered at chat OPEN, not at play time: registration is
        // not instantaneous, and a same-frame register+play can come out flat
        // 2D instead of positioned on the NPC.
        StVoice.Prepare(GetGameInstance(), npc);

        // DUCK FOR THE WHOLE CONVERSATION. This started as "quiet the NPC
        // while their reply plays", which left every gap uncovered - and the
        // game fires barks in those gaps: a vendor greeting a customer, a
        // reaction to being looked at, whatever the AI does when we step them
        // out of their routine. In chat mode the only voice should be the one
        // we synthesised, so the game's dialogue channel stays down from open
        // to close.
        this.DuckDialogue();

        // Background lookup, now, before the first word is typed. Nothing
        // waits on it: the chat is usable immediately and the card is rebuilt
        // in place if a biography turns up.
        this.PrepBio(displayName);

        // One setup for everyone: a walking pedestrian stops instead of
        // strolling out of your life mid-sentence, a vendor steps out of her
        // stall routine (only when gestures can play), and whoever we take
        // control of turns to face you - once, here, not per line.
        if IsDefined(this.actions) {
            let anims = RealTalkSettings.Get();
            this.actions.PrepareForChat(npc, identity.isCrowd,
                IsDefined(anims) && anims.talkAnims);
        }

        if NotEquals(this.activeId, identity.persistentId) || ArraySize(this.history) == 0 {
            StLog(s"chat: NEW thread (prev \(this.activeId) -> \(identity.persistentId))");
            ArrayClear(this.history);
            this.activeId = identity.persistentId;
            this.activeIsCrowd = identity.isCrowd;
            ArrayPush(this.history, this.Msg("system", persona));
            // Pick the thread back up where it left off last session.
            if !identity.isCrowd {
                this.LoadPast();
            }
            // Nothing saved? Then whatever the game just had them say IS the
            // start of this conversation - the bark you triggered with F, or
            // the dialogue scene you just played, both sides of it.
            // ONLY into a genuinely empty conversation: nothing saved from a
            // past session, nothing said yet this one. A resumed thread keeps
            // its own history and never gets the game's dialogue stapled on.
            let ui2 = RealTalkUI.Get();
            let visibleEmpty: Bool = !IsDefined(ui2) || ui2.LineCount() == 0;
            if ArraySize(this.history) == 1 && visibleEmpty {
                this.SeedFromOverheard(npc);
            } else {
                StLog(s"chat: not seeding - \(ArraySize(this.history) - 1) message(s) already in this thread");
            }
        } else {
            // Keep the identity fields honest on a resume too - these used to
            // be set only when a NEW thread started, so a stale crowd flag
            // could silently disable saving for a community NPC.
            this.activeId = identity.persistentId;
            this.activeIsCrowd = identity.isCrowd;
            StLog(s"chat: resuming, \(ArraySize(this.history) - 1) lines in memory");
        }
        // Whether the thread is new or resumed, anything the two of you have
        // said IN THE GAME since the last chat message belongs in it - a quest
        // scene played between two conversations otherwise vanishes.
        this.AppendFreshDialogue(npc);
    }

    // The game's own dialogue, continued. Lines the player just heard from
    // this NPC (and V's lines in the same beat) become the opening of the
    // thread, on both sides - so pressing F on a pedestrian, getting snapped
    // at, and then opening the chat lands you mid-argument instead of at
    // "hello". Display and history both, so the model sees exactly what the
    // player sees.
    private func SeedFromOverheard(npc: ref<NPCPuppet>) -> Void {
        let heard = GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"RealTalk.RealTalkHintSystem") as RealTalkHintSystem;
        if !IsDefined(heard) {
            StLog("chat: overheard capture unavailable");
            return;
        }
        let recent = heard.RecentWith(npc, this.activeName);
        if ArraySize(recent) == 0 {
            return;
        }
        let ui = RealTalkUI.Get();
        // THE NEWEST six, not the first six. A long quest scene produced 13
        // lines and this seeded the oldest of them, so the chat opened on
        // something said ten minutes ago instead of the sentence that had just
        // finished (field report).
        let total: Int32 = ArraySize(recent);
        let i: Int32 = total > 6 ? total - 6 : 0;
        while i < total {
            let l = recent[i];
            let clean: String = StActions.CleanTemplate(l.text);
            if StrLen(clean) > 0 {
                ArrayPush(this.history, this.Msg(l.isPlayer ? "user" : "assistant", clean));
                if IsDefined(ui) && ui.IsOpen() {
                    ui.AddLine(l.isPlayer ? "V" : "THEM", clean, l.isPlayer);
                }
            }
            i += 1;
        }
        StLog(s"chat: seeded from the newest \(total > 6 ? 6 : total) of \(total) overheard line(s)");
    }

    // Lines from the game that are not in the thread yet. Deduplicated against
    // what is already there, so reopening a chat twice cannot double them up.
    private func AppendFreshDialogue(npc: ref<NPCPuppet>) -> Void {
        let heard = GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"RealTalk.RealTalkHintSystem") as RealTalkHintSystem;
        if !IsDefined(heard) {
            return;
        }
        let recent = heard.RecentWith(npc, this.activeName);
        let ui = RealTalkUI.Get();
        let added: Int32 = 0;
        let i: Int32 = ArraySize(recent) > 6 ? ArraySize(recent) - 6 : 0;
        while i < ArraySize(recent) {
            let l = recent[i];
            let clean: String = StActions.CleanTemplate(l.text);
            if StrLen(clean) > 0 && !this.HistoryHas(clean) {
                ArrayPush(this.history, this.Msg(l.isPlayer ? "user" : "assistant", clean));
                if IsDefined(ui) && ui.IsOpen() {
                    ui.AddLine(l.isPlayer ? "V" : "THEM", clean, l.isPlayer);
                }
                added += 1;
            }
            i += 1;
        }
        if added > 0 {
            StLog(s"chat: added \(added) line(s) said since the last message");
        }
    }

    // An action that actually happened, kept in the transcript in order.
    // Role "action" is inert: it is saved and replayed, and every path that
    // feeds history to the model skips it, so a record of what was done never
    // becomes an instruction to do more of it.
    public func NoteAction(text: String) -> Void {
        if ArraySize(this.history) == 0 || StActions.IsBlank(text) {
            return;
        }
        ArrayPush(this.history, this.Msg("action", text));
        this.SaveActive();
    }

    private func HistoryHas(text: String) -> Bool {
        let i: Int32 = ArraySize(this.history) - 1;
        let seen: Int32 = 0;
        while i >= 1 && seen < 20 {
            if Equals(this.history[i].content, text) {
                return true;
            }
            seen += 1;
            i -= 1;
        }
        return false;
    }

    // ------------------------------------------------------------------
    //  CHARACTER BACKGROUND, fetched once at chat open.
    //
    //  Nothing waits on it: the chat is usable immediately, the game's own
    //  dialogue is seeded as normal, and the panel just says what it is doing.
    //  When the biography lands the CARD IS REBUILT in place, so the very
    //  first reply already knows who they are. If the lookup is off, fails, or
    //  the server is not running, this costs one dead request and nothing else.
    // ------------------------------------------------------------------
    // ---- character background from the wiki (see RealTalkWiki.reds) ----
    // The requests live here because THIS system provably runs. Every branch
    // logs, so "it should have found a page" is answerable from the log rather
    // than by guessing.
    private let wikiName: String;
    private let wikiTriedSearch: Bool;

    private func WikiNote(active: Bool) -> Void {
        let ui = RealTalkUI.Get();
        if IsDefined(ui) {
            ui.SetLookup(active);
        }
    }

    private func PrepBio(displayName: String) -> Void {
        let settings = RealTalkSettings.Get();
        this.WikiNote(false);
        if !IsDefined(settings) || !settings.wikiLookup {
            StLog("wiki: lookup is off in Mod Settings");
            return;
        }
        if StrLen(displayName) < 4 || StWiki.IsGenericName(displayName) {
            StLog(s"wiki: '\(displayName)' is a role, not a person - skipped");
            return;
        }
        if StrLen(StPersona.BioLines(displayName)) > 0 {
            StLog(s"wiki: already have a background for \(displayName)");
            return;
        }
        this.wikiName = displayName;
        this.wikiTriedSearch = false;
        this.WikiNote(true);
        StLog(s"wiki: looking up \(displayName)");
        let bail = new StWikiTimeout();
        bail.chat = this;
        bail.forName = displayName;
        GameInstance.GetDelaySystem(GetGameInstance()).DelayCallback(bail, 12.0, false);
        AsyncHttpClient.Get(HttpCallback.Create(this, n"OnWikiPage"),
                            StWiki.PageUrl(displayName));
    }

    public func WikiTimedOut(forName: String) -> Void {
        if Equals(this.wikiName, forName) {
            StLog(s"wiki: no answer for \(forName) - giving up");
            this.WikiNote(false);
        }
    }

    private cb func OnWikiPage(response: ref<HttpResponse>) -> Void {
        let wikitext: String = "";
        if IsDefined(response) && Equals(response.GetStatus(), HttpStatus.OK) {
            let json = response.GetJson();
            if IsDefined(json) && !json.IsUndefined() {
                let root = json as JsonObject;
                if IsDefined(root) {
                    let parse = root.GetKey("parse") as JsonObject;
                    if IsDefined(parse) {
                        let wt = parse.GetKey("wikitext") as JsonObject;
                        if IsDefined(wt) {
                            wikitext = wt.GetKeyString("*");
                        }
                    }
                }
            }
        } else {
            StLog("wiki: request failed (no internet, or blocked)");
        }
        if StrLen(wikitext) < 80 || !StrContains(wikitext, "Infobox Character") {
            if !this.wikiTriedSearch && StrLen(this.wikiName) > 0 {
                this.wikiTriedSearch = true;
                StLog(s"wiki: no character page at that title - searching for \(this.wikiName)");
                AsyncHttpClient.Get(HttpCallback.Create(this, n"OnWikiSearch"),
                                    StWiki.SearchUrl(this.wikiName));
                return;
            }
            StLog(s"wiki: nothing usable for \(this.wikiName)");
            this.WikiNote(false);
            return;
        }
        this.SaveBio(StWiki.Parse(wikitext));
    }

    private cb func OnWikiSearch(response: ref<HttpResponse>) -> Void {
        this.WikiNote(false);
        if !IsDefined(response) || NotEquals(response.GetStatus(), HttpStatus.OK) {
            return;
        }
        let json = response.GetJson();
        if !IsDefined(json) || json.IsUndefined() {
            return;
        }
        let root = json as JsonObject;
        if !IsDefined(root) {
            return;
        }
        let query = root.GetKey("query") as JsonObject;
        if !IsDefined(query) {
            return;
        }
        let hits = query.GetKey("search") as JsonArray;
        if !IsDefined(hits) || hits.GetSize() == 0u {
            StLog(s"wiki: search found nothing for \(this.wikiName)");
            return;
        }
        let first = hits.GetItem(0u) as JsonObject;
        if !IsDefined(first) {
            return;
        }
        let title: String = first.GetKeyString("title");
        if StrLen(title) == 0 {
            return;
        }
        StLog(s"wiki: '\(this.wikiName)' -> '\(title)'");
        this.WikiNote(true);
        AsyncHttpClient.Get(HttpCallback.Create(this, n"OnWikiPage"),
                            StWiki.PageUrl(title));
    }

    private func SaveBio(lines: array<String>) -> Void {
        this.WikiNote(false);
        if ArraySize(lines) == 0 || StrLen(this.wikiName) == 0 {
            return;
        }
        let fs = RealTalkFS.Get();
        if !IsDefined(fs) || !IsDefined(fs.Storage()) {
            return;
        }
        let dto = new StBioFileDTO();
        dto.lines = lines;
        let file = fs.Storage().GetFile(s"bio_\(StPersona.Slug(this.wikiName)).json");
        if IsDefined(file) {
            file.WriteText(ToJson(dto).ToString());
            StLog(s"wiki: background saved for \(this.wikiName)");
            this.RebuildCard();
        }
    }

    // Called when a biography arrives. Position 0 is always the system
    // message, so the model sees the new card on its next request whether the
    // player has typed yet or not - and the conversation is never disturbed.
    public func RebuildCard() -> Void {
        if !IsDefined(this.activeNpc) || !IsDefined(this.activeIdentity)
            || ArraySize(this.history) == 0 {
            return;
        }
        let fresh: String = StPersona.Build(this.activeNpc, this.activeIdentity,
            this.activeMemory, this.activeFamiliarity, this.activeName,
            GetGameInstance());
        this.history[0] = this.Msg("system", fresh);
        let ui = RealTalkUI.Get();
        if IsDefined(ui) {
            ui.SetLookup(false);
        }
        StLog("chat: character card rebuilt with their background");
    }

    // ---- menu mute ----
    // The game pauses in menus; Audioware does not. The hint poller watches
    // UI_System.IsInMenu and silences the active line.
    private let voicePlaying: Bool;

    // ---- gapless playback queue ----
    // Chunks are fetched EAGERLY (the server blocks until each is ready) and
    // queued by sim-time so each starts the instant the previous ends. The
    // old scheme waited for a chunk to finish playing before even asking for
    // the next - that wait, plus a round trip, was the mid-reply pause.
    private let voiceGen: Int32;
    private let lastSlot: Int32;

    private func NowS() -> Float {
        return EngineTime.ToFloat(GameInstance.GetSimTime(GetGameInstance()));
    }

    private func PlayChunk(slot: Int32, durMs: Int64, text: String, more: Bool) -> Void {
        this.Enqueue(this.npcChain, slot, durMs, text, more);
        if !more {
            this.CloseChain(this.npcChain);
        }
    }

    public func PlayNow(slot: Int32, gen: Int32, text: String, more: Bool) -> Void {
        if gen != this.voiceGen {
            return;   // silenced or superseded while queued
        }
        // Never START audio while a menu is up. The poller's mute only stops
        // what is already playing - a chunk ARRIVING mid-menu walked right
        // past it (field report: ESC before playback began, voice played
        // over the menu anyway).
        if GameInstance.GetBlackboardSystem(GetGameInstance()).Get(GetAllBlackboardDefs().UI_System)
            .GetBool(GetAllBlackboardDefs().UI_System.IsInMenu) {
            this.FlushReveal();
            return;
        }
        // the sentence appears the moment its audio starts
        if StrLen(text) > 0 && StrLen(this.revealPending) > 0 {
            this.revealAccum += StrLen(this.revealAccum) > 0 ? " " + text : text;
            let rui = RealTalkUI.Get();
            if IsDefined(rui) && rui.IsOpen() {
                // trailing ... while more sentences are still coming, so it
                // is obvious when they have actually finished talking
                rui.UpdateLastLine("THEM", more ? this.revealAccum + " ..." : this.revealAccum);
            }
        }
        StVoice.Speak(GetGameInstance(), this.activeNpc, slot);
        // Gesture while the words come out (optional, see RealTalkActions).
        // The final chunk arms the idle tick to end the gesture with the
        // audio; a mid-reply idle (gap between sentences) leaves it running.
        let anims = RealTalkSettings.Get();
        if IsDefined(anims) && anims.talkAnims && IsDefined(this.actions) {
            this.actions.StartTalking(this.activeNpc, this.activeGender, this.activeVkey, text, this.pendingAnim);
            // The classifier drives the face when Smart Actions is on (the
            // game's real 9 emotions). Only fall back to the keyword heuristic
            // when it is off - otherwise the two overwrite each other.
            if !anims.smartActions {
                this.actions.FaceTalk(this.activeNpc, this.activeDirection);
            }
        }
        this.DuckDialogue();
        this.talkStopOnIdle = !more;
        this.lastSlot = slot;
        this.voicePlaying = true;
    }

    // Warm the voice the moment the chat opens: forge if needed, compute the
    // conditioning - so the FIRST reply speaks as fast as any other. The UI
    // shows a warming indicator until the server confirms.
    private let prepPending: Bool;
    private let prepLineShown: Bool;

    public func PrepVoice() -> Void {
        let settings = RealTalkSettings.Get();
        let cfg = RealTalkConfig.Get();
        if !IsDefined(settings) || !settings.ttsEnabled || !IsDefined(cfg) {
            return;
        }
        let ui = RealTalkUI.Get();
        if IsDefined(ui) {
            ui.SetVoicePrep(true);
        }
        // If the warm-up is still running after a moment, say so IN the chat
        // - a footer suffix alone is easy to miss during a 15s first-meeting
        // forge. Cached voices come back fast and never show the line.
        this.prepPending = true;
        this.prepLineShown = false;
        let slow = new StPrepSlowTick();
        slow.chat = this;
        // 4s, not 1.5: a cached voice answers well inside that, so reopening a
        // chat no longer claims to be learning a voice it already has. A real
        // forge takes 10-30s and still gets its line.
        GameInstance.GetDelaySystem(GetGameInstance()).DelayCallback(slow, 4.0, false);
        let req = new StTtsPrepDTO();
        req.prep = 1;
        req.voice = this.activeName;
        req.voicetag = this.activeVoiceTag;
        req.crowd = this.activeIsCrowd;
        req.gender = this.activeGender;
        req.faction = this.activeFaction;
        req.vkey = this.activeVkey;
        req.diag = this.activeDiag;
        req.log = settings.debugLog;
        req.wiki = settings.wikiLookup;
        req.cond = settings.condSeconds;
        req.tts = 1;
        let headers: array<HttpHeader>;
        ArrayPush(headers, HttpHeader.Create("Content-Type", "application/json"));
        AsyncHttpClient.Post(HttpCallback.Create(this, n"OnPrepDone"), cfg.ttsUrl, ToJson(req).ToString(), headers);
    }

    public func PrepStillRunning() -> Void {
        if this.prepPending {
            this.prepLineShown = true;
            let ui = RealTalkUI.Get();
            if IsDefined(ui) && ui.IsOpen() {
                ui.AddLine("--", "learning their voice from your game files...", false);
            }
        }
    }

    private cb func OnPrepDone(response: ref<HttpResponse>) -> Void {
        this.prepPending = false;
        // Was a voice actually built, or just loaded from disk? Only a real
        // forge earns the "learning their voice / voice ready" pair.
        let forged: Bool = false;
        if IsDefined(response) && Equals(response.GetStatus(), HttpStatus.OK) {
            let json = response.GetJson();
            if IsDefined(json) && !json.IsUndefined() {
                let root = json as JsonObject;
                if IsDefined(root) {
                    forged = root.GetKeyInt64("forged") > 0l;
                }
            }
        }
        let ui = RealTalkUI.Get();
        if IsDefined(ui) {
            ui.SetVoicePrep(false);
            if this.prepLineShown && forged && ui.IsOpen() {
                ui.AddLine("--", "voice ready", false);
            }
        }
        if !IsDefined(response) || NotEquals(response.GetStatus(), HttpStatus.OK) {
            StLog("voice: warm-up failed (server down?) - first line will pay the cost instead");
        }
    }

    // Take back the last exchange - your message and their reply - from the
    // conversation and the screen. For when something you said sent a chat
    // somewhere you did not want it to go, without reloading a save: the
    // model never sees it again, so it cannot keep building on it.
    public func UndoLast() -> Bool {
        // ONE message per press - theirs, then yours - so you can take back
        // only their reply and try again, or take back your own line too.
        // history[0] is the character card and is never touched.
        if ArraySize(this.history) <= 1 {
            return false;
        }
        // Actions sit after the reply that caused them, so taking back a
        // message takes back what it did to the transcript too - otherwise
        // undo leaves "starts following you" hanging under nothing.
        let last: Int32 = ArraySize(this.history) - 1;
        while last >= 1 && Equals(this.history[last].role, "action") {
            ArrayRemove(this.history, this.history[last]);
            last -= 1;
        }
        if last < 1 {
            this.SaveActive();
            return true;
        }
        ArrayRemove(this.history, this.history[last]);
        this.SaveActive();
        StLog("chat: undid one message");
        return true;
    }

    // Cheats only: run an intent directly, with nobody asked and nobody
    // agreeing. See RealTalkInput.
    public func CheatAction(intent: String) -> Void {
        if IsDefined(this.actions) && IsDefined(this.activeNpc) {
            this.actions.RunIntent(this.activeNpc, intent);
        }
    }

    public func DisarmActive() -> Bool {
        return IsDefined(this.actions) && IsDefined(this.activeNpc)
            && this.actions.Disarm(this.activeNpc);
    }

    public func ResetNpcActions() -> Void {
        if IsDefined(this.actions) && IsDefined(this.activeNpc) {
            this.actions.EmergencyReset(this.activeNpc);
            this.actions.ReleaseChatHold(this.activeNpc);
        }
    }

    // The poller calls this every tick while the panel is open: a menu lifts
    // the duck (menus should sound normal), so it has to come back afterwards.
    // Is this the person we are mid-conversation with? Used to gag the game's
    // own barks for exactly that one NPC (RealTalkVoice.reds).
    public func IsChattingWith(obj: ref<GameObject>) -> Bool {
        if !IsDefined(obj) || !IsDefined(this.activeNpc) {
            return false;
        }
        let ui = RealTalkUI.Get();
        if !IsDefined(ui) || !ui.IsOpen() {
            return false;
        }
        return EntityID.ToHash(obj.GetEntityID())
            == EntityID.ToHash(this.activeNpc.GetEntityID());
    }

    // "Rebuild All Voices" from Mod Settings: throw the cloned voices away and
    // let them be built again from the game files on the next conversation.
    public func RequestVoiceRebuild() -> Void {
        let cfg = RealTalkConfig.Get();
        if !IsDefined(cfg) {
            return;
        }
        let req = new StTtsResetDTO();
        req.reset_voices = 1;
        let headers: array<HttpHeader>;
        ArrayPush(headers, HttpHeader.Create("Content-Type", "application/json"));
        AsyncHttpClient.Post(HttpCallback.Create(this, n"OnVoiceRebuild"), cfg.ttsUrl,
                             ToJson(req).ToString(), headers);
        StLog("voice: rebuild requested");
    }

    private cb func OnVoiceRebuild(response: ref<HttpResponse>) -> Void {
        let ui = RealTalkUI.Get();
        if IsDefined(ui) && ui.IsOpen() {
            ui.AddLine("--", "voices will be rebuilt from your game files", false);
        }
    }

    // After a load this system is built fresh, so these start at zero by
    // themselves - which is exactly the signal that followers need restoring.
    private let restoreTries: Int32;
    private let restoreDone: Bool;

    public func RestoreFollowersTick() -> Void {
        if this.restoreDone || !IsDefined(this.actions) {
            return;
        }
        this.restoreTries += 1;
        // Roughly a minute of trying at the poller's rate, then give up: an
        // NPC who never streams in is somewhere V is not.
        if this.actions.RestoreFollowers(GetGameInstance()) || this.restoreTries > 120 {
            this.restoreDone = true;
            if this.restoreTries > 120 {
                StLog("follow: gave up restoring companions - never found them");
            }
        }
    }

    // Called from the poller every tick: keeps track of who V is looking at,
    // which is what "him" means when V says "shoot him".
    // Every NPC this mod resolves gets checked against the saved companions.
    public func MatchSavedFollower(npc: ref<NPCPuppet>) -> Void {
        if IsDefined(this.actions) {
            this.actions.MatchSavedFollower(npc);
        }
    }

    public func VerifyFollowersTick() -> Void {
        if IsDefined(this.actions) {
            this.actions.VerifyFollowers();
        }
    }

    public func NoteLookedAt(npc: ref<GameObject>) -> Void {
        if IsDefined(this.actions) && IsDefined(npc) && npc != this.activeNpc {
            this.actions.NoteLookedAt(npc,
                EngineTime.ToFloat(GameInstance.GetSimTime(GetGameInstance())));
        }
    }

    // Diagnostics only: is this the NPC this mod just ordered to attack?
    public func IsUnderOrders(npc: ref<NPCPuppet>) -> Bool {
        return IsDefined(this.actions) && this.actions.IsUnderOrders(npc);
    }

    // Called from the poller while the panel is open.
    public func KeepFacingTick() -> Void {
        if IsDefined(this.actions) && IsDefined(this.activeNpc) {
            this.actions.KeepFacing(this.activeNpc);
        }
    }

    // Called from the poller: a follower climbs into your car when you do.
    public func RideAlongCheck() -> Void {
        if IsDefined(this.actions) {
            this.actions.RideAlongTick();
        }
    }

    public func EnsureDucked() -> Void {
        this.DuckDialogue();
    }

    // Called by the UI when the panel closes: crowd hold ends with the chat.
    public func OnChatClosed() -> Void {
        if IsDefined(this.actions) && IsDefined(this.activeNpc) {
            this.actions.ReleaseChatHold(this.activeNpc);
        }
        this.RestoreDialogue();
    }

    public func SilenceVoice() -> Void {
        // Kill the chunk chain and everything queued - a menu pause should
        // end the whole line, not just the sentence currently playing.
        // Streamed TEXT keeps arriving (the poll id stays); only audio stops.
        this.ttsChainId = "";
        this.FlushReveal();
        this.voiceGen += 1;
        this.ClearQueue();
        if this.voicePlaying {
            this.voicePlaying = false;
            StVoice.Silence(GetGameInstance(), this.activeNpc, this.lastSlot);
        }
        this.vChainId = "";
        this.vGen += 1;
        StVoice.SilenceFlat(GetGameInstance(), this.vLastSlot);
        if IsDefined(this.actions) {
            this.actions.StopTalking(this.activeNpc);
            this.actions.FaceRest(this.activeNpc);
        }
        this.RestoreDialogue();
    }

    // ------------------------------------------------------------------
    //  Cross-session persistence. One file per community NPC, keyed on the
    //  measured-stable persistent id. Crowd NPCs are never saved - their ids
    //  churn every session, so a saved thread would attach to a stranger.
    // ------------------------------------------------------------------
    private func ChatFileName() -> String {
        return s"chat_\(this.activeId).json";
    }

    // Called by the UI when the panel closes. Saves the ENTIRE conversation -
    // it is a text file; disk is not the constraint. The model's context
    // window is, and that limit is applied where it physically exists: on the
    // request, in Send(), governed by the History Sent setting.
    public func SaveActive() -> Void {
        if this.activeId == Cast<Uint64>(0) || this.activeIsCrowd {
            return;
        }
        let dto = new StChatFileDTO();
        let total: Int32 = ArraySize(this.history);
        let i: Int32 = 1;   // index 0 is the system persona - never saved
        while i < total {
            if NotEquals(this.history[i].role, "system") {
                ArrayPush(dto.lines, this.history[i]);
            }
            i += 1;
        }
        // Nothing said = nothing written, so an opened-and-closed panel does
        // not clobber a real saved conversation with an empty one.
        if ArraySize(dto.lines) == 0 {
            return;
        }
        let storage = RealTalkFS.Get().Storage();
        if !IsDefined(storage) {
            return;
        }
        let file = storage.GetFile(this.ChatFileName());
        if IsDefined(file) {
            // WriteText, not WriteJson - see RealTalkMemory.Save.
            file.WriteText(ToJson(dto).ToString());
            StLog(s"chat saved (\(ArraySize(dto.lines)) lines)");
        }
        this.MaybeSummarize();
    }

    // ------------------------------------------------------------------
    //  Memory summaries. Once, on chat close, when enough has been said:
    //  ask the model what this character now remembers about V, and store
    //  it as the gist the persona already injects on the next meeting.
    //  Runs while the panel is closed, so its latency is invisible.
    // ------------------------------------------------------------------
    private func MaybeSummarize() -> Void {
        let settings = RealTalkSettings.Get();
        let cfg = RealTalkConfig.Get();
        let memory = StMemory.Get();
        if !IsDefined(settings) || !settings.summarize || !IsDefined(cfg) || !IsDefined(memory) {
            return;
        }
        if this.summarizing {
            return;
        }
        let nonSystem: Int32 = ArraySize(this.history) - 1;
        // Not before a conversation has any substance, and not again until a
        // dozen new lines have been said since the last summary.
        if nonSystem < 16 || nonSystem - memory.GistLines(this.activeId) < 12 {
            return;
        }

        let convo: String = "";
        let total: Int32 = ArraySize(this.history);
        let start: Int32 = total - 80;
        if start < 1 {
            start = 1;
        }
        let i: Int32 = start;
        while i < total {
            if NotEquals(this.history[i].role, "action") {
                convo += (Equals(this.history[i].role, "user") ? "V: " : "Me: ")
                       + this.history[i].content + "\n";
            }
            i += 1;
        }

        let prior: String = "none";
        let e = memory.FindEntry(this.activeId);
        if IsDefined(e) && StrLen(e.gist) > 0 {
            prior = e.gist;
        }

        let req = new StChatRequestDTO();
        req.model = cfg.customModel;
        req.max_tokens = 180;
        req.temperature = 0.4;
        req.stream = false;
        ArrayPush(req.messages, this.Msg("system",
            "You maintain the private memory of a character in Night City."
            + " From the conversation, write what the character now knows, feels and remembers about V"
            + " - facts, promises, grudges, warmth. Three to five sentences, first person, as the character."
            + " If a previous memory is given, merge it and keep what still matters."));
        ArrayPush(req.messages, this.Msg("user", s"Previous memory: \(prior)\n\nConversation:\n\(convo)"));

        let headers: array<HttpHeader>;
        ArrayPush(headers, HttpHeader.Create("Content-Type", "application/json"));
        if StrLen(cfg.customApiKey) > 0 {
            ArrayPush(headers, HttpHeader.Create("Authorization", "Bearer " + cfg.customApiKey));
        }

        this.summarizing = true;
        this.gistTargetId = this.activeId;
        this.gistTargetLines = nonSystem;
        AsyncHttpClient.Post(HttpCallback.Create(this, n"OnGistReply"), settings.GetEndpoint(), ToJson(req).ToString(), headers);
        StLog("memory summary requested");
    }

    private cb func OnGistReply(response: ref<HttpResponse>) -> Void {
        this.summarizing = false;
        if !IsDefined(response) || NotEquals(response.GetStatus(), HttpStatus.OK) {
            StLog("memory summary failed - will retry after the next conversation");
            return;
        }
        let json = response.GetJson();
        if !IsDefined(json) || json.IsUndefined() {
            return;
        }
        let root = json as JsonObject;
        if !IsDefined(root) {
            return;
        }
        let choices = root.GetKey("choices") as JsonArray;
        if !IsDefined(choices) || choices.GetSize() == 0u {
            return;
        }
        let first = choices.GetItem(0u) as JsonObject;
        if !IsDefined(first) {
            return;
        }
        let message = first.GetKey("message") as JsonObject;
        if !IsDefined(message) {
            return;
        }
        let text: String = message.GetKeyString("content");
        if StrLen(text) == 0 {
            return;
        }
        let memory = StMemory.Get();
        if IsDefined(memory) {
            memory.SetGist(this.gistTargetId, text, this.gistTargetLines);
            StLog(s"memory summary updated: \(text)");
        }
    }

    // Reads the WHOLE saved conversation back into memory - strings in RAM
    // cost nothing either. What gets sent to the model is trimmed in Send().
    // Reading uses the JsonObject accessors so a malformed file degrades to
    // "no past chat".
    private func LoadPast() -> Void {
        let storage = RealTalkFS.Get().Storage();
        if !IsDefined(storage) {
            return;
        }
        if NotEquals(storage.Exists(this.ChatFileName()), FileSystemStatus.True) {
            return;
        }
        let file = storage.GetFile(this.ChatFileName());
        if !IsDefined(file) {
            return;
        }
        let json = file.ReadAsJson();
        if !IsDefined(json) || json.IsUndefined() {
            return;
        }
        let root = json as JsonObject;
        if !IsDefined(root) {
            return;
        }
        let arr = root.GetKey("lines") as JsonArray;
        if !IsDefined(arr) {
            return;
        }
        let size: Uint32 = arr.GetSize();
        let loaded: Int32 = 0;
        let i: Uint32 = 0u;
        while i < size {
            let o = arr.GetItem(i) as JsonObject;
            if IsDefined(o) {
                let role: String = o.GetKeyString("role");
                // "action" belongs here too. These lines are written to the
                // file and were then dropped on the way back in, so the amber
                // record of what actually happened - she started following
                // you, she got in the car - survived a reopen but never
                // survived a restart (field report).
                if Equals(role, "user") || Equals(role, "assistant")
                    || Equals(role, "action") {
                    // Scrub on the way IN as well as out. A conversation saved
                    // before the leak was fixed still contains the model's own
                    // "<|im_start|>user" turn, and a model shown that in its
                    // history will happily produce more of it - a saved bug
                    // that repairs itself instead of needing the player to
                    // wipe the conversation.
                    ArrayPush(this.history, this.Msg(role,
                        StActions.CleanTemplate(o.GetKeyString("content"))));
                    loaded += 1;
                }
            }
            i += 1u;
        }
        if loaded > 0 {
            StLog(s"chat resumed: \(loaded) lines from last session");
        }
    }

    // Overwrite the saved thread with an empty one. RedFileSystem exposes no
    // delete, so empty-write is the erase.
    private func WipeSaved() -> Void {
        if this.activeId == Cast<Uint64>(0) || this.activeIsCrowd {
            return;
        }
        let storage = RealTalkFS.Get().Storage();
        if !IsDefined(storage) {
            return;
        }
        let file = storage.GetFile(this.ChatFileName());
        if IsDefined(file) {
            let dto = new StChatFileDTO();
            file.WriteText(ToJson(dto).ToString());
        }
    }

    // Wipe the current thread but keep the persona, so the NPC is still who
    // they are - you are starting the conversation over, not turning them into
    // a different person. Also clears the stored gist for this NPC, otherwise
    // resetting the visible chat would leave the model still remembering it.
    public func Reset() -> Void {
        if ArraySize(this.history) == 0 {
            return;
        }
        let persona: ref<StChatMessageDTO> = this.history[0];
        ArrayClear(this.history);
        if IsDefined(persona) && Equals(persona.role, "system") {
            ArrayPush(this.history, persona);
        }
        this.busy = false;

        let memory = StMemory.Get();
        if IsDefined(memory) {
            memory.ForgetGist(this.activeId);
        }
        // Forget the saved thread too, or it walks right back in next session.
        this.WipeSaved();
        StLog("conversation reset");
    }

    // Exposed so the UI can redraw an existing conversation on reopen.
    public func GetHistory() -> array<ref<StChatMessageDTO>> {
        return this.history;
    }

    public func IsBusy() -> Bool {
        return this.busy;
    }

    public func Send(playerLine: String) -> Void {
        if this.busy {
            return;
        }
        let settings = RealTalkSettings.Get();
        let cfg = RealTalkConfig.Get();
        if !IsDefined(settings) || !IsDefined(cfg) {
            return;
        }

        ArrayPush(this.history, this.Msg("user", playerLine));
        StLog(s"V: \(playerLine)");
        // What you just asked for, kept until they answer - so "sure" means
        // something.
        this.pendingAsk = StActions.AskIntent(playerLine);

        // V says it out loud while the model composes the answer.
        this.SpeakAsV(playerLine);

        // The request carries the persona plus as many recent lines as the
        // model's context physically holds - measured in tokens against the
        // Context Size setting, newest first. ~4 chars per token plus a small
        // per-message overhead is the standard estimate; 256 tokens of margin
        // absorbs the estimate being wrong. Storage is unlimited; see
        // SaveActive. Anything that no longer fits is what Memory Summaries
        // fold into the NPC's remembered gist.
        let msgs: array<ref<StChatMessageDTO>>;
        let total: Int32 = ArraySize(this.history);
        let budget: Int32 = settings.contextSize - settings.maxTokens - 256;
        budget -= StrLen(this.history[0].content) / 4 + 8;
        let used: Int32 = 0;
        let firstIdx: Int32 = total;
        let j: Int32 = total - 1;
        while j >= 1 {
            // Action lines cost the model nothing: they are never sent.
            let cost: Int32 = Equals(this.history[j].role, "action")
                ? 0 : StrLen(this.history[j].content) / 4 + 8;
            if used + cost > budget {
                break;
            }
            used += cost;
            firstIdx = j;
            j -= 1;
        }
        if firstIdx >= total {
            firstIdx = total - 1;   // always send at least the newest line
        }
        ArrayPush(msgs, this.history[0]);
        let k: Int32 = firstIdx;
        while k < total {
            if NotEquals(this.history[k].role, "action") {
                // TWO USER TURNS IN A ROW IS NOT A CONVERSATION. Undoing a
                // reply leaves the line that prompted it in place, so typing
                // again stacks two user messages together - and a chat
                // template renders that as a malformed exchange, which is
                // exactly the sort of thing a 7B answers badly. Merge them
                // into the one turn they actually are.
                let n: Int32 = ArraySize(msgs);
                if n > 0 && Equals(msgs[n - 1].role, this.history[k].role)
                    && Equals(this.history[k].role, "user") {
                    msgs[n - 1] = this.Msg("user",
                        msgs[n - 1].content + "\n" + this.history[k].content);
                } else {
                    ArrayPush(msgs, this.history[k]);
                }
            }
            k += 1;
        }
        // WHAT V IS DOING WHILE THEY SAY IT, on the newest line only.
        //
        // Told nothing, a character noticed that V was crouched behind cover
        // with a rifle up in 2 of 32 replies; given this, 30 of 32 - with no
        // cost to format compliance (measured, dpe-7b). Putting the same facts
        // in the character card instead only reached 20 of 32: it reads as
        // background there, and as something happening right now here.
        //
        // The newest message only, and only on the copy that is SENT. Stamping
        // it into history would leave a trail of stale poses - "crouched,
        // holding a Lexington" attached to a line said twenty minutes ago -
        // and the saved transcript should be what the player typed.
        // AND IN THE SAME SHAPE THE REPLY IS ASKED FOR. The model is told to
        // write "speech in quotes" then *an action* - so sending V's turn as
        // bare text with an asterisk beat demonstrates half the format and
        // contradicts the other half.
        //
        // Measured head to head at 96 per arm, both carrying the state beat:
        // quoting V's words came out slightly AHEAD on quoted speech (97.9% vs
        // 92.7%, p=0.17 - not significant, so read it as "no worse"), with
        // beats identical at 92.7%. An earlier 32-sample run pointed the other
        // way and was reported as a loss; it was noise (p=0.24). The
        // transcript being internally consistent is the reason to keep it.
        let last: Int32 = ArraySize(msgs) - 1;
        if last > 0 && Equals(msgs[last].role, "user") {
            let said: String = s"\"\(msgs[last].content)\"";
            let doing: String = StTarget.PlayerBeat(GetGameInstance());
            if StrLen(doing) > 0 {
                said += s" *\(doing)*";
                StLog(s"context: V is \(doing)");
            }
            msgs[last] = this.Msg("user", said);
        }

        if firstIdx > 1 {
            StLog(s"context: sending \(total - firstIdx) of \(total - 1) lines (~\(used) tok, budget \(budget)); older lines live in the memory summary");
        }

        let req = new StChatRequestDTO();
        req.model = cfg.customModel;
        req.messages = msgs;
        req.max_tokens = settings.maxTokens;
        req.temperature = settings.temperature;
        req.stream = false;

        // Record that a real conversation happened, and persist it.
        let memory = StMemory.Get();
        if IsDefined(memory) {
            memory.NoteConversation(this.activeId);
        }

        this.busy = true;
        // A new exchange orphans anything still queued from the last one...
        this.voiceGen += 1;
        this.ClearQueue();
        this.revealPending = "";
        this.revealAccum = "";
        // ...and books this exchange's two places in order: V speaks, then
        // they answer. Both are reserved here, before either has a single
        // sample of audio, which is what makes the order independent of how
        // long each takes to synthesise.
        this.vChain = this.ReserveChain(true);
        this.npcChain = this.ReserveChain(false);
        this.SendDirect(req);
    }

    private func SendDirect(req: ref<StChatRequestDTO>) -> Void {
        let settings = RealTalkSettings.Get();
        let cfg = RealTalkConfig.Get();
        if !IsDefined(settings) || !IsDefined(cfg) {
            this.busy = false;
            return;
        }
        let headers: array<HttpHeader>;
        ArrayPush(headers, HttpHeader.Create("Content-Type", "application/json"));
        if StrLen(cfg.customApiKey) > 0 {
            ArrayPush(headers, HttpHeader.Create("Authorization", "Bearer " + cfg.customApiKey));
        }
        let url: String = settings.GetEndpoint();
        AsyncHttpClient.Post(HttpCallback.Create(this, n"OnReply"), url, ToJson(req).ToString(), headers);
        if settings.debugLog {
            StLog(s"POST \(url)");
        }
    }

    public func VoiceIdle() -> Void {
        this.voicePlaying = false;
        if this.talkStopOnIdle {
            if IsDefined(this.actions) {
                this.actions.StopTalking(this.activeNpc);
                this.actions.FaceRest(this.activeNpc);
            }
            // NOT restored here any more - the chat is still open, and the
            // gaps between lines are exactly when barks land.
        }
    }

    // Fire the second-pass classifier: the beat in, one action id out.
    public func ClassifyBeat(beat: String) -> Void {
        let settings = RealTalkSettings.Get();
        let cfg = RealTalkConfig.Get();
        if !IsDefined(settings) || !IsDefined(cfg) {
            return;
        }
        let req = new StClassifyRequestDTO();
        req.model = cfg.customModel;
        req.max_tokens = 12;
        req.temperature = 0.0;
        req.stream = false;
        req.grammar = StActions.ClassifierGrammar();
        let sys = new StChatMessageDTO();
        sys.role = "system";
        sys.content = StActions.ClassifierMenu();
        let usr = new StChatMessageDTO();
        usr.role = "user";
        usr.content = beat;
        ArrayPush(req.messages, sys);
        ArrayPush(req.messages, usr);
        let headers: array<HttpHeader>;
        ArrayPush(headers, HttpHeader.Create("Content-Type", "application/json"));
        if StrLen(cfg.customApiKey) > 0 {
            ArrayPush(headers, HttpHeader.Create("Authorization", "Bearer " + cfg.customApiKey));
        }
        AsyncHttpClient.Post(HttpCallback.Create(this, n"OnClassified"),
                             settings.GetEndpoint(), ToJson(req).ToString(), headers);
    }

    private cb func OnClassified(response: ref<HttpResponse>) -> Void {
        let npc = this.pendingClassNpc;
        if !IsDefined(npc) || !IsDefined(this.actions) {
            return;
        }
        // ANY classifier failure falls back to the word-matcher, so a backend
        // that rejects the grammar field (or is just down) still gets actions.
        if !IsDefined(response) || NotEquals(response.GetStatus(), HttpStatus.OK) {
            StLog("classifier: call failed - falling back to the word matcher");
            this.actions.ApplyIntentAsked(npc, this.pendingClassBeat,
                                          this.pendingClassSpeech, this.pendingClassAsked);
            return;
        }
        let id: String = "";
        let json = response.GetJson();
        if IsDefined(json) && !json.IsUndefined() {
            let root = json as JsonObject;
            if IsDefined(root) {
                let choices = root.GetKey("choices") as JsonArray;
                if IsDefined(choices) && choices.GetSize() > 0u {
                    let msg = (choices.GetItem(0u) as JsonObject).GetKey("message") as JsonObject;
                    if IsDefined(msg) {
                        id = msg.GetKeyString("content");
                    }
                }
            }
        }
        let intent: String = StActions.MapClassId(id);
        if StrLen(intent) > 0 {
            StLog(s"classifier: beat -> \(id) (action)");
            this.actions.DispatchIntent(npc, intent);
            return;
        }
        // An emotion: drive the face with the game's own (category, idle).
        let emo: Int32 = StActions.MapEmotion(id);
        if emo >= 0 {
            StLog(s"classifier: beat -> \(id) (face)");
            this.actions.SetFace(npc, emo / 100, emo % 100);
            return;
        }
        // Beat classified as nothing mechanical. Fall to the asked-agreement:
        // "follow me" / "yeah alright" with no acted beat.
        StLog(s"classifier: beat -> none (\(id))");
        if StrLen(this.pendingClassAsked) > 0
            && StActions.IsAffirmative(this.pendingClassSpeech)
            && !StActions.IsQuestion(this.pendingClassSpeech) {
            StLog(s"classifier: falling to agreement on '\(this.pendingClassAsked)'");
            this.actions.DispatchIntent(npc, this.pendingClassAsked);
        }
    }

    private cb func OnReply(response: ref<HttpResponse>) -> Void {
        this.busy = false;
        let settings = RealTalkSettings.Get();

        // Every failure path now SAYS SO ON SCREEN, not just in the log.
        // Silence read as "the model is warming up" (field report) - the user
        // sat waiting for a reply that a dead socket was never going to send.
        let eui = RealTalkUI.Get();
        if !IsDefined(response) {
            StLog("no response object");
            if IsDefined(eui) && eui.IsOpen() {
                eui.AddAction("no reply came back - is your model server running?");
            }
            this.FlushReveal();
            return;
        }
        if NotEquals(response.GetStatus(), HttpStatus.OK) {
            let code = response.GetStatusCode();
            StLog(s"request failed, status \(code)");
            if IsDefined(eui) && eui.IsOpen() {
                if code == 0 {
                    // Never opened a socket: server down, wrong port, or the
                    // -no-tls flag is missing. His exact case was a port
                    // mismatch after a settings reset.
                    eui.AddAction("can't reach the model - check Mod Settings > Server (right program/port), and that the game was launched with -no-tls.");
                } else {
                    eui.AddAction(s"the model server returned an error (status \(code)).");
                }
            }
            if code == 0 {
                StLog("  status 0 = the request never opened a socket.");
                StLog("  Launch the game with:  %command% -no-tls");
                StLog("  and make sure RedHttpClient is 0.7.1 or newer.");
            }
            this.FlushReveal();
            return;
        }

        let json = response.GetJson();
        if !IsDefined(json) || json.IsUndefined() {
            StLog("response was not valid JSON");
            if IsDefined(eui) && eui.IsOpen() {
                eui.AddAction("the server replied, but not in the expected format.");
            }
            this.FlushReveal();
            return;
        }
        let root = json as JsonObject;
        if !IsDefined(root) {
            return;
        }
        let choices = root.GetKey("choices") as JsonArray;
        if !IsDefined(choices) || choices.GetSize() == 0u {
            StLog("no choices in response");
            return;
        }
        let first = choices.GetItem(0u) as JsonObject;
        if !IsDefined(first) {
            return;
        }
        let message = first.GetKey("message") as JsonObject;
        if !IsDefined(message) {
            return;
        }
        let text: String = message.GetKeyString("content");

        if StrLen(text) == 0 {
            // Empty content with a 200 means a reasoning model put its output
            // in reasoning_content. Say so plainly rather than showing a blank
            // message - this exact failure wasted hours once already.
            StLog("empty content - the server is running a REASONING model.");
            StLog("  Start it with --reasoning off, or use a non-reasoning model.");
            return;
        }

        // Chat-template leakage comes off before anything else looks at the
        // reply - a leaked "<|im_start|>assistant" turn must never reach the
        // screen, the voice, the history, or the animation search.
        text = StActions.CleanTemplate(text);

        // The narration around the quotes is not garbage - it is the stage
        // direction the persona asks for, and it drives the animation and
        // facial pick. Harvest it FIRST, then reduce the message to the
        // spoken words for display, voice, and history.
        this.activeDirection = StActions.ExtractDirection(text, this.activeName);
        // A beat is a few words. Anything longer is prose the game cannot act
        // out, and storing it teaches the model to write more of it - so it is
        // cut here, before it reaches history or the animation search.
        if StrLen(this.activeDirection) > 90 {
            this.activeDirection = StrLeft(this.activeDirection, 90);
        }
        this.pendingAnim = n"";
        text = StActions.CleanProse(text, this.activeName);

        // Act on any tags before the text is shown or stored - the cleaned
        // reply is what goes in history, so tags never feed back into context
        // and multiply.
        if IsDefined(settings) && settings.npcActions && IsDefined(this.activeNpc) && IsDefined(this.actions) {
            this.actions.BeginReply();
            text = this.actions.Apply(this.activeNpc, text);
            // THE ACTION FROM THE BEAT. With Smart Actions on and a beat to
            // read, a second model call classifies it (see OnClassified);
            // otherwise the hand-written word-matcher runs. Either way explicit
            // [tags] above already won.
            if IsDefined(settings) && settings.smartActions
                && StrLen(this.activeDirection) > 3 {
                this.pendingClassNpc = this.activeNpc;
                this.pendingClassBeat = this.activeDirection;
                this.pendingClassSpeech = text;
                this.pendingClassAsked = this.pendingAsk;
                this.ClassifyBeat(this.activeDirection);
            } else {
                // No beat (asked-agreement still handled here), or classifier
                // off -> the word-matcher.
                this.actions.ApplyIntentAsked(this.activeNpc, this.activeDirection,
                                              text, this.pendingAsk);
            }
            this.pendingAsk = "";
        }

        // WHAT THE MODEL REMEMBERS SAYING: the words plus its own action beat,
        // which is how a roleplay chat reads and how the format sustains
        // itself - a model shown its own beats keeps writing them, and those
        // beats are what drive the animations and the intent actions. The
        // executed TAGS stay out: those already happened, and feeding them
        // back invites a model to sprinkle more of them every turn.
        let remembered: String = text;
        if StrLen(this.activeDirection) > 0 {
            // Empty quotes in front of a beat is not something anyone writes,
            // and a model shown that starts producing it.
            remembered = !StActions.IsBlank(text)
                ? s"\"\(text)\" \(this.activeDirection)"
                : this.activeDirection;
        }
        if !StActions.IsBlank(remembered) {
            ArrayPush(this.history, this.Msg("assistant", remembered));
            // SAVED HERE, not only when the panel closes. Persisting on close
            // alone means a session that ends any other way - quitting with
            // the chat open, a crash, alt-F4 - loses the whole conversation,
            // which is exactly what happened (a full session with zero "chat
            // saved" lines in the log). A small write per reply is nothing
            // next to losing an evening's conversation.
            this.SaveActive();
        }

        // Voice-paced text: when the reply will be SPOKEN, each sentence
        // appears as its audio starts - the text "streams" with the voice
        // instead of landing all at once ahead of it. No voice = instant
        // text, and every failure path flushes the full text.
        let spoke: Bool = this.MaybeSpeak(text);
        if !spoke {
            // Nothing to say out loud: give the place back rather than making
            // everything behind it wait for audio that is never coming.
            this.CloseChain(this.npcChain);
        }
        let ui = RealTalkUI.Get();
        if spoke {
            this.revealPending = text;
            this.revealAccum = "";
            // the "thinking" beat: a placeholder that the first spoken
            // sentence replaces the moment audio starts
            if IsDefined(ui) && ui.IsOpen() {
                ui.AddLine("THEM", "...", false);
            }
            // Generous: the 12s version fired BEFORE slow multi-sentence
            // synthesis started playing, dumping all text early - the exact
            // text-way-before-voice complaint. Chunk pacing owns the text;
            // this only rescues it when the audio chain genuinely dies.
            let flush = new StRevealFlushTick();
            flush.chat = this;
            flush.gen = this.voiceGen;
            GameInstance.GetDelaySystem(GetGameInstance()).DelayCallback(flush, 25.0, false);
        } else {
            if IsDefined(ui) && ui.IsOpen() {
                // A reply that was ONLY a tag or only a beat leaves nothing to
                // say once it is cleaned - it printed as a blank "THEM:" line
                // (field report). Nothing spoken means nothing shown.
                if !StActions.IsBlank(text) {
                    ui.AddLine("THEM", text, false);
                } else {
                    // Say so on screen. A reply that vanishes silently is
                    // indistinguishable from the mod being broken - and a
                    // reply that was ALL narration is not nothing: it is what
                    // she did, and it belongs on screen as an action.
                    if StrLen(this.activeDirection) == 0 {
                        ui.AddAction("no answer came back - say that again");
                        StLog("reply: the model returned nothing");
                    } else {
                        ui.AddAction(this.activeDirection, true);
                        StLog("reply was action-only - shown as an action");
                    }
                }
            }
        }
        // THE WHOLE REPLY. A debug log that hides the text is useless for
        // debugging - the point of the switch is that nothing is written at
        // all while it is OFF (owner call, and obviously right).
        StLog(s"reply: \(text)");
    }

    // ------------------------------------------------------------------
    //  Spoken replies. Ask the TTS server to render the line into an
    //  Audioware slot; play the slot at the NPC once the server confirms
    //  the file is written. Text is never delayed by this - it is already
    //  on screen when the request goes out.
    // ------------------------------------------------------------------
    private let revealPending: String;
    private let revealAccum: String;

    public func FlushRevealIf(gen: Int32) -> Void {
        if gen == this.voiceGen {
            this.FlushReveal();
        }
    }

    public func FlushReveal() -> Void {
        if StrLen(this.revealPending) > 0 {
            let full: String = this.revealPending;
            this.revealPending = "";
            this.revealAccum = "";
            let ui = RealTalkUI.Get();
            if IsDefined(ui) && ui.IsOpen() {
                ui.UpdateLastLine("THEM", full);
            }
        }
    }

    // V's line, in V's voice, from the player. Fired the moment the message is
    // sent - it plays while the model is still writing the answer.
    public func SpeakAsV(playerLine: String) -> Void {
        let settings = RealTalkSettings.Get();
        let cfg = RealTalkConfig.Get();
        if !IsDefined(settings) || !settings.ttsEnabled || !settings.vVoice
            || !IsDefined(cfg) || StrLen(playerLine) == 0 {
            this.CloseChain(this.vChain);   // V is not speaking this turn
            return;
        }
        let player = GetPlayer(GetGameInstance());
        if !IsDefined(player) {
            this.CloseChain(this.vChain);
            return;
        }
        this.vChainId = "";
        this.vGen += 1;
        let vui = RealTalkUI.Get();
        if IsDefined(vui) {
            vui.SetVoicing(true);
        }

        let req = new StTtsRequestDTO();
        req.text = playerLine;
        req.voice = "V";
        // GetResolvedGenderName IS the player-appearance API - the one that
        // returns nothing for NPCs (see RealTalkGender.reds) - so here, on
        // the player, it is exactly right. Male and female V share the single
        // "v" speaker slug in the archives, so the forge needs the gender to
        // avoid cloning both at once.
        req.gender = NameToString(player.GetResolvedGenderName());
        // Roughly -8 dB. V's line plays flat at the listener's own position
        // while every NPC line is attenuated by distance, so equal gain is not
        // an equal mix - V came out plainly louder than the game's own V.
        req.gain = 0.45;   // -7 dB, measured in an editor against the game's own V lines
        let vset = RealTalkSettings.Get();
        if IsDefined(vset) {
            req.cond = vset.condSeconds;
        }
        req.slot = this.ttsSlot;
        this.ttsSlot = (this.ttsSlot + 1) % 4;
        let headers: array<HttpHeader>;
        ArrayPush(headers, HttpHeader.Create("Content-Type", "application/json"));
        AsyncHttpClient.Post(HttpCallback.Create(this, n"OnVTtsReady"), cfg.ttsUrl,
                             ToJson(req).ToString(), headers);
    }

    private cb func OnVTtsReady(response: ref<HttpResponse>) -> Void {
        if !IsDefined(response) || NotEquals(response.GetStatus(), HttpStatus.OK) {
            let failUi = RealTalkUI.Get();
            if IsDefined(failUi) {
                failUi.SetVoicing(false);
            }
            this.CloseChain(this.vChain);
            return;
        }
        let json = response.GetJson();
        if !IsDefined(json) || json.IsUndefined() {
            return;
        }
        let root = json as JsonObject;
        if !IsDefined(root) {
            return;
        }
        let id: String = root.GetKeyString("id");
        let isCont: Bool = root.GetKeyInt64("cont") > 0l;
        if isCont && NotEquals(id, this.vChainId) {
            return;   // superseded chain
        }
        let slot: Int32 = Cast<Int32>(root.GetKeyInt64("slot"));
        let durMs: Int64 = root.GetKeyInt64("dur_ms");
        this.Enqueue(this.vChain, slot, durMs, "", false);
        if root.GetKeyInt64("more") > 0l {
            this.vChainId = id;
            let next = new StVTtsNextTick();
            next.chat = this;
            next.id = id;
            GameInstance.GetDelaySystem(GetGameInstance()).DelayCallback(next, 0.05, false);
        } else {
            this.CloseChain(this.vChain);
        }
    }

    public func PlayVNow(slot: Int32, gen: Int32) -> Void {
        let doneUi = RealTalkUI.Get();
        if IsDefined(doneUi) {
            doneUi.SetVoicing(false);   // V is audible now
        }
        if gen != this.vGen {
            return;
        }
        if GameInstance.GetBlackboardSystem(GetGameInstance()).Get(GetAllBlackboardDefs().UI_System)
            .GetBool(GetAllBlackboardDefs().UI_System.IsInMenu) {
            return;
        }
        StVoice.SpeakFlat(GetGameInstance(), slot);
        this.vLastSlot = slot;
    }

    public func RequestNextVChunk(id: String) -> Void {
        let cfg = RealTalkConfig.Get();
        if !IsDefined(cfg) || NotEquals(id, this.vChainId) {
            return;
        }
        let req = new StTtsNextDTO();
        req.next = id;
        req.slot = this.ttsSlot;
        this.ttsSlot = (this.ttsSlot + 1) % 4;
        let headers: array<HttpHeader>;
        ArrayPush(headers, HttpHeader.Create("Content-Type", "application/json"));
        AsyncHttpClient.Post(HttpCallback.Create(this, n"OnVTtsReady"), cfg.ttsUrl,
                             ToJson(req).ToString(), headers);
    }

    private func MaybeSpeak(text: String) -> Bool {
        let settings = RealTalkSettings.Get();
        let cfg = RealTalkConfig.Get();
        if !IsDefined(settings) || !settings.ttsEnabled || !IsDefined(cfg) {
            return false;
        }
        if !IsDefined(this.activeNpc) {
            return false;
        }
        // NOTHING TO SAY IS NOT SOMETHING TO SYNTHESISE. An empty reply was
        // still sent to the voice server, still put a "..." placeholder on
        // screen, and then had no text to replace it with - so the panel sat
        // on "Panam: ..." forever while the log said the server had failed
        // (field report).
        if StActions.IsBlank(text) {
            return false;
        }
        // A new reply supersedes any chunk chain still in flight.
        this.ttsChainId = "";

        let req = new StTtsRequestDTO();
        req.text = text;
        req.voice = this.activeName;
        req.voicetag = this.activeVoiceTag;
        req.crowd = this.activeIsCrowd;
        req.gender = this.activeGender;
        req.faction = this.activeFaction;
        req.vkey = this.activeVkey;
        req.direction = this.activeDirection;
        req.held = StrLen(StActions.HeldItemName(this.activeNpc)) > 0;
        req.log = settings.debugLog;
        req.cond = settings.condSeconds;
        req.slot = this.ttsSlot;
        this.ttsPendingSlot = this.ttsSlot;
        this.ttsSlot = (this.ttsSlot + 1) % 4;

        let headers: array<HttpHeader>;
        ArrayPush(headers, HttpHeader.Create("Content-Type", "application/json"));
        AsyncHttpClient.Post(HttpCallback.Create(this, n"OnTtsReady"), cfg.ttsUrl, ToJson(req).ToString(), headers);
        // THE line whose absence broke voice-paced text entirely: without it
        // this Bool function fell off the end, returned default FALSE, and
        // every reply took the no-voice instant-text path - words on screen,
        // voice trailing behind, pacing machinery never engaged once.
        return true;
    }

    // Chained playback state: replies are spoken sentence by sentence, so the
    // voice starts after the FIRST sentence synthesizes instead of the whole
    // reply. Each response carries the chunk's duration; the next fetch is
    // scheduled for when the current chunk finishes.
    private let ttsChainId: String;

    private cb func OnTtsReady(response: ref<HttpResponse>) -> Void {
        if !IsDefined(response) || NotEquals(response.GetStatus(), HttpStatus.OK) {
            StLog("voice: TTS server unreachable or failed - is npc-tts-server.sh running?");
            this.FlushReveal();
            return;
        }
        let json = response.GetJson();
        if !IsDefined(json) || json.IsUndefined() {
            return;
        }
        let root = json as JsonObject;
        if !IsDefined(root) {
            return;
        }
        let id: String = root.GetKeyString("id");
        let isCont: Bool = root.GetKeyInt64("cont") > 0l;
        // A continuation from a chain we already abandoned (menu opened, or a
        // newer reply started): drop it.
        if isCont && NotEquals(id, this.ttsChainId) {
            return;
        }
        let animPick: String = root.GetKeyString("anim");
        if StrLen(animPick) > 0 {
            this.pendingAnim = StringToName(animPick);
        }
        let slot: Int32 = Cast<Int32>(root.GetKeyInt64("slot"));
        this.PlayChunk(slot, root.GetKeyInt64("dur_ms"), root.GetKeyString("text"),
                       root.GetKeyInt64("more") > 0l);

        if root.GetKeyInt64("more") > 0l {
            this.ttsChainId = id;
            let tick = new StTtsNextTick();
            tick.chat = this;
            tick.id = id;
            // Ask for the next chunk IMMEDIATELY - the server blocks until it
            // is synthesized and PlayChunk queues it to start the instant the
            // current one ends. Waiting for playback to finish before even
            // asking was the mid-reply pause.
            GameInstance.GetDelaySystem(GetGameInstance()).DelayCallback(tick, 0.05, false);
        } else {
            this.ttsChainId = "";
            // exact final text once the last chunk finishes speaking
            let flush = new StRevealFlushTick();
            flush.chat = this;
            flush.gen = this.voiceGen;
            // The queue decides when the words finish, so this is only the
            // net that catches a chain that dies mid-sentence.
            GameInstance.GetDelaySystem(GetGameInstance()).DelayCallback(flush, 25.0, false);
        }
    }

    public func RequestNextChunk(id: String) -> Void {
        if NotEquals(id, this.ttsChainId) {
            return;   // chain was silenced or superseded while we waited
        }
        let cfg = RealTalkConfig.Get();
        if !IsDefined(cfg) {
            return;
        }
        let req = new StTtsNextDTO();
        req.next = id;
        req.slot = this.ttsSlot;
        this.ttsPendingSlot = this.ttsSlot;
        this.ttsSlot = (this.ttsSlot + 1) % 4;

        let headers: array<HttpHeader>;
        ArrayPush(headers, HttpHeader.Create("Content-Type", "application/json"));
        AsyncHttpClient.Post(HttpCallback.Create(this, n"OnTtsReady"), cfg.ttsUrl, ToJson(req).ToString(), headers);
    }

    public static func Get() -> ref<StChat> {
        return GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"RealTalk.StChat") as StChat;
    }
}
