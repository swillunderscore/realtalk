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

// One rendered line of conversation, kept so the visible window can re-render
// when the player scrolls.
public class StUiLine extends IScriptable {
    public let who: String;
    public let text: String;
    public let isPlayer: Bool;
    public let isAction: Bool;   // something they DID, drawn apart from speech
    // TWO KINDS OF ACTION LINE, and the difference is worth seeing. The bright
    // ones are this mod reporting something that HAPPENED in the game - she
    // really is following you, the eddies really moved. The dim ones are the
    // model's own narration, which is writing, not fact: it may describe a
    // shot that the game never fired.
    public let saidByModel: Bool;
}

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
        this.SetFooter(this.PanelFooter());
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
        this.SetFooter(this.TypingFooter());
    }

    private func SetFooter(text: String) -> Void {
        if IsDefined(this.footer) {
            this.footer.SetText(text);
        }
    }

    // While the server forges/warms this character's voice (first meeting),
    // the footer says so - the "what's it doing" indicator.
    private let voicePrep: Bool;

    // "reading up on them" - the background lookup, shown the same way the
    // voice warm-up is, so the panel is never silently busy.
    private let lookup: Bool;

    // V's own line being synthesised - the beat between pressing enter and
    // hearing yourself, which was previously silent with nothing on screen.
    private let voicing: Bool;

    public func SetVoicing(active: Bool) -> Void {
        this.voicing = active;
        this.SetFooter(this.typing ? this.TypingFooter() : this.PanelFooter());
    }

    public func SetLookup(active: Bool) -> Void {
        this.lookup = active;
        this.SetFooter(this.typing ? this.TypingFooter() : this.PanelFooter());
    }

    public func SetVoicePrep(active: Bool) -> Void {
        this.voicePrep = active;
        this.SetFooter(this.typing ? this.TypingFooter() : this.PanelFooter());
    }

    // Footer text is built from the settings, so rebinding a key in Mod
    // Settings is immediately reflected the next time the footer changes.
    private func TypingFooter() -> String {
        let t: String = "[ENTER] send   (empty = step out)";
        if this.voicePrep {
            t += "   · learning their voice...";
        }
        if this.lookup {
            t += "   · reading up on them...";
        }
        if this.voicing {
            t += "   · voicing your line...";
        }
        return t;
    }

    private func PanelFooter() -> String {
        let s = StreetTalkSettings.Get();
        let t: String;
        if !IsDefined(s) {
            t = "[ENTER] type";
        } else {
            t = s"[ENTER] type   [\(s.OpenKeyLabel())] close   [\(s.ResetKeyLabel())] reset   [\(s.UndoKeyLabel())] undo   [ARROWS] scroll";
        }
        if this.voicePrep {
            t += "   · learning their voice...";
        }
        if this.lookup {
            t += "   · reading up on them...";
        }
        if this.voicing {
            t += "   · voicing your line...";
        }
        return t;
    }

    private let speakerName: String;

    public func Show(speakerName: String) -> Void {
        if this.open {
            return;
        }
        this.speakerName = speakerName;
        // The look-at prompt has no business sitting under the open panel.
        this.HideHint();

        let hud = this.GetHudRoot();
        if !IsDefined(hud) {
            StLog("HUD root not found - cannot draw conversation UI");
            return;
        }

        // LEFT side, vertically centred. It sat on the right originally and
        // long replies grew straight over the quest tracker and minimap - the
        // left edge has nothing under it that matters mid-conversation.
        // (inkEAnchor.CenterLeft is what the game anchors its own co-op chat
        // box with - cpoHudRoot.swift:27.)
        let panel = new inkVerticalPanel();
        panel.SetName(n"streettalk_panel");
        panel.SetAnchor(inkEAnchor.CenterLeft);
        panel.SetAnchorPoint(new Vector2(0.0, 0.5));
        panel.SetHAlign(inkEHorizontalAlign.Left);
        panel.SetVAlign(inkEVerticalAlign.Center);
        // Nudged UP from dead centre: the panel grows downward as it fills,
        // and at full height it was reaching the bottom-left HUD cluster
        // (health, quickslots) - field report. With the row-budgeted window
        // capping the height, this clears it.
        panel.SetMargin(new inkMargin(80.0, 0.0, 0.0, 140.0));
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
        title.SetHAlign(inkEHorizontalAlign.Left);
        title.SetTintColor(new HDRColor(0.37, 0.90, 0.93, 1.0));
        title.Reparent(panel);

        let lines = new inkVerticalPanel();
        lines.SetName(n"streettalk_lines");
        lines.SetFitToContent(true);
        lines.SetHAlign(inkEHorizontalAlign.Left);
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
        foot.SetText(this.TypingFooter());
        foot.SetFontFamily("base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily");
        foot.SetFontStyle(n"Regular");
        foot.SetFontSize(24);
        foot.SetHAlign(inkEHorizontalAlign.Left);
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
        // Fresh render - without this, reopening replays on top of the
        // transcript kept from last time and every line doubles.
        this.ClearLines();
        let i: Int32 = 0;
        while i < ArraySize(history) {
            let m = history[i];
            if Equals(m.role, "action") {
                let done = new StUiLine();
                done.who = "";
                done.text = m.content;
                done.isAction = true;
                ArrayPush(this.transcript, done);
            } else {
              if NotEquals(m.role, "system") {
                // PushLine, not AddLine: AddLine re-renders the window every
                // call, which would turn a long loaded history into hundreds
                // of widget rebuilds on open. Push everything, render once.
                // SPEECH ONLY on screen. History deliberately keeps each
                // reply WITH its action beat, because that is what teaches the
                // model to keep writing beats - but replaying it raw put that
                // narration into the panel the moment a chat was reopened
                // (field report). The panel shows what was said; the beat is
                // for the model and for the amber action lines.
                let said: String = StActions.CleanProse(m.content);
                if StActions.IsBlank(said) && Equals(m.role, "assistant") {
                    // All narration, no speech. Live it shows as an action
                    // line; a reopened chat should not show a blank "THEM:".
                    let beat = new StUiLine();
                    beat.who = "";
                    beat.text = StActions.ExtractDirection(m.content);
                    beat.isAction = true;
                    beat.saidByModel = true;
                    ArrayPush(this.transcript, beat);
                } else {
                    this.PushLine(Equals(m.role, "user") ? "V" : "THEM",
                                  said, Equals(m.role, "user"));
                }
              }
            }
            i += 1;
        }
        this.scrollOffset = 0;
        this.RenderWindow();
    }

    // ---- transcript + scrolling ----
    // The UI keeps its own copy of the visible conversation and renders a
    // WINDOW of it: the newest 8 lines, shifted by scrollOffset. Arrow keys
    // move the window while the text box is unfocused. Mouse wheel is
    // deliberately NOT used - the game switches weapons on wheel input and a
    // raw-key layer cannot stop that.
    private let transcript: array<ref<StUiLine>>;
    private let scrollOffset: Int32;

    private func PushLine(who: String, text: String, isPlayer: Bool) -> Void {
        let entry = new StUiLine();
        entry.who = who;
        entry.text = text;
        entry.isPlayer = isPlayer;
        ArrayPush(this.transcript, entry);
        // SCROLLBACK cap, stated plainly: the panel can scroll 500 lines into
        // the past, because each line is a live widget when rendered and the
        // window re-renders on every scroll step. The conversation itself is
        // stored in full on disk regardless of this.
        if ArraySize(this.transcript) > 500 {
            ArrayRemove(this.transcript, this.transcript[0]);
        }
    }

    public func AddLine(who: String, text: String, isPlayer: Bool) -> Void {
        if !this.open {
            return;
        }
        this.PushLine(who, text, isPlayer);
        // A new line always snaps the view back to the newest message.
        this.scrollOffset = 0;
        this.measureTries = 0;
        this.RenderWindow();
    }

    // Something the NPC actually did, shown as its own line. Actions used to
    // be invisible - a reply that was only a tag printed nothing at all, so
    // following or attacking just happened with no acknowledgement on screen.
    public func AddAction(text: String, opt saidByModel: Bool) -> Void {
        if !this.open {
            return;
        }
        let entry = new StUiLine();
        entry.who = "";
        entry.text = text;
        entry.isAction = true;
        entry.saidByModel = saidByModel;
        ArrayPush(this.transcript, entry);
        if ArraySize(this.transcript) > 500 {
            ArrayRemove(this.transcript, this.transcript[0]);
        }
        this.scrollOffset = 0;
        this.measureTries = 0;
        this.RenderWindow();
    }

    // Streamed replies: grow the newest line in place instead of appending.
    public func UpdateLastLine(who: String, text: String) -> Void {
        if !this.open {
            return;
        }
        let n: Int32 = ArraySize(this.transcript);
        if n > 0 && Equals(this.transcript[n - 1].who, who) {
            this.transcript[n - 1].text = text;
            this.scrollOffset = 0;
            this.RenderWindow();
        } else {
            this.AddLine(who, text, false);
        }
    }

    // +1 = one line older, -1 = one line newer. The cap is "all but one
    // entry": the visible window is now sized in rows, so an entry count
    // could no longer tell us where the top is.
    public func Scroll(delta: Int32) -> Void {
        let maxOffset: Int32 = ArraySize(this.transcript) - 1;
        if maxOffset < 0 {
            maxOffset = 0;
        }
        this.scrollOffset += delta;
        if this.scrollOffset < 0 {
            this.scrollOffset = 0;
        }
        if this.scrollOffset > maxOffset {
            this.scrollOffset = maxOffset;
        }
        this.RenderWindow();
    }

    // How many WRAPPED ROWS an entry will take. The character-count estimate
    // is only a starting guess - the panel MEASURES itself after every render
    // (Measure below) and adjusts the budget, which is why the visible height
    // stays put instead of swinging with message length.
    private func RowsFor(entry: ref<StUiLine>) -> Int32 {
        return (StrLen(entry.who) + 2 + StrLen(entry.text)) / 46 + 1;
    }

    // ------------------------------------------------------------------
    //  SELF-MEASURING WINDOW. Estimating wrapped rows from character counts
    //  was never going to be consistent - a line of capitals is wider than a
    //  line of lowercase, and one long reply could swallow the panel. So after
    //  each render the panel asks how tall it actually became
    //  (inkWidget.GetDesiredSize, abstractWidgets.swift:131) and moves the row
    //  budget one step until it fits the target height. Converges in a render
    //  or two and then holds, so the chat is the same size whoever is talking.
    // ------------------------------------------------------------------
    private let visibleRows: Int32 = 10;
    private let measureTries: Int32;

    public func Measure() -> Void {
        if !this.open || !IsDefined(this.log) {
            return;
        }
        let h: Float = this.log.GetDesiredSize().Y;
        if h <= 0.0 {
            return;   // not laid out yet
        }
        this.measureTries += 1;
        if this.measureTries > 6 {
            return;   // settled, or oscillating - leave it alone
        }
        let changed: Bool = false;
        if h > 430.0 && this.visibleRows > 3 {
            this.visibleRows -= 1;
            changed = true;
        } else {
            // Room to spare AND something older to show.
            if h < 300.0 && this.visibleRows < 16
                && ArraySize(this.transcript) > this.shownCount {
                this.visibleRows += 1;
                changed = true;
            }
        }
        if changed {
            this.RenderWindow();
        }
    }

    private let shownCount: Int32;

    private func RenderWindow() -> Void {
        if !this.open || !IsDefined(this.log) {
            return;
        }
        while this.log.GetNumChildren() > 0 {
            this.log.RemoveChild(this.log.GetWidget(0));
        }
        let total: Int32 = ArraySize(this.transcript);
        let last: Int32 = total - this.scrollOffset;
        if last < 1 {
            return;
        }
        // BUDGET IN ROWS, NOT ENTRIES, walked backwards from the newest. The
        // old version showed "the last 8 entries", but a long reply wraps to
        // five rows - so eight entries could be thirty rows, overflowing the
        // panel and pushing the newest line out of sight while the OLDEST
        // stayed on screen. That is the "stuck on page 1" bug: the newest
        // message must always be the one you can see.
        let rows: Int32 = 0;
        let first: Int32 = last;
        while first > 0 {
            let r: Int32 = this.RowsFor(this.transcript[first - 1]);
            if first < last && rows + r > this.visibleRows {
                break;
            }
            rows += r;
            first -= 1;
        }
        let i: Int32 = first;
        while i < last {
            this.BuildLineWidget(this.transcript[i]);
            i += 1;
        }
        this.shownCount = last - first;
        // Check the real height once the layout has caught up.
        let m = new StUiMeasureTick();
        m.ui = this;
        GameInstance.GetDelaySystem(GetGameInstance()).DelayCallback(m, 0.08, false);
    }

    private func BuildLineWidget(entry: ref<StUiLine>) -> Void {
        let line = new inkText();
        line.SetName(n"line");
        if entry.isAction {
            // Attributed, like anything else they do: it is Blue Moon who
            // started following you, and it reads as part of her turn rather
            // than a stray system note.
            line.SetText(StrLen(this.speakerName) > 0
                ? s"\(this.speakerName): * \(entry.text) *"
                : s"* \(entry.text) *");
        } else {
            // "THEM" is a placeholder the code uses; on screen it should be
            // whoever you are actually talking to.
            let who: String = entry.who;
            if Equals(who, "THEM") && StrLen(this.speakerName) > 0 {
                who = this.speakerName;
            }
            line.SetText(s"\(who): \(entry.text)");
        }
        line.SetFontFamily("base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily");
        line.SetFontStyle(n"Regular");
        line.SetFontSize(30);
        line.SetHAlign(inkEHorizontalAlign.Left);
        line.SetWrapping(true, 700.0, textWrappingPolicy.Default);
        // V in muted white, the NPC in cyan, so the two are readable apart
        // without needing a background plate behind them.
        if entry.isAction {
            // Amber and italic, in the *asterisks* convention roleplay chats
            // already use - unmistakably not speech.
            line.SetFontStyle(n"Italic");
            // Bright amber: the game did this. Dimmer: the model wrote it.
            line.SetTintColor(entry.saidByModel
                ? new HDRColor(0.62, 0.50, 0.32, 1.0)
                : new HDRColor(1.00, 0.72, 0.25, 1.0));
        } else {
            if entry.isPlayer {
                line.SetTintColor(new HDRColor(0.85, 0.85, 0.85, 1.0));
            } else {
                line.SetTintColor(new HDRColor(0.37, 0.90, 0.93, 1.0));
            }
        }
        line.Reparent(this.log);
    }

    public func LineCount() -> Int32 {
        return ArraySize(this.transcript);
    }

    // (UndoLines lived here. It edited the visible transcript by itself,
    // which is precisely how the screen and the history stopped agreeing.
    // The panel is now always a rendering of the history - see Replay.)

    // Wipe the visible transcript without closing the panel.
    public func ClearLines() -> Void {
        ArrayClear(this.transcript);
        this.scrollOffset = 0;
        if !IsDefined(this.log) {
            return;
        }
        while this.log.GetNumChildren() > 0 {
            this.log.RemoveChild(this.log.GetWidget(0));
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

        // Give the NPC their interaction back.
        let input = GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"StreetTalk.StreetTalkInputSystem") as StreetTalkInputSystem;
        if IsDefined(input) {
            input.RestoreInteraction();
        }

        // Flush memory on close so a session ending unexpectedly does not lose
        // everything recorded during it.
        let memory = StMemory.Get();
        if IsDefined(memory) {
            memory.Save();
        }

        // Persist the conversation for next session.
        let chat = StChat.Get();
        if IsDefined(chat) {
            chat.SaveActive();
            chat.OnChatClosed();
        }

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

    // ---- the look-at prompt ----
    // Drawn by the mod, not through the game's input-hint rail: the rail can
    // only render icons for game ACTIONS (InputHintData.action is what the
    // icon lookup keys off), and the talk key is a raw, configurable key.
    // The keycap is the GAME'S OWN art - icons_keyboard.inkatlas, the same
    // atlas the real hint rail draws from; every bindable key was verified
    // to have a part (kb_r ... kb_delete). Right side of the screen, clear
    // of the crosshair, styled like a native prompt.
    private let hint: wref<inkHorizontalPanel>;

    public func ShowHint(keyLabel: String) -> Void {
        if IsDefined(this.hint) {
            return;
        }
        let hud = this.GetHudRoot();
        if !IsDefined(hud) {
            return;
        }
        let row = new inkHorizontalPanel();
        row.SetName(n"streettalk_hint");
        row.SetAnchor(inkEAnchor.CenterRight);
        row.SetAnchorPoint(new Vector2(1.0, 0.5));
        row.SetTranslation(new Vector2(-300.0, 60.0));
        let icon = new inkImage();
        icon.SetName(n"key");
        icon.SetAtlasResource(r"base\\gameplay\\gui\\common\\input\\icons_keyboard.inkatlas");
        icon.SetTexturePart(StringToName(s"kb_\(StrLower(keyLabel))"));
        icon.SetSize(new Vector2(40.0, 40.0));
        icon.SetFitToContent(false);
        // The HUD's cyan, same tint the chat panel uses - "blue like
        // everything else", not white (owner feedback).
        icon.SetTintColor(new HDRColor(0.37, 0.90, 0.93, 1.0));
        icon.Reparent(row);
        let t = new inkText();
        t.SetName(n"label");
        t.SetText("TALK");
        t.SetFontFamily("base\\gameplay\\gui\\fonts\\raj\\raj.inkfontfamily");
        t.SetFontStyle(n"Medium");
        t.SetFontSize(26);
        t.SetMargin(new inkMargin(8.0, 8.0, 0.0, 0.0));
        t.SetTintColor(new HDRColor(0.37, 0.90, 0.93, 1.0));
        t.Reparent(row);
        row.Reparent(hud);
        this.hint = row;
    }

    public func HideHint() -> Void {
        if !IsDefined(this.hint) {
            return;
        }
        let parent = this.hint.GetParentWidget() as inkCompoundWidget;
        if IsDefined(parent) {
            parent.RemoveChild(this.hint);
        }
        this.hint = null;
    }

    public static func Get() -> ref<StreetTalkUI> {
        return GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"StreetTalk.StreetTalkUI") as StreetTalkUI;
    }
}


// Reads the panel's real height a beat after it is drawn, so the row budget
// can settle on a consistent size instead of trusting a character-count guess.
public class StUiMeasureTick extends DelayCallback {
    public let ui: wref<StreetTalkUI>;
    public func Call() -> Void {
        if IsDefined(this.ui) {
            this.ui.Measure();
        }
    }
}
