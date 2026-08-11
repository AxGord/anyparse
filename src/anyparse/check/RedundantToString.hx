package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;

using StringTools;
using Lambda;

/**
 * Flags a `.toString()` call sitting in a position that ALREADY stringifies, so the call only
 * restates what the language does anyway. `Severity.Info`; `fix` drops the call. **DEFAULT OFF** —
 * opt in per project with `apqlint.json` `"rules": { "redundant-tostring": { "enabled": true } }`, or
 * select it with `--rule redundant-tostring`.
 *
 * ## The four stringifying contexts
 *
 * - **interpolation** — `'${x.toString()}'` -> `'$x'` (a plain identifier, when the `$name`
 *   shorthand cannot swallow what follows) or `'${expr.toString()}'` -> `'${expr}'`;
 * - **concatenation** — an operand of a `+` whose OTHER operand is String-typed, since the
 *   concatenation stringifies it: `s + x.toString()` -> `s + x`;
 * - **`Std.string(...)`** — `Std.string(x.toString())` -> `Std.string(x)`;
 * - **identity** — the receiver is itself String-typed, so the call returns it unchanged:
 *   `s.toString()` -> `s`. This arm needs no surrounding context; the other three do.
 *
 * A bare `.toString()` in a STRING-REQUIRED position is deliberately NOT an arm: Haxe has no
 * implicit stringification when a String is EXPECTED, so `var now: String = Date.now().toString();`,
 * `f(d.toString())` into a `String` parameter and `return d.toString();` from a `:String` function
 * all stay silent — dropping the call there is a type error, not a cleanup. Silence there falls out
 * of the arms being CONTEXT-gated rather than receiver-gated; there is no separate veto to keep in
 * sync.
 *
 * ## Three proofs gate the FIX; a site missing one is still REPORTED
 *
 * Every finding whose fix is not proven carries a message naming the missing proof and produces no
 * edit, so `--fix` can only ever act on a site all three cover (`blockerFor`).
 *
 * **1. The receiver is non-null.** Removing the call turns a null receiver from a crash into the
 * text `null` (verified on js: `o.toString()` throws where `'$o'`, `Std.string(o)` and `'x' + o` all
 * yield `"null"`). Proven for: a plain identifier the shared prover accepts
 * (`TypeResolver.isProvablyNonNull` — a `RefShape.nonNullableTypeNames` value type, or any recovered
 * nominal type while `@:nullSafety` is active at both its declaration and the read; an optional /
 * default-null parameter or a `Null<…>` / `Dynamic` / `Any` type refuses); a `RefShape.newExprKind`
 * (a constructor cannot yield null); a literal; and a call whose declared return type is recovered
 * and is not a nullable wrapper — a STATIC from the curated `RefShape.staticMethodReturns` table
 * (hand-picked stdlib statics whose contract excludes null), or an INSTANCE call resolved through
 * `SymbolIndex.returnNominalOf`, which additionally requires `@:nullSafety` active at the call site.
 * The NULL LITERAL is excluded explicitly rather than by its absence from `literalTypeNames`, an
 * omission maintained for another consumer.
 *
 * **2. The coercion calls the DECLARED `toString`** (the three context arms; the identity arm
 * performs no coercion). The receiver's type must be declared in the analysed scope with NO EXTERN
 * declaration — see `coercionCallsDeclaredToString` for the measured `extern class Date` /
 * `extern class Array` divergence on js that makes this gate load-bearing rather than defensive.
 *
 * **3. `+` on the receiver really is concatenation** (the `+` arm only): its type must be a CLASS,
 * since an `abstract` may overload `@:op(A + B)` and the overload wins over the concatenation rule
 * (`isClassType`).
 *
 * ## Why a custom `toString` needs no separate gate
 *
 * Once proof 2 holds, the receiver's type is one the compiler itself compiles, so stringification
 * resolves to that type's own `toString` — for a class, an abstract and an `enum abstract` alike
 * (compile-and-run verified on `--interp` and js: an `abstract Deg(Float)` with `toString():String`
 * prints `45 deg` from `'$d'`, `Std.string(d)` and `'x' + d` exactly as from `d.toString()`). The
 * method therefore runs exactly once either way, so a `toString` with side effects is neither
 * silenced nor duplicated by the rewrite.
 *
 * ## Shape gates
 *
 * The call must take NO arguments and its receiver must be a VALUE: a static `Type.toString(x)`
 * (Haxe's `CallStack.toString(stack)`) is excluded by the argument count, and a zero-argument static
 * `Type.toString()` by `TypeResolver.receiverRootIsUnboundType` — dropping either would leave a bare
 * type reference. That same predicate silently declines any receiver whose ROOT binds to nothing the
 * resolver sees, `this.` and `super.` among them. The call must be the DIRECT operand / argument of
 * its context node, so `s + x.toString().substr(0)` (where the call is a receiver, not an operand) is
 * not touched. A comment anywhere in the removed `.toString()` text suppresses the fix (the finding
 * stays). Macro-reification subtrees (`RefShape.opaqueKinds`) are not descended into.
 */
@:nullSafety(Strict)
final class RedundantToString implements Check implements DefaultOff {

	/** The stringification method every arm looks for. */
	private static inline final TO_STRING: String = 'toString';

	/** The receiver name the `Std.string(...)` arm matches on. */
	private static inline final STD_TYPE: String = 'Std';

	/** The member name the `Std.string(...)` arm matches on. */
	private static inline final STD_METHOD: String = 'string';

	public function new() {}

	public function id(): String {
		return 'redundant-tostring';
	}

	public function description(): String {
		return 'a .toString() call in a position that already stringifies';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final resolved: Seams = seams;
		final index: SymbolIndex = SymbolIndex.build(files, plugin);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final context: Null<Ctx> = contextFor(plugin, entry.source, resolved, index);
			if (context == null) continue;
			for (found in collect(context)) {
				final blocker: Null<String> = found.blocker;
				violations.push({
					file: entry.file,
					span: found.span,
					rule: 'redundant-tostring',
					severity: Severity.Info,
					message: blocker == null ? 'redundant .toString() — ${found.why}' : 'redundant .toString() — ${found.why}, but $blocker'
				});
			}
		}
		return violations;
	}

	/**
	 * Re-collect the candidates for `source` and return the edit of each one a `violations`
	 * span names — the same collector `run` reports from, so the two can never disagree about
	 * which sites are fixable. A report-only finding contributes no edit.
	 */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final scope: SymbolIndex = index ?? SymbolIndex.build([{ file: '', source: source }], plugin);
		final context: Null<Ctx> = contextFor(plugin, source, seams, scope);
		if (context == null) return [];
		final wanted: Array<String> = [];
		for (violation in violations) {
			final span: Null<Span> = violation.span;
			if (span != null) wanted.push(spanKey(span));
		}
		final edits: Array<{ span: Span, text: String }> = [];
		for (found in collect(context)) {
			final edit: Null<{ span: Span, text: String }> = found.edit;
			if (edit != null && wanted.contains(spanKey(found.span))) edits.push(edit);
		}
		return edits;
	}

	/**
	 * Whether `c` continues an identifier. Hand-rolled rather than taken from a seam: the
	 * `$name` shorthand is the ONE place this check emits new syntax, and the alphabet that
	 * bounds it is the interpolation scanner's, not the grammar's general identifier rule.
	 */
	private static inline function isIdentContinue(c: Int): Bool {
		return (c >= 'a'.code && c <= 'z'.code) || (c >= 'A'.code && c <= 'Z'.code) || (c >= '0'.code && c <= '9'.code) || c == '_'.code;
	}

	/** A span rendered as the key `fix` matches a violation against its re-collected candidate by. */
	private static inline function spanKey(span: Span): String {
		return '${span.from}:${span.to}';
	}

	/**
	 * The per-file context `run` and `fix` share, or null when `source` does not parse. Both build
	 * it the same way, so the collector they drive can only differ through `index` — whole-scope in
	 * `run`, and whole-scope in `fix` too whenever the caller passes one (`Cli` always does).
	 */
	private static function contextFor(plugin: GrammarPlugin, source: String, seams: Seams, index: SymbolIndex): Null<Ctx> {
		final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, source);
		if (tree == null) return null;
		final provider: Null<TypeInfoProvider> = plugin is TypeInfoProvider ? cast plugin : null;
		return {
			root: tree,
			source: source,
			seams: seams,
			declaredTypes: provider == null ? [] : provider.declaredTypes(source),
			index: index
		};
	}

	/** Every `.toString()` candidate in the context's tree, each carrying its edit or the reason it has none. */
	private static function collect(ctx: Ctx): Array<Candidate> {
		final out: Array<Candidate> = [];
		function walk(node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>): Void {
			if (ctx.seams.opaqueKinds.contains(node.kind)) return;
			final found: Null<Candidate> = candidate(node, parent, grand, ctx);
			if (found != null) out.push(found);
			for (child in node.children) walk(child, node, parent);
		}
		walk(ctx.root, null, null);
		return out;
	}

	/** The candidate `node` is, or null when it is not a redundant `.toString()` call at all. */
	private static function candidate(node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>, ctx: Ctx): Null<Candidate> {
		final seams: Seams = ctx.seams;
		if (node.kind != seams.callKind || node.children.length != 1) return null;
		final callee: QueryNode = node.children[0];
		if (callee.kind != seams.fieldAccessKind || callee.name != TO_STRING || callee.children.length != 1) return null;
		final receiver: QueryNode = callee.children[0];
		final callSpan: Null<Span> = node.span;
		final recvSpan: Null<Span> = receiver.span;
		if (callSpan == null || recvSpan == null) return null;
		// `Type.toString()` reads a STATIC; dropping it would leave a bare type reference. The same
		// predicate also declines every receiver whose ROOT binds to nothing the resolver sees —
		// `this.toString()`, `super.toString()` and `this.f.toString()` among them — so those are
		// silently not candidates, while the bare `f.toString()` spelling of the same field read IS.
		if (TypeResolver.receiverRootIsUnboundType(receiver, ctx.root, seams.shape)) return null;
		final arm: Null<Arm> = classify(node, parent, grand, receiver, ctx);
		if (arm == null) return null;
		final blocker: Null<String> = blockerFor(arm, resolveReceiver(receiver, callSpan, ctx), recvSpan, callSpan, ctx);
		final why: String = reason(arm);
		return blocker != null
			? {
				span: callSpan,
				edit: null,
				why: why,
				blocker: blocker
			}
			: {
				span: callSpan,
				edit: rewrite(arm, receiver, callSpan, recvSpan, ctx),
				why: why,
				blocker: null
			};
	}

	/**
	 * Why this site is REPORT-ONLY, or null when its fix is proven safe. Three proofs, in the order
	 * a reader needs them: the receiver is non-null; the receiver's `toString` is the method the
	 * runtime's string coercion also calls; and, for the `+` arm alone, `+` on that receiver really
	 * is concatenation. Then the one textual guard — a comment inside the text the fix removes.
	 *
	 * The identity arm (`StringReceiver`) skips the middle two: it performs no coercion at all (a
	 * String's `toString` returns the receiver) and does not involve `+`.
	 */
	private static function blockerFor(arm: Arm, info: ReceiverInfo, recvSpan: Span, callSpan: Span, ctx: Ctx): Null<String> {
		if (!info.nonNull) return 'the receiver is not provably non-null, so dropping the call would print "null" where it throws';
		final typeName: Null<String> = info.typeName;
		if (arm != StringReceiver) {
			if (typeName == null || !coercionCallsDeclaredToString(typeName, ctx))
				return 'the receiver type is not a non-extern type '
					+ 'declared in scope, so its toString is not provably the method the string coercion calls';
			if (arm == Concat && !isClassType(typeName, ctx))
				return 'the receiver type is not a class, so a `+` operator overload could make this something other than concatenation';
		}
		final removed: String = ctx.source.substring(recvSpan.to, callSpan.to);
		return removed.indexOf('//') != -1 || removed.indexOf('/*') != -1 ? 'a comment sits inside the text the fix would remove' : null;
	}

	/** Which stringifying context `node` sits in, or null when it sits in none. */
	private static function classify(
		node: QueryNode, parent: Null<QueryNode>, grand: Null<QueryNode>, receiver: QueryNode, ctx: Ctx
	): Null<Arm> {
		final seams: Seams = ctx.seams;
		if (parent != null) {
			final host: QueryNode = parent;
			final blockKind: Null<String> = seams.stringInterpBlockKind;
			if (
				blockKind != null && grand != null && host.kind == blockKind && host.children.length == 1
				&& seams.stringLiteralKinds.contains(grand.kind)
			)
				return Interpolation(host, grand);
			final concatKind: Null<String> = seams.concatKind;
			if (
				concatKind != null && host.kind == concatKind && host.children.length == 2
				&& isStringTyped(host.children[0] == node ? host.children[1] : host.children[0], ctx)
			)
				return Concat;
			if (isStdStringArgument(host, node, ctx)) return StdString;
		}
		return isStringTyped(receiver, ctx) ? StringReceiver : null;
	}

	/**
	 * Whether the string coercion the context arms rely on provably calls the SAME `toString` the
	 * explicit call does: `typeName` must be declared in the analysed scope and NO declaration of it
	 * may be EXTERN. The two genuinely diverge for an extern type, whose methods are declarations
	 * over a foreign runtime object — measured on Haxe 4.3.7 / js, `extern class Date`'s
	 * `d.toString()` yields `2023-11-15 00:13:20` where `'$d'`, `Std.string(d)` and `'' + d` all
	 * yield the native `Wed Nov 15 2023 …`, and `extern class Array`'s `a.toString()` yields `1,2`
	 * where the same three yield `[1,2]`. A non-extern type is compiled by the compiler that also
	 * emits the coercion, so there is ONE `toString` and every context reaches it — verified for a
	 * class, an inherited `toString`, an `abstract` over `Array` and over `Date`, and an
	 * `enum abstract`. An unresolved, out-of-scope or extern type keeps the conservative default.
	 */
	private static function coercionCallsDeclaredToString(typeName: String, ctx: Ctx): Bool {
		final decls: Array<TypeDeclInfo> = declsOf(typeName, ctx);
		return decls.length != 0 && !decls.exists(decl -> decl.isExtern);
	}

	/**
	 * Whether every in-scope declaration of `typeName` is a CLASS. Haxe lets an `abstract` overload
	 * `+` (`@:op(A + B)`), and the overload is resolved BEFORE the String-concatenation rule, so the
	 * `+` arm's premise — the other operand being a String makes this a concatenation — holds only
	 * for a type that cannot carry one. Verified: an `abstract Tag(String)` with `@:op(A + B)` and
	 * `@:to String` silently changes the value once the explicit call is dropped.
	 */
	private static function isClassType(typeName: String, ctx: Ctx): Bool {
		final decls: Array<TypeDeclInfo> = declsOf(typeName, ctx);
		return decls.length != 0 && decls.foreach(decl -> ctx.seams.classDeclKinds.contains(decl.kind));
	}

	/** Every in-scope top-level declaration named `typeName`. */
	private static function declsOf(typeName: String, ctx: Ctx): Array<TypeDeclInfo> {
		return [for (info in ctx.index.declaringFiles(typeName)) for (decl in info.types) if (decl.name == typeName) decl];
	}

	/** The human-facing half of a finding's message — why this position already stringifies. */
	private static function reason(arm: Arm): String {
		return switch arm {
			case Interpolation(_): 'string interpolation stringifies its expression';
			case Concat: 'concatenation with a String stringifies the other operand';
			case StdString: 'Std.string() stringifies its argument';
			case StringReceiver: 'the receiver is already a String';
		};
	}

	/**
	 * Whether `call` is `Std.string(arg)` with `arg` as its single argument. The `Std` receiver is
	 * checked to bind to NO value, exactly as the `.toString()` receiver is: a local named `Std`
	 * shadowing the class would otherwise take this arm.
	 */
	private static function isStdStringArgument(call: QueryNode, arg: QueryNode, ctx: Ctx): Bool {
		final seams: Seams = ctx.seams;
		if (call.kind != seams.callKind || call.children.length != 2 || call.children[1] != arg) return false;
		final callee: QueryNode = call.children[0];
		if (callee.kind != seams.fieldAccessKind || callee.name != STD_METHOD || callee.children.length != 1) return false;
		final receiver: QueryNode = callee.children[0];
		return receiver.kind == seams.identKind && receiver.name == STD_TYPE
			&& TypeResolver.receiverRootIsUnboundType(receiver, ctx.root, seams.shape);
	}

	/**
	 * Whether `node` is provably String-typed: a string literal, an identifier whose recovered
	 * nominal type is the grammar's string type, or a concatenation with a String-typed operand
	 * (`+` yields a String as soon as either side is one, so a chain stays String all the way up).
	 * Any other shape keeps the conservative default.
	 */
	private static function isStringTyped(node: QueryNode, ctx: Ctx): Bool {
		final seams: Seams = ctx.seams;
		if (seams.stringLiteralKinds.contains(node.kind)) return true;
		final stringTypeName: Null<String> = seams.stringTypeName;
		if (node.kind == seams.identKind)
			return stringTypeName != null && TypeResolver.identTypeName(node, ctx.root, seams.shape, ctx.declaredTypes) == stringTypeName;
		final concatKind: Null<String> = seams.concatKind;
		return concatKind != null && node.kind == concatKind && node.children.length == 2
			&& (isStringTyped(node.children[0], ctx) || isStringTyped(node.children[1], ctx));
	}

	/**
	 * The receiver's resolved simple nominal TYPE NAME plus whether it is provably NON-NULL — the
	 * two facts every gate downstream needs, recovered in one pass because the same shape decides
	 * both. A plain identifier goes through the shared prover (`TypeResolver.isProvablyNonNull`); a
	 * `new T(...)` and a literal are non-null by construction; a call is resolved through its
	 * declared return type. The NULL LITERAL is excluded FIRST and explicitly: it is absent from
	 * `literalTypeNames` today, but that omission is maintained for another consumer, and inheriting
	 * it would make `null.toString()` fixable the day the map gains an entry.
	 */
	private static function resolveReceiver(receiver: QueryNode, callSpan: Span, ctx: Ctx): ReceiverInfo {
		final seams: Seams = ctx.seams;
		final unresolved: ReceiverInfo = { typeName: null, nonNull: false };
		if (receiver.kind == seams.identKind) return {
			typeName: TypeResolver.identTypeName(receiver, ctx.root, seams.shape, ctx.declaredTypes),
			nonNull: TypeResolver.isProvablyNonNull(receiver, ctx.root, seams.shape, ctx.declaredTypes)
		};
		if (receiver.kind == seams.shape.nullLiteralKind) return unresolved;
		final newExprKind: Null<String> = seams.shape.newExprKind;
		if (newExprKind != null && receiver.kind == newExprKind)
			return { typeName: TypeResolver.simpleNominalName(receiver.name), nonNull: true };
		final literalType: Null<String> = seams.literalTypeNames[receiver.kind];
		return if (literalType != null)
			{ typeName: literalType, nonNull: true }
		else if (receiver.kind == seams.callKind)
			callReceiver(receiver, callSpan, ctx)
		else
			unresolved;
	}

	/**
	 * The `resolveReceiver` arm for a CALL receiver: its declared return type, when that is recovered
	 * and is not a nullable wrapper. A genuine `Type.method()` goes through the curated
	 * `RefShape.staticMethodReturns` table, whose entries are hand-picked stdlib statics whose
	 * contract excludes null, so no further gate applies. An INSTANCE call is resolved through
	 * `SymbolIndex.returnNominalOf` and is non-null only while `@:nullSafety` is active at the call
	 * site — the same trust `isProvablyNonNull` places in a declared field type, with the same
	 * residual: a declarer under `@:nullSafety(Off)` could still return null.
	 */
	private static function callReceiver(call: QueryNode, callSpan: Span, ctx: Ctx): ReceiverInfo {
		final seams: Seams = ctx.seams;
		final unresolved: ReceiverInfo = { typeName: null, nonNull: false };
		if (call.children.length == 0) return unresolved;
		final callee: QueryNode = call.children[0];
		if (callee.kind != seams.fieldAccessKind || callee.children.length != 1) return unresolved;
		final method: Null<String> = callee.name;
		if (method == null) return unresolved;
		final owner: QueryNode = callee.children[0];
		final ownerName: Null<String> = owner.name;
		if (ownerName != null && TypeResolver.receiverRootIsUnboundType(owner, ctx.root, seams.shape)) {
			final declared: Null<String> = nonWrapperNominal(seams.staticMethodReturns['$ownerName.$method'], seams);
			return declared == null ? unresolved : { typeName: declared, nonNull: true };
		}
		final ownerType: Null<String> = TypeResolver.identTypeName(owner, ctx.root, seams.shape, ctx.declaredTypes);
		final metaName: Null<String> = seams.shape.nullSafetyMetaName;
		if (ownerType == null || metaName == null) return unresolved;
		final returned: Null<String> = nonWrapperNominal(ctx.index.returnNominalOf(ownerType, method), seams);
		return returned == null ? unresolved : {
			typeName: returned,
			nonNull: TypeResolver.enclosingIsNullSafe(ctx.root, callSpan, metaName, seams.shape.nullSafetyDisableArg)
		};
	}

	/** `typeSrc`'s simple nominal name, or null when it is absent or names one of the nullable wrappers. */
	private static function nonWrapperNominal(typeSrc: Null<String>, seams: Seams): Null<String> {
		final simple: Null<String> = TypeResolver.simpleNominalName(typeSrc);
		return simple != null && !seams.nullableWrapperTypeNames.contains(simple) ? simple : null;
	}

	/**
	 * The edit for an approved candidate: drop the `.toString()` text, or — in an interpolation
	 * block holding nothing else — collapse the whole `${ … }` to the `$name` shorthand.
	 */
	private static function rewrite(arm: Arm, receiver: QueryNode, callSpan: Span, recvSpan: Span, ctx: Ctx): { span: Span, text: String } {
		final drop: { span: Span, text: String } = { span: new Span(recvSpan.to, callSpan.to), text: '' };
		return switch arm {
			case Interpolation(block, literal): collapse(block, literal, receiver, callSpan, ctx) ?? drop;
			case _: drop;
		};
	}

	/**
	 * `'${x.toString()}'` -> `'$x'`, or null when the shorthand does not apply and the plain drop
	 * (`'${x}'`) is used instead. The receiver must be a plain identifier; the block must hold the
	 * call and NOTHING else, which is span arithmetic — a `${ … }` block spans exactly `$`, `{`, its
	 * expression, `}`, so any comment or spacing inside it shows up as slack at either end; and
	 * nothing must be able to EXTEND the `$name` read past the block: the next character must not
	 * continue an identifier, and — because Haxe DECODES a literal's escapes before it scans for
	 * interpolation, the very fact `HxInterpProjection` is built on — a literal carrying `\x` / `\u`
	 * anywhere is refused outright. Verified: `'${x.toString()}\x61'` prints `KKKa`, while the
	 * collapsed `'$x\x61'` is a read of `xa` — an `Unknown identifier` when none exists, and a
	 * SILENTLY different value when one does.
	 */
	private static function collapse(
		block: QueryNode, literal: QueryNode, receiver: QueryNode, callSpan: Span, ctx: Ctx
	): Null<{ span: Span, text: String }> {
		final source: String = ctx.source;
		final name: Null<String> = receiver.name;
		final blockSpan: Null<Span> = block.span;
		final literalSpan: Null<Span> = literal.span;
		if (receiver.kind != ctx.seams.identKind || name == null || blockSpan == null || literalSpan == null) return null;
		final span: Span = blockSpan;
		if (span.from != callSpan.from - 2 || span.to != callSpan.to + 1) return null;
		final literalSource: String = source.substring(literalSpan.from, literalSpan.to);
		return if (literalSource.indexOf('\\x') != -1 || literalSource.indexOf('\\u') != -1)
			null
		else if (span.to < source.length && isIdentContinue(source.fastCodeAt(span.to)))
			null
		else
			{ span: span, text: '$$$name' };
	}

	/** Resolve the seam kinds this check reads, or null when a required one is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final callKind: Null<String> = shape.callKind;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (callKind == null || fieldAccessKind == null) return null;
		final stringLiteralKinds: Array<String> = shape.stringLiteralKinds ?? [];
		final literalTypeNames: Map<String, String> = shape.literalTypeNames ?? [];
		final classDeclKinds: Array<String> = (shape.classDeclKinds ?? []).copy();
		for (kind in [shape.plainClassDeclKind, shape.finalClassDeclKind]) if (kind != null && !classDeclKinds.contains(kind))
			classDeclKinds.push(kind);
		final fold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		return {
			shape: shape,
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			identKind: shape.identKind,
			stringInterpBlockKind: shape.stringInterpBlockKind,
			stringLiteralKinds: stringLiteralKinds,
			stringTypeName: stringLiteralKinds.length == 0 ? null : literalTypeNames[stringLiteralKinds[0]],
			literalTypeNames: literalTypeNames,
			classDeclKinds: classDeclKinds,
			concatKind: fold?.concatKind(),
			staticMethodReturns: shape.staticMethodReturns ?? [],
			nullableWrapperTypeNames: shape.nullableWrapperTypeNames ?? [],
			opaqueKinds: shape.opaqueKinds ?? []
		};
	}

}

/** Which stringifying CONTEXT makes a `toString()` call redundant. */
private enum Arm {

	/**
	 * Inside a `${ … }` interpolation block. Carries the block node the `$name` collapse rewrites
	 * and the string literal that owns it, whose escapes decide whether the collapse is safe.
	 */
	Interpolation(block: QueryNode, literal: QueryNode);

	/** A direct operand of a `+` whose other operand is String-typed. */
	Concat;

	/** The single argument of a `Std.string(...)` call. */
	StdString;

	/** The receiver is itself String-typed, so the call is the identity — no surrounding context needed. */
	StringReceiver;

}

/** One `.toString()` site, already resolved to its edit or to the reason it has none. */
private typedef Candidate = {

	/** The call node's span — the violation's span and the key `fix` matches on. */
	final span: Span;

	/** The edit that removes the call, or null when `blocker` says why there is none. */
	final edit: Null<{ span: Span, text: String }>;

	/** Why this position already stringifies — the first half of the message. */
	final why: String;

	/** Why the site is report-only, or null when it is fixable. */
	final blocker: Null<String>;
};

/** The resolved seams `RedundantToString` reads in both `run` and `fix`. */
private typedef Seams = {

	/** The whole shape, for the `TypeResolver` calls that take it directly. */
	final shape: RefShape;

	final callKind: String;
	final fieldAccessKind: String;
	final identKind: String;

	/** The `${ … }` interpolation block kind, or null when the grammar has no interpolation. */
	final stringInterpBlockKind: Null<String>;

	/** The string-literal kinds — a literal operand is String-typed by construction. */
	final stringLiteralKinds: Array<String>;

	/** The grammar's string type name, read off `literalTypeNames` for a string literal kind. */
	final stringTypeName: Null<String>;

	/** Literal kind -> type name; its KEYS are the literal receivers that are non-null by construction. */
	final literalTypeNames: Map<String, String>;

	/** Every CLASS declaration kind — the only shapes that cannot overload `+`. */
	final classDeclKinds: Array<String>;

	/** The string-concatenation operator kind, or null when the grammar declares no `StringFoldSupport`. */
	final concatKind: Null<String>;

	/** `Type.method` -> declared return type, the curated non-null static table. */
	final staticMethodReturns: Map<String, String>;

	/** Type names that WRAP a nullable value, so a declared return of one proves nothing. */
	final nullableWrapperTypeNames: Array<String>;

	/** Subtrees the walk does not descend into (macro reification). */
	final opaqueKinds: Array<String>;
};

/** The per-file inputs every collector function reads — one struct instead of a six-parameter tuple. */
private typedef Ctx = {
	final root: QueryNode;
	final source: String;
	final seams: Seams;
	final declaredTypes: Map<Int, String>;

	/** The resolution scope: whole-analysed-set in `run`, and in `fix` whenever the caller passes one. */
	final index: SymbolIndex;
};

/** What a receiver resolves to — the two facts every gate downstream needs. */
private typedef ReceiverInfo = {

	/** The receiver's SIMPLE nominal type name, or null when unresolved. */
	final typeName: Null<String>;

	/** Whether the receiver is provably non-null. */
	final nonNull: Bool;
};
