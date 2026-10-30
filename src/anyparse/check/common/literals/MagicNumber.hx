package anyparse.check.common.literals;

import anyparse.check.Check.ConfigAware;
import anyparse.check.Check.NoAutofix;
import anyparse.check.common.literals.LiteralTables.LiteralTableShape;
import anyparse.query.NodeShape;
import anyparse.query.SymbolIndex;

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
 *     k`) is still in logic and is flagged. A literal that is the direct value of an
 *     object-literal field (`RefShape.objectFieldKind`, e.g. `{ value: 30 }`) is likewise
 *     declarative data and exempt; a computed field value keeps the literal under the
 *     operator and stays flagged. A literal in the index slot of a subscript
 *     (`RefShape.indexAccessKind`, e.g. `args[3]`) is a position, not a hidden quantity, and a
 *     literal compared against a size-like field access (`RefShape.sizeFieldNames`, e.g.
 *     `args.length == 3`) is a structural arity check — both exempt; a computed index
 *     (`args[i + 3]`) or a comparison against a plain value (`score == 100`) stays flagged. A
 *     literal reaching a string-position method argument (`positionMethodNames`, e.g.
 *     `s.charCodeAt(i + 5)` / `s.substr(0, 4)`), directly or through `+` / `-` offset
 *     arithmetic (`additiveKinds`), is a position, and a literal offset from a size field
 *     (`s.length - 3`) is a count offset — both exempt, while a bare offset
 *     with no size sibling (`from + 3`) stays flagged. A literal that is DIRECTLY an argument of a
 *     call named in the `ignoreCallArguments` option (`t('label', 10233)` under `["t"]`) is a key
 *     the callee owns, and exempt; one nested in an argument expression (`t('x', 100 + k)`) is not.
 *     So is a negated one (`f(-18)`), a constructor's under `T.new`, and one of a value object built in
 *     place as a listed argument (`childKeyCtx`).
 *  3. under `literalTables` (default off), it is not in a switch or named collection TABLE
 *     (`LiteralTables`, `isNamedTable`).
 *  4. its numeric value is not in the exempt set `{0, 1, 2}` plus any number
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
final class MagicNumber extends RuleBase implements ConfigAware implements NoAutofix {

	/** This check's stable id, also the key of its `apqlint.json` options. */
	private static inline final RULE_ID: String = 'magic-number';

	/** Conventional values that carry no hidden meaning and are never flagged. */
	private static final EXEMPT: Array<Float> = [-1, 0, 1, 2];

	/** The linter's memoised per-file config resolver; null when run outside it (falls back to `LintConfig.discover`). */
	private var _resolveConfig: Null<(String) -> LintConfig> = null;

	public function new() {
		super(RULE_ID, 'a magic numeric literal in logic that should be a named constant', RuleCategory.Literals);
	}

	public function setConfigResolver(resolve: Null<(String) -> LintConfig>): Void {
		_resolveConfig = resolve;
	}

	public function run(files: Array<{ file: String, source: String }>, plugin: GrammarPlugin): Array<Violation> {
		final shape: RefShape = plugin.refShape();
		final numericKinds: Array<String> = shape.numericLiteralKinds ?? [];
		final functionKinds: Array<String> = shape.functionKinds ?? [];
		if (numericKinds.length == 0 || functionKinds.length == 0) return [];
		final cfg: MagicNumberCfg = buildCfg(shape, numericKinds, functionKinds, plugin);
		return RunScan.collect(files, plugin, (entry, tree, violations) -> {
			// Exempt base: a project checkstyle `MagicNumber.ignoreNumbers`, else the built-in default;
			// the apqlint `ignore` list adds to it.
			final base: Array<Float> = plugin.checkOverrides(entry.file)?.magicNumberIgnore ?? EXEMPT;
			final config: LintConfig = LintConfig.resolveWith(_resolveConfig, entry.file);
			final ignore: Array<Float> = config.numberListOption(RULE_ID, 'ignore') ?? [];
			final calls: Array<String> = config.stringListOption(RULE_ID, 'ignoreCallArguments') ?? [];
			final exempt: MagicNumberExempt = {
				values: base.concat(ignore),
				calls: [for (c in calls) if (c != '') c.split('.')],
				tables: config.boolOption(RULE_ID, 'literalTables') ?? false,
				source: entry.source
			};
			walk(violations, entry.file, tree, null, false, false, false, cfg, exempt);
		});
	}

	/** No mechanical autofix — a literal cannot be auto-named. */
	public function fix(
		source: String, violations: Array<Violation>, plugin: GrammarPlugin, ?index: SymbolIndex
	): Array<{ span: Span, text: String }> {
		return [];
	}

	/**
	 * The literal is flagged so a HUMAN names it. An auto-hoisted `CONST_7` restates the
	 * digit and hides it behind an indirection, which is strictly worse than the literal.
	 */
	public function noAutofixReason(): String {
		return
			'the finding asks for a NAME, and only the author knows it — an auto-hoisted CONST_7 restates the digit behind an indirection';
	}

	/**
	 * A literal in the index slot of a subscript access (`args[3]`) — the number
	 * is a position, not a hidden quantity, and extracting it would not aid the
	 * reader. A computed index (`args[i + 3]`) keeps the literal under the
	 * operator node, so it stays flagged.
	 */
	private static inline function isArrayIndex(parent: Null<QueryNode>, cfg: MagicNumberCfg): Bool {
		return parent != null && cfg.indexAccessKind != '' && parent.kind == cfg.indexAccessKind;
	}

	/**
	 * The key-context flag for the `childIndex`-th child. A `keyHost` — a listed call or constructor, or a
	 * constructor that is itself in key context (a value object built in place as a listed argument:
	 * `new SpriteDescriptor(id, new Point(-18, -83.75))`) — hands it to its ARGUMENTS: a call's children
	 * after the callee, a constructor's after its type arguments (`QueryNode.typeArgCount`). A negation in
	 * key context hands it to its operand, since Haxe has no negative literal (`f(-18)` is `Neg(IntLit 18)`).
	 * Every other node resets it, so `t('x', 100 + k)` and `t('x', make(5))` keep their literals flagged.
	 */
	private static inline function childKeyCtx(
		node: QueryNode, childIndex: Int, currentCtx: Bool, keyHost: Bool, cfg: MagicNumberCfg
	): Bool {
		return keyHost ? childIndex >= (node.kind == cfg.callKind ? 1 : node.typeArgCount) : currentCtx && node.kind == cfg.negationKind;
	}

	/**
	 * Walk `node`, tracking whether we are inside a function unit (`inFunction`,
	 * sticky once set), the `parent` node (for sibling/context checks), whether
	 * we sit in a string-POSITION context (`positionCtx` — inside a position-method
	 * call's arguments, propagated through offset arithmetic), and whether we sit in a
	 * KEY context (`keyCtx` — a direct argument of an `ignoreCallArguments` callee, see
	 * `childKeyCtx`). Flag a numeric literal in logic that is not a named-binding
	 * initializer, an object-field value, an array index, a collection-size comparison
	 * or arithmetic, a string position or a key, and whose value is not exempt. Under
	 * `literalTables` a switch table's arms and a named collection table are not walked.
	 */
	private static function walk(
		out: Array<Violation>, file: String, node: QueryNode, parent: Null<QueryNode>, inFunction: Bool, positionCtx: Bool, keyCtx: Bool,
		cfg: MagicNumberCfg, exempt: MagicNumberExempt
	): Void {
		final parentKind: String = parent != null ? parent.kind : '';
		final here: Bool = inFunction || cfg.functionKinds.contains(node.kind);
		if (
			here
			&& cfg.numericKinds.contains(node.kind)
			&& !cfg.localDeclKinds.contains(parentKind)
			&& parentKind != cfg.objectFieldKind
			&& !isArrayIndex(parent, cfg)
			&& !hasSizeFieldSibling(node, parent, cfg, cfg.comparisonKinds)
			&& !hasSizeFieldSibling(node, parent, cfg, cfg.additiveKinds)
			&& !positionCtx
			&& !keyCtx
		)
			flag(out, file, node, exempt.values);
		if (exempt.tables) {
			if (LiteralTables.isSwitchTable(node, exempt.source, cfg.tables)) {
				// The table is the arms; the subject is logic like any other expression.
				walk(out, file, node.children[0], node, here, false, false, cfg, exempt);
				return;
			}
			if (isNamedTable(node, parent, cfg, exempt.source)) return;
		}
		final posCall: Bool = isPositionCall(node, cfg);
		final keyHost: Bool = isIgnoredCall(node, cfg, exempt.calls) || keyCtx && node.kind == cfg.newExprKind;
		for (i in 0...node.children.length) {
			final child: QueryNode = node.children[i];
			walk(
				out, file, child, node, here, childPositionCtx(node, i, positionCtx, posCall, cfg),
				childKeyCtx(node, i, keyCtx, keyHost, cfg), cfg, exempt
			);
		}
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
			rule: RULE_ID,
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
		final clean: String = text.replace('_', '');
		if (clean.startsWith('0x') || clean.startsWith('0X')) {
			return (Std.parseInt(clean): Null<Int>);
		}
		final f: Float = Std.parseFloat(clean);
		return Math.isNaN(f) ? null : f;
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
		return posCall ? childIndex >= 1 : (cfg.additiveKinds.contains(node.kind) || node.kind == cfg.parenKind) && currentCtx;
	}

	/** Resolve the kind/name config once per run from `shape` — threads one struct into the recursion instead of a dozen scalars. */
	private static function buildCfg(
		shape: RefShape, numericKinds: Array<String>, functionKinds: Array<String>, plugin: GrammarPlugin
	): MagicNumberCfg {
		return {
			numericKinds: numericKinds,
			functionKinds: functionKinds,
			localDeclKinds: shape.localDeclKinds ?? [],
			objectFieldKind: shape.objectFieldKind ?? '',
			indexAccessKind: shape.indexAccessKind ?? '',
			comparisonKinds: shape.comparisonKinds ?? [],
			fieldAccessKind: shape.fieldAccessKind ?? '',
			identKind: shape.identKind,
			sizeFieldNames: shape.sizeFieldNames ?? [],
			callKind: shape.callKind ?? '',
			parenKind: shape.parenKind ?? '',
			positionMethodNames: shape.positionMethodNames ?? [],
			additiveKinds: shape.additiveKinds ?? [],
			newExprKind: shape.newExprKind ?? '',
			negationKind: shape.negationKind ?? '',
			constructorName: shape.constructorName ?? '',
			functionBodyKinds: shape.functionBodyKinds ?? [],
			valueReturnKinds: shape.valueReturnKinds ?? [],
			tables: LiteralTables.shapeOf(shape, plugin.stringFoldSupport())
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

	/**
	 * Whether `node` is a call or a constructor whose callee matches an `ignoreCallArguments` entry — the
	 * callee owns its arguments' literals as keys (`t('Complete with AI', 10233)`), not quantities. An entry
	 * matches when its dotted segments are the LAST segments of the callee as written (see `pathEndsWith`
	 * and `calledPath`).
	 */
	private static function isIgnoredCall(node: QueryNode, cfg: MagicNumberCfg, calls: Array<Array<String>>): Bool {
		if (calls.length == 0) return false;
		final path: Array<String> = calledPath(node, cfg);
		return path.length > 0 && calls.exists(entry -> pathEndsWith(path, entry));
	}

	/**
	 * The callee path an `ignoreCallArguments` entry is matched against: a call's callee as written
	 * (`NodeShape.calleePath` — `Lang.t(…)` is `[Lang, t]`), or for a constructor the constructed type's
	 * path followed by the grammar's `RefShape.constructorName` — `new data.SpriteDescriptor(…)` is
	 * `[data, SpriteDescriptor, new]`, the spelling Haxe itself gives a constructor used as a value
	 * (`SpriteDescriptor.new`). Type arguments are no part of the path. Empty for anything else, and for a
	 * constructor when the grammar names no constructor, so no entry reaches it.
	 */
	private static function calledPath(node: QueryNode, cfg: MagicNumberCfg): Array<String> {
		if (node.kind == cfg.callKind && node.children.length > 0)
			return NodeShape.calleePath(node.children[0], cfg.fieldAccessKind, cfg.identKind);
		final typeName: Null<String> = node.name;
		return node.kind == cfg.newExprKind && typeName != null && cfg.constructorName != ''
			? typeName.split('.').concat([cfg.constructorName])
			: [];
	}

	/**
	 * Whether `node` is a collection TABLE (`LiteralTables.isCollectionTable`) a NAME gives its meaning to —
	 * the reasoning that already exempts `final x = 5000;`: the direct initializer of a local
	 * (`RefShape.localDeclKinds`), or, tested at a function BODY (`RefShape.functionBodyKinds`), the value
	 * of the body's only statement when that is a return (`RefShape.valueReturnKinds`):
	 * `function initDecodeChar() return [-1, 62, 63]`. A table handed to a call, built inside an expression
	 * or returned beside other statements has no name of its own and stays logic.
	 */
	private static function isNamedTable(node: QueryNode, parent: Null<QueryNode>, cfg: MagicNumberCfg, source: String): Bool {
		if (LiteralTables.isCollectionTable(node, source, cfg.tables)) return parent != null && cfg.localDeclKinds.contains(parent.kind);
		if (!cfg.functionBodyKinds.contains(node.kind) || node.children.length != 1) return false;
		final ret: QueryNode = node.children[0];
		return cfg.valueReturnKinds.contains(ret.kind)
			&& ret.children.length == 1
			&& LiteralTables.isCollectionTable(ret.children[0], source, cfg.tables);
	}

	/**
	 * Whether `suffix` is the tail of `path`, segment for segment. So a bare `t` matches every call whose
	 * last name is `t` (`t(…)`, `Lang.t(…)`, `this.t(…)`), `Lang.t` matches `Lang.t(…)` and
	 * `pkg.Lang.t(…)` but not a bare `t(…)` — a call imported by name no longer spells its type — and a
	 * receiver that is no path (`make().t(…)`) contributes nothing, so only a bare entry reaches it.
	 */
	private static function pathEndsWith(path: Array<String>, suffix: Array<String>): Bool {
		if (suffix.length == 0 || suffix.length > path.length) return false;
		final offset: Int = path.length - suffix.length;
		for (i in 0...suffix.length) if (path[offset + i] != suffix[i]) return false;
		return true;
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
	final identKind: String;
	final sizeFieldNames: Array<String>;
	final callKind: String;
	final parenKind: String;
	final positionMethodNames: Array<String>;
	final additiveKinds: Array<String>;
	final newExprKind: String;
	final negationKind: String;
	final constructorName: String;
	final functionBodyKinds: Array<String>;
	final valueReturnKinds: Array<String>;
	final tables: LiteralTableShape;
};

/**
 * What exempts a literal in one file: the exempt `values`, the `ignoreCallArguments` entries, each
 * already split into its dotted segments, whether `literalTables` is on, and the file's `source` (a
 * table's string data is read through the grammar's string-fold seam, which needs it).
 */
private typedef MagicNumberExempt = {
	final values: Array<Float>;
	final calls: Array<Array<String>>;
	final tables: Bool;
	final source: String;
};
