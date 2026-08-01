// ============================================================================
//  STREET TALK - spoken replies
// ============================================================================
//
//  HOW IT WORKS, end to end:
//    1. A reply arrives; StChat.MaybeSpeak POSTs { text, voice, slot } to the
//       local TTS server (server/streettalk-tts.py, port 8082).
//    2. The server synthesises the line in the NPC's cloned voice and writes
//       it over r6/audioware/StreetTalk/slots/slot_<N>.wav, replying only
//       when the file is fully written (atomic rename server-side).
//    3. This class plays that slot THROUGH AUDIOWARE, spatialised at the
//       NPC's position.
//
//  WHY OVERWRITTEN SLOT FILES WORK: the manifest registers each slot with
//  usage: on-demand, which Audioware documents as "loaded all-at-once each
//  time on-demand, and never kept around" - the file is read from disk on
//  every play, so each play gets whatever the TTS server last wrote.
//  (SETTINGS page of the Audioware book; the overwrite pattern itself is the
//  one thing docs don't state outright, so if voices ever repeat stale lines,
//  this is the assumption that broke.)
//
//  API verified against the INSTALLED Audioware, not just docs (Ext.reds):
//    RegisterEmitter(entityID, tagName, opt name, opt settings) -> Bool
//    IsRegisteredEmitter(entityID, opt tagName) -> Bool
//    PlayOnEmitter(eventName, entityID, tagName)
//
//  Audioware is OPTIONAL: everything here is gated on @if(ModuleExists) - the
//  pattern Responsive NPCs and others ship with - so users without it still
//  compile and just get text.
// ============================================================================

module StreetTalk

@if(ModuleExists("Audioware"))
import Audioware.*

public class StVoice {

    // V's own lines play from the PLAYER, which is why these take a plain
    // GameObject: the same slot files, the same emitter mechanism, a
    // different mouth.
    // V'S OWN LINES PLAY FLAT (2D), not from an emitter. The player IS
    // Audioware's listener, and registering the listener as an emitter at its
    // own position produced a slot file that was written, logged, and never
    // audible (field report: "V does not have a tts"). Audioware's plain
    // Play(eventName) is the non-positional path (Ext.reds:70) - which is also
    // what V's voice should be: it comes from your own head, not from a point
    // in the world.
    @if(ModuleExists("Audioware"))
    public static func SpeakFlat(game: GameInstance, slot: Int32) -> Void {
        let ext = GameInstance.GetAudioSystemExt(game);
        if !IsDefined(ext) {
            return;
        }
        ext.Play(StringToName(s"streettalk_slot_\(slot)"));
        StLog(s"voice: V speaking, slot \(slot)");
    }

    @if(!ModuleExists("Audioware"))
    public static func SpeakFlat(game: GameInstance, slot: Int32) -> Void {
        StLog("voice: Audioware is not installed - spoken replies need it");
    }

    @if(ModuleExists("Audioware"))
    public static func SilenceFlat(game: GameInstance, slot: Int32) -> Void {
        let ext = GameInstance.GetAudioSystemExt(game);
        if IsDefined(ext) {
            ext.Stop(StringToName(s"streettalk_slot_\(slot)"));
        }
    }

    @if(!ModuleExists("Audioware"))
    public static func SilenceFlat(game: GameInstance, slot: Int32) -> Void {}

    @if(ModuleExists("Audioware"))
    public static func Speak(game: GameInstance, npc: wref<NPCPuppet>, slot: Int32) -> Void {
        if !IsDefined(npc) {
            return;
        }
        // GameInstance.GetAudioSystemExt(game), NOT a bare call: Audioware
        // declares it @addMethod(GameInstance) (Ext.reds:8), so it only
        // resolves through the class. Calling it bare compiled in the docs'
        // shorthand but is UNRESOLVED_FN against the real installed script.
        let ext = GameInstance.GetAudioSystemExt(game);
        if !IsDefined(ext) {
            return;
        }
        let id: EntityID = npc.GetEntityID();
        if !ext.IsRegisteredEmitter(id, n"StreetTalk") {
            ext.RegisterEmitter(id, n"StreetTalk");
        }
        ext.PlayOnEmitter(StringToName(s"streettalk_slot_\(slot)"), id, n"StreetTalk");
        StLog(s"voice: playing slot \(slot)");
    }

    @if(!ModuleExists("Audioware"))
    public static func Speak(game: GameInstance, npc: wref<NPCPuppet>, slot: Int32) -> Void {
        StLog("voice: Audioware is not installed - spoken replies need it");
    }

    // Register the NPC as an emitter ahead of time, at chat open. Registering
    // and playing in the same frame can leave the line un-positioned - the
    // "audio just plays from nowhere" symptom.
    @if(ModuleExists("Audioware"))
    public static func Prepare(game: GameInstance, npc: wref<NPCPuppet>) -> Void {
        if !IsDefined(npc) {
            return;
        }
        let ext = GameInstance.GetAudioSystemExt(game);
        if IsDefined(ext) && !ext.IsRegisteredEmitter(npc.GetEntityID(), n"StreetTalk") {
            ext.RegisterEmitter(npc.GetEntityID(), n"StreetTalk");
        }
    }

    @if(!ModuleExists("Audioware"))
    public static func Prepare(game: GameInstance, npc: wref<NPCPuppet>) -> Void {}

    // Hard-stop the currently playing line (menu opened).
    @if(ModuleExists("Audioware"))
    public static func Silence(game: GameInstance, npc: wref<NPCPuppet>, slot: Int32) -> Void {
        if !IsDefined(npc) {
            return;
        }
        let ext = GameInstance.GetAudioSystemExt(game);
        if IsDefined(ext) {
            ext.StopOnEmitter(StringToName(s"streettalk_slot_\(slot)"), npc.GetEntityID(), n"StreetTalk", null);
        }
    }

    @if(!ModuleExists("Audioware"))
    public static func Silence(game: GameInstance, npc: wref<NPCPuppet>, slot: Int32) -> Void {}
}

// ============================================================================
//  NO VANILLA BARKS DURING A CHAT
// ============================================================================
//  Ducking the dialogue channel made the game's barks quiet; it could not stop
//  them happening. And they DO happen - the reaction system plays a voiceover
//  when an NPC notices you (reactionComponent.swift:2871), AI sub-actions play
//  them from behaviour trees (tweakAISubActions.swift:93), and stepping a
//  vendor out of her work routine so she can gesture is exactly the kind of
//  thing that makes her greet a customer. Field report, twice: she recited her
//  scripted line mid-conversation.
//
//  Every script-side voiceover funnels through this one static
//  (gameObject.swift:743), so the fix is one interception: while the chat is
//  open, the person you are talking to does not get to say anything the mod
//  did not write. Everyone else in Night City is untouched.
// ============================================================================
@wrapMethod(GameObject)
public final static func PlayVoiceOver(self: ref<GameObject>, voName: CName, debugInitialContext: CName, opt delay: Float, opt answeringEntityID: EntityID, opt canPlayInVehicle: Bool) -> DelayID {
    let chat = StChat.Get();
    if IsDefined(chat) && chat.IsChattingWith(self) {
        StLog(s"bark suppressed during chat: \(voName)");
        let none: DelayID;
        return none;
    }
    return wrappedMethod(self, voName, debugInitialContext, delay, answeringEntityID, canPlayInVehicle);
}
