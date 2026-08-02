// ============================================================================
//  STREET TALK - input
// ============================================================================
//
//  REWRITTEN to match how Generative Texting does it, after three failed
//  attempts at the game-action layer.
//
//  WHAT WAS WRONG BEFORE:
//    A PlayerPuppet input listener receiving ListenerActions, with
//    ConsumeSingleAction, and later PushGameContext(ModalPopup) on top. None of
//    it worked. Enter still picked hidden dialogue options and C still
//    crouched, because game ACTIONS are dispatched on a path that listener does
//    not gate - consuming there stops neither the dialogue system nor movement.
//
//  WHAT WORKS:
//    Codeware's CallbackSystem delivers RAW key events on "Input/Key", a
//    different layer entirely from game actions. Read the key, gate everything
//    on our own typing flag, and the game never sees a competing binding.
//    This is the pattern Generative Texting uses and it demonstrably works on
//    this install.
//
//  Keys: R opens on a talkable NPC, ENTER sends (or steps out when empty),
//        C closes when not typing.
// ============================================================================

module RealTalk

public class RealTalkInputSystem extends ScriptableSystem {

    private let callbackSystem: wref<CallbackSystem>;
    public let typing: Bool;

    private func OnAttach() -> Void {
        this.callbackSystem = GameInstance.GetCallbackSystem();
        if IsDefined(this.callbackSystem) {
            this.callbackSystem.RegisterCallback(n"Input/Key", this, n"OnKeyInput", true);
        }
    }

    private func OnDetach() -> Void {
        if IsDefined(this.callbackSystem) {
            this.callbackSystem.UnregisterCallback(n"Input/Key", this, n"OnKeyInput");
        }
    }

    private cb func OnKeyInput(event: ref<KeyInputEvent>) -> Void {
        // Press only, or every key fires twice (press and release).
        if NotEquals(s"\(event.GetAction())", "IACT_Press") {
            return;
        }

        let settings = RealTalkSettings.Get();
        if !IsDefined(settings) || !settings.enabled {
            return;
        }
        let ui = RealTalkUI.Get();
        if !IsDefined(ui) {
            return;
        }

        let key: String = s"\(event.GetKey())";

        // ---- typing: ENTER sends, or steps out when the box is empty ----
        if this.typing {
            if Equals(key, "IK_Enter") {
                let text: String = ui.GetTyped();
                if StrLen(text) == 0 {
                    this.typing = false;
                    ui.Unfocus();
                    return;
                }
                let chat = StChat.Get();
                if IsDefined(chat) && !chat.IsBusy() {
                    ui.AddLine("V", text, true);
                    ui.ClearTyped();
                    chat.Send(text);
                }
            }
            // Everything else while typing belongs to the text field.
            return;
        }

        // ---- open but not typing: C closes, ENTER returns to the box ----
        if ui.IsOpen() {
            // TAB, not C. C is crouch, and raw-key handling does not stop the
            // game seeing the same press - so the only reliable fix is to pick
            // a key gameplay does not bind.
            if Equals(key, "IK_Tab") {
                ui.Hide();
                return;
            }
            if Equals(key, "IK_Enter") {
                this.typing = true;
                ui.Refocus();
            }
            return;
        }

        // No open key. Talk is a real entry in the NPC's interaction list
        // (see RealTalkAction.reds) - selecting it takes the player out of
        // dialogue, which is what makes the whole input problem disappear.
    }

    // Called by the action handler when the panel opens from the dialogue list.
    public static func SetTyping(value: Bool) -> Void {
        let sys = GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"RealTalk.RealTalkInputSystem") as RealTalkInputSystem;
        if IsDefined(sys) {
            sys.typing = value;
        }
    }
}
