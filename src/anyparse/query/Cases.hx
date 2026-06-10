package anyparse.query;

import anyparse.runtime.Span;
import anyparse.runtime.Span.Position;

/**
 * `apq cases <Ctor> <file-or-dir>...` — match all switch case-patterns
 * whose top-level constructor is `<Ctor>`. THE precise answer to
 * "where is `case Foo(_):` written" — `apq search 'case Foo(_)'`
 * fails because case-patterns are not parseable as top-level
 * declarations/statements/expressions, and `apq mentions` over-matches
 * (imports, NewExpr, IdentExpr in non-pattern positions).
 *
 * Walks the QueryNode tree for `CaseBranch` nodes (Haxe plugin only —
 * other languages would need a different node kind). For each
 * CaseBranch, inspects every child except the last (the body stmt) as
 * a pattern slot; emits a hit when a pattern's top-level is
 * `IdentExpr` with the target name, `Call` whose first sub-child is
 * `IdentExpr <target>`, or a recursive `BitOr` (`|`-alternation) of
 * the same shapes.
 */
@:nullSafety(Strict)
final class Cases {

	public static function find(target: String, tree: QueryNode): Array<CasesHit> {
		final out: Array<CasesHit> = [];
		walk(target, tree, out);
		return out;
	}

	private static function walk(target: String, node: QueryNode, out: Array<CasesHit>): Void {
		if (node.kind == 'CaseBranch') {
			final kids: Array<QueryNode> = node.children;
			// Patterns are all children except the LAST (which is the body
			// statement). Multi-pattern `case A, B:` parses as
			// `CaseBranch(A, B, body)`; alternation `case A | B:` parses
			// as `CaseBranch(BitOr(A, B), body)` — both shapes covered
			// by `matchPattern` recursion.
			final patternCount: Int = kids.length > 0 ? kids.length - 1 : 0;
			for (i in 0...patternCount) {
				final pat: QueryNode = kids[i];
				if (matchPattern(target, pat)) {
					out.push(new CasesHit(node, (pat.span: Null<Span>), pat.kind));
					break;
				}
			}
		}
		for (c in node.children) walk(target, c, out);
	}

	private static function matchPattern(target: String, pat: QueryNode): Bool {
		return switch pat.kind {
			case 'IdentExpr':
				pat.name == target;
			case 'Call':
				final kids: Array<QueryNode> = pat.children;
				kids.length > 0 && kids[0].kind == 'IdentExpr' && kids[0].name == target;
			case 'BitOr':
				final kids: Array<QueryNode> = pat.children;
				kids.length >= 2 && (matchPattern(target, kids[0]) || matchPattern(target, kids[1]));
			case 'Plain':
				// Slice 34: every `case <expr>:` (other than `case var X:`) is
				// wrapped in `HxCasePatternBody.Plain(expr:HxExpr)` — the inner
				// `IdentExpr`/`Call`/`BitOr` we care about lives one child
				// deeper. Without this arm, `cases <Ctor>` returned 0 hits on
				// every post-Slice-34 Haxe source (the killer-use-case for
				// "added a new enum ctor → audit all exhaustive switches").
				final kids: Array<QueryNode> = pat.children;
				kids.length > 0 && matchPattern(target, kids[0]);
			case 'Capture':
				// Slice 34: `case var X:` — `HxCasePatternBody.Capture(name)`
				// carries an `HxVarNameLit` child, never matches an enum ctor.
				// Explicit `false` documents the design (vs falling through
				// the default arm and looking like an oversight).
				false;
			case _:
				false;
		};
	}

	public static function render(file: String, source: String, hits: Array<CasesHit>, flat: Bool = false): String {
		final buf: StringBuf = new StringBuf();
		if (!flat && hits.length > 0) buf.add('$file:\n');
		for (h in hits) {
			final span: Null<Span> = h.span;
			if (span == null) continue;
			final pos: Position = span.lineCol(source);
			if (flat)
				buf.add('$file:${pos.line}:${pos.col}: ${h.patternKind}\n');
			else
				buf.add('  ${pos.line}:${pos.col}: ${h.patternKind}\n');
		}
		return buf.toString();
	}

}

@:nullSafety(Strict)
final class CasesHit {

	public final caseBranch: QueryNode;
	public final span: Null<Span>;
	public final patternKind: String;

	public function new(caseBranch: QueryNode, span: Null<Span>, patternKind: String) {
		this.caseBranch = caseBranch;
		this.span = span;
		this.patternKind = patternKind;
	}

}
