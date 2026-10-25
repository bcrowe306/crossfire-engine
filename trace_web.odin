#+build js
package crossfire

import "base:runtime"

// The browser build has no Spall trace (trace.odin): these do nothing

Trace_Start :: proc(path := "") -> bool { return false }
Trace_Stop :: proc() {}
Trace_Share :: proc(begin: TraceBeginProc, end: TraceEndProc) {}
Trace_Running :: proc "contextless" () -> bool { return false }
Trace_ThreadEnd :: proc "contextless" () {}
Trace_NameThread :: proc "contextless" (name: string) {}
Trace_Begin :: proc "contextless" (name: string, args := "") {}
Trace_End :: proc "contextless" () {}
Trace_AutoEnter :: proc "contextless" (loc: runtime.Source_Code_Location) {}
Trace_AutoExit :: proc "contextless" () {}
