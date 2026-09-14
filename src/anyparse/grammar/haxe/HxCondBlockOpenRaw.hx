package anyparse.grammar.haxe;

/**
 * Raw byte capture of a BLOCK-OPENING conditional-compilation region: everything after the
 * dispatching `#if` keyword up to AND INCLUDING the closing `#end`, constrained so that the
 * fragment (a) contains a `#else` / `#elseif` clause and (b) ends on an OPENING `{`
 * immediately before `#end`. Together the two constraints select exactly the shape where the
 * region holds PARALLEL branches, each opening a block whose body and closing `}` live AFTER
 * `#end`, shared by every compilation variant:
 *
 * ```haxe
 * #if (haxe_ver >= 4.10)
 * if (Std.isOfType(o, IWH)) {
 * #else
 * if (Std.is(o, IWH)) {
 * #end
 * } else load(o);
 * ```
 *
 * WHY A DEDICATED TERMINAL rather than reusing `HxCondSpliceRaw`. The owning ctor
 * `HxStatement.CondSpliceBlockOpen` has to be dispatched BEFORE `HxStatement.CondSpliceStmt`,
 * because `CondSpliceStmt`'s `{raw, tail}` shape MATCHES these regions too (the first shared
 * statement binds as `tail`) and leaves the block the region opened without a closer — the
 * parse dies far downstream with no backtracking left. An unconstrained raw terminal that
 * early would in turn steal every dangling-else region `CondSpliceStmt` owns; the
 * trailing-`{` constraint makes the two disjoint by construction, since no dangling-else
 * fragment and no structurally representable region ends on an unclosed brace.
 *
 * WHY THE `#else` REQUIREMENT. An OPENER region with no alternative branch, whose matching
 * closer lives in a SECOND region further down (`#if display try { #end … #if display }
 * catch (_:Dynamic) { } #end`), ends on `{` just the same; there the `}` that closes the
 * `try` is INSIDE the second region, so consuming a `}` after the shared statements steals
 * the enclosing function's closer. A parallel-branch region carries a `#else` / `#elseif`
 * and an opener/closer PAIR does not, so demanding one keeps this ctor off the pair shape
 * (`HxCondBlockTailRaw` owns its closing half); `#elseif` satisfies the test as a prefix.
 *
 * The `#end` is swallowed INTO the raw match so the owning struct can parse the shared
 * statement list immediately after this terminal with no mid-struct keyword field — the
 * `HxCondSpliceRaw` convention. NESTING is deliberately NOT supported: the scan stops at the
 * FIRST `#end`, so a region containing a complete inner `#if ... #end` fails the
 * trailing-`{` check and falls through. `@:rawString` — byte-exact round-trip, no unescape.
 */
@:re('(?:(?!#end)[\\s\\S])*#else(?:(?!#end)[\\s\\S])*\\{\\s*#end')
@:rawString
@:condRegionRaw
abstract HxCondBlockOpenRaw(String) from String to String {}
