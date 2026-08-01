// ============================================================================
//  STREET TALK - look-at prompt poller
// ============================================================================
//
//  Decides when the "[R] talk" prompt is on screen. The drawing itself lives
//  in StreetTalkUI.ShowHint/HideHint.
//
//  WHY THE GAME'S INPUT-HINT RAIL IS NOT USED ANY MORE:
//    InputHintData.action must name a game ACTION - that is what the icon
//    lookup keys off (braindance.swift:444) - and the talk key is no longer an
//    action, it is a raw, user-configurable key. The rail has no way to render
//    an icon for it. A label the mod draws itself, built from the same setting
//    as the binding, can never show a stale key.
// ============================================================================

module StreetTalk

import RedFileSystem.*

public class StreetTalkHintSystem extends ScriptableSystem {
    private let shown: Bool;
    private let ticks: Int32;

    // ---- overheard dialogue (see StreetTalkOverheard.reds) ----
    // Lives here because this system provably instantiates and ticks.
    private let heard: array<ref<StOverheardLine>>;

    private func OnAttach() -> Void {
        let cb = new StHintTick();
        cb.system = this;
        GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(cb, 3.0, false);

    }

    // Called from the subtitle line controllers (StreetTalkOverheard.reds).
    public func NoteOverheard(line: scnDialogLineData) -> Void {
        if Equals(line.type, scnDialogLineType.Radio) || StrLen(line.text) == 0
            || !IsDefined(line.speaker) {
            return;
        }
        let entry = new StOverheardLine();
        entry.speakerHash = EntityID.ToHash(line.speaker.GetEntityID());
        entry.speakerName = line.speakerName;
        // A CAST, not an id comparison. Comparing entity-id hashes marked
        // every line as the player's, V and vendor alike (field-caught), so
        // the whole exchange looked like V talking to himself and nothing ever
        // matched the NPC.
        entry.isPlayer = IsDefined(line.speaker as PlayerPuppet);
        entry.text = StActions.CleanMarkup(line.text);
        entry.at = EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGameInstance()));
        // The same line can be re-set as the widget updates; ignore repeats.
        let n: Int32 = ArraySize(this.heard);
        if n > 0 && Equals(this.heard[n - 1].text, entry.text) {
            return;
        }
        ArrayPush(this.heard, entry);
        if ArraySize(this.heard) > 16 {
            ArrayRemove(this.heard, this.heard[0]);
        }
        StLog(s"overheard: \(line.speakerName): \(entry.text)"
            + (entry.isPlayer ? " (that was V)" : ""));
    }

    // The exchange just heard with THIS npc, oldest first. Empty when nothing
    // recent involved them.
    public func RecentWith(npc: ref<NPCPuppet>, displayName: String) -> array<ref<StOverheardLine>> {
        let out: array<ref<StOverheardLine>>;
        if !IsDefined(npc) {
            return out;
        }
        let hash: Uint64 = EntityID.ToHash(npc.GetEntityID());
        let name: String = StrLower(displayName);
        let now: Float = EngineTime.ToFloat(GameInstance.GetSimTime(this.GetGameInstance()));

        // ONE EXCHANGE, bounded by whoever else spoke. The first version took
        // this NPC's lines plus ANY of V's lines from the last minute, so
        // talking to a vendor and then walking up to a pedestrian pulled V's
        // half of the vendor conversation into her chat (field report).
        //
        // A third party speaking IS the boundary: scanning back from the
        // newest line, another NPC's voice ends the exchange. Within that run,
        // V's lines count as part of it - they were said to this person -
        // except a leading one, which only belongs if it came moments before
        // they answered (the "press F and get snapped at" case).
        let firstIdx: Int32 = -1;
        let sawNpc: Bool = false;
        let i: Int32 = ArraySize(this.heard) - 1;
        while i >= 0 {
            let l = this.heard[i];
            if now - l.at > 60.0 {
                break;
            }
            if this.Mine(l, hash, name) {
                sawNpc = true;
                firstIdx = i;
            } else {
                if l.isPlayer {
                    firstIdx = i;
                } else {
                    break;   // somebody else was talking: exchange ends here
                }
            }
            i -= 1;
        }
        if !sawNpc {
            StLog(s"overheard: nothing recent from this NPC (\(ArraySize(this.heard)) lines buffered)");
            return out;
        }
        // Drop leading lines of V's that predate this person's first word by
        // more than a beat - those were addressed to whoever came before.
        while firstIdx < ArraySize(this.heard) && this.heard[firstIdx].isPlayer {
            let nextIsTheirs: Bool = firstIdx + 1 < ArraySize(this.heard)
                && this.Mine(this.heard[firstIdx + 1], hash, name)
                && this.heard[firstIdx + 1].at - this.heard[firstIdx].at <= 15.0;
            if nextIsTheirs {
                break;
            }
            firstIdx += 1;
        }
        let j: Int32 = firstIdx;
        while j < ArraySize(this.heard) {
            ArrayPush(out, this.heard[j]);
            j += 1;
        }
        return out;
    }

    // Is this line THIS npc's? Entity id when it lines up, otherwise the
    // game's own speaker label - which for a named character comes from the
    // same record the chat header does.
    private func Mine(l: ref<StOverheardLine>, hash: Uint64, lowerName: String) -> Bool {
        if l.isPlayer {
            return false;
        }
        if l.speakerHash == hash {
            return true;
        }
        return StrLen(lowerName) > 0 && Equals(StrLower(l.speakerName), lowerName);
    }

    public func Tick() -> Void {
        let game = this.GetGameInstance();
        this.ticks += 1;
        if this.ticks == 1 {
            StLog("hint poller running");
        // WHICH BUILD IS THIS? redscript compiles at launch, so copying files
        // into the game while it is running changes nothing until the next
        // start - and two rounds of diagnosis were spent on logs that may or
        // may not have come from the build being diagnosed.
        StLog("build: facing-from-vectors (GetWorldForward + GetAngleDegAroundAxis)");
        }
        if this.ticks == 1 {
            // Crash insurance for the dialogue duck: if the last session died
            // while an NPC reply was playing, the user's Dialogue volume was
            // left lowered. The saved value waits in storage; put it back
            // before anyone notices their game got quiet.
            let fs = StreetTalkFS.Get();
            if IsDefined(fs) && IsDefined(fs.Storage()) {
                let marker = fs.Storage().GetFile("duck_marker.txt");
                if IsDefined(marker) {
                    let savedText: String = marker.ReadAsText();
                    let saved: Int32 = StringToInt(savedText, 0);
                    if saved > 20 {
                        let us = GameInstance.GetSettingsSystem(game);
                        if IsDefined(us) && us.HasGroup(n"/audio/volume") {
                            let grp = us.GetGroup(n"/audio/volume");
                            if grp.HasVar(n"DialogueVolume") {
                                let v = grp.GetVar(n"DialogueVolume") as ConfigVarInt;
                                if IsDefined(v) && v.GetValue() < saved {
                                    v.SetValue(saved);
                                    StLog(s"dialogue volume restored to \(saved) after unclean shutdown");
                                }
                            }
                        }
                        let mfc = fs.Storage().GetFile("duck_marker.txt");
            if IsDefined(mfc) {
                mfc.WriteText("");
            }
                    }
                }
            }
        }

        let ui = StreetTalkUI.Get();
        let settings = StreetTalkSettings.Get();

        // Menus pause the game but not Audioware - silence any spoken line
        // the moment one opens.
        let inMenu: Bool = GameInstance.GetBlackboardSystem(game)
            .Get(GetAllBlackboardDefs().UI_System)
            .GetBool(GetAllBlackboardDefs().UI_System.IsInMenu);
        if inMenu {
            let voiceChat = StChat.Get();
            if IsDefined(voiceChat) {
                voiceChat.SilenceVoice();
            }
        } else {
            // Chat open and no menu: the game's dialogue channel stays ducked,
            // so nothing but our own voices talks. Idempotent.
            if IsDefined(ui) && ui.IsOpen() {
                let duckChat = StChat.Get();
                if IsDefined(duckChat) {
                    duckChat.EnsureDucked();
                }
            }
        }

        // "Forget Everyone" is a toggle standing in for a button (Mod Settings
        // has no button type), so it has to be watched rather than listened
        // to. This poller already runs, so the check is free.
        if IsDefined(settings) && settings.resetVoices {
            settings.resetVoices = false;
            let vchat = StChat.Get();
            if IsDefined(vchat) {
                vchat.RequestVoiceRebuild();
            }
        }

        if IsDefined(settings) && settings.forgetEveryone {
            settings.forgetEveryone = false;
            let memory = StMemory.Get();
            if IsDefined(memory) {
                memory.ForgetAll();
            }
            let chat = StChat.Get();
            if IsDefined(chat) {
                chat.Reset();
            }
        }

        // A follower rides along - checked every tick, so it works whether you
        // get in the car during the conversation or long after it.
        let rideChat = StChat.Get();
        if IsDefined(rideChat) {
            rideChat.RideAlongCheck();
            rideChat.RestoreFollowersTick();
            rideChat.VerifyFollowersTick();
            if IsDefined(ui) && ui.IsOpen() {
                rideChat.KeepFacingTick();
            }
        }

        // Remember who V is looking at even while the panel is open - that is
        // the whole point: "shoot him" is typed with a chat window up, long
        // after the crosshair has drifted off the person V meant.
        let seenChat = StChat.Get();
        if IsDefined(seenChat) {
            let seen = StTarget.AimObject(game);
            seenChat.NoteLookedAt(seen);
            // Looking at someone is enough to pick a saved companion back up.
            seenChat.MatchSavedFollower(seen as NPCPuppet);
        }

        let want: Bool = false;
        if IsDefined(settings) && settings.enabled && IsDefined(ui) && !ui.IsOpen() {
            let npc: ref<NPCPuppet> = StTarget.LookAtNpc(game);
            if IsDefined(npc) && !npc.IsDead() && !npc.IsEnemy() && !npc.IsAggressive() {
                let identity: ref<StIdentity> = StIdentityResolver.Resolve(npc);
                if identity.valid {
                    if identity.isCrowd {
                        want = settings.allowCrowd;
                    } else {
                        want = settings.allowCommunity;
                    }
                }
            }
        }

        if want && !this.shown {
            ui.ShowHint(settings.OpenKeyLabel());
            this.shown = true;
        } else {
            if !want && this.shown {
                if IsDefined(ui) {
                    ui.HideHint();
                }
                this.shown = false;
            }
        }

        let next = new StHintTick();
        next.system = this;
        GameInstance.GetDelaySystem(game).DelayCallback(next, 0.25, false);
    }
}

public class StHintTick extends DelayCallback {
    public let system: wref<StreetTalkHintSystem>;
    public func Call() -> Void {
        if IsDefined(this.system) {
            this.system.Tick();
        }
    }
}
