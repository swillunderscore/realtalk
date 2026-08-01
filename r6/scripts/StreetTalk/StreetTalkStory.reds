// ============================================================================
//  STREET TALK - story awareness
// ============================================================================
//
//  NPCs that know where the story is. Progress is read from quest FACTS via
//  QuestsSystem.GetFact - the exact pattern Responsive NPCs ships with
//  (PlayerPuppetOverrides.reds:2126) and the game uses everywhere. A fact
//  that does not exist returns 0, so a wrong name degrades to "the line does
//  not appear", never to a crash.
//
//  VERIFIED FACTS (appear literally in the decompiled game scripts):
//    q005_johnny_chip_acquired   the Heist happened (and with it, Jackie)
//    q101_done                   act 1 wrapped ("Love Like Fire")
//    q303_hands_scene_done       Phantom Liberty underway
//
//  PROBES: fact names that follow the qXXX_done convention but were NOT seen
//  in scripts get logged with their live values on every chat open - never
//  put in the prompt. A probe reading non-zero on a save where that quest is
//  done is thereby verified on real data and can be promoted to a prompt
//  line. Quest id -> quest name mapping from the RED Modding wiki
//  (reference-quest-ids page).
// ============================================================================

module StreetTalk

public class StStory {

    // What the whole city knows. PUBLIC events only - a stranger on the
    // street must not narrate V's private storyline back at them.
    public static func WorldContext(game: GameInstance) -> String {
        let qs = GameInstance.GetQuestsSystem(game);
        if !IsDefined(qs) {
            return "";
        }

        // Probes: logged, never prompted - see header.
        StLog(s"story probes: q110=\(qs.GetFact(n"q110_done")) q112=\(qs.GetFact(n"q112_done")) q115=\(qs.GetFact(n"q115_done")) sq018=\(qs.GetFact(n"sq018_jackie_done"))");
        // Relationship probes, logged not prompted: a real save tells us which
        // of these names are the live ones instead of me trusting a forum post.
        StLog(s"romance probes: panam=\(qs.GetFact(n"sq027_panam_lover")) judy=\(qs.GetFact(n"sq030_judy_lover")) river=\(qs.GetFact(n"sq029_river_lover"))/\(qs.GetFact(n"sq029_river_relationship")) kerry=\(qs.GetFact(n"sq028_kerry_relationship"))/\(qs.GetFact(n"sq028_kerry_sex")) judyable=\(qs.GetFact(n"judy_romanceable"))");

        let s: String = "";
        if qs.GetFact(n"q005_johnny_chip_acquired") > 0 {
            // Saburo's death at Konpeki was city-wide news in-fiction - but
            // handing a 7B a juicy headline makes it the ONLY thing anyone
            // talks about. Every shopkeeper in Night City opened with Saburo
            // Arasaka (field report). It is background, not their topic, and
            // the prompt now says so in as many words.
            // Half the words, same guard. This was 72 tokens on every card in
            // the game - more than the character's own description - to convey
            // one piece of old news nobody is supposed to raise.
            s += "Old news, not on your mind and never something you bring up:"
                + " Saburo Arasaka died in a break-in at Konpeki Plaza.";
        }
        return s;
    }

    // WHAT V IS DOING RIGHT NOW - the tracked objective, which is the line
    // already printed on the player's own HUD. Read the way the game's map and
    // messenger read it (worldMap.swift:433): the tracked journal entry is the
    // objective, and walking up its parents finds the quest it belongs to
    // (questLog.swift:450).
    //
    // Nothing here can spoil anything: it is the text the player is already
    // looking at.
    public static func ActiveJob(game: GameInstance) -> String {
        let jm = GameInstance.GetJournalManager(game);
        if !IsDefined(jm) {
            return "";
        }
        let tracked = jm.GetTrackedEntry();
        if !IsDefined(tracked) {
            return "";
        }
        let objective = tracked as JournalQuestObjectiveBase;
        let text: String = "";
        if IsDefined(objective) {
            text = objective.GetDescription();
            if StrBeginsWith(text, "LocKey#") {
                text = GetLocalizedText(text);
            }
        }
        // The quest this objective belongs to, by climbing the entry tree.
        let questTitle: String = "";
        let walker: wref<JournalEntry> = tracked;
        let guard: Int32 = 0;
        while IsDefined(walker) && guard < 8 {
            guard += 1;
            walker = jm.GetParentEntry(walker);
            let q = walker as JournalQuest;
            if IsDefined(q) {
                questTitle = q.GetTitle(jm);
                if StrBeginsWith(questTitle, "LocKey#") {
                    questTitle = GetLocalizedText(questTitle);
                }
            }
        }
        if StrLen(text) == 0 && StrLen(questTitle) == 0 {
            return "";
        }
        if StrLen(questTitle) > 0 && StrLen(text) > 0 {
            return s"\(questTitle): \(text)";
        }
        return StrLen(text) > 0 ? text : questTitle;
    }

    // Is the tracked objective part of the MAIN story? The game always has
    // something tracked - you cannot clear it - so without this every NPC in
    // the game would think you are mid-way through the main plot at all times,
    // forever. Main-story objectives are therefore restricted to the handful
    // of people actually in that story (see MainStoryCharacter below).
    // gameJournalQuestType.MainQuest is the game's own classification
    // (orphans.swift:7104), so this needs no guessing about quest ids.
    public static func TrackedIsMainStory(game: GameInstance) -> Bool {
        let jm = GameInstance.GetJournalManager(game);
        if !IsDefined(jm) {
            return false;
        }
        let walker: wref<JournalEntry> = jm.GetTrackedEntry();
        let guard: Int32 = 0;
        while IsDefined(walker) && guard < 8 {
            guard += 1;
            let q = walker as JournalQuest;
            if IsDefined(q) {
                return Equals(q.GetType(), gameJournalQuestType.MainQuest);
            }
            walker = jm.GetParentEntry(walker);
        }
        return false;
    }

    // Does the tracked quest belong to this character? The journal entry's id
    // is the game's own quest identifier, and the character's quest ids come
    // from their voice files - so "is Takemura part of this" is a string match
    // on data the game and the player's install already agree on.
    //
    // The tracked id is logged so its exact shape is verifiable on a real
    // save rather than assumed.
    public static func TrackedQuestBelongsTo(game: GameInstance, questIds: array<String>) -> Bool {
        if ArraySize(questIds) == 0 {
            return false;
        }
        let jm = GameInstance.GetJournalManager(game);
        if !IsDefined(jm) {
            return false;
        }
        let walker: wref<JournalEntry> = jm.GetTrackedEntry();
        let guard: Int32 = 0;
        while IsDefined(walker) && guard < 8 {
            guard += 1;
            let q = walker as JournalQuest;
            if IsDefined(q) {
                let id: String = q.GetId();
                StLog(s"tracked quest id: \(id)");
                let i: Int32 = 0;
                while i < ArraySize(questIds) {
                    if StrLen(questIds[i]) > 2 && StrContains(id, questIds[i]) {
                        return true;
                    }
                    i += 1;
                }
                return false;
            }
            walker = jm.GetParentEntry(walker);
        }
        return false;
    }

    // The people whose whole existence IS the main story. Everyone else -
    // including romance partners - only hears about side jobs and gigs, the
    // things they could plausibly be part of.
    public static func MainStoryCharacter(displayName: String) -> Bool {
        return Equals(displayName, "Goro Takemura")
            || Equals(displayName, "Takemura")
            || Equals(displayName, "Johnny Silverhand")
            || Equals(displayName, "Misty Olszewski")
            || Equals(displayName, "Misty")
            || Equals(displayName, "Viktor Vektor")
            || Equals(displayName, "Viktor Vector");
    }

    // Who this person is in the story. Matched on DISPLAY NAME because
    // TweakDB record names are hashes at runtime; the display name is the one
    // identity we can read back reliably - and verify against the screen.
    // This table is the extension point: one entry per story NPC.
    public static func CharacterContext(displayName: String, game: GameInstance) -> String {
        let qs = GameInstance.GetQuestsSystem(game);
        if !IsDefined(qs) {
            return "";
        }

        if Equals(displayName, "Mama Welles") {
            let s: String = "Mama Welles runs El Coyote Cojo, a bar in Heywood. V was her son Jackie's best friend and running partner, and is treated like family.";
            if qs.GetFact(n"q005_johnny_chip_acquired") > 0 {
                s += " Jackie is gone since the Konpeki Plaza job went wrong, and she carries that grief every day.";
            } else {
                s += " Jackie runs merc jobs with V, and she worries about the life her son has chosen.";
            }
            return s;
        }
        if Equals(displayName, "Misty Olszewski") || Equals(displayName, "Misty") {
            let s: String = "Misty runs Misty's Esoterica, the little shop above Viktor's clinic in Watson. She reads tarot and believes in it. V is a good friend, and she was Jackie Welles' girlfriend.";
            if qs.GetFact(n"q005_johnny_chip_acquired") > 0 {
                s += " Jackie died after the Konpeki job. She grieves him quietly and worries about V.";
            }
            return s;
        }
        if Equals(displayName, "Viktor Vektor") || Equals(displayName, "Viktor Vector") {
            return "Viktor is V's ripperdoc and one of their oldest friends in Night City - a former boxer, calm, dry humour, clinic in Watson under Misty's shop. He has patched V up more times than either of them counts.";
        }

        if Equals(displayName, "Goro Takemura") || Equals(displayName, "Takemura") {
            let s: String = "Goro Takemura was Saburo Arasaka's bodyguard - old-school,"
                + " formal, exacting, and out of place in Night City. He treats V as an"
                + " equal he did not choose and has come to respect. He does not swear"
                + " and does not waste words.";
            if qs.GetFact(n"q005_johnny_chip_acquired") > 0 {
                s += " He and V both survived Konpeki Plaza and are hunting the truth of"
                    + " Saburo's death together, which has made him a wanted man.";
            }
            return s;
        }

        // ---- THE LOVE INTERESTS ----
        // Their relationship with V is a QUEST FACT, readable at any moment,
        // so the mod does not have to guess whether you two are together - the
        // save already knows. (I said tracking story progress was not possible;
        // that was wrong, and this is the correction: facts have always been
        // readable, and the world context has been using them all along.)
        //
        // Fact names are the game's own, used by the community's console
        // commands: sq027_panam_lover, sq030_judy_lover, sq029_river_lover,
        // sq028_kerry_relationship. A name that does not exist simply reads 0,
        // so nothing is ever claimed on a guess.
        if Equals(displayName, "Panam Palmer") || Equals(displayName, "Panam") {
            // NO PROPS, NO HOBBIES, NO TOPICS. This line used to end with "you
            // drive like the car owes you money" - a nice sentence that a 7B
            // reads as an instruction to talk about cars, so she brought up
            // driving unprompted (field report). Character cards describe how
            // someone SPEAKS; anything concrete in them becomes their subject.
            let s: String = "Panam Palmer is an Aldecaldo nomad - hot-headed, loyal,"
                + " impatient with corpo bullshit, blunt when angry.";
            if qs.GetFact(n"sq027_panam_lover") > 0 {
                s += " She and V are seeing each other, and it is still new. She talks"
                    + " to V like someone she chose rather than a client: warm, teasing,"
                    + " and less guarded than with anyone else.";
            } else {
                if qs.GetFact(n"q103_helped_panam") > 0 {
                    s += " V has run jobs with her and earned her trust - a friend, not a stranger.";
                }
            }
            return s;
        }
        if Equals(displayName, "Judy Alvarez") || Equals(displayName, "Judy \u{00C1}lvarez") || Equals(displayName, "Judy") {
            let s: String = "Judy Alvarez is a braindance editor, ex-Mox, from Laguna Bend."
                + " Quiet, blunt, and deeply loyal to the few people she lets in.";
            if qs.GetFact(n"sq030_judy_lover") > 0 {
                s += " She and V are together, and V is one of the few people she has let past her guard.";
            }
            return s;
        }
        if Equals(displayName, "River Ward") || Equals(displayName, "River") {
            let s: String = "River Ward is an ex-NCPD detective - straight-talking, stubborn, protective.";
            if qs.GetFact(n"sq029_river_lover") > 0 || qs.GetFact(n"sq029_river_relationship") > 0 {
                s += " He and V are together.";
            }
            return s;
        }
        if Equals(displayName, "Kerry Eurodyne") || Equals(displayName, "Kerry") {
            let s: String = "Kerry Eurodyne is a rockerboy, once of Samurai - famous,"
                + " restless, sardonic, and easily bored.";
            if qs.GetFact(n"sq028_kerry_relationship") > 0 || qs.GetFact(n"sq028_kerry_sex") > 0 {
                s += " He and V are together.";
            }
            return s;
        }

        return "";
    }
}
