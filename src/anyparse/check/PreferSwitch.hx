package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Flags an `if` / `else if` chain that tests one expression against literal
 * values — `if (x == 'a') … else if (x == 'b') …` — which reads more clearly as
 * a `switch`. Purely structural (no type information), so it holds without a
 * type-checker; `Info` — the code is correct, this is a readability suggestion.
 * Report-only (`fix` yields no edits): converting a chain to a `switch` is a
 * control-flow rewrite left to a follow-up.
 *
 * ## What is flagged
 *
 * The HEAD of a chain of `ifStatementKinds` whose `else` (`children[2]`) is
 * itself an `if`, where EVERY rung's condition is an equality (`eqKind`)
 * comparing the SAME discriminant against a literal. A rung qualifies when
 * exactly one operand is a constant literal — a non-string literal kind
 * (`caseLiteralKinds`) or a plain, interpolation-free string
 * (`stringFoldSupport().literalOf`, so an interpolated `'$x'` is rejected) — and
 * the other (the discriminant) is identical across all rungs
 * (`RefactorSupport.sameSource`) and call-free: a `callKind` in the discriminant
 * means a `switch` would evaluate it once where the chain evaluates it per rung,
 * a behaviour change, so it is left alone. At least two rungs are required (a
 * lone `if`, or a single `if` / `else`, is not a chain). An inner else-if rung is
 * never re-reported: the walk skips an `if` reached as another `if`'s else-slot.
 *
 * ## Grammar-agnostic
 *
 * Drives off `RefShape`: `ifStatementKinds` (unset → no-op), `eqKind` (the `==`
 * kind — a `!=` chain does not map to `case` patterns), `caseLiteralKinds` (the
 * non-string literal kinds; unset → no-op), and the always-present `callKind`,
 * plus `GrammarPlugin.stringFoldSupport` for interpolation-free string literals.
 * No language-specific kinds are named here.
 */
@:nullSafety(Strict)
final class PreferSwitch implements Check {

	public function new() {}

	public function id(): String {
		return 'prefer-switch';
	}

	public function description(): String {
		return 'an if/else-if chain testing one expression against literals — clearer as a switch';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final ifKinds: Array<String> = shape.ifStatementKinds ?? [];
		final eqKind: Null<String> = shape.eqKind;
		final litKinds: Array<String> = shape.caseLiteralKinds ?? [];
		if (ifKinds.length == 0 || eqKind == null || litKinds.length == 0) return [];
		final callKind: Null<String> = shape.callKind;
		final stringFold: Null<StringFoldSupport> = plugin.stringFoldSupport();
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, entry.source, tree, false, ifKinds, eqKind, litKinds, callKind, stringFold);
		}
		return violations;
	}

	/** Prefer-switch has no autofix — converting a chain to a switch is a follow-up. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Walk `node`, flagging each chain head. `inElseSlot` is true when `node` is
	 * reached as another `if`'s `else` branch (`children[2]`), so an else-if rung is
	 * not re-evaluated as its own head.
	 */
	private static function walk(
		out: Array<Violation>, file: String, source: String, node: QueryNode, inElseSlot: Bool, ifKinds: Array<String>, eqKind: String,
		litKinds: Array<String>, callKind: Null<String>, stringFold: Null<StringFoldSupport>
	): Void {
		if (ifKinds.contains(node.kind) && !inElseSlot) flagChain(out, file, source, node, ifKinds, eqKind, litKinds, callKind, stringFold);
		final elseSlot: Int = ifKinds.contains(node.kind) ? 2 : -1;
		for (i in 0...node.children.length)
			walk(out, file, source, node.children[i], i == elseSlot, ifKinds, eqKind, litKinds, callKind, stringFold);
	}

	/**
	 * Emit one `Info` on `head` when it heads a chain of at least two equality rungs
	 * all testing the same call-free discriminant against literals.
	 */
	private static function flagChain(
		out: Array<Violation>, file: String, source: String, head: QueryNode, ifKinds: Array<String>, eqKind: String,
		litKinds: Array<String>, callKind: Null<String>, stringFold: Null<StringFoldSupport>
	): Void {
		var discriminant: Null<QueryNode> = null;
		var rungs: Int = 0;
		var cur: QueryNode = head;
		while (ifKinds.contains(cur.kind) && cur.children.length >= 2) {
			final d: Null<QueryNode> = eqDiscriminant(cur.children[0], eqKind, litKinds, stringFold, source);
			if (d == null) return;
			if (callKind != null && RefactorSupport.subtreeContainsKind(d, callKind)) return;
			if (discriminant == null)
				discriminant = d;
			else if (!RefactorSupport.sameSource(discriminant, d, source)) return;
			rungs++;
			if (cur.children.length >= 3 && ifKinds.contains(cur.children[2].kind))
				cur = cur.children[2];
			else
				break;
		}
		final disc: Null<QueryNode> = discriminant;
		if (rungs < 2 || disc == null) return;
		final span: Null<Span> = head.span;
		final dSpan: Null<Span> = disc.span;
		if (span == null || dSpan == null) return;
		final discText: String = StringTools.trim(source.substring(dSpan.from, dSpan.to));
		out.push({
			file: file,
			span: span,
			rule: 'prefer-switch',
			severity: Severity.Info,
			message: 'if/else-if chain testing `$discText` against literals — clearer as a switch'
		});
	}

	/**
	 * The discriminant operand of an equality condition `D == lit` (either order):
	 * the non-literal operand when exactly one operand is a constant literal, else
	 * null.
	 */
	private static function eqDiscriminant(
		cond: QueryNode, eqKind: String, litKinds: Array<String>, stringFold: Null<StringFoldSupport>, source: String
	): Null<QueryNode> {
		if (cond.kind != eqKind || cond.children.length != 2) return null;
		final a: QueryNode = cond.children[0];
		final b: QueryNode = cond.children[1];
		final aLit: Bool = isConstLiteral(a, litKinds, stringFold, source);
		final bLit: Bool = isConstLiteral(b, litKinds, stringFold, source);
		if (aLit == bLit) return null;
		return aLit ? b : a;
	}

	/**
	 * Whether `node` is a constant literal usable verbatim as a switch `case`: a
	 * plain interpolation-free string (via `stringFoldSupport`, which yields null
	 * for an interpolated `'$x'`) or one of the non-string literal kinds.
	 */
	private static function isConstLiteral(
		node: QueryNode, litKinds: Array<String>, stringFold: Null<StringFoldSupport>, source: String
	): Bool {
		if (stringFold != null && stringFold.literalOf(node, source) != null) return true;
		return litKinds.contains(node.kind);
	}

}
