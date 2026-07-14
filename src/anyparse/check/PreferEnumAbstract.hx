package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Suggests grouping a set of related `static final` integer constants into an
 * `enum abstract` — the constants read as a closed enumeration but carry no
 * distinct type, so any `Int` flows where one is expected and the set is not
 * visible as one concept. An advisory that proposes a STRUCTURAL refactor rather
 * than flagging a defect; `Info`, report-only (the conversion picks an operator
 * flavour a mechanical edit cannot choose — see below).
 *
 * ## What is flagged
 *
 * A type in `RefShape.visibilityContainerKinds` (class / abstract) declaring THREE
 * OR MORE `static [inline] final <NAME> = <numericLiteral>` members sharing a
 * common name prefix — the segment before the first `_` (`RANK_ACCESSOR` /
 * `RANK_CONSTRUCTOR` → `RANK`). The shared prefix is the author's own signal that
 * the constants form one enumeration; requiring it keeps the check precise (an
 * unrelated `MAX` / `TIMEOUT` pair is not a set). One `Info` per prefix group,
 * anchored on its first constant.
 *
 * ## Not flagged
 *
 * An existing `enum abstract` (its values are not `fieldDeclKinds`, its decl kind
 * not a container kind); a mutable `static var` (`mutableFieldDeclKinds`); an
 * instance (non-`static`) `final` field; a non-numeric constant; fewer than three
 * sharing a prefix; a prefix-less name.
 *
 * ## Why report-only
 *
 * The right enum-abstract FLAVOUR depends on how the values are used, which the
 * check does not analyse: ordinal comparison (`<`) needs `@:op(A < B)`, bitwise
 * combination (bit-flags) needs `from Int to Int`, pure `==` / `switch` needs
 * neither. A blind rewrite would pick the wrong one, so the fix is the author's;
 * `fix` yields no edits.
 *
 * ## Grammar-agnostic
 *
 * Container / field / modifier / literal kinds all come from the plugin; a grammar
 * declaring none makes the check a no-op.
 */
@:nullSafety(Strict)
final class PreferEnumAbstract implements Check {

	/** The minimum same-prefix constant group worth an enum-abstract suggestion — a pair is not yet a set. */
	private static inline final MIN_GROUP: Int = 3;

	public function new() {}

	public function id(): String {
		return 'prefer-enum-abstract';
	}

	public function description(): String {
		return 'related static-final int constants that read as a closed enumeration';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final containerKinds: Array<String> = shape.visibilityContainerKinds ?? [];
		final mutableKinds: Array<String> = shape.mutableFieldDeclKinds ?? [];
		final fieldKinds: Array<String> = shape.fieldDeclKinds ?? [];
		final constKinds: Array<String> = [for (k in fieldKinds) if (!mutableKinds.contains(k)) k];
		final staticKind: Null<String> = shape.staticModifierKind;
		final numericKinds: Array<String> = shape.numericLiteralKinds ?? [];
		if (staticKind == null || containerKinds.length == 0 || constKinds.length == 0 || numericKinds.length == 0) return [];
		final staticKindValue: String = staticKind;
		final cfg: EnumAbstractCfg = {
			constKinds: constKinds,
			staticKind: staticKindValue,
			modifierKinds: shape.modifierOrderKinds ?? [],
			numericKinds: numericKinds,
			negationKind: shape.negationKind ?? ''
		};
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) walk(violations, entry.file, tree, containerKinds, cfg);
		}
		return violations;
	}

	/** No mechanical autofix — the enum-abstract flavour depends on usage the check does not analyse. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/** Walk `node`; at every container type flag its `MIN_GROUP`+ same-prefix constant groups. */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, containerKinds: Array<String>, cfg: EnumAbstractCfg
	): Void {
		if (containerKinds.contains(node.kind)) flagGroups(out, file, node, cfg);
		for (child in node.children) walk(out, file, child, containerKinds, cfg);
	}

	/** Collect `container`'s static-final numeric constants, group by name prefix, flag each group of `MIN_GROUP`+. */
	private static function flagGroups(out: Array<Violation>, file: String, container: QueryNode, cfg: EnumAbstractCfg): Void {
		final byPrefix: Map<String, Array<ConstDecl>> = [];
		for (decl in collectConsts(container, cfg)) {
			final existing: Null<Array<ConstDecl>> = byPrefix[decl.prefix];
			if (existing == null)
				byPrefix[decl.prefix] = [decl];
			else
				existing.push(decl);
		}
		for (prefix => group in byPrefix) if (group.length >= MIN_GROUP) out.push({
			file: file,
			span: group[0].span,
			rule: 'prefer-enum-abstract',
			severity: Severity.Info,
			message: '${group.length} \'${prefix}_*\' static-final constants read as a closed enumeration — consider an enum abstract for a distinct type'
		});
	}

	/**
	 * The prefixed static-final numeric constants declared directly by `container`.
	 * A constant is a `constKinds` (final) member preceded by a `Static` modifier,
	 * whose value is a numeric literal and whose name carries a `_`-delimited prefix.
	 */
	private static function collectConsts(container: QueryNode, cfg: EnumAbstractCfg): Array<ConstDecl> {
		final out: Array<ConstDecl> = [];
		final kids: Array<QueryNode> = container.children;
		for (i in 0...kids.length) {
			final node: QueryNode = kids[i];
			if (!cfg.constKinds.contains(node.kind) || !precededByStatic(kids, i, cfg) || !hasNumericValue(node, cfg)) continue;
			final name: Null<String> = node.name;
			final span: Null<Span> = node.span;
			final prefix: Null<String> = name != null ? prefixOf(name) : null;
			if (prefix != null && span != null) {
				final prefixValue: String = prefix;
				final spanValue: Span = span;
				out.push({ prefix: prefixValue, span: spanValue });
			}
		}
		return out;
	}

	/** Whether the member at `kids[i]` carries a `Static` modifier — scanning back over its preceding modifier siblings. */
	private static function precededByStatic(kids: Array<QueryNode>, i: Int, cfg: EnumAbstractCfg): Bool {
		var j: Int = i - 1;
		while (j >= 0) {
			final kind: String = kids[j].kind;
			if (kind == cfg.staticKind) return true;
			if (!cfg.modifierKinds.contains(kind)) break;
			j--;
		}
		return false;
	}

	/** Whether `node`'s value — its first child — is a numeric literal. */
	private static function hasNumericValue(node: QueryNode, cfg: EnumAbstractCfg): Bool {
		if (node.children.length == 0) return false;
		final value: QueryNode = node.children[0];
		final literal: QueryNode = cfg.negationKind != '' && value.kind == cfg.negationKind && value.children.length > 0
			? value.children[0]
			: value;
		return cfg.numericKinds.contains(literal.kind);
	}

	/** The `_`-delimited prefix of `name` (`RANK_ACCESSOR` → `RANK`), or null when the name has no prefix. */
	private static function prefixOf(name: String): Null<String> {
		final idx: Int = name.indexOf('_');
		return idx > 0 ? name.substring(0, idx) : null;
	}

}

private typedef ConstDecl = {
	final prefix: String;
	final span: Span;
};

private typedef EnumAbstractCfg = {
	final constKinds: Array<String>;
	final staticKind: String;
	final modifierKinds: Array<String>;
	final numericKinds: Array<String>;
	final negationKind: String;
};
