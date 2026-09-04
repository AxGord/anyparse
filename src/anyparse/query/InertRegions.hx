package anyparse.query;

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

	/** The INTERPOLATING string kind (Haxe single quotes) — masked segment by segment, never whole. */
	private static inline final INTERP_STRING_KIND: String = 'SingleStringExpr';

	/**
	 * Literal kinds whose WHOLE span is inert text — a double-quoted string (Haxe never
	 * interpolates one) and a regex literal, whose body is pattern syntax, not Haxe. Neither can
	 * bind or read a name, so both are masked entire.
	 */
	private static final WHOLE_LITERAL_KINDS: Array<String> = ['DoubleStringExpr', 'RegexLit'];

	/**
	 * The segments of an interpolating literal that carry TEXT: a plain fragment, the escaped
	 * dollar `$$` and a lone trailing `$`. Its OTHER segments — the `$name` shorthand (`Ident`)
	 * and the `${ … }` hole (`Block`) — are real references and are deliberately absent.
	 *
	 * The two dollar forms are listed to keep the split of the segment kinds exhaustive, not to
	 * change an answer: their spans hold `$` characters only, which no identifier match can start
	 * inside, so no fixture can discriminate them. Their bytes are NOT covered by a neighbouring
	 * `Literal` — the split cuts a fragment at every trigger — so dropping them would leave the
	 * enumeration reading as if a `$$` were code.
	 */
	private static final TEXT_SEGMENT_KINDS: Array<String> = ['Literal', 'Dollar', 'LoneDollar'];

	/**
	 * Every inert region of one source: the comment spans among its scanned `regions` first, then the
	 * literal-text spans of `root`, its parsed top level, in tree order. A null `root` (a caller with
	 * no parsed file) yields the comment half alone, which is the conservative reading: an unmasked
	 * literal only ever costs a refusal.
	 *
	 * The regions come from the caller because the scan is the GRAMMAR's
	 * (`GrammarPlugin.lexicalRegions`) — this class is grammar-agnostic and never picks a lexer.
	 */
	public static function of(root: Null<QueryNode>, regions: Array<LexRegion>): Array<Span> {
		final out: Array<Span> = SourceComments.collectCommentRegions(regions);
		if (root != null) collectLiterals(root, out);
		return out;
	}

	/**
	 * Append to `out` every span of `node`'s subtree that is inert LITERAL text.
	 *
	 * A double-quoted string and a regex literal go in whole (`WHOLE_LITERAL_KINDS`). An
	 * interpolating literal goes in segment by segment: its text fragments are inert, its `$name`
	 * and `${ … }` segments are references and are LEFT OUT, so a name read through one still
	 * vetoes. The reference segments are recursed into rather than skipped, which is what masks a
	 * nested literal — the `"Bar"` of `'a ${ "Bar" } b'` is text like any other.
	 *
	 * A `${ … }` the ESCAPE rescan discovered carries no child expression (see
	 * `HxInterpProjection`), so nothing inside it is masked and every name it spells keeps its
	 * veto — the fail-closed direction for a hole anyparse cannot read.
	 */
	private static function collectLiterals(node: QueryNode, out: Array<Span>): Void {
		final span: Null<Span> = node.span;
		if (span != null && WHOLE_LITERAL_KINDS.contains(node.kind)) {
			out.push(span);
			return;
		}
		final interpolating: Bool = node.kind == INTERP_STRING_KIND;
		for (child in node.children) {
			final childSpan: Null<Span> = child.span;
			if (interpolating && childSpan != null && TEXT_SEGMENT_KINDS.contains(child.kind))
				out.push(childSpan);
			else
				collectLiterals(child, out);
		}
	}

}
