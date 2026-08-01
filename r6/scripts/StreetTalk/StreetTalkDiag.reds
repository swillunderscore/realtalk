// ============================================================================
//  STREET TALK - what the AI itself says
// ============================================================================
//
//  This file adds NO behaviour. It reads state back out of the game and writes
//  it to the log, and it exists because three separate explanations for "she
//  draws her rifle, aims, and never fires" were each shipped as a fix and each
//  disproved by the next log. Guessing was the problem; this is the
//  alternative.
//
//  Everything here is read from where the combat AI itself reads it:
//
//    IsAggressive + the IsAggressive STAT   the gate in
//                                           tweakAIConditionChecks.swift:1772
//    IsFriendlyFiring()                     aiComponent.swift:548 - the AI's own
//                                           answer to "would shooting hit a
//                                           friend"
//    desiredNumberOfShots / totalShotsFired the shooting blackboard
//                                           (AIShootingDataDef). The decisive
//                                           pair: it separates "she has decided
//                                           not to shoot" from "she is trying
//                                           and something stops the bullet"
//    CombatTarget / CommandCombatTarget     the behaviour arguments the shoot
//                                           task validates against
//    hostile threats                        the target tracker's own list
//
//  Nothing here changes a value. If a probe line and a claim of mine ever
//  disagree, the probe is right.
// ============================================================================

module StreetTalk

public class StProbe {

    // Called on a timer after an attack order - everything on one line, so a
    // sequence of them reads as a story.
    public static func Report(npc: ref<NPCPuppet>, target: ref<GameObject>, at: Float) -> Void {
        if !IsDefined(npc) {
            return;
        }
        let game = npc.GetGame();
        let stats = GameInstance.GetStatsSystem(game);
        let aggStat: Float = IsDefined(stats)
            ? stats.GetStatValue(Cast<StatsObjectID>(npc.GetEntityID()),
                                 gamedataStatType.IsAggressive)
            : -1.0;

        let aic = npc.GetAIControllerComponent();
        let friendlyFiring: String = "?";
        let combatArg: String = "none";
        let cmdArg: String = "none";
        let wants: Int32 = -1;
        let fired: Int32 = -1;
        if IsDefined(aic) {
            friendlyFiring = s"\(aic.IsFriendlyFiring())";
            let ct = FromVariant<ref<GameObject>>(aic.GetBehaviorArgument(n"CombatTarget"));
            if IsDefined(ct) {
                combatArg = StActions.ReadableObj(ct);
            }
            let cct = FromVariant<ref<GameObject>>(aic.GetBehaviorArgument(n"CommandCombatTarget"));
            if IsDefined(cct) {
                cmdArg = StActions.ReadableObj(cct);
            }
            // THE DECIDING NUMBERS. An AI that wants zero shots has decided
            // not to shoot. An AI that wants shots and has fired none is being
            // stopped somewhere else entirely, and those are different bugs.
            let sbb = aic.GetShootingBlackboard();
            if IsDefined(sbb) {
                wants = sbb.GetInt(GetAllBlackboardDefs().AIShooting.desiredNumberOfShots);
                fired = sbb.GetInt(GetAllBlackboardDefs().AIShooting.totalShotsFired);
            }
        }

        let tracker = npc.GetTargetTrackerComponent();
        let hostiles: Int32 = -1;
        let targetIsThreat: String = "?";
        if IsDefined(tracker) {
            hostiles = ArraySize(tracker.GetHostileThreats(false));
            if IsDefined(target) {
                let found: TrackedLocation;
                targetIsThreat = s"\(tracker.ThreatFromEntity(target, found))";
            }
        }

        let attitude: String = "?";
        let back: String = "?";
        if IsDefined(target) {
            let mine = npc.GetAttitudeAgent();
            let theirs = target.GetAttitudeAgent();
            if IsDefined(mine) && IsDefined(theirs) {
                attitude = Equals(mine.GetAttitudeTowards(theirs), EAIAttitude.AIA_Hostile)
                    ? "hostile" : "not hostile";
                back = Equals(theirs.GetAttitudeTowards(mine), EAIAttitude.AIA_Hostile)
                    ? "hostile" : "not hostile";
            }
        }

        let dist: Float = IsDefined(target)
            ? Vector4.Distance(npc.GetWorldPosition(), target.GetWorldPosition()) : -1.0;

        // WHICH BRANCH OF IsAggressive IS FAILING. It is script, not native
        // (scriptedPuppet.swift:1578), and it answers true for any of: the
        // FistFight restriction, an aggressive reaction preset, being in the
        // reaction system's aggressive register, or being hostile to V. The
        // last one we do not want. This says which of the others is live.
        let rs = GameInstance.GetReactionSystem(game);
        let registered: String = IsDefined(rs)
            ? s"\(rs.IsRegisteredAsAggressive(npc.GetEntityID()))" : "?";
        let presetAgg: String = "?";
        let reaction = npc.GetStimReactionComponent();
        if IsDefined(reaction) && IsDefined(reaction.GetReactionPreset()) {
            presetAgg = s"\(reaction.GetReactionPreset().IsAggressive())";
        }
        // ...and what the tracker thinks the threat is WORTH. hostileThreats=0
        // alongside targetIsThreat=true says the entry exists but does not
        // count as hostile, and these are the numbers behind that.
        let threatVal: Float = -1.0;
        let threatVisible: String = "?";
        if IsDefined(tracker) && IsDefined(target) {
            let tl: TrackedLocation;
            if tracker.ThreatFromEntity(target, tl) {
                threatVal = tl.threat;
                threatVisible = s"\(tl.visible)";
            }
        }

        StLog(s"probe +\(at)s \(StActions.Readable(npc)): state=\(StProbe.StateName(npc))"
            + s" aggressive=\(npc.IsAggressive()) aggStat=\(aggStat)"
            + s" friendlyFiring=\(friendlyFiring)"
            + s" wantsShots=\(wants) shotsFired=\(fired)"
            + s" CombatTarget=\(combatArg) CommandCombatTarget=\(cmdArg)"
            + s" hostileThreats=\(hostiles) targetIsThreat=\(targetIsThreat)"
            + s" attitude=\(attitude) back=\(back) dist=\(dist)"
            + s" registeredAggressive=\(registered) presetAggressive=\(presetAgg)"
            + s" threatValue=\(threatVal) threatVisible=\(threatVisible)");
    }

    public static func StateName(npc: ref<NPCPuppet>) -> String {
        let st = npc.GetHighLevelStateFromBlackboard();
        if Equals(st, gamedataNPCHighLevelState.Combat) {
            return "combat";
        }
        if Equals(st, gamedataNPCHighLevelState.Alerted) {
            return "alerted";
        }
        if Equals(st, gamedataNPCHighLevelState.Relaxed) {
            return "relaxed";
        }
        if Equals(st, gamedataNPCHighLevelState.Stealth) {
            return "stealth";
        }
        return "other";
    }

    // Only the person this mod just gave an order to. Every NPC in the district
    // runs these same code paths, and a log that reports all of them reports
    // nothing.
    public static func Watching(puppet: ref<ScriptedPuppet>) -> Bool {
        let npc = puppet as NPCPuppet;
        if !IsDefined(npc) {
            return false;
        }
        let chat = StChat.Get();
        return IsDefined(chat) && chat.IsUnderOrders(npc);
    }
}

public class StProbeTick extends DelayCallback {
    public let npc: wref<NPCPuppet>;
    public let target: wref<GameObject>;
    public let at: Float;
    public func Call() -> Void {
        StProbe.Report(this.npc, this.target, this.at);
    }
}

// ---------------------------------------------------------------------------
//  THE GAME'S OWN VERDICTS. These two are the gates a shoot order passes
//  through (aiActionHelper.swift:190 and :226). They are plain script, so they
//  can be watched without being changed. If neither ever logs a line, her
//  behaviour tree never asked to shoot at all - which is itself the answer, and
//  not one any amount of attitude-setting would have revealed.
// ---------------------------------------------------------------------------
@wrapMethod(AIActionHelper)
public final static func TryChangingAttitudeToHostile(owner: ref<ScriptedPuppet>, target: ref<GameObject>) -> Bool {
    let ok = wrappedMethod(owner, target);
    if StProbe.Watching(owner) {
        StLog(s"ai: TryChangingAttitudeToHostile(\(StActions.ReadableObj(target))) = \(ok)");
    }
    return ok;
}

@wrapMethod(AIActionHelper)
public final static func IsCommandCombatTargetValid(context: ScriptExecutionContext, commandName: CName) -> Bool {
    let ok = wrappedMethod(context, commandName);
    if StProbe.Watching(ScriptExecutionContext.GetOwner(context) as ScriptedPuppet) {
        StLog(s"ai: IsCommandCombatTargetValid(\(NameToString(commandName))) = \(ok)");
    }
    return ok;
}

@wrapMethod(AIActionHelper)
public final static func SetCommandCombatTarget(context: ScriptExecutionContext, target: wref<GameObject>, isPersistant: Bool, persistenceSource: Uint32) -> Bool {
    let ok = wrappedMethod(context, target, isPersistant, persistenceSource);
    if StProbe.Watching(ScriptExecutionContext.GetOwner(context) as ScriptedPuppet) {
        StLog(s"ai: SetCommandCombatTarget(\(StActions.ReadableObj(target))) = \(ok)");
    }
    return ok;
}


// ---------------------------------------------------------------------------
//  DID THE TURN STICK? The turn itself runs - the log says "turning to face
//  the player, -61.6 degrees" - and she is still not facing V. So the question
//  is not whether we turned her but whether something turns her back, and only
//  a reading a second later can answer it.
// ---------------------------------------------------------------------------
public class StFaceProbe extends DelayCallback {
    public let npc: wref<NPCPuppet>;
    public let at: Float;
    public func Call() -> Void {
        if !IsDefined(this.npc) {
            return;
        }
        let player = GetPlayer(this.npc.GetGame());
        if !IsDefined(player) {
            return;
        }
        // RAW NUMBERS. want=0 and have=0 in every line so far, which is not a
        // facing that happens to be zero - it is two reads coming back empty.
        // These say which one, and whether re-fetching the entity by id gives
        // a different answer than the weak reference does.
        let pp: Vector4 = player.GetWorldPosition();
        let np: Vector4 = this.npc.GetWorldPosition();
        let fresh = GameInstance.FindEntityByID(this.npc.GetGame(),
                                                this.npc.GetEntityID()) as NPCPuppet;
        let fp: Vector4 = IsDefined(fresh) ? fresh.GetWorldPosition() : new Vector4(0.0, 0.0, 0.0, 0.0);
        StLog(s"face raw: player=(\(pp.X), \(pp.Y)) npc=(\(np.X), \(np.Y))"
            + s" refetched=(\(fp.X), \(fp.Y)) attached=\(this.npc.IsAttached())"
            + s" quat=(\(this.npc.GetWorldOrientation().i), \(this.npc.GetWorldOrientation().k),"
            + s" \(this.npc.GetWorldOrientation().r))");

        let dir: Vector4 = pp - np;
        dir.Z = 0.0;
        // ALL THREE COMPONENTS of each. If the positions are real and Yaw is
        // still zero, then the heading simply is not in the field I have been
        // reading, and every facing calculation in this mod has been comparing
        // two zeroes.
        let wantE: EulerAngles = Vector4.ToRotation(dir);
        let haveE: EulerAngles = Quaternion.ToEulerAngles(this.npc.GetWorldOrientation());
        StLog(s"face euler: dir=(\(dir.X), \(dir.Y)) toRotation=(pitch \(wantE.Pitch),"
            + s" yaw \(wantE.Yaw), roll \(wantE.Roll)) npcEuler=(pitch \(haveE.Pitch),"
            + s" yaw \(haveE.Yaw), roll \(haveE.Roll))");
        let want: Float = wantE.Yaw;
        let have: Float = haveE.Yaw;
        let off: Float = want - have;
        while off > 180.0 {
            off -= 360.0;
        }
        while off < -180.0 {
            off += 360.0;
        }
        StLog(s"face +\(this.at)s \(StActions.Readable(this.npc)): want=\(want) have=\(have) off=\(off)");
    }
}
