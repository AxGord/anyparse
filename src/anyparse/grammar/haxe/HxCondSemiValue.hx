package anyparse.grammar.haxe;

/**
 * The `= #if … #end` value of `HxCondSemiAssign`. A one-branch enum rather than a struct field because the spaces
 * around the `=` (`spaceBeforeLead` / `spaceAfterLead`) are read off an enum BRANCH only — `HxVarSemiInitRegion`'s
 * reason; the `#if` rides the region's `cond`, since a branch carrying both a lead and a keyword emits the keyword first.
 */
@:peg
enum HxCondSemiValue {

	@:lead('=') @:trail('#end') @:fmt(spaceBeforeLead, spaceAfterLead)
	CondSemiRegion(inner: HxCondSemiRegion);

}
