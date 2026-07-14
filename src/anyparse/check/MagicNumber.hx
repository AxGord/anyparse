package anyparse.check;

import anyparse.check.Check.Violation;
import anyparse.query.GrammarPlugin;
import anyparse.query.GrammarPlugin.RefShape;
import anyparse.query.QueryNode;
import anyparse.query.SymbolIndex;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;
import anyparse.check.Check.ConfigAware;

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
 *     k`) is still in logic and is flagged. A literal that is the direct value of an object-literal field (`RefShape.objectFieldKind`, e.g. `{ value: 30 }`) is likewise declarative data and exempt; a computed field value keeps the literal under the operator and stays flagged. A literal in the index slot of a subscript (`RefShape.indexAccessKind`, e.g. `args[3]`) is a position, not a hidden quantity, and a literal compared against a size-like field access (`RefShape.sizeFieldNames`, e.g. `args.length == 3`) is a structural arity check — both exempt; a computed index (`args[i + 3]`) or a comparison against a plain value (`score == 100`) stays flagged. A literal reaching a string-position method argument (`positionMethodNames`, e.g. `s.charCodeAt(i + 5)` / `s.substr(0, 4)`), directly or through `+` / `-` offset arithmetic (`additiveKinds`), is a position, and a literal offset from a size field (`s.length - 3`) is a count offset — both exempt, while a bare offset with no size sibling (`from + 3`) stays flagged.
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
final class MagicNumber implements Check implements ConfigAware {

	/** Conventional values that carry no hidden meaning and are never flagged. */
	private static final EXEMPT: Array<Float> = [-1, 0, 1, 2];

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

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
		if (numericKinds.length == 0 || functionKinds.length == 0) return [];
		final cfg: MagicNumberCfg = buildCfg(shape, numericKinds, functionKinds);
		final violations: Array<Violation> = [];
		for (entry in files) {
			final tree: Null<QueryNode> =
				try plugin.parseFile(entry.source) catch (exception: ParseError) null catch (exception: Exception) null;
			if (tree != null) {
				// Exempt base: a project checkstyle `MagicNumber.ignoreNumbers`, else the built-in default;
				// the apqlint `ignore` list adds to it.
				final base: Array<Float> = plugin.checkOverrides(entry.file)?.magicNumberIgnore ?? EXEMPT;
				final ignore: Array<Float> = LintConfig.resolveWith(_resolveConfig, entry.file)
					.numberListOption('magic-number', 'ignore') ?? [];
				final exempt: Array<Float> = base.concat(ignore);
				walk(violations, entry.file, tree, null, false, false, cfg, exempt);
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
	 * sticky once set), the `parent` node (for sibling/context checks), and whether
	 * we sit in a string-POSITION context (`positionCtx` — inside a position-method
	 * call's arguments, propagated through offset arithmetic). Flag a numeric literal
	 * in logic that is not a named-binding initializer, an object-field value, an
	 * array index, a collection-size comparison or arithmetic, or a string position,
	 * and whose value is not exempt.
	 */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, parent: Null<QueryNode>, inFunction: Bool, positionCtx: Bool,
		cfg: MagicNumberCfg, exempt: Array<Float>
	): Void {
		final parentKind: String = parent != null ? parent.kind : '';
		final here: Bool = inFunction || cfg.functionKinds.contains(node.kind);
		if (
			here && cfg.numericKinds.contains(node.kind) && !cfg.localDeclKinds.contains(parentKind) && parentKind != cfg.objectFieldKind
			&& !isArrayIndex(parent, cfg) && !hasSizeFieldSibling(node, parent, cfg, cfg.comparisonKinds)
			&& !hasSizeFieldSibling(node, parent, cfg, cfg.additiveKinds) && !positionCtx
		)
			flag(out, file, node, exempt);
		final posCall: Bool = isPositionCall(node, cfg);
		for (i in 0...node.children.length)
			walk(out, file, node.children[i], node, here, childPositionCtx(node, i, positionCtx, posCall, cfg), cfg, exempt);
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

	/**
	 * A literal in the index slot of a subscript access (`args[3]`) — the number
	 * is a position, not a hidden quantity, and extracting it would not aid the
	 * reader. A computed index (`args[i + 3]`) keeps the literal under the
	 * operator node, so it stays flagged.
	 */
	private static function isArrayIndex(parent: Null<QueryNode>, cfg: MagicNumberCfg): Bool {
		return parent != null && cfg.indexAccessKind != '' && parent.kind == cfg.indexAccessKind;
	}

	/** A `Call` to one of `positionMethodNames` — its callee node's name is the invoked string-position method. */
	private static function isPositionCall(node: QueryNode, cfg: MagicNumberCfg): Bool {
		if (cfg.callKind == '' || node.kind != cfg.callKind || node.children.length == 0) return false;
		final calleeName: Null<String> = node.children[0].name;
		return calleeName != null && cfg.positionMethodNames.contains(calleeName);
	}

	/**
	 * The position-context flag for the `childIndex`-th child: true inside a
	 * position-method call's ARGUMENTS (index >= 1 — the callee at 0 is excluded),
	 * propagated through `+`/`-` offset arithmetic and parentheses, and reset to false
	 * at any other node — so `substr(0, foo(x * 5))` exempts the `0` but not the `5`
	 * under the unrelated inner call.
	 */
	private static function childPositionCtx(node: QueryNode, childIndex: Int, currentCtx: Bool, posCall: Bool, cfg: MagicNumberCfg): Bool {
		if (posCall) return childIndex >= 1;
		if (cfg.additiveKinds.contains(node.kind) || node.kind == cfg.parenKind) return currentCtx;
		return false;
	}

	/** Resolve the kind/name config once per run from `shape` — threads one struct into the recursion instead of a dozen scalars. */
	private static function buildCfg(shape: RefShape, numericKinds: Array<String>, functionKinds: Array<String>): MagicNumberCfg {
		return {
			numericKinds: numericKinds,
			functionKinds: functionKinds,
			localDeclKinds: shape.localDeclKinds ?? [],
			objectFieldKind: shape.objectFieldKind ?? '',
			indexAccessKind: shape.indexAccessKind ?? '',
			comparisonKinds: shape.comparisonKinds ?? [],
			fieldAccessKind: shape.fieldAccessKind ?? '',
			sizeFieldNames: shape.sizeFieldNames ?? [],
			callKind: shape.callKind ?? '',
			parenKind: shape.parenKind ?? '',
			positionMethodNames: shape.positionMethodNames ?? [],
			additiveKinds: shape.additiveKinds ?? []
		};
	}

	/**
	 * A literal that sits under an operator of `opKinds` (comparison or additive) with a
	 * collection-size field-access sibling (`args.length == 3`, `s.length - 3`) — a
	 * structural size check or count offset, whose number is contextual to the
	 * collection, not a hidden quantity. A comparison / offset against a plain value
	 * (`score == 100`, `from + 3`) has no size sibling and stays flagged.
	 */
	private static function hasSizeFieldSibling(
		node: QueryNode, parent: Null<QueryNode>, cfg: MagicNumberCfg, opKinds: Array<String>
	): Bool {
		if (parent == null || cfg.fieldAccessKind == '' || !opKinds.contains(parent.kind)) return false;
		for (sib in parent.children) {
			final sibName: Null<String> = sib.name;
			if (sib != node && sib.kind == cfg.fieldAccessKind && sibName != null && cfg.sizeFieldNames.contains(sibName)) return true;
		}
		return false;
	}

}

/**
 * Resolved kind config for the magic-number walk, built once per run so the
 * recursion threads one struct instead of a dozen scalars.
 */
private typedef MagicNumberCfg = {
	final numericKinds: Array<String>;
	final functionKinds: Array<String>;
	final localDeclKinds: Array<String>;
	final objectFieldKind: String;
	final indexAccessKind: String;
	final comparisonKinds: Array<String>;
	final fieldAccessKind: String;
	final sizeFieldNames: Array<String>;
	final callKind: String;
	final parenKind: String;
	final positionMethodNames: Array<String>;
	final additiveKinds: Array<String>;
};
