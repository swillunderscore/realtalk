// ============================================================================
//  STREET TALK - per-NPC memory
// ============================================================================
//
//  MEMORY MODEL (fuzzy-trace theory, applied):
//
//    People encode two traces in parallel. VERBATIM is the exact wording and
//    it decays within minutes. GIST is the meaning and it persists for years.
//    That is why you forget the colour of a building you walked past but
//    remember that you waited outside a clinic in the rain feeling uneasy.
//
//    Naive context truncation gets this exactly backwards: it drops by
//    recency, so it throws away the gist along with the noise. Ten thousand
//    tokens of transcript then evicts "you saved my life once" to make room
//    for "nice weather".
//
//    So we store tiers:
//      tier 1  encountered   count + where + when          ~40 bytes
//      tier 2  spoken to     + a short gist the model wrote ~200 bytes
//      tier 3  promoted      + full history                 (later)
//
//    Recognition at tier 1 is a dictionary lookup. No inference, no LLM call,
//    no per-frame work. Tracking thousands of NPCs costs well under a MB.
//
//  KEY: the NPC's persistent ID, which was MEASURED stable across game
//  restarts for community NPCs (see StreetTalkIdentity.reds header). Crowd
//  NPCs are never stored - their IDs churn every session, so a record keyed on
//  one would attach to a stranger later.
// ============================================================================

module StreetTalk

import RedFileSystem.*
import RedData.Json.*

public class StMemoryEntry extends IScriptable {
    public let persistentId: Uint64;
    public let recordId: String;       // archetype, for regenerating a persona
    public let encounters: Int32;      // how many times we've met
    public let conversations: Int32;   // how many times we've actually spoken
    public let gist: String;           // what the model remembers, in its words
    public let lastDistrict: String;
}

// Serialisation shape. Field names here become the JSON keys, so keep them
// short and stable - renaming one silently orphans every existing save.
public class StMemoryRowDTO extends IScriptable {
    public let id: Int64;
    public let record: String;
    public let met: Int32;
    public let talked: Int32;
    public let gist: String;
}

public class StMemoryFileDTO extends IScriptable {
    public let people: array<ref<StMemoryRowDTO>>;
}

public class StMemory extends ScriptableSystem {

    private let entries: array<ref<StMemoryEntry>>;
    private let loaded: Bool;

    // RedFileSystem sandboxes each mod to its own storage directory, so this
    // is a relative name, not a path. No slashes, no platform difference.
    private func Storage() -> ref<FileSystemStorage> {
        return FileSystem.GetStorage("StreetTalk");
    }

    private func Find(id: Uint64) -> ref<StMemoryEntry> {
        for e in this.entries {
            if Equals(e.persistentId, id) {
                return e;
            }
        }
        return null;
    }

    // Called every time we resolve a community NPC. Cheap by design: a lookup
    // and an integer bump, no allocation in the common case.
    public func NoteEncounter(identity: ref<StIdentity>) -> ref<StMemoryEntry> {
        if !IsDefined(identity) || !identity.IsRememberable() {
            return null;
        }
        this.EnsureLoaded();

        let e: ref<StMemoryEntry> = this.Find(identity.persistentId);
        if !IsDefined(e) {
            e = new StMemoryEntry();
            e.persistentId = identity.persistentId;
            e.recordId = TDBID.ToStringDEBUG(identity.recordId);
            e.encounters = 0;
            e.conversations = 0;
            e.gist = "";
            ArrayPush(this.entries, e);
        }
        e.encounters += 1;
        return e;
    }

    // How familiar is this person with V? Drives greeting warmth without
    // costing an LLM call - the model is told the number, not asked to guess.
    public func FamiliarityLine(e: ref<StMemoryEntry>) -> String {
        if !IsDefined(e) || e.conversations == 0 {
            if IsDefined(e) && e.encounters > 6 {
                return "You have seen this person around a lot but never spoken to them.";
            }
            return "You have never spoken to this person before.";
        }
        if e.conversations == 1 {
            return "You have spoken to this person once before.";
        }
        if e.conversations < 5 {
            return s"You have spoken with this person \(e.conversations) times. They are becoming a familiar face.";
        }
        return s"You know this person well - you have talked \(e.conversations) times.";
    }

    private func EnsureLoaded() -> Void {
        if this.loaded {
            return;
        }
        this.loaded = true;

        let storage = this.Storage();
        if !IsDefined(storage) {
            StLog("storage unavailable - memory will not persist this session");
            return;
        }
        if NotEquals(storage.Exists("memory.json"), FileSystemStatus.True) {
            return;
        }
        let file = storage.GetFile("memory.json");
        if !IsDefined(file) {
            return;
        }
        let json = file.ReadAsJson();
        if !IsDefined(json) || json.IsUndefined() {
            return;
        }
        // Read back through the same shape Save() writes: a root object with a
        // "people" array. Reading uses the JsonObject accessors (the pattern
        // Generative Texting uses for responses) rather than FromJson, so a
        // malformed or half-written file degrades to "no memory" instead of
        // throwing.
        let root = json as JsonObject;
        if !IsDefined(root) {
            return;
        }
        let arr = root.GetKey("people") as JsonArray;
        if !IsDefined(arr) {
            return;
        }
        let i: Uint32 = 0u;
        while i < arr.GetSize() {
            let o = arr.GetItem(i) as JsonObject;
            if IsDefined(o) {
                let e = new StMemoryEntry();
                e.persistentId = Cast<Uint64>(o.GetKeyInt64("id"));
                e.recordId = o.GetKeyString("record");
                e.encounters = Cast<Int32>(o.GetKeyInt64("met"));
                e.conversations = Cast<Int32>(o.GetKeyInt64("talked"));
                e.gist = o.GetKeyString("gist");
                ArrayPush(this.entries, e);
            }
            i += 1u;
        }
        StLog(s"memory loaded: \(ArraySize(this.entries)) known people");
    }

    // Serialised via ToJson() on a DTO rather than constructing JsonObject
    // directly. No shipped mod on this system instantiates JsonObject/JsonArray
    // with `new` (they're native classes); the Generative Texting mod builds a
    // DTO and calls ToJson on it, so that's the proven path.
    public func Save() -> Void {
        let storage = this.Storage();
        if !IsDefined(storage) {
            return;
        }

        let dto = new StMemoryFileDTO();
        for e in this.entries {
            let row = new StMemoryRowDTO();
            // Int64, not String: StringToUint64 does not exist in this build,
            // and observed IDs are ~9,000,000 - orders of magnitude below the
            // 2^53 point where JSON numbers lose precision.
            row.id = Cast<Int64>(e.persistentId);
            row.record = e.recordId;
            row.met = e.encounters;
            row.talked = e.conversations;
            row.gist = e.gist;
            ArrayPush(dto.people, row);
        }

        let file = storage.GetFile("memory.json");
        if IsDefined(file) {
            file.WriteJson(ToJson(dto), "  ");
        }
    }

    public static func Get() -> ref<StMemory> {
        return GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"StreetTalk.StMemory") as StMemory;
    }
}
