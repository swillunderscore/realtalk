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

    // WHAT V IS PHYSICALLY DOING, as a stage direction.
    //
    // The NPC has never had any idea. Measured on dpe-7b: told nothing, a
    // character acknowledged that V was crouched behind cover aiming a rifle
    // at someone in 2 of 32 replies. Given this beat on V's own line, 30 of
    // 32 - and unlike putting it in the card (20 of 32), it costs nothing in
    // format compliance.
    //
    // Only things the game states plainly: stance, what is in V's hands, who
    // V is pointing it at, and whether V is sitting in a car. No inference.
    public static func PlayerBeat(game: GameInstance) -> String {
        let player = GetPlayer(game);
        if !IsDefined(player) {
            return "";
        }
        let bits: String = "";

        // In a vehicle beats everything else - you are not crouching in a car.
        let car = GetMountedVehicle(player);
        if IsDefined(car) {
            return "sitting in the car with them";
        }

        let bb = GameInstance.GetBlackboardSystem(game)
            .Get(GetAllBlackboardDefs().PlayerStateMachine);
        if IsDefined(bb) {
            let loco: Int32 = bb.GetInt(GetAllBlackboardDefs().PlayerStateMachine.Locomotion);
            if loco == EnumInt(gamePSMLocomotionStates.Crouch)
                || loco == EnumInt(gamePSMLocomotionStates.CrouchSprint)
                || loco == EnumInt(gamePSMLocomotionStates.CrouchDodge) {
                bits = "crouched";
            } else {
                if loco == EnumInt(gamePSMLocomotionStates.Sprint) {
                    bits = "out of breath from running";
                }
            }
        }

        // What is actually in V's hands, and who it is pointed at.
        let ts = GameInstance.GetTransactionSystem(game);
        let weapon: String = "";
        if IsDefined(ts) {
            let item = ts.GetItemInSlot(player, t"AttachmentSlots.WeaponRight");
            if !IsDefined(item) {
                item = ts.GetItemInSlot(player, t"AttachmentSlots.WeaponLeft");
            }
            if IsDefined(item) {
                // Same route the mod already uses to name an NPC's weapon.
                let rec = TweakDBInterface.GetItemRecord(
                    ItemID.GetTDBID(item.GetItemID()));
                if IsDefined(rec) {
                    weapon = LocKeyToString(rec.DisplayName());
                    if StrBeginsWith(weapon, "LocKey#") {
                        weapon = GetLocalizedText(weapon);
                    }
                }
            }
        }
        if StrLen(weapon) > 0 {
            let at = StTarget.AimObject(game);
            if IsDefined(at) && !at.IsDead() {
                let who: String = at.GetDisplayName();
                if StrBeginsWith(who, "LocKey#") {
                    who = GetLocalizedText(who);
                }
                bits += StrLen(bits) > 0 ? ", " : "";
                bits += s"pointing a \(weapon) at \(who)";
            } else {
                bits += StrLen(bits) > 0 ? ", " : "";
                bits += s"holding a \(weapon)";
            }
        }
        return bits;
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
