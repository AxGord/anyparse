package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.query.TypeInfoProvider;
import anyparse.query.TypeResolver;
import anyparse.runtime.Span;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.ConcatOperand;

/**
 * Flags `Std.string(x)` and rewrites it to string interpolation — `'$x'` for a simple
 * identifier, `'${expr}'` for any other interpolation-safe expression — `Severity.Info`
 * (a modernization cleanup matching the Haxe idiom: direct conversion, no reflection
 * overhead), with an autofix.
 *
 * Minimal safe subset: only a single-argument `Std.string(...)` call is touched. An
 * argument whose source contains a quote, a `$`, or a newline is left alone — wrapping it
 * in `'${ … }'` could break the string (an inner `'` would close it). String
 * concatenation around the call (`"a" + Std.string(x)`) is not merged into one
 * interpolated string here — only the `Std.string(x)` node itself is rewritten in place,
 * which stays correct (`"a" + '$x'`); the harder merge is a separate concern.
 *
 * ## Not equivalence-preserving for every argument
 *
 * `Std.string` accepts `Null<Dynamic>` and never rejects a nullable argument; the
 * interpolation form compiles to a `+`-concatenation that DOES, under
 * `@:nullSafety(Strict)`, reject a nullable operand — and field access never narrows
 * (a preceding `obj.field != null` guard does not make `obj.field` provably non-null to
 * the checker), so rewriting `Std.string(obj.field)` to `'${obj.field}'` can turn
 * working code into a null-safety compile error. A bare field access (`Std.string(o.f)`)
 * is therefore left alone unconditionally. A simple-identifier argument (a local /
 * parameter) is rewritten only when its resolved declaration is provably not itself
 * nullable — a known nominal type (unannotated / inferred locals are conservatively
 * skipped, their type being unknown) that is not `Null<…>` / `Dynamic` / `Any`, not an
 * optional parameter (`?p`), and not a default-null parameter (`p: T = null`). Any other
 * argument shape (a call, a binary expression, …) keeps the pre-existing
 * `interpolationSafe`-gated braced rewrite.
 *
 * ## Grammar-agnostic
 *
 * Driven by `RefShape.callKind`, `fieldAccessKind`, and `identKind` (a missing optional
 * kind → no-op); the receiver `Std` and member `string` are matched on node names, not
 * kinds. The outermost matching call is flagged and not descended into, so a nested
 * `Std.string(Std.string(x))` yields one non-overlapping fix. The identifier-safety gate
 * degrades gracefully when `plugin` is not a `TypeInfoProvider` (no declared-type map,
 * treated as empty) — a simple identifier is then never proven safe and is left alone.
 */
@:nullSafety(Strict)
final class PreferInterpolation implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-interpolation';
	}

	public function description(): String {
		return "a Std.string(x) call replaceable with string interpolation ('$x')";
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final shape: RefShape = plugin.refShape();
		final provider: Null<TypeInfoProvider> = (plugin is TypeInfoProvider) ? cast plugin : null;
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree == null) continue;
			final declaredTypes: Map<Int, String> = provider == null ? [] : provider.declaredTypes(entry.source);
			walk(violations, entry.file, entry.source, tree, tree, seams, shape, declaredTypes);
		}
		return violations;
	}

	/** Rewrite each flagged `Std.string(arg)` or `+` concatenation to its interpolation. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final seams: Null<Seams> = resolveSeams(plugin);
		if (seams == null) return [];
		final sf: Null<StringFoldSupport> = seams.stringFold;
		final kinds: Array<String> = sf != null ? [seams.callKind, sf.concatKind()] : [seams.callKind];
		return CheckScan.applyBySpan(plugin, source, violations, kinds, (node, span) -> {
			if (sf != null && node.kind == sf.concatKind()) {
				final text: Null<String> = renderChain(node, source, seams);
				return text == null ? null : { span: span, text: text };
			}
			final arg: Null<QueryNode> = matchArg(node, seams.callKind, seams.fieldAccessKind, seams.identKind);
			final replacement: Null<String> = arg == null ? null : render(arg, source, seams.identKind);
			return replacement == null ? null : { span: span, text: replacement };
		});
	}

	/**
	 * Walk `node`; flag the outermost `Std.string(...)` call and STOP — a nested one
	 * inside the argument would yield an overlapping fix, and is caught on the next
	 * `--fix` iteration.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, root: QueryNode, node: QueryNode, seams: Seams, shape: RefShape,
		declaredTypes: Map<Int, String>
	): Void {
		final opaque: Null<Array<String>> = shape.opaqueKinds;
		if (opaque != null && opaque.contains(node.kind)) return;
		final sf: Null<StringFoldSupport> = seams.stringFold;
		if (sf != null && node.kind == sf.concatKind()) {
			final chainText: Null<String> = renderChain(node, source, seams);
			final chainSpan: Null<Span> = node.span;
			if (chainText != null && chainSpan != null) {
				out.push({
					file: file,
					span: chainSpan,
					rule: 'prefer-interpolation',
					severity: Severity.Info,
					message: 'this string concatenation can be string interpolation'
				});
				return;
			}
		}
		final arg: Null<QueryNode> = matchArg(node, seams.callKind, seams.fieldAccessKind, seams.identKind);
		if (
			arg != null && isSafeArg(arg, root, seams.fieldAccessKind, seams.identKind, shape, declaredTypes)
			&& render(arg, source, seams.identKind) != null
		) {
			final span: Null<Span> = node.span;
			if (span != null) {
				out.push({
					file: file,
					span: span,
					rule: 'prefer-interpolation',
					severity: Severity.Info,
					message: 'this Std.string() call can be string interpolation'
				});
				return;
			}
		}
		for (c in node.children) walk(out, file, source, root, c, seams, shape, declaredTypes);
	}

	/**
	 * If `call` is a single-argument `Std.string(arg)`, its argument node; else null.
	 * Purely structural — the caller separately gates safety (`isSafeArg`, `run`-side
	 * only) and renders the replacement (`render`).
	 */
	private static function matchArg(call: QueryNode, callKind: String, fieldAccessKind: String, identKind: String): Null<QueryNode> {
		if (call.kind != callKind || call.children.length != 2) return null;
		final callee: QueryNode = call.children[0];
		if (callee.kind != fieldAccessKind || callee.name != 'string' || callee.children.length != 1) return null;
		final receiver: QueryNode = callee.children[0];
		return receiver.kind != identKind || receiver.name != 'Std' ? null : call.children[1];
	}

	/**
	 * Whether `arg` is safe to rewrite into an interpolation under
	 * `@:nullSafety(Strict)` — `Std.string` accepts a nullable value; the
	 * interpolation's underlying `+`-concatenation does not, so an argument that
	 * is not provably non-null must be left alone.
	 *
	 * A bare field access (`fieldAccessKind`) never narrows and is always refused,
	 * guard or not. A simple identifier (`identKind`) is safe only when it resolves
	 * (via the scope resolver) to a local / parameter declaration with a KNOWN
	 * nominal type — an unresolved binding or an unannotated/inferred declaration
	 * (absent from `declaredTypes`) keeps the conservative default — that is not an
	 * optional parameter (`?p`), not a default-null parameter (`p: T = null`), and
	 * not one of `RefShape.nullableWrapperTypeNames` (`Null<…>` / `Dynamic` / `Any`).
	 * Any other argument shape (a call, a binary expression, …) is left to the
	 * pre-existing `interpolationSafe`-gated braced rewrite, unaffected by this gate.
	 */
	private static function isSafeArg(
		arg: QueryNode, root: QueryNode, fieldAccessKind: String, identKind: String, shape: RefShape, declaredTypes: Map<Int, String>
	): Bool {
		if (arg.kind == fieldAccessKind) return false;
		if (arg.kind != identKind) return true;
		final bindingFrom: Null<Int> = TypeResolver.identBindingFrom(arg, root, shape);
		if (bindingFrom == null) return false;
		final optionalParamKind: Null<String> = shape.optionalParamKind;
		if (optionalParamKind != null && TypeResolver.bindingIsOptionalParam(root, bindingFrom, optionalParamKind)) return false;
		final paramKinds: Null<Array<String>> = shape.paramKinds;
		final nullLiteralKind: Null<String> = shape.nullLiteralKind;
		if (
			paramKinds != null && nullLiteralKind != null
			&& TypeResolver.bindingIsDefaultNullParam(root, bindingFrom, paramKinds, nullLiteralKind)
		)
			return false;
		final typeName: Null<String> = declaredTypes[bindingFrom];
		if (typeName == null) return false;
		final nullableWrapperTypeNames: Array<String> = shape.nullableWrapperTypeNames ?? [];
		return !nullableWrapperTypeNames.contains(typeName);
	}

	/**
	 * The interpolation text for an already-approved `arg` (`'$x'` for a simple
	 * identifier, `'${expr}'` for an interpolation-safe expression); else null.
	 */
	private static function render(arg: QueryNode, source: String, identKind: String): Null<String> {
		final argName: Null<String> = arg.name;
		if (arg.kind == identKind && argName != null) return "'$" + argName + "'";
		final span: Null<Span> = arg.span;
		if (span == null) return null;
		final src: String = source.substring(span.from, span.to);
		return !interpolationSafe(src) ? null : "'${" + src + "}'";
	}

	/** Whether `src` can sit inside a single-quoted `'${ … }'` without breaking the string. */
	private static function interpolationSafe(src: String): Bool {
		for (i in 0...src.length) {
			final c: Int = StringTools.fastCodeAt(src, i);
			// A single-quote, double-quote, dollar, or newline in the argument source would
			// close or re-interpolate the wrapping '${ … }', making the rewrite unsafe.
			if (c == "'".code || c == '"'.code || c == "$".code || c == '\n'.code || c == '\r'.code) return false;
		}
		return true;
	}


	/** Resolve the call / field-access / ident seam kinds, or null when a required kind is unset. */
	private static function resolveSeams(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final callKind: Null<String> = shape.callKind;
		if (callKind == null) return null;
		final fieldAccessKind: Null<String> = shape.fieldAccessKind;
		if (fieldAccessKind == null) return null;
		final identKind: String = shape.identKind;
		final stringFold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		return {
			callKind: callKind,
			fieldAccessKind: fieldAccessKind,
			identKind: identKind,
			stringFold: stringFold
		};
	}


	/**
	 * The single-quoted interpolated string a qualifying `+`-concatenation `node`
	 * folds to, or null when the chain does not qualify (fewer than two operands,
	 * no string literal, no non-literal operand, an interpolated-literal operand,
	 * or an interior comment). Used as BOTH the walk-side qualify check (non-null
	 * means flag) and the fix-side replacement text, so it recomputes rather than
	 * caching state across the two passes.
	 */
	private static function renderChain(node: QueryNode, source: String, seams: Seams): Null<String> {
		final stringFold: Null<StringFoldSupport> = seams.stringFold;
		if (stringFold == null) return null;
		final concatKind: String = stringFold.concatKind();
		final operands: Array<QueryNode> = [];
		var cur: QueryNode = node;
		while (cur.kind == concatKind && cur.children.length == 2) {
			operands.unshift(cur.children[1]);
			cur = cur.children[0];
		}
		operands.unshift(cur);
		if (operands.length < 2) return null;
		final classes: Array<ConcatOperand> = [for (op in operands) stringFold.stringConcatOperand(op, source)];
		var firstLitIdx: Int = -1;
		var hasNonLiteral: Bool = false;
		for (i in 0...classes.length) switch classes[i] {
			case InterpolatedStringLit:
				return null;
			case StringLit(_, _):
				if (firstLitIdx == -1) firstLitIdx = i;
			case NonStringOperand:
				hasNonLiteral = true;
		}
		if (firstLitIdx == -1 || !hasNonLiteral) return null;
		final firstSpan: Null<Span> = operands[0].span;
		final lastSpan: Null<Span> = operands[operands.length - 1].span;
		if (firstSpan == null || lastSpan == null) return null;
		if (chainHasComment(source, firstSpan.from, lastSpan.to)) return null;
		final parts: Null<Array<Part>> = buildParts(operands, classes, firstLitIdx, source, seams);
		return parts == null ? null : "'" + joinParts(parts) + "'";
	}

	/**
	 * `node` rendered as a `PIdent` (a simple identifier) or a brace-safe `PExpr`
	 * (any other expression); null when its source is not brace-safe or its span
	 * is missing.
	 */
	private static function identOrExprPart(node: QueryNode, source: String, identKind: String): Null<Part> {
		final name: Null<String> = node.name;
		if (node.kind == identKind && name != null) return PIdent(name);
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final s: String = source.substring(span.from, span.to);
		return braceSafeExpr(s) ? PExpr(s) : null;
	}

	/** Whether `s` can sit inside a single-quoted `'${ … }'` interpolation (no `$`, no newline; quotes are allowed). */
	private static function braceSafeExpr(s: String): Bool {
		for (i in 0...s.length) {
			final c: Int = StringTools.fastCodeAt(s, i);
			if (c == "$".code || c == '\n'.code || c == '\r'.code) return false;
		}
		return true;
	}

	/** The single-quoted-context escaping of a `+`-operand literal's raw `content` (its `quote` selects the rule). */
	private static function escapeLiteral(quote: String, raw: String): String {
		return quote == "'" ? normalizeSingleDollars(raw) : escapeDoubleToSingle(raw);
	}

	/**
	 * Normalize a single-quoted literal's already-escaped raw `content` for reuse
	 * inside a single-quoted interpolation: a lone `$` becomes `$$`, an existing
	 * `$$` pair is preserved. Every other character (`\'`, `\n`, `\\`, `\x..`) is
	 * copied verbatim.
	 */
	private static function normalizeSingleDollars(s: String): String {
		final buf: StringBuf = new StringBuf();
		var i: Int = 0;
		while (i < s.length) {
			final c: Int = StringTools.fastCodeAt(s, i);
			if (c == "$".code) {
				buf.add("$$");
				i += i + 1 < s.length && StringTools.fastCodeAt(s, i + 1) == "$".code ? 2 : 1;
			} else {
				buf.addChar(c);
				i++;
			}
		}
		return buf.toString();
	}

	/**
	 * Re-escape a double-quoted literal's raw `content` for a single-quoted
	 * interpolation: `\"` becomes `"`, `$` becomes `$$`, `'` becomes `\'`; other
	 * escapes (`\n`, `\t`, `\\`, `\x..`) and plain characters are copied verbatim.
	 */
	private static function escapeDoubleToSingle(raw: String): String {
		final buf: StringBuf = new StringBuf();
		var i: Int = 0;
		while (i < raw.length) {
			final c: Int = StringTools.fastCodeAt(raw, i);
			if (c == '\\'.code && i + 1 < raw.length) {
				final n: Int = StringTools.fastCodeAt(raw, i + 1);
				if (n == '"'.code) {
					buf.addChar('"'.code);
				} else {
					buf.addChar('\\'.code);
					buf.addChar(n);
				}
				i += 2;
			} else if (c == "$".code) {
				buf.add("$$");
				i++;
			} else if (c == "'".code) {
				buf.add("\\'");
				i++;
			} else {
				buf.addChar(c);
				i++;
			}
		}
		return buf.toString();
	}

	/** Concatenate `parts` into the interpolation body (`$name` / `${expr}` / literal text). */
	private static function joinParts(parts: Array<Part>): String {
		final buf: StringBuf = new StringBuf();
		for (i in 0...parts.length) switch parts[i] {
			case PLit(t):
				buf.add(t);
			case PExpr(e):
				buf.add("${" + e + "}");
			case PIdent(name):
				final nc: Int = nextOutputChar(parts, i + 1);
				buf.add(nc != -1 && isIdentContinue(nc) ? "${" + name + "}" : "$" + name);
		}
		return buf.toString();
	}

	/** The first output character code that `parts[j...]` emits, or -1 when none remain. */
	private static function nextOutputChar(parts: Array<Part>, j: Int): Int {
		for (k in j ... parts.length) switch parts[k] {
			case PLit(t):
				if (t.length > 0) return StringTools.fastCodeAt(t, 0);
			case PExpr(_), PIdent(_):
				return "$".code;
		}
		return -1;
	}

	/** Whether `code` continues an identifier (a letter, a digit, or an underscore). */
	private static function isIdentContinue(code: Int): Bool {
		return code >= 'a'.code && code <= 'z'.code || code >= 'A'.code && code <= 'Z'.code || code >= '0'.code && code <= '9'.code
			|| code == '_'.code;
	}

	/**
	 * Whether the source range `[from, to)` carries a `//` or `/*` comment OUTSIDE
	 * any string literal — a comment between chain operands would be lost by the
	 * fold, so such a chain is left alone. String bodies are skipped (respecting
	 * `\` escapes) so a `'http://x'` literal does not read as a comment.
	 */
	private static function chainHasComment(source: String, from: Int, to: Int): Bool {
		var i: Int = from;
		while (i < to) {
			final c: Int = StringTools.fastCodeAt(source, i);
			if (c == "'".code || c == '"'.code) {
				i++;
				while (i < to) {
					final d: Int = StringTools.fastCodeAt(source, i);
					if (d == '\\'.code) {
						i += 2;
					} else if (d == c) {
						i++;
						break;
					} else {
						i++;
					}
				}
			} else if (c == '/'.code && i + 1 < to) {
				final n: Int = StringTools.fastCodeAt(source, i + 1);
				if (n == '/'.code || n == '*'.code) return true;
				i++;
			} else {
				i++;
			}
		}
		return false;
	}


	/**
	 * The `Part` list a qualifying chain's operands render to (prefix expression,
	 * then one part per operand from `firstLitIdx`), or null when any operand's
	 * source is not brace-safe or a span is missing.
	 */
	private static function buildParts(
		operands: Array<QueryNode>, classes: Array<ConcatOperand>, firstLitIdx: Int, source: String, seams: Seams
	): Null<Array<Part>> {
		final parts: Array<Part> = [];
		if (firstLitIdx == 1) {
			final part: Null<Part> = identOrExprPart(operands[0], source, seams.identKind);
			if (part == null) return null;
			parts.push(part);
		} else if (firstLitIdx > 1) {
			final pfxFrom: Null<Span> = operands[0].span;
			final pfxTo: Null<Span> = operands[firstLitIdx - 1].span;
			if (pfxFrom == null || pfxTo == null) return null;
			final pfx: String = source.substring(pfxFrom.from, pfxTo.to);
			if (!braceSafeExpr(pfx)) return null;
			parts.push(PExpr(pfx));
		}
		for (i in firstLitIdx ... operands.length) switch classes[i] {
			case StringLit(quote, raw):
				parts.push(PLit(escapeLiteral(quote, raw)));
			case NonStringOperand:
				final op: QueryNode = operands[i];
				final sarg: Null<QueryNode> = matchArg(op, seams.callKind, seams.fieldAccessKind, seams.identKind);
				final part: Null<Part> = identOrExprPart(sarg ?? op, source, seams.identKind);
				if (part == null) return null;
				parts.push(part);
			case InterpolatedStringLit:
				return null;
		}
		return parts;
	}

}

/** The resolved seams `PreferInterpolation` reads in both `run` and `fix`. */
private typedef Seams = {
	final callKind: String;
	final fieldAccessKind: String;
	final identKind: String;
	final stringFold: Null<StringFoldSupport>;
};
/** A rendered fragment of a folded `+`-concatenation: a literal, a `$name` identifier, or a `${expr}`. */
private enum Part {
	PLit(text: String);
	PIdent(name: String);
	PExpr(expr: String);
}
