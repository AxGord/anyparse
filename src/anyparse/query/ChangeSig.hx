package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.Refs.RefHit;
import anyparse.query.Refs.RefKind;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import anyparse.runtime.Span.Position;
import haxe.Exception;

using Lambda;

/**
 * Outcome of a `ChangeSig.changeSig` call. `Ok` carries the
 * format-preserving rewritten source plus an optional advisory (a
 * non-fatal note printed to stderr — e.g. the cross-file caveat for a
 * method whose out-of-file callers cannot be seen); `Err` carries a
 * human-readable diagnostic (cursor not on a function, a non-permutation
 * argument, an unresolvable / receiver-qualified call site, an arity
 * mismatch, a post-rewrite re-parse failure). Modelled as a sum type so
 * the CLI maps it to stdout vs. stderr + a non-zero exit without a
 * sentinel-string convention. Mirrors `ExtractResult` / `InlineResult`.
 */
enum ChangeSigResult {
	Ok(text:String, advisory:Null<String>);
	Err(message:String);
}

/**
 * Scope-correct, format-preserving change-signature (parameter reorder)
 * — the fourth refactoring operation built on the query engine, the
 * sibling of `Rename` / `Inline` / `ExtractVar`.
 *
 * Given a cursor on a function declaration (or a resolvable bare call to
 * it), the reorder:
 *
 *  1. Parses the source and inverts the printed `apq refs` column to a
 *     raw offset, identically to `Rename` / `Inline` / `ExtractVar`.
 *  2. Resolves the function declaration at `line:col`. A cursor that
 *     lands directly on a `FnMember` (method) or `LocalFnStmt` (named
 *     local function) decl IS the declaration; a cursor on a bare
 *     `name(...)` call resolves back to the method decl through the
 *     shared `Refs` binding resolver.
 *  3. Reads the function's parameters — the leading `Required` /
 *     `Optional` children of the decl, in source order (the trailing
 *     `Named` return-type child and the body are excluded).
 *  4. Validates `<perm>` as a true permutation of `0..n-1` and rejects
 *     the identity (a no-op).
 *  5. Collects every in-file call site and PROVES the set is complete —
 *     change-signature's failure mode is SILENT (a missed call keeps the
 *     old argument order against the new parameters), so any call that
 *     cannot be proven to target this function is a hard refusal.
 *  6. Overwrites each parameter / argument slot's span with the source
 *     text of the item that moves there (a SLOT SWAP: only the slot
 *     contents move; the commas and whitespace between slots stay put,
 *     so the existing layout is preserved verbatim).
 *  7. Re-parses the result; an unparseable rewrite is rejected.
 *
 * Call-site collection differs by declaration kind because the `Refs`
 * resolver indexes methods but not local functions:
 *
 *  - `FnMember` (method): bare `name(...)` calls resolve through `Refs`
 *    to the decl binding; `this.name(...)` calls are matched
 *    structurally (a `FieldAccess` named `name` whose receiver is
 *    `this`), exactly like `Rename`'s `this.<name>` handling. Any
 *    `obj.name(...)` (non-`this` receiver) or unresolved bare call is a
 *    refusal. A method may have callers in OTHER files we cannot see, so
 *    a successful reorder carries a cross-file advisory.
 *  - `LocalFnStmt` (local function): `Refs` does not index local
 *    functions, so a bare call's binding comes back unresolved and
 *    cannot be told apart from an unrelated unresolved call. The reorder
 *    instead requires the function name to be UNIQUE among the file's
 *    declarations (no other local function, class member, top-level
 *    function, or local binding of the same name); with uniqueness
 *    proven, every bare `name(...)` call in the file unambiguously
 *    targets this local function. A receiver-qualified `*.name(...)`
 *    call is then impossible for the same name and is refused. A local
 *    function cannot escape its file, so the call set is complete and
 *    no advisory is needed.
 *
 * Coordinate convention: `line` / `col` are interpreted exactly as
 * `apq refs` PRINTS them (`Span.lineCol().col - 1`), identical to
 * `Rename` / `Inline` / `ExtractVar`.
 */
@:nullSafety(Strict)
final class ChangeSig {

	/**
	 * Decl kinds the cursor's resolved node must carry to be a reorder
	 * target: a class method or a named local function. Both expose their
	 * leading `Required` / `Optional` children as the parameter list.
	 */
	private static final FN_DECL_KINDS:Array<String> = ['FnMember', 'LocalFnStmt'];

	/** Parameter slot kinds — the leading children of a function decl. */
	private static final PARAM_KINDS:Array<String> = ['Required', 'Optional'];

	/**
	 * Declaration kinds that, if any node of one carries the same name as
	 * the target local function, make a bare `name(...)` call ambiguous —
	 * so a `LocalFnStmt` reorder refuses unless its name is unique across
	 * all of these. Covers every binding a bare identifier could resolve
	 * to: other local functions, class members, top-level functions, and
	 * local var / final / param bindings.
	 */
	private static final NAME_CLASH_KINDS:Array<String> = [
		'LocalFnStmt', 'FnMember', 'VarMember', 'FinalMember', 'FnField', 'VarField', 'FinalField',
		'FnDecl', 'VarDecl',
		'VarStmt', 'FinalStmt', 'StaticVarStmt', 'StaticFinalStmt',
		'Required', 'Optional', 'Rest',
	];

	/**
	 * Reorder the parameters of the function whose decl / binding is at
	 * `line:col` in `source` per `perm`, permuting the positional
	 * arguments at every resolvable call site to match. `perm` is a
	 * comma-separated 0-based list giving the NEW order of OLD parameter
	 * indices (for `g(a, b, c)`, `2,0,1` reorders to `c, a, b`). `plugin`
	 * / `shape` are the caller-owned grammar plugin and its `RefShape`
	 * (the same pair the `refs` CLI builds), so the resolver stays
	 * language-agnostic. Returns `Ok(rewritten, advisory)` or an `Err`
	 * describing why the reorder could not be applied. The source is never
	 * mutated — the caller decides whether to write the result.
	 */
	public static function changeSig(source:String, line:Int, col:Int, perm:String, plugin:GrammarPlugin, shape:RefShape):ChangeSigResult {
		final tree:QueryNode = try plugin.parseFile(source)
			catch (exception:ParseError) return Err('source does not parse: ${exception.toString()}')
			catch (exception:Exception) return Err('source does not parse: ${exception.message}');

		// `apq refs` prints `Span.lineCol().col - 1`; invert that here so a
		// position copied from `refs` output maps back to the real offset.
		final cursor:Int = Span.offsetOf(source, line, col + 1);

		final node:Null<QueryNode> = RefactorSupport.resolveCursorNode(tree, cursor, source);
		if (node == null)
			return Err('position $line:$col is not on a function or a call');
		final cursorNode:QueryNode = node;
		final targetName:Null<String> = cursorNode.name;
		if (targetName == null)
			return Err('position $line:$col is not on a function or a call');
		final name:String = targetName;

		// Resolve the function declaration node. A cursor already on a
		// function decl IS that decl; otherwise (a bare call) resolve the
		// binding back to the decl through the shared resolver — this
		// works for methods (indexed by `Refs`) but not for local
		// functions reached via a call.
		final declNode:Null<QueryNode> = resolveDeclNode(cursorNode, tree, name, shape);
		if (declNode == null)
			return Err('could not resolve a function binding for "$name" at $line:$col');
		final decl:QueryNode = declNode;
		if (!FN_DECL_KINDS.contains(decl.kind))
			return Err('"$name" is not a function (change-sig reorders function parameters)');
		final declSpan:Null<Span> = decl.span;
		if (declSpan == null)
			return Err('"$name" declaration has no source span');
		final binding:Int = declSpan.from;

		// Parameters: the leading Required / Optional children, in source
		// order. The scan stops at the first child that is neither (the
		// `Named` return type or the body).
		final params:Array<QueryNode> = leadingParams(decl);
		final n:Int = params.length;
		if (n < 2)
			return Err('"$name" has fewer than 2 parameters — nothing to reorder');

		final order:Array<Int> = switch parsePerm(perm, n) {
			case POk(o): o;
			case PErr(message): return Err(message);
		};

		// Collect the call sites and prove the set is complete. The two
		// decl kinds use different strategies (see the class docstring).
		final isMethod:Bool = decl.kind == 'FnMember';
		final collected:CollectResult = isMethod
			? collectMethodCalls(tree, source, name, binding, shape)
			: collectLocalFnCalls(tree, source, name, binding);
		final callSites:Array<QueryNode> = switch collected {
			case CErr(message): return Err(message);
			case COk(sites): sites;
		};

		// Arity: every collected call must have exactly `n` positional
		// arguments. A call with omitted optional / defaulted arguments
		// cannot be slot-swapped, so it is a hard refusal rather than a
		// silent misorder.
		for (call in callSites) {
			final argc:Int = call.children.length - 1;
			if (argc != n) {
				final at:String = posOf(source, call.span);
				return Err('call at $at has $argc args, expected $n — change-sig cannot reorder calls with omitted optional arguments');
			}
		}

		// Build the slot-swap edits. Each new slot `i` is overwritten with
		// the source text of the item that the permutation moves into it
		// (`order[i]`). All spans are disjoint, so the splice is order-free.
		final edits:Array<{span:Span, text:String}> = [];
		appendSlotSwap(edits, source, params, order);
		for (call in callSites) {
			final args:Array<QueryNode> = call.children.slice(1);
			appendSlotSwap(edits, source, args, order);
		}

		final rewritten:String = RefactorSupport.applyEdits(source, edits);
		if (rewritten == source)
			return Err('reorder of "$name" is a no-op');

		try plugin.parseFile(rewritten)
			catch (exception:ParseError) return Err('rewritten source does not parse: ${exception.toString()}')
			catch (exception:Exception) return Err('rewritten source does not parse: ${exception.message}');

		final advisory:Null<String> = isMethod
			? 'updated the declaration and ${callSites.length} in-file call site(s); if "$name" is called from other files, update those call sites too — cross-file resolution is out of scope'
			: null;
		return Ok(rewritten, advisory);
	}

	/**
	 * The function declaration node the cursor identifies. When the cursor
	 * already sits on a `FnMember` / `LocalFnStmt` decl, that node is
	 * returned directly. Otherwise the cursor is on a call / reference and
	 * the binding is resolved back to its decl through the shared
	 * resolver: `resolveBindingFrom` yields the decl's `span.from`, and
	 * `nodeAtFrom` looks the decl node up by that offset. Returns null when
	 * nothing resolves.
	 */
	private static function resolveDeclNode(cursorNode:QueryNode, tree:QueryNode, name:String, shape:RefShape):Null<QueryNode> {
		if (FN_DECL_KINDS.contains(cursorNode.kind)) return cursorNode;

		final hits:Array<RefHit> = Refs.find(name, tree, shape);
		final bindingFrom:Null<Int> = RefactorSupport.resolveBindingFrom(cursorNode, hits);
		if (bindingFrom == null) return null;
		return RefactorSupport.nodeAtFrom(tree, bindingFrom);
	}

	/**
	 * The leading `Required` / `Optional` children of `decl`, in source
	 * order. The scan stops at the first child that is neither — the
	 * `Named` return-type child or the function body — so the return type
	 * is never mistaken for a parameter.
	 */
	private static function leadingParams(decl:QueryNode):Array<QueryNode> {
		final out:Array<QueryNode> = [];
		for (child in decl.children) {
			if (!PARAM_KINDS.contains(child.kind)) break;
			out.push(child);
		}
		return out;
	}

	/**
	 * Collect a method's in-file call sites and prove the set complete.
	 *
	 *  - Bare `name(...)` calls: every `Read` hit bound to `binding` whose
	 *    enclosing `Call` has an `IdentExpr name` callee at the hit's span.
	 *  - `this.name(...)` calls: matched structurally — a `Call` whose
	 *    callee is a `FieldAccess name` with an `IdentExpr this` receiver.
	 *
	 * Completeness scan: every `Call` callee named `name` must be in one
	 * of those two sets. A bare callee binding to a DIFFERENT decl is a
	 * different function (ignored); a bare callee with no resolvable
	 * binding, or an `obj.name(...)` call with a non-`this` receiver, is a
	 * refusal — those could be this very function but cannot be proven, so
	 * silently leaving their argument order stale is not allowed.
	 */
	private static function collectMethodCalls(tree:QueryNode, source:String, name:String, binding:Int, shape:RefShape):CollectResult {
		final hits:Array<RefHit> = Refs.find(name, tree, shape);
		final boundReads:Array<RefHit> = [
			for (h in hits)
				if (h.kind == RefKind.Read && h.bindingSpan != null && bindingFrom(h) == binding) h
		];
		final boundReadFroms:Array<Int> = [for (h in boundReads) h.span.from];

		final sites:Array<QueryNode> = [];
		final consumedFroms:Array<Int> = [];
		var thisSiteCount:Int = 0;
		var error:Null<String> = null;
		function walk(node:QueryNode):Void {
			if (error != null) return;
			if (node.kind == 'Call' && node.children.length > 0) {
				final callee:QueryNode = node.children[0];
				switch calleeShape(callee, name) {
					case CalleeBare(identSpan):
						// A bare `name(...)` call. It is OUR call iff its
						// callee identifier read binds to `binding`.
						if (boundReadFroms.contains(identSpan.from)) {
							sites.push(node);
							consumedFroms.push(identSpan.from);
						} else if (!bareBindsElsewhere(identSpan, hits))
							error = 'cannot prove all call sites target "$name": unresolved call at ${posOf(source, node.span)} — change-sig needs every call site resolvable';
					case CalleeThis:
						sites.push(node);
						thisSiteCount++;
					case CalleeOtherReceiver(recv):
						error = 'cannot resolve receiver-qualified call `$recv.$name(...)` at ${posOf(source, node.span)} — change-sig requires every call site resolvable (supported for local functions and methods called only via bare `$name(...)` / `this.$name(...)`)';
					case CalleeNone:
				}
			}
			for (c in node.children) {
				if (error != null) return;
				walk(c);
			}
		}
		walk(tree);
		// Refuse the method captured as a first-class value, whose indirect
		// calls cannot be tracked — reordering would silently break them.
		// Three capture forms: a bare `var fn = foo;` (a binding read not
		// consumed as a call callee), a `var f = this.foo;` (a `this.foo`
		// field access beyond the `this.foo(...)` call count), and a
		// `var f = obj.foo;` (any non-`this` receiver field access — its
		// call form already errored above).
		if (error == null) {
			final dangling:Null<RefHit> = boundReads.find(h -> !consumedFroms.contains(h.span.from));
			if (dangling != null)
				error = '"$name" is referenced as a value (not called) at ${posOf(source, dangling.span)} — change-sig cannot track indirect calls through a captured reference';
		}
		if (error == null) error = fieldAccessValueCapture(tree, source, name, thisSiteCount);
		return error != null ? CErr(error) : COk(sites);
	}

	/**
	 * Detect a method captured as a value via a field access — a
	 * `this.name` / `obj.name` `FieldAccess` that is not a call callee. A
	 * non-`this` receiver field access is always a refusal (its call form
	 * has already errored, so any remaining one is a value capture); a
	 * `this.name` field access is a refusal only for the surplus beyond
	 * the `this.name(...)` call sites (each call contributes exactly one
	 * `this.name` access). Returns the diagnostic or null when no value
	 * capture is present.
	 */
	private static function fieldAccessValueCapture(tree:QueryNode, source:String, name:String, thisSiteCount:Int):Null<String> {
		var thisAccess:Int = 0;
		var error:Null<String> = null;
		function scan(node:QueryNode):Void {
			if (error != null) return;
			if (node.kind == 'FieldAccess' && node.name == name && node.children.length > 0) {
				final recv:QueryNode = node.children[0];
				if (recv.kind == 'IdentExpr' && recv.name == 'this') thisAccess++;
				else error = '"$name" is referenced as a value (not called) at ${posOf(source, node.span)} — change-sig cannot track indirect calls through a captured reference';
			}
			for (c in node.children) scan(c);
		}
		scan(tree);
		if (error != null) return error;
		if (thisAccess > thisSiteCount)
			return '"$name" is referenced as a value (not called) via `this.$name` — change-sig cannot track indirect calls through a captured reference';
		return null;
	}

	/**
	 * Collect a local function's in-file call sites. `Refs` does not index
	 * local functions, so the name's UNIQUENESS across the file's
	 * declarations is required first (any clashing declaration makes a bare
	 * `name(...)` ambiguous). With uniqueness proven, every bare
	 * `name(...)` call in the file targets this function, and a
	 * receiver-qualified `*.name(...)` call is impossible for that name and
	 * is refused.
	 */
	private static function collectLocalFnCalls(tree:QueryNode, source:String, name:String, binding:Int):CollectResult {
		final clashes:Int = countNameDecls(tree, name);
		if (clashes > 1)
			return CErr('cannot prove all call sites target the local function "$name": another declaration named "$name" exists — change-sig refuses when a local-function name is ambiguous');

		final sites:Array<QueryNode> = [];
		var error:Null<String> = null;
		function walk(node:QueryNode):Void {
			if (error != null) return;
			if (node.kind == 'Call' && node.children.length > 0) {
				final callee:QueryNode = node.children[0];
				switch calleeShape(callee, name) {
					case CalleeBare(_):
						sites.push(node);
					case CalleeThis:
						error = 'cannot resolve `this.$name(...)` at ${posOf(source, node.span)} — `$name` is a local function, not a method';
					case CalleeOtherReceiver(recv):
						error = 'cannot resolve receiver-qualified call `$recv.$name(...)` at ${posOf(source, node.span)} — `$name` is a local function and cannot be called through a receiver';
					case CalleeNone:
				}
			}
			for (c in node.children) {
				if (error != null) return;
				walk(c);
			}
		}
		walk(tree);
		// With the name proven unique, every `IdentExpr` named `name` is a
		// reference to this local function. Each bare CALL contributes
		// exactly one such ident (its callee); a surplus is a non-call
		// value reference whose indirect calls cannot be tracked.
		if (error == null && countIdentExprNamed(tree, name) > sites.length)
			error = 'the local function "$name" is referenced as a value (not called) — change-sig cannot track indirect calls through a captured reference';
		return error != null ? CErr(error) : COk(sites);
	}

	/**
	 * Classify a `Call`'s callee node relative to the target `name`:
	 * a bare `IdentExpr name` (with its span), a `this.name` field access,
	 * an `obj.name` field access on a non-`this` receiver (with the
	 * receiver's display name), or none of these (a call to something
	 * else).
	 */
	private static function calleeShape(callee:QueryNode, name:String):CalleeShape {
		if (callee.kind == 'IdentExpr' && callee.name == name) {
			final span:Null<Span> = callee.span;
			return span == null ? CalleeNone : CalleeBare(span);
		}
		if (callee.kind == 'FieldAccess' && callee.name == name && callee.children.length > 0) {
			final recv:QueryNode = callee.children[0];
			if (recv.kind == 'IdentExpr' && recv.name == 'this') return CalleeThis;
			final recvName:String = recv.name == null ? recv.kind : recv.name;
			return CalleeOtherReceiver(recvName);
		}
		return CalleeNone;
	}

	/**
	 * Does the bare callee identifier at `identSpan` resolve to a binding
	 * (a different same-named function)? True ⇒ the call belongs to that
	 * other function and is safely ignored. False ⇒ the callee has no
	 * resolvable binding at all, so it cannot be proven NOT to be ours.
	 * `hits` is the already-computed `Refs.find(name, …)` result for the
	 * target name — reused so the resolver is not re-run per call site.
	 */
	private static function bareBindsElsewhere(identSpan:Span, hits:Array<RefHit>):Bool {
		final hit:Null<RefHit> = hits.find(h -> h.span.from == identSpan.from);
		return hit != null && hit.bindingSpan != null;
	}

	/** Count declarations named `name` anywhere in the tree. */
	private static function countNameDecls(tree:QueryNode, name:String):Int {
		var count:Int = 0;
		function walk(node:QueryNode):Void {
			if (node.name == name && NAME_CLASH_KINDS.contains(node.kind)) count++;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return count;
	}

	/** Count `IdentExpr` nodes named `name` anywhere in the tree. */
	private static function countIdentExprNamed(tree:QueryNode, name:String):Int {
		var count:Int = 0;
		function walk(node:QueryNode):Void {
			if (node.kind == 'IdentExpr' && node.name == name) count++;
			for (c in node.children) walk(c);
		}
		walk(tree);
		return count;
	}

	/**
	 * Append a slot-swap edit set: for each destination slot `i`, overwrite
	 * `slots[i].span` with the verbatim source text of `slots[order[i]]`.
	 * Only the slot contents move — the separators between slots are left
	 * untouched, so the existing layout is preserved. A no-move slot
	 * (`order[i] == i`) is still emitted; it is a harmless identity splice
	 * and the call-level no-op guard catches a fully-identity reorder.
	 */
	private static function appendSlotSwap(edits:Array<{span:Span, text:String}>, source:String, slots:Array<QueryNode>, order:Array<Int>):Void {
		for (i in 0...slots.length) {
			final destSpan:Null<Span> = slots[i].span;
			final srcSpan:Null<Span> = slots[order[i]].span;
			if (destSpan == null || srcSpan == null) continue;
			edits.push({span: new Span(destSpan.from, destSpan.to), text: source.substring(srcSpan.from, srcSpan.to)});
		}
	}

	/**
	 * Parse `perm` as a true permutation of `0..n-1`: exactly `n`
	 * comma-separated 0-based integers, each in range and all distinct.
	 * Rejects the identity permutation as a no-op. Returns the parsed order
	 * or a diagnostic.
	 */
	private static function parsePerm(perm:String, n:Int):PermResult {
		final parts:Array<String> = perm.split(',');
		if (parts.length != n)
			return PErr('permutation "$perm" lists ${parts.length} indices but the function has $n parameters');

		final order:Array<Int> = [];
		final seen:Array<Int> = [];
		for (part in parts) {
			final trimmed:String = StringTools.trim(part);
			final idx:Null<Int> = RefactorSupport.parseStrictInt(trimmed);
			if (idx == null)
				return PErr('permutation "$perm" contains a non-integer index "$trimmed"');
			final value:Int = idx;
			if (value < 0 || value >= n)
				return PErr('permutation "$perm" index $value is out of range 0..${n - 1}');
			if (seen.contains(value))
				return PErr('permutation "$perm" repeats index $value — must be a true permutation');
			seen.push(value);
			order.push(value);
		}

		var identity:Bool = true;
		for (i in 0...n) if (order[i] != i) identity = false;
		if (identity)
			return PErr('permutation "$perm" is the identity — nothing to reorder');

		return POk(order);
	}

	/** `from` offset of a Read / Write hit's binding span (caller null-checks). */
	private static inline function bindingFrom(hit:RefHit):Int {
		final b:Null<Span> = hit.bindingSpan;
		return b == null ? -1 : b.from;
	}

	/** Human-facing `line:col` for a span, in the `apq refs` print convention. */
	private static function posOf(source:String, span:Null<Span>):String {
		if (span == null) return '?:?';
		final pos:Position = span.lineCol(source);
		return '${pos.line}:${pos.col - 1}';
	}
}

/** Parsed permutation or a diagnostic — internal to `ChangeSig`. */
private enum PermResult {
	POk(order:Array<Int>);
	PErr(message:String);
}

/** Collected call sites or a completeness diagnostic — internal. */
private enum CollectResult {
	COk(sites:Array<QueryNode>);
	CErr(message:String);
}

/** Classification of a `Call`'s callee relative to the target name — internal. */
private enum CalleeShape {
	CalleeBare(identSpan:Span);
	CalleeThis;
	CalleeOtherReceiver(recv:String);
	CalleeNone;
}
