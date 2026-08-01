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

// The four local entries are the SAME protocol - an OpenAI-compatible
// /v1/chat/completions endpoint - and differ only in the port each program
// listens on by default. They exist as separate choices so nobody has to know
// their port number, which is the single most common local-setup mistake.
//
// OpenRouter sits SECOND, right under the local default: it is the zero-setup
// path (no model download, no launch option, no hardware requirement) and
// burying it under four local options misrepresented what most people will
// actually pick. Reordering remaps stored values, so it happens now, before
// release, and never after.
enum StProvider {
    LlamaCpp = 0,      // llama.cpp / llama-server        127.0.0.1:8080
    OpenRouter = 1,    // cloud, https - no -no-tls needed; key+model in config
    Ollama = 2,        // Ollama                          127.0.0.1:11434
    LMStudio = 3,      // LM Studio                       127.0.0.1:1234
    KoboldCpp = 4,     // KoboldCpp                       127.0.0.1:5001
    Custom = 5,        // whatever is in StreetTalkConfig.reds
}

// Keys offered for rebinding. Only keys VERIFIED to exist under these exact
// EInputKey member names - the game's own r6/config/inputUserMappings.xml for
// most, Codeware's shipped scripts for Delete/End. F2 and Insert appear in
// neither, so they are not offered.
enum StBindableKey {
    R = 0,
    T = 1,
    G = 2,
    H = 3,
    J = 4,
    K = 5,
    N = 6,
    M = 7,
    U = 8,
    F3 = 9,
    F4 = 10,
    Home = 11,
    End = 12,
    Delete = 13,
}

public class StreetTalkSettings extends ScriptableSystem {

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "General")
    @runtimeProperty("ModSettings.displayName", "Enabled")
    @runtimeProperty("ModSettings.description", "Turn conversation prompts on or off entirely.")
    public let enabled: Bool = true;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Voice")
    @runtimeProperty("ModSettings.displayName", "Voice Detail (seconds)")
    @runtimeProperty("ModSettings.description", "How many seconds of a character's real voice the model listens to before speaking as them. More is a closer match and slower lines; less is faster and drifts toward a generic accent. 30 is what these voices were built on - 12 was tried and audibly lost the character. Changing this rebuilds each voice's conditioning once.")
    @runtimeProperty("ModSettings.step", "3")
    @runtimeProperty("ModSettings.min", "6")
    @runtimeProperty("ModSettings.max", "30")
    public let condSeconds: Int32 = 30;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Voice")
    @runtimeProperty("ModSettings.displayName", "Rebuild All Voices")
    @runtimeProperty("ModSettings.description", "Throws away every cloned voice and lets them be built again from your game files, next time you talk to someone. For when a voice came out wrong. Flips itself back off.")
    public let resetVoices: Bool = false;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Voice")
    @runtimeProperty("ModSettings.displayName", "Speak V's Lines")
    @runtimeProperty("ModSettings.description", "Your own messages are spoken in V's voice, cloned from V's lines in your archives, before the NPC answers. It also hides synthesis time: the reply is being generated while V talks.")
    public let vVoice: Bool = true;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Voice")
    @runtimeProperty("ModSettings.displayName", "Talking Gestures")
    @runtimeProperty("ModSettings.description", "NPCs gesture while their reply plays. Needs Appearance Menu Mod installed; does nothing without it.")
    public let talkAnims: Bool = true;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Conversation")
    @runtimeProperty("ModSettings.displayName", "Violence")
    @runtimeProperty("ModSettings.description", "NPCs can turn on whoever you are pointing at if you talk them into it. They use the game's own hostility, so it is a real fight with real consequences for your save - and Night City reacts to it. OFF by default. Requires NPC Actions.")
    public let npcCombat: Bool = false;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "General")
    @runtimeProperty("ModSettings.displayName", "Character Lookup (online)")
    @runtimeProperty("ModSettings.description", "Look named characters up on the Cyberpunk wiki so they know who they are - Blue Moon knows she is in Us Cracks, Viktor knows he is a ripperdoc. OFF by default because it is the ONLY thing in this mod that touches the internet: with it on, a character's name is sent to a public wiki, like opening the page yourself. Only their intro is read, death dates are ignored, and generic people (a clothing vendor, a passer-by) are never looked up because no page exists for them. Cached per character, so each one is fetched once ever.")
    public let wikiLookup: Bool = false;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "General")
    @runtimeProperty("ModSettings.displayName", "Debug Log")
    @runtimeProperty("ModSettings.description", "Write a diagnostic log to r6/storages/StreetTalk/streettalk.log - including each NPC's full character card. Off by default; nothing is written at all while off, and conversation text is never logged.")
    public let debugLog: Bool = false;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Connection")
    @runtimeProperty("ModSettings.displayName", "Server")
    @runtimeProperty("ModSettings.description", "Where replies come from. LOCAL servers are 100% private but need a model on your PC and the -no-tls launch option. OpenRouter is a paid cloud service: zero setup beyond an API key and model id in the config file, but your conversations go to their servers.")
    @runtimeProperty("ModSettings.displayValues.LlamaCpp", "llama.cpp (local, port 8080)")
    @runtimeProperty("ModSettings.displayValues.OpenRouter", "OpenRouter (cloud, needs API key)")
    @runtimeProperty("ModSettings.displayValues.Ollama", "Ollama (local, port 11434)")
    @runtimeProperty("ModSettings.displayValues.LMStudio", "LM Studio (local, port 1234)")
    @runtimeProperty("ModSettings.displayValues.KoboldCpp", "KoboldCpp (local, port 5001)")
    @runtimeProperty("ModSettings.displayValues.Custom", "Custom - any OpenAI-compatible server (see config file)")
    public let provider: StProvider = StProvider.LlamaCpp;

    // ------------------------------------------------------------------
    //  Controls. A dropdown of real keys, not a game-action binding: the
    //  interact button already means too many things (the previous build
    //  used secondary interact, and the chat fought every other use of that
    //  button), and keys the game polls for gameplay cannot be reserved from
    //  script anyway - whatever is picked here, the game will also do its own
    //  thing with that key if it binds it.
    // ------------------------------------------------------------------

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Controls")
    @runtimeProperty("ModSettings.displayName", "Talk Key")
    @runtimeProperty("ModSettings.description", "Opens the chat on the NPC you are looking at, and closes it again when the text box is not focused (press Enter on an empty box to step out of the box first). If the game also uses this key, both things happen - pick a free key if that bothers you.")
    @runtimeProperty("ModSettings.displayValues.R", "R")
    @runtimeProperty("ModSettings.displayValues.T", "T")
    @runtimeProperty("ModSettings.displayValues.G", "G")
    @runtimeProperty("ModSettings.displayValues.H", "H")
    @runtimeProperty("ModSettings.displayValues.J", "J")
    @runtimeProperty("ModSettings.displayValues.K", "K")
    @runtimeProperty("ModSettings.displayValues.N", "N")
    @runtimeProperty("ModSettings.displayValues.M", "M")
    @runtimeProperty("ModSettings.displayValues.U", "U")
    @runtimeProperty("ModSettings.displayValues.F3", "F3")
    @runtimeProperty("ModSettings.displayValues.F4", "F4")
    @runtimeProperty("ModSettings.displayValues.Home", "Home")
    @runtimeProperty("ModSettings.displayValues.End", "End")
    @runtimeProperty("ModSettings.displayValues.Delete", "Delete")
    public let openKey: StBindableKey = StBindableKey.R;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Controls")
    @runtimeProperty("ModSettings.displayName", "Reset Key")
    @runtimeProperty("ModSettings.description", "Wipes the current conversation, while the chat is open and the text box is not focused. Keep it different from the Talk Key.")
    @runtimeProperty("ModSettings.displayValues.R", "R")
    @runtimeProperty("ModSettings.displayValues.T", "T")
    @runtimeProperty("ModSettings.displayValues.G", "G")
    @runtimeProperty("ModSettings.displayValues.H", "H")
    @runtimeProperty("ModSettings.displayValues.J", "J")
    @runtimeProperty("ModSettings.displayValues.K", "K")
    @runtimeProperty("ModSettings.displayValues.N", "N")
    @runtimeProperty("ModSettings.displayValues.M", "M")
    @runtimeProperty("ModSettings.displayValues.U", "U")
    @runtimeProperty("ModSettings.displayValues.F3", "F3")
    @runtimeProperty("ModSettings.displayValues.F4", "F4")
    @runtimeProperty("ModSettings.displayValues.Home", "Home")
    @runtimeProperty("ModSettings.displayValues.End", "End")
    @runtimeProperty("ModSettings.displayValues.Delete", "Delete")
    public let resetKey: StBindableKey = StBindableKey.Delete;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Controls")
    @runtimeProperty("ModSettings.displayName", "Undo Key")
    @runtimeProperty("ModSettings.description", "Takes back the last exchange - your message and their reply - while the chat is open and the text box is not focused. The model never sees it again, so a conversation that went somewhere you did not want can be stepped back instead of reloaded.")
    @runtimeProperty("ModSettings.displayValues.R", "R")
    @runtimeProperty("ModSettings.displayValues.T", "T")
    @runtimeProperty("ModSettings.displayValues.G", "G")
    @runtimeProperty("ModSettings.displayValues.H", "H")
    @runtimeProperty("ModSettings.displayValues.J", "J")
    @runtimeProperty("ModSettings.displayValues.K", "K")
    @runtimeProperty("ModSettings.displayValues.N", "N")
    @runtimeProperty("ModSettings.displayValues.M", "M")
    @runtimeProperty("ModSettings.displayValues.U", "U")
    @runtimeProperty("ModSettings.displayValues.F3", "F3")
    @runtimeProperty("ModSettings.displayValues.F4", "F4")
    @runtimeProperty("ModSettings.displayValues.Home", "Home")
    @runtimeProperty("ModSettings.displayValues.End", "End")
    @runtimeProperty("ModSettings.displayValues.Delete", "Delete")
    public let undoKey: StBindableKey = StBindableKey.End;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Conversation")
    @runtimeProperty("ModSettings.displayName", "Reply Length")
    @runtimeProperty("ModSettings.description", "Maximum tokens per reply. Lower is snappier. Spoken lines rarely need more than 120.")
    @runtimeProperty("ModSettings.step", "20")
    @runtimeProperty("ModSettings.min", "40")
    @runtimeProperty("ModSettings.max", "400")
    public let maxTokens: Int32 = 90;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Conversation")
    @runtimeProperty("ModSettings.displayName", "Temperature")
    @runtimeProperty("ModSettings.description", "Higher is more unpredictable. 1.0 suits most character models.")
    @runtimeProperty("ModSettings.step", "0.05")
    @runtimeProperty("ModSettings.min", "0.1")
    @runtimeProperty("ModSettings.max", "2.0")
    public let temperature: Float = 1.0;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Conversation")
    @runtimeProperty("ModSettings.displayName", "Context Size")
    @runtimeProperty("ModSettings.description", "Your model server's context window, in TOKENS (llama.cpp -c, LM Studio context length, Ollama num_ctx). The mod fits as much recent conversation as physically fits and folds anything older into the NPC's memory summary. Full chats are always saved to disk regardless.")
    @runtimeProperty("ModSettings.step", "1024")
    @runtimeProperty("ModSettings.min", "2048")
    @runtimeProperty("ModSettings.max", "32768")
    public let contextSize: Int32 = 8192;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Conversation")
    @runtimeProperty("ModSettings.displayName", "Memory Summaries")
    @runtimeProperty("ModSettings.description", "When a conversation has grown, the model is asked once - when you close the chat - to update what this NPC remembers about you. Old talks survive as memories instead of vanishing off the end of the context window.")
    public let summarize: Bool = true;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Conversation")
    @runtimeProperty("ModSettings.displayName", "NPC Actions")
    @runtimeProperty("ModSettings.description", "Lets NPCs act on what they say: walk with you, step closer or back off, walk away, melt into the crowd, put something down, and move real eddies. They decide from what they say they are doing.")
    public let npcActions: Bool = true;

    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Voice")
    @runtimeProperty("ModSettings.displayName", "Spoken Replies (TTS)")
    @runtimeProperty("ModSettings.description", "NPC replies are spoken aloud, in a cloned voice, from where the NPC is standing. Needs the Audioware mod AND the StreetTalk TTS server running (see README). Text appears immediately either way; the voice follows a few seconds later.")
    public let ttsEnabled: Bool = false;

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

    // A one-shot action dressed as a toggle. Mod Settings has no button type,
    // and no way to list things that did not exist at compile time: it builds
    // its menu by reflecting over declared class fields, and exposes no runtime
    // API for adding options. So a per-conversation list here is impossible -
    // this wipes everyone, and per-NPC reset lives in the chat itself (DELETE).
    // The flag is polled and switched back off, so it reads as a button.
    @runtimeProperty("ModSettings.mod", "Street Talk")
    @runtimeProperty("ModSettings.category", "Memory")
    @runtimeProperty("ModSettings.displayName", "Forget Everyone")
    @runtimeProperty("ModSettings.description", "Erases every NPC's memory of you and every saved conversation. Switch it on to wipe - it turns itself back off once done. There is no undo.")
    public let forgetEveryone: Bool = false;

    // (Test Mode auto-greet was removed along with the driver that implemented
    // it - the DetermineInteractionState wrap it lived in had stopped firing,
    // so the toggle did nothing. A knob that lies is worse than no knob.)


    public static func Get() -> ref<StreetTalkSettings> {
        return GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"StreetTalk.StreetTalkSettings") as StreetTalkSettings;
    }

    public func OpenKeyCode() -> String {
        return StreetTalkSettings.KeyCode(this.openKey);
    }

    public func ResetKeyCode() -> String {
        return StreetTalkSettings.KeyCode(this.resetKey);
    }

    public func OpenKeyLabel() -> String {
        return StreetTalkSettings.KeyLabel(this.openKey);
    }

    public func ResetKeyLabel() -> String {
        return StreetTalkSettings.KeyLabel(this.resetKey);
    }

    public func UndoKeyCode() -> String {
        return StreetTalkSettings.KeyCode(this.undoKey);
    }

    public func UndoKeyLabel() -> String {
        return StreetTalkSettings.KeyLabel(this.undoKey);
    }

    // The EInputKey member name, exactly as Codeware's Input/Key events
    // stringify it. Compared against s"\(event.GetKey())" in the input system.
    public static func KeyCode(k: StBindableKey) -> String {
        switch k {
            case StBindableKey.T: return "IK_T";
            case StBindableKey.G: return "IK_G";
            case StBindableKey.H: return "IK_H";
            case StBindableKey.J: return "IK_J";
            case StBindableKey.K: return "IK_K";
            case StBindableKey.N: return "IK_N";
            case StBindableKey.M: return "IK_M";
            case StBindableKey.U: return "IK_U";
            case StBindableKey.F3: return "IK_F3";
            case StBindableKey.F4: return "IK_F4";
            case StBindableKey.Home: return "IK_Home";
            case StBindableKey.End: return "IK_End";
            case StBindableKey.Delete: return "IK_Delete";
            default: return "IK_R";
        }
    }

    // What the footer and the look-at prompt print for the key.
    public static func KeyLabel(k: StBindableKey) -> String {
        switch k {
            case StBindableKey.T: return "T";
            case StBindableKey.G: return "G";
            case StBindableKey.H: return "H";
            case StBindableKey.J: return "J";
            case StBindableKey.K: return "K";
            case StBindableKey.N: return "N";
            case StBindableKey.M: return "M";
            case StBindableKey.U: return "U";
            case StBindableKey.F3: return "F3";
            case StBindableKey.F4: return "F4";
            case StBindableKey.Home: return "HOME";
            case StBindableKey.End: return "END";
            case StBindableKey.Delete: return "DEL";
            default: return "R";
        }
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
            case StProvider.OpenRouter:
                // https, so no -no-tls launch option involved. Key + model id
                // come from the config file, same fields Custom uses.
                return "https://openrouter.ai/api/v1/chat/completions";
            default:
                return "http://127.0.0.1:8080/v1/chat/completions";
        }
    }
}
