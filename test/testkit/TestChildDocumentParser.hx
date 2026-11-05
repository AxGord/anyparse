package testkit;

/** Marker class for the macro-generated parser of `TestChildDocument`; `parse` throws on malformed or wrong-shaped input. */
@:build(anyparse.macro.Build.buildParser(testkit.TestChildDocument))
@:nullSafety(Strict)
class TestChildDocumentParser {}
