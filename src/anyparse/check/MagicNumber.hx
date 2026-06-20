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
 * Flags a numeric literal used in executable code whose value is not a small
 * conventional one — a "magic number" the reader cannot interpret without
 * tracing intent. Enforces the project rule that such a literal be extracted
 * into a named constant. Report-only: a literal cannot be auto-named, so `fix`
 * produces no edits (like `complexity`).
 *
 * ## What is flagged
 *
 * A node whose kind is in `RefShape.numericLiteralKinds` (`IntLit` / `FloatLit`
 * / `HexLit` for Haxe), when ALL hold:
 *
 *  1. it is INSIDE a function unit (a `RefShape.functionKinds` ancestor) — i.e.
 *     "in logic". A literal outside any function — a member field initializer
 *     (`final MAX = 5000;`), an enum-abstract value (`A = 4;`), a typedef
 *     default, a metadata argument — is exempt by construction: it already
 *     names or annotates rather than hiding in a computation.
 *  2. it is NOT the direct initializer of a local binding (its parent kind is
 *     not in `RefShape.localDeclKinds`): `var x = 5000;` / `final x = 5000;`
 *     already give the literal a name, which is exactly the extraction the rule
 *     asks for. A literal nested in an initializer expression (`var x = 5000 *
 *     k`) is still in logic and is flagged. A literal that is the direct value of an object-literal field (`RefShape.objectFieldKind`, e.g. `{ value: 30 }`) is likewise declarative data and exempt; a computed field value keeps the literal under the operator and stays flagged.
 *  3. its numeric value is not in the exempt set `{0, 1, 2}` plus any number
 *     listed in the `magic-number` `ignore` option of a discovered
 *     `apqlint.json`. A negative literal parses as a negation wrapping a
 *     non-negative literal (`-1` is `Neg(IntLit 1)`), so the magnitude check on
 *     the bare literal exempts `-1` / `-2` and flags `-5000` with no
 *     special-casing.
 *
 * ## Grammar-agnostic
 *
 * Both kind-sets come from the plugin; a grammar that declares no
 * `numericLiteralKinds` (or no `functionKinds`) makes the check a no-op.
 */
@:nullSafety(Strict)
final class MagicNumber implements Check {

	/** Conventional values that carry no hidden meaning and are never flagged. */
	private static final EXEMPT: Array<Float> = [-1, 0, 1, 2];

	public function new() {}

	public function id(): String {
		return 'magic-number';
	}

	public function description(): String {
		return 'a magic numeric literal in logic that should be a named constant';
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final numericKinds: Array<String> = shape.numericLiteralKinds ?? [];
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		final localDeclKinds: Array<String> = shape.localDeclKinds ?? [];
		final objectFieldKind: String = shape.objectFieldKind ?? '';
		if (numericKinds.length == 0 || functionKinds.length == 0) return [];
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) {
				// Exempt base: a project checkstyle `MagicNumber.ignoreNumbers`, else the built-in default;
				// the apqlint `ignore` list adds to it.
				final base: Array<Float> = plugin.checkOverrides(entry.file)?.magicNumberIgnore ?? EXEMPT;
				final ignore: Array<Float> = LintConfig.discover(entry.file).numberListOption('magic-number', 'ignore') ?? [];
				final exempt: Array<Float> = base.concat(ignore);
				walk(violations, entry.file, tree, '', false, numericKinds, functionKinds, localDeclKinds, objectFieldKind, exempt);
			}
		}
		return violations;
	}

	/** No mechanical autofix — a literal cannot be auto-named. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * Walk `node`, tracking whether we are inside a function unit (`inFunction`,
	 * sticky once set) and the immediate `parentKind`. Flag a numeric literal in
	 * logic that is neither a named-binding initializer nor an exempt value.
	 */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, parentKind: String, inFunction: Bool, numericKinds: Array<String>,
		functionKinds: Array<String>, localDeclKinds: Array<String>, objectFieldKind: String, exempt: Array<Float>
	): Void {
		final here: Bool = inFunction || functionKinds.contains(node.kind);
		if (here && numericKinds.contains(node.kind) && !localDeclKinds.contains(parentKind) && parentKind != objectFieldKind)
			flag(out, file, node, exempt);
		for (child in node.children)
			walk(out, file, child, node.kind, here, numericKinds, functionKinds, localDeclKinds, objectFieldKind, exempt);
	}

	/** Append a `Warning` unless the literal's value is exempt or unparseable. */
	private static function flag(out: Array<Violation>, file: String, node: QueryNode, exempt: Array<Float>): Void {
		final span: Null<Span> = node.span;
		final text: Null<String> = node.name;
		if (span == null || text == null) return;
		final value: Null<Float> = literalValue(text);
		if (value == null || exempt.contains(value)) return;
		out.push({
			file: file,
			span: span,
			rule: 'magic-number',
			severity: Severity.Warning,
			message: 'magic number $text — extract into a named constant'
		});
	}

	/**
	 * The numeric value of a literal's source text, or null when it does not
	 * parse. Underscores are stripped (`100_000`); a `0x` prefix is read as hex;
	 * everything else (`3.14`, `1e5`, `.5`) parses as a float.
	 */
	private static function literalValue(text: String): Null<Float> {
		final clean: String = StringTools.replace(text, '_', '');
		if (StringTools.startsWith(clean, '0x') || StringTools.startsWith(clean, '0X')) {
			final i: Null<Int> = Std.parseInt(clean);
			return i ?? null;
		}
		final f: Float = Std.parseFloat(clean);
		return Math.isNaN(f) ? null : f;
	}

}
