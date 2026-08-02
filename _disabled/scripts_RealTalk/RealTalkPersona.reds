// ============================================================================
//  STREET TALK - persona
// ============================================================================
//
//  Builds the system prompt for one NPC from what the game already knows plus
//  what we remember about them.
//
//  DESIGN: the model is never told the game's internals - no TweakDB IDs, no
//  entity hashes, no record names. It gets a person, in plain language. The
//  code does the translating. That keeps the prompt small (which matters, a 7B
//  follows short prompts far more reliably) and keeps engine detail out of the
//  fiction.
// ============================================================================

module RealTalk

public class StPersona {

    // Archetype -> a role the model can play. Extend this table rather than
    // making the model guess from a record name it cannot parse.
    public static func RoleFor(recordId: TweakDBID) -> String {
        if Equals(recordId, t"Character.hey_gle_gunsmith_01") {
            return "a gun vendor working a cramped weapons stall";
        }
        if Equals(recordId, t"Character.sts_ep1_10_bill_hotdog_vendor") {
            return "a street food vendor running a hot dog stand";
        }
        return "someone working a stall on the street";
    }

    // Short label for the UI header. Deliberately a role, not a name - the game
    // generates NPC names randomly at spawn, so a name would be meaningless and
    // would change between sessions even for the same person.
    public static func ShortNameFor(recordId: TweakDBID) -> String {
        if Equals(recordId, t"Character.hey_gle_gunsmith_01") {
            return "GUN VENDOR";
        }
        if Equals(recordId, t"Character.sts_ep1_10_bill_hotdog_vendor") {
            return "FOOD VENDOR";
        }
        return "STRANGER";
    }

    public static func Build(identity: ref<StIdentity>, memory: ref<StMemoryEntry>, familiarity: String) -> String {
        let cfg = RealTalkConfig.Get();

        let who: String = StPersona.RoleFor(identity.recordId);

        // No gender field: GetGender() does not return gamedataGender in this
        // build (the compiler flagged it as comparing unrelated types), and it
        // is not worth another round trip to resolve. The model infers it from
        // the voice and appearance the player is looking at.
        let p: String =
            s"You are a person in Night City, \(who). You are talking face to face with V, a mercenary."
            + " Speak only your own dialogue, in first person. Never narrate actions, never use asterisks."
            + " Keep replies short - one to three sentences, the way people actually talk."
            + s" \(familiarity)";

        if IsDefined(memory) && StrLen(memory.gist) > 0 {
            // The gist, not a transcript. This is what survives - see the
            // memory model note in RealTalkMemory.reds.
            p += s" What you remember about V: \(memory.gist)";
        }

        if IsDefined(cfg) && StrLen(cfg.extraSystemPrompt) > 0 {
            p += " " + cfg.extraSystemPrompt;
        }

        return p;
    }
}
