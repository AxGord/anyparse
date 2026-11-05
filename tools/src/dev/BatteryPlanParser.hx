package dev;

/** Marker class for the macro-generated parser of `BatteryPlan`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.BatteryPlan))
@:nullSafety(Strict)
class BatteryPlanParser {}
