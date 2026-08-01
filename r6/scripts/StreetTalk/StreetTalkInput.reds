// ============================================================================
//  STREET TALK - input
// ============================================================================
//
//  Raw keys via Codeware's CallbackSystem ("Input/Key") - the same layer
//  Generative Texting uses - plus ONE properly-registered game-action listener
//  used purely defensively (see StreetTalkActionGuard below).
//
//  THE OPEN/CLOSE KEY ACTS ON RELEASE, NOT PRESS:
//    Opening on press created the text box and focused it in the same frame as
//    the keystroke, so the character event from that same press landed in the
//    box - open the chat with R and an "r" was already sitting in the input.
//    Character events arrive with the press; by release they have already
//    happened, so a box created on release starts empty. Release for both open
//    and close also means one keystroke toggles exactly once.
//
//  Keys (Mod Settings > Street Talk > Controls; defaults):
//    R       open on the NPC you are looking at / close again. Closing needs
//            the text box unfocused - ENTER on an empty box steps out first.
//    ENTER   send; on an empty box, step out of the box
//    DELETE  reset the conversation (not while typing - while the box is
//            focused DELETE belongs to text editing)
// ============================================================================

module StreetTalk

public class StreetTalkInputSystem extends ScriptableSystem {

    private let callbackSystem: wref<CallbackSystem>;
    public let typing: Bool;

    // ------------------------------------------------------------------
    //  Dialogue suppression.
    //
    //  This lived in its own ScriptableSystem (StDialogSuppression) and that
    //  system NEVER CAME UP - the session log showed the panel opening with no
    //  "dialogue suppressed" line, because Get() returned null and an
    //  IsDefined guard silently skipped the whole thing. That is why ENTER
    //  still selected dialogue options: nothing was ever suppressed.
    //
    //  It now lives HERE, in the system that provably instantiates (every
    //  keypress goes through it) - and deliberately as a BARE BOOL. The dead
    //  system's one structural difference from every working one was its
    //  DialogChoiceHubs struct field; ScriptableSystems participate in save
    //  persistence, making a native importonly struct field the prime suspect.
    //  Unproven - but no struct field is needed anyway, so the design removes
    //  the suspect entirely rather than moving it into the system that must
    //  not break.
    //
    //  Suppress = write empty once + filter renders while open
    //  (StreetTalkDialog.reds). Restore = push the captured hubs back AND
    //  stop filtering: the game rewrites this blackboard from its own
    //  authoritative state, but only ON CHANGE - relying on that alone left
    //  the options hidden until the player looked away and back.
    // ------------------------------------------------------------------
    private let suppressing: Bool;
    // The hub state captured at suppress time, pushed straight back on
    // close. Waiting for the game's next rewrite is not enough: it only
    // rewrites on CHANGE, so standing still after closing the chat left
    // the real dialogue options hidden until you looked away and back
    // (field report). If the capture is stale, the game's next authoritative
    // write wins anyway.
    private let savedHubs: Variant;

    public func IsSuppressing() -> Bool {
        return this.suppressing;
    }

    private func SuppressDialogs() -> Void {
        if this.suppressing {
            return;
        }
        let bboard = GameInstance.GetBlackboardSystem(this.GetGameInstance())
            .Get(GetAllBlackboardDefs().UIInteractions);
        if !IsDefined(bboard) {
            StLog("suppress FAILED: UIInteractions blackboard not found");
            return;
        }
        let key = GetAllBlackboardDefs().UIInteractions.DialogChoiceHubs;
        this.savedHubs = bboard.GetVariant(key);
        let live: DialogChoiceHubs = FromVariant<DialogChoiceHubs>(this.savedHubs);
        this.suppressing = true;

        let empty: DialogChoiceHubs;
        bboard.SetVariant(key, ToVariant(empty));
        StLog(s"dialogue suppressed (\(ArraySize(live.choiceHubs)) hub(s) were live)");
    }

    private func RestoreDialogs() -> Void {
        if !this.suppressing {
            return;
        }
        this.suppressing = false;
        let bboard = GameInstance.GetBlackboardSystem(this.GetGameInstance())
            .Get(GetAllBlackboardDefs().UIInteractions);
        if IsDefined(bboard) {
            // forceFire=true so listeners redraw even though the value may
            // equal what they last rendered before suppression.
            bboard.SetVariant(GetAllBlackboardDefs().UIInteractions.DialogChoiceHubs, this.savedHubs, true);
        }
        StLog("dialogue suppression lifted, hubs pushed back");
    }

    // Called by the UI when the panel closes.
    public func RestoreInteraction() -> Void {
        this.RestoreDialogs();
    }

    // ------------------------------------------------------------------
    //  Raw keys
    // ------------------------------------------------------------------
    private func OnAttach() -> Void {
        this.callbackSystem = GameInstance.GetCallbackSystem();
        if IsDefined(this.callbackSystem) {
            this.callbackSystem.RegisterCallback(n"Input/Key", this, n"OnKeyInput", true);
        }
    }

    private func OnDetach() -> Void {
        if IsDefined(this.callbackSystem) {
            this.callbackSystem.UnregisterCallback(n"Input/Key", this, n"OnKeyInput");
        }
    }

    private cb func OnKeyInput(event: ref<KeyInputEvent>) -> Void {
        let act: String = s"\(event.GetAction())";
        let isPress: Bool = Equals(act, "IACT_Press");
        let isRelease: Bool = Equals(act, "IACT_Release");
        if !isPress && !isRelease {
            return;
        }

        let settings = StreetTalkSettings.Get();
        if !IsDefined(settings) || !settings.enabled {
            return;
        }
        let ui = StreetTalkUI.Get();
        if !IsDefined(ui) {
            return;
        }

        let key: String = s"\(event.GetKey())";

        // ---- typing: every key belongs to the text box except ENTER ----
        if this.typing {
            if isPress && Equals(key, "IK_Enter") {
                let text: String = ui.GetTyped();
                if StrLen(text) == 0 {
                    // Sending nothing steps out of the box, which is what
                    // frees the close and reset keys.
                    this.typing = false;
                    ui.Unfocus();
                    return;
                }
                // Escape hatch, not dialogue: undo anything the mod ever
                // commanded on this NPC (runaway follow, etc).
                if Equals(text, "/reset") || Equals(text, "/stop") {
                    let rchat = StChat.Get();
                    if IsDefined(rchat) {
                        rchat.ResetNpcActions();
                    }
                    ui.ClearTyped();
                    ui.AddLine("--", "npc actions reset", false);
                    return;
                }
                // TAKING A WEAPON IS V'S CALL, NOT THE MODEL'S. Asking someone
                // to put it away is roleplay and goes through the normal
                // intent path; taking it off them is a decision the player
                // makes, so it is a command rather than something an NPC can
                // be talked into doing to itself.
                if Equals(text, "/disarm") || Equals(text, "/take") {
                    let dchat = StChat.Get();
                    if IsDefined(dchat) {
                        ui.AddLine("--", dchat.DisarmActive()
                            ? "you take the weapon off them"
                            : "they have nothing in their hands", false);
                    }
                    ui.ClearTyped();
                    return;
                }
                let chat = StChat.Get();
                if IsDefined(chat) && !chat.IsBusy() {
                    ui.AddLine("V", text, true);
                    ui.ClearTyped();
                    chat.Send(text);
                }
            }
            return;
        }

        // ---- open, box not focused ----
        if ui.IsOpen() {
            if isPress && Equals(key, settings.ResetKeyCode()) {
                let chat = StChat.Get();
                if IsDefined(chat) {
                    chat.Reset();
                    ui.ClearLines();
                    ui.AddLine("--", "conversation reset", false);
                }
                return;
            }
            if isPress && Equals(key, settings.UndoKeyCode()) {
                let uchat = StChat.Get();
                if IsDefined(uchat) && uchat.UndoLast() {
                    // RE-RENDER FROM HISTORY, never edit the screen on its
                    // own. The transcript used to drop exactly one visible
                    // line while the undo removed a message AND whatever
                    // actions it caused - so the two drifted apart, and the
                    // screen went on showing an exchange the model no longer
                    // had. The player then judged the conversation by a
                    // transcript that was not the conversation (field report:
                    // "she was so down to kill him" - in a reply that had
                    // been undone).
                    ui.Replay(uchat.GetHistory());
                }
                return;
            }
            if isRelease && Equals(key, settings.OpenKeyCode()) {
                ui.Hide();
                return;
            }
            // Arrow keys scroll the conversation window. IK_Up / IK_Down are
            // the Dialog_Choice_Up/Down buttons (inputUserMappings.xml), which
            // do nothing meaningful while the dialogue hub is suppressed.
            if isPress && Equals(key, "IK_Up") {
                ui.Scroll(1);
                return;
            }
            if isPress && Equals(key, "IK_Down") {
                ui.Scroll(-1);
                return;
            }
            if isPress && Equals(key, "IK_Enter") {
                this.typing = true;
                ui.Refocus();
            }
            return;
        }

        // ---- closed: the talk key opens on whoever you are looking at ----
        if isRelease && Equals(key, settings.OpenKeyCode()) {
            this.TryOpen(ui, settings);
        }
    }

    private func TryOpen(ui: ref<StreetTalkUI>, settings: ref<StreetTalkSettings>) -> Void {
        let game: GameInstance = this.GetGameInstance();
        let npc: ref<NPCPuppet> = StTarget.LookAtNpc(game);
        if !IsDefined(npc) || npc.IsDead() || npc.IsEnemy() || npc.IsAggressive() {
            return;
        }
        let identity: ref<StIdentity> = StIdentityResolver.Resolve(npc);
        if !identity.valid {
            return;
        }
        if identity.isCrowd && !settings.allowCrowd {
            return;
        }
        if !identity.isCrowd && !settings.allowCommunity {
            return;
        }
        let memory = StMemory.Get();
        let chat = StChat.Get();
        if !IsDefined(memory) || !IsDefined(chat) {
            return;
        }

        // The game's own name for this NPC, resolved the way the SCANNER
        // resolves it (NPCPuppet.swift:3473-3497), because the scanner is the
        // thing that knows about story-progress name reveals:
        //
        //   HasAlternativeName() on the puppet's persistent state is the
        //   quest-driven flip - Garry showed as "Stranger" (his record's base
        //   name) even deep in a save where the scanner says "Garry the
        //   Prophet", because only the ALTERNATIVE name carries the reveal.
        //   Same mechanism covers Songbird and every other renamed character.
        //
        // Then the scanner's fallback order: civilians use DisplayName, named
        // characters prefer FullDisplayName, and the generated crowd name
        // from GetDisplayName() catches everyone else.
        // FULL names preferred, both branches - the scanner-dossier reading.
        // Deliberate: "So Mi" over "Songbird", "Gerald Winkler" over "Garry
        // the Prophet". The dossier name is the deeper cut - who they ARE,
        // not what the street calls them - and the discovery is half the fun
        // (owner's call, reversing an earlier short-name preference).
        let displayName: String = "";
        let charRec = TweakDBInterface.GetCharacterRecord(npc.GetRecordID());
        let pps = npc.GetPS();
        if IsDefined(charRec) && IsDefined(pps) && pps.HasAlternativeName() {
            if IsNameValid(charRec.AlternativeFullDisplayName()) {
                displayName = LocKeyToString(charRec.AlternativeFullDisplayName());
            } else {
                displayName = LocKeyToString(charRec.AlternativeDisplayName());
            }
        } else {
            if IsDefined(charRec) && !npc.IsCharacterCivilian() && IsNameValid(charRec.FullDisplayName()) {
                displayName = LocKeyToString(charRec.FullDisplayName());
            }
        }
        if StrLen(displayName) == 0 {
            displayName = npc.GetDisplayName();
        }
        // GetDisplayName / LocKeyToString can hand back an UNRESOLVED
        // localisation key - "LocKey#2914". Ink widgets resolve those when
        // rendering, which is why the header looked right while the raw key
        // went into the persona and Mama Welles introduced herself as
        // "LocKey". Resolve it the way the game does (captionParts.swift:20).
        if StrBeginsWith(displayName, "LocKey#") {
            displayName = GetLocalizedText(displayName);
        }

        // The NPC's actual voice bank, straight off their record. For named
        // characters it matches their name slug; for crowd NPCs it is the
        // archetype voice (civ_..., gang_...) their barks use - which means
        // even a random pedestrian can be cloned from their real voice actor.
        let voiceTag: String = "";
        let rec = TweakDBInterface.GetCharacterRecord(identity.recordId);
        if IsDefined(rec) {
            voiceTag = NameToString(rec.VoiceTag());
        }
        // Some records carry NO voice tag; CName none stringifies to the
        // LITERAL "None", which then flowed through resolution as a real
        // name (a male bartender got the female fallback voice this way).
        if Equals(voiceTag, "None") {
            voiceTag = "";
        }
        // The full ladder lives in StreetTalkGender.reds: persistent state,
        // then the character record's template->gender pairing, then the
        // template path's own wa/ma naming. (GetGender() alone came back
        // empty for crowd puppets - a female "NC Resident" spoke male.)
        let gender: String = StGender.Resolve(npc);

        let entry: ref<StMemoryEntry> = memory.NoteEncounter(identity);
        let persona: String = StPersona.Build(npc, identity, entry, memory.FamiliarityLine(entry), displayName, game);

        // Take the dialogue choices away while we have the screen.
        this.SuppressDialogs();

        chat.Begin(identity, persona, npc, displayName, voiceTag, gender,
                   entry, memory.FamiliarityLine(entry));
        ui.Show(StrLen(displayName) > 0 ? displayName : StPersona.ShortNameFor(identity.recordId));
        ui.Replay(chat.GetHistory());
        // Start forging/warming their voice NOW, not on the first reply -
        // with the footer saying so while it happens.
        chat.PrepVoice();
        this.typing = true;
        if StrLen(gender) == 0 {
            // Unresolvable even by template - log the path so the next
            // report of a wrong voice carries its own diagnosis.
            StLog(s"chat open: \(displayName) | voicetag=\(voiceTag) | gender=? tpl=\(ResRef.ToString(npc.GetTemplatePath()))");
        } else {
            StLog(s"chat open: \(displayName) | voicetag=\(voiceTag) | gender=\(gender)");
        }
    }

    // ------------------------------------------------------------------
    //  Action guard
    // ------------------------------------------------------------------
    private let actionGuard: ref<StreetTalkActionGuard>;

    public func RegisterGuard(player: ref<PlayerPuppet>) -> Void {
        this.actionGuard = new StreetTalkActionGuard();
        // One registration per action name - gameObject.swift:152, and every
        // registration in the game names its action. The names are what the
        // input contexts deliver for dialogue selection: ENTER and F both feed
        // the DialogConfirm mapping (inputUserMappings.xml:1195), which the
        // contexts hand to script as ChoiceApply (inputContexts.xml:128) and,
        // in one context, one_click_confirm (inputContexts.xml:1260). Choice1
        // and Choice2 are the world-prompt interactions, guarded so pressing
        // the talk key to close the chat does not also fire an interaction.
        player.RegisterInputListener(this.actionGuard, n"ChoiceApply");
        player.RegisterInputListener(this.actionGuard, n"one_click_confirm");
        player.RegisterInputListener(this.actionGuard, n"DialogConfirm");
        player.RegisterInputListener(this.actionGuard, n"Choice1");
        player.RegisterInputListener(this.actionGuard, n"Choice2");
        StLog("action guard registered");
    }
}

// While the chat panel is open, consume the dialogue-select and interact
// actions so the scene system never receives them.
//
// HONESTY NOTE: whether ConsumeSingleAction stops the NATIVE scene handler is
// unproven - the shipped scripts never call it, so there is no precedent to
// read. The earlier "consumption cannot work" result is void though: that
// listener was registered without an action name, i.e. subscribed to nothing.
// This one is registered correctly and logs every action it sees, so the next
// session's log settles the question either way.
public class StreetTalkActionGuard {

    protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
        let ui = StreetTalkUI.Get();
        if !IsDefined(ui) || !ui.IsOpen() {
            return false;
        }
        let name: CName = ListenerAction.GetName(action);
        ListenerActionConsumer.ConsumeSingleAction(consumer);
        StLog(s"guard consumed \(NameToString(name))");
        return true;
    }
}

@wrapMethod(PlayerPuppet)
protected cb func OnGameAttached() -> Bool {
    let r = wrappedMethod();
    let sys = GameInstance.GetScriptableSystemsContainer(GetGameInstance())
        .Get(n"StreetTalk.StreetTalkInputSystem") as StreetTalkInputSystem;
    if IsDefined(sys) {
        sys.RegisterGuard(this);
    } else {
        StLog("OnGameAttached: input system NOT FOUND - guard never registered");
    }
    return r;
}
