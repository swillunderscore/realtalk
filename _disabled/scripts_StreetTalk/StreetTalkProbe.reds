// ============================================================================
//  STREET TALK - logging
// ============================================================================
//
//  Buffers lines in memory and rewrites the whole file each time.
//
//  WHY: two file-append approaches both failed silently, each leaving only the
//  most recent line. FileSystemWriteMode.Append truncated; so did a
//  read-modify-write via ReadAsText (GetFile appears to hand back a fresh empty
//  file). Seeing only the last line caused two wrong diagnoses in a row - crowd
//  NPCs were overwriting state dozens of times a second and the log couldn't
//  show it.
//
//  Holding the lines in a system and writing the joined buffer is slower but
//  actually preserves history, which is the entire point of a log.
// ============================================================================

module StreetTalk

import RedFileSystem.*

public class StreetTalkLog extends ScriptableSystem {
    private let lines: array<String>;

    public func Add(text: String) -> Void {
        // Cap it. This runs on a 0.2s tick and would grow without bound.
        if ArraySize(this.lines) > 400 {
            ArrayRemove(this.lines, this.lines[0]);
        }
        ArrayPush(this.lines, text);

        let storage = FileSystem.GetStorage("StreetTalk");
        if !IsDefined(storage) {
            return;
        }
        let file = storage.GetFile("streettalk.log");
        if !IsDefined(file) {
            return;
        }
        let all: String = "";
        let i: Int32 = 0;
        while i < ArraySize(this.lines) {
            all += this.lines[i] + "\n";
            i += 1;
        }
        file.WriteText(all);
    }

    public static func Get() -> ref<StreetTalkLog> {
        return GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"StreetTalk.StreetTalkLog") as StreetTalkLog;
    }
}

public static func StLog(const text: String) {
    FTLog(s"[StreetTalk]: \(text)");
    let sink = StreetTalkLog.Get();
    if IsDefined(sink) {
        sink.Add(text);
    }
}
