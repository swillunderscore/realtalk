// ============================================================================
//  STREET TALK - NPC gender, from data the game actually has
// ============================================================================
//
//  Field report: a female crowd walker ("NC Resident", North Oak) got a male
//  voice. GetGender() reads persistent state and comes back empty for crowd
//  puppets, and GetResolvedGenderName() is a PLAYER-appearance API - every
//  vanilla call site is character customization or inventory - so it never
//  resolves for NPCs. With gender unknown, the voice ladder ran unfiltered
//  and a male archetype won.
//
//  But the game knows. Two places, both verified:
//
//  1. Character_Record.Genders() - a list of GenderEntity_Record pairing each
//     spawnable entity template with a gender (orphans.swift:16306, 60773).
//     Codeware's Entity.GetTemplatePath() says exactly which template this
//     puppet spawned from; matching it into that list reads back the same
//     pairing the game used to spawn her. When every entry in the record
//     agrees anyway, no matching is needed.
//
//  2. The template path itself. The game's own asset naming carries gender
//     as path tokens - verified against this player's archives:
//     player_ma_fpp.ent / player_wa_fpp.ent (paired in-engine with "man" /
//     "woman" rig names), crowd__westbrook_northoaks_ma.ent,
//     gang__voodoo_wa.ent. "ma" = man adult, "wa" = woman adult.
// ============================================================================

module StreetTalk

public class StGender {

    public static func Resolve(npc: ref<NPCPuppet>) -> String {
        // What worked for anchored NPCs stays first.
        let g: String = NameToString(npc.GetGender());
        if Equals(g, "Male") || Equals(g, "Female") {
            return g;
        }

        // Codeware's ResRef helpers are STATICS ON ResRef - a bare
        // ToString(resref) silently resolves to redscript's generic debug
        // formatter instead ("redResourceReferenceScriptToken[ resource: ]",
        // field-caught: it reduced this whole ladder to comparing garbage).
        let tplRef: ResRef = npc.GetTemplatePath();
        let tpl: String = ResRef.ToString(tplRef);

        // The record's own template->gender pairing. Only "Male"/"Female"
        // are trusted out of it - any other enum name falls through rather
        // than flowing onward as a fake fact.
        let rec = TweakDBInterface.GetCharacterRecord(npc.GetRecordID());
        if IsDefined(rec) {
            let count: Int32 = rec.GetGendersCount();
            let unanimous: String = "";
            let mixed: Bool = false;
            let i: Int32 = 0;
            while i < count {
                let entry = rec.GetGendersItem(i);
                if IsDefined(entry) && IsDefined(entry.Gender()) {
                    let name: String = NameToString(entry.Gender().EnumName());
                    if Equals(name, "Male") || Equals(name, "Female") {
                        // Hash-to-hash comparison (Codeware ResRef.GetHash) -
                        // no string conversion, no operator-resolution
                        // ambiguity in the load-bearing path.
                        if ResRef.GetHash(entry.Entity()) == ResRef.GetHash(tplRef)
                            && ResRef.GetHash(tplRef) != 0ul {
                            return name;
                        }
                        if StrLen(unanimous) == 0 {
                            unanimous = name;
                        } else {
                            if NotEquals(unanimous, name) {
                                mixed = true;
                            }
                        }
                    }
                }
                i += 1;
            }
            if StrLen(unanimous) > 0 && !mixed {
                return unanimous;
            }
        }

        let fromTpl: String = StGender.FromTemplateTokens(tpl);
        if StrLen(fromTpl) > 0 {
            return fromTpl;
        }

        // The record NAME itself: crowd records are called things like
        // Character.CorpoWoman (field-observed via diag). CamelCase and
        // underscores split into words, matched whole - "Woman" can never
        // read as "Man", "Manager" matches nothing.
        let fromRec: String = StGender.FromNameWords(TDBID.ToStringDEBUG(npc.GetRecordID()));
        if StrLen(fromRec) > 0 {
            return fromRec;
        }

        // Appearance names are artist-written and often carry the same
        // wa/ma body tokens as entity paths. Same strict whole-token
        // matcher, so a non-gendered appearance just resolves nothing.
        return StGender.FromTemplateTokens(NameToString(npc.GetCurrentAppearanceName()));
    }

    // Everything the ladder saw, one line, for the voice server's always-on
    // log - in-game logging is opt-in and diagnosis must not depend on it.
    public static func Diag(npc: ref<NPCPuppet>) -> String {
        let rec = TweakDBInterface.GetCharacterRecord(npc.GetRecordID());
        let genders: Int32 = IsDefined(rec) ? rec.GetGendersCount() : -1;
        let wtags: String = "";
        let tags: array<CName> = npc.GetCurrentWorkspotTags();
        let i: Int32 = 0;
        while i < ArraySize(tags) {
            wtags += s" \(tags[i])";
            i += 1;
        }
        return s"raw=\(npc.GetGender()) rec=\(TDBID.ToStringDEBUG(npc.GetRecordID())) genders=\(genders) tpl=\(ResRef.ToString(npc.GetTemplatePath())) app=\(npc.GetCurrentAppearanceName()) wtags=[\(wtags) ]";
    }

    // "wa" / "ma" as whole path tokens only - "_ward" or "warden" can never
    // match. When both appear (a gendered file inside a gendered directory)
    // the LAST occurrence wins: the filename is the more specific fact.
    public static func FromTemplateTokens(path: String) -> String {
        if StrLen(path) == 0 {
            return "";
        }
        let norm: String = StrReplaceAll(path, "\\", "_");
        norm = StrReplaceAll(norm, "/", "_");
        norm = StrReplaceAll(norm, ".", "_");
        norm = s"_\(norm)_";
        let wa: Int32 = StGender.LastIndexOf(norm, "_wa_");
        let ma: Int32 = StGender.LastIndexOf(norm, "_ma_");
        if wa > ma {
            return "Female";
        }
        if ma > wa {
            return "Male";
        }
        return "";
    }

    // Split on case boundaries, underscores, dots and digits, then compare
    // whole words. "Character.CorpoWoman" -> [character, corpo, woman].
    public static func FromNameWords(name: String) -> String {
        let words: String = "";
        let i: Int32 = 0;
        while i < StrLen(name) {
            let ch: String = StrMid(name, i, 1);
            let lower: String = StrLower(ch);
            if StrFindFirst("abcdefghijklmnopqrstuvwxyz", lower) == -1 {
                words += " ";
            } else {
                if NotEquals(ch, lower) {
                    words += " ";
                }
                words += lower;
            }
            i += 1;
        }
        words = s" \(words) ";
        // Female words FIRST is not just style: " woman " as a whole word can
        // never be confused, but ordering still documents the trap.
        if StrContains(words, " woman ") || StrContains(words, " female ") || StrContains(words, " girl ") {
            return "Female";
        }
        if StrContains(words, " man ") || StrContains(words, " male ") || StrContains(words, " boy ") {
            return "Male";
        }
        return "";
    }

    static func LastIndexOf(hay: String, needle: String) -> Int32 {
        let last: Int32 = -1;
        let offset: Int32 = 0;
        let guard: Int32 = 0;
        // Overlaps matter here: "_ma_ma_" must find the second "_ma_", so the
        // scan advances one character past each hit, not past the needle.
        while guard < 64 {
            guard += 1;
            let idx: Int32 = StrFindFirst(StrMid(hay, offset), needle);
            if idx == -1 {
                break;
            }
            last = offset + idx;
            offset = last + 1;
        }
        return last;
    }
}
