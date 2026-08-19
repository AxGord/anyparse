package anyparse.check;

import anyparse.check.Check.DefaultOff;
import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.QueryNode;
import anyparse.query.RefactorSupport;
import anyparse.query.SymbolIndex;
import anyparse.runtime.Span;

/**
 * Flags a redundant trailing comma - the `,` between the LAST element of a
 * comma-separated list and its closing delimiter (`[1, 2,]`, `{x: 1, y: 2,}`,
 * `new D(1, 2,)`, `function f(a:Int, b:Int,)`). The comma parses and means nothing
 * there, so removing it preserves both the parse and the semantics.
 *
 * A grammar may also have a list whose separator is MANDATORY after the last
 * element - the Haxe anon-type extension entry, where `{> Base,}` compiles and
 * `{> Base}` is `Expected ,`. That comma is neither a separator nor redundant and
 * deleting it is a compile error, so the shape is declared out by
 * `RefShape.mandatoryTrailingCommaChildKinds`. The distinction is per LAST ELEMENT,
 * not per host: `{> Base, x:Int,}` ends in an ordinary field and its comma IS
 * redundant.
 *
 * Like the absorbed `;` of `empty-statement`, the comma is invisible to a tree
 * walk - the parser folds it into the span of the HOST itself, past the last child,
 * so no node marks it and detection is span arithmetic. It is invisible to the
 * writer too for the literal hosts (`fmt` re-emits `[1, 2,]` verbatim, so the file
 * counts as canonical), which is why this is a lint rule with an autofix rather
 * than a writer change: canonicalising the comma away in the writer would silently
 * rewrite every file that has one. For the hosts whose trivia the writer does NOT
 * preserve (`Call`, `MetaCall`, an enum constructor parameter list) a finding can
 * only appear in a file that is not yet canonical, where `lint --fix` is refused by
 * the canonical gate and `fmt --write` is the remedy.
 *
 * `Info`; `fix` deletes the comma - the whole physical line when it sits alone on
 * one (so no blank residue is left), otherwise only the comma itself. A comment
 * between the comma and the closer is trivia and survives.
 *
 * ## Grammar-agnostic
 *
 * Two arms, both declared by the plugin. `RefShape.trailingCommaHostKinds` names
 * the hosts whose span ENDS with the closing delimiter of the list, so the comma
 * sits between the last child and the last byte of the host itself.
 * `RefShape.paramKinds` reaches the parameter lists, whose host runs on past the
 * `)` (a return type, a body): the last parameter child is the last element of the
 * list and the `)` that follows it is the closer.
 * `RefShape.mandatoryTrailingCommaChildKinds` vetoes either arm by the KIND of that
 * last element. With no arm set the check is a no-op.
 *
 * ## Default OFF - opt-in
 *
 * A `DefaultOff` marker: dropped from the default set and from a bare `lint ... --all`
 * report unless a project opts in via `apqlint.json`
 * (`"rules": { "redundant-trailing-comma": { "enabled": true } }`), or an explicit
 * `--rule redundant-trailing-comma` selects it. Whether a list ends on a comma is a
 * project style decision, not a defect - the same call `shorten-type-ref` makes about
 * how qualified a type reference should be. anyparse's own house style KEEPS the
 * trailing comma (1041 would-be findings across `src` + `test`), and a rule whose
 * default verdict contradicts its own repository is one that trains readers to ignore
 * the report.
 */
@:nullSafety(Strict)
final class RedundantTrailingComma implements Check implements DefaultOff {

	public function new() {}

	public function id(): String {
		return 'redundant-trailing-comma';
	}

	public function description(): String {
		return 'a redundant trailing comma before a list\'s closing delimiter';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final kinds: ListKinds = {
			hosts: shape.trailingCommaHostKinds ?? [],
			params: shape.paramKinds ?? [],
			mandatory: shape.mandatoryTrailingCommaChildKinds ?? []
		};
		if (kinds.hosts.length == 0 && kinds.params.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> = CheckScan.parseOrNull(plugin, entry.source);
			if (tree != null) walk(violations, entry.file, entry.source, tree, kinds);
		}
		return violations;
	}

	/** Delete each flagged comma. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		final edits: Array<{ span: Span, text: String }> = [];
		for (v in violations) {
			final span: Null<Span> = v.span;
			if (span != null) edits.push({ span: RefactorSupport.lineExtendedSpan(source, span), text: '' });
		}
		return edits;
	}

	private static inline function isCloser(c: String): Bool {
		return c == ']' || c == '}' || c == ')';
	}

	private static inline function oneChar(at: Int): Span {
		return new Span(at, at + 1);
	}

	/** Walk `node`, flagging every trailing comma reached. */
	private static function walk(out: Array<Violation>, file: String, source: String, node: QueryNode, kinds: ListKinds): Void {
		final comma: Null<Span> = trailingComma(source, node, kinds);
		if (comma != null) out.push({
			file: file,
			span: comma,
			rule: 'redundant-trailing-comma',
			severity: Severity.Info,
			message: 'redundant trailing comma'
		});
		for (c in node.children) walk(out, file, source, c, kinds);
	}

	/**
	 * The span of the redundant trailing `,` of the list `node` hosts, or null when it
	 * hosts no list, the list is empty, its last element is not followed by one, or
	 * that separator is MANDATORY after the element it terminates.
	 *
	 * The two arms differ only in where the closer is. A `trailingCommaHostKinds` host
	 * OWNS its closer as its own last byte; a parameter list has no node ending there,
	 * so its arm asks the source for the `)` instead - after the last parameter of a
	 * list, a `,` can only be trailing. Both then repeat the same fail-closed
	 * assertion, that the comma is the last significant thing before that closer. In
	 * this grammar the assertion is inert (a separator always has an element after it,
	 * and every element is a child, so `lastListChild` already picked the last one); it
	 * is kept for a grammar where a NON-element child may end after the list.
	 */
	private static function trailingComma(source: String, node: QueryNode, kinds: ListKinds): Null<Span> {
		final span: Null<Span> = node.span;
		if (span == null) return null;
		final host: Bool = kinds.hosts.contains(node.kind);
		final last: Null<QueryNode> = lastListChild(node, host ? null : kinds.params);
		if (last == null || kinds.mandatory.contains(last.kind)) return null;
		final lastSpan: Null<Span> = last.span;
		if (lastSpan == null) return null;
		final found: Null<{ comma: Int, next: Int }> = commaThenToken(source, lastSpan.to, span.to);
		if (found == null) return null;
		final closes: Bool = host ? found.next == span.to - 1 && isCloser(source.charAt(found.next)) : source.charAt(found.next) == ')';
		return closes ? oneChar(found.comma) : null;
	}

	/**
	 * The first significant byte at or after `from` when it is a `,`, paired with the
	 * first significant byte after that comma; null when either falls outside `limit`
	 * or the gap holds anything but whitespace and comments.
	 */
	private static function commaThenToken(source: String, from: Int, limit: Int): Null<{ comma: Int, next: Int }> {
		final comma: Int = RefactorSupport.skipForwardTrivia(source, from);
		if (comma >= limit || source.charAt(comma) != ',') return null;
		final next: Int = RefactorSupport.skipForwardTrivia(source, comma + 1);
		return next >= limit ? null : { comma: comma, next: next };
	}

	/**
	 * The child of `node` that ENDS last, restricted to `kinds` when given - the last
	 * element of the list, whose kind decides whether the comma after it is redundant
	 * or mandatory. By end position rather than by document order so a grammar that
	 * emits a child out of source order cannot mis-place it.
	 */
	private static function lastListChild(node: QueryNode, kinds: Null<Array<String>>): Null<QueryNode> {
		var out: Null<QueryNode> = null;
		var end: Int = -1;
		for (child in node.children) {
			final span: Null<Span> = child.span;
			if (span == null || (kinds != null && !kinds.contains(child.kind))) continue;
			if (span.to <= end) continue;
			out = child;
			end = span.to;
		}
		return out;
	}

}

/** The kind sets `RedundantTrailingComma` reads off the plugin, resolved once per run. */
private typedef ListKinds = {
	final hosts: Array<String>;
	final params: Array<String>;
	final mandatory: Array<String>;
};
