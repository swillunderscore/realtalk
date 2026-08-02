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

import RedFileSystem.*
import RedData.Json.*

public class StPersona {

    // Real lines this character speaks in the game, cached by the voice
    // service into the mod's own storage directory as examples_<slug>.json.
    public static func ExampleLines(displayName: String) -> String {
        let fs = RealTalkFS.Get();
        if !IsDefined(fs) || StrLen(displayName) == 0 {
            return "";
        }
        let storage = fs.Storage();
        if !IsDefined(storage) {
            return "";
        }
        let name: String = s"examples_\(StPersona.Slug(displayName)).json";
        if NotEquals(storage.Exists(name), FileSystemStatus.True) {
            return "";
        }
        let file = storage.GetFile(name);
        if !IsDefined(file) {
            return "";
        }
        let json = file.ReadAsJson();
        if !IsDefined(json) || json.IsUndefined() {
            return "";
        }
        let root = json as JsonObject;
        if !IsDefined(root) {
            return "";
        }
        let arr = root.GetKey("lines") as JsonArray;
        if !IsDefined(arr) {
            return "";
        }
        let out: String = "";
        let i: Uint32 = 0u;
        while i < arr.GetSize() && i < 8u {
            // JsonVariant.GetString(), not a JsonString class - that type
            // does not exist in RedData (RedData.Json.reds:73).
            let v = arr.GetItem(i);
            if IsDefined(v) && v.IsString() {
                out += s" \"\(v.GetString())\"";
            }
            i += 1u;
        }
        return out;
    }

    // What the GAME's own text says about this person - shards, emails,
    // messages, briefings - harvested by the voice service into
    // bio_<slug>.json. Story context used to be three hand-written characters
    // and nothing for everyone else; this covers anyone the game bothered to
    // mention, which is most named characters.
    public static func BioLines(displayName: String) -> String {
        let fs = RealTalkFS.Get();
        if !IsDefined(fs) || StrLen(displayName) == 0 {
            return "";
        }
        let storage = fs.Storage();
        if !IsDefined(storage) {
            return "";
        }
        let name: String = s"bio_\(StPersona.Slug(displayName)).json";
        if NotEquals(storage.Exists(name), FileSystemStatus.True) {
            return "";
        }
        let file = storage.GetFile(name);
        if !IsDefined(file) {
            return "";
        }
        let json = file.ReadAsJson();
        if !IsDefined(json) || json.IsUndefined() {
            return "";
        }
        let root = json as JsonObject;
        if !IsDefined(root) {
            return "";
        }
        let arr = root.GetKey("lines") as JsonArray;
        if !IsDefined(arr) {
            return "";
        }
        let out: String = "";
        let i: Uint32 = 0u;
        while i < arr.GetSize() && i < 3u {
            let v = arr.GetItem(i);
            if IsDefined(v) && v.IsString() {
                out += s" \(v.GetString())";
            }
            i += 1u;
        }
        return out;
    }

    // The quest ids this character actually speaks in, cached next to their
    // dialogue examples by the voice service - derived from their own voice
    // files, so it covers every voiced character in the game without anyone
    // maintaining a list.
    public static func QuestIds(displayName: String) -> array<String> {
        let out: array<String>;
        let fs = RealTalkFS.Get();
        if !IsDefined(fs) || StrLen(displayName) == 0 {
            return out;
        }
        let storage = fs.Storage();
        if !IsDefined(storage) {
            return out;
        }
        let name: String = s"examples_\(StPersona.Slug(displayName)).json";
        if NotEquals(storage.Exists(name), FileSystemStatus.True) {
            return out;
        }
        let file = storage.GetFile(name);
        if !IsDefined(file) {
            return out;
        }
        let json = file.ReadAsJson();
        if !IsDefined(json) || json.IsUndefined() {
            return out;
        }
        let root = json as JsonObject;
        if !IsDefined(root) {
            return out;
        }
        let arr = root.GetKey("quests") as JsonArray;
        if !IsDefined(arr) {
            return out;
        }
        let i: Uint32 = 0u;
        while i < arr.GetSize() && i < 40u {
            let v = arr.GetItem(i);
            if IsDefined(v) && v.IsString() {
                ArrayPush(out, v.GetString());
            }
            i += 1u;
        }
        return out;
    }

    // Must match voice_forge.slugify: lowercase, non-alphanumeric runs to
    // single underscores.
    public static func Slug(name: String) -> String {
        let lower: String = StrLower(name);
        let out: String = "";
        let i: Int32 = 0;
        let lastUnderscore: Bool = true;
        while i < StrLen(lower) {
            let ch: String = StrMid(lower, i, 1);
            let isAlnum: Bool = (Equals(ch, "0") || StrFindFirst("123456789", ch) != -1
                || StrFindFirst("abcdefghijklmnopqrstuvwxyz", ch) != -1);
            if isAlnum {
                out += ch;
                lastUnderscore = false;
            } else {
                if !lastUnderscore {
                    out += "_";
                    lastUnderscore = true;
                }
            }
            i += 1;
        }
        if StrLen(out) > 0 && Equals(StrMid(out, StrLen(out) - 1, 1), "_") {
            out = StrLeft(out, StrLen(out) - 1);
        }
        return out;
    }

    // Specific roles for records we know. Returns "" when we don't - the card
    // built from live game data covers everyone else, which is exactly what
    // the old fallback ("someone working a stall on the street") failed to do:
    // it told Mama Welles she runs a stall, and left so little substance the
    // model invented the rest.
    public static func RoleFor(recordId: TweakDBID) -> String {
        if Equals(recordId, t"Character.hey_gle_gunsmith_01") {
            return "a gun vendor working a cramped weapons stall";
        }
        if Equals(recordId, t"Character.sts_ep1_10_bill_hotdog_vendor") {
            return "a street food vendor running a hot dog stand";
        }
        return "";
    }

    // Fallback label for the UI header, used only when GetDisplayName() comes
    // back empty. (This used to be the ONLY source of the header, mapping two
    // hardcoded vendors and labelling everyone else STRANGER - which read as
    // names never populating.)
    public static func ShortNameFor(recordId: TweakDBID) -> String {
        if Equals(recordId, t"Character.hey_gle_gunsmith_01") {
            return "GUN VENDOR";
        }
        if Equals(recordId, t"Character.sts_ep1_10_bill_hotdog_vendor") {
            return "FOOD VENDOR";
        }
        return "STRANGER";
    }

    // The character card: everything the game will actually tell us about the
    // person standing there, in plain language. Every fact below comes from a
    // verified API - none of it is invented:
    //   name       GameObject.GetDisplayName()            (gameObject.swift:314)
    //   kind       IsCharacterCivilian/Ganger/Children    (scriptedPuppet.swift:1394+)
    //   faction    NPCPuppet.GetAffiliation()             (NPCPuppet.swift:698)
    //   district   PreventionSystem.GetCurrentDistrict()  (districtPrereq.swift:12)
    //   time       GameTime.Hours(GetGameTime())          (vehicleComponent.swift:4217)
    //   attitude   GameObject.GetAttitudeTowards()        (senseComponent.swift:789)
    //
    // Gender is deliberately absent: Character_Record holds a LIST of gender
    // entities (one per appearance entity), not one fact. The model infers it.
    // Affiliations are enum names: "TheMox", "ValentinosGang". Printed raw
    // after a hard-coded article they came out as "runs with the TheMox" -
    // small models copy what they are shown, including the stammer.
    public static func FactionName(faction: String) -> String {
        let spaced: String = "";
        let i: Int32 = 0;
        while i < StrLen(faction) {
            let ch: String = StrMid(faction, i, 1);
            if i > 0 && Equals(ch, StrUpper(ch)) && NotEquals(ch, StrLower(ch)) {
                spaced += " ";
            }
            spaced += ch;
            i += 1;
        }
        // "The Mox" already has its article; anything else takes one.
        return StrBeginsWith(StrLower(spaced), "the ") ? spaced : "the " + spaced;
    }

    public static func Build(npc: ref<NPCPuppet>, identity: ref<StIdentity>, memory: ref<StMemoryEntry>, familiarity: String, displayName: String, game: GameInstance) -> String {
        let cfg = RealTalkConfig.Get();

        // ---- who they are ----
        // Empty, not "someone". An unresolved kind used to put "Judy Alvarez
        // is someone in Night City" at the very top of the card - the first
        // thing a small model reads, saying nothing, in the position that
        // matters most.
        let kind: String = "";
        if npc.IsCharacterChildren() {
            kind = "a kid";
        } else {
            if npc.IsCharacterCivilian() {
                kind = "a civilian";
            } else {
                if npc.IsCharacterGanger() {
                    kind = "a gang member";
                }
            }
        }

        // EnumName string, e.g. "Valentinos". "Unknown" when the record has
        // no affiliation set.
        let faction: String = npc.GetAffiliation();
        // "Civilian" is not an affiliation, it is the absence of one - and
        // "You are affiliated with Civilian" is exactly the kind of line that
        // makes a card read like a form. Same for the empty values.
        let hasFaction: Bool = StrLen(faction) > 0
            && NotEquals(faction, "Unknown")
            && NotEquals(faction, "Unaffiliated")
            && NotEquals(faction, "Civilian")
            && NotEquals(faction, "None");

        // ---- where and when ----
        let district: String = "Night City";
        let ps = GameInstance.GetScriptableSystemsContainer(game)
            .Get(n"PreventionSystem") as PreventionSystem;
        if IsDefined(ps) {
            let d = ps.GetCurrentDistrict();
            if IsDefined(d) {
                let rec = d.GetDistrictRecord();
                if IsDefined(rec) {
                    let dn: String = rec.LocalizedName();
                    if StrBeginsWith(dn, "LocKey#") {
                        dn = GetLocalizedText(dn);
                    }
                    if StrLen(dn) > 0 {
                        district = dn;
                    }
                }
            }
        }
        let hour: Int32 = GameTime.Hours(GameInstance.GetTimeSystem(game).GetGameTime());

        // ---- assemble ----
        // THIRD PERSON, and quiet. Small models take a description far better
        // than a briefing: "Panam is blunt when angry" is read as character,
        // while "You ARE blunt - do NOT be polite" is read as an argument to
        // win. Capitals and imperatives in a card come back as capitals and
        // imperatives in the dialogue, so there are none here.
        let who: String = StrLen(displayName) > 0 ? displayName : "This person";
        let opening: String = "";
        if StrLen(kind) > 0 {
            opening = s"\(who) is \(kind) in Night City";
            opening += hasFaction
                ? s", running with \(StPersona.FactionName(faction))." : ".";
        } else {
            opening = hasFaction
                ? s"\(who) runs with \(StPersona.FactionName(faction))."
                : s"\(who) is in Night City.";
        }
        let role: String = StPersona.RoleFor(identity.recordId);
        if StrLen(role) > 0 {
            opening += s" \(who) is \(role).";
        }
        opening += s" The place is \(district), around \(hour):00.";

        // Crowd NPCs have no story - but their APPEARANCE name is written
        // by the game's artists and is honestly descriptive
        // (GetCurrentAppearanceName, entity.swift:38). Tokens like
        // "kabuki_food_vendor_fat_old" give the model a person to be.
        if identity.isCrowd {
            let app: String = NameToString(npc.GetCurrentAppearanceName());
            if StrLen(app) > 3 && NotEquals(app, "None") {
                opening += s" The look: \(StrReplaceAll(app, "_", " ")).";
            }
        }

        // Hands. If they are holding something, the model must know - or it
        // promises actions its hands cannot do (field concern). One line,
        // only when true.
        let held: String = StActions.HeldItemName(npc);
        if StrLen(held) > 0 {
            // Stated concretely, because this is now what stops them narrating
            // things their hands cannot do - there is no [DROP] instruction
            // left to lean on.
            opening += s" \(who) is holding \(held) right now, and can put it down.";
        } else {
            // Workspot props (a bartender's glass and rag) belong to the
            // ANIMATION, not the puppet - no script API can read them
            // (verified: the item system's only hand slots are WeaponRight/
            // Left, and workspot items have no getter). So for an NPC
            // visibly mid-routine, say that much - the model improvises
            // consistently with what the player SEES instead of claiming
            // empty hands next to a full ones.
            let ws = GameInstance.GetWorkspotSystem(game);
            if IsDefined(ws) && ws.IsActorInWorkspot(npc) {
                // The workspot's authored TAGS name the routine when the
                // author bothered (GetCurrentWorkspotTags,
                // scriptedPuppet.swift:1192) - the closest thing to reading
                // the idle animation itself. Fed cleaned, capped at three.
                let tagStr: String = "";
                let wtags: array<CName> = npc.GetCurrentWorkspotTags();
                let i: Int32 = 0;
                while i < ArraySize(wtags) && i < 3 {
                    let tw: String = StrReplaceAll(NameToString(wtags[i]), "_", " ");
                    if StrLen(tw) > 2 && NotEquals(tw, "None") {
                        tagStr += StrLen(tagStr) > 0 ? ", " + tw : tw;
                    }
                    i += 1;
                }
                if StrLen(tagStr) > 0 {
                    opening += s" \(who) is in the middle of the usual routine: \(StrLower(tagStr)).";
                } else {
                    opening += s" \(who)'s hands are busy with the usual work.";
                }
            }
        }

        // Disposition. Hostile NPCs never reach this code (TryOpen filters
        // them), so the only useful distinction left is friendly vs neutral.
        let player = GetPlayer(game);
        if IsDefined(player) && Equals(GameObject.GetAttitudeTowards(npc, player), EAIAttitude.AIA_Friendly) {
            opening += s" \(who) is on friendly terms with this merc.";
        }

        // Whether this person KNOWS V decides whether the prompt may name V.
        // A stranger who was told "you're talking to V" greeted the player by
        // name (field report) - the model can't know a fact is off-limits if
        // the prompt states it as scene truth. Story characters know V;
        // anyone the player has actually conversed with before has at least
        // met them.
        let charStory: String = StStory.CharacterContext(displayName, game);
        let knowsV: Bool = StrLen(charStory) > 0
            || (IsDefined(memory) && memory.conversations > 0);

        let p: String = opening;
        if knowsV {
            // WHY they know the name, not just that they do. Story characters
            // know V because of history; everyone else knows because V told
            // them in an earlier conversation, and saying so keeps the model
            // from treating the name as something it simply knows.
            if StrLen(charStory) > 0 {
                p += s" \(who) is talking with V, a mercenary.";
            } else {
                p += s" \(who) is talking with a mercenary they have met before,"
                    + " who told them their name is V.";
            }
        } else {
            p += s" \(who) is talking with an armed merc-looking stranger whose"
                + " name they do not know, and who they did not ask to be"
                + " interrupted by.";
        }
        // Format doubles as protocol: the quotes carry the spoken words
        // (display + voice), the beat drives the animation and expression
        // pickers. Two lines of prompt, no lists - token budget matters.
        p += s" \(familiarity)";

        // Actions the model may take, when enabled. ONLY the ones where intent
        // must be EXPLICIT: everything expressive - walking off, waving,
        // putting something down - is read out of the stage beat instead
        // (StActions.ResolveIntent). That removed 150 tokens from every card
        // and stopped the model reaching for a tag on every single reply.
        let st = RealTalkSettings.Get();
        if IsDefined(st) && st.npcActions {
            // ALMOST NOTHING. Every instruction here competes for a small
            // model's attention with being a person, and the last version
            // taught tags the model then typo'd, parroted, or dropped -
            // costing the action either way. What they DO is read out of the
            // plain words of their reply instead (StActions.ResolveIntent and
            // beat), which needs no instruction at all.
            //
            // Money is the exception that stays: it moves real eddies, so it
            // must be deliberate rather than inferred from a turn of phrase.
            p += " Money is real: write [PAY 500] to hand V 500 eddies of your own,"
                + " or [CHARGE 500] to take 500 from V - only when a price has"
                + " actually been agreed.";
            if IsDefined(st) && st.npcCombat {
                p += " If V talks you into real violence, [ATTACK] makes you turn on"
                    + " whoever V is pointing at. That is a real fight - only if you"
                    + " mean it.";
            }
        }

        // Story context - who this person is in the narrative, and what the
        // whole city publicly knows. See RealTalkStory.reds.
        //
        // CONTRADICTION GUARD: for characters whose story establishes a
        // relationship with V, the encounter-counter's "you have never
        // spoken to this person" must not ALSO be in the prompt - a 7B
        // resolves that clash by greeting Jackie's best friend like a
        // stranger ("never seen your face", field-reported).
        if StrLen(charStory) > 0 {
            if StrContains(p, "You have never spoken to this person") {
                p = StrReplace(p, " You have never spoken to this person before.", "");
                p = StrReplace(p, "You have seen this person around a lot but never spoken to them.", "");
            }
            p += " " + charStory;
        }
        // THE JOB IN PROGRESS - but only for people plausibly in it with V:
        // someone with a story in this mod, or an actual companion right now
        // (aiComponent.swift:493). A clothing vendor has no business knowing
        // what V is in the middle of, and "don't forget the mission" from a
        // stranger would be the worst line in the game.
        let inItTogether: Bool = StrLen(charStory) > 0;
        if !inItTogether {
            let aic = npc.GetAIControllerComponent();
            inItTogether = IsDefined(aic) && aic.IsPlayerCompanion();
        }
        // The game never lets you clear the tracked objective, so the main
        // story is ALWAYS tracked in the background. Handing that to every
        // friend you have would make the whole city think you are mid-plot
        // permanently - so main-story objectives go only to the people whose
        // story it is.
        // IS THIS THEIR QUEST? Answered from their own voice lines rather than
        // a hand-written list: if the tracked quest's id appears among the
        // quests they speak in, they belong to it. That covers characters
        // nobody would think to list - the fixer from the opening, a one-scene
        // quest-giver - and needs no maintenance at all.
        let theirQuest: Bool = StStory.TrackedQuestBelongsTo(
            game, StPersona.QuestIds(displayName));
        if inItTogether && StStory.TrackedIsMainStory(game) && !theirQuest
            && !StStory.MainStoryCharacter(displayName) {
            inItTogether = false;
        }
        // And someone whose quest it IS hears about it even if this mod has
        // never heard of them.
        if theirQuest {
            inItTogether = true;
        }
        if inItTogether {
            let job: String = StStory.ActiveJob(game);
            if StrLen(job) > 0 {
                p += s" You and V are in the middle of something right now - \(job)."
                    + " You would NOT recite the objective at V like a reminder;"
                    + " you simply talk like someone with somewhere to be.";
            }
        }

        let world: String = StStory.WorldContext(game);
        if StrLen(world) > 0 {
            p += " " + world;
        }

        // Their OWN dialogue, harvested from the archives, as few-shot
        // examples. A 7B told to "be in character" still writes like a
        // brochure ("from classic cocktails to custom concoctions"); shown
        // eight of the character's real lines, it copies their register.
        // Who the city says you are, before how you talk.
        let bio: String = StPersona.BioLines(displayName);
        if StrLen(bio) > 0 {
            p += " Things written about you in Night City - messages, shards,"
                + " word going around. This is who you are, not something you"
                + " would recite:" + bio;
        }

        let examples: String = StPersona.ExampleLines(displayName);
        if StrLen(examples) > 0 {
            p += " Here is how you actually talk - match this voice, rhythm and vocabulary:" + examples;
        }
        p += " Never use marketing or brochure language, alliteration, or tidy lists."
            + " Talk like a real person in a bar or on a street: short, plain, sometimes blunt.";

        // One line so the log shows exactly what the model was told about them.
        StLog(s"card: \(displayName) | \(kind) | faction=\(faction) | \(district) \(hour):00");
        // ...and the whole card, once, when Debug Log is on. Being able to
        // read what an NPC was actually told is the only way to tell a model
        // failure from a prompt failure - and it is the prompt more often
        // than not.
        StLog(s"card text: \(p)");

        if IsDefined(memory) && StrLen(memory.gist) > 0 {
            // The gist, not a transcript. This is what survives - see the
            // memory model note in RealTalkMemory.reds.
            p += s" What you remember about V: \(memory.gist)";
        }

        if IsDefined(cfg) && StrLen(cfg.extraSystemPrompt) > 0 {
            p += " " + cfg.extraSystemPrompt;
        }

        // THE FORMAT RULE GOES LAST, and it goes last for a measured reason:
        // it used to sit in the middle, and everything after it - the story,
        // the anti-brochure note, and especially eight examples of this
        // character's REAL dialogue, which are pure speech with no action in
        // them - taught the opposite. The model wrote speech only, so there was
        // no action beat, so nothing could be acted on (field report: agreed to
        // follow, stood still). Recency wins with a small model, so the format
        // is the last thing it reads before answering.
        p += s" Reply as \(who): one or two sentences of speech in double quotes,"
            + " then a few plain words for what they physically do, or *the"
            + " action between asterisks* - either way, always something."
            // A SHAPE, NOT A LINE. This used to end with a worked example -
            // "What's up?" *crosses her arms* - and a 7B handed that exact
            // line back as its answer 3 times in 22 (measured, first-turn:
            // "follow me" and "come closer" both got "What's up?"). It is the
            // last thing in the prompt, so the model reads it as the reply
            // rather than the pattern.
            //
            // Deleting it outright is worse: the beat then goes missing in
            // 14% of replies, because the example is what teaches the format.
            // A placeholder shape keeps the teaching and cannot be copied -
            // measured at zero parroting, 100% quotes, 100% beats.
            + s" The shape is: \"<what they say>\" *<what they do>*"
            // WHOSE REPLY IS IT. Without this the model sometimes writes the
            // PLAYER's action into the beat - "*V takes the shot*", "*V
            // prepares to leave*" - and the mod then performs it on the NPC,
            // which is how someone does a thing V never asked for. Measured:
            // subject confusion 1/48 -> 0/48, and the model echoing V's own
            // line back as its dialogue 7/48 -> 4/48. Framing the card as a
            // two-sided conversation on top of this added nothing and cost
            // format compliance, so it is deliberately not here."
            + " Never speak or act for V - only write what they themselves say and do.";

        return p;
    }
}
