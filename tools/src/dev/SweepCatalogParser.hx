package dev;

/** Marker class for the macro-generated parser of `SweepCatalog`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(dev.SweepCatalog))
@:nullSafety(Strict)
class SweepCatalogParser {}
