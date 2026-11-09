package anyparse.check.haxe.literals;

import anyparse.check.Check.FixEdit;
import anyparse.check.common.literals.ConstantReadSlots.ChildSlot;
import anyparse.check.common.literals.ConstantReadSlots.ConstantReadSlots;
import anyparse.check.scan.NativeCodeScan;
import anyparse.check.scan.RunScan;
import anyparse.macro.CppLiteralGuard;
import anyparse.query.StringFold.StringFoldSupport;
import anyparse.query.StringFold.StringLiteral;
import anyparse.query.SymbolIndex;

using StringTools;

/**
 * Flags a plain string literal holding a C++ trigraph (`??` followed by one of `=/'()!<>-`) and rewrites it to a
 * concatenation cut between the two question marks, `'a??)'` -> `('a?' + '?)')`. `Warning`, because hxcpp copies a
 * Haxe string literal verbatim into a C++ literal and a C++ compiler in a pre-C++17 mode replaces the trigraph before it
 * lexes (`??)` becomes `]`): the same program holds other bytes on that target.
 *
 * ## Why a concatenation
 *
 * Haxe has no escape for the second `?` (`"\?"` is an invalid escape), and a `\x3F` spelling is decoded by the Haxe lexer
 * before gencpp sees the literal. gencpp never folds a `+` of two string literals, so each operand reaches the C++
 * compiler as its own literal and no trigraph forms across the cut; the bytes are equal on every target.
 * `fold-adjacent-string-literals` leaves a cut that would form a trigraph unmerged.
 *
 * ## Scope
 *
 * - A literal with an escape or an interpolation is not read: the grammar's `valueOf` names no text for it.
 * - A literal in an annotation argument, a reification or a target-code call (`__cpp__`, `Syntax.code`) is skipped: a
 *   macro or the target reads its text, and a concatenation there is read otherwise.
 * - A `case` pattern, a parameter default, an `inline` field's initialiser and an enum-abstract value are REPORTED without
 *   a fix: the compiler reads each as a constant, and a concatenation there is no constant (`ConstantReadSlots`).
 * - The fix wraps the concatenation in parentheses unless the literal already sits in a slot that binds no operator
 *   across it (a delimited slot, or an operand of `+`).
 *
 * ## Haxe only
 *
 * The rule is `LanguageBound` to Haxe: hxcpp compiles Haxe, and a string in another document is not that target's literal.
 * The trigraph vocabulary is `CppLiteralGuard`'s.
 */
@:nullSafety(Strict)
final class TrigraphInString extends HaxeRule {

	private static inline final RULE_ID: String = 'trigraph-in-string';

	public function new() {
		super(RULE_ID, 'a string literal holding a C++ trigraph, which hxcpp compiles to other bytes', RuleCategory.Literals);
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		return RunScan.collectWith(files, plugin, seamsOf(plugin), (entry, tree, seams, out) -> {
			scan(tree, entry.source, seams, site -> {
				final span: Null<Span> = site.node.span;
				if (span != null) out.push({
					file: entry.file,
					span: span,
					rule: RULE_ID,
					severity: Severity.Warning,
					message: 'this string literal holds a C++ trigraph, so hxcpp compiles other bytes'
					+ (site.fixable ? '' : ', and its position accepts no concatenation to cut it with')
				});
			});
		});
	}

	/** Rewrite each fixable literal to its concatenation cut between the question marks of every trigraph. */
	public function fix(source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex): Array<FixEdit> {

		return RunScan.editsWith(plugin, source, seamsOf(plugin), (tree, seams) -> {
			final siteBySpan: Map<String, Site> = [];
			scan(tree, source, seams, site -> {
				final span: Null<Span> = site.node.span;
				if (span != null && site.fixable) siteBySpan['${span.from}:${span.to}'] = site;
			});
			final edits: Array<FixEdit> = [];
			RunScan.eachMatched(violations, siteBySpan, (site, span) -> {
				final text: Null<String> = rewritten(site, seams);
				if (text == null) return;
				final cut: String = text;
				edits.push({ span: span, text: cut });
			});
			return edits;
		});
	}

	private static function seamsOf(plugin: GrammarPlugin): Null<Seams> {
		final shape: RefShape = plugin.refShape();
		final support: Null<StringFoldSupport> = plugin.stringFoldSupport();
		return support == null ? null : {
			support: support,
			shape: shape,
			literalKinds: shape.stringLiteralKinds ?? [],
			skipKinds: (shape.opaqueKinds ?? []).concat(plugin.metaShape().metaKinds),
			unfixableKinds: (shape.paramKinds ?? []).concat(shape.plainCasePatternKind == null ? [] : [shape.plainCasePatternKind]),
			modifierKinds: CheckScan.modifierKinds(shape),
			inlineKind: shape.inlineModifierKind,
			metaKinds: plugin.metaShape().metaKinds,
			enumAbstractMetaName: shape.enumAbstractMetaName,
			enumAbstractDeclKind: shape.enumAbstractDeclKind,
			conditionalKind: shape.conditionalMemberKind,
			functionKinds: shape.functionKinds ?? []
		};
	}

	/** Visits every literal holding a trigraph outside the skipped subtrees, in document order. */
	private static function scan(tree: QueryNode, source: String, seams: Seams, visit: (Site) -> Void): Void {
		walk(tree, null, 0, true, false, source, seams, visit);
	}

	private static function walk(
		node: QueryNode, parent: Null<QueryNode>, index: Int, fixable: Bool, constantMembers: Bool, source: String, seams: Seams,
		visit: (Site) -> Void
	): Void {
		if (seams.skipKinds.contains(node.kind) || NativeCodeScan.isCarrier(node, seams.shape, seams.support)) return;
		if (seams.literalKinds.contains(node.kind)) {
			final found: Null<StringLiteral> = seams.support.literalOf(node, source);
			if (found == null) return;
			final literal: StringLiteral = found;
			final value: String = seams.support.valueOf(literal) ?? '';
			if (CppLiteralGuard.hasTrigraph(value)) visit({
				node: node,
				parent: parent,
				index: index,
				literal: literal,
				fixable: fixable
			});
			return;
		}
		final inner: Bool = fixable && !seams.unfixableKinds.contains(node.kind);
		final slots: Array<ChildSlot> = ConstantReadSlots.of(node, constantMembers, seams);
		for (i => c in node.children) walk(c, node, i, inner && !slots[i].constant, slots[i].constantMembers, source, seams, visit);
	}

	/** The concatenation replacing `site`'s literal, or null when the position needs parentheses the grammar cannot spell. */
	private static function rewritten(site: Site, seams: Seams): Null<String> {
		final quote: String = site.literal.quote;
		final pieces: Array<String> = CppLiteralGuard.cutTrigraphs(site.literal.content);
		final joined: String = pieces.map(piece -> quote + piece + quote).join(' + ');
		if (bindsNothingAround(site, seams)) return joined;
		return seams.shape.parenKind == null ? null : '($joined)';
	}

	/** Whether the literal's slot binds no operator across it, so a bare concatenation reads as the literal did. */
	private static function bindsNothingAround(site: Site, seams: Seams): Bool {
		final parent: Null<QueryNode> = site.parent;
		return parent != null && (
			parent.kind == seams.support.concatKind()
			|| (seams.shape.delimitedAllChildKinds ?? []).contains(parent.kind)
			|| (site.index > 0 && (seams.shape.delimitedTailChildKinds ?? []).contains(parent.kind))
		);
	}

}

private typedef Seams = {

	final support: StringFoldSupport;
	final shape: RefShape;
	final literalKinds: Array<String>;

	/** Kinds whose subtree is never read: a macro or the target reads the text there. */
	final skipKinds: Array<String>;

	/** Kinds under which a literal is reported but cannot be rewritten into a concatenation. */
	final unfixableKinds: Array<String>;
	final modifierKinds: Array<String>;
	final inlineKind: Null<String>;
	final metaKinds: Array<String>;
	final enumAbstractMetaName: Null<String>;
	final enumAbstractDeclKind: Null<String>;
	final conditionalKind: Null<String>;
	final functionKinds: Array<String>;

};

private typedef Site = {
	final node: QueryNode;
	final parent: Null<QueryNode>;
	final index: Int;
	final literal: StringLiteral;
	final fixable: Bool;
};
