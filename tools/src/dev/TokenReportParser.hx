package dev;

/**
 * Marker class for the macro-generated parser of `AuditReport`, the `--json`
 * file of `dev token-audit`; `parse` throws on malformed or wrong-shaped input.
 */
@:build(anyparse.macro.Build.buildParser(dev.AuditReport))
@:nullSafety(Strict)
class TokenReportParser {}
