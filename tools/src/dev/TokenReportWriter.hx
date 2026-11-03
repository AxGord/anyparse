package dev;

/** Macro-generated JSON writer of `AuditReport`, the `--json` file of `dev token-audit`; used through its generated static `write`. */
@:build(anyparse.macro.Build.buildWriter(dev.AuditReport, dev.TokenReportWriteOptions))
@:nullSafety(Strict)
class TokenReportWriter {

	private function new() {}

}
