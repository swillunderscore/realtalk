// ============================================================================
//  STREET TALK - config file
// ============================================================================
//
//  MOST PEOPLE DO NOT NEED TO EDIT THIS FILE.
//
//  Pick your server from the "Server" dropdown in Mod Settings instead - the
//  address is filled in for you. Only edit here if you set that dropdown to
//  "Custom", or if you run your model on a different machine.
//
//  Scripts recompile when the game launches, so save and relaunch to apply.
// ============================================================================

module RealTalk

public class RealTalkConfig extends ScriptableSystem {

    // Used only when Mod Settings -> Server is set to "Custom".
    //
    // Must be a full chat-completions URL. Examples:
    //   http://127.0.0.1:8081/v1/chat/completions      (llama.cpp, this machine)
    //   http://192.168.1.50:8080/v1/chat/completions   (a server on your LAN)
    //
    // NOTE: http:// only works if the game is launched with -no-tls. See the
    // README - this is the single most common reason the mod appears dead.
    public let customBaseUrl: String = "http://127.0.0.1:8081/v1/chat/completions";

    // Local servers ignore this and serve whatever model they were started
    // with (it just has to be non-empty). CLOUD providers require a real
    // model id - for OpenRouter e.g.:
    //   public let customModel: String = "meta-llama/llama-3.3-70b-instruct";
    public let customModel: String = "local-model";

    // Required for cloud providers (your OpenRouter key goes here). Local
    // servers normally need nothing - leave empty.
    public let customApiKey: String = "";

    // Appended to every character's prompt. Use it to set a house style for
    // the whole city - tone, profanity level, how much slang, whatever.
    // Leave empty to use each character's own prompt unmodified.
    public let extraSystemPrompt: String = "";

    // Where the RealTalk TTS server listens (server/npc-tts-server.sh).
    // Only change this if you moved the server.
    public let ttsUrl: String = "http://127.0.0.1:8082/speak";

    public static func Get() -> ref<RealTalkConfig> {
        return GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"RealTalk.RealTalkConfig") as RealTalkConfig;
    }
}
