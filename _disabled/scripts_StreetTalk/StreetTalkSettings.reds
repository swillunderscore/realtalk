// ============================================================================
//  STREET TALK - settings (Mod Settings menu)
// ============================================================================
//
//  DESIGN NOTE - why presets instead of a text box:
//    Mod Settings has no free-text field, and the single biggest barrier for
//    non-technical users is getting the endpoint URL right. Every common local
//    server listens on a well-known port, so a dropdown of presets means most
//    people never open a config file at all. "Custom" falls through to
//    StreetTalkConfig.reds for anyone running something unusual.
//
//  This is a ScriptableSystem, not a ScriptableService, on purpose: services
//  are created before Mod Settings loads, so saved values silently revert to
//  code defaults. Systems are created fresh each session, after Mod Settings.
//  (Same lesson the Generative Texting mod learned the hard way.)
// ============================================================================

module StreetTalk

enum StProvider {
    LlamaCpp = 0,      // llama.cpp / llama-server        127.0.0.1:8080
    Ollama = 1,        // Ollama                          127.0.0.1:11434
    LMStudio = 2,      // LM Studio                       127.0.0.1:1234
    KoboldCpp = 3,     // KoboldCpp                       127.0.0.1:5001
    Custom = 4,        // whatever is in StreetTalkConfig.reds
}

public class StreetTalkSettings extends ScriptableSystem {

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "General")
    @runtimeProperty("ModSettings.displayName", "Enabled")
    @runtimeProperty("ModSettings.description", "Turn conversation prompts on or off entirely.")
    public let enabled: Bool = true;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Connection")
    @runtimeProperty("ModSettings.displayName", "Server")
    @runtimeProperty("ModSettings.description", "Which local AI server you are running. Pick the one you use - the address is filled in for you. IMPORTANT: the game must be launched with -no-tls or requests will silently fail.")
    @runtimeProperty("ModSettings.displayValues.LlamaCpp", "llama.cpp (port 8080)")
    @runtimeProperty("ModSettings.displayValues.Ollama", "Ollama (port 11434)")
    @runtimeProperty("ModSettings.displayValues.LMStudio", "LM Studio (port 1234)")
    @runtimeProperty("ModSettings.displayValues.KoboldCpp", "KoboldCpp (port 5001)")
    @runtimeProperty("ModSettings.displayValues.Custom", "Custom (see config file)")
    public let provider: StProvider = StProvider.LlamaCpp;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Conversation")
    @runtimeProperty("ModSettings.displayName", "Reply Length")
    @runtimeProperty("ModSettings.description", "Maximum tokens per reply. Lower is snappier. Spoken lines rarely need more than 120.")
    @runtimeProperty("ModSettings.step", "20")
    @runtimeProperty("ModSettings.min", "40")
    @runtimeProperty("ModSettings.max", "400")
    public let maxTokens: Int32 = 120;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Conversation")
    @runtimeProperty("ModSettings.displayName", "Temperature")
    @runtimeProperty("ModSettings.description", "Higher is more unpredictable. 1.0 suits most character models.")
    @runtimeProperty("ModSettings.step", "0.05")
    @runtimeProperty("ModSettings.min", "0.1")
    @runtimeProperty("ModSettings.max", "2.0")
    public let temperature: Float = 1.0;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Who You Can Talk To")
    @runtimeProperty("ModSettings.displayName", "Community NPCs")
    @runtimeProperty("ModSettings.description", "Shopkeepers, ripperdocs, bartenders and other NPCs anchored to a place. These have stable identities, so they remember you.")
    public let allowCommunity: Bool = true;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Who You Can Talk To")
    @runtimeProperty("ModSettings.displayName", "Crowd NPCs")
    @runtimeProperty("ModSettings.description", "Random pedestrians. The game pools and recycles these, so they CANNOT remember you between encounters - every conversation starts fresh.")
    public let allowCrowd: Bool = false;

    // Fires one greeting at the model the first time you meet a community NPC
    // and logs the reply. Exists to prove the whole chain works while the
    // interaction UI is still unsolved. Off for normal play - it talks to the
    // model every time you meet someone new.
    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Advanced")
    @runtimeProperty("ModSettings.displayName", "Test Mode (auto-greet)")
    @runtimeProperty("ModSettings.description", "Automatically sends a greeting to your AI server the first time you look at a community NPC, and writes the reply to the log. For verifying your setup works. Requires Enable Logs.")
    public let testMode: Bool = false;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Advanced")
    @runtimeProperty("ModSettings.displayName", "Enable Logs")
    @runtimeProperty("ModSettings.description", "Writes requests and errors to the CET gamelog. Leave off unless something is broken - logging on a hot path costs performance.")
    public let logging: Bool = false;

    public static func Get() -> ref<StreetTalkSettings> {
        return GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"StreetTalk.StreetTalkSettings") as StreetTalkSettings;
    }

    // Resolve the preset to an actual endpoint. Kept here rather than in the
    // request code so there is exactly one place that knows about ports.
    public func GetEndpoint() -> String {
        switch this.provider {
            case StProvider.Ollama:
                return "http://127.0.0.1:11434/v1/chat/completions";
            case StProvider.LMStudio:
                return "http://127.0.0.1:1234/v1/chat/completions";
            case StProvider.KoboldCpp:
                return "http://127.0.0.1:5001/v1/chat/completions";
            case StProvider.Custom:
                return StreetTalkConfig.Get().customBaseUrl;
            default:
                return "http://127.0.0.1:8080/v1/chat/completions";
        }
    }
}
