// ============================================================================
//  STREET TALK - who is this person, according to the wiki
// ============================================================================
//
//  Optional, OFF by default, and the only thing in this mod that touches the
//  internet. When it is on, a character's name goes to the public Cyberpunk
//  wiki and their intro comes back - the same request a browser makes opening
//  that page. Nothing is redistributed: the text is fetched by this machine
//  and cached here, per character, forever.
//
//  IN THE GAME, NOT IN THE VOICE SERVER. The first version did this
//  server-side, which quietly made a text-only setup unable to use it at all.
//  The MediaWiki response has fixed keys - parse.wikitext["*"] - so the game
//  can read it directly, and this feature now needs nothing but the mod.
//
//  AND NOT IN A SYSTEM OF ITS OWN. The second version lived in a fresh
//  ScriptableSystem which never instantiated - Blue Moon produced not one line
//  in the log, because the system holding the code was never created. That is
//  the THIRD time this codebase has hit that (see RealTalkInput.reds and the
//  overheard capture). So the parsing is plain static helpers here, and the
//  requests are made by StChat, which provably runs: every conversation is
//  proof of it.
//
//  TWO GUARDS THAT MATTER, both learned from what the game actually contains:
//    1. Generic labels are not people. "Clothing Vendor", "NC Resident" and
//       "Stranger" have no page, and searching for them returns something
//       irrelevant with total confidence. They are refused before any request.
//    2. The page must carry an {{Infobox Character}}. That single check is
//       what stops a plausible-looking article about a district, a weapon or a
//       quest being read out as somebody's life story.
//
//  Titles do not always match the game's spelling either - the game says
//  Viktor Vector, the wiki says Vektor; Mama Welles is filed under her full
//  name - so a miss falls back to the wiki's own search.
// ============================================================================

module RealTalk

import RedHttpClient.*
import RedData.Json.*
import RedFileSystem.*

public class StWiki {

    // Words that mean "a role", not "a person". A name made only of these is
    // a label the game generated, and nobody wrote an article about it.
    public static func IsGenericName(name: String) -> Bool {
        let n: String = StrLower(name);
        let labels: array<String> = [
            "vendor", "resident", "stranger", "civilian", "guard", "bouncer",
            "merc", "dealer", "ripperdoc", "netrunner", "cop", "officer",
            "patron", "worker", "clerk", "shopkeeper", "bartender", "medic",
            "gonk", "corpo", "nomad", "fixer", "driver", "passerby", "child"
        ];
        let i: Int32 = 0;
        while i < ArraySize(labels) {
            if StrContains(n, labels[i]) {
                return true;
            }
            i += 1;
        }
        return false;
    }

    public static func PageUrl(page: String) -> String {
        return "https://cyberpunk.fandom.com/api.php?action=parse"
            + "&prop=wikitext&section=0&redirects=1&format=json&page="
            + StWiki.UrlEncode(page);
    }

    public static func SearchUrl(name: String) -> String {
        return "https://cyberpunk.fandom.com/api.php?action=query"
            + "&list=search&srlimit=1&format=json&srsearch="
            + StWiki.UrlEncode(name);
    }

    // Pull the useful pieces out of wikitext and cache them where the persona
    // reads them (bio_<slug>.json, the same file the offline harvester writes).
    public static func Parse(wikitext: String) -> array<String> {
        let lines: array<String>;
        let facts: String = "";
        facts += StWiki.Field(wikitext, "role");
        facts += StWiki.Field(wikitext, "occupation");
        facts += StWiki.Field(wikitext, "affiliation");
        facts += StWiki.Field(wikitext, "aka");
        facts += StWiki.Field(wikitext, "home");

        // The lead paragraph, with templates and links removed.
        let prose: String = StWiki.Clean(StWiki.StripBraces(wikitext));
        if StrLen(prose) > 360 {
            prose = StrLeft(prose, 360);
        }

        if StrLen(facts) > 0 {
            ArrayPush(lines, facts);
        }
        if StrLen(prose) > 60 {
            ArrayPush(lines, prose);
        }
        return lines;
    }

    // "|role = Japanese idol" -> "role: Japanese idol. "
    static func Field(wikitext: String, key: String) -> String {
        let at: Int32 = StrFindFirst(wikitext, s"|\(key)");
        if at == -1 {
            return "";
        }
        let rest: String = StrMid(wikitext, at);
        let eq: Int32 = StrFindFirst(rest, "=");
        if eq == -1 {
            return "";
        }
        let tail: String = StrMid(rest, eq + 1);
        // value ends at the next field or the end of the infobox
        let stop: Int32 = StrFindFirst(tail, "|");
        let nl: Int32 = StrFindFirst(tail, "\n");
        if nl != -1 && (stop == -1 || nl < stop) {
            stop = nl;
        }
        if stop == -1 {
            return "";
        }
        let val: String = StWiki.Clean(StrLeft(tail, stop));
        if StrLen(val) == 0 || StrLen(val) > 60 {
            return "";
        }
        return s"\(key): \(val). ";
    }

    // Remove {{...}} including nested ones - a single pass leaves the outer
    // braces of an infobox behind, which then reads as garbage in the card.
    static func StripBraces(text: String) -> String {
        let out: String = "";
        let depth: Int32 = 0;
        let i: Int32 = 0;
        while i < StrLen(text) {
            if Equals(StrMid(text, i, 2), "{{") {
                depth += 1;
                i += 2;
            } else {
                if Equals(StrMid(text, i, 2), "}}") {
                    if depth > 0 {
                        depth -= 1;
                    }
                    i += 2;
                } else {
                    if depth == 0 {
                        out += StrMid(text, i, 1);
                    }
                    i += 1;
                }
            }
        }
        return out;
    }

    // Wiki link syntax, bold/italic marks and stray brackets.
    static func Clean(text: String) -> String {
        let t: String = StrReplaceAll(text, "[[", "");
        t = StrReplaceAll(t, "]]", "");
        t = StrReplaceAll(t, "'''", "");
        t = StrReplaceAll(t, "''", "");
        t = StrReplaceAll(t, "\n", " ");
        t = StrReplaceAll(t, "  ", " ");
        // "Display|Target" links keep the readable half
        let bar: Int32 = StrFindFirst(t, "|");
        if bar != -1 && bar < 40 {
            t = StrMid(t, bar + 1);
        }
        return t;
    }

    static func UrlEncode(text: String) -> String {
        return StrReplaceAll(text, " ", "%20");
    }
}

// Serialisation shape for the cached biography.
public class StBioFileDTO extends IScriptable {
    public let lines: array<String>;
}


public class StWikiTimeout extends DelayCallback {
    public let chat: wref<StChat>;
    public let forName: String;
    public func Call() -> Void {
        if IsDefined(this.chat) {
            this.chat.WikiTimedOut(this.forName);
        }
    }
}
