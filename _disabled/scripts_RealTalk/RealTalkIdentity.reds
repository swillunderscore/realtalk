// ============================================================================
//  STREET TALK - identity and persona seed
// ============================================================================
//
//  ESTABLISHED BY MEASUREMENT (2026-07-27), not assumption:
//
//    - IsCrowd() cleanly separates pooled pedestrians from anchored NPCs.
//      62+ samples, no misclassification observed.
//
//    - GetPersistentID() is STABLE ACROSS GAME RESTARTS for community NPCs.
//      One NPC (entityHash 9006113) was observed at 17:20 and 17:21, the game
//      was relaunched twice (four redscript recompiles in the window), and it
//      returned with the identical ID at 17:30. Crowd NPCs beside it churned
//      through fresh IDs the whole time.
//
//    - The two ID ranges do not overlap: community ~9.0M, crowd ~10.1M.
//      Consistent with community entities coming from persisted save data and
//      crowd entities from a runtime pool. Suggestive; the restart test above
//      is the actual proof.
//
//  CONSEQUENCE: community NPCs can be remembered permanently, keyed on their
//  persistent ID. Crowd NPCs cannot, ever - not a limitation we can engineer
//  around, it is how the engine spawns crowds.
// ============================================================================

module RealTalk

// What we know about an NPC before a single word is exchanged. This is the
// seed a persona gets generated from, and the key memory is stored under.
public class StIdentity extends IScriptable {
    // EntityID.ToHash(), not GetPersistentID().
    //
    // GetPersistentID() returns a PersistentID struct that will not coerce to a
    // number, and there are no accessors on it reachable from redscript. But
    // the measurements showed the persistent ID's entityHash and the EntityID
    // are THE SAME VALUE (both printed 9006113 for the NPC that survived two
    // restarts), so hashing the EntityID gives the same stable key in a type we
    // can compare and serialise.
    public let persistentId: Uint64;      // stable for community NPCs
    public let recordId: TweakDBID;       // archetype: gunsmith, vendor, fixer...
    public let isCrowd: Bool;             // false = rememberable
    public let valid: Bool;

    // A community NPC is one the engine anchors to a place. Those are the only
    // ones worth generating a persona for, because they're the only ones the
    // player can deliberately go back to.
    public func IsRememberable() -> Bool {
        return this.valid && !this.isCrowd;
    }
}

public class StIdentityResolver {

    public static func Resolve(npc: ref<NPCPuppet>) -> ref<StIdentity> {
        let id: ref<StIdentity> = new StIdentity();
        id.valid = false;

        if !IsDefined(npc) || npc.IsDead() {
            return id;
        }

        let tdbid: TweakDBID = GameObject.GetTDBID(npc);

        // V's preview puppets masquerade as community NPCs - see RealTalkProbe
        // for why IsPlayer() is not sufficient here.
        if Equals(tdbid, t"Character.Player_Puppet_Menu")
            || Equals(tdbid, t"Character.Player_Puppet_Inventory")
            || Equals(tdbid, t"Character.Player_Puppet_Default") {
            return id;
        }

        id.persistentId = EntityID.ToHash(npc.GetEntityID());
        id.recordId = tdbid;
        id.isCrowd = npc.IsCrowd();
        id.valid = true;
        return id;
    }
}
