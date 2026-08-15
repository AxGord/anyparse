package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.ControlFlow.ControlFlowSupport;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.Refs;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

/**
 * Flags a redundant intermediate local: an IMMUTABLE single-variable declaration whose
 * initializer is a TRIVIAL PURE READ and whose one and only reference sits in the
 * immediately following sibling statement, so the read can be substituted at the use and the
 * declaration line dropped:
 *
 * ```haxe
 * final logoBmd:Null<BitmapData> = _userLogoBmd;
 * logoBmd?.dispose();
 * // ->
 * _userLogoBmd?.dispose();
 * ```
 *
 * `Info` -- the code is correct, this is a readability simplification. A member of the
 * `join-` family beside `join-return` (which joins a declaration and its next RETURN) and
 * `join-declaration-assignment` (which joins a bare declaration and its next ASSIGNMENT).
 *
 * Such a capture is usually residue of the strict-null-safety idiom: a FIELD does not narrow,
 * so `if (x != null) x.dispose()` needed a local to hold the narrowed value. Once
 * `prefer-safe-nav` rewrites the guard to `?.` the capture buys nothing, and a later `--fix`
 * pass of this check removes it.
 *
 * ## What is flagged
 *
 * Two CONSECUTIVE statements of one statement list (`ControlFlowSupport.blockKinds`) where
 * every gate below holds. Each gate is a structurally-provable shape invariant, so the fix is
 * not `RiskyFix`; every gate fails CLOSED (an unset seam, an unresolved type or an unexpected
 * node shape refuses the site).
 *
 * - THE DECLARATION is a single-variable IMMUTABLE local (`localDeclKinds` minus
 *   `mutableLocalDeclKinds` minus `localDeclContinuationKinds`) with an initializer -- exactly
 *   one child -- and no multi-declarator continuation. A `var` is out of scope: it can be
 *   written between the capture and the read, so the captured value and the re-read value
 *   differ. The declaration must also OWN its physical line
 *   (`RefactorSupport.lineExtendedSpan` must widen its span), since the fix deletes that line
 *   whole; a declaration sharing a line with another statement, or trailed by a comment, is
 *   refused here.
 * - THE INITIALIZER is a trivial pure read: a bare identifier (a local, a param, `this`, or a
 *   bare field read) or a dotted field-read chain over one (`fieldAccessKind`, incl.
 *   `this.f`). A strict WHITELIST -- calls, `new`, index access, literals, casts, operators
 *   and lambdas all refuse. Safe navigation (`nullSafeAccessKind`) refuses too, and not merely
 *   out of caution: substituting `a?.b` into `x.c` turns an NPE into a silent short-circuit. A
 *   bare read of a MUTABLE local refuses too: under strict null safety Haxe narrows an
 *   immutable binding but not a `var` a closure captures, so `final b = best; b?.span` compiles
 *   where the inlined `best?.span` does not -- the `final`-ness is doing the work.
 * - THE LOCAL HAS EXACTLY ONE REFERENCE and it is a Read (`CheckScan.soleReferenceNameFrom`
 *   plus `CheckScan.escapesConditionalRegion`, shared with `join-return`). This is what
 *   protects the narrowing shape the rule grew out of: in
 *   `final x = field; if (x != null) x.m();` the local is read TWICE, so the site is refused
 *   until `prefer-safe-nav` has collapsed it to one read.
 * - THE NAME OCCURS NOWHERE ELSE past the declaration, in the whole enclosing function, other
 *   than at that one read. `Refs` indexes ordinary identifier references and nothing else, so a
 *   braceless `$name` string interpolation and a macro reification `$name` (`DollarIdentExpr`)
 *   both read a local invisibly and leave the sole-reference count at one where there are two --
 *   the fix would then unbind the survivor. Enumerating those channels would be a negative list
 *   that leaks by category, so the gate is inverted: any node carrying the name is a use unless
 *   it is provably not one (the read itself, or a kind whose `name` is a MEMBER -- a field / safe
 *   / force field access, an object-literal key). The scan is scoped to the enclosing FUNCTION,
 *   not to the statement list: under the branch-aware projection that list may be a synthetic
 *   `CondBranch`, which is NOT a Haxe scope -- a local declared inside `#if A ... #end` is still
 *   visible past `#end`.
 * - NO IDENTIFIER THE INITIALIZER READS IS RE-BOUND between the declaration and the read. The
 *   initializer text is copied verbatim but its free identifiers re-resolve where they land, so
 *   an intervening binder captures the copy: `final x = n; try p catch (n:Dynamic) use(x);` would
 *   become `use(n)` reading the exception -- output that COMPILES and is silently wrong.
 * - THE READ SITS IN THE IMMEDIATELY FOLLOWING SIBLING statement. Adjacency is load-bearing:
 *   an intervening statement could mutate the source between the capture and the read.
 * - THE READ IS EVALUATED AT MOST ONCE, EAGERLY. No node on the path from the next statement
 *   down to the read may be a nested function or a loop: a LAMBDA or nested function defers
 *   the read past the eager capture (a timing change), and a LOOP evaluates it once per
 *   iteration while the body may mutate the source in between, so the single captured value
 *   and the re-read value diverge. CONDITIONAL evaluation -- an `if` branch, a `&&` / `||`
 *   right operand, a ternary branch, a `case` body -- is ACCEPTED for a BARE-IDENTIFIER
 *   initializer, whose read has no effect at all, and REFUSED (`RefShape.branchKinds`) for a
 *   field chain, where moving the read under a condition stops an eager null-dereference from
 *   throwing and stops a property getter's side effect from running -- the same hazard the
 *   initializer whitelist already refuses `a?.b` for, reached by another route.
 * - NOTHING IMPURE IS EVALUATED BEFORE THE READ. Every subtree that precedes the read in
 *   left-to-right evaluation order (each earlier sibling of each node on that path) must be
 *   `RefactorSupport.isSideEffectFree` or itself a trivial pure read. So `_obj.m(x)` and
 *   `log(x, reset())` pass -- the callee chain is a pure read, and a call AFTER the read
 *   cannot change the value it produces -- while `log(reset(), x)` refuses. The trivial-read
 *   arm is unioned in deliberately: it is the SAME purity notion the rule already trusts for
 *   the initializer, so a property getter in a preceding field-read chain carries exactly the
 *   residual risk the rule already accepts for the capture, and nothing new. An ancestor's OWN
 *   effect never matters -- a call calls after its arguments, an assignment stores after its
 *   r-value -- so only preceding SIBLING subtrees can run before the read.
 * - THE TYPE ANNOTATION IS NOT DOING CONVERSION WORK. An unannotated declaration always
 *   passes. An annotated one passes only when the annotation RE-STATES the initializer's own
 *   resolved declared type (`TypeResolver.identDeclaredTypeSource`, whitespace-insensitive),
 *   which makes the substitution provably type-neutral. Otherwise the annotation may be
 *   carrying real work the substitution would drop: an abstract `@:from` implicit conversion
 *   (`final c:types.Color = str;`) or an upcast that changes the static type at the use site
 *   (`final b:Base = _derived;`). A field-access initializer has no ident binding to resolve,
 *   so an annotated one is always refused -- fail-closed.
 * - NO COMMENT INTERSECTS THE DELETED REGION (the declaration's line). A comment BETWEEN the
 *   two statements, or anywhere inside the next statement, rides along untouched.
 * - THE NEXT STATEMENT IS NOT `return <name>;` -- that exact pair is `join-return`'s, and it
 *   emits the better text (it owns the annotation-ascription decision). A `return` of an
 *   EXPRESSION over the local is not that shape and stays this check's.
 *
 * ## Autofix
 *
 * `fix` emits two disjoint raw edits per finding: the declaration's line is deleted, and the
 * read's identifier token is replaced by the initializer's verbatim source. NO
 * PARENTHESISATION is needed or added -- by the initializer gate the substituted text is
 * always a bare identifier or a field-access chain, both maximal-precedence primaries.
 *
 * Needs `localDeclKinds`, `mutableLocalDeclKinds` and `controlFlowSupport` (any unset makes the
 * check a no-op). An EMPTY `mutableLocalDeclKinds` would admit mutable locals, so it is refused
 * rather than read as "no kind is provably immutable" -- the check goes inert instead of guessing.
 */
@:nullSafety(Strict)
final class JoinSingleUseLocal implements Check {

	/** A single-variable declaration with an initializer projects as exactly one child: the initializer. */
	private static inline final INIT_CHILD_COUNT: Int = 1;

	/** A trivial field-access link wraps exactly one child: its receiver. */
	private static inline final FIELD_ACCESS_CHILD_COUNT: Int = 1;

	/** A valued `return` node has exactly one child: the returned expression. */
	private static inline final RETURN_VALUE_CHILD_COUNT: Int = 1;

	public function new() {}

	public function id(): String {
		return 'join-single-use-local';
	}

	public function description(): String {
		return 'a single-use local capturing a trivial read, inlinable into the next statement';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final s: Seams = seams;
		return [
			for (entry in files) for (m in collect(entry.source, plugin, s)) ({
				file: entry.file,
				span: m.declSpan,
				rule: 'join-single-use-local',
				severity: Severity.Info,
				message: 'this local only captures a trivial read and can be inlined into the next statement'
			}: Violation)
		];
	}

	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = readSeams(plugin);
		if (seams == null) return [];
		final byKey: Map<String, Match> = [];
		for (m in collect(source, plugin, seams)) byKey['${m.declSpan.from}:${m.declSpan.to}'] = m;

		final selected: Array<Match> = [];
		for (v in violations) {
			final vspan: Null<Span> = v.span;
			if (vspan == null) continue;
			final m: Null<Match> = byKey['${vspan.from}:${vspan.to}'];
			if (m != null) selected.push(m);
		}

		final edits: Array<{ span: Span, text: String }> = [];
		for (m in selected) if (!readSwallowed(m, selected)) {
			edits.push({ span: m.dropSpan, text: '' });
			edits.push({ span: m.readSpan, text: m.initSource });
		}
		return RefactorSupport.dropContainedEdits(edits);
	}

	/**
	 * Whether another selected match DELETES the very statement holding `m`'s read. Chained
	 * captures (`final a = x; final b = a; b.m();`) each qualify on their own, but applying both
	 * in ONE pass drops the line carrying `a`'s substitution and leaves `b`'s surviving statement
	 * bound to a name that no longer exists -- output that does not compile. The swallowed match
	 * yields its whole edit PAIR (dropping only the contained substitution would delete the
	 * declaration and keep the dangling read); the `--fix` driver's next pass picks it up again
	 * over the already-shortened source, so the chain still collapses, one link per pass.
	 */
	private static function readSwallowed(m: Match, selected: Array<Match>): Bool {
		for (other in selected) if (
			other.declSpan.from != m.declSpan.from && m.readSpan.from >= other.dropSpan.from && m.readSpan.to <= other.dropSpan.to
		)
			return true;
		return false;
	}

	/** Parse `source` and collect every inlinable pair in it, or nothing when it does not parse. */
	private static function collect(source: String, plugin: GrammarPlugin, s: Seams): Array<Match> {
		final tree: Null<QueryNode> = CheckScan.parseBranchAwareOrNull(plugin, source);
		if (tree == null) return [];
		final root: QueryNode = tree;
		final comments: Array<{ from: Int, to: Int, isLine: Bool }> = RefactorSupport.collectCommentTokens(source);
		final declTypeSources: () -> Map<Int, String> = TypeResolver.memoizedDeclaredTypeSources(plugin, source);
		final out: Array<Match> = [];
		collectMatches(root, source, comments, s, root, declTypeSources, out);
		return out;
	}

	/**
	 * Bundle the kinds the check reads, or null when a required one is unset (the check is then
	 * a no-op). An EMPTY `mutableLocalDeclKinds` is refused rather than treated as "no local is
	 * mutable": the immutability gate is what keeps a written-between local out, so a grammar
	 * that cannot name its mutable declarations must make the check inert, not permissive.
	 */
	private static function readSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final localDeclKinds: Null<Array<String>> = shape.localDeclKinds;
		final mutableKinds: Null<Array<String>> = shape.mutableLocalDeclKinds;
		if (localDeclKinds == null || localDeclKinds.length == 0) return null;
		if (mutableKinds == null || mutableKinds.length == 0) return null;
		final support: Null<ControlFlowSupport> = plugin.controlFlowSupport();
		if (support == null) return null;
		final barriers: Array<String> = barrierKinds(shape);
		return {
			localDeclKinds: localDeclKinds,
			mutableKinds: mutableKinds,
			continuationKinds: shape.localDeclContinuationKinds ?? [],
			identKind: shape.identKind,
			fieldAccessKind: shape.fieldAccessKind,
			returnKind: shape.returnStatementKind,
			blockKinds: support.blockKinds(),
			barrierKinds: barriers,
			branchKinds: shape.branchKinds ?? [],
			memberNamingKinds: memberNamingKinds(shape),
			fnKinds: (shape.functionKinds ?? []).concat(shape.lambdaKinds ?? []).concat(shape.localFunctionKinds ?? []),
			shape: shape
		};
	}

	/**
	 * The node kinds that make a read REPEATED or DEFERRED relative to the eager, once-only
	 * capture it would replace -- nested functions and loops. Built from the `RefShape` seams
	 * that name them, unioned with `NullFlow`'s curated Haxe lists for the same two categories:
	 * those cover the expression-position forms (`ForExpr` / `WhileExpr` in a comprehension,
	 * `NamedFnExpr`) that no `RefShape` seam names -- `loopStatementKinds` is documented as
	 * STATEMENT loops only. `opaqueKinds` joins them because a reification subtree's uses are
	 * spliced rather than written, so no textual scan can price the substitution there.
	 */
	private static function memberNamingKinds(shape: RefShape): Array<String> {
		final out: Array<String> = [];
		for (k in [
			shape.fieldAccessKind,
			shape.nullSafeAccessKind,
			shape.forceFieldAccessKind,
			shape.objectFieldKind
		]) if (k != null && !out.contains(k)) out.push(k);
		return out;
	}

	private static function barrierKinds(shape: RefShape): Array<String> {
		final out: Array<String> = [];
		inline function add(kinds: Null<Array<String>>): Void {
			if (kinds != null) for (k in kinds) if (!out.contains(k)) out.push(k);
		}
		add(shape.functionKinds);
		add(shape.lambdaKinds);
		add(shape.localFunctionKinds);
		add(shape.inlineFunctionKinds);
		add(shape.fnExprKind == null ? null : [shape.fnExprKind]);
		add(shape.loopStatementKinds);
		add(shape.doWhileLoopKinds);
		add(shape.forStmtKind == null ? null : [shape.forStmtKind]);
		add(shape.whileStmtKind == null ? null : [shape.whileStmtKind]);
		add(shape.opaqueKinds);
		add(NullFlow.NESTED_FN_KINDS);
		add(NullFlow.LOOP_KINDS);
		return out;
	}

	/** Collect every inlinable (declaration, next-statement) pair reachable under `node`. */
	private static function collectMatches(
		node: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>, s: Seams, tree: QueryNode,
		declTypeSources: () -> Map<Int, String>, out: Array<Match>
	): Void {
		if (s.blockKinds.contains(node.kind)) {
			final kids: Array<QueryNode> = node.children;
			for (i in 0...kids.length - 1) {
				final m: Null<Match> = matchPair(kids[i], kids[i + 1], node, source, comments, s, tree, declTypeSources);
				if (m != null) out.push(m);
			}
		}
		for (c in node.children) collectMatches(c, source, comments, s, tree, declTypeSources, out);
	}

	/**
	 * The inline match for a `decl` immediately followed by `next`, or null when any gate
	 * declines (see the class doc for every one of them, in this order).
	 */
	private static function matchPair(
		decl: QueryNode, next: QueryNode, block: QueryNode, source: String, comments: Array<{ from: Int, to: Int, isLine: Bool }>,
		s: Seams, tree: QueryNode, declTypeSources: () -> Map<Int, String>
	): Null<Match> {
		final name: Null<String> = decl.name;
		final declSpan: Null<Span> = decl.span;
		if (name == null || declSpan == null) return null;
		final drop: Null<Span> = deletableDeclLine(decl, declSpan, source, s);
		if (drop == null) return null;
		final dropSpan: Span = drop;

		final init: QueryNode = decl.children[0];
		final initSpan: Null<Span> = init.span;
		if (initSpan == null || !isTrivialPureRead(init, s) || readsMutableLocal(init, tree, s)) return null;

		if (isJoinReturnShape(next, name, s)) return null;

		final declNameFrom: Null<Int> = CheckScan.soleReferenceNameFrom(name, declSpan, tree, s.shape);
		if (declNameFrom == null) return null;
		if (CheckScan.escapesConditionalRegion(name, declSpan, tree, s.shape)) return null;
		final read: Null<RefHit> = soleReadHit(name, declSpan, tree, s.shape);
		if (read == null) return null;
		final readHit: RefHit = read;
		// ADJACENCY: `pathTo` is the gate -- it yields null unless the read sits inside the
		// IMMEDIATELY following sibling, so a read further down the list never matches.
		if (!readPositionIsSafe(next, readHit.span, init, s)) return null;

		if (!annotationIsNeutral(declTypeSources()[declNameFrom], init, s, tree, declTypeSources)) return null;
		if (commentInDroppedRegion(comments, dropSpan)) return null;

		final tokenFrom: Int = RefactorSupport.identTokenOffset(source, readHit.span, name);
		if (tokenFrom < 0) return null;
		if (unindexedNameUse(name, declSpan, tokenFrom, tree, s)) return null;
		if (initIdentRebound(init, declSpan, tokenFrom, tree, s)) return null;
		// Re-bind to a non-null local: narrowing does not reach the struct literal below.
		final keySpan: Span = declSpan;
		return {
			declSpan: keySpan,
			dropSpan: dropSpan,
			readSpan: new Span(tokenFrom, tokenFrom + name.length),
			initSource: source.substring(initSpan.from, initSpan.to)
		};
	}

	/**
	 * The line-wide region the fix would delete for `decl`, or null when the declaration is not
	 * a deletable single-variable IMMUTABLE binding with an initializer. Splits the shape half
	 * of the gate chain off `matchPair`: kind and mutability, no multi-declarator continuation,
	 * a single initializer child, a span ending in the statement terminator, and -- the reason
	 * this returns a span rather than a Bool -- OWNERSHIP of the physical line, which
	 * `RefactorSupport.lineExtendedSpan` reports by widening the span it is given. A shared line,
	 * or one whose declaration is trailed by a comment, leaves the span unchanged and refuses.
	 */
	private static function deletableDeclLine(decl: QueryNode, declSpan: Span, source: String, s: Seams): Null<Span> {
		if (!s.localDeclKinds.contains(decl.kind) || s.mutableKinds.contains(decl.kind)) return null;
		if (s.continuationKinds.contains(decl.kind) || decl.children.length != INIT_CHILD_COUNT) return null;
		if (RefactorSupport.isMultiDeclarator(decl, s.continuationKinds)) return null;
		// The decl span includes its trailing `;`; a bare single-var decl ends in one.
		if (declSpan.to <= declSpan.from || source.charAt(declSpan.to - 1) != ';') return null;
		final dropSpan: Span = RefactorSupport.lineExtendedSpan(source, declSpan);
		return dropSpan.from == declSpan.from && dropSpan.to == declSpan.to ? null : dropSpan;
	}

	/**
	 * Whether `node` is a bare identifier or a dotted chain of field reads over one -- the only
	 * initializer shapes whose substitution is provably free of extra work or extra
	 * null-semantics. A strict whitelist: everything else, safe navigation included, refuses.
	 */
	private static function isTrivialPureRead(node: QueryNode, s: Seams): Bool {
		if (node.kind == s.identKind) return node.children.length == 0;
		final fieldKind: Null<String> = s.fieldAccessKind;
		if (fieldKind == null || node.kind != fieldKind || node.children.length != FIELD_ACCESS_CHILD_COUNT) return false;
		return isTrivialPureRead(node.children[0], s);
	}

	/**
	 * Whether the initializer is a bare read of a MUTABLE local (`mutableLocalDeclKinds`). Such a
	 * capture is not noise even when the value is unchanged: under strict null safety Haxe
	 * narrows an immutable binding but NOT a `var` a closure captures, so `final b = best;
	 * b?.span` compiles where the inlined `best?.span` does not -- the `final`-ness itself is
	 * doing the work an annotation would do elsewhere. Found by running the rule over its own
	 * source (`enclosingFunctionSubtree`), where the inline produced code that does not compile.
	 *
	 * Only the bare-identifier form is asked: a field-read chain never resolves to a local
	 * declaration, so it cannot be this shape.
	 */
	private static function readsMutableLocal(init: QueryNode, tree: QueryNode, s: Seams): Bool {
		if (init.kind != s.identKind) return false;
		final name: Null<String> = init.name;
		final span: Null<Span> = init.span;
		if (name == null || span == null) return false;
		final bindingFrom: Null<Int> = TypeResolver.resolveBindingFrom(name, span, tree, s.shape);
		return bindingFrom != null && TypeResolver.mayBeLocalOrParam(tree, bindingFrom, s.mutableKinds, []);
	}

	/** Whether `next` is exactly `return <name>;` -- the pair `join-return` claims. */
	private static function isJoinReturnShape(next: QueryNode, name: String, s: Seams): Bool {
		final returnKind: Null<String> = s.returnKind;
		if (returnKind == null || next.kind != returnKind || next.children.length != RETURN_VALUE_CHILD_COUNT) return false;
		final value: QueryNode = next.children[0];
		return value.kind == s.identKind && value.name == name;
	}

	/**
	 * The single non-declaration Read of `name` bound at `declSpan`, or null when that one
	 * reference is a write. `CheckScan.soleReferenceNameFrom` has already proven there is
	 * exactly one; an immutable local can never be written, but the kind is asserted rather
	 * than assumed.
	 */
	private static function soleReadHit(name: String, declSpan: Span, tree: QueryNode, shape: RefShape): Null<RefHit> {
		for (h in Refs.find(name, tree, shape)) {
			final bs: Null<Span> = h.bindingSpan;
			if (bs == null || bs.from < declSpan.from || bs.to > declSpan.to) continue;
			if (bs.from == h.span.from && bs.to == h.span.to) continue;
			return h.kind == RefKind.Read ? h : null;
		}
		return null;
	}

	/**
	 * Whether the declaration's own type `annotation` is provably doing NO conversion work, so
	 * dropping it with the declaration cannot retype the use site. True when there is no
	 * annotation at all, or when it RE-STATES the initializer's own resolved declared type
	 * (whitespace-insensitive).
	 *
	 * Otherwise the annotation may be carrying real work: an abstract `@:from` implicit
	 * conversion (`final c:types.Color = str;`), an upcast that changes the static type at the
	 * use (`final b:Base = _derived;`), a downcast off a `Dynamic` source
	 * (`final t:Stage = event.currentTarget;`), or -- the sharpest one -- a strict-null-safety
	 * NARROWING capture (`if (f == null) throw ...; final x:T = f;` over a field declared
	 * `Null<T>`), where the substitution would hand the use a value the compiler still types as
	 * nullable. A field-access initializer has no ident binding to resolve, so an annotated one
	 * is always refused -- fail-closed.
	 */
	private static function annotationIsNeutral(
		annotation: Null<String>, init: QueryNode, s: Seams, tree: QueryNode, declTypeSources: () -> Map<Int, String>
	): Bool {
		if (annotation == null) return true;
		final sourceType: Null<String> = TypeResolver.identDeclaredTypeSource(init, s.shape, tree, declTypeSources, true);
		return sourceType != null && TypeResolver.stripWs(annotation) == sourceType;
	}

	/**
	 * Whether `name` occurs ANYWHERE past the declaration, in its enclosing function, other than
	 * at the one read `Refs` resolved -- an occurrence the resolution index cannot see.
	 *
	 * `Refs` indexes ordinary identifier references and nothing else, so several source channels
	 * read a local invisibly and leave `CheckScan.soleReferenceNameFrom` counting one reference
	 * where there are two. Deleting the declaration then unbinds the survivor: a `--fix` that
	 * does not compile. Two are confirmed on real trees -- a braceless `$name` string
	 * interpolation (TM-Haxe4 `src/video/VideoExportController.hx:239` captures `batchH` for a
	 * call and re-reads it from the `trace` on the next line) and a macro reification `$name`
	 * (`DollarIdentExpr`, which `opaqueKinds` only guards when the macro is ON the path to the
	 * read).
	 *
	 * Enumerating those channels would be a negative list that leaks by category, so the gate is
	 * inverted: ANY node carrying the name is a use unless it is provably not one. The only
	 * exemptions are the read itself and the kinds whose `name` is a MEMBER rather than a
	 * binding (`memberNamingKinds` -- a field access, a safe / force field access, an
	 * object-literal key), where `o.name` says nothing about a local called `name`. Everything
	 * else -- including shapes nobody has found yet -- fails closed at the cost of recall.
	 *
	 * A BRACED `${name}` read needs no exemption reasoning either way: it IS indexed, so the
	 * sole-reference gate has already refused the site.
	 *
	 * The scan is scoped to the enclosing FUNCTION, not to the statement list holding the
	 * declaration: under the branch-aware projection that list may be a synthetic `CondBranch`,
	 * which is not a Haxe scope -- a local declared inside `#if A ... #end` is still visible after
	 * `#end`, and a `$name` read there would sit outside the scanned subtree.
	 */
	private static function unindexedNameUse(name: String, declSpan: Span, readFrom: Int, tree: QueryNode, s: Seams): Bool {
		final scope: QueryNode = enclosingFunctionSubtree(tree, declSpan, s);
		var found: Bool = false;
		function walk(n: QueryNode): Void {
			if (found) return;
			final span: Null<Span> = n.span;
			if (
				n.name == name && span != null && span.from >= declSpan.to && span.from != readFrom && !s.memberNamingKinds.contains(
					n.kind
				)
			) {
				found = true;
				return;
			}
			for (c in n.children) walk(c);
		}
		walk(scope);
		return found;
	}

	/**
	 * Whether an identifier the initializer READS is re-bound between the declaration and the
	 * read, so the substituted text would resolve somewhere else at its new position.
	 *
	 * The initializer is copied verbatim, but its free identifiers are re-resolved where they
	 * land. Any declaration of one of those names in between captures the copy:
	 * `final x = n; try p catch (n:Dynamic) use(x);` becomes `use(n)` reading the exception
	 * rather than the parameter -- output that COMPILES and is silently wrong. Most binder forms
	 * are already refused by other gates (a loop or lambda head is a barrier, an intervening
	 * declaration is an impure earlier sibling), but that is coverage by accident; this asks the
	 * question directly, for every binder `Refs` projects as a declaration.
	 *
	 * The window is compared on the declaration hit's START offset alone: a binder that ENCLOSES
	 * the read reports the whole construct's span (`Refs` gives a `catch (n:T) ...` clause the
	 * CatchClause span, which ends PAST the read), so an end-offset window would let exactly the
	 * shape this gate exists for slip through. A declaration after the read cannot capture it --
	 * Haxe binds a reference to the nearest PRECEDING declaration.
	 */
	private static function initIdentRebound(init: QueryNode, declSpan: Span, readFrom: Int, tree: QueryNode, s: Seams): Bool {
		for (nm in initIdentNames(init, s)) for (h in Refs.find(nm, tree, s.shape)) if (
			h.kind == RefKind.Decl && h.span.from >= declSpan.to && h.span.from < readFrom
		)
			return true;
		return false;
	}

	/** Every identifier name the initializer reads, deduplicated. */
	private static function initIdentNames(init: QueryNode, s: Seams): Array<String> {
		final out: Array<String> = [];
		function walk(n: QueryNode): Void {
			final nm: Null<String> = n.name;
			if (n.kind == s.identKind && nm != null && !out.contains(nm)) out.push(nm);
			for (c in n.children) walk(c);
		}
		walk(init);
		return out;
	}

	/**
	 * The innermost function / lambda / local-function subtree containing `inner`, or the whole
	 * `tree` when none does -- the widest region a local declared at `inner` can still be read
	 * from. Deliberately NOT the statement-list node the declaration sits in: under the
	 * branch-aware projection that node may be a synthetic `CondBranch`, which is not a Haxe
	 * scope (a local declared inside `#if A ... #end` stays visible past `#end`), so scanning it
	 * would miss exactly the reads the caller is looking for. Mirrors `Rename`'s own
	 * enclosing-function walk, and like it does no containment pruning: the parse root carries
	 * no span, so a prune at a null-span node would stop there and silently widen the scope.
	 */
	private static function enclosingFunctionSubtree(tree: QueryNode, inner: Span, s: Seams): QueryNode {
		var best: Null<QueryNode> = null;
		function walk(n: QueryNode): Void {
			final span: Null<Span> = n.span;
			if (s.fnKinds.contains(n.kind) && span != null && span.from <= inner.from && inner.to <= span.to) {
				// Re-bind before the field read: null safety does not narrow a closure-captured `var`.
				final b: Null<QueryNode> = best;
				final bSpan: Null<Span> = b?.span;
				if (bSpan == null || span.to - span.from < bSpan.to - bSpan.from) best = n;
			}
			for (c in n.children) walk(c);
		}
		walk(tree);
		return best ?? tree;
	}

	/**
	 * Whether the read at `readSpan` sits in a position the substitution may take over, judged on
	 * its path down from the next statement `next`. Three conditions, all fail-closed:
	 *
	 * - the read IS inside `next` at all (`pathTo` yields null otherwise) -- this is the adjacency
	 *   gate: a read further down the statement list never resolves to a path here;
	 * - it is evaluated at most once and eagerly (`evaluatedOnceEagerly`);
	 * - nothing impure runs before it (`nothingImpureBefore`);
	 * - and, for a FIELD-CHAIN initializer only, the path is unconditional. A bare identifier may
	 *   land under a branch -- reading it has no effect at all, so never evaluating it is
	 *   unobservable -- but a field chain moved under a condition stops throwing an eager
	 *   null-dereference and stops running a property getter's side effect. That is the same
	 *   hazard the initializer whitelist already refuses `a?.b` for, reached by a different route.
	 */
	private static function readPositionIsSafe(next: QueryNode, readSpan: Span, init: QueryNode, s: Seams): Bool {
		final path: Null<Array<QueryNode>> = pathTo(next, readSpan);
		if (path == null) return false;
		final steps: Array<QueryNode> = path;
		return
			evaluatedOnceEagerly(steps, s) && nothingImpureBefore(steps, s) && (init.kind == s.identKind || !pathIsConditional(steps, s));
	}

	/** Whether any comment overlaps `dropSpan`, the declaration line the fix deletes whole. */
	private static function commentInDroppedRegion(comments: Array<{ from: Int, to: Int, isLine: Bool }>, dropSpan: Span): Bool {
		for (tok in comments) if (tok.to > dropSpan.from && tok.from < dropSpan.to) return true;
		return false;
	}

	/** Whether any node on `path` evaluates the read CONDITIONALLY (`RefShape.branchKinds`). */
	private static function pathIsConditional(path: Array<QueryNode>, s: Seams): Bool {
		for (n in path) if (s.branchKinds.contains(n.kind)) return true;
		return false;
	}

	/** The node chain from `root` down to the node whose span is exactly `target`, or null when there is none. */
	private static function pathTo(root: QueryNode, target: Span): Null<Array<QueryNode>> {
		final span: Null<Span> = root.span;
		if (span == null || span.from > target.from || span.to < target.to) return null;
		if (span.from == target.from && span.to == target.to) return [root];
		for (c in root.children) {
			final below: Null<Array<QueryNode>> = pathTo(c, target);
			if (below != null) return [root].concat(below);
		}
		return null;
	}

	/** Whether no node on `path` repeats the read (a loop) or defers it (a nested function). */
	private static function evaluatedOnceEagerly(path: Array<QueryNode>, s: Seams): Bool {
		for (n in path) if (s.barrierKinds.contains(n.kind)) return false;
		return true;
	}

	/**
	 * Whether every subtree evaluated BEFORE the read is pure. Those are exactly the earlier
	 * siblings of each step of `path`: a parent's own effect always follows its children's.
	 */
	private static function nothingImpureBefore(path: Array<QueryNode>, s: Seams): Bool {
		for (i in 0...path.length - 1) {
			final kids: Array<QueryNode> = path[i].children;
			for (c in kids) {
				if (c == path[i + 1]) break;
				if (!RefactorSupport.isSideEffectFree(c) && !isTrivialPureRead(c, s)) return false;
			}
		}
		return true;
	}

}

/** The kinds `JoinSingleUseLocal` reads. */
private typedef Seams = {
	var localDeclKinds: Array<String>;
	var mutableKinds: Array<String>;
	var continuationKinds: Array<String>;
	var identKind: String;
	var fieldAccessKind: Null<String>;
	var returnKind: Null<String>;
	var blockKinds: Array<String>;
	var barrierKinds: Array<String>;
	var branchKinds: Array<String>;
	var memberNamingKinds: Array<String>;
	var fnKinds: Array<String>;
	var shape: RefShape;
}

/**
 * An inlinable pair: the declaration span (finding key), the line-wide region the fix drops,
 * the identifier token the fix overwrites, and the initializer text it writes there.
 */
private typedef Match = {
	var declSpan: Span;
	var dropSpan: Span;
	var readSpan: Span;
	var initSource: String;
}
