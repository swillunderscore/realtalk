// ============================================================================
//  STREET TALK - keeping the dialogue picker closed
// ============================================================================
//
//  The suppression itself (park the choice hubs, write an empty list, restore
//  on close) lives in RealTalkInputSystem - it used to be a separate
//  ScriptableSystem here, and that system never instantiated. The session log
//  proved it: the panel opened and "dialogue suppressed" never appeared,
//  because Get() returned null and an IsDefined guard skipped everything
//  without a word. Rule applied since: a missing system is LOGGED, never
//  silently tolerated.
//
//  This file keeps only the render-side half: the game rewrites the
//  UIInteractions blackboard continuously, so a single empty write would be
//  overwritten almost immediately. OnDialogsData on the base controller is
//  where that data enters the UI (it sets m_AreDialogsOpen, forwards to
//  UpdateDialogsData and triggers the render - interactionUIBase.swift:63);
//  handing it an empty struct while the panel is open shuts all of that down
//  for every subclass, and passes through untouched the rest of the time.
//
//  HISTORY, so none of it is retried:
//    - PushGameContext(ModalPopup): hid the widget, selection still worked.
//    - Consuming from an unnamed-registration listener: subscribed to nothing,
//      received nothing, proved nothing. Fixed version lives in
//      RealTalkInput.reds (RealTalkActionGuard).
//    - A dialogue exit API: does not exist. Checked the full decompiled tree.
//    - SceneSystemInterface: fast-forward, rewind and camera control only -
//      nothing that blocks or clears choices (orphans.swift:32214 area).
// ============================================================================

module RealTalk

@wrapMethod(InteractionUIBase)
protected cb func OnDialogsData(value: Variant) -> Bool {
    let sys = GameInstance.GetScriptableSystemsContainer(GetGameInstance())
        .Get(n"RealTalk.RealTalkInputSystem") as RealTalkInputSystem;
    if IsDefined(sys) && sys.IsSuppressing() {
        let empty: DialogChoiceHubs;
        return wrappedMethod(ToVariant(empty));
    }
    return wrappedMethod(value);
}
