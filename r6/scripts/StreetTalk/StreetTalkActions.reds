// ============================================================================
//  STREET TALK - NPC actions ("tool use")
// ============================================================================
//
//  The model can act, not just talk. A reply may carry a tag - [FOLLOW],
//  [STOP], [GREET] - which is executed on the NPC and stripped from the text
//  before display.
//
//  Every API verified against decompiled sources before use:
//    AIFollowTargetCommand { target, desiredDistance, tolerance,
//      stopWhenDestinationReached, movementType }      orphans.swift:47171
//    AIComponent.SendCommand(puppet, cmd)  [static]    aiComponent.swift:98
//    AIComponent.CancelCommand(puppet, cmd) [static]   aiComponent.swift
//    moveMovementType.Walk                             (in use across scripts)
//    AIJoinCrowdCommand                                orphans.swift:47190
//    TransactionSystem GiveItem/RemoveItem              orphans.swift:18031+
//
//  Movement uses the game's own navmesh pathfinding - whatever route the AI
//  picks is the route. If a bartender takes the scenic tour of her own bar,
//  that is the game driving, and it stays.
// ============================================================================

module StreetTalk

import RedData.Json.*
import RedFileSystem.*

import RedFileSystem.*

public class StActions extends IScriptable {

    // Say on screen what just happened. An action with no acknowledgement
    // looks like a bug even when it worked.
    // Is there anything here but whitespace? Written by hand ON PURPOSE.
    //
    // The obvious version - StrLen(StrReplaceAll(text, " ", "")) > 0 - takes
    // the string as a script_ref and MUTATES THE CALLER'S STRING: replies came
    // out as "Yeah,you'reright,Ishould!" because three of these checks ran
    // over the text before it reached the screen. A test that quietly edits
    // what it is testing is the worst kind of helper.
    public static func IsBlank(text: String) -> Bool {
        let i: Int32 = 0;
        while i < StrLen(text) {
            let ch: String = StrMid(text, i, 1);
            if NotEquals(ch, " ") && NotEquals(ch, "\n") && NotEquals(ch, "\t") {
                return false;
            }
            i += 1;
        }
        return true;
    }

    static func Announce(text: String) -> Void {
        let ui = StreetTalkUI.Get();
        if IsDefined(ui) {
            ui.AddAction(text);
        }
        // ...and into the conversation itself, so reopening a chat still shows
        // that she started following you. These lines were screen-only before,
        // which meant the amber "starts following you" vanished the moment the
        // panel was closed and the transcript read as though nothing had
        // happened (field report). Stored under their own role so they come
        // back on replay without ever being sent to the model.
        let chat = StChat.Get();
        if IsDefined(chat) {
            chat.NoteAction(text);
        }
    }

    // EVERY companion, not one. A single slot could not describe a car with
    // people in it: whoever followed second overwrote the first, so only one
    // of them could ever be stopped, seated or sent home. Each entry owns the
    // things that are true of that person alone - their command, whether this
    // mod gave them the companion role, and where they are sitting.
    private let followers: array<ref<StFollower>>;

    // FOLLOWING SURVIVES A RELOAD. A companion is a state of the world, not
    // of this session: loading a save dropped every follower and the AI
    // commands with them, so the person who was walking beside V simply
    // stopped (field report). Entity ids round-trip through Codeware's
    // EntityID.FromHash, so the same people can be asked again.
    private let restoreLogged: Int32;
    private let wantedRecords: array<String>;
    private let wantedNames: array<String>;

    // Called whenever this mod resolves an NPC - opening a chat, or looking at
    // one. If they are someone who was following when the game was saved, they
    // pick it up again. This is the half that actually works: an entity id is
    // gone after a reload, but the person is still the same person.
    public func MatchSavedFollower(npc: ref<NPCPuppet>) -> Void {
        if !IsDefined(npc) || npc.IsDead() || this.IsFollowing(npc) {
            return;
        }
        if ArraySize(this.wantedRecords) == 0 && ArraySize(this.wantedNames) == 0 {
            return;
        }
        let rec: String = TDBID.ToStringDEBUG(npc.GetRecordID());
        let name: String = StActions.Readable(npc);
        let hit: Bool = false;
        let i: Int32 = 0;
        while i < ArraySize(this.wantedRecords) {
            if StrLen(rec) > 0 && Equals(this.wantedRecords[i], rec) {
                hit = true;
            }
            i += 1;
        }
        i = 0;
        while i < ArraySize(this.wantedNames) {
            if StrLen(name) > 0 && Equals(this.wantedNames[i], name) {
                hit = true;
            }
            i += 1;
        }
        if hit {
            StLog(s"follow: \(name) was walking with you when you saved - picking it back up");
            this.Follow(npc);
            ArrayClear(this.wantedRecords);
            ArrayClear(this.wantedNames);
        }
    }

    private func SaveFollowers() -> Void {
        let fs = StreetTalkFS.Get();
        if !IsDefined(fs) {
            return;
        }
        let storage = fs.Storage();
        if !IsDefined(storage) {
            return;
        }
        let dto = new StFollowFileDTO();
        let i: Int32 = 0;
        while i < ArraySize(this.followers) {
            let f = this.followers[i];
            if IsDefined(f.npc) {
                // ENTITY IDS DO NOT SURVIVE A RELOAD. The id came back
                // well-formed and resolved to nothing at all - "id
                // defined=true entity=false" - so a companion could never be
                // found again. What does survive is WHO they are: the
                // character record behind them, and their name.
                ArrayPush(dto.ids, s"\(EntityID.ToHash(f.npc.GetEntityID()))");
                ArrayPush(dto.records, TDBID.ToStringDEBUG(f.npc.GetRecordID()));
                ArrayPush(dto.names, StActions.Readable(f.npc));
            }
            i += 1;
        }
        let file = storage.GetFile("followers.json");
        if IsDefined(file) {
            file.WriteText(ToJson(dto).ToString());
        }
    }

    // Tried repeatedly after a load: the NPC may not be streamed in yet, and
    // FindEntityByID answers null until they are.
    public func RestoreFollowers(game: GameInstance) -> Bool {
        let fs = StreetTalkFS.Get();
        if !IsDefined(fs) {
            return true;
        }
        let storage = fs.Storage();
        if !IsDefined(storage)
            || NotEquals(storage.Exists("followers.json"), FileSystemStatus.True) {
            return true;   // nobody was following - nothing to wait for
        }
        let file = storage.GetFile("followers.json");
        if !IsDefined(file) {
            return true;
        }
        let json = file.ReadAsJson();
        if !IsDefined(json) || json.IsUndefined() {
            return true;
        }
        let root = json as JsonObject;
        if !IsDefined(root) {
            return true;
        }
        let dto = FromJson(root, n"StreetTalk.StFollowFileDTO") as StFollowFileDTO;
        if !IsDefined(dto) || ArraySize(dto.ids) == 0 {
            return true;
        }
        // Remember who we are looking for. Whoever matches, whenever they
        // turn up, resumes following - see MatchSavedFollower, called every
        // time the mod resolves an NPC.
        ArrayClear(this.wantedRecords);
        ArrayClear(this.wantedNames);
        let w: Int32 = 0;
        while w < ArraySize(dto.records) {
            ArrayPush(this.wantedRecords, dto.records[w]);
            w += 1;
        }
        w = 0;
        while w < ArraySize(dto.names) {
            ArrayPush(this.wantedNames, dto.names[w]);
            w += 1;
        }
        let all: Bool = true;
        let i: Int32 = 0;
        while i < ArraySize(dto.ids) {
            let hash: Uint64 = StringToUint64(dto.ids[i], Cast<Uint64>(0));
            let id: EntityID = EntityID.FromHash(hash);
            let ent = GameInstance.FindEntityByID(game, id);
            let npc = ent as NPCPuppet;
            if IsDefined(npc) && !npc.IsDead() {
                if !this.IsFollowing(npc) {
                    this.Follow(npc);
                    StLog(s"follow: \(StActions.Readable(npc)) picked up where they left off");
                }
            } else {
                all = false;   // not streamed in yet - try again shortly
                // Silence here meant a restore that never worked looked
                // exactly like a restore that had nothing to do.
                if this.restoreLogged < 3 {
                    this.restoreLogged += 1;
                    StLog(s"follow: saved companion \(dto.ids[i]) -> id defined="
                        + s"\(EntityID.IsDefined(id)) entity=\(IsDefined(ent))"
                        + s" puppet=\(IsDefined(npc)) - waiting for them to stream in");
                }
            }
            i += 1;
        }
        return all;
    }

    private func FindFollower(npc: ref<NPCPuppet>) -> ref<StFollower> {
        if !IsDefined(npc) {
            return null;
        }
        let want: Uint64 = EntityID.ToHash(npc.GetEntityID());
        let i: Int32 = 0;
        while i < ArraySize(this.followers) {
            let f = this.followers[i];
            if IsDefined(f.npc) && EntityID.ToHash(f.npc.GetEntityID()) == want {
                return f;
            }
            i += 1;
        }
        return null;
    }

    public func IsFollowing(npc: ref<NPCPuppet>) -> Bool {
        return IsDefined(this.FindFollower(npc));
    }

    // Where the NPC stood before [FOLLOW], so /reset can put them back
    // instead of leaving them stranded across the district.
    private let preFollowPos: Vector4;
    private let preFollowRot: EulerAngles;
    private let hasPreFollow: Bool;

    // THE game teardown for an AI command, copied from how the game itself
    // retracts move commands (quickhackEffectors.swift:902): a command that
    // is already EXECUTING must be stopped, not cancelled - CancelCommand
    // only kills queued ones. Field report: Mama Welles kept following
    // through /reset and /stop, because her follow was executing and our
    // cancel was a no-op.
    private func StopCmd(npc: ref<NPCPuppet>, cmd: ref<AICommand>) -> Void {
        let aic = npc.GetAIControllerComponent();
        if !IsDefined(aic) || !IsDefined(cmd) {
            return;
        }
        let state = aic.GetCommandState(cmd);
        if Equals(state, AICommandState.Executing) {
            aic.StopExecutingCommand(cmd, true);
        } else {
            if Equals(state, AICommandState.Enqueued) {
                aic.CancelCommand(cmd);
            }
        }
    }

    // Crowd NPCs keep walking mid-conversation; this parks them while the
    // chat is open and turns them toward the player. Two verified pieces:
    //
    //   AIHoldPositionCommand{duration}  the game's own stop-in-place
    //     (npcStateComponent.swift:527). Duration generous; released
    //     explicitly on chat close.
    //
    //   LookAtAddEvent  the game's own "civilian glances at V" reaction -
    //     every parameter below is copied from ActivateReactionLookAt
    //     (reactionComponent.swift:3558). Eyes + head + chest weight 2.0
    //     turns the upper body toward you; it is NOT a full-body spin, so
    //     someone addressed from directly behind will crane, not pivot.
    //     (A true AIRotateToCommand exists but no vanilla code constructs
    //     one, so its speed units are unknowable - not shipping guesses.)
    //     Removal is public: LookAtRemoveEvent.QueueRemoveLookatEvent
    //     (reactionComponent.swift:3664).
    private let holdCmd: ref<AIHoldPositionCommand>;
    private let chatLookAt: ref<LookAtAddEvent>;
    private let bodyTurned: Bool;

    // Where this NPC stood when the chat opened, and whether we took control
    // of them. Modding an AI this old means accepting that it will sometimes
    // do something unasked - so every takeover is reversible and leashed.
    private let chatHomePos: Vector4;
    private let chatHomeRot: EulerAngles;
    private let hasChatHome: Bool;
    private let chatTookOver: Bool;

    // ------------------------------------------------------------------
    //  RIDING ALONG. The companion role makes them follow on foot; getting
    //  into your car is a separate act, and the game does it by asking the
    //  mounting facility for a seat (gameVehicleMountableComponent.swift:45).
    //  Checked from the poller, so it happens whenever you get in - not only
    //  in the moment they agreed to come.
    // ------------------------------------------------------------------
    // The poller's entry point. It asks about the FOLLOWERS, not about whoever
    // was last spoken to: those stopped being the same person the moment a
    // second conversation started, and the companion left standing in the
    // street while V drove off was the visible half of that (field report).
    // THE TWO HAVE TO AGREE. This mod's list of companions and the game's own
    // idea of who is a companion drifted apart across a reload - the list said
    // yes, the game said no, and nothing reconciled them. The game's answer
    // wins: re-issue the command, and if it will not take, stop claiming they
    // are following.
    private let lastVerifyAt: Float;

    public func VerifyFollowers() -> Void {
        if ArraySize(this.followers) == 0 {
            return;
        }
        // Once every four seconds. A command needs time to take, and the
        // poller runs five times a second - judging a fresh follow instantly
        // would drop everyone before they had taken a step.
        let now: Float = EngineTime.ToFloat(GameInstance.GetSimTime(GetGameInstance()));
        if now - this.lastVerifyAt < 4.0 {
            return;
        }
        this.lastVerifyAt = now;
        let i: Int32 = ArraySize(this.followers) - 1;
        while i >= 0 {
            let f = this.followers[i];
            if !IsDefined(f.npc) || f.npc.IsDead() {
                ArrayErase(this.followers, i);
                this.SaveFollowers();
            } else {
                let aic = f.npc.GetAIControllerComponent();
                if IsDefined(aic) && !aic.IsPlayerCompanion() {
                    f.retries += 1;
                    if f.retries > 3 {
                        StLog(s"follow: \(StActions.Readable(f.npc)) is not actually following - dropping it");
                        ArrayErase(this.followers, i);
                        this.SaveFollowers();
                    } else {
                        StLog(s"follow: re-issuing the follow for \(StActions.Readable(f.npc))");
                        this.Follow(f.npc);
                    }
                } else {
                    f.retries = 0;
                }
            }
            i -= 1;
        }
    }

    public func RideAlongTick() -> Void {
        let i: Int32 = 0;
        while i < ArraySize(this.followers) {
            this.RideAlong(this.followers[i]);
            i += 1;
        }
    }

    public func RideAlong(f: ref<StFollower>) -> Void {
        let npc = f.npc;
        if !IsDefined(npc) || npc.IsDead() {
            return;
        }
        let game = npc.GetGame();
        let player = GetPlayer(game);
        if !IsDefined(player) {
            return;
        }
        // A global, not a method (vehicles.swift:1489).
        let car = GetMountedVehicle(player);
        if !IsDefined(car) {
            // YOU GOT OUT, SO THEY GET OUT. Without this they stayed sitting
            // in the parked car while V walked away - which is how the game
            // leaves them, and how AMM leaves them, and it is wrong either
            // way (field report).
            if f.riding {
                this.Dismount(f);
            }
            return;
        }
        if f.riding {
            return;   // already aboard
        }
        let mf = GameInstance.GetMountingFacility(game);
        if !IsDefined(mf) {
            return;
        }
        // THE CAR'S OWN SEATS, in the car's own order (vehicleComponent.swift
        // :1215). A hardcoded list of three was wrong in both directions: it
        // invented back seats in a two-seater and ignored the extra ones in a
        // Basilisk.
        let seats: array<wref<VehicleSeat_Record>>;
        if !VehicleComponent.GetSeats(game, car, seats) || ArraySize(seats) == 0 {
            return;
        }
        // V's own seat is off limits - usually the driver's, but not if V
        // rode shotgun in someone else's car.
        let mine: MountingInfo = mf.GetMountingInfoSingleWithObjects(player);
        let free: CName = n"";
        let firstOther: CName = n"";
        let i: Int32 = 0;
        while i < ArraySize(seats) {
            let name: CName = seats[i].SeatName();
            if NotEquals(name, mine.slotId.id) && NotEquals(name, n"seat_front_left") {
                if !IsNameValid(firstOther) {
                    firstOther = name;
                }
                if !VehicleComponent.IsSlotOccupied(game, car.GetEntityID(), name)
                    && !this.SeatClaimed(name) {
                    free = name;
                    i = ArraySize(seats);
                }
            }
            i += 1;
        }
        // Full car, more companions: they pile into the first passenger seat
        // rather than being left in the street. Owner's call, and the same
        // thing AMM does when you do not assign seats by hand.
        if !IsNameValid(free) {
            free = firstOther;
            if !IsNameValid(free) {
                return;   // a one-seater. Nothing to offer.
            }
            StLog(s"follow: no free seat, piling into \(free)");
        }
        let info: MountingInfo;
        info.parentId = car.GetEntityID();
        info.childId = npc.GetEntityID();
        info.slotId.id = free;
        let req = new MountingRequest();
        req.lowLevelMountingInfo = info;
        req.preservePositionAfterMounting = false;
        let data = new MountEventData();
        let opts = new MountEventOptions();
        opts.entityID = npc.GetEntityID();
        opts.alive = true;
        opts.occupiedByNonFriendly = false;
        data.mountEventOptions = opts;
        req.mountData = data;
        mf.Mount(req);
        f.riding = true;
        f.seat = free;
        f.carId = car.GetEntityID();
        StLog(s"follow: \(StActions.Readable(npc)) into \(free)");
        StActions.Announce("gets in with you");
    }

    // Is another companion already heading for this seat? Occupancy is not
    // instant - two of them assigned in the same tick would both read the
    // seat as empty and land on top of each other for no reason.
    private func SeatClaimed(seat: CName) -> Bool {
        let i: Int32 = 0;
        while i < ArraySize(this.followers) {
            let f = this.followers[i];
            if f.riding && Equals(f.seat, seat) {
                return true;
            }
            i += 1;
        }
        return false;
    }

    // GETTING OUT IS NOT THE OPPOSITE OF GETTING IN. Mounting is one call;
    // unmounting is what the game's own exit task does (aiVehicle.swift:97),
    // and doing only the mounting-facility half left Panam sitting in the
    // parked car while the log cheerfully said "out of the car" every time V
    // walked away (field report). The facility tracks the RECORD. The body is
    // in a vehicle workspot, and until the workspot lets go, nobody moves.
    private func Dismount(f: ref<StFollower>) -> Void {
        let npc = f.npc;
        f.riding = false;
        f.seat = n"";
        if !IsDefined(npc) {
            return;
        }
        let game = npc.GetGame();
        let mf = GameInstance.GetMountingFacility(game);
        if !IsDefined(mf) {
            return;
        }
        // Ask where they actually are rather than trusting our own record.
        let info: MountingInfo = mf.GetMountingInfoSingleWithObjects(npc);
        let slotName: CName = info.slotId.id;
        let car = GameInstance.FindEntityByID(game, info.parentId) as VehicleObject;
        if !IsDefined(car) || !IsNameValid(slotName) {
            StLog("follow: nothing to climb out of");
            return;
        }
        if !car.GetVehiclePS().IsSlotOccupiedByNPC(slotName) {
            return;
        }
        // The door, so it opens and shuts behind them.
        let door = new VehicleExternalDoorRequestEvent();
        door.slotName = car.GetBoneNameFromSlot(slotName);
        door.autoClose = true;
        // The vehicle's own "someone is leaving" notice - this is what frees
        // the seat as far as the rest of the game is concerned.
        let leaving = new VehicleStartedMountingEvent();
        leaving.slotID = slotName;
        leaving.isMounting = false;
        leaving.character = npc;
        let ws = GameInstance.GetWorkspotSystem(game);
        if IsDefined(ws) {
            // (parent, child, instant) and nothing more: the next two
            // parameters are a Vector4 and a Quaternion, not an animation
            // name, so the exit slot cannot be named without inventing a
            // position and a rotation to go with it. The game's default exit
            // is the right one anyway.
            ws.UnmountFromVehicle(car, npc, false);
        }
        car.QueueEvent(leaving);
        car.QueueEvent(door);
        let out = new UnmountingRequest();
        out.lowLevelMountingInfo = info;
        mf.Unmount(out);
        // Back on their feet and back behind you: the follow command was
        // suspended by the ride, and standing in the road is not following.
        if IsDefined(f.cmd) {
            AIComponent.SendCommand(npc, f.cmd);
        }
        StLog(s"follow: \(StActions.Readable(npc)) out of the car");
        StActions.Announce("climbs out");
    }

    // Display names are sometimes still a LocKey when we log them ("follow:
    // LocKey#46999 into seat_front_right"), which tells a reader nothing.
    public static func ReadableObj(obj: ref<GameObject>) -> String {
        if !IsDefined(obj) {
            return "someone";
        }
        let n: String = obj.GetDisplayName();
        return StrBeginsWith(n, "LocKey#") ? GetLocalizedText(n) : n;
    }

    public static func Readable(npc: ref<NPCPuppet>) -> String {
        if !IsDefined(npc) {
            return "someone";
        }
        let n: String = npc.GetDisplayName();
        return StrBeginsWith(n, "LocKey#") ? GetLocalizedText(n) : n;
    }

    // Put them back where the conversation found them. Used on chat close and
    // by /reset - NOT on a timer: an NPC yanked back every quarter second can
    // never do anything you asked for, and being able to tell someone to go
    // somewhere is the point.
    public func SendHome(npc: ref<NPCPuppet>) -> Void {
        if !this.hasChatHome || !IsDefined(npc) {
            return;
        }
        GameInstance.GetTeleportationFacility(npc.GetGame())
            .Teleport(npc, this.chatHomePos, this.chatHomeRot);
        StLog("chat: NPC returned to where the conversation started");
    }

    // ONE setup at chat open, for everyone. Doing this per-animation is what
    // made NPCs turn mid-conversation and snap back after every line (field
    // report). Now they turn to you once when the chat opens, gesture facing
    // you, and go back to what they were doing when it closes.
    //
    // The BODY turn is the game's own face-a-target pattern: Teleport with
    // Vector4.ToRotation(direction), exactly as vanilla does it
    // (worldMap.swift:949, roadBlockTrap.swift:74). No yaw convention to
    // guess - hand a direction vector to the engine's own converter.
    public func PrepareForChat(npc: ref<NPCPuppet>, isCrowd: Bool, gesturesOn: Bool) -> Void {
        if !IsDefined(npc) || npc.IsDead() {
            return;
        }
        let game = npc.GetGame();
        let ws = GameInstance.GetWorkspotSystem(game);

        // Reopening the chat on someone already following you must not hold
        // them in place, step them out of anything, or teleport them home -
        // they are where you asked them to be. They should still TURN AND
        // LOOK AT YOU, though: this used to return before the body turn, so a
        // companion talked to you over her shoulder for the whole
        // conversation while her head swivelled round (field report).
        if this.IsFollowing(npc) {
            this.FacePlayer(npc, 0.2);
            this.TurnToPlayer(npc, "talking to a companion");
            return;
        }

        // WHERE THEY WERE, recorded before anything is touched. This is the
        // ground truth every safeguard below restores to: the leash while the
        // chat is open, and the return home when it closes. A shopkeeper
        // walked out of her stall and stood inside the player once (field
        // report) - after which nothing could put her back, because nothing
        // had written down where "back" was.
        this.chatHomePos = npc.GetWorldPosition();
        this.chatHomeRot = Quaternion.ToEulerAngles(npc.GetWorldOrientation());
        this.hasChatHome = true;

        // HOLD FIRST, then release them from the workspot. The other order
        // gives their ambient AI a window with no orders and a free body,
        // which is exactly when one of them decided to come say hello in
        // person.
        if isCrowd || (gesturesOn && IsDefined(ws) && ws.IsActorInWorkspot(npc)) {
            if !IsDefined(this.holdCmd) {
                let cmd = new AIHoldPositionCommand();
                cmd.duration = 600.0;
                this.holdCmd = cmd;
                AIComponent.SendCommand(npc, cmd);
            }
        }

        // Stepping a vendor out of her stall-idle is only worth it when
        // gestures will actually play; otherwise she keeps her authored pose
        // and simply gives you eye contact.
        let steppedOut: Bool = false;
        if gesturesOn && IsDefined(ws) && ws.IsActorInWorkspot(npc) {
            ws.StopInDevice(npc);
            steppedOut = true;
            StLog("chat: NPC stepped out of their workspot");
        }
        this.chatTookOver = isCrowd || steppedOut;

        // TURN THE WHOLE PERSON, not just the neck. This used to be limited
        // to NPCs whose idle we had already taken over, so everyone else
        // tracked V with their head and chest while their feet stayed put - a
        // 180-degree torso twist, described from the field as "a skinwalker
        // 180".
        this.bodyTurned = true;
        this.TurnToPlayer(npc, "chat opened");
        let fp1 = new StFaceProbe();
        fp1.npc = npc;
        fp1.at = 1.0;
        GameInstance.GetDelaySystem(game).DelayCallback(fp1, 1.0, false);
        let fp2 = new StFaceProbe();
        fp2.npc = npc;
        fp2.at = 4.0;
        GameInstance.GetDelaySystem(game).DelayCallback(fp2, 4.0, false);

        // Eyes and head track you for the whole conversation either way.
        this.FacePlayer(npc, this.bodyTurned ? 1.0 : 0.2);
    }

    // Eyes + head track the player for the whole chat; chestWeight sets how
    // much the torso follows. 2.0 turns a free-standing crowd walker toward
    // you; 0.2 is the vanilla upperBody variant - enough life for a
    // workspot NPC (bartender, Ralph at his terminal) without fighting
    // their authored pose. Same event, weights straight from
    // ActivateReactionLookAt (reactionComponent.swift:3558).
    public func FacePlayer(npc: ref<NPCPuppet>, chestWeight: Float) -> Void {
        if !IsDefined(npc) || npc.IsDead() || IsDefined(this.chatLookAt) {
            return;
        }
        let player = GetPlayer(npc.GetGame());
        if IsDefined(player) {
            let lookAtEvent = new LookAtAddEvent();
            lookAtEvent.SetEntityTarget(player, n"pla_default_tgt", Vector4.EmptyVector());
            lookAtEvent.SetStyle(animLookAtStyle.Normal);
            lookAtEvent.request.limits.softLimitDegrees = 360.0;
            lookAtEvent.request.limits.hardLimitDegrees = 270.0;
            lookAtEvent.request.limits.backLimitDegrees = 210.0;
            lookAtEvent.request.limits.hardLimitDistance = GetLookAtLimitDistanceValue(animLookAtLimitDistanceType.None);
            lookAtEvent.request.calculatePositionInParentSpace = true;
            lookAtEvent.bodyPart = n"Eyes";
            let lookAtParts: array<LookAtPartRequest>;
            let part: LookAtPartRequest;
            part.partName = n"Head";
            part.weight = 0.10;
            part.suppress = 1.0;
            part.mode = 0;
            ArrayPush(lookAtParts, part);
            part.partName = n"Chest";
            part.weight = chestWeight;
            part.suppress = 0.0;
            part.mode = 0;
            ArrayPush(lookAtParts, part);
            lookAtEvent.SetAdditionalPartsArray(lookAtParts);
            npc.QueueEvent(lookAtEvent);
            this.chatLookAt = lookAtEvent;
        }
    }

    public func ReleaseChatHold(npc: ref<NPCPuppet>) -> Void {
        this.StopTalking(npc);
        if !IsDefined(npc) {
            return;
        }
        if IsDefined(this.holdCmd) {
            this.StopCmd(npc, this.holdCmd);
            this.holdCmd = null;
        }
        if IsDefined(this.chatLookAt) {
            LookAtRemoveEvent.QueueRemoveLookatEvent(npc, this.chatLookAt);
            this.chatLookAt = null;
        }
        // Put them back exactly where the conversation found them, facing the
        // way they were - unless you asked them to be somewhere else. A
        // following companion should stay following when you close the chat;
        // only NPCs whose routine WE interrupted get sent back.
        if this.chatTookOver && !this.IsFollowing(npc) {
            this.SendHome(npc);
        }
        this.bodyTurned = false;
        this.chatTookOver = false;
        this.hasChatHome = false;
    }

    // RP-tuned models narrate even when told not to - field sample:
    //   "What's up?" I say, looking the stranger over.
    // and the TTS read every word of it. When quotation marks are present,
    // the quotes CONTAIN the dialogue and everything outside them is
    // narration: keep the quoted spans, keep bracketed action tags from
    // anywhere (so "Sure." [FOLLOW] I nod. still follows), drop the rest.
    // Asterisk *actions* go unconditionally. Deterministic cleanup beats
    // prompt hope; the prompt ALSO forbids it (StreetTalkPersona.reds).
    public static func CleanProse(text: String) -> String {
        // curly quotes normalise first - models emit both
        let t: String = StrReplaceAll(StrReplaceAll(text, "\u{201C}", "\""), "\u{201D}", "\"");
        // strip *action* spans
        let noStars: String = "";
        let rest: String = t;
        let guard: Int32 = 0;
        while guard < 16 {
            guard += 1;
            let a: Int32 = StrFindFirst(rest, "*");
            if a == -1 {
                break;
            }
            let tail: String = StrMid(rest, a + 1);
            let b: Int32 = StrFindFirst(tail, "*");
            if b == -1 {
                break;
            }
            noStars += StrLeft(rest, a);
            rest = StrMid(rest, a + b + 2);
        }
        noStars += rest;
        // quoted spans become the whole message (plus any bracket tags)
        let firstQ: Int32 = StrFindFirst(noStars, "\"");
        if firstQ == -1 {
            return noStars;
        }
        let dialogue: String = "";
        let scan: String = noStars;
        guard = 0;
        while guard < 16 {
            guard += 1;
            let q1: Int32 = StrFindFirst(scan, "\"");
            if q1 == -1 {
                break;
            }
            let tail2: String = StrMid(scan, q1 + 1);
            let q2: Int32 = StrFindFirst(tail2, "\"");
            if q2 == -1 {
                break;
            }
            let span: String = StrMid(scan, q1 + 1, q2);
            dialogue += StrLen(dialogue) > 0 ? " " + span : span;
            scan = StrMid(scan, q1 + q2 + 2);
        }
        if StrLen(dialogue) == 0 {
            return noStars;
        }
        // bracket tags outside the quotes still count as actions
        let tagScan: String = noStars;
        guard = 0;
        while guard < 8 {
            guard += 1;
            let lb: Int32 = StrFindFirst(tagScan, "[");
            if lb == -1 {
                break;
            }
            let tail3: String = StrMid(tagScan, lb);
            let rb: Int32 = StrFindFirst(tail3, "]");
            if rb == -1 {
                break;
            }
            if StrFindFirst(dialogue, StrMid(tagScan, lb, rb + 1)) == -1 {
                dialogue += " " + StrMid(tagScan, lb, rb + 1);
            }
            tagScan = StrMid(tagScan, lb + rb + 1);
        }
        return dialogue;
    }

    // ------------------------------------------------------------------
    //  INTENT RESOLUTION - the animation resolver's trick, applied to acts.
    //
    //  Every action named in the prompt costs tokens AND attention: eight tags
    //  with worked examples was 236 tokens, 38% of a whole character card, and
    //  a 7B carrying that many rules starts picking the WRONG tool rather than
    //  no tool. So the expressive actions left the prompt entirely. The model
    //  writes its stage beat as it always did - "shrugs and heads back to the
    //  stall" - and this reads the intent out of it.
    //
    //  Only consequential actions keep explicit tags (money, follow/stop),
    //  because "did you mean to hand over 500 eddies" must never be inferred.
    //
    //  STRICTNESS, learned from [rolls eyes] firing FOLLOW:
    //    - only the BEAT is searched, never the spoken words
    //    - whole words only, and the third-person -s form the beat format
    //      produces ("runs", "leaves", "drops") - so a noun or an -ing clause
    //      cannot trigger anything
    //    - ambiguous verbs need their phrase ("walks AWAY", not "walks")
    //    - negations and hypotheticals veto the whole beat
    //    - no match means NO ACTION, every time
    // ------------------------------------------------------------------
    static func WordIn(hay: String, word: String) -> Bool {
        let padded: String = s" \(hay) ";
        return StrContains(padded, s" \(word) ")
            || StrContains(padded, s" \(word),")
            || StrContains(padded, s" \(word).");
    }

    public static func ResolveIntent(beat: String, holding: Bool) -> String {
        let b: String = StrLower(beat);
        if StrLen(b) < 4 {
            return "";
        }
        // Running is also leaving, so it is tested first.
        if StActions.Did(b, "runs") || StActions.Did(b, "bolts")
            || StActions.Did(b, "flees") || StActions.Did(b, "sprints")
            || StActions.Did(b, "hurries off") || StActions.Did(b, "hurries away")
            || StActions.Did(b, "takes off") || StActions.Did(b, "runs off") {
            return "run";
        }
        if StActions.Did(b, "holsters") || StActions.Did(b, "puts it away")
            || StActions.Did(b, "puts the gun away") || StActions.Did(b, "stows")
            || StActions.Did(b, "lowers her weapon") || StActions.Did(b, "lowers his weapon")
            || StActions.Did(b, "puts her weapon away") || StActions.Did(b, "puts his weapon away") {
            return "holster";
        }
        if StActions.Did(b, "leaves") || StActions.Did(b, "walks away")
            || StActions.Did(b, "walks off") || StActions.Did(b, "turns away")
            || StActions.Did(b, "heads off") || StActions.Did(b, "heads out") {
            return "leave";
        }
        // Positions we can actually compute - no named places, because there
        // is no script-queryable index of rooms or landmarks, and a location
        // parser that fails on most sentences is worse than none.
        if StActions.Did(b, "steps closer") || StActions.Did(b, "comes closer")
            || StActions.Did(b, "steps up") || StActions.Did(b, "moves closer")
            || StActions.Did(b, "walks over") || StActions.Did(b, "approaches") {
            return "closer";
        }
        if StActions.Did(b, "steps back") || StActions.Did(b, "backs off")
            || StActions.Did(b, "backs away") || StActions.Did(b, "steps aside")
            || StActions.Did(b, "gives ground") {
            return "back";
        }
        if StActions.Did(b, "goes back to work") || StActions.Did(b, "returns to")
            || StActions.Did(b, "gets back to") || StActions.Did(b, "goes back to her")
            || StActions.Did(b, "goes back to his") {
            return "post";
        }
        // Cannot put down what they are not holding - and the card tells them
        // what is in their hands, so they rarely try.
        if holding && (StActions.Did(b, "drops") || StActions.Did(b, "sets it down")
            || StActions.Did(b, "puts it down") || StActions.Did(b, "sets down")
            || StActions.Did(b, "tosses it")) {
            return "drop";
        }
        // Melting back into the crowd - the game's own AIJoinCrowdCommand,
        // and the most Night City exit there is.
        if StActions.Did(b, "disappears") || StActions.Did(b, "melts")
            || StActions.Did(b, "vanishes") || StActions.Did(b, "slips away")
            || StActions.Did(b, "blends") || StActions.Did(b, "loses himself")
            || StActions.Did(b, "loses herself") {
            return "crowd";
        }
        return "";
    }

    // "Did they actually do this?" - the phrase present, and NOT negated
    // immediately before it.
    //
    // The first version vetoed the whole beat if a negation word appeared
    // ANYWHERE in it, which is brittle in both directions: "No offense, but
    // she walks off" was vetoed, and a doubled negation would sail through.
    // Negation in English attaches to the verb it precedes, so only the words
    // DIRECTLY before the match are examined - the same reason the animation
    // matcher looks at tokens rather than whole sentences.
    static func Did(beat: String, phrase: String) -> Bool {
        if !StActions.WordIn(beat, phrase) {
            return false;
        }
        let at: Int32 = StrFindFirst(beat, phrase);
        if at <= 0 {
            return true;
        }
        // The ~24 characters before it: roughly "does not " / "instead of "
        // / "without " / "refuses to " and nothing further back.
        let start: Int32 = at > 24 ? at - 24 : 0;
        let before: String = StrMid(beat, start, at - start);
        if StrContains(before, "not") || StrContains(before, "n't")
            || StrContains(before, "never") || StrContains(before, "instead")
            || StrContains(before, "without") || StrContains(before, "refus")
            || StrContains(before, "almost") || StrContains(before, "nearly") {
            StLog(s"intent: '\(phrase)' is negated in the beat - no action");
            return false;
        }
        return true;
    }

    // Run whatever the beat meant. Separate from tag execution so the two
    // channels cannot double-fire the same action.
    // NOTHING IS READ OUT OF THE SPOKEN WORDS ANY MORE.
    //
    // Phrase-matching dialogue could not be made safe: "I'm with you because I
    // want to be" is affection, and it marched someone off down the street
    // mid-argument. Speech is for meaning; the action beat is for actions, and
    // mixing them means every affectionate line is a potential command.
    //
    // What is left reads only the beat - plus one narrow case that reads
    // YOUR words rather than theirs: a bare "sure" against something you just
    // asked for. That one cannot misfire on prose, because prose is not what
    // it looks at.
    // What V just asked for, read from V's own sentence. Paired with a plain
    // agreement below, this is the one path that can act on a reply as short
    // as "Sure." - and it looks at the player's words, never the NPC's prose,
    // so no amount of affectionate dialogue can trip it.
    public static func AskIntent(playerLine: String) -> String {
        let t: String = StrLower(playerLine);
        // STOP IS TESTED FIRST, because every way of saying it contains a way
        // of saying follow: "stop following me" must not read as "follow me".
        if StrContains(t, "wait here") || StrContains(t, "stay here")
            || StrContains(t, "stay put") || StrContains(t, "stop following")
            || StrContains(t, "quit following") || StrContains(t, "don't follow")
            || StrContains(t, "dont follow") || StrContains(t, "stay there")
            || StrContains(t, "hold up") || StrContains(t, "wait there") {
            return "stop";
        }
        // "would you mind FOLLOWING me" was not an ask under the old literal
        // list, so a perfectly clear request went nowhere (field report). The
        // stem is what people vary around.
        if StrContains(t, "follow me") || StrContains(t, "following me")
            || StrContains(t, "follow along") || StrContains(t, "come with me")
            || StrContains(t, "come with") || StrContains(t, "come along")
            || StrContains(t, "walk with me") || StrContains(t, "tag along")
            || StrContains(t, "stick with me") || StrContains(t, "stay with me")
            || StrContains(t, "let's go") || StrContains(t, "lets go")
            || StrContains(t, "come on") || StrContains(t, "cmon")
            || StrContains(t, "follow") {
            return "follow";
        }
        if StrContains(t, "get lost") || StrContains(t, "go away")
            || StrContains(t, "leave me") || StrContains(t, "piss off") {
            return "leave";
        }
        if StrContains(t, "run away") || StrContains(t, "make a run") {
            return "run";
        }
        // ASKED TO PUT IT AWAY - tested before "drop it", because "put that
        // away" and "put that down" are one word apart and mean different
        // things: away is theirs to keep, down is on the floor.
        if StrContains(t, "put it away") || StrContains(t, "put that away")
            || StrContains(t, "put the gun away") || StrContains(t, "holster")
            || StrContains(t, "weapon away") || StrContains(t, "gun away")
            || StrContains(t, "stop pointing") || StrContains(t, "lower your weapon")
            || StrContains(t, "lower the gun") {
            return "holster";
        }
        if StrContains(t, "put it down") || StrContains(t, "drop it")
            || StrContains(t, "drop that") {
            return "drop";
        }
        if StrContains(t, "back off") || StrContains(t, "step back")
            || StrContains(t, "give me space") {
            return "back";
        }
        if StrContains(t, "come closer") || StrContains(t, "step closer")
            || StrContains(t, "come here") {
            return "closer";
        }
        // HOW PEOPLE ACTUALLY SAY IT. The old list wanted a pronoun attached
        // ("shoot him"), so "just go ahead and take the shot" and "im ready,
        // shoot" registered as no request at all - and the agreement that
        // followed ("Alright, I've got him in my sights") had nothing to
        // agree TO (field report, a whole conversation of it).
        if StrContains(t, "kill") || StrContains(t, "shoot")
            || StrContains(t, "attack") || StrContains(t, "take the shot")
            || StrContains(t, "take him out") || StrContains(t, "take her out")
            || StrContains(t, "take them out") || StrContains(t, "light him up")
            || StrContains(t, "light her up") || StrContains(t, "put him down")
            || StrContains(t, "put her down") || StrContains(t, "waste him")
            || StrContains(t, "waste her") || StrContains(t, "smoke him")
            || StrContains(t, "ice him") || StrContains(t, "geek him")
            || StrContains(t, "drop him") || StrContains(t, "drop her")
            || StrContains(t, "end him") || StrContains(t, "off him") {
            return "attack";
        }
        return "";
    }

    // Did they agree? This reads the ANSWER, not the whole sentence.
    //
    // The first version vetoed on any negative word anywhere, and Judy paid
    // for it twice in one conversation: "Alright V, I'll follow you, but we're
    // staying together, no funny business, got it?" was thrown out for "no ",
    // and "Fine, just don't get me killed" for "n't". Both were yesses. People
    // agree in sentences that contain negatives - the negative is usually a
    // condition on the yes, not a refusal of it.
    //
    // So: the yes has to open the reply, and only an ACTUAL refusal - a bare
    // "no" standing as its own clause, or a phrase that can only mean no -
    // takes it back. "Yeah, no" still reads as no, which is the case the old
    // rule existed for.
    public static func IsAffirmative(speech: String) -> Bool {
        let t: String = StrLower(speech);
        if StrLen(t) == 0 {
            return false;
        }
        if !StActions.StartsYes(StActions.FirstClause(t)) {
            return false;
        }
        return !StActions.HasRefusal(t);
    }

    // "Alright, but what has he done?" is a person asking, not agreeing. A
    // reply that ends in a question mark is checking something, whatever
    // word it happens to open with.
    public static func IsQuestion(speech: String) -> Bool {
        let t: String = StActions.TrimEnds(speech);
        return StrLen(t) > 0 && Equals(StrMid(t, StrLen(t) - 1, 1), "?");
    }

    static func StartsYes(clause: String) -> Bool {
        return StrBeginsWith(clause, "yes") || StrBeginsWith(clause, "yeah")
            || StrBeginsWith(clause, "yep") || StrBeginsWith(clause, "sure")
            || StrBeginsWith(clause, "okay") || StrBeginsWith(clause, "ok")
            || StrBeginsWith(clause, "alright") || StrBeginsWith(clause, "all right")
            || StrBeginsWith(clause, "fine") || StrBeginsWith(clause, "of course")
            || StrBeginsWith(clause, "got it") || StrBeginsWith(clause, "you got it")
            || StrBeginsWith(clause, "deal") || StrBeginsWith(clause, "done")
            || StrBeginsWith(clause, "absolutely") || StrBeginsWith(clause, "let's do")
            || StrBeginsWith(clause, "right behind you") || StrBeginsWith(clause, "lead the way")
            || StrBeginsWith(clause, "after you") || StrBeginsWith(clause, "why not")
            || StrBeginsWith(clause, "guess so") || StrBeginsWith(clause, "i guess")
            || StrBeginsWith(clause, "count me in") || StrBeginsWith(clause, "on it")
            || StrBeginsWith(clause, "got him") || StrBeginsWith(clause, "got her")
            || StrBeginsWith(clause, "gotcha") || StrBeginsWith(clause, "consider it")
            || StrBeginsWith(clause, "with pleasure") || StrBeginsWith(clause, "say the word")
            || StrBeginsWith(clause, "done deal") || StrBeginsWith(clause, "you bet");
    }

    // Words that can only be a refusal, plus a bare "no" as a whole clause -
    // which is what "yeah, no" is, and what "no funny business" is not.
    static func HasRefusal(text: String) -> Bool {
        if StrContains(text, "rather not") || StrContains(text, "no way")
            || StrContains(text, "no thanks") || StrContains(text, "not happening")
            || StrContains(text, "can't") || StrContains(text, "cannot")
            || StrContains(text, "won't") || StrContains(text, "not going")
            || StrContains(text, "don't want") || StrContains(text, "don't think")
            || StrContains(text, "forget it") || StrContains(text, "no chance")
            || StrContains(text, "i'll pass") || StrContains(text, "another time")
            || StrContains(text, "maybe later") || StrContains(text, "sorry") {
            return true;
        }
        let parts: array<String> = StActions.Clauses(text);
        let i: Int32 = 0;
        while i < ArraySize(parts) {
            let c: String = parts[i];
            if Equals(c, "no") || Equals(c, "nope") || Equals(c, "nah")
                || Equals(c, "hell no") || Equals(c, "not a chance") {
                return true;
            }
            i += 1;
        }
        return false;
    }

    static func FirstClause(text: String) -> String {
        let parts: array<String> = StActions.Clauses(text);
        return ArraySize(parts) > 0 ? parts[0] : "";
    }

    // Split on what someone says between breaths. Written by hand rather than
    // with StrSplit because the string helpers in this game take their input
    // by reference and some of them edit it (StrReplaceAll ate every space in
    // a reply once), and a splitter is not worth that risk.
    static func Clauses(text: String) -> array<String> {
        let out: array<String>;
        let cur: String = "";
        let i: Int32 = 0;
        while i < StrLen(text) {
            let ch: String = StrMid(text, i, 1);
            if Equals(ch, ",") || Equals(ch, ".") || Equals(ch, "!")
                || Equals(ch, "?") || Equals(ch, ";") || Equals(ch, "-")
                || Equals(ch, "\n") {
                if !StActions.IsBlank(cur) {
                    ArrayPush(out, StActions.TrimEnds(cur));
                }
                cur = "";
            } else {
                cur += ch;
            }
            i += 1;
        }
        if !StActions.IsBlank(cur) {
            ArrayPush(out, StActions.TrimEnds(cur));
        }
        return out;
    }

    static func TrimEnds(text: String) -> String {
        let a: Int32 = 0;
        let b: Int32 = StrLen(text);
        while a < b && Equals(StrMid(text, a, 1), " ") {
            a += 1;
        }
        while b > a && Equals(StrMid(text, b - 1, 1), " ") {
            b -= 1;
        }
        return StrMid(text, a, b - a);
    }

    public func ApplyIntentFull(npc: ref<NPCPuppet>, beat: String, speech: String) -> Void {
        this.ApplyIntentAsked(npc, beat, speech, "");
    }

    public func ApplyIntentAsked(npc: ref<NPCPuppet>, beat: String, speech: String, asked: String) -> Void {
        if !IsDefined(npc) || npc.IsDead() {
            return;
        }
        let holding: Bool = StrLen(StActions.HeldItemName(npc)) > 0;
        let intent: String = StActions.ResolveIntent(beat, holding);
        // A bare "sure" against what V actually asked for.
        // A QUESTION IS NOT A YES. "Anything short of a refusal" was too
        // loose by far: Panam said "I'm not killing anyone", then "Shoot him?
        // That's a bad idea", and then asked "What has he done?" - and the
        // third one fired the shot, because a question contains no refusal
        // words (field report). What counts is an actual yes, or a beat in
        // which they do it. Nothing else.
        if StrLen(intent) == 0 && StrLen(asked) > 0 {
            if StActions.IsAffirmative(speech) && !StActions.IsQuestion(speech) {
                intent = asked;
                StLog(s"intent: they agreed to '\(asked)'");
            } else {
                // Silence here is what made this impossible to diagnose from a
                // log: an ask that went nowhere looked identical to no ask.
                StLog(s"intent: asked to '\(asked)' - reply did not read as agreement");
            }
        }
        if StrLen(intent) == 0 {
            return;
        }
        // Walking out ON you is a decision, not a contradiction: someone who
        // has had enough stops following AND goes. (This used to be blocked
        // outright, so an NPC who announced she was leaving just kept
        // trailing after you - field report.)
        if this.IsFollowing(npc) && (Equals(intent, "leave") || Equals(intent, "run")) {
            StLog("intent: they are done following you");
            this.StopFollowing(npc);
        }
        StLog(s"intent: beat resolved to \(intent)");
        if Equals(intent, "stop") {
            this.StopFollowing(npc);
            return;
        }
        if Equals(intent, "follow") {
            // ALWAYS ISSUE IT. "They are already following, so this is just
            // talk" assumed the list and the game agree - and after a reload
            // the list can hold someone the game never got the command for,
            // so every later request was swallowed and she said yes and stood
            // there (field report). Re-sending a follow command to someone
            // already following costs nothing.
            this.Follow(npc);
            return;
        }
        if Equals(intent, "run") {
            this.Leave(npc, true);
            return;
        }
        if Equals(intent, "leave") {
            this.Leave(npc, false);
            return;
        }
        if Equals(intent, "holster") {
            this.Holster(npc);
            return;
        }
        if Equals(intent, "drop") {
            this.DropHeld(npc);
            return;
        }
        if Equals(intent, "crowd") {
            this.JoinCrowd(npc);
            return;
        }
        if Equals(intent, "closer") {
            this.StepTo(npc, 1.6);
            return;
        }
        if Equals(intent, "back") {
            this.StepTo(npc, 4.0);
            return;
        }
        if Equals(intent, "attack") {
            this.Attack(npc);
            return;
        }
        if Equals(intent, "post") {
            // Their own spot, which the chat recorded when it opened.
            this.SendHome(npc);
        }
    }

    // Move to a point at a given distance from the player, along the line
    // between them - which covers "steps closer" and "backs off" without any
    // named-location parsing. Same move command the leave action uses.
    private func StepTo(npc: ref<NPCPuppet>, meters: Float) -> Void {
        let player = GetPlayer(npc.GetGame());
        if !IsDefined(player) {
            return;
        }
        let away: Vector4 = npc.GetWorldPosition() - player.GetWorldPosition();
        away.Z = 0.0;
        let dest: Vector4 = player.GetWorldPosition() + Vector4.Normalize(away) * meters;
        let cmd = new AIMoveToCommand();
        let wp: WorldPosition;
        WorldPosition.SetVector4(wp, dest);
        AIPositionSpec.SetWorldPosition(cmd.movementTarget, wp);
        cmd.movementType = moveMovementType.Walk;
        cmd.finishWhenDestinationReached = true;
        cmd.desiredDistanceFromTarget = 0.5;
        // A held NPC cannot take a step, same lesson as following.
        if IsDefined(this.holdCmd) {
            this.StopCmd(npc, this.holdCmd);
            this.holdCmd = null;
        }
        let ws = GameInstance.GetWorkspotSystem(npc.GetGame());
        if IsDefined(ws) && ws.IsActorInWorkspot(npc) {
            ws.StopInDevice(npc);
        }
        AIComponent.SendCommand(npc, cmd);
        StLog(s"action: moved to \(meters)m from the player");
    }

    // Walk off and become one of the pedestrians again. AIJoinCrowdCommand
    // (orphans.swift:47190) is the game's own crowd-reintegration move, so the
    // NPC does not just stop existing - they rejoin the street.
    private func JoinCrowd(npc: ref<NPCPuppet>) -> Void {
        if IsDefined(this.holdCmd) {
            this.StopCmd(npc, this.holdCmd);
            this.holdCmd = null;
        }
        this.chatTookOver = false;
        AIComponent.SendCommand(npc, new AIJoinCrowdCommand());
        StLog("action: joined the crowd");
        StActions.Announce("melts into the crowd");
    }

    // The game's own subtitle MARKUP. Foreign-language lines arrive as
    //   <mothertongue l="jpn" m="Arigatou" b="" a="! May ancestors ..."/>
    // where m/b/a are the readable pieces in order (field-caught: the tag went
    // into the chat verbatim). Everything else bracketed is stripped.
    static func Attr(text: String, name: String) -> String {
        let key: String = s"\(name)=\"";
        let at: Int32 = StrFindFirst(text, key);
        if at == -1 {
            return "";
        }
        let rest: String = StrMid(text, at + StrLen(key));
        let end: Int32 = StrFindFirst(rest, "\"");
        if end == -1 {
            return "";
        }
        return StrLeft(rest, end);
    }

    public static func CleanMarkup(text: String) -> String {
        if StrFindFirst(text, "<") == -1 {
            return text;
        }
        let out: String = text;
        if StrContains(text, "mothertongue") {
            let m: String = StActions.Attr(text, "m");
            let b: String = StActions.Attr(text, "b");
            let a: String = StActions.Attr(text, "a");
            let joined: String = m;
            if StrLen(b) > 0 {
                joined += StrLen(joined) > 0 ? " " + b : b;
            }
            if StrLen(a) > 0 {
                joined += a;
            }
            if StrLen(joined) > 0 {
                out = joined;
            }
        }
        return StActions.StripPair(out, "<", ">");
    }

    // CHAT-TEMPLATE MARKERS. A model that runs past its stop token spills the
    // raw template into the reply - "<|im_start|>assistant" and then a whole
    // invented next turn, read aloud by the TTS (field report). No prompt can
    // prevent it and no single server setting fixes it across model families,
    // so the text is cut at the first marker it contains. The list covers the
    // formats people actually run: ChatML (Qwen, Hermes, most 7Bs), Llama 3,
    // Mistral/Mixtral, Gemma, Phi, Alpaca-style, and plain sentinels.
    //
    // Anything after a marker is the model talking to itself, so truncating
    // beats stripping - and if the marker came first and truncation would
    // leave nothing, the markers are simply removed instead.
    public static func CleanTemplate(text: String) -> String {
        let marks: array<String> = [
            "<|im_start|>", "<|im_end|>", "<|endoftext|>", "<|eot_id|>",
            "<|start_header_id|>", "<|end_header_id|>", "<|eom_id|>",
            "<|user|>", "<|assistant|>", "<|system|>", "<|end|>",
            "<start_of_turn>", "<end_of_turn>", "[INST]", "[/INST]",
            "</s>", "<s>", "### Instruction", "### Response", "### Input",
            "<|channel|>", "<|message|>", "<|return|>"
        ];
        let cut: Int32 = -1;
        let i: Int32 = 0;
        while i < ArraySize(marks) {
            let at: Int32 = StrFindFirst(text, marks[i]);
            if at != -1 && (cut == -1 || at < cut) {
                cut = at;
            }
            i += 1;
        }
        if cut == -1 {
            return text;
        }
        let head: String = StrLeft(text, cut);
        if !StActions.IsBlank(head) {
            StLog("reply: chat-template marker found - text truncated there");
            return head;
        }
        // Marker at the very start: keep the words, drop the markers.
        let stripped: String = text;
        i = 0;
        while i < ArraySize(marks) {
            stripped = StrReplaceAll(stripped, marks[i], " ");
            i += 1;
        }
        StLog("reply: chat-template markers stripped");
        return stripped;
    }

    // The inverse of CleanProse: everything OUTSIDE the quotes (plus any
    // *asterisk* span), which is the model's stage direction - "I say,
    // looking the stranger over" - and exactly the search text the
    // animation picker wants. Bracket tags are actions, not directions.
    public static func ExtractDirection(text: String) -> String {
        let t: String = StrReplaceAll(StrReplaceAll(text, "\u{201C}", "\""), "\u{201D}", "\"");
        if StrFindFirst(t, "\"") == -1 {
            // NO QUOTES, BUT ASTERISKS: this is narration and nothing else -
            // "*Panam pulls the trigger, the bullet drops him*" is a whole
            // reply the model really wrote. It used to be thrown away twice
            // over: CleanProse strips asterisk spans, so no speech survived,
            // and this returned "" because there were no quotes, so there was
            // no beat to act on either. The result was an empty reply, a
            // panel stuck on "...", and an order to shoot that nothing ever
            // carried out (field report).
            //
            // No quotes AND no asterisks still means the whole reply is
            // speech - feeding that back as a direction is what made the word
            // "Look," in dialogue trigger a look-around animation.
            let beat: String = "";
            let rest0: String = t;
            let g0: Int32 = 0;
            while g0 < 8 {
                g0 += 1;
                let a0: Int32 = StrFindFirst(rest0, "*");
                if a0 == -1 {
                    break;
                }
                let tail0: String = StrMid(rest0, a0 + 1);
                let b0: Int32 = StrFindFirst(tail0, "*");
                if b0 == -1 {
                    break;
                }
                let span0: String = StrMid(rest0, a0 + 1, b0);
                beat += StrLen(beat) > 0 ? " " + span0 : span0;
                rest0 = StrMid(rest0, a0 + b0 + 2);
            }
            return StActions.StripTags(beat);
        }
        t = StActions.StripTags(t);
        // asterisk spans COUNT as direction - unwrap them
        t = StrReplaceAll(t, "*", " ");
        let outside: String = "";
        let guard: Int32 = 0;
        while guard < 16 {
            guard += 1;
            let q1: Int32 = StrFindFirst(t, "\"");
            if q1 == -1 {
                break;
            }
            let tail: String = StrMid(t, q1 + 1);
            let q2: Int32 = StrFindFirst(tail, "\"");
            if q2 == -1 {
                break;
            }
            outside += StrLeft(t, q1) + " ";
            t = StrMid(t, q1 + q2 + 2);
        }
        outside += t;
        return outside;
    }

    // Execute any bracketed tags in the reply and strip EVERY bracketed token
    // from the display text - matched or not. A 7B typos its tags ([FOLLW]
    // happened in the field: no action fired AND the garbage stayed on
    // screen), so matching is fuzzy and stripping is unconditional.
    public func Apply(npc: ref<NPCPuppet>, text: String) -> String {
        // BOTH bracket styles. The prompt demonstrates [FOLLOW], and the model
        // still wrote <follow> - which then neither fired nor got stripped, so
        // it sat on screen doing nothing (field report). Angle brackets are
        // parsed identically; template markers like <|im_start|> are already
        // gone by this point, so there is nothing else here shaped like a tag.
        let out: String = this.ApplyPair(npc, text, "[", "]");
        return this.ApplyPair(npc, out, "<", ">");
    }

    private func ApplyPair(npc: ref<NPCPuppet>, text: String, open: String, close: String) -> String {
        let out: String = "";
        let remaining: String = text;
        let guard: Int32 = 0;
        while guard < 8 {
            guard += 1;
            let lb: Int32 = StrFindFirst(remaining, open);
            if lb == -1 {
                break;
            }
            let tail: String = StrMid(remaining, lb);
            let rb: Int32 = StrFindFirst(tail, close);
            if rb == -1 {
                break;
            }
            let token: String = StrMid(remaining, lb + 1, rb - 1);
            out += StrLeft(remaining, lb);
            remaining = StrMid(remaining, lb + rb + 1);
            this.Execute(npc, token);
        }
        out += remaining;
        return out;
    }

    // Strip bracketed tokens WITHOUT executing - used on partial streamed
    // text, where "[FOLL" may not even be complete yet. Anything after an
    // unclosed '[' is hidden too, so half-written tags never flash on screen.
    public static func StripTags(text: String) -> String {
        return StActions.StripPair(StActions.StripPair(text, "[", "]"), "<", ">");
    }

    static func StripPair(text: String, open: String, close: String) -> String {
        let out: String = "";
        let remaining: String = text;
        let guard: Int32 = 0;
        while guard < 8 {
            guard += 1;
            let lb: Int32 = StrFindFirst(remaining, open);
            if lb == -1 {
                break;
            }
            let tail: String = StrMid(remaining, lb);
            let rb: Int32 = StrFindFirst(tail, close);
            out += StrLeft(remaining, lb);
            if rb == -1 {
                return out;   // unclosed tag mid-stream: hide the fragment
            }
            remaining = StrMid(remaining, lb + rb + 1);
        }
        out += remaining;
        return out;
    }

    // STRICT matching: single word, anchored prefix, short. The fuzzy
    // substring version fired on RP stage directions - "[rolls eyes]"
    // contains "oll" and sent Mama Welles sliding after the player,
    // uncommanded, in her wall-lean pose (field report). Typos like FOLLW
    // still match; prose never does.
    private func Execute(npc: ref<NPCPuppet>, token: String) -> Void {
        if !IsDefined(npc) || npc.IsDead() {
            return;
        }
        let up: String = StrUpper(token);
        // Money tags carry a number ("PAY 500"), so they are allowed a space
        // and more length - everything else stays strictly one short word.
        let isMoney: Bool = StrBeginsWith(StrUpper(token), "PAY")
            || StrBeginsWith(StrUpper(token), "CHARGE");
        if !isMoney && (StrFindFirst(token, " ") != -1 || StrLen(token) > 8) {
            StLog(s"action: non-tag [\(token)] stripped");
            return;
        }
        if isMoney && StrLen(token) > 16 {
            StLog("action: money tag too long - stripped");
            return;
        }
        // THREE LETTERS, not four. The model wrote "[FOLOW]" - one L - and a
        // four-letter prefix threw the whole action away (field report). The
        // token is already known to be a single short word, so three letters
        // is specific enough while surviving the typos a 7B actually makes.
        if StrBeginsWith(up, "FOL") {
            this.Follow(npc);
            return;
        }
        if StrBeginsWith(up, "STO") || StrBeginsWith(up, "WAI") {
            this.StopFollowing(npc);
            return;
        }
        if StrBeginsWith(up, "DRO") {
            this.DropHeld(npc);
            return;
        }
        if StrBeginsWith(up, "PAY") {
            this.Money(npc, token, true);
            return;
        }
        if StrBeginsWith(up, "ATT") || StrBeginsWith(up, "SHO") || StrBeginsWith(up, "KIL") {
            this.Attack(npc);
            return;
        }
        if StrBeginsWith(up, "CHARGE") {
            this.Money(npc, token, false);
            return;
        }
        if StrBeginsWith(up, "LEA") {
            this.Leave(npc, false);
            return;
        }
        if StrBeginsWith(up, "RUN") {
            this.Leave(npc, true);
            return;
        }
        StLog(s"action: unknown tag [\(token)] - stripped, not executed");
    }

    // ------------------------------------------------------------------
    //  Talking animation (optional). The workspot machinery is the game's
    //  (WorkspotGameSystem, orphans.swift:18381) but the anim ENTITY is
    //  AMM's - base\amm_workspots\entity\workspot_anim.ent, whose workspot
    //  enumerates hundreds of vanilla anims jumpable by name. The whole
    //  feature therefore switches on a runtime ResourceExists check: AMM
    //  installed = gestures, not installed = nothing, no hard dependency.
    //  Play recipe copied from AMM's Poses:PlayAnimationOnTarget
    //  (anims.lua:328): spawn at the NPC yaw+180, PlayInDeviceSimple with
    //  its component names, SendJumpToAnimEnt.
    // ------------------------------------------------------------------
    private let talkAnimEntId: EntityID;
    private let talkAnimating: Bool;
    private let talkAnimName: CName;
    private let talkAnimNpc: wref<NPCPuppet>;
    private let talkAnimTries: Int32;

    // ------------------------------------------------------------------
    //  SELF-CALIBRATING FACING. Three field reports in a row said the pose
    //  played at the wrong angle, because the relationship between the anim
    //  entity's yaw and the actor's final facing is an engine convention I
    //  cannot read anywhere - and guessing it burned three attempts.
    //
    //  So: stop guessing, MEASURE. Every gesture records the yaw it wanted
    //  and, once the animation is actually playing, the yaw the NPC really
    //  ended up with. The difference is the convention. It is logged, it
    //  corrects the current pose immediately, and it is remembered on disk -
    //  so at most ONE gesture on a fresh install is misaligned, and every
    //  one after that is right, on any machine, whatever the convention
    //  turns out to be.
    //
    //  The +90 seed below is what two of those field reports imply
    //  (actor_facing = entity_yaw - 90); if it is wrong the calibration
    //  absorbs it on the first measurement anyway.
    // ------------------------------------------------------------------
    private let talkDesiredYaw: Float;
    private let yawOffset: Float;
    private let yawLoaded: Bool;

    private func YawOffset() -> Float {
        if this.yawLoaded {
            return this.yawOffset;
        }
        this.yawLoaded = true;
        let fs = StreetTalkFS.Get();
        if IsDefined(fs) && IsDefined(fs.Storage()) {
            let f = fs.Storage().GetFile("anim_yaw.txt");
            if IsDefined(f) {
                this.yawOffset = StringToFloat(f.ReadAsText(), 0.0);
            }
        }
        return this.yawOffset;
    }

    private func SaveYawOffset(v: Float) -> Void {
        this.yawOffset = v;
        this.yawLoaded = true;
        let fs = StreetTalkFS.Get();
        if IsDefined(fs) && IsDefined(fs.Storage()) {
            let f = fs.Storage().GetFile("anim_yaw.txt");
            if IsDefined(f) {
                f.WriteText(FloatToStringPrec(v, 2));
            }
        }
    }

    // Runs a beat after the animation actually starts playing.
    public func VerifyTalkYaw() -> Void {
        let npc = this.talkAnimNpc;
        if !this.talkAnimating || !IsDefined(npc) || npc.IsDead() {
            return;
        }
        // Measured against where the player actually is, not against a
        // remembered number - the old comparison used a desired yaw that was
        // zero in every log it ever printed.
        let player = GetPlayer(npc.GetGame());
        if !IsDefined(player) {
            return;
        }
        let toP: Vector4 = player.GetWorldPosition() - npc.GetWorldPosition();
        toP.Z = 0.0;
        let want: Float = Vector4.ToRotation(toP).Yaw;
        let actual: Float = Quaternion.ToEulerAngles(npc.GetWorldOrientation()).Yaw;
        let err: Float = StActions.Norm180(want - actual);
        StLog(s"gesture yaw: facing \(actual), player is at \(want), off by \(err)");
        if AbsF(err) > 20.0 {
            this.TurnToPlayer(npc, "gesture left them facing away");
        }
    }

    // The FALLBACK pool - used when the reply's stage direction matched
    // nothing, which is most ordinary conversation. One entry per distinct
    // POSTURE (hands on hips, arms folded, hands behind back, open gesture),
    // every name taken from a query against the installed animation database
    // and filtered to standing, prop-free, single-actor loops. Was three
    // names per gender, which read as "she does the same two animations over
    // and over" (field report).
    static func PickAnimF(text: String) -> CName {
        if StrContains(text, "!") {
            return n"stand__2h_on_hip__01__conversation_step__nervous__01";
        }
        let i: Int32 = StrLen(text) % 7;
        if i == 0 { return n"alt__stand__2h_on_sides__01__talk__01"; }
        if i == 1 { return n"stand__2h_back__01__talk__01"; }
        if i == 2 { return n"stand__2h_on_hip__02__talk__01"; }
        if i == 3 { return n"stand__2h_up__02__talk__01"; }
        if i == 4 { return n"stand__arms_crossed_front__02__talk__01"; }
        if i == 5 { return n"stand__2h_on_sides__01__talk__neutral__01"; }
        return n"stand__2h_on_hip__01__talk__neutral__01";
    }

    static func PickAnimM(text: String) -> CName {
        if StrContains(text, "!") {
            return n"stand__2h_on_sides__01__conversation_step__nervous__01";
        }
        let i: Int32 = StrLen(text) % 7;
        if i == 0 { return n"dirt__stand__2h_on_hip__01__talk__01"; }
        if i == 1 { return n"stand__2h_folded__02__talk__01"; }
        if i == 2 { return n"stand__2h_front__01__talk__01"; }
        if i == 3 { return n"stand__lh_crossed_front__01__talk__nostalgic__01"; }
        if i == 4 { return n"stand__2h_up__02__talk__01"; }
        if i == 5 { return n"stand__arms_crossed_front__01__talk__01"; }
        return n"stand__2h_on_sides__06__talk__01";
    }

    public func StartTalking(npc: ref<NPCPuppet>, gender: String, appearance: String, text: String, animOverride: CName) -> Void {
        if this.talkAnimating || !IsDefined(npc) || npc.IsDead() || npc.IsCharacterChildren() {
            return;
        }
        // A follower stays a follower. Playing a gesture would put them back
        // in a workspot and end the follow - so while they are walking with
        // you they talk without their hands.
        if this.IsFollowing(npc) {
            StLog("gesture: skipped - NPC is following");
            return;
        }
        // Each skip logs its reason (Debug Log on): "no gesture" reports
        // must diagnose themselves, same rule as the voice ladder.
        // The anims are authored for the Average rigs; on heavy bodies they
        // distort. Appearance tokens are the only rig hint script can see.
        let app: String = StrLower(appearance);
        if StrContains(app, "fat") || StrContains(app, "big") || StrContains(app, "massive") {
            StLog("gesture: skipped - heavy-body rig");
            return;
        }
        // Rig-matched, MOOD-matched picks - every name a verified row of
        // AMM's own database. The catalog names are honestly descriptive
        // (nervous, arms_crossed, nostalgic), so cheap text cues buy real
        // relevance: exclamations get animated hands, questions get open
        // ones, and the seed varies the pick per reply. Unknown gender
        // means unknown rig: no animation beats a glitched one.
        // The server may have picked one already - it can work the rig out from
        // the character's own voice files when the game cannot (Panam's record
        // carries no gender at all, and gestures were being skipped for her
        // entirely). A pick from there is proof enough of the rig.
        let anim: CName;
        if IsNameValid(animOverride) {
            // The voice server searched AMM's whole animation database with
            // the model's own stage direction - its pick beats our
            // three-anim heuristic whenever it exists.
            anim = animOverride;
        } else {
            if Equals(gender, "Female") {
                anim = StActions.PickAnimF(text);
            } else {
                if Equals(gender, "Male") {
                    anim = StActions.PickAnimM(text);
                } else {
                    // Unknown gender used to mean NO GESTURE AT ALL, which is
                    // how a character whose record carries no gender (Panam)
                    // ended up standing perfectly still through every
                    // conversation. A wrong-rig gesture is a bit stiff; no
                    // gesture reads as broken. Take the woman-rig loops, which
                    // are the ones authored for civilian conversation.
                    StLog("gesture: gender unknown - using the neutral pool");
                    anim = StActions.PickAnimF(text);
                }
            }
        }
        let game = npc.GetGame();
        let ws = GameInstance.GetWorkspotSystem(game);
        if !IsDefined(ws) {
            return;
        }
        // A gesture IS a workspot, so when one finishes the NPC's own AI
        // walks them back into their authored routine - and every later reply
        // then found them "in a workspot" and skipped, which is why one NPC
        // gestured once and never again (field report). If they are someone
        // we already took over, step them out again; if we never took them
        // over, their pose is theirs to keep.
        if ws.IsActorInWorkspot(npc) {
            if !this.chatTookOver {
                StLog("gesture: skipped - NPC kept their authored pose");
                return;
            }
            ws.StopInDevice(npc);
        }
        if !GameInstance.GetResourceDepot().ResourceExists(r"base\\amm_workspots\\entity\\workspot_anim.ent") {
            StLog("gesture: skipped - AMM not installed");
            return;
        }
        let spec = new DynamicEntitySpec();
        spec.templatePath = r"base\\amm_workspots\\entity\\workspot_anim.ent";
        spec.position = npc.GetWorldPosition();
        // The wanted facing, straight from the engine's own direction->angle
        // converter (no convention guessed here), plus the learned offset
        // that VerifyTalkYaw measures and remembers.
        let e: EulerAngles;
        let facePlayer = GetPlayer(game);
        if IsDefined(facePlayer) {
            let toPlayer: Vector4 = facePlayer.GetWorldPosition() - npc.GetWorldPosition();
            toPlayer.Z = 0.0;
            this.talkDesiredYaw = Vector4.ToRotation(toPlayer).Yaw;
        } else {
            this.talkDesiredYaw = Quaternion.ToEulerAngles(npc.GetWorldOrientation()).Yaw;
        }
        e.Yaw = StActions.Norm180(this.talkDesiredYaw + 90.0 + this.YawOffset());
        spec.orientation = EulerAngles.ToQuat(e);
        ArrayPush(spec.tags, n"StreetTalk.TalkAnim");
        this.talkAnimEntId = GameInstance.GetDynamicEntitySystem().CreateEntity(spec);
        this.talkAnimName = anim;
        this.talkAnimNpc = npc;
        this.talkAnimTries = 0;
        this.talkAnimating = true;
        this.ScheduleTalkTick(game);
    }

    private func ScheduleTalkTick(game: GameInstance) -> Void {
        let tick = new StTalkAnimTick();
        tick.actions = this;
        GameInstance.GetDelaySystem(game).DelayCallback(tick, 0.15, false);
    }

    // Spawn is asynchronous; poll briefly, then play. AMM polls the same way.
    public func TalkAnimTick() -> Void {
        if !this.talkAnimating {
            return;
        }
        let npc = this.talkAnimNpc;
        if !IsDefined(npc) || npc.IsDead() {
            this.StopTalking(null);
            return;
        }
        let ent = GameInstance.GetDynamicEntitySystem().GetEntity(this.talkAnimEntId);
        if !IsDefined(ent) {
            this.talkAnimTries += 1;
            if this.talkAnimTries > 12 {
                this.talkAnimating = false;
                GameInstance.GetDynamicEntitySystem().DeleteEntity(this.talkAnimEntId);
                return;
            }
            this.ScheduleTalkTick(npc.GetGame());
            return;
        }
        let ws = GameInstance.GetWorkspotSystem(npc.GetGame());
        if IsDefined(ws) {
            // PlayAtResourcePosition, NOT AMM's DontPlayAtResourcePosition.
            // AMM poses NPCs exactly where the user put them, so it tells the
            // workspot to ignore the resource transform - which is precisely
            // why the entity's yaw kept having no effect and NPCs played
            // their gestures facing away. Letting the resource transform win
            // makes the orientation deterministic (the entity is spawned at
            // the NPC's own position, so nobody moves), and removes the
            // corrective teleport that was causing the jitter on the way in.
            // THE GESTURE NO LONGER DECIDES WHICH WAY SHE FACES.
            // PlayAtResourcePosition hands her orientation to the workspot
            // resource, which meant her facing came out of a hardcoded "+90
            // degrees" convention plus an offset a verification loop was
            // supposed to learn - and that loop has been comparing "wanted
            // 0.000000" against "got -0.000000" in every log, so it has never
            // learned anything. That is why she faces V, then turns away the
            // moment she starts talking (field report).
            //
            // AMM's own choice is the right one: don't move the actor. Facing
            // belongs to the turn in PrepareForChat, which is measured against
            // the player's actual position, and it is re-applied below so a
            // gesture cannot quietly undo it.
            ws.PlayInDeviceSimple(ent as GameObject, npc, false, n"amm_workspot_base",
                n"AMM_WORKSPOT", n"", 0.0, WorkspotSlidingBehaviour.DontPlayAtResourcePosition, null);
            ws.SendJumpToAnimEnt(npc, this.talkAnimName, true);
            StLog(s"gesture: playing \(this.talkAnimName)");
            this.TurnToPlayer(npc, "after the gesture started");

            // Re-assert the hold: entering a workspot can clear commands, and
            // an un-held NPC is one that wanders mid-conversation.
            if this.chatTookOver && IsDefined(this.holdCmd) {
                AIComponent.SendCommand(npc, this.holdCmd);
            }
            // Then measure what actually happened and learn from it.
            let check = new StTalkYawTick();
            check.actions = this;
            GameInstance.GetDelaySystem(npc.GetGame()).DelayCallback(check, 0.35, false);
        }
    }

    // ------------------------------------------------------------------
    //  Facial engagement while speaking. There is no mouth-flap: the game's
    //  lip animation is generated from ITS own VO inside the scene system,
    //  and the scriptable facial-reaction catalog is emotions only (checked
    //  against AMM's full expression table - the mechanism AMM's Facial
    //  Expression feature uses, tools.lua:2377). What CAN be done: put a
    //  living expression on the face for the duration of the line, varied
    //  per sentence, and let it settle back to neutral after. Unlike the
    //  body gestures this needs no AMM and is safe for workspot NPCs -
    //  AnimFeature_FacialReaction {category, idle} via the public
    //  ApplyFeature static (animationControllerComponent.swift:30).
    // ------------------------------------------------------------------
    private let faceActive: Bool;

    public func FaceTalk(npc: ref<NPCPuppet>, direction: String) -> Void {
        if !IsDefined(npc) || npc.IsDead() {
            return;
        }
        // The stage direction names the emotion more often than not -
        // "she smiles", "he snaps", "shifts nervously" - and the catalog
        // (AMM's verified category/idle table) has a face for each.
        let d: String = StrLower(direction);
        let cat: Int32 = 0;
        let idle: Int32 = 0;
        if StrContains(d, "smil") || StrContains(d, "grin") {
            cat = 3; idle = 6;
        } else { if StrContains(d, "laugh") || StrContains(d, "joy") {
            cat = 3; idle = 5;
        } else { if StrContains(d, "angr") || StrContains(d, "scowl") || StrContains(d, "glare") || StrContains(d, "snap") {
            cat = 3; idle = 1;
        } else { if StrContains(d, "nervous") || StrContains(d, "uneas") || StrContains(d, "fidget") {
            cat = 3; idle = 10;
        } else { if StrContains(d, "sad") || StrContains(d, "sigh") {
            cat = 3; idle = 3;
        } else { if StrContains(d, "surpris") || StrContains(d, "startl") || StrContains(d, "shock") {
            cat = 3; idle = 8;
        } else { if StrContains(d, "fear") || StrContains(d, "afraid") || StrContains(d, "terrif") {
            cat = 3; idle = 11;
        } else { if StrContains(d, "disgust") || StrContains(d, "sneer") {
            cat = 3; idle = 7;
        } else {
            // no cue: alternate interested / engaged-neutral
            if StrLen(d) % 2 == 0 {
                cat = 1; idle = 3;
            } else {
                cat = 2; idle = 2;
            }
        }}}}}}}}
        let feat = new AnimFeature_FacialReaction();
        feat.category = cat;
        feat.idle = idle;
        AnimationControllerComponent.ApplyFeature(npc, n"FacialReaction", feat);
        this.faceActive = true;
    }

    public func FaceRest(npc: ref<NPCPuppet>) -> Void {
        if !this.faceActive {
            return;
        }
        this.faceActive = false;
        if !IsDefined(npc) {
            return;
        }
        let feat = new AnimFeature_FacialReaction();
        feat.category = 2;
        feat.idle = 2;
        AnimationControllerComponent.ApplyFeature(npc, n"FacialReaction", feat);
    }

    public func StopTalking(npc: ref<NPCPuppet>) -> Void {
        if !this.talkAnimating {
            return;
        }
        this.talkAnimating = false;
        let who: wref<NPCPuppet> = npc;
        if !IsDefined(who) {
            who = this.talkAnimNpc;
        }
        if IsDefined(who) {
            GameInstance.GetWorkspotSystem(who.GetGame()).StopInDevice(who);
        }
        GameInstance.GetDynamicEntitySystem().DeleteEntity(this.talkAnimEntId);
    }

    // ------------------------------------------------------------------
    //  Held items. GetItemInSlot on the Weapon slots is how the game's own
    //  held-item animation code checks hands (animationControllerComponent
    //  .swift:50); DropItemFromSlot is the public static its unequip
    //  subactions call (scriptedPuppet.swift:2476). The persona tells the
    //  model what its hands are doing so it never promises "let me pull up
    //  a Nicola" around a gun it cannot stow - and [DROP] lets it decide
    //  to put the thing down.
    // ------------------------------------------------------------------
    public static func HeldItemName(npc: ref<NPCPuppet>) -> String {
        if !IsDefined(npc) {
            return "";
        }
        let ts = GameInstance.GetTransactionSystem(npc.GetGame());
        if !IsDefined(ts) {
            return "";
        }
        let item = ts.GetItemInSlot(npc, t"AttachmentSlots.WeaponRight");
        if !IsDefined(item) {
            item = ts.GetItemInSlot(npc, t"AttachmentSlots.WeaponLeft");
        }
        if !IsDefined(item) {
            return "";
        }
        let rec = TweakDBInterface.GetItemRecord(ItemID.GetTDBID(item.GetItemID()));
        if !IsDefined(rec) {
            return "";
        }
        let name: String = LocKeyToString(rec.DisplayName());
        if StrBeginsWith(name, "LocKey#") {
            name = GetLocalizedText(name);
        }
        return name;
    }

    // [LEAVE] - they end the conversation by walking away, and can be told to
    // run. There is no on-foot flee command in the scriptable layer (only
    // vehicle panic), so this is the game's own move-to command aimed at a
    // point away from the player: AIMoveToCommand{movementTarget,
    // movementType} with AIPositionSpec.SetWorldPosition, the same pieces
    // the quickhack "come here" effector uses (quickhackEffectors.swift:912).
    private func Leave(npc: ref<NPCPuppet>, run: Bool) -> Void {
        let player = GetPlayer(npc.GetGame());
        if !IsDefined(player) {
            return;
        }
        let away: Vector4 = npc.GetWorldPosition() - player.GetWorldPosition();
        away.Z = 0.0;
        let dest: Vector4 = npc.GetWorldPosition() + Vector4.Normalize(away) * 18.0;
        let cmd = new AIMoveToCommand();
        // AIPositionSpec takes a WorldPosition, not a Vector4 (compile gate
        // caught it) - WorldPosition.SetVector4 converts, orphans.swift:11247.
        let wp: WorldPosition;
        WorldPosition.SetVector4(wp, dest);
        AIPositionSpec.SetWorldPosition(cmd.movementTarget, wp);
        cmd.movementType = run ? moveMovementType.Run : moveMovementType.Walk;
        cmd.ignoreNavigation = false;
        cmd.finishWhenDestinationReached = true;
        cmd.desiredDistanceFromTarget = 1.0;
        // Leaving means leaving: the hold that kept them here is what would
        // stop them, and going home on chat close would undo it.
        if IsDefined(this.holdCmd) {
            this.StopCmd(npc, this.holdCmd);
            this.holdCmd = null;
        }
        this.chatTookOver = false;
        AIComponent.SendCommand(npc, cmd);
        StLog(run ? "action: LEAVE (running)" : "action: LEAVE (walking)");
        StActions.Announce(run ? "runs off" : "walks away");
    }

    // [PAY n] / [CHARGE n] - eddies actually move. Money is an ITEM in this
    // game (Items.money, quantity-based - the HUB menu reads the player's
    // balance exactly this way, hubMenuGameController.swift:146), so the
    // transaction system's own GiveItem/RemoveItem do the work
    // (orphans.swift:18031-18035). A vendor who agrees to a price can now
    // honour it, and a fixer who owes you can pay.
    //
    // GUARDRAILS, because a language model deciding your bank balance is a
    // real hazard: one transfer per reply, hard cap, and CHARGE can never take
    // more than you have.
    private let paidThisReply: Bool;
    private func Money(npc: ref<NPCPuppet>, token: String, toPlayer: Bool) -> Void {
        if this.paidThisReply {
            StLog("money: ignored - one transfer per reply");
            return;
        }
        let player = GetPlayer(npc.GetGame());
        let ts = GameInstance.GetTransactionSystem(npc.GetGame());
        if !IsDefined(player) || !IsDefined(ts) {
            return;
        }
        // Digits only, from anywhere in the token: PAY500, PAY 500, PAY_500.
        let digits: String = "";
        let i: Int32 = 0;
        while i < StrLen(token) {
            let ch: String = StrMid(token, i, 1);
            if StrFindFirst("0123456789", ch) != -1 {
                digits += ch;
            }
            i += 1;
        }
        let amount: Int32 = StringToInt(digits, 0);
        if amount <= 0 {
            return;
        }
        if amount > 5000 {
            amount = 5000;   // a street conversation is not a wire transfer
        }
        let query: ItemID = ItemID.CreateQuery(t"Items.money");
        if toPlayer {
            ts.GiveItem(player, query, amount);
            StLog(s"money: NPC paid the player \(amount)");
            StActions.Announce(s"hands you \(amount) eddies");
        } else {
            let have: Int32 = ts.GetItemQuantity(player, query);
            if have < amount {
                amount = have;
            }
            if amount > 0 {
                ts.RemoveItem(player, query, amount);
                StLog(s"money: player paid the NPC \(amount)");
                StActions.Announce(s"takes \(amount) eddies");
            }
        }
        this.paidThisReply = true;
    }

    // Called once per reply, before tags are executed.
    public func BeginReply() -> Void {
        this.paidThisReply = false;
    }

    // [ATTACK] - they turn on whoever you are pointing at. The game's own way
    // of setting one agent against another (aiActionHelper.swift:304): flip
    // the attitude and push a threat so the AI acts on it now rather than
    // eventually.
    //
    // THE TARGET IS WHOEVER YOU ARE LOOKING AT. NPCs cannot enumerate who is
    // nearby - no script API exposes that - but they do not need to: your
    // crosshair is the referent, so "him" is unambiguous and needs no world
    // knowledge at all.
    // Arm them, if they are not already. Two routes, no invented item ids:
    //   1. They own a weapon -> AISwitchToPrimaryWeaponCommand draws it.
    //      Gangers, guards and cops all carry; this is just "pull your piece".
    //   2. They own nothing -> they get a copy of WHATEVER YOU ARE HOLDING.
    //      The player's equipped weapon gives a real, verified-at-runtime item
    //      id, so nothing is hardcoded and nothing is guessed - and a civilian
    //      pulling the same gun you are carrying reads better than an empty
    //      hand refusing an order.
    // Turn them to face V, in steps, over about a third of a second. One
    // implementation, used when a chat opens and again whenever something
    // else has moved them - a gesture, a walk, their own AI.
    private let lastTurnAt: Float;
    private let turnGaveUp: Bool;

    public func TurnToPlayer(npc: ref<NPCPuppet>, why: String) -> Void {
        if !IsDefined(npc) || npc.IsDead() {
            return;
        }
        // A COMPANION'S FEET BELONG TO THEIR OWN LOCOMOTION. Teleporting a
        // walking follower to a new yaw is undone by their movement the same
        // frame - the log shows the identical "turning 101.6 degrees" over and
        // over with the heading never moving. They get the look-at and nothing
        // else, which is what the game does for its own companions.
        if this.IsFollowing(npc) {
            if !this.turnGaveUp {
                this.turnGaveUp = true;
                StLog("chat: not turning a walking companion - their own movement owns their facing");
            }
            this.FacePlayer(npc, 1.0);
            return;
        }
        let game = npc.GetGame();
        let ws = GameInstance.GetWorkspotSystem(game);
        // A WORKSPOT IS NOT A REASON TO TALK TO SOMEONE'S BACK. This used to
        // return silently for anyone standing in an authored idle, to avoid
        // fighting their animation - which is why Panam, leaning on something
        // in the camp, was measured 168 degrees off and never turned once
        // (probe: want=78.14 have=-90.00). Step them out of the idle instead,
        // and mark that we did, so closing the chat puts them back exactly
        // where and how they were.
        if IsDefined(ws) && ws.IsActorInWorkspot(npc) && !this.talkAnimating {
            ws.StopInDevice(npc);
            this.chatTookOver = true;
            StLog("chat: stepped them out of an idle so they can face you");
            // AND COME BACK IN A MOMENT. A puppet still parented to a workspot
            // reports a useless transform - which is where every
            // "want=0.000000 have=-0.000000" in the log came from - so
            // measuring it in the same breath as releasing it measures
            // nothing. Let the release land first.
            let retry = new StTurnRetry();
            retry.actions = this;
            retry.npc = npc;
            retry.why = why;
            GameInstance.GetDelaySystem(game).DelayCallback(retry, 0.35, false);
            return;
        }
        let player = GetPlayer(game);
        if !IsDefined(player) {
            StLog("chat: cannot turn them - no player to turn towards");
            return;
        }
        let pp: Vector4 = player.GetWorldPosition();
        let np: Vector4 = npc.GetWorldPosition();
        let dir: Vector4 = pp - np;
        dir.Z = 0.0;

        // NO QUATERNION, NO YAW CONVENTION. GetWorldOrientation comes back as
        // an all-zero quaternion for this puppet - the probe printed
        // quat=(0, 0, 0) - so every angle derived from it was meaningless, and
        // that is where "off by 0.000000" came from, not from the arithmetic.
        //
        // The AI answers this question about itself with vectors instead
        // (tweakAIAction.swift:1226): the signed angle from where they are
        // facing to where the target is, measured around their own up axis.
        // Vector4.Heading then turns a direction into the yaw a teleport
        // wants (followSlotsComponent.swift:41 uses it the same way).
        let fwd: Vector4 = npc.GetWorldForward();
        let delta: Float = Vector4.GetAngleDegAroundAxis(fwd, dir, npc.GetWorldUp());
        let want: Float = Vector4.Heading(dir);
        let have: Float = Vector4.Heading(fwd);
        if AbsF(delta) < 12.0 {
            StLog(s"chat: no turn needed, off by \(delta)"
                + s" | facing=(\(fwd.X), \(fwd.Y)) toPlayer=(\(dir.X), \(dir.Y))"
                + s" heading=\(have) want=\(want)");
            return;
        }
        StLog(s"chat: turning \(delta) degrees to face the player - \(why)"
            + s" | heading=\(have) want=\(want)");
        let i: Int32 = 1;
        while i <= 6 {
            let step = new StTurnStep();
            step.actions = this;
            step.npc = npc;
            step.yaw = have + StActions.Norm180(want - have) * (Cast<Float>(i) / 6.0);
            GameInstance.GetDelaySystem(game).DelayCallback(step, 0.05 * Cast<Float>(i), false);
            i += 1;
        }
    }

    // Called by the poller while the panel is open. A conversation is not a
    // single moment: V walks around, and someone who turned to face V once is
    // facing the wrong way a few seconds later. Anyone mid-fight is left
    // alone - they have somewhere else to point.
    public func KeepFacing(npc: ref<NPCPuppet>) -> Void {
        if !IsDefined(npc) || npc.IsDead() || IsDefined(this.attackNpc) {
            return;
        }
        // NOT EVERY TICK. This ran at the poller's rate: six teleports and a
        // log line every fifth of a second, for a turn that could not take -
        // which floods the log, rewrites the log file hundreds of times, and
        // fights the NPC's own animation while doing it (field report: "what
        // is going on with the chat").
        let now: Float = EngineTime.ToFloat(GameInstance.GetSimTime(npc.GetGame()));
        if now - this.lastTurnAt < 3.0 {
            return;
        }
        this.lastTurnAt = now;
        this.TurnToPlayer(npc, "keeping their eyes on you");
        this.FacePlayer(npc, this.bodyTurned ? 1.0 : 0.2);
    }

    // OUR OWN, BECAUSE THE GAME'S RETURNS ZERO HERE. Every angle this mod
    // ever measured came out "0.000000" - the gesture-yaw learner that never
    // learned, and every turn that decided it had nothing to do - and all of
    // them went through AngleNormalize180. The probe, which normalises with
    // this loop instead, printed correct angles in the same session on the
    // same data (off=168.14 while the turn beside it saw 0.00). Whatever that
    // native does, it is not this.
    public static func Norm180(a: Float) -> Float {
        let x: Float = a;
        while x > 180.0 {
            x -= 360.0;
        }
        while x < -180.0 {
            x += 360.0;
        }
        return x;
    }

    public func TurnTo(npc: ref<NPCPuppet>, yaw: Float) -> Void {
        if !IsDefined(npc) || npc.IsDead() {
            return;
        }
        // Built fresh rather than read back from GetWorldOrientation, which
        // returns an all-zero quaternion for these puppets.
        let rot: EulerAngles;
        rot.Pitch = 0.0;
        rot.Roll = 0.0;
        rot.Yaw = yaw;
        GameInstance.GetTeleportationFacility(npc.GetGame())
            .Teleport(npc, npc.GetWorldPosition(), rot);
    }

    public func ReportArmed(npc: ref<NPCPuppet>) -> Void {
        let ts = GameInstance.GetTransactionSystem(npc.GetGame());
        if !IsDefined(ts) {
            return;
        }
        let held = ts.GetItemInSlot(npc, t"AttachmentSlots.WeaponRight");
        if !IsDefined(held) {
            held = ts.GetItemInSlot(npc, t"AttachmentSlots.WeaponLeft");
        }
        // Everything the game will admit to, two seconds in - all of it read
        // back rather than assumed, because every guess so far has been wrong
        // in a way the log could have caught.
        let sv: Float = GameInstance.GetStatsSystem(npc.GetGame())
            .GetStatValue(Cast<StatsObjectID>(npc.GetEntityID()), gamedataStatType.IsAggressive);
        StLog(s"attack: armed=\(IsDefined(held)) aggressive=\(npc.IsAggressive()) stat=\(sv)"
            + s" inCombat=\(Equals(npc.GetHighLevelStateFromBlackboard(), gamedataNPCHighLevelState.Combat))"
            + s" alerted=\(Equals(npc.GetHighLevelStateFromBlackboard(), gamedataNPCHighLevelState.Alerted))");
    }

    private func Arm(npc: ref<NPCPuppet>) -> Void {
        let game = npc.GetGame();
        let ts = GameInstance.GetTransactionSystem(game);
        if !IsDefined(ts) {
            return;
        }
        if IsDefined(ts.GetItemInSlot(npc, t"AttachmentSlots.WeaponRight"))
            || IsDefined(ts.GetItemInSlot(npc, t"AttachmentSlots.WeaponLeft")) {
            return;   // already holding something
        }
        // Draw whatever they own.
        AIComponent.SendCommand(npc, new AISwitchToPrimaryWeaponCommand());

        let player = GetPlayer(game);
        if !IsDefined(player) {
            return;
        }
        // YOUR LOADOUT, not your hands. Standing in a conversation with your
        // weapon holstered is the normal state, and reading the hand slot
        // meant she was handed nothing and just stood there (field report).
        // EquipmentSystem knows what you have EQUIPPED even when it is on your
        // back (equipmentSystem.swift:4489).
        let tdbid: TweakDBID = t"";
        let equip = EquipmentSystem.GetData(player);
        if IsDefined(equip) {
            let slotted: ItemID = equip.GetActiveItem(gamedataEquipmentArea.Weapon);
            if ItemID.IsValid(slotted) {
                tdbid = ItemID.GetTDBID(slotted);
            }
        }
        // Failing that, whatever is actually in your hand right now.
        if !TDBID.IsValid(tdbid) {
            let mine = ts.GetItemInSlot(player, t"AttachmentSlots.WeaponRight");
            if IsDefined(mine) {
                tdbid = ItemID.GetTDBID(mine.GetItemID());
            }
        }
        if !TDBID.IsValid(tdbid) {
            // Bare hands are a valid answer - the hostility still stands, she
            // just swings instead of shooting.
            StLog("arm: nothing equipped to copy - they go in unarmed");
            return;
        }
        // A COPY. Your own weapon never leaves your inventory - this creates a
        // new instance for them, so handing someone your one-of-a-kind iconic
        // costs you nothing.
        ts.GiveItemByTDBID(npc, tdbid, 1);
        let equipCmd = new AIEquipCommand();
        equipCmd.slotId = t"AttachmentSlots.WeaponRight";
        equipCmd.itemId = tdbid;
        equipCmd.failIfItemNotFound = false;
        AIComponent.SendCommand(npc, equipCmd);
        StLog("arm: gave them a copy of your equipped weapon");
        StActions.Announce("pulls a piece");
    }

    // IS THIS A FIGHT OR A MURDER? The game already draws the line the player
    // sees: an NPC hostile towards V is the one with the chevron over their
    // head, who will draw on V anyway and whose death costs no stars. A
    // civilian is the opposite of that, and killing one brings the cops.
    //
    // Nobody is off limits - a companion who is talked into it can still
    // shoot a bystander - but the bar is not the same. Being asked to shoot
    // someone already trying to kill you is not much of a question.
    // WHO "HIM" IS. The crosshair alone was the answer, which cannot work
    // while a chat panel is open and V is typing: by the time the reply lands
    // the camera has drifted and there is nobody in the crosshair at all, so
    // an order to shoot resolved to nothing (field report, whole conversation
    // of it). Whoever V was last looking at, recently, is what "him" means.
    // The last person ordered to attack, and who they were pointed at. Only
    // used by the diagnostics (StreetTalkDiag.reds).
    private let attackNpc: wref<NPCPuppet>;
    private let attackTarget: wref<GameObject>;
    private let beforeAttitude: EAIAttitude;
    private let hadAttitude: Bool;
    private let standDownTries: Int32;

    public func IsUnderOrders(npc: ref<NPCPuppet>) -> Bool {
        return IsDefined(npc) && IsDefined(this.attackNpc)
            && EntityID.ToHash(npc.GetEntityID())
               == EntityID.ToHash(this.attackNpc.GetEntityID());
    }

    private let markNpc: wref<GameObject>;
    private let markAt: Float;
    // Kept apart from the last person seen, because while V types "shoot him"
    // the camera is usually pointed at the companion being asked, not at the
    // person V means. The last HOSTILE V looked at is almost always the one.
    private let markHostile: wref<GameObject>;
    private let markHostileAt: Float;

    // Called every tick by the poller, chat open or not.
    public func NoteLookedAt(obj: ref<GameObject>, now: Float) -> Void {
        if !IsDefined(obj) || obj.IsDead() {
            return;
        }
        let asNpc = obj as NPCPuppet;
        if IsDefined(asNpc) && this.IsFollowing(asNpc) {
            return;   // the person being talked to is not the person meant
        }
        this.markNpc = obj;
        this.markAt = now;
        if StActions.IsFairGame(obj) {
            this.markHostile = obj;
            this.markHostileAt = now;
        }
    }

    // A robot is not a civilian and does not have to be a person: whatever
    // wears the chevron and shoots back is fair game.
    public static func IsFairGame(obj: ref<GameObject>) -> Bool {
        if !IsDefined(obj) {
            return false;
        }
        let puppet = obj as ScriptedPuppet;
        if IsDefined(puppet) && puppet.IsCivilian() {
            return false;
        }
        return obj.IsHostile() || (IsDefined(puppet) && puppet.IsAggressive());
    }

    public func AimedAt(game: GameInstance) -> ref<GameObject> {
        // 45 seconds: long enough to look at someone, open a chat and argue
        // about it, short enough that it is still the person V meant.
        let now: Float = EngineTime.ToFloat(GameInstance.GetSimTime(game));
        let live = StTarget.AimObject(game);
        if IsDefined(live) && !this.IsFollowing(live as NPCPuppet) {
            return live;
        }
        if IsDefined(this.markHostile) && !this.markHostile.IsDead()
            && now - this.markHostileAt < 45.0 {
            return this.markHostile;
        }
        if IsDefined(this.markNpc) && !this.markNpc.IsDead()
            && now - this.markAt < 45.0 {
            return this.markNpc;
        }
        return null;
    }

    public func TargetIsFairGame(game: GameInstance) -> Bool {
        let target = this.AimedAt(game);
        if !IsDefined(target) {
            StLog("intent: nobody in your crosshair and nobody looked at recently");
            return false;
        }
        let fair: Bool = StActions.IsFairGame(target);
        StLog(s"intent: \(StActions.ReadableObj(target)) is \(fair ? "fair game" : "not hostile")");
        return fair;
    }

    private func Attack(npc: ref<NPCPuppet>) -> Void {
        let settings = StreetTalkSettings.Get();
        if !IsDefined(settings) || !settings.npcCombat {
            StLog("action: ATTACK ignored - Violence is off in Mod Settings");
            return;
        }
        let game = npc.GetGame();
        let target = this.AimedAt(game);
        if !IsDefined(target) || target == npc {
            StLog("action: ATTACK - nobody in your crosshair to attack");
            return;
        }
        let mine = npc.GetAttitudeAgent();
        let theirs = target.GetAttitudeAgent();
        if !IsDefined(mine) || !IsDefined(theirs) {
            return;
        }
        // Arming happens automatically - being told to shoot someone while
        // empty-handed should not be a conversation about logistics.
        this.Arm(npc);
        // A FIGHT HAS TWO SIDES. One-way hostility plus a threat entry is what
        // the game's own squad helper does (aiActionHelper.swift:306) - but it
        // runs on every member of a squad, so both sides end up hostile to
        // each other. Doing only our half left her holding a grudge nobody
        // answered: she played the animation, said "Got him", and stood there
        // (field report, three weapons tried).
        // THE GROUP LEVEL IS THE ONE THAT COUNTS. SetAttitudeTowards on the
        // agent is not what GetAttitudeTowards answers with, and the combat
        // behaviour cancels its own shoot command the moment it reads the
        // target as friendly (aiActionHelper.swift:274). That is why she drew
        // a sniper, aimed, and never pulled the trigger (field report). The
        // game's own inject-threat command sets the GROUP attitude
        // (aiInjectCombatThreatCommand.swift:91), so this does the same.
        // WHAT SHE WAS BEFORE. Group-level hostility is what actually makes
        // her fight - and a group is a group, which is why she carried on and
        // shot people across the street (field report). Keeping the old value
        // is what makes standing down possible at all.
        this.beforeAttitude = mine.GetAttitudeTowards(theirs);
        this.hadAttitude = true;
        mine.SetAttitudeTowards(theirs, EAIAttitude.AIA_Hostile);
        theirs.SetAttitudeTowards(mine, EAIAttitude.AIA_Hostile);
        mine.SetAttitudeTowardsAgentGroup(theirs, mine, EAIAttitude.AIA_Hostile);
        theirs.SetAttitudeTowardsAgentGroup(mine, theirs, EAIAttitude.AIA_Hostile);

        // A THREAT THAT DOES NOT FADE. Without persistence the entry decays
        // out of the tracker and she drifts back to standing around; the same
        // command sets it whenever the order has no duration.
        let src = TweakDBInterface.GetAIThreatPersistenceSourceRecord(
            t"AIThreatPersistenceSource.CommandInjectThreat");
        let tracker = npc.GetTargetTrackerComponent();
        if IsDefined(tracker) {
            tracker.AddThreat(target, true, target.GetWorldPosition(), 1.0, -1.0, true);
            if IsDefined(src) {
                tracker.SetThreatPersistence(target, true, Cast<Uint32>(src.EnumValue()));
            }
        }
        let theirTracker = target.GetTargetTrackerComponent();
        if IsDefined(theirTracker) {
            theirTracker.AddThreat(npc, true, npc.GetWorldPosition(), 1.0, -1.0, true);
            if IsDefined(src) {
                theirTracker.SetThreatPersistence(npc, true, Cast<Uint32>(src.EnumValue()));
            }
        }
        // AGGRESSIVE OR IT NEVER HAPPENS. The game's own "start a fight with
        // this person" refuses outright unless the puppet is an aggressive
        // type (aiActionHelper.swift:208) - and a friendly companion is not
        // one. That is why Panam drew her Overwatch, took aim at the man, and
        // simply held it: hostile attitude, threat listed, weapon out, and an
        // AI with no business fighting anyone (field report).
        // AGGRESSION, VIA THE ONE DOOR THE GAME ACTUALLY OPENS. IsAggressive()
        // is script (scriptedPuppet.swift:1578) and answers true for four
        // things; the reaction system's own register is the one that can be
        // set from outside without side effects. The stat modifier I tried
        // before is not read by that function at all - the probe proved it
        // (aggStat=1.0 alongside aggressive=false).
        let rs = GameInstance.GetReactionSystem(game);
        let registered: Bool = IsDefined(rs)
            && rs.TryRegisteringAggressiveNPC(npc, false);
        StLog(s"attack: registered as aggressive = \(registered)");

        let mask = new SetAggressiveMask();
        mask.isAggressive = true;
        npc.QueueEvent(mask);

        // AGGRESSION IS A STAT. The event above never took - two seconds
        // later the log still read aggressive=false - because the AI does not
        // ask a flag, it asks the stats system
        // (tweakAIConditionChecks.swift:1772). So set the stat.
        let stats = GameInstance.GetStatsSystem(game);
        if IsDefined(stats) {
            stats.AddModifier(Cast<StatsObjectID>(npc.GetEntityID()),
                RPGManager.CreateStatModifier(gamedataStatType.IsAggressive,
                                              gameStatModifierType.Additive, 1.0));
        }

        // AND THE FRIENDLY-FIRE BLOCK COMES OFF. The same condition is the
        // game's "do not shoot near friends" rule, and it is what a companion
        // is subject to every time V asks them to shoot somebody standing in
        // the street. The game ships an off switch for it by name - that is
        // the whole purpose of the effect - so it is not a guess:
        // BaseStatusEffect.DoNotBlockShootingOnFriendlyFire.
        StatusEffectHelper.ApplyStatusEffect(npc,
            t"BaseStatusEffect.DoNotBlockShootingOnFriendlyFire", npc.GetEntityID());

        // Then ask the game to start the fight, rather than assembling one by
        // hand: this is the same call the reaction system makes when someone
        // trespasses (reactionComponent.swift:970).
        let started: Bool = AIActionHelper.TryStartCombatWithTarget(npc, target);
        // ...and name the target for the combat behaviour itself. Threats are
        // a list of who is dangerous; THIS is who to shoot.
        let aicc = npc.GetAIControllerComponent();
        if IsDefined(aicc) {
            aicc.SetBehaviorArgument(n"CombatTarget", ToVariant(target));
            aicc.SetBehaviorArgument(n"CommandCombatTarget", ToVariant(target));
        }

        // AND LET HER PERCEIVE IT. Attitude and threats are bookkeeping; what
        // actually drags an NPC into somebody else's fight is a stimulus -
        // the squad helper pulls squadmates in with exactly this
        // (aiSquadHelper.swift:132), and the target tracker uses it to make a
        // fight mutual (targetTrackingComponent.swift:696). Sent FROM the
        // target so it reads as "that man is fighting", and again as a hit so
        // it reads as "that man is fighting ME".
        let bc = target.GetStimBroadcasterComponent();
        if IsDefined(bc) {
            bc.SendDrirectStimuliToTarget(target, gamedataStimType.Combat, npc);
            bc.SendDrirectStimuliToTarget(target, gamedataStimType.CombatHit, npc);
        }

        // AND SOMEONE HAS TO START IT. A threat on the list is not combat:
        // until the puppet's high-level state changes, it keeps running the
        // behaviour it was already in - which for a companion is standing
        // next to V (NPCPuppet.swift:1105; the state change is what puts them
        // in combat stance, npcStateComponent.swift:376).
        NPCPuppet.ChangeHighLevelState(npc, gamedataNPCHighLevelState.Combat);
        NPCPuppet.ChangeHighLevelState(target, gamedataNPCHighLevelState.Combat);
        // EVERY LEASH OFF. A fighter has to be free to move, and this mod
        // had three separate things holding her still: the hold-position
        // command, the companion role (which tethers her to you), and the
        // look-at that keeps her eyes on YOU rather than the person she is
        // fighting. With a melee weapon those matter most - the game's combat
        // AI closes the distance itself, but only if nothing is anchoring her.
        this.StopTalking(npc);
        if IsDefined(this.holdCmd) {
            this.StopCmd(npc, this.holdCmd);
            this.holdCmd = null;
        }
        this.SetCompanion(npc, false);
        if IsDefined(this.chatLookAt) {
            LookAtRemoveEvent.QueueRemoveLookatEvent(npc, this.chatLookAt);
            this.chatLookAt = null;
        }
        this.chatTookOver = false;
        let ts2 = GameInstance.GetTransactionSystem(game);
        let armed: Bool = IsDefined(ts2)
            && (IsDefined(ts2.GetItemInSlot(npc, t"AttachmentSlots.WeaponRight"))
                || IsDefined(ts2.GetItemInSlot(npc, t"AttachmentSlots.WeaponLeft")));
        // The attitude the BEHAVIOUR will read, which is the one that decides
        // whether the shot happens. armed is checked on a delay because
        // drawing a weapon is a command, not an instant.
        StLog(s"action: ATTACK on \(StActions.ReadableObj(target))"
            + s" | reads as hostile=\(Equals(mine.GetAttitudeTowards(theirs), EAIAttitude.AIA_Hostile))"
            + s" | combat started=\(started) | was aggressive=\(npc.IsAggressive())"
            + s" | civilian=\(IsDefined(target as ScriptedPuppet) && (target as ScriptedPuppet).IsCivilian())");
        let check = new StArmedCheck();
        check.actions = this;
        check.npc = npc;
        GameInstance.GetDelaySystem(game).DelayCallback(check, 2.0, false);

        // WATCH WHAT SHE ACTUALLY DOES. Five readings over twelve seconds,
        // straight out of the AI's own state - see StreetTalkDiag.reds. This
        // replaces me explaining what I think is happening.
        this.attackNpc = npc;
        this.attackTarget = target;
        this.standDownTries = 0;
        let watch = new StStandDownTick();
        watch.actions = this;
        GameInstance.GetDelaySystem(game).DelayCallback(watch, 2.0, false);
        let times: array<Float> = [0.5, 2.0, 4.0, 8.0, 12.0];
        let pi: Int32 = 0;
        while pi < ArraySize(times) {
            let probe = new StProbeTick();
            probe.npc = npc;
            probe.target = target;
            probe.at = times[pi];
            GameInstance.GetDelaySystem(game).DelayCallback(probe, times[pi], false);
            pi += 1;
        }
        StActions.Announce(s"turns on \(target.GetDisplayName())");
    }

    // THE FIGHT ENDS WHEN THE TARGET DOES. Nothing in the game switches a
    // companion back off - being asked to shoot one man left Panam hostile to
    // his whole attitude group, so she went looking for more of them across
    // the street. Checked every two seconds; ends on the target's death, or
    // after a minute if the fight simply goes nowhere.
    public func StandDownTick() -> Void {
        let npc = this.attackNpc;
        if !IsDefined(npc) {
            return;
        }
        this.standDownTries += 1;
        let target = this.attackTarget;
        let over: Bool = !IsDefined(target) || target.IsDead() || npc.IsDead();
        // BUT NOT WHILE PEOPLE ARE SHOOTING AT HER. If the man had friends,
        // the job is not over when he goes down - and clearing her threats
        // mid-firefight would leave her standing in the open with her hands
        // empty. Wait until nobody is fighting her any more.
        let tracker = npc.GetTargetTrackerComponent();
        if over && IsDefined(tracker) && tracker.HasHostileThreat(false)
            && this.standDownTries < 90 {
            let stillOn = new StStandDownTick();
            stillOn.actions = this;
            GameInstance.GetDelaySystem(npc.GetGame()).DelayCallback(stillOn, 2.0, false);
            return;
        }
        if !over && this.standDownTries < 30 {
            let again = new StStandDownTick();
            again.actions = this;
            GameInstance.GetDelaySystem(npc.GetGame()).DelayCallback(again, 2.0, false);
            return;
        }
        this.StandDown(npc, over ? "target is down" : "nothing came of it");
    }

    public func StandDown(npc: ref<NPCPuppet>, why: String) -> Void {
        if !IsDefined(npc) {
            return;
        }
        let game = npc.GetGame();
        // Put the attitude back exactly as it was, both ways.
        let target = this.attackTarget;
        if this.hadAttitude && IsDefined(target) {
            let mine = npc.GetAttitudeAgent();
            let theirs = target.GetAttitudeAgent();
            if IsDefined(mine) && IsDefined(theirs) {
                mine.SetAttitudeTowardsAgentGroup(theirs, mine, this.beforeAttitude);
                mine.SetAttitudeTowards(theirs, this.beforeAttitude);
            }
        }
        this.hadAttitude = false;
        // Out of the aggressive register, which is what made her willing.
        let rs = GameInstance.GetReactionSystem(game);
        if IsDefined(rs) {
            rs.TryUnregisteringAggressiveNPC(npc.GetEntityID());
        }
        let calm = new SetAggressiveMask();
        calm.isAggressive = false;
        npc.QueueEvent(calm);
        StatusEffectHelper.RemoveStatusEffect(npc,
            t"BaseStatusEffect.DoNotBlockShootingOnFriendlyFire");
        let stats = GameInstance.GetStatsSystem(game);
        if IsDefined(stats) {
            stats.RemoveAllModifiers(Cast<StatsObjectID>(npc.GetEntityID()),
                                     gamedataStatType.IsAggressive, true);
        }
        // No threats left to chase, and nobody to chase them as.
        let tracker = npc.GetTargetTrackerComponent();
        if IsDefined(tracker) {
            tracker.ClearThreats();
        }
        let aic = npc.GetAIControllerComponent();
        if IsDefined(aic) {
            aic.SetBehaviorArgument(n"CombatTarget", ToVariant(null));
            aic.SetBehaviorArgument(n"CommandCombatTarget", ToVariant(null));
        }
        NPCPuppet.ChangeHighLevelState(npc, gamedataNPCHighLevelState.Relaxed);
        // ONLY someone who was already walking with V. The attack takes the
        // companion role off to free them up to fight, and this puts it back -
        // for people who had it. Being asked to shoot somebody is not a
        // request to follow you around, and the two have nothing to do with
        // each other: this list only ever contains people who were told to
        // follow.
        if this.IsFollowing(npc) {
            this.SetCompanion(npc, true);
        }
        this.attackNpc = null;
        this.attackTarget = null;
        StLog(s"attack: \(StActions.Readable(npc)) stands down - \(why)");
        StActions.Announce("lowers their weapon");
    }

    // PUT IT AWAY. Not the same as dropping it: the weapon goes back on their
    // back or hip and stays theirs. Both hands, because a blade in the left is
    // still a blade.
    private func Holster(npc: ref<NPCPuppet>) -> Void {
        let right = new AIUnequipCommand();
        right.slotId = t"AttachmentSlots.WeaponRight";
        AIComponent.SendCommand(npc, right);
        let left = new AIUnequipCommand();
        left.slotId = t"AttachmentSlots.WeaponLeft";
        AIComponent.SendCommand(npc, left);
        StLog("action: HOLSTER");
        StActions.Announce("puts it away");
    }

    // TAKE IT OFF THEM. The player's own escape hatch for someone who will not
    // put a weapon down when asked - it ends up in V's inventory, because a gun
    // that vanishes is a bug and a gun on the floor gets picked back up.
    public func Disarm(npc: ref<NPCPuppet>) -> Bool {
        if !IsDefined(npc) || npc.IsDead() {
            return false;
        }
        let game = npc.GetGame();
        let ts = GameInstance.GetTransactionSystem(game);
        let player = GetPlayer(game);
        if !IsDefined(ts) || !IsDefined(player) {
            return false;
        }
        let took: Bool = false;
        let slots: array<TweakDBID> = [t"AttachmentSlots.WeaponRight",
                                       t"AttachmentSlots.WeaponLeft"];
        let i: Int32 = 0;
        while i < ArraySize(slots) {
            let item = ts.GetItemInSlot(npc, slots[i]);
            if IsDefined(item) {
                let name: String = StActions.HeldItemName(npc);
                if ts.TransferItem(npc, player, item.GetItemID(), 1) {
                    took = true;
                    StLog(s"action: DISARM - took \(name)");
                    StActions.Announce(s"loses \(name) to V");
                }
            }
            i += 1;
        }
        if !took {
            StLog("action: DISARM - their hands were already empty");
        }
        return took;
    }

    private func DropHeld(npc: ref<NPCPuppet>) -> Void {
        ScriptedPuppet.DropItemFromSlot(npc, t"AttachmentSlots.WeaponRight");
        ScriptedPuppet.DropItemFromSlot(npc, t"AttachmentSlots.WeaponLeft");
        StLog("action: DROP");
        StActions.Announce("puts it down");
    }

    // The panic button behind the /reset chat command: stop anything this
    // mod ever commanded on the NPC AND teleport them back to where they
    // stood before [FOLLOW] - their ambient AI (workspot, patrol route)
    // belongs to that spot, so putting them back is what makes them "act
    // normally" again instead of standing lost wherever the walk ended.
    // Teleport(obj, Vector4, EulerAngles): vehicles.swift:1407.
    public func EmergencyReset(npc: ref<NPCPuppet>) -> Void {
        // Undo the fight, not just the conversation. Whatever was done to
        // make someone willing to shoot has to come off again, or /reset
        // hands back a person who is permanently spoiling for one.
        if IsDefined(npc) {
            let stats = GameInstance.GetStatsSystem(npc.GetGame());
            if IsDefined(stats) {
                stats.RemoveAllModifiers(Cast<StatsObjectID>(npc.GetEntityID()),
                                         gamedataStatType.IsAggressive, true);
            }
            StatusEffectHelper.RemoveStatusEffect(npc,
                t"BaseStatusEffect.DoNotBlockShootingOnFriendlyFire");
            let calm = new SetAggressiveMask();
            calm.isAggressive = false;
            npc.QueueEvent(calm);
        }
        this.StopTalking(npc);
        this.StopFollowing(npc);
        this.FaceRest(npc);
        if !IsDefined(npc) {
            return;
        }
        let ws = GameInstance.GetWorkspotSystem(npc.GetGame());
        if IsDefined(ws) && ws.IsActorInWorkspot(npc) {
            ws.StopInDevice(npc);   // out of any pose we put them in
        }
        // Where they were before [FOLLOW] wins if they were led away; failing
        // that, where this conversation found them. Either way /reset means
        // "undo everything this mod did to this person", including position.
        if this.hasPreFollow {
            GameInstance.GetTeleportationFacility(npc.GetGame())
                .Teleport(npc, this.preFollowPos, this.preFollowRot);
            this.hasPreFollow = false;
        } else {
            this.SendHome(npc);
        }
        StLog("action: emergency reset");
    }

    // The game's OWN companion role, which is how the Flathead follows you
    // (subCharacterSystem.swift:75). A role does what a raw move command
    // cannot: they keep up properly, and they get in the car with you.
    // Cleared with AINoRole, the same way the game clears roles.

    private func SetCompanion(npc: ref<NPCPuppet>, on: Bool) -> Void {
        if on {
            let player = GetPlayer(npc.GetGame());
            if !IsDefined(player) {
                return;
            }
            let role = new AIFollowerRole();
            role.SetFollowTarget(player);
            AIHumanComponent.SetCurrentRole(npc, role);
            // THE SECOND HALF, without which none of it counts. The game's own
            // test for "is this a companion" (aiComponent.swift:493) wants the
            // Follower role AND a FriendlyTarget behaviour argument pointing at
            // the player - the role's own OnRoleSet does exactly this
            // (aiRole.swift:197). Set only the role and they trail after you
            // without ever being a companion: no squad status, and they will
            // not get in your car (field report).
            let aic = npc.GetAIControllerComponent();
            if IsDefined(aic) {
                aic.SetBehaviorArgument(n"FriendlyTarget", ToVariant(player));
            }
            let fr = this.FindFollower(npc);
            if IsDefined(fr) {
                fr.hasRole = true;
            }
            StLog("follow: companion role + friendly target set");
        } else {
            let fc = this.FindFollower(npc);
            // Only undo a role THIS mod gave them. Clearing it wholesale would
            // strip the authored role off anyone who already had one.
            if IsDefined(fc) && fc.hasRole {
                AIHumanComponent.SetCurrentRole(npc, new AINoRole());
                let aic2 = npc.GetAIControllerComponent();
                if IsDefined(aic2) {
                    aic2.SetBehaviorArgument(n"FriendlyTarget", ToVariant(null));
                }
                fc.hasRole = false;
                StLog("follow: companion role cleared");
            }
        }
    }

    private func Follow(npc: ref<NPCPuppet>) -> Void {
        let player = GetPlayer(npc.GetGame());
        if !IsDefined(player) {
            return;
        }
        // FOLLOWING BEATS EVERYTHING THE CHAT DID TO THEM. Two things this mod
        // itself set up make walking physically impossible, and both were
        // silently winning (field report: "does the animating thing override
        // the following? its not working"):
        //   - the hold-position command that stops NPCs wandering mid-chat
        //   - the gesture, which IS a workspot, and a workspot owns the body
        // So a follow request tears both down first. Gestures then stay off
        // for the duration of the follow (see StartTalking) - a companion
        // walking beside you must not be yanked back into a talking pose.
        this.StopTalking(npc);
        let ws = GameInstance.GetWorkspotSystem(npc.GetGame());
        if IsDefined(ws) && ws.IsActorInWorkspot(npc) {
            ws.StopInDevice(npc);
        }
        if IsDefined(this.holdCmd) {
            this.StopCmd(npc, this.holdCmd);
            this.holdCmd = null;
        }
        // First follow of this conversation: remember home. Not overwritten
        // by a second [FOLLOW] mid-walk - home is where they lived, not
        // wherever they happened to pause.
        if !this.hasPreFollow {
            this.preFollowPos = npc.GetWorldPosition();
            this.preFollowRot = Quaternion.ToEulerAngles(npc.GetWorldOrientation());
            this.hasPreFollow = true;
        }
        let cmd = new AIFollowTargetCommand();
        cmd.target = player;
        cmd.desiredDistance = 2.0;
        cmd.tolerance = 1.5;
        cmd.stopWhenDestinationReached = false;
        cmd.movementType = moveMovementType.Walk;
        // AS MANY AS ASK. Companions are a crowd, not a slot - and each of
        // them keeps their own command so any one of them can be stopped
        // without touching the others.
        let f = this.FindFollower(npc);
        if !IsDefined(f) {
            f = new StFollower();
            f.npc = npc;
            ArrayPush(this.followers, f);
        }
        f.cmd = cmd;
        AIComponent.SendCommand(npc, cmd);
        // Role first, command second: the role handles keeping up and riding
        // along, the command is the fallback if a role does not take.
        this.SetCompanion(npc, true);
        this.SaveFollowers();
        StLog("action: FOLLOW");
        StActions.Announce("starts following you");
    }

    private func StopFollowing(npc: ref<NPCPuppet>) -> Void {
        let f = this.FindFollower(npc);
        if !IsDefined(f) {
            return;
        }
        this.SetCompanion(npc, false);
        if f.riding {
            this.Dismount(f);
        }
        if IsDefined(f.cmd) {
            this.StopCmd(npc, f.cmd);
        }
        ArrayRemove(this.followers, f);
        this.SaveFollowers();
        StLog("action: STOP");
        StActions.Announce("stops following");
    }

    // (There WAS a [GREET] action here that played the NPC's recorded
    // "greeting" bark. Removed: the NPC is already speaking a synthesised
    // line, so a second, canned voice on top read as a bug rather than a
    // wave - owner call, and correct.)
}

// One companion. Everything here is true of this person and nobody else,
// which is exactly what the old single-slot version could not express.
public class StFollower extends IScriptable {
    public let npc: wref<NPCPuppet>;
    public let retries: Int32;
    public let cmd: ref<AIFollowTargetCommand>;
    public let hasRole: Bool;
    public let riding: Bool;
    public let seat: CName;
    public let carId: EntityID;
}

// Who was walking with V when the game was last saved.
public class StFollowFileDTO extends IScriptable {
    public let ids: array<String>;
    public let records: array<String>;
    public let names: array<String>;
}

// Did the weapon actually come out? Asked two seconds later, because the
// draw is an AI command and reading the hand slot immediately always said no.
// Re-tries a turn once the NPC is actually free of their workspot.
public class StTurnRetry extends DelayCallback {
    public let actions: wref<StActions>;
    public let npc: wref<NPCPuppet>;
    public let why: String;
    public func Call() -> Void {
        if IsDefined(this.actions) && IsDefined(this.npc) {
            this.actions.TurnToPlayer(this.npc, this.why);
        }
    }
}

// One step of a turn. Six of these make a person pivot instead of snapping.
public class StTurnStep extends DelayCallback {
    public let actions: wref<StActions>;
    public let npc: wref<NPCPuppet>;
    public let yaw: Float;
    public func Call() -> Void {
        if IsDefined(this.actions) && IsDefined(this.npc) {
            this.actions.TurnTo(this.npc, this.yaw);
        }
    }
}

// Watches for the fight being over so the companion can stop being one.
public class StStandDownTick extends DelayCallback {
    public let actions: wref<StActions>;
    public func Call() -> Void {
        if IsDefined(this.actions) {
            this.actions.StandDownTick();
        }
    }
}

public class StArmedCheck extends DelayCallback {
    public let actions: wref<StActions>;
    public let npc: wref<NPCPuppet>;
    public func Call() -> Void {
        if IsDefined(this.actions) && IsDefined(this.npc) {
            this.actions.ReportArmed(this.npc);
        }
    }
}

public class StTalkAnimTick extends DelayCallback {
    public let actions: wref<StActions>;
    public func Call() -> Void {
        if IsDefined(this.actions) {
            this.actions.TalkAnimTick();
        }
    }
}

// Measures where the NPC actually ended up facing once the gesture is
// playing, so the engine's yaw convention is learned instead of guessed.
public class StTalkYawTick extends DelayCallback {
    public let actions: wref<StActions>;
    public func Call() -> Void {
        if IsDefined(this.actions) {
            this.actions.VerifyTalkYaw();
        }
    }
}
