// ============================================================================
//  STREET TALK - overheard dialogue
// ============================================================================
//
//  The game's OWN dialogue becomes the opening of your conversation.
//
//  Press F on a pedestrian, they snap "What do you want?" - and then you open
//  the chat and answer THAT, instead of starting from nothing. Same for real
//  dialogue scenes: the option you picked shows up as your line, theirs as
//  theirs, and the model continues from where the game left off.
//
//  HOW - and why this is the THIRD design, with the two dead ends recorded so
//  nobody repeats them:
//    1. @wrapMethod(BaseSubtitlesGameController) ShowDialogLines - captured
//       nothing. Never fired.
//    2. A listener on UIGameData.ShowDialogLine via the BlackboardSystem -
//       registered fine and received nothing ("0 lines buffered"), because the
//       subtitle controllers read GetUIBlackboard(), a UI-local instance, NOT
//       the global blackboard of the same definition.
//    3. THIS: wrap SetLineData on the two CONCRETE line controllers -
//       SubtitleLineLogicController (dialogue scenes, subtitlesControllers
//       .swift:131) and ChatterLineLogicController (barks and street chatter,
//       chattersControllers.swift:395). Both OVERRIDE the base method, which is
//       exactly why wrapping the base class caught neither. This is the last
//       step before the words hit the screen: if a subtitle is visible, it
//       passed through here.
//
//  It also lives in the HINT POLLER's system rather than a system of its own.
//  This codebase has already been burned once by a standalone ScriptableSystem
//  that silently never instantiated (see the dialogue-suppression note in
//  RealTalkInput.reds); the poller provably runs, so the capture rides it.
//
//  Each line carries the speaker as a live GameObject, so matching them to the
//  NPC in front of you is an entity-id comparison, not a name-string guess.
// ============================================================================

module RealTalk

public class StOverheardLine extends IScriptable {
    public let speakerHash: Uint64;   // EntityID.ToHash of the speaker
    public let speakerName: String;   // the game's own label, matched as a
                                      // fallback when entity ids do not line up
    public let isPlayer: Bool;
    public let text: String;
    public let at: Float;             // engine seconds, for staleness
}

// One capture point per concrete controller. wrappedMethod first - the game's
// subtitle must never wait on our bookkeeping.
@wrapMethod(SubtitleLineLogicController)
public func SetLineData(const lineData: script_ref<scnDialogLineData>) -> Void {
    wrappedMethod(lineData);
    StOverheardSink.Note(Deref(lineData));
    StOverheardSink.HideIfChatting(this.GetRootWidget(), Deref(lineData));
}

@wrapMethod(ChatterLineLogicController)
public func SetLineData(const lineData: script_ref<scnDialogLineData>) -> Void {
    wrappedMethod(lineData);
    StOverheardSink.Note(Deref(lineData));
    StOverheardSink.HideIfChatting(this.GetRootWidget(), Deref(lineData));
}

// Hands the line to the poller system, which owns the buffer.
public class StOverheardSink {

    // SUBTITLES TOO, not just the audio. Gagging PlayVoiceOver stopped the
    // NPC being heard, but the game still printed her scripted line across
    // the bottom of the screen (field report: "she was silent, i just meant
    // the subtitle"). The line widget is right here, so it gets hidden -
    // only for the person you are talking to, and only while the chat is
    // open. Every other subtitle in the game renders normally.
    public static func HideIfChatting(root: wref<inkWidget>, line: scnDialogLineData) -> Void {
        if !IsDefined(root) {
            return;
        }
        let chat = StChat.Get();
        let hide: Bool = IsDefined(chat) && IsDefined(line.speaker)
            && chat.IsChattingWith(line.speaker);
        // Set BOTH ways: these controllers are pooled and reused, so a widget
        // hidden for one line would stay hidden for the next.
        root.SetVisible(!hide);
        if hide {
            StLog("subtitle hidden during chat");
        }
    }

    public static func Note(line: scnDialogLineData) -> Void {
        let sys = GameInstance.GetScriptableSystemsContainer(GetGameInstance())
            .Get(n"RealTalk.RealTalkHintSystem") as RealTalkHintSystem;
        if IsDefined(sys) {
            sys.NoteOverheard(line);
        }
    }
}
