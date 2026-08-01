// ============================================================================
//  STREET TALK - conversation UI
// ============================================================================
//
//  A panel anchored to the RIGHT side of the HUD, deliberately unlike the
//  phone's texting window: no red backing plate, no phone chrome, just text
//  over the world with a thin input line. This is a face-to-face conversation,
//  not a text message, and it should not read as one.
//
//  WHY THIS APPROACH:
//    Adding an option to the NPC's own interaction list needs a hook we never
//    found. But the UI never needed it. Generative Texting draws its chat with
//    plain ink widgets on the HUD layer and captures typing with Codeware's
//    HubTextInput, and that works today on this install - so we use the same
//    proven pieces and skip the interaction system entirely.
//
//    Two earlier attempts are recorded in StreetTalkProbe.reds so they are not
//    retried: a blueline pushed onto the UIInteractions blackboard (the game
//    overwrites it continuously), and binding to one_click_confirm (that is the
//    dialogue-select key, so it fired while the player was choosing lines).
// ============================================================================

module StreetTalk

import Codeware.UI.*

public class StreetTalkUI extends ScriptableSystem {

    private let root: wref<inkVerticalPanel>;
    private let log: wref<inkVerticalPanel>;
    private let input: wref<HubTextInput>;
    private let open: Bool;
    private let typing: Bool;   // is the cursor in the text box?
    private let lines: Int32;
    private let footer: wref<inkText>;

    private func GetHudRoot() -> wref<inkCompoundWidget> {
        let inkSystem = GameInstance.GetInkSystem();
        if !IsDefined(inkSystem) {
            return null;
        }
        let layer = inkSystem.GetLayer(n"inkHUDLayer");
        if !IsDefined(layer) {
            return null;
        }
        let vw = layer.GetVirtualWindow();
        if !IsDefined(vw) {
            return null;
        }
        let r = vw.GetWidget(0) as inkCompoundWidget;
        if !IsDefined(r) {
            r = vw.GetWidgetByPathName(n"Root") as inkCompoundWidget;
        }
        return r;
    }

    public func IsOpen() -> Bool {
        return this.open;
    }

    public func IsTyping() -> Bool {
        return this.typing;
    }

    // Release the cursor from the text box without closing the panel. Typed
    // text is preserved - stepping out of the box should never destroy what
    // you wrote.
    public func Unfocus() -> Void {
        if !this.typing {
            return;
        }
        this.typing = false;
        let inkSystem = GameInstance.GetInkSystem();
        if IsDefined(inkSystem) {
            inkSystem.SetFocus(null);
        }
        this.SetFooter("[TAB] close   [ENTER] type again");
    }

    public func Refocus() -> Void {
        if this.typing || !IsDefined(this.input) {
            return;
        }
        this.typing = true;
        let inkSystem = GameInstance.GetInkSystem();
        if IsDefined(inkSystem) {
            inkSystem.SetFocus(this.input.GetRootWidget());
        }
        this.SetFooter("[ENTER] send   [ENTER] empty = step out   [TAB] close");
    }

    private func SetFooter(text: String) -> Void {
        if IsDefined(this.footer) {
            this.footer.SetText(text);
        }
    }

    public func Show(speakerName: String) -> Void {
        if this.open {
            return;
        }
        let hud = this.GetHudRoot();
        if !IsDefined(hud) {
            StLog("HUD root not found - cannot draw conversation UI");
            return;
        }

        // Right side, vertically centred-ish. Margin right of 80 keeps it off
        // the screen edge without colliding with the quest tracker, which sits
        // top-right at margin 110.
        let panel = new inkVerticalPanel();
        panel.SetName(n"streettalk_panel");
        panel.SetAnchor(inkEAnchor.CenterRight);
        panel.SetAnchorPoint(new Vector2(1.0, 0.5));
        panel.SetHAlign(inkEHorizontalAlign.Right);
        panel.SetVAlign(inkEVerticalAlign.Center);
        panel.SetMargin(new inkMargin(0.0, 0.0, 80.0, 0.0));
        panel.SetFitToContent(true);
        panel.SetChildMargin(new inkMargin(0.0, 4.0, 0.0, 4.0));
        panel.Reparent(hud);
        this.root = panel;

        // Who you're talking to. Cyan, matching the game's interaction accents
        // rather than the phone's red.
        let title = new inkText();
        title.SetName(n"speaker");
        title.SetText(speakerName);
        title.SetFontFamily("base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily");
        title.SetFontStyle(n"Medium");
        title.SetFontSize(38);
        title.SetHAlign(inkEHorizontalAlign.Right);
        title.SetTintColor(new HDRColor(0.37, 0.90, 0.93, 1.0));
        title.Reparent(panel);

        let lines = new inkVerticalPanel();
        lines.SetName(n"streettalk_lines");
        lines.SetFitToContent(true);
        lines.SetHAlign(inkEHorizontalAlign.Right);
        lines.SetChildMargin(new inkMargin(0.0, 2.0, 0.0, 2.0));
        lines.Reparent(panel);
        this.log = lines;

        // NOTE: an earlier version pushed UIGameContext.ModalPopup here to try
        // to suppress gameplay input. It did not work - Enter still selected
        // hidden dialogue options and C still crouched. Input is now handled at
        // the raw-key layer (see StreetTalkInput.reds), which is how the mods
        // that actually work on this install do it, so no context push is
        // needed or wanted.

        this.open = true;
        this.typing = true;
        this.lines = 0;
        this.BuildInput(panel);

        // Footer telling you how to get out. The original build had no exit
        // affordance at all - the only way out was Escape, which opens the
        // game menu instead of closing the chat.
        let foot = new inkText();
        foot.SetName(n"streettalk_footer");
        foot.SetText("[ENTER] send   [ENTER] empty = step out   [TAB] close");
        foot.SetFontFamily("base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily");
        foot.SetFontStyle(n"Regular");
        foot.SetFontSize(24);
        foot.SetHAlign(inkEHorizontalAlign.Right);
        foot.SetTintColor(new HDRColor(0.55, 0.55, 0.55, 1.0));
        foot.Reparent(panel);
        this.footer = foot;
    }

    private func BuildInput(parent: wref<inkCompoundWidget>) -> Void {
        let field = HubTextInput.Create();
        field.SetText("");
        field.Reparent(parent);
        this.input = field;

        // Focus is what routes keystrokes into the widget instead of the game.
        let inkSystem = GameInstance.GetInkSystem();
        if IsDefined(inkSystem) {
            inkSystem.SetFocus(field.GetRootWidget());
        }
    }

    // Redraw a conversation that already exists. The transcript lives in
    // StChat, not the UI, so closing the panel never lost it - but the panel
    // was rebuilt empty on reopen, which made it LOOK reset. This replays it.
    public func Replay(history: array<ref<StChatMessageDTO>>) -> Void {
        let i: Int32 = 0;
        while i < ArraySize(history) {
            let m = history[i];
            if NotEquals(m.role, "system") {
                this.AddLine(Equals(m.role, "user") ? "V" : "THEM", m.content, Equals(m.role, "user"));
            }
            i += 1;
        }
    }

    public func AddLine(who: String, text: String, isPlayer: Bool) -> Void {
        if !this.open || !IsDefined(this.log) {
            return;
        }

        let line = new inkText();
        line.SetName(n"line");
        line.SetText(s"\(who): \(text)");
        line.SetFontFamily("base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily");
        line.SetFontStyle(n"Regular");
        line.SetFontSize(30);
        line.SetHAlign(inkEHorizontalAlign.Right);
        line.SetWrapping(true, 700.0, textWrappingPolicy.Default);
        // V in muted white, the NPC in cyan, so the two are readable apart
        // without needing a background plate behind them.
        if isPlayer {
            line.SetTintColor(new HDRColor(0.85, 0.85, 0.85, 1.0));
        } else {
            line.SetTintColor(new HDRColor(0.37, 0.90, 0.93, 1.0));
        }
        line.Reparent(this.log);

        // Keep the panel from growing forever. Older lines drop off the top;
        // the conversation itself is still intact in StChat's history.
        this.lines += 1;
        if this.lines > 8 {
            this.log.RemoveChild(this.log.GetWidget(0));
            this.lines -= 1;
        }
    }

    public func GetTyped() -> String {
        if !IsDefined(this.input) {
            return "";
        }
        return this.input.GetText();
    }

    public func ClearTyped() -> Void {
        if IsDefined(this.input) {
            this.input.SetText("");
        }
    }

    public func Hide() -> Void {
        if !this.open {
            return;
        }
        this.open = false;

        let inkSystem = GameInstance.GetInkSystem();
        if IsDefined(inkSystem) {
            inkSystem.SetFocus(null);
        }
        if IsDefined(this.root) {
            let parent = this.root.GetParentWidget() as inkCompoundWidget;
            if IsDefined(parent) {
                parent.RemoveChild(this.root);
            }
        }
        this.typing = false;
        this.root = null;
        this.log = null;
        this.input = null;
        this.footer = null;
        this.lines = 0;
    }

    // The right-side [ TALK ] hint was removed. It existed only because there
    // was no way to discover the keybind; now that Talk is a real entry in the
    // NPC's interaction list, a floating label on the opposite side of the
    // screen is just clutter competing with the thing it duplicates.
    public func HideHint() -> Void {}
    public func ShowHint(label: String) -> Void {}

    public static func Get() -> ref<StreetTalkUI> {
        return GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"StreetTalk.StreetTalkUI") as StreetTalkUI;
    }
}
