package anyparse.grammar.haxe;

import anyparse.query.GrammarPlugin;
import anyparse.query.Pattern;
import anyparse.query.QueryNode;
import anyparse.runtime.ParseError;
import anyparse.runtime.Span;
import haxe.Exception;

/**
 * Haxe grammar binding for the `apq` query engine.
 *
 * Parses with the macro-generated span-mode `HaxeModuleSpanParser` and
 * translates the typed AST into a generic `QueryNode` tree using
 * runtime type introspection (`Type` / `Reflect`). The span-mode parser
 * returns the paired `HxModuleS` typed AST directly — each enum value
 * carries its own `_span:Span` as the trailing positional arg
 * (`SpanTypeSynth` synthesises these on every Alt ctor).
 *
 *  - **Enum values become nodes.** `kind` is the constructor name
 *    verbatim (`ClassDecl`, `FnDecl`, `IfStmt`, …). The span is read
 *    directly from the value's last positional arg (post-Phase-2:
 *    in-AST instead of side-channel) so Reflect ordering of struct
 *    fields can no longer desynchronise span attribution.
 *  - **Anonymous structs are transparent.** Their fields contribute
 *    children to the enclosing enum-ctor node. A struct's `name` field
 *    (when a String) becomes the parent ctor's `name` slot.
 *  - **Arrays are transparent.** Their elements contribute children.
 *  - **Trivial-mode wrappers** (`{ node:T, leadingComments:…, … }`) are
 *    transparent on the `node` slot; the span-mode parser does not
 *    produce them, but the descent is in place for a future Trivia +
 *    Spans composition.
 *  - **Primitive leaves** (`String`/`Int`/`Float`/`Bool`/`Span`) do not
 *    emit nodes — they are absorbed into name detection or, in the
 *    case of `Span`, attached to the enclosing enum node.
 *
 * The root is a synthetic `module` node so users have a single
 * top-level handle in selectors and JSON output. The root carries no
 * span — `HxModule` itself is a Seq (struct) so no enum-ctor span
 * applies. Its children (top-level decls) carry their own spans.
 */
@:nullSafety(Strict)
final class HaxeQueryPlugin implements GrammarPlugin {

	/**
	 * Binding-declaration kinds shared by `refShape` and `metaShape`
	 * so the two contracts cannot drift. Top-level type decls,
	 * statement-level var bindings, class-member bindings, function
	 * parameters (`HxParam`'s three Alt branches), the
	 * `@:spanned('LambdaParam')` lambda-parameter struct, and enum
	 * constructors (`SimpleCtor` / `ParamCtor`) so an annotation on
	 * an `enum E { @:kw('x') A; }` ctor attributes to that ctor — the
	 * `MetaCall` and ctor nodes flatten as spanned siblings, so
	 * `Meta.followingDeclHost` resolves once the kind is a host.
	 * Anon-struct fields (`VarField` / `FinalField` / `FnField`, the
	 * `var` / `final` / `function` forms of `HxAnonField`) so
	 * `typedef T = { @:meta var f; }` field metadata + the field
	 * binding surface — the bare `name:Type` forms reuse the
	 * `Required` / `Optional` entries above. Reached only once
	 * `appendNodes` descends the anon `type` (see `isAnonType`).
	 */
	private static final DECL_HOST_KINDS:Array<String> = [
		'VarDecl', 'FnDecl',
		'ClassDecl', 'InterfaceDecl', 'EnumDecl', 'AbstractDecl', 'TypedefDecl',
		'VarMember', 'FinalMember', 'FnMember',
		'VarStmt', 'FinalStmt',
		'Required', 'Optional', 'Rest',
		'LambdaParam',
		'SimpleCtor', 'ParamCtor',
		'VarField', 'FinalField', 'FnField',
	];

	public function new() {}

	public function langName():String return 'haxe';

	public function parseFile(source:String):QueryNode {
		final root:Dynamic = HaxeModuleSpanParser.parse(source);
		final children:Array<QueryNode> = [];
		appendNodes(Reflect.field(root, 'decls'), children);
		return new QueryNode('module', null, children);
	}

	public function refShape():RefShape {
		// Identifier references come exclusively through `HxExpr.IdentExpr(v)`
		// — the bare-identifier branch of the expression enum. Field-access
		// (`obj.foo`), method names, type references, and string-literal
		// fragments live under different ctors and never match.
		//
		// Decl-host kinds: any enum-ctor whose `extractName` walk resolves
		// to a binding declaration. Top-level type decls (`ClassDecl`, …),
		// statement-level var bindings (`VarStmt`, `FinalStmt`, top-level
		// `VarDecl`/`FnDecl`), class-member bindings (`VarMember`,
		// `FinalMember`, `FnMember`), and function-parameter bindings via
		// `HxParam`'s three Alt branches (`Required`/`Optional`/`Rest`).
		//
		// Scope kinds: every node that opens a fresh lexical scope. The
		// walker pushes a frame on enter and pops on exit; decl-hosts
		// found in that scope's subtree (until the next inner scope
		// boundary) become the frame's bindings, shadowing same-named
		// outer bindings for any Read encountered inside.
		//
		// For-loop iterator variables (`HxForStmt.varName` /
		// `HxForExpr.varName`) are resolved (Phase 3.2b-alpha): the
		// `varName` alias in `extractName` surfaces the iterator on the
		// `ForStmt` / `ForExpr` ctor's `name` slot, and both kinds are
		// listed in `selfScopeDeclKinds` so the iterator self-binds into
		// the loop's own scope frame, visible to reads inside the body,
		// not after the loop.
		//
		// Catch-clause exception names and lambda-parameter names are
		// resolved (Phase 3.2b-beta): their grammar typedefs are tagged
		// `@:spanned('CatchClause')` / `@:spanned('LambdaParam')`, so the
		// paired struct carries a per-instance `_span` + `_kind` and
		// `appendNodes` surfaces it as an addressable node. `CatchClause`
		// is a self-scoped decl (the exception var is visible only inside
		// the clause body, like a for-loop iterator); `LambdaParam` is a
		// decl-host that binds into the enclosing lambda scope frame.
		//
		// Write-parent kinds: ctors on `HxExpr` whose first positional
		// child carries the binding being modified. `Assign(left, right)`
		// plus all 12 compound `*Assign(left, right)` variants, and the
		// four increment/decrement ctors `PreIncr` / `PreDecr` /
		// `PostIncr` / `PostDecr` (`HxExpr`, P5 Slice H — their single
		// operand at child-0 is the mutated binding). `x++` / `++x` both
		// read and write `x`; mirroring the compound-assign convention
		// they classify as a single Write. Per the `RefShape` docstring,
		// only the direct child-0 IdentExpr is reclassified Write;
		// `obj.x = …` and `arr[i] = …` keep `obj` / `arr` / `i` as Reads.
		return {
			identKind: 'IdentExpr',
			declHostKinds: DECL_HOST_KINDS,
			// `CatchClause` is surfaced by `appendNodes` from the
			// `@:spanned('CatchClause')` paired struct; it opens a scope
			// (the clause body) and self-binds the exception name into
			// that frame (see `selfScopeDeclKinds`).
			scopeKinds: [
				'ClassDecl', 'InterfaceDecl', 'AbstractDecl', 'EnumDecl', 'TypedefDecl',
				'FnDecl', 'FnExpr', 'FnMember',
				'ThinParenLambdaExpr', 'ParenLambdaExpr',
				'BlockBody', 'BlockExpr', 'BlockStmt',
				'ForStmt', 'ForExpr',
				'CatchClause',
			],
			writeParentKinds: [
				'Assign',
				'AddAssign', 'SubAssign', 'MulAssign', 'DivAssign', 'ModAssign',
				'ShlAssign', 'ShrAssign', 'UShrAssign',
				'BitOrAssign', 'BitAndAssign', 'BitXorAssign',
				'NullCoalAssign',
				'PreIncr', 'PreDecr', 'PostIncr', 'PostDecr',
			],
			// Self-scoped decl kinds: scope-introducers whose own name binds
			// into the frame they open (the for-loop iterator pattern). Listed
			// in scopeKinds, absent from declHostKinds — the binding is visible
			// only inside the loop, not to enclosing-scope siblings.
			selfScopeDeclKinds: [
				'ForStmt', 'ForExpr',
				'CatchClause',
			],
		};
	}

	public function metaShape():MetaShape {
		// Annotation nodes come through the three `HxMetadata` enum
		// ctors: `MetaCall` for the paren-bearing `@:name(args)` form
		// (its arg expressions are children), `Meta` for the paren-less
		// `@:name`, and `PlainMeta` for the verbatim raw catch-all
		// (`@:name(args)` carried inline as the node's `name` slot).
		// Decl-host kinds are shared with `refShape` so an annotation
		// attributes to the same binding-declaration nodes the refs
		// walker recognises.
		return {
			metaKinds: ['MetaCall', 'Meta', 'PlainMeta'],
			declHostKinds: DECL_HOST_KINDS,
		};
	}

	public function parsePattern(source:String):Pattern {
		// `$X` / `$_` are not valid Haxe identifier prefixes outside string
		// interpolation, so we substitute them for reserved-identifier
		// placeholders before parsing and reclassify the resulting leaves
		// post-parse. The grammar parser stays unmodified.
		final substituted:String = Metavar.substituteMetavarsHaxe(source);
		final attempts:Array<{wrap:String->String, extract:QueryNode->Null<QueryNode>, category:PatternCategory}> = [
			{wrap: src -> src, extract: extractFirstDecl, category: PatternCategory.Decl},
			{wrap: wrapAsStmt, extract: extractFirstStmt, category: PatternCategory.Stmt},
			{wrap: wrapAsExpr, extract: extractFirstExpr, category: PatternCategory.Expr},
			{wrap: wrapAsMetaArgs, extract: extractFirstMeta, category: PatternCategory.MetaArgs},
		];
		var bestError:Null<String> = null;
		for (attempt in attempts) {
			final wrapped:String = attempt.wrap(substituted);
			final tree:Null<QueryNode> = try parseFile(wrapped)
				catch (e:ParseError) {
					bestError = bestError ?? 'pattern: ${e.toString()}';
					null;
				}
				catch (e:Exception) {
					bestError = bestError ?? 'pattern: ${e.message}';
					null;
				};
			if (tree == null) continue;
			final extracted:Null<QueryNode> = attempt.extract(tree);
			if (extracted == null) continue;
			final reclassified:QueryNode = Metavar.reclassify(extracted);
			return new Pattern(reclassified, attempt.category, source);
		}
		throw bestError ?? 'pattern: failed to parse as decl / stmt / expr / meta-args';
	}

	private static function wrapAsStmt(src:String):String {
		return 'class _ApqPattern { static function _apq() { $src; } }';
	}

	private static function wrapAsExpr(src:String):String {
		return 'class _ApqPattern { static function _apq() { var _v = $src; } }';
	}

	private static function wrapAsMetaArgs(src:String):String {
		return 'class _ApqPattern { $src var _v:Int = 0; }';
	}

	private static function extractFirstDecl(module:QueryNode):Null<QueryNode> {
		if (module.children.length == 0) return null;
		return module.children[0];
	}

	private static function extractFirstStmt(module:QueryNode):Null<QueryNode> {
		// module → ClassDecl wrapper → FunctionField → FnDecl struct →
		// HxFnBody.BlockBody (enum) → HxFnBlock struct (flattened) →
		// stmts[0]. We navigate by enum kind names; struct envelopes are
		// transparent in the QueryNode tree.
		final cls:Null<QueryNode> = findFirstByKind(module, 'ClassDecl');
		if (cls == null) return null;
		final block:Null<QueryNode> = findFirstByKind(cls, 'BlockBody');
		if (block == null) return null;
		if (block.children.length == 0) return null;
		return block.children[0];
	}

	private static function extractFirstExpr(module:QueryNode):Null<QueryNode> {
		final cls:Null<QueryNode> = findFirstByKind(module, 'ClassDecl');
		if (cls == null) return null;
		final varStmt:Null<QueryNode> = findFirstByKind(cls, 'VarStmt');
		if (varStmt == null) return null;
		// VarStmt → HxVarDecl struct (flattened) → init expr is the last
		// child after name/type. Heuristic: the init is the last enum
		// child that isn't a name/type placeholder.
		if (varStmt.children.length == 0) return null;
		return varStmt.children[varStmt.children.length - 1];
	}

	private static function extractFirstMeta(module:QueryNode):Null<QueryNode> {
		final cls:Null<QueryNode> = findFirstByKind(module, 'ClassDecl');
		if (cls == null) return null;
		return findFirstByKind(cls, 'HxMeta')
			?? findFirstByKind(cls, 'Meta')
			?? findFirstByKindPrefix(cls, 'Meta');
	}

	private static function findFirstByKind(node:QueryNode, kind:String):Null<QueryNode> {
		if (node.kind == kind) return node;
		for (c in node.children) {
			final found:Null<QueryNode> = findFirstByKind(c, kind);
			if (found != null) return found;
		}
		return null;
	}

	private static function findFirstByKindPrefix(node:QueryNode, prefix:String):Null<QueryNode> {
		if (StringTools.startsWith(node.kind, prefix)) return node;
		for (c in node.children) {
			final found:Null<QueryNode> = findFirstByKindPrefix(c, prefix);
			if (found != null) return found;
		}
		return null;
	}

	private function appendNodes(value:Dynamic, into:Array<QueryNode>):Void {
		if (value == null) return;
		if (value is String) return;
		if (Std.isOfType(value, Span)) return;
		final t:Type.ValueType = Type.typeof(value);
		switch t {
			case TEnum(_):
				into.push(makeEnumNode(value));
			case TObject:
				if (Reflect.hasField(value, 'node')) {
					appendNodes(Reflect.field(value, 'node'), into);
					return;
				}
				// `@:spanned('<Kind>')` Seq structs carry `_kind` + `_span`
				// (see SpanTypeSynth / Lowering ω-spanned-struct): surface
				// them as addressable nodes instead of descending
				// transparently, so decl-bearing transparent structs (catch
				// clause, lambda param) resolve in `apq refs`.
				final kindVal:Dynamic = Reflect.hasField(value, '_kind') ? Reflect.field(value, '_kind') : null;
				final spanVal:Dynamic = Reflect.hasField(value, '_span') ? Reflect.field(value, '_span') : null;
				if (kindVal is String && Std.isOfType(spanVal, Span)) {
					final kindStr:String = kindVal;
					final spanObj:Span = cast spanVal;
					final children:Array<QueryNode> = [];
					for (field in Reflect.fields(value)) {
						if (field == 'name' || field == '_span' || field == '_kind') continue;
						// Mirror the generic branch: descend an anon-struct
						// `type` (decl-host members), skip name-slot type-refs.
						if (field == 'type' && !isAnonType(Reflect.field(value, 'type'))) continue;
						appendNodes(Reflect.field(value, field), children);
					}
					into.push(new QueryNode(kindStr, extractName(value), children, spanObj));
					return;
				}
				for (field in Reflect.fields(value)) {
					if (field == 'name') continue;
					// `type` is normally a name-slot leaf (`new T(...)`,
					// `var x:Foo`) and skipped — but an anon struct type
					// (`typedef T = {…}`, `var x:{…}`) carries decl-host
					// members + their metadata, so descend it. `HxType` is
					// an enum; the `Anon` ctor gate keeps `Named` type-refs
					// skipped (no phantom child per typed binding).
					if (field == 'type' && !isAnonType(Reflect.field(value, 'type'))) continue;
					appendNodes(Reflect.field(value, field), into);
				}
			case TClass(_):
				if (Std.isOfType(value, Array)) {
					final arr:Array<Dynamic> = cast value;
					for (e in arr) appendNodes(e, into);
				}
			case _:
		}
	}

	private function makeEnumNode(value:Dynamic):QueryNode {
		final ctor:String = Type.enumConstructor(value);
		final params:Array<Dynamic> = Type.enumParameters(value);
		var name:Null<String> = null;
		var span:Null<Span> = null;
		final children:Array<QueryNode> = [];
		for (p in params) {
			if (Std.isOfType(p, Span)) {
				span = cast p;
				continue;
			}
			if (name == null) name = extractName(p);
			appendNodes(p, children);
		}
		return new QueryNode(ctor, name, children, span);
	}

	private function extractName(value:Dynamic):Null<String> {
		if (value == null) return null;
		if (value is String) return value;
		final t:Type.ValueType = Type.typeof(value);
		switch t {
			case TObject:
				// Try canonical name slots in priority order. `name` is the
				// common case (HxClassDecl, HxFnDecl, ...); `type` covers
				// `new T(...)` (HxNewExpr) and similar nominally-typed
				// nodes; `varName` covers for-loop iterators (HxForStmt /
				// HxForExpr); `node` unwraps Trivial<T> envelopes for the
				// future Trivia + span composition.
				for (field in ['name', 'type', 'varName']) if (Reflect.hasField(value, field)) {
					final n:Dynamic = Reflect.field(value, field);
					if (n is String) return n;
				}
				if (Reflect.hasField(value, 'node')) return extractName(Reflect.field(value, 'node'));
			case _:
		}
		return null;
	}

	/**
	 * True when `v` is an `HxType.Anon` enum value — the anon-struct
	 * type whose `fields` carry decl-host members + their metadata.
	 * Gates the `appendNodes` `type`-field descent so only anon
	 * bodies surface; `Named` / `Arrow` / `Parens` type-refs stay
	 * skipped (descending them would emit a phantom child per typed
	 * binding).
	 */
	private static inline function isAnonType(v:Dynamic):Bool {
		if (v == null) return false;
		final t:Type.ValueType = Type.typeof(v);
		return switch t {
			case TEnum(_): Type.enumConstructor(v) == 'Anon';
			case _: false;
		}
	}
}
