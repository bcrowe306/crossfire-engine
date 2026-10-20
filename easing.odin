package crossfire

import "core:math"

/*
Easing curves for animating a value over a fixed duration.

"In" curves start slow, "Out" curves end slow, "InOut" do both. Back curves overshoot
slightly past the ends, Elastic springs past the end and settles, Bounce bounces at the end.
See https://easings.net for a visual reference of each curve. Used by `Ease`, tweens and
camera pans.
*/
EaseType :: enum {
	Linear,
	InQuad,
	OutQuad,
	InOutQuad,
	InCubic,
	OutCubic,
	InOutCubic,
	InSine,
	OutSine,
	InOutSine,
	InExpo,
	OutExpo,
	InOutExpo,
	InBack,
	OutBack,
	InOutBack,
	OutElastic,
	OutBounce,
}

/*
Applies an easing curve to a progress value.

Inputs:
- type: The easing curve
- t: Progress from 0 (start) to 1 (end). Values outside 0..1 are clamped

Returns:
- Eased progress. 0 at t = 0 and 1 at t = 1; Back and Elastic curves briefly go outside 0..1

Example:
	// Given: elapsed: f32, duration: f32, from: [2]f32, to: [2]f32
	t := elapsed / duration
	pos := from + (to - from) * e.Ease(.InOutCubic, t)
*/
Ease :: proc(type: EaseType, t: f32) -> f32 {
	t := clamp(t, 0, 1)
	BACK :: 1.70158
	BACK_INOUT :: BACK * 1.525

	switch type {
	case .Linear:     return t
	case .InQuad:     return t * t
	case .OutQuad:    return 1 - (1 - t) * (1 - t)
	case .InOutQuad:  return t < 0.5 ? 2 * t * t : 1 - math.pow(-2 * t + 2, 2) / 2
	case .InCubic:    return t * t * t
	case .OutCubic:   return 1 - math.pow(1 - t, 3)
	case .InOutCubic: return t < 0.5 ? 4 * t * t * t : 1 - math.pow(-2 * t + 2, 3) / 2
	case .InSine:     return 1 - math.cos(t * math.PI / 2)
	case .OutSine:    return math.sin(t * math.PI / 2)
	case .InOutSine:  return -(math.cos(math.PI * t) - 1) / 2
	case .InExpo:     return t == 0 ? 0 : math.pow(2, 10 * t - 10)
	case .OutExpo:    return t == 1 ? 1 : 1 - math.pow(2, -10 * t)
	case .InOutExpo:
		if t == 0 || t == 1 do return t
		return t < 0.5 ? math.pow(2, 20 * t - 10) / 2 : (2 - math.pow(2, -20 * t + 10)) / 2
	case .InBack:     return (BACK + 1) * t * t * t - BACK * t * t
	case .OutBack:    return 1 + (BACK + 1) * math.pow(t - 1, 3) + BACK * math.pow(t - 1, 2)
	case .InOutBack:
		if t < 0.5 do return (math.pow(2 * t, 2) * ((BACK_INOUT + 1) * 2 * t - BACK_INOUT)) / 2
		return (math.pow(2 * t - 2, 2) * ((BACK_INOUT + 1) * (t * 2 - 2) + BACK_INOUT) + 2) / 2
	case .OutElastic:
		if t == 0 || t == 1 do return t
		return math.pow(2, -10 * t) * math.sin((t * 10 - 0.75) * (2 * math.PI / 3)) + 1
	case .OutBounce:
		return easeOutBounce(t)
	}
	return t
}

@(private="file")
easeOutBounce :: proc(t: f32) -> f32 {
	N :: 7.5625
	D :: 2.75
	switch {
	case t < 1 / D:   return N * t * t
	case t < 2 / D:   t := t - 1.5 / D;   return N * t * t + 0.75
	case t < 2.5 / D: t := t - 2.25 / D;  return N * t * t + 0.9375
	case:             t := t - 2.625 / D; return N * t * t + 0.984375
	}
}
