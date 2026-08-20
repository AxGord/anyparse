package anyparse.grammar.haxe;

/**
 * A metadata-prefixed statement whose whole body is a SELF-TERMINATING
 * `#if … ; #end` region: `@SuppressWarnings('…') #if (haxe_ver > 4.2)
 * l_usedLibs = Tools.usedLibsDirs(); #else l_usedLibs = new Map(); #end`
 * (`Pony/pony/Logable.hx:229`).
 *
 * WHY THE METADATA IS PART OF THE SHAPE. A bare region in statement
 * position is already served: the structured `HxStatement.Conditional`
 * reads it as a conditional whose branches are statements. The metadata is
 * what breaks that — `@meta` dispatches through
 * `HxStatement.ExprStmt(MetaExpr(…))`, and `HxMetaExpr.expr` is an
 * EXPRESSION, so the region there can only be an expression-position
 * splice. The last such ctor is `HxExpr.CondSpliceExpr`, whose MANDATORY
 * `tail` then parsed the NEXT STATEMENT as part of the region: measured on
 * `Logable.hx`, `l_origTrace = Log.trace;` projected as
 * `MetaExpr(@SuppressWarnings, CondSpliceExpr(Assign l_origTrace …))`.
 * Silent, because the writer re-emits the raw fragment plus the absorbed
 * tail verbatim and the file round-trips byte-exactly.
 *
 * The metadata is also what keeps this ctor NARROW. A general
 * expression-position ctor for the same raw shape was built and measured
 * before this one, and it claimed a construct that only parses today
 * because nothing in the statement Star matches it: a switch's guarded
 * `case` region, where `HxConditionalCase` relies on the case-body
 * statement Star FAILING (`Pony/pony/Tools.hx:128` re-indented one level).
 * Requiring the metadata Ref first means a bare region is never a
 * candidate, so that construct is out of reach by construction rather than
 * by ordering luck.
 *
 * Dispatched BEFORE `ExprStmt`, which is the ctor that would otherwise win
 * with the swallow. It carries NO trail slot: a `;` written after the
 * `#end` becomes its own `EmptyStmt` and round-trips, whereas
 * `@:trailOpt(';')` made the writer invent one (measured on the `return`
 * twin).
 */
@:peg
typedef HxMetaCondStmt = {
	var meta: HxMetadata;
	var region: HxCondSpliceClosedRegion;
};
