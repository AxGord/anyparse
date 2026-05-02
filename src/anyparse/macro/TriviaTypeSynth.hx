package anyparse.macro;

#if macro
import anyparse.core.ShapeTree;
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * ω₄c — Atomic synthesis of paired `*T` typedefs / enums for
 * trivia-bearing grammar rules.
 *
 * Every rule that `TriviaAnalysis` marked with `trivia.bearing = true`
 * gets a sibling type suffixed `T`, placed in a dedicated synth module
 * at `<rootPack>.trivia.Pairs`. The synthesised types mirror the
 * originating rules structurally with three mechanical rewrites:
 *
 *  1. `Ref` fields/args whose target is itself bearing switch to the
 *     target's `*T` variant — non-bearing refs (e.g. `HxExpr`,
 *     `HxIdentLit`) stay unchanged.
 *  2. `Array<T>` containers whose Star carries `trivia.starCollects`
 *     wrap the element type in `anyparse.runtime.Trivial<…>` so the
 *     element's source-fidelity trivia (leading comments, blank-line
 *     marker, trailing comment) sits alongside the wrapped node.
 *  3. `Null<T>` wrapping + `@:optional` meta are preserved so downstream
 *     struct-literal construction in Trivia-mode Lowering compiles
 *     against the same surface the Plain-mode code compiles against.
 *
 * **Why atomic `defineModule`, not per-type `defineType`?** The grammar
 * reference graph is cyclic — `HxStatementT` references `HxIfStmtT`
 * which references `HxStatementT`. `defineType` eagerly type-checks
 * each TypeDefinition's field types on insertion, so the first call
 * fails the moment it encounters a sibling reference that hasn't been
 * registered yet. `Context.onTypeNotFound` was investigated as the
 * cycle-safe alternative but empirically does **not** fire for
 * references discovered during typing of a callback-returned
 * TypeDefinition — Haxe only consults the hook for the initial
 * top-level lookup. `defineModule` takes the whole batch at once and
 * types them as a single compilation unit, so within-batch cycles
 * resolve naturally.
 *
 * **Access path.** Each synthesised type's canonical name becomes
 * `<rootPack>.trivia.Pairs.<Leaf>T` — sub-module reference through
 * the synth module. Consumers import via
 * `import anyparse.grammar.haxe.trivia.Pairs.HxModuleT;` (direct
 * short-name alias) or `import anyparse.grammar.haxe.trivia.Pairs;`
 * followed by `Pairs.HxModuleT`. The separate subpackage keeps the
 * original grammar package free of generated artefacts.
 *
 * `arm(shape)` is called from `Build.buildParser` after
 * `TriviaAnalysis.run` when `ctx.trivia` is true. Repeated calls with
 * the same `ShapeResult` are idempotent — the per-name `defined` map
 * short-circuits already-synthesised types. A future second trivia
 * grammar would get its own synth module under its own root pack.
 *
 * See `feedback_definetype_cycles.md` for the rolled-back ω₄b attempt
 * and the `onTypeNotFound` probe that led to this pivot.
 */
class TriviaTypeSynth {

	/**
	 * ω-issue-316 — suffixes for kw-trivia sibling slots synthesised on
	 * paired Seq types alongside `@:optional @:kw(...)` Ref fields.
	 * Exposed so `Lowering` and `WriterLowering` can reference the same
	 * names without risk of silent divergence.
	 */
	public static inline final AFTER_KW_SUFFIX:String = 'AfterKw';
	public static inline final KW_LEADING_SUFFIX:String = 'KwLeading';

	/**
	 * ω-keep-policy — two additional source-shape slots captured
	 * alongside `AfterKw` / `KwLeading` for the same `@:optional @:kw(...)`
	 * Ref fields. `BeforeKwNewline` records whether the source had a
	 * newline between the preceding token and the keyword (consumed by
	 * `sameLineSeparator`'s `Keep` branch). `BodyOnSameLine` records
	 * whether the body's first token followed the keyword on the same
	 * line (consumed by `bodyPolicyWrap`'s `Keep` branch). Both default
	 * to `false` on the commit-miss path.
	 */
	public static inline final BEFORE_KW_NEWLINE_SUFFIX:String = 'BeforeKwNewline';
	public static inline final BODY_ON_SAME_LINE_SUFFIX:String = 'BodyOnSameLine';

	/**
	 * ω-trivia-before-kw — own-line comments captured BEFORE the optional
	 * keyword commit point (e.g. `if (x) { }\n// comment\nelse { }`). The
	 * pre-commit `skipWs` previously discarded this trivia; the new path
	 * collects it and stashes here on commit-success. Empty array on the
	 * commit-miss path (rewind discards the captured trivia).
	 */
	public static inline final BEFORE_KW_LEADING_SUFFIX:String = 'BeforeKwLeading';

	/**
	 * ω-issue-48-v2 — source-shape slot synthesised on paired Seq types
	 * alongside bare non-first Ref fields (no `@:optional`, no `@:kw`, no
	 * `@:lead`). Records whether the source had a newline in the gap
	 * between the preceding content and the sub-rule's first token.
	 * Consumed by the writer's inter-field separator so that
	 * `@:allow(...)\n\tvar x` round-trips with the newline intact even
	 * when the member's `modifiers` Star is empty — the first element of
	 * that empty Star cannot carry the `newlineBefore` signal, so the
	 * parser drains the stashed trivia here instead.
	 */
	public static inline final BEFORE_NEWLINE_SUFFIX:String = 'BeforeNewline';

	/**
	 * ω-orphan-trivia — suffixes for trailing-trivia sibling slots
	 * synthesised on paired Seq types alongside `@:trivia` Star fields.
	 * `TrailingLeading` carries the own-line comments captured AFTER
	 * the last element and BEFORE the close (or EOF); `TrailingBlankBefore`
	 * records whether the captured run crossed a blank line so the writer
	 * can reproduce the source's vertical separation between the final
	 * member and the orphan comments.
	 */
	public static inline final TRAILING_BLANK_BEFORE_SUFFIX:String = 'TrailingBlankBefore';
	public static inline final TRAILING_LEADING_SUFFIX:String = 'TrailingLeading';

	/**
	 * ω-close-trailing — suffix for the same-line trailing comment
	 * captured immediately after a `@:trivia` Star's close literal.
	 * Synthesised only for close-peek Stars (those with `@:trail`);
	 * EOF-mode Stars have no close to trail, and `@:trivia + @:tryparse`
	 * already rejects `@:trail` at compile time. `Null<String>` — `null`
	 * when the source had no same-line comment after the close.
	 */
	public static inline final TRAILING_CLOSE_SUFFIX:String = 'TrailingClose';

	/**
	 * ω-trailopt-source-track — positional arg name appended to paired
	 * Alt ctors that carry `@:trailOpt(...)`. The parser's `matchLit`
	 * result lands here so the writer can gate trail emission on source
	 * presence (`true` → emit literal; `false` → omit). Plain mode keeps
	 * the original ctor arity and falls back to AST-shape gates such as
	 * `@:fmt(trailOptShapeGate(...))`. First consumers: `HxDeclT.TypedefDecl`
	 * and `HxDeclT.VarDecl` (top-level) plus `HxStatementT.VarStmt` /
	 * `FinalStmt` (function-body locals).
	 */
	public static inline final TRAIL_PRESENT_ARG_NAME:String = 'trailPresent';

	private static inline final PAIRED_SUFFIX:String = 'T';
	private static inline final SYNTH_SUBPACK:String = 'trivia';
	private static inline final SYNTH_MODULE_LEAF:String = 'Pairs';
	private static final shapes:Array<ShapeBuilder.ShapeResult> = [];
	private static final defined:Map<String, Bool> = new Map();

	public static function arm(shape:ShapeBuilder.ShapeResult):Void {
		if (shapes.indexOf(shape) == -1) shapes.push(shape);
		final rootPack:Array<String> = packOf(shape.root);
		final synthPack:Array<String> = rootPack.concat([SYNTH_SUBPACK]);
		final modulePath:String = synthPack.concat([SYNTH_MODULE_LEAF]).join('.');
		final paired:Array<TypeDefinition> = [];
		for (origName => node in shape.rules) {
			if (node.annotations.get('trivia.bearing') != true) continue;
			final pairedFqn:String = origName + PAIRED_SUFFIX;
			if (defined.exists(pairedFqn)) continue;
			defined.set(pairedFqn, true);
			paired.push(buildTypeDefinition(origName, node, synthPack));
		}
		if (paired.length == 0) return;
		Context.defineModule(modulePath, paired);
		#if anyparse_trivia_dump
		for (td in paired)
			Sys.println('// trivia.synth: defined ${td.pack.join('.')}.${td.name} in module $modulePath');
		#end
	}

	private static function buildTypeDefinition(origName:String, origNode:ShapeNode, synthPack:Array<String>):TypeDefinition {
		final pairedSimple:String = leafOf(origName) + PAIRED_SUFFIX;
		final pos:Position = Context.currentPos();
		return switch origNode.kind {
			case Seq:
				final fields:Array<Field> = [];
				for (child in origNode.children) {
					fields.push(buildStructField(child, pos, synthPack));
					// ω-issue-316: `@:optional @:kw(...)` Ref fields grow two
					// sibling trivia slots — a same-line trailing comment
					// captured right after the kw (`AfterKw`), and own-line
					// comments captured between kw and body (`KwLeading`).
					// Writer consumes these to preserve source layout; absent
					// consumers read `null` / `[]` with no harm.
					if (isOptionalKwRef(child))
						for (extra in buildKwTriviaSlots(child, pos)) fields.push(extra);
					// ω-orphan-trivia: `@:trivia` Star fields grow two
					// sibling slots capturing trailing trivia (own-line
					// comments between the last element and the close /
					// EOF). Without them a class body like `{ /* orphan */ }`
					// would lose its comment at parse time.
					if (isTriviaStarField(child))
						for (extra in buildStarTrailingSlots(child, pos)) fields.push(extra);
					// ω-issue-48-v2: bare non-first Ref fields grow a
					// `BeforeNewline:Bool` slot capturing whether the source
					// had a newline in the gap between the preceding content
					// and the sub-rule's first token. Consumed by the
					// writer's inter-field separator.
					if (isBareNonFirstRef(child, origNode))
						fields.push(buildBeforeNewlineSlot(child, pos));
				}
				final anon:ComplexType = TAnonymous(fields);
				{pos: pos, pack: synthPack, name: pairedSimple, kind: TDAlias(anon), fields: []};
			case Alt:
				final fields:Array<Field> = [for (branch in origNode.children) buildEnumCtor(branch, pos, synthPack)];
				{pos: pos, pack: synthPack, name: pairedSimple, kind: TDEnum, fields: fields};
			case _:
				Context.fatalError('TriviaTypeSynth: unsupported bearing kind ${origNode.kind} for $origName', pos);
				throw 'unreachable';
		};
	}

	private static function buildStructField(child:ShapeNode, pos:Position, synthPack:Array<String>):Field {
		final fieldName:String = child.annotations.get('base.fieldName');
		final ct:ComplexType = shapeToComplexType(child, synthPack);
		final optional:Bool = child.annotations.get('base.optional') == true;
		final meta:Metadata = optional ? [{name: ':optional', params: [], pos: pos}] : [];
		return {name: fieldName, kind: FVar(ct), pos: pos, access: [], meta: meta};
	}

	private static function isOptionalKwRef(child:ShapeNode):Bool {
		if (child.kind != Ref) return false;
		if (child.annotations.get('base.optional') != true) return false;
		return readMetaString(child, ':kw') != null;
	}

	private static function isBareNonFirstRef(child:ShapeNode, parent:ShapeNode):Bool {
		if (child.kind != Ref) return false;
		if (child.annotations.get('base.optional') == true) return false;
		if (child == parent.children[0]) return false;
		if (readMetaString(child, ':kw') != null) return false;
		if (readMetaString(child, ':lead') != null) return false;
		return true;
	}

	private static function buildBeforeNewlineSlot(child:ShapeNode, pos:Position):Field {
		final fieldName:String = child.annotations.get('base.fieldName');
		final boolCT:ComplexType = TPath({pack: [], name: 'Bool', params: []});
		return {name: fieldName + BEFORE_NEWLINE_SUFFIX, kind: FVar(boolCT), pos: pos, access: []};
	}

	private static function buildKwTriviaSlots(child:ShapeNode, pos:Position):Array<Field> {
		final fieldName:String = child.annotations.get('base.fieldName');
		final strCT:ComplexType = TPath({pack: [], name: 'String', params: []});
		final nullStrCT:ComplexType = TPath({pack: [], name: 'Null', params: [TPType(strCT)]});
		final arrayStrCT:ComplexType = TPath({pack: [], name: 'Array', params: [TPType(strCT)]});
		final boolCT:ComplexType = TPath({pack: [], name: 'Bool', params: []});
		// Slots are mandatory (no `@:optional`). The parser always
		// populates them — `AfterKw` gets a captured same-line trailing
		// or `null`; `KwLeading` gets a list of own-line comments
		// (possibly empty); `BeforeKwNewline` / `BodyOnSameLine` carry
		// source-shape booleans for the `Keep` policy branches.
		// Mandatory typing keeps Null-Safety strict happy in the
		// writer's `kwGapDoc` / `bodyPolicyWrap` call sites.
		return [
			{name: fieldName + AFTER_KW_SUFFIX, kind: FVar(nullStrCT), pos: pos, access: []},
			{name: fieldName + KW_LEADING_SUFFIX, kind: FVar(arrayStrCT), pos: pos, access: []},
			{name: fieldName + BEFORE_KW_NEWLINE_SUFFIX, kind: FVar(boolCT), pos: pos, access: []},
			{name: fieldName + BODY_ON_SAME_LINE_SUFFIX, kind: FVar(boolCT), pos: pos, access: []},
			{name: fieldName + BEFORE_KW_LEADING_SUFFIX, kind: FVar(arrayStrCT), pos: pos, access: []},
		];
	}

	private static function isTriviaStarField(child:ShapeNode):Bool {
		return child.kind == Star && child.annotations.get('trivia.starCollects') == true;
	}

	private static function buildStarTrailingSlots(child:ShapeNode, pos:Position):Array<Field> {
		final fieldName:String = child.annotations.get('base.fieldName');
		final strCT:ComplexType = TPath({pack: [], name: 'String', params: []});
		final arrayStrCT:ComplexType = TPath({pack: [], name: 'Array', params: [TPType(strCT)]});
		final boolCT:ComplexType = TPath({pack: [], name: 'Bool', params: []});
		final fields:Array<Field> = [
			{name: fieldName + TRAILING_BLANK_BEFORE_SUFFIX, kind: FVar(boolCT), pos: pos, access: []},
			{name: fieldName + TRAILING_LEADING_SUFFIX, kind: FVar(arrayStrCT), pos: pos, access: []},
		];
		// ω-close-trailing: close-peek Stars (those with `@:trail`)
		// additionally carry a same-line trailing comment captured right
		// after the close literal. EOF-mode Stars omit this slot —
		// there's no close to trail. `@:trivia + @:tryparse` already
		// rejects `@:trail`, so tryparse cannot reach this branch.
		//
		// Reads `@:trail` directly from `base.meta` rather than the
		// Lit-strategy-derived `lit.trailText` annotation: `TriviaTypeSynth.arm`
		// runs BEFORE `registry.runAnnotate` in `Build.buildParser` /
		// `buildWriter` (the paired type must exist before Lowering /
		// WriterLowering reference it), so at this point the Lit pass has
		// not yet populated `lit.trailText`. Mirrors `isOptionalKwRef`'s
		// direct-meta read pattern.
		if (readMetaString(child, ':trail') != null) {
			final nullStrCT:ComplexType = TPath({pack: [], name: 'Null', params: [TPType(strCT)]});
			fields.push({name: fieldName + TRAILING_CLOSE_SUFFIX, kind: FVar(nullStrCT), pos: pos, access: []});
		}
		return fields;
	}

	private static function readMetaString(node:ShapeNode, tag:String):Null<String> {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return null;
		for (entry in meta) if (entry.name == tag) {
			if (entry.params.length != 1) return null;
			return switch entry.params[0].expr {
				case EConst(CString(s, _)): s;
				case _: null;
			};
		}
		return null;
	}

	private static function buildEnumCtor(branch:ShapeNode, pos:Position, synthPack:Array<String>):Field {
		final ctorName:String = branch.annotations.get('base.ctor');
		if (branch.children.length == 0) return {name: ctorName, kind: FVar(null), pos: pos, access: []};
		final args:Array<FunctionArg> = [for (arg in branch.children) {
			name: (arg.annotations.get('base.fieldName') : String),
			type: shapeToComplexType(arg, synthPack),
		}];
		// ω-close-trailing-alt: close-peek `@:trivia` Alt-branch Stars
		// (only `HxStatement.BlockStmt` in the current grammar) grow a
		// positional `closeTrailing:Null<String>` arg alongside the
		// existing Trivial-wrapped Star array. Mirrors the Seq-struct
		// close-trailing slot synthesised by `buildStarTrailingSlots`,
		// but the arg has no field-name prefix — Alt ctors are
		// positional so the writer reads it via `argNames[1]`.
		if (isAltCloseTrailingBranch(branch)) {
			final strCT:ComplexType = TPath({pack: [], name: 'String', params: []});
			final nullStrCT:ComplexType = TPath({pack: [], name: 'Null', params: [TPType(strCT)]});
			args.push({name: 'closeTrailing', type: nullStrCT});
		}
		// ω-trailopt-source-track: `@:trailOpt(...)` Alt branches with a
		// single Ref child grow a positional `trailPresent:Bool` arg
		// holding the parser's `matchLit` result. Disjoint from
		// `isAltCloseTrailingBranch` (Star vs Ref child shapes), so the
		// two cannot collide on the same ctor. Read `@:trailOpt` from
		// `base.meta` directly since `arm()` runs BEFORE the Lit pass
		// populates `lit.trailOptional` on the branch.
		if (isAltTrailOptBranch(branch)) {
			final boolCT:ComplexType = TPath({pack: [], name: 'Bool', params: []});
			args.push({name: TRAIL_PRESENT_ARG_NAME, type: boolCT});
		}
		return {name: ctorName, kind: FFun({args: args, ret: null, expr: null}), pos: pos, access: []};
	}

	/**
	 * True when the branch is a close-peek `@:trivia` Alt-ctor wrapping
	 * a single Star child — structurally equivalent to the Seq Case 4
	 * shape that grows a `TrailingClose` slot in `buildStarTrailingSlots`.
	 * Reads `@:trail` from `base.meta` directly since `arm()` runs
	 * before the Lit strategy populates `lit.trailText`.
	 */
	public static function isAltCloseTrailingBranch(branch:ShapeNode):Bool {
		if (branch.children.length != 1) return false;
		final star:ShapeNode = branch.children[0];
		if (star.kind != Star) return false;
		if (star.annotations.get('trivia.starCollects') != true) return false;
		return readMetaString(branch, ':trail') != null;
	}

	/**
	 * True when the branch is a single-Ref Alt-ctor carrying `@:trailOpt(...)`.
	 * Such ctors grow a positional `trailPresent:Bool` arg in the synth
	 * pair so the writer can preserve source presence of the optional
	 * trail literal. Reads `@:trailOpt` from `base.meta` directly since
	 * `arm()` runs before the Lit strategy populates `lit.trailOptional`.
	 *
	 * Disjoint from `isAltCloseTrailingBranch`: that function requires a
	 * single Star child with `@:trail`, this requires a single Ref child
	 * with `@:trailOpt`. The two never coexist on the same branch.
	 */
	public static function isAltTrailOptBranch(branch:ShapeNode):Bool {
		if (branch.children.length != 1) return false;
		if (branch.children[0].kind != Ref) return false;
		return readMetaString(branch, ':trailOpt') != null;
	}

	private static function shapeToComplexType(node:ShapeNode, synthPack:Array<String>):ComplexType {
		return switch node.kind {
			case Ref:
				final refName:String = node.annotations.get('base.ref');
				final base:ComplexType = refIsBearing(refName)
					? TPath({pack: synthPack, name: leafOf(refName) + PAIRED_SUFFIX, params: []})
					: TPath({pack: packOf(refName), name: leafOf(refName), params: []});
				return wrapOptional(node, base);
			case Star:
				final elementCT:ComplexType = shapeToComplexType(node.children[0], synthPack);
				final wrapped:ComplexType = node.annotations.get('trivia.starCollects') == true
					? TPath({pack: ['anyparse', 'runtime'], name: 'Trivial', params: [TPType(elementCT)]})
					: elementCT;
				return wrapOptional(node, TPath({pack: [], name: 'Array', params: [TPType(wrapped)]}));
			case Terminal:
				final tp:Null<String> = node.annotations.get('base.typePath');
				if (tp != null) return wrapOptional(node, TPath({pack: packOf(tp), name: leafOf(tp), params: []}));
				final under:String = node.annotations.get('base.underlying');
				return wrapOptional(node, TPath({pack: [], name: under, params: []}));
			case _:
				Context.fatalError('TriviaTypeSynth: unexpected node kind ${node.kind} in field-shape', Context.currentPos());
				throw 'unreachable';
		};
	}

	private static inline function wrapOptional(node:ShapeNode, base:ComplexType):ComplexType {
		return node.annotations.get('base.optional') == true
			? TPath({pack: [], name: 'Null', params: [TPType(base)]})
			: base;
	}

	private static function refIsBearing(refName:String):Bool {
		for (shape in shapes) {
			final node:Null<ShapeNode> = shape.rules.get(refName);
			if (node != null) return node.annotations.get('trivia.bearing') == true;
		}
		return false;
	}

	private static function packOf(qualifiedName:String):Array<String> {
		final idx:Int = qualifiedName.lastIndexOf('.');
		return idx == -1 ? [] : qualifiedName.substring(0, idx).split('.');
	}

	private static function leafOf(qualifiedName:String):String {
		final idx:Int = qualifiedName.lastIndexOf('.');
		return idx == -1 ? qualifiedName : qualifiedName.substring(idx + 1);
	}
}
#end
