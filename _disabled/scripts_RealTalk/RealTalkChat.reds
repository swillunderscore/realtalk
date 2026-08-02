// ============================================================================
//  STREET TALK - conversation
// ============================================================================
//
//  Talks to any OpenAI-compatible endpoint (llama.cpp, Ollama, LM Studio,
//  KoboldCpp). The endpoint comes from Mod Settings presets so most users
//  never edit a file.
//
//  HARD REQUIREMENT: the game must be launched with -no-tls.
//    RedHttpClient refuses http:// urls outright - it returns null WITHOUT
//    opening a socket, which surfaces as status code 0 and looks exactly like
//    a dead mod. -no-tls permits unencrypted requests to localhost and local
//    network ranges, and it only exists in RedHttpClient 0.7.1+ (0.7.0 has no
//    such flag at all, so the Nexus build may be too old - use GitHub).
//    This cost hours to diagnose once; the README leads with it.
//
//  REASONING MODELS: if the server runs a thinking model, replies come back
//  with an empty `content` and the text in `reasoning_content`. The mod reads
//  `content`, so every message renders blank. Start llama.cpp with
//  --reasoning off, or use a non-reasoning model.
// ============================================================================

module RealTalk

import RedHttpClient.*
import RedData.Json.*

// Request shape. Serialised with ToJson(), matching the proven pattern - see
// RealTalkMemory for why we don't build JsonObjects directly.
public class StChatMessageDTO extends IScriptable {
    public let role: String;
    public let content: String;
}

public class StChatRequestDTO extends IScriptable {
    public let model: String;
    public let messages: array<ref<StChatMessageDTO>>;
    public let max_tokens: Int32;
    public let temperature: Float;
    public let stream: Bool;
}

public class StChat extends ScriptableSystem {

    private let busy: Bool;
    private let history: array<ref<StChatMessageDTO>>;
    private let activeId: Uint64;

    private func Msg(role: String, content: String) -> ref<StChatMessageDTO> {
        let m = new StChatMessageDTO();
        m.role = role;
        m.content = content;
        return m;
    }

    // Starting a conversation with a different person clears the thread, but
    // returning to the SAME person mid-session resumes it - so stepping out to
    // pick a real dialogue option and coming back doesn't wipe the exchange.
    public func Begin(identity: ref<StIdentity>, persona: String) -> Void {
        if !IsDefined(identity) || !identity.valid {
            return;
        }
        if NotEquals(this.activeId, identity.persistentId) || ArraySize(this.history) == 0 {
            ArrayClear(this.history);
            this.activeId = identity.persistentId;
            ArrayPush(this.history, this.Msg("system", persona));
        }
    }

    // Exposed so the UI can redraw an existing conversation on reopen.
    public func GetHistory() -> array<ref<StChatMessageDTO>> {
        return this.history;
    }

    public func IsBusy() -> Bool {
        return this.busy;
    }

    public func Send(playerLine: String) -> Void {
        if this.busy {
            return;
        }
        let settings = RealTalkSettings.Get();
        let cfg = RealTalkConfig.Get();
        if !IsDefined(settings) || !IsDefined(cfg) {
            return;
        }

        ArrayPush(this.history, this.Msg("user", playerLine));

        let req = new StChatRequestDTO();
        req.model = cfg.customModel;
        req.messages = this.history;
        req.max_tokens = settings.maxTokens;
        req.temperature = settings.temperature;
        req.stream = false;

        let headers: array<HttpHeader>;
        ArrayPush(headers, HttpHeader.Create("Content-Type", "application/json"));
        if StrLen(cfg.customApiKey) > 0 {
            ArrayPush(headers, HttpHeader.Create("Authorization", "Bearer " + cfg.customApiKey));
        }

        let url: String = settings.GetEndpoint();
        let body: String = ToJson(req).ToString();

        this.busy = true;
        AsyncHttpClient.Post(HttpCallback.Create(this, n"OnReply"), url, body, headers);
        if settings.logging {
            StLog(s"POST \(url)");
        }
    }

    private cb func OnReply(response: ref<HttpResponse>) -> Void {
        this.busy = false;
        let settings = RealTalkSettings.Get();

        if !IsDefined(response) {
            StLog("no response object");
            return;
        }
        if NotEquals(response.GetStatus(), HttpStatus.OK) {
            let code = response.GetStatusCode();
            StLog(s"request failed, status \(code)");
            // Status 0 means the request never left - almost always the
            // missing -no-tls launch flag rather than a server problem.
            if code == 0 {
                StLog("  status 0 = the request never opened a socket.");
                StLog("  Launch the game with:  %command% -no-tls");
                StLog("  and make sure RedHttpClient is 0.7.1 or newer.");
            }
            return;
        }

        let json = response.GetJson();
        if !IsDefined(json) || json.IsUndefined() {
            StLog("response was not valid JSON");
            return;
        }
        let root = json as JsonObject;
        if !IsDefined(root) {
            return;
        }
        let choices = root.GetKey("choices") as JsonArray;
        if !IsDefined(choices) || choices.GetSize() == 0u {
            StLog("no choices in response");
            return;
        }
        let first = choices.GetItem(0u) as JsonObject;
        if !IsDefined(first) {
            return;
        }
        let message = first.GetKey("message") as JsonObject;
        if !IsDefined(message) {
            return;
        }
        let text: String = message.GetKeyString("content");

        if StrLen(text) == 0 {
            // Empty content with a 200 means a reasoning model put its output
            // in reasoning_content. Say so plainly rather than showing a blank
            // message - this exact failure wasted hours once already.
            StLog("empty content - the server is running a REASONING model.");
            StLog("  Start it with --reasoning off, or use a non-reasoning model.");
            return;
        }

        ArrayPush(this.history, this.Msg("assistant", text));

        // Push it into the on-screen panel if one is open. If the player closed
        // the chat while the model was still thinking, this is a no-op and the
        // line simply stays in history for when they reopen.
        let ui = RealTalkUI.Get();
        if IsDefined(ui) && ui.IsOpen() {
            ui.AddLine("THEM", text, false);
        }
        if IsDefined(settings) && settings.logging {
            StLog(s"reply: \(text)");
        }
    }

    public static func Get() -> ref<StChat> {
        return GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"RealTalk.StChat") as StChat;
    }
}
