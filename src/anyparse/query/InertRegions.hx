package anyparse.query;

import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.LexicalRegions.LexRegion;
import anyparse.runtime.Span;

/**
 * The bytes of a file that can neither BIND nor READ a name: its comments, and the literal TEXT
 * of its string and regex literals. The mask a name-FREENESS scan
 * (`RefactorSupport.referencedInRange`) is handed as its `excluded` list — built for
 * `TypeRefPrinter.canAddImport`, which without it refuses an import on the strength of a word in
 * a doc-comment or an assertion message.
 *
 * NOT for the `unused-*` / rename consumers of that same scan — not WHOLE, at least. Masking makes
 * the scan report FEWER references, and there a missed reference DELETES or REBINDS a binding, so
 * the raw over-counting scan is what protects them. That reasoning holds for the LITERAL half
 * only: `Type.resolveClass('Foo')` reaches a type through a string, and nothing else sees it. It
 * does not hold for the comment half, and `unused-import` masks comments on its own since
 * 2026-08-27 (see its class doc for the measurement). That split is why this stays a caller-owned
 * mask rather than a change to `referencedInRange`: each consumer decides which of the two inert
 * sources it can afford to ignore.
 *
 * Two sources because the two questions have two exact answers. Comments are TRIVIA — no node
 * carries them — so they come off the lexer (`RefactorSupport.collectCommentRegions`). Literals
 * ARE nodes, and the tree is the only model that knows which of a literal's bytes are text and
 * which are code: `'\x24name'` spells a plain fragment in raw bytes and a real `Ident` read to
 * the compiler, and only the projection (`HxInterpProjection`) says which. Nothing is memoised —
 * a per-file caller should hoist the result.
 *
 * So this is NOT a third Haxe lexer, and reading it as one is the mistake to avoid: the comment
 * half is the SEAM's own answer reached through `RefactorSupport`, and the literal half is the
 * parse. `unit.LexicalRegionAgreementTest` pins both halves against the scanner — every comment
 * span this returns is exactly a scanner comment region, and every literal span lies INSIDE a
 * scanner literal region, never straddling one — so the two can no longer drift apart in silence.
 */
@:nullSafety(Strict)
final class InertRegions {

	/**
	 * Every inert region of one source: the comment spans among its scanned `regions` first, then the
	 * literal-text spans of `root`, its parsed top level, in tree order. A null `root` (a caller with
	 * no parsed file) yields the comment half alone, which is the conservative reading: an unmasked
	 * literal only ever costs a refusal. A null `shape` yields the same half for the same reason.
	 *
	 * Both the regions and the shape come from the caller because both are the GRAMMAR's
	 * (`GrammarPlugin.lexicalRegions` / `GrammarPlugin.refShape`) — this class is grammar-agnostic,
	 * never picks a lexer and, since S188, no longer spells a ctor name of one grammar either. The
	 * three vocabularies it used to hardcode are `interpolatingStringKinds`,
	 * `inertTextLiteralKinds` and `stringInterpTextKind` + `stringInterpInertSegmentKinds`.
	 */
	public static function of(root: Null<QueryNode>, regions: Array<LexRegion>, shape: Null<RefShape>): Array<Span> {
		final out: Array<Span> = SourceComments.collectCommentRegions(regions);
		if (root != null && shape != null) collectLiterals(root, shape, textSegmentKinds(shape), out);
		return out;
	}

	/**
	 * The segment kinds of an interpolating literal that carry TEXT: the plain fragment
	 * (`stringInterpTextKind`) and the inert interpolation triggers
	 * (`stringInterpInertSegmentKinds` — Haxe's `$$` and a lone `$`). Its OTHER segments, the
	 * `$name` shorthand and the `${ … }` hole, are real references and are deliberately absent.
	 *
	 * Built once per `of` rather than per node: the shape rebuilds its struct on every read, and
	 * this walk asks the question at every child of every interpolating literal in the file.
	 */
	private static function textSegmentKinds(shape: RefShape): Array<String> {
		final text: Null<String> = shape.stringInterpTextKind;
		final out: Array<String> = text == null ? [] : [text];
		for (kind in shape.stringInterpInertSegmentKinds ?? []) out.push(kind);
		return out;
	}

	/**
	 * Append to `out` every span of `node`'s subtree that is inert LITERAL text.
	 *
	 * An `inertTextLiteralKinds` literal goes in whole. An `interpolatingStringKinds` one goes in
	 * segment by segment: its text fragments (`textSegments`) are inert, its `$name` and
	 * `${ … }` segments are references and are LEFT OUT, so a name read through one still vetoes.
	 * The reference segments are recursed into rather than skipped, which is what masks a nested
	 * literal — the `"Bar"` of `'a ${ "Bar" } b'` is text like any other.
	 *
	 * A `${ … }` the ESCAPE rescan discovered carries no child expression (see
	 * `HxInterpProjection`), so nothing inside it is masked and every name it spells keeps its
	 * veto — the fail-closed direction for a hole anyparse cannot read.
	 */
	private static function collectLiterals(node: QueryNode, shape: RefShape, textSegments: Array<String>, out: Array<Span>): Void {
		final span: Null<Span> = node.span;
		if (span != null && (shape.inertTextLiteralKinds ?? []).contains(node.kind)) {
			out.push(span);
			return;
		}
		final interpolating: Bool = (shape.interpolatingStringKinds ?? []).contains(node.kind);
		for (child in node.children) {
			final childSpan: Null<Span> = child.span;
			if (interpolating && childSpan != null && textSegments.contains(child.kind))
				out.push(childSpan);
			else
				collectLiterals(child, shape, textSegments, out);
		}
	}

}
