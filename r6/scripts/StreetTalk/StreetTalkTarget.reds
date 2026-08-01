// ============================================================================
//  STREET TALK - who is the player looking at?
// ============================================================================
//
//  OUR OWN acquisition. Two discoveries forced this file:
//
//  1. The global GetLookAtObject(game) this mod called since its first day
//     belongs to the STREET VENDORS mod (street_vendors.reds:130) - an
//     accidental hard dependency that would have broken every Nexus user
//     without it, discovered only when grepping for why crowds don't work.
//
//  2. Crowd NPCs never appeared because that helper calls
//     GetLookAtObject(player, false, false): the registered-targets path,
//     which anchored NPCs join and lightweight crowd puppets do not. AMM -
//     which demonstrably targets crowd walkers - uses the withLOS variant
//     first and falls back: (player, true, false) or (player, false, false).
//     That exact chain, copied.
// ============================================================================

module StreetTalk

public class StTarget {

    public static func LookAtNpc(game: GameInstance) -> ref<NPCPuppet> {
        let player = GetPlayer(game);
        if !IsDefined(player) {
            return null;
        }
        let ts = GameInstance.GetTargetingSystem(game);
        if !IsDefined(ts) {
            return null;
        }
        let obj = ts.GetLookAtObject(player, true, false);
        if !IsDefined(obj) {
            obj = ts.GetLookAtObject(player, false, false);
        }
        let npc = obj as NPCPuppet;
        if !IsDefined(npc) {
            return null;
        }
        // GetLookAtObject is the AIM target - it reaches across the street.
        // Talking is a face-to-face thing: same ballpark as the game's own
        // world interactions, slightly generous.
        if Vector4.Distance(player.GetWorldPosition(), npc.GetWorldPosition()) > 4.5 {
            return null;
        }
        return npc;
    }

    // WHO V IS POINTING AT - the same look-at without the conversational
    // range clamp. Talking happens at arm's length; shooting does not, and
    // borrowing the talk helper for it meant an order to shoot found "nobody
    // in your crosshair" unless the target was close enough to chat with
    // (field report: she said "Got him" and stood there).
    // NOT JUST PEOPLE. A drone, a mech and a turret all wear the same chevron
    // and all shoot back, but the NPCPuppet cast quietly refused every one of
    // them - an order to shoot a robot came back "nobody in your crosshair"
    // (field report). A puppet or a sensor is a valid combat target as far as
    // the game is concerned (aiActionHelper.swift:194), so that is the test.
    public static func AimObject(game: GameInstance) -> ref<GameObject> {
        let player = GetPlayer(game);
        if !IsDefined(player) {
            return null;
        }
        let ts = GameInstance.GetTargetingSystem(game);
        if !IsDefined(ts) {
            return null;
        }
        let obj = ts.GetLookAtObject(player, true, false);
        if !IsDefined(obj) {
            obj = ts.GetLookAtObject(player, false, false);
        }
        if !IsDefined(obj) || !(obj.IsPuppet() || obj.IsSensor()) {
            return null;
        }
        if Vector4.Distance(player.GetWorldPosition(), obj.GetWorldPosition()) > 60.0 {
            return null;
        }
        return obj;
    }

    public static func AimNpc(game: GameInstance) -> ref<NPCPuppet> {
        let player = GetPlayer(game);
        if !IsDefined(player) {
            return null;
        }
        let ts = GameInstance.GetTargetingSystem(game);
        if !IsDefined(ts) {
            return null;
        }
        let obj = ts.GetLookAtObject(player, true, false);
        if !IsDefined(obj) {
            obj = ts.GetLookAtObject(player, false, false);
        }
        let npc = obj as NPCPuppet;
        if !IsDefined(npc) {
            return null;
        }
        // Generous, but not the whole district: past this it is scenery.
        if Vector4.Distance(player.GetWorldPosition(), npc.GetWorldPosition()) > 60.0 {
            return null;
        }
        return npc;
    }
}
