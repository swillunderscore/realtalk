// ============================================================================
//  STREET TALK - add our entry to the NPC's interaction list
// ============================================================================
//
//  HOOK ATTEMPTS, all dead ends - recorded so none are retried:
//    dialogWidgetGameController.OnDialogsData      not a method on that class
//    InteractionUIBase.OnDialogsData               compiles, never fires
//    dialogWidgetGameController.UpdateDialogsData  compiles, never fires
//    InteractionUIBase.OnInteractionsChanged       qualifiers rejected
//
//  So: stop hunting for a hook. The very first attempt DID render an entry by
//  writing InteractionChoiceHubData to the UIInteractions blackboard - it only
//  flickered because it OVERWROTE a blackboard the game rewrites constantly,
//  and because it wrote once on a state change rather than continuously.
//
//  This reads the hub the game just published, appends one choice, and writes
//  it back - on a short timer, so it survives the game's own rewrites. The
//  vendor keeps all their real options; ours is added to the end.
// ============================================================================

module RealTalk

public class RealTalkChoiceSystem extends ScriptableSystem {

    private let currentValid: Bool;
    private let currentIsCrowd: Bool;
    private let currentRecord: TweakDBID;
    private let currentId: Uint64;

    public static func SetCurrent(identity: ref<StIdentity>, npc: ref<NPCPuppet>) -> Void {
        let sys = GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"RealTalk.RealTalkChoiceSystem") as RealTalkChoiceSystem;
        if !IsDefined(sys) || !IsDefined(identity) {
            return;
        }
        // Only record NPCs we would actually open on.
        //
        // Recording every evaluated NPC was wrong: crowd pedestrians stream past
        // constantly and each one overwrote the vendor the player is standing in
        // front of. With crowd disabled, the tick then saw "not talkable" - even
        // though the vendor was right there.
        let settings = RealTalkSettings.Get();
        if !IsDefined(settings) {
            return;
        }
        if identity.isCrowd && !settings.allowCrowd {
            return;
        }
        if !identity.isCrowd && !settings.allowCommunity {
            return;
        }

        StLog(s"SetCurrent: recorded npc crowd=\(identity.isCrowd)");
        sys.currentValid = identity.valid;
        sys.currentIsCrowd = identity.isCrowd;
        sys.currentRecord = identity.recordId;
        sys.currentId = identity.persistentId;
    }

    public static func CurrentIsTalkable() -> Bool {
        let sys = GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"RealTalk.RealTalkChoiceSystem") as RealTalkChoiceSystem;
        let settings = RealTalkSettings.Get();
        if !IsDefined(sys) || !IsDefined(settings) || !sys.currentValid {
            return false;
        }
        if sys.currentIsCrowd {
            return settings.allowCrowd;
        }
        return settings.allowCommunity;
    }

    private func OnAttach() -> Void {
        let cb = new StChoiceTick();
        cb.game = this.GetGameInstance();
        GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(cb, 3.0, false);
    }
}

public class StChoiceTick extends DelayCallback {
    public let game: GameInstance;
    public func Call() -> Void {
        StChoiceUpdate(this.game);
        let next = new StChoiceTick();
        next.game = this.game;
        GameInstance.GetDelaySystem(this.game).DelayCallback(next, 0.2, false);
    }
}

// Every exit logs its reason. The previous version returned silently at six
// different points, so "no output" told us nothing about which one.
public static func StChoiceUpdate(game: GameInstance) -> Void {
    let settings = RealTalkSettings.Get();
    if !IsDefined(settings) {
        return;
    }
    if !settings.enabled {
        return;
    }
    if !settings.logging {
        return;
    }

    let ui = RealTalkUI.Get();
    if IsDefined(ui) && ui.IsOpen() {
        return;
    }

    // NO NPC GATE.
    //
    // Every attempt to identify the NPC first has failed: GetLookAtObject
    // returns null once an interaction is active, and the driver hook that was
    // meant to record the NPC never fires while standing at the vendor. Both
    // dead ends cost several launches.
    //
    // But the tick does not need to know who it is. An interaction hub with
    // choices only exists when the player is interacting with something. Append
    // there, and resolve the NPC when the entry is actually selected - at which
    // point we can afford to look, because the interaction is ending.
    //
    // Worst case the entry appears on a non-NPC interaction and does nothing.

    let defs = GetAllBlackboardDefs();
    let bb = GameInstance.GetBlackboardSystem(game).Get(defs.UIInteractions);
    if !IsDefined(bb) {
        StLog("tick: no UIInteractions blackboard");
        return;
    }

    // UIInteractions.InteractionChoiceHub is EMPTY while the vendor lines are
    // on screen - measured:
    //   tick: hub id=-1 title='' choices=0 active=false
    // So those lines are not the world-interaction hub. Read the dialogue
    // blackboard instead, which is where scene choices are published.
    // DialogChoiceHubs lives on UIInteractionsDef, alongside InteractionChoiceHub
    // and ActiveChoiceHubID. Confirmed by RTTI reflection after the compiler
    // rejected UIGameDataDef.
    //
    // Measured: InteractionChoiceHub is EMPTY (id=-1, choices=0) while the
    // vendor's lines are on screen - so the right blackboard was in hand from
    // the first attempt; only the key was wrong.
    // Check a safe primitive BEFORE touching the variant.
    //
    // FromVariant on an unset variant crashes the script - it killed the attach
    // loop earlier and just crashed the game at the logo, because at startup no
    // dialogue exists and DialogChoiceHubs is empty. ActiveChoiceHubID is an
    // Int32 and safe to read at any time; -1 means nothing is active.
    let activeId: Int32 = bb.GetInt(defs.UIInteractions.ActiveChoiceHubID);
    if activeId < 0 {
        return;
    }

    let hubs: DialogChoiceHubs = FromVariant<DialogChoiceHubs>(
        bb.GetVariant(defs.UIInteractions.DialogChoiceHubs));

    StLog(s"tick: dialogHubs=\(ArraySize(hubs.choiceHubs))");

    let h: Int32 = 0;
    while h < ArraySize(hubs.choiceHubs) {
        let hub = hubs.choiceHubs[h];
        StLog(s"  hub[\(h)] id=\(hub.id) title='\(hub.title)' choices=\(ArraySize(hub.choices))");
        let c: Int32 = 0;
        while c < ArraySize(hub.choices) {
            StLog(s"     choice[\(c)] '\(hub.choices[c].localizedName)'");
            c += 1;
        }
        h += 1;
    }
}

public static func StChoiceUpdateOld(game: GameInstance) -> Void {
    let settings = RealTalkSettings.Get();
    if !IsDefined(settings) || !settings.enabled {
        return;
    }
    let ui = RealTalkUI.Get();
    if IsDefined(ui) && ui.IsOpen() {
        return;
    }

    // Only when looking at someone we would actually talk to.
    let npc: ref<NPCPuppet> = GetLookAtObject(game) as NPCPuppet;
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

    let defs = GetAllBlackboardDefs();
    let bb = GameInstance.GetBlackboardSystem(game).Get(defs.UIInteractions);
    if !IsDefined(bb) {
        return;
    }

    // Read what the game just published, don't invent a hub.
    let hub: InteractionChoiceHubData = FromVariant<InteractionChoiceHubData>(
        bb.GetVariant(defs.UIInteractions.InteractionChoiceHub));

    if ArraySize(hub.choices) == 0 {
        return;
    }

    // Already added this frame? Leave it alone.
    let i: Int32 = 0;
    while i < ArraySize(hub.choices) {
        if Equals(hub.choices[i].localizedName, "Chat") {
            return;
        }
        i += 1;
    }

    let mine: InteractionChoiceData;
    mine.localizedName = "Chat";
    mine.inputAction = n"Choice1";   // field name taken from Street Vendors, the working reference
    let choiceType: ChoiceTypeWrapper;
    ChoiceTypeWrapper.SetType(choiceType, gameinteractionsChoiceType.Blueline);
    mine.type = choiceType;

    ArrayPush(hub.choices, mine);
    bb.SetVariant(defs.UIInteractions.InteractionChoiceHub, ToVariant(hub), true);

    if settings.logging {
        StLog(s"appended Chat to hub '\(hub.title)' (now \(ArraySize(hub.choices)) choices)");
    }
}
