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

module StreetTalk

public class StreetTalkConfig extends ScriptableSystem {

    // Used only when Mod Settings -> Server is set to "Custom".
    //
    // Must be a full chat-completions URL. Examples:
    //   http://127.0.0.1:8081/v1/chat/completions      (llama.cpp, this machine)
    //   http://192.168.1.50:8080/v1/chat/completions   (a server on your LAN)
    //
    // NOTE: http:// only works if the game is launched with -no-tls. See the
    // README - this is the single most common reason the mod appears dead.
    public let customBaseUrl: String = "http://127.0.0.1:8081/v1/chat/completions";

    // Most local servers ignore this and serve whatever model they were started
    // with, but it must be non-empty for the request to be well formed.
    public let customModel: String = "local-model";

    // Only needed if your endpoint requires authentication. Local servers
    // normally do not. Leave empty.
    public let customApiKey: String = "";

    // Appended to every character's prompt. Use it to set a house style for
    // the whole city - tone, profanity level, how much slang, whatever.
    // Leave empty to use each character's own prompt unmodified.
    public let extraSystemPrompt: String = "";

    public static func Get() -> ref<StreetTalkConfig> {
        return GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"StreetTalk.StreetTalkConfig") as StreetTalkConfig;
    }
}
