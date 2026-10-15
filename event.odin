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
	index := -1
	for listener, i in subject.listeners {
		if listener.id == handle {
			index = i
			break
		}
	}
	if index != -1 {
		unordered_remove(&subject.listeners, index)
	}
	else {
		log.warn("Listener handle not found for unsubscribe")
	}
}

Event_Notify :: proc(subject: ^EventSubject, source: rawptr, data: EventData) {
	for listener in subject.listeners {
		listener.callback(subject, source, data, listener.userData)
	}
}

Event_Destroy :: proc(subject: ^EventSubject) {
	delete(subject.listeners)
}
