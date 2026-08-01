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
import Codeware.*

// ============================================================================
//  THE storage handle. RedFileSystem's documentation, verbatim: "You must get
//  your storage only one time when running your mod. If you try to call
//  GetStorage again, you will no longer be able to use it."
//
//  We called it on EVERY log line and every save, from five call sites. The
//  first call of the process won - which is why every session's log held
//  exactly one line and memory.json / chat files never existed at all. One
//  bug, three symptoms, days of "why doesn't anything persist".
//
//  A ScriptableService (not a System) because services live once per process,
//  surviving save reloads - exactly the lifetime GetStorage demands.
// ============================================================================
public class StreetTalkFS extends ScriptableService {
    private let storage: ref<FileSystemStorage>;
    private let tried: Bool;

    public func Storage() -> ref<FileSystemStorage> {
        if !this.tried {
            this.tried = true;
            this.storage = FileSystem.GetStorage("StreetTalk");
        }
        return this.storage;
    }

    public static func Get() -> ref<StreetTalkFS> {
        return GameInstance.GetScriptableServiceContainer()
            .GetService(n"StreetTalk.StreetTalkFS") as StreetTalkFS;
    }
}

public class StreetTalkLog extends ScriptableSystem {
    private let lines: array<String>;

    private let lastLine: String;
    private let repeats: Int32;

    public func Add(text: String) -> Void {
        // ONE STUCK LINE MUST NOT BURY THE LOG. A turn that retried every tick
        // wrote hundreds of identical lines, pushed everything useful out of
        // the 400-line buffer - including the build stamp - and rewrote the
        // whole file each time.
        if Equals(text, this.lastLine) {
            this.repeats += 1;
            if this.repeats > 3 {
                return;
            }
        } else {
            if this.repeats > 3 {
                let n: Int32 = this.repeats - 3;
                this.lastLine = "";
                this.repeats = 0;
                this.Add(s"   (last line repeated \(n) more times)");
            }
            this.repeats = 0;
        }
        this.lastLine = text;
        this.AddLine(text);
    }

    private func AddLine(text: String) -> Void {
        // Cap it. This runs on a 0.2s tick and would grow without bound.
        if ArraySize(this.lines) > 400 {
            ArrayRemove(this.lines, this.lines[0]);
        }
        ArrayPush(this.lines, text);

        let fs = StreetTalkFS.Get();
        if !IsDefined(fs) {
            return;
        }
        let storage = fs.Storage();
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

// Diagnostics are opt-in (Mod Settings > General > Debug Log, default off):
// a mod on someone else's machine has no business writing files nobody asked
// for. During the settings system's own startup window the toggle is
// unreadable and logging stays off - those first frames only cost log lines,
// never behaviour.
public static func StLog(const text: String) {
    let settings = StreetTalkSettings.Get();
    if !IsDefined(settings) || !settings.debugLog {
        return;
    }
    FTLog(s"[StreetTalk]: \(text)");
    let sink = StreetTalkLog.Get();
    if IsDefined(sink) {
        sink.Add(text);
    }
}
