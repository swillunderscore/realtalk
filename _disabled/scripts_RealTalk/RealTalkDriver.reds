// ============================================================================
//  STREET TALK - driver
// ============================================================================
//
//  Ties the pieces together: identity -> memory -> persona -> model.
//
//  WHY THERE IS A TEST MODE:
//    The interaction UI is not solved yet. Adding an option to an NPC's real
//    choice list needs a hook we haven't found (the blueline approach was
//    abandoned - the game rewrites that blackboard continuously, so the prompt
//    only flickered into view during dialogue; and binding a key collided with
//    the dialogue-select key on exactly the NPCs that matter).
//
//    Rather than block the whole pipeline on the UI, test mode fires one
//    greeting at the model the first time you look at a community NPC and logs
//    the reply. That exercises identity, memory, persona, HTTP and parsing
//    end to end. Build the brain, prove it works, then attach the mouth.
//
//    It is OFF by default and should stay off for normal play - it talks to
//    the model every time you meet someone new.
// ============================================================================

module RealTalk

@wrapMethod(ScriptedPuppet)
protected func DetermineInteractionState() -> Void {
    wrappedMethod();

    let settings = RealTalkSettings.Get();
    if !IsDefined(settings) || !settings.enabled {
        return;
    }
    let npc: ref<NPCPuppet> = this as NPCPuppet;
    if !IsDefined(npc) {
        return;
    }

    let identity: ref<StIdentity> = StIdentityResolver.Resolve(npc);
    if !identity.valid {
        return;
    }

    // Record the current NPC on EVERY evaluation, before the once-per-puppet
    // dedupe below. Putting this after the dedupe meant it only ever ran the
    // first time an NPC was seen - so returning to the gunsmith later left the
    // choice tick with no idea who was in front of the player.
    RealTalkChoiceSystem.SetCurrent(identity, npc);

    if this.m_stSeen {
        return;
    }

    // Respect the who-can-I-talk-to settings. Crowd NPCs are off by default
    // because they cannot be remembered - their IDs churn every session.
    if identity.isCrowd && !settings.allowCrowd {
        return;
    }
    if !identity.isCrowd && !settings.allowCommunity {
        return;
    }

    this.m_stSeen = true;

    let memory = StMemory.Get();
    if !IsDefined(memory) {
        return;
    }

    // Cheap: a dictionary lookup and an integer bump. No model call.
    let entry: ref<StMemoryEntry> = memory.NoteEncounter(identity);

    if settings.logging {
        let kind: String = identity.isCrowd ? "crowd" : "community";
        let met: Int32 = IsDefined(entry) ? entry.encounters : 0;
        StLog(s"met \(kind) npc, id=\(identity.persistentId), times seen=\(met)");
    }

    // Test mode still works (auto-greet on first sight) but is no longer the
    // only way in - the UI opens on demand now. Left in place because it is the
    // fastest way for a user to verify their server setup without hunting for
    // an NPC to talk to.
    if !settings.testMode || identity.isCrowd {
        return;
    }

    let chat = StChat.Get();
    if !IsDefined(chat) || chat.IsBusy() {
        return;
    }
    let familiarity: String = memory.FamiliarityLine(entry);
    let persona: String = StPersona.Build(identity, entry, familiarity);
    chat.Begin(identity, persona);
    chat.Send("Hey.");
    StLog("test mode: greeting sent, reply will follow");
}

@addField(ScriptedPuppet)
public let m_stSeen: Bool;
