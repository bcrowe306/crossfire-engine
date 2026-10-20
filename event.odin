package engine

import "core:log"
import "core:crypto"
import "core:encoding/uuid"

EventData :: union {
	int,
	u32,
	u64,
	f32,
	f64,
	bool,
	rawptr
}

EntityId :: uuid.Identifier

ListenerHandle :: EntityId

EventListener :: struct {
	id: ListenerHandle,
	callback : proc(event: ^EventSubject, source: rawptr, data: EventData, userData: rawptr),
	userData : rawptr,
}

EventSubject :: struct {
	listeners : [dynamic]EventListener,
	// Notifications running (nested ones count): while one runs, unsubscribing only marks the
	// listener, and the list is compacted when the last one ends
	notifying: int,
	// A listener was marked for removal while notifying
	compact: bool,
	subscribe: proc(subject: ^EventSubject, callback: proc(event: ^EventSubject, source: rawptr, data: EventData, userData: rawptr), userData: rawptr) -> ListenerHandle ,
	unsubscribe: proc(subject: ^EventSubject, handle: ListenerHandle),
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

Event_Subscribe :: proc(subject: ^EventSubject, callback: proc(event: ^EventSubject, source: rawptr, data: EventData, userData: rawptr), userData: rawptr) -> ListenerHandle {
	context.random_generator = crypto.random_generator()
	handle := uuid.generate_v4()
	listener := EventListener{
		id = handle,
		callback = callback,
		userData = userData,
	}
	append(&subject.listeners, listener)
	return handle
}

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
notification; ones unsubscribed then aren't called again, this time included.
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

Event_Destroy :: proc(subject: ^EventSubject) {
	delete(subject.listeners)
}
