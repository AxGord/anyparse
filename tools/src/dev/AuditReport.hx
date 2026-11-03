package dev;

/** The whole reading; a before/after pair of its JSON diffs by key. */
@:peg
@:schema(anyparse.grammar.json.JsonFormat)
@:ws
typedef AuditReport = {
	var agents: Int;
	var turns: Int;
	var toolInTok: Int;
	var toolOutTok: Int;
	var cost: Float;
	var tools: Array<ToolRow>;
	var roles: Array<RoleToolRow>;
	var models: Array<ModelRow>;
	var slices: Array<SliceCost>;
	@:optional var landed: Null<LandedSummary>;
	var rewrites: RewriteSummary;
	var bypass: BypassSummary;
	var assumptions: Array<String>;
}
