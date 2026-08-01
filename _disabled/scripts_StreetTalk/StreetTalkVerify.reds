// ============================================================================
//  STREET TALK - verify the attach actually landed
// ============================================================================
//
//  The attach runs during TweakXL's apply phase, where logging is not
//  available. This reads the result back once the session is live, so we can
//  see whether it worked instead of inferring from whether an option appears.
// ============================================================================

module StreetTalk

public class StreetTalkVerifySystem extends ScriptableSystem {
    private func OnAttach() -> Void {
        let cb = new StVerifyOnce();
        cb.system = this;
        GameInstance.GetDelaySystem(this.GetGameInstance()).DelayCallback(cb, 4.0, false);
    }

    public func Verify() -> Void {
        let ourAction: TweakDBID = t"ObjectAction.StreetTalk_Talk";
        let talkAction: TweakDBID = t"GenericInteraction.Talk";

        // Sample rather than sweep - reading every record here would repeat the
        // mistake that made the attach itself unobservable.
        let probes: array<TweakDBID>;
        ArrayPush(probes, t"Character.hey_gle_gunsmith_01");
        ArrayPush(probes, t"Character.sts_ep1_10_bill_hotdog_vendor");

        let i: Int32 = 0;
        while i < ArraySize(probes) {
            let rec = TweakDBInterface.GetCharacterRecord(probes[i]);
            if !IsDefined(rec) {
                StLog(s"verify [\(i)]: record not found");
            } else {
                let count: Int32 = rec.GetObjectActionsCount();
                let hasTalk: Bool = false;
                let hasOurs: Bool = false;
                let j: Int32 = 0;
                while j < count {
                    let act = rec.GetObjectActionsItem(j);
                    if IsDefined(act) {
                        if Equals(act.GetID(), talkAction) { hasTalk = true; }
                        if Equals(act.GetID(), ourAction) { hasOurs = true; }
                    }
                    j += 1;
                }
                StLog(s"verify [\(i)]: actions=\(count) vanillaTalk=\(hasTalk) ourChat=\(hasOurs)");
            }
            i += 1;
        }
    }
}

public class StVerifyOnce extends DelayCallback {
    public let system: wref<StreetTalkVerifySystem>;
    public func Call() -> Void {
        if IsDefined(this.system) {
            this.system.Verify();
        }
    }
}
