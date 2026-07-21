package anyparse.grammar.haxe;

/**
 * Raw byte capture of a BLOCK-OPENING conditional-compilation region:
 * everything after the dispatching `#if` keyword up to AND INCLUDING the
 * closing `#end`, constrained so that the fragment (a) contains a
 * `#else` / `#elseif` clause and (b) ends on an OPENING `{` immediately
 * before `#end`.
 *
 * Those two constraints are the whole point of the type. Together they
 * select exactly the shape where the region holds PARALLEL branches, each
 * opening a block whose body and closing `}` live AFTER `#end`, shared by
 * every compilation variant:
 *
 * ```haxe
 * #if (haxe_ver >= 4.10)
 * if (Std.isOfType(o, IWH)) {
 * #else
 * if (Std.is(o, IWH)) {
 * #end
 *     tasks.add();
 *     cast(o, IWH).wait(tasks.end);
 * } else load(o);
 * ```
 *
 * (`pony/ui/gui/BaseLayoutCore.hx:63`; the same shape twice in
 * `pony/heaps/ui/gui/Node.hx`, and in `pony/flash/HaxeInit.hx:65`,
 * `std/sys/Http.hx:471`, `std/haxe/Serializer.hx:180` and
 * `std/flash/Boot.hx:332` - the last two with a multi-statement first
 * branch, and Boot's opener being an anonymous-function literal rather
 * than an `if` head.)
 *
 * WHY A DEDICATED TERMINAL rather than reusing `HxCondSpliceRaw`. The
 * owning ctor `HxStatement.CondSpliceBlockOpen` has to be dispatched
 * BEFORE `HxStatement.CondSpliceStmt`, because `CondSpliceStmt`'s
 * `{raw, tail}` shape MATCHES these regions too (the first shared
 * statement binds as `tail`) and then leaves the block that the region
 * opened without a closer - the parse dies far downstream with no
 * backtracking left. Placing an unconstrained raw terminal that early
 * would in turn steal every dangling-else region `CondSpliceStmt` owns.
 * The trailing-`{` constraint makes the two disjoint by construction: a
 * region a structural production can represent never ends on an unclosed
 * brace, and no dangling-else fragment does either.
 *
 * WHY THE `#else` REQUIREMENT. The trailing-`{` test alone is not enough.
 * An OPENER region with no alternative branch, whose matching closer lives
 * in a SECOND region further down, ends on `{` just the same:
 *
 * ```haxe
 * #if display
 * try {
 * #end
 * ...
 * #if display
 * } catch (_:Dynamic) {
 * }
 * #end
 * return fields;
 * ```
 *
 * (`pony/magic/builder/ChainBuilder.hx:26`.) There the `}` that closes the
 * `try` is INSIDE the second region, so consuming a `}` after the shared
 * statements steals the enclosing function's closer - measured as a live
 * regression: the file parses as two `CondSpliceStmt`s and did so before
 * this terminal existed. Every observed parallel-branch region carries a
 * `#else` / `#elseif`; every observed opener/closer PAIR does not, so
 * demanding one keeps this ctor off the pair shape. `#elseif` satisfies the
 * test because `#else` is its literal prefix.
 *
 * The `#end` is swallowed INTO the raw match (rather than living on a
 * `@:trail`) so the owning struct can parse the shared statement list
 * immediately after this terminal with no mid-struct keyword field -
 * the `HxCondSpliceRaw` convention.
 *
 * NESTING is deliberately NOT supported: the scan stops at the FIRST
 * `#end`, so a region containing a complete inner `#if ... #end` fails
 * the trailing-`{` check and falls through to the other conditional
 * ctors. `HxCondSpliceRaw`'s nesting-aware alternation exists because
 * three live sources need it; no observed block-opening region nests,
 * and the simpler regex cannot scan past a shared `#end` into an
 * unrelated one (the hazard flagged for the nesting-aware form).
 *
 * `@:rawString` - byte-exact round-trip through `_dt(value)`, no
 * unescape pass; the writer re-emits the fragment verbatim.
 */
@:re('(?:(?!#end)[\\s\\S])*#else(?:(?!#end)[\\s\\S])*\\{\\s*#end')
@:rawString
abstract HxCondBlockOpenRaw(String) from String to String {}
