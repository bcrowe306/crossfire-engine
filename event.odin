package crossfire

import "core:log"
import "core:encoding/uuid"
import "core:math/rand"

// The value an event carries to its listeners (`Event_Notify`). nil when there's none. A string
// is only valid during the notification: clone it to keep it
EventData :: union {
	int,
	u32,
	u64,
	f32,
	f64,
	bool,
	rawptr,
	string,
}

// A unique id (a version 4 UUID) for a node or an event listener. Made by `NewEntityId`
EntityId :: uuid.Identifier

/*
A new random id (a version 4 UUID) from Odin's fast per-thread generator. Ids needn't be
secret, and the OS's cryptographic source (what `uuid.generate_v4` insists on) cost a system call
per node and per listener.

Returns:
- The new id
*/
NewEntityId :: proc() -> EntityId {
	id := transmute(EntityId)rand.uint128()
	id[6] = (id[6] & 0x0f) | 0x40 // version 4
	id[8] = (id[8] & 0x3f) | 0x80 // RFC 4122 variant
	return id
}

// Identifies a subscription, returned by `Event_Subscribe`; pass it to `Event_Unsubscribe`
ListenerHandle :: EntityId

// One subscription to an `EventSubject`
EventListener :: struct {
	// The handle `Event_Subscribe` returned
	id: ListenerHandle,
	// Called on each notification with the subject, the notifier's source and data, and
	// `userData`. nil while a removal waits for the notification to end
	callback : proc(event: ^EventSubject, source: rawptr, data: EventData, userData: rawptr),
	// Passed back to `callback` as it was given to `Event_Subscribe`
	userData : rawptr,
}

/*
An event that listeners subscribe to (the observer pattern). Scenes and nodes use them for
hooks such as `onEnter` and `onExit`.

Set it up with `EventSubject_Init`; the procedures are called with `->`:
`subject->subscribe(callback, userData)`, `subject->notify(source, data)`,
`subject->unsubscribe(handle)`. Free it with `Event_Destroy`.
*/
EventSubject :: struct {
	// The subscriptions, in the order they subscribed
	listeners : [dynamic]EventListener,
	// Notifications running (nested ones count): while one runs, unsubscribing only marks the
	// listener, and the list is compacted when the last one ends
	notifying: int,
	// A listener was marked for removal while notifying
	compact: bool,
	// `Event_Subscribe`, set by `EventSubject_Init`
	subscribe: proc(subject: ^EventSubject, callback: proc(event: ^EventSubject, source: rawptr, data: EventData, userData: rawptr), userData: rawptr) -> ListenerHandle ,
	// `Event_Unsubscribe`, set by `EventSubject_Init`
	unsubscribe: proc(subject: ^EventSubject, handle: ListenerHandle),
	// `Event_Notify`, set by `EventSubject_Init`
	notify: proc(subject: ^EventSubject, source: rawptr, data: EventData),
}

/*
Prepares an event subject for use.

Inputs:
- subject: The subject to initialize
- allocator: Allocator for the listener list. Use the owner's allocator (e.g. `Node_GetAllocator(node)`)
  so the list is freed along with the owner
*/
EventSubject_Init :: proc(subject: ^EventSubject, allocator := context.allocator) {
	subject.listeners = make([dynamic]EventListener, allocator)
	subject.subscribe = Event_Subscribe
	subject.unsubscribe = Event_Unsubscribe
	subject.notify = Event_Notify
}

/*
Adds a listener to a subject. Call it as `subject->subscribe(callback, userData)`.

A listener added while a notification runs is first called by the next notification.

Inputs:
- subject: The subject to listen to
- callback: Called on each notification with the subject, the source and data passed to
  `Event_Notify`, and `userData`
- userData: Any pointer, passed back to `callback` (nil when not needed)

Returns:
- The handle to unsubscribe with (`Event_Unsubscribe`)

Example:
	// Given: subject: ^e.EventSubject
	handle := subject->subscribe(proc(event: ^e.EventSubject, source: rawptr, data: e.EventData, userData: rawptr) {
		if score, ok := data.(int); ok do log.infof("score: %d", score)
	}, nil)
	subject->notify(nil, 42)
	subject->unsubscribe(handle)
*/
Event_Subscribe :: proc(subject: ^EventSubject, callback: proc(event: ^EventSubject, source: rawptr, data: EventData, userData: rawptr), userData: rawptr) -> ListenerHandle {
	handle := NewEntityId()
	listener := EventListener{
		id = handle,
		callback = callback,
		userData = userData,
	}
	append(&subject.listeners, listener)
	return handle
}

/*
Removes a listener from a subject. Call it as `subject->unsubscribe(handle)`.

Safe during a notification: the listener isn't called again, and the list is compacted when
the notification ends. The other listeners keep their order. Logs a warning if the handle isn't
subscribed.

Inputs:
- subject: The subject
- handle: The handle `Event_Subscribe` returned
*/
Event_Unsubscribe :: proc(subject: ^EventSubject, handle: ListenerHandle) {
	for &listener, i in subject.listeners {
		if listener.id != handle || listener.callback == nil do continue
		if subject.notifying > 0 {
			// The notification walking the list must not see it shift: mark it, compact later
			listener.callback = nil
			subject.compact = true
		} else {
			// Ordered: the others keep being called in the order they subscribed
			ordered_remove(&subject.listeners, i)
		}
		return
	}
	log.warn("Listener handle not found for unsubscribe")
}

/*
Calls every listener, in the order they subscribed. A listener may subscribe or unsubscribe
(itself or others) while being called: ones that subscribe then are first called by the next
notification; ones unsubscribed then aren't called again, this time included. Call it as
`subject->notify(source, data)`.

Inputs:
- subject: The subject
- source: Who sent it (a node, a scene...), passed to each listener; may be nil
- data: A value passed to each listener; nil for none
*/
Event_Notify :: proc(subject: ^EventSubject, source: rawptr, data: EventData) {
	subject.notifying += 1
	count := len(subject.listeners)
	// By index, re-reading the list each time: a subscribe can move it
	for i := 0; i < count && i < len(subject.listeners); i += 1 {
		listener := subject.listeners[i]
		if listener.callback != nil do listener.callback(subject, source, data, listener.userData)
	}
	subject.notifying -= 1
	if subject.notifying == 0 && subject.compact {
		subject.compact = false
		kept := 0
		for listener in subject.listeners {
			if listener.callback == nil do continue
			subject.listeners[kept] = listener
			kept += 1
		}
		resize(&subject.listeners, kept)
	}
}

/*
Frees the subject's listener list. Not needed when the list was made with an arena allocator
that's freed anyway (a node's or scene's).

Inputs:
- subject: The subject
*/
Event_Destroy :: proc(subject: ^EventSubject) {
	delete(subject.listeners)
}
