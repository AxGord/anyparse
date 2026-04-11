package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import anyparse.core.LoweringCtx;
import anyparse.core.ShapeTree;

/**
 * Pass 3 of the macro pipeline — lowering.
 *
 * Walks the shape tree produced by `ShapeBuilder` (after the strategy
 * annotation pass has written the `lit.*`, `re.*`, `skip.*` slots on
 * each node) and emits one `GeneratedRule` per top-level type in the
 * grammar. Each rule's body uses unqualified helper names (`skipWs`,
 * `matchLit`, `expectLit`, `parseXxx`) that Codegen injects into the
 * same class, plus `$p{...}` expressions for cross-package type and
 * constructor references.
 *
 * Phase 2 ships three rule shapes: enum Alt rules (construct a named
 * enum constructor per branch), typedef Seq rules (build an anonymous
 * struct literal), and Terminal rules (run an `EReg` and decode the
 * matched slice). Structural CoreIR primitives (`Lit`, `Re`, `Seq`,
 * `Alt`, `Star`, `Opt`, `Ref`, `Empty`) are used to describe each rule
 * conceptually; the emitter produces the concrete Haxe expression
 * directly rather than round-tripping through a separate `CoreIR →
 * Expr` serializer, which would double the code with no observable
 * benefit until Phase 3 adds more primitive variants.
 */
class Lowering {

	private final shape:ShapeBuilder.ShapeResult;
	private final formatInfo:FormatReader.FormatInfo;
	private final ctx:LoweringCtx;
	private final eregByRule:Map<String, GeneratedRule.EregSpec> = new Map();

	public function new(shape:ShapeBuilder.ShapeResult, formatInfo:FormatReader.FormatInfo, ctx:LoweringCtx) {
		this.shape = shape;
		this.formatInfo = formatInfo;
		this.ctx = ctx;
	}

	public function generate():Array<GeneratedRule> {
		final rules:Array<GeneratedRule> = [];
		for (typePath => node in shape.rules) rules.push(lowerRule(typePath, node));
		return rules;
	}

	private function lowerRule(typePath:String, node:ShapeNode):GeneratedRule {
		final simpleName:String = simpleName(typePath);
		final fnName:String = 'parse$simpleName';
		final returnCT:ComplexType = TPath({pack: packOf(typePath), name: simpleName, params: []});
		final body:Expr = switch node.kind {
			case Alt: lowerEnum(node, typePath);
			case Seq: lowerStruct(node, typePath);
			case Terminal: lowerTerminal(node, typePath, simpleName);
			case _:
				Context.fatalError('Lowering: cannot lower top-level ${node.kind} for $typePath', Context.currentPos());
				throw 'unreachable';
		};
		final eregs:Array<GeneratedRule.EregSpec> = [];
		if (eregByRule.exists(typePath)) eregs.push(eregByRule.get(typePath));
		return new GeneratedRule(fnName, returnCT, body, eregs);
	}

	// -------- enum rule --------

	private function lowerEnum(node:ShapeNode, typePath:String):Expr {
		final branchExprs:Array<Expr> = [for (branch in node.children) tryBranch(branch, typePath)];
		final failExpr:Expr = macro throw new anyparse.runtime.ParseError(
			new anyparse.runtime.Span(ctx.pos, ctx.pos),
			$v{'expected ${simpleName(typePath)}'}
		);
		final statements:Array<Expr> = branchExprs.concat([failExpr]);
		return macro $b{statements};
	}

	private function tryBranch(branch:ShapeNode, typePath:String):Expr {
		final body:Expr = lowerEnumBranch(branch, typePath);
		return macro {
			final _savedPos:Int = ctx.pos;
			try $body catch (_e:anyparse.runtime.ParseError) ctx.pos = _savedPos;
		};
	}

	private function lowerEnumBranch(branch:ShapeNode, typePath:String):Expr {
		final ctor:String = branch.annotations.get('base.ctor');
		final ctorPath:Array<String> = packOf(typePath).concat([simpleName(typePath), ctor]);
		final ctorRef:Expr = MacroStringTools.toFieldExpr(ctorPath);

		// Classify branch shape.
		final litList:Null<Array<String>> = branch.annotations.get('lit.litList');
		final children:Array<ShapeNode> = branch.children;
		final leadText:Null<String> = branch.annotations.get('lit.leadText');
		final trailText:Null<String> = branch.annotations.get('lit.trailText');
		final sepText:Null<String> = branch.annotations.get('lit.sepText');

		// Case 1: zero-arg ctor with @:lit(single).
		if (litList != null && litList.length == 1 && children.length == 0) {
			final lit:String = litList[0];
			return macro {
				skipWs(ctx);
				expectLit(ctx, $v{lit});
				return $ctorRef;
			};
		}

		// Case 2: single-arg ctor with @:lit(multi) — literals map to ident values of the field type.
		if (litList != null && litList.length > 1 && children.length == 1) {
			final attempts:Array<Expr> = [];
			for (lit in litList) {
				final valueExpr:Expr = {expr: EConst(CIdent(lit)), pos: Context.currentPos()};
				final call:Expr = {expr: ECall(ctorRef, [valueExpr]), pos: Context.currentPos()};
				attempts.push(macro if (matchLit(ctx, $v{lit})) return $call);
			}
			final failExpr:Expr = macro throw new anyparse.runtime.ParseError(
				new anyparse.runtime.Span(ctx.pos, ctx.pos),
				$v{'expected one of ${litList.join(", ")}'}
			);
			final body:Array<Expr> = [macro skipWs(ctx)].concat(attempts).concat([failExpr]);
			return macro $b{body};
		}

		// Case 3: single-arg ctor wrapping a Ref (no literal glue).
		if (litList == null && leadText == null && children.length == 1 && children[0].kind == Ref) {
			final refName:String = children[0].annotations.get('base.ref');
			final callSub:Expr = {
				expr: ECall(macro $i{'parse${simpleName(refName)}'}, [macro ctx]),
				pos: Context.currentPos(),
			};
			final ctorCall:Expr = {expr: ECall(ctorRef, [macro _raw]), pos: Context.currentPos()};
			return macro {
				skipWs(ctx);
				final _raw = $callSub;
				return $ctorCall;
			};
		}

		// Case 4: single-arg ctor wrapping Array<Ref> with @:lead/@:trail/@:sep.
		if (leadText != null && trailText != null && children.length == 1 && children[0].kind == Star) {
			final inner:ShapeNode = children[0].children[0];
			if (inner.kind != Ref) {
				Context.fatalError('Lowering: Star child must be a Ref in Phase 2', Context.currentPos());
			}
			final elemRefName:String = inner.annotations.get('base.ref');
			final elemFn:String = 'parse${simpleName(elemRefName)}';
			final elemCT:ComplexType = TPath({pack: packOf(elemRefName), name: simpleName(elemRefName), params: []});
			final elemCall:Expr = {
				expr: ECall(macro $i{elemFn}, [macro ctx]),
				pos: Context.currentPos(),
			};
			final sepCharCode:Int = sepText != null && sepText.length > 0 ? sepText.charCodeAt(0) : -1;
			final closeCharCode:Int = trailText.charCodeAt(0);
			final ctorCall:Expr = {expr: ECall(ctorRef, [macro _items]), pos: Context.currentPos()};
			return macro {
				skipWs(ctx);
				expectLit(ctx, $v{leadText});
				final _items:Array<$elemCT> = [];
				skipWs(ctx);
				if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
					_items.push($elemCall);
					skipWs(ctx);
					while (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
						ctx.pos++;
						skipWs(ctx);
						_items.push($elemCall);
						skipWs(ctx);
					}
				}
				skipWs(ctx);
				expectLit(ctx, $v{trailText});
				return $ctorCall;
			};
		}

		Context.fatalError('Lowering: unsupported enum branch shape for ${simpleName(typePath)}.${ctor}', Context.currentPos());
		throw 'unreachable';
	}

	// -------- struct rule --------

	private function lowerStruct(node:ShapeNode, typePath:String):Expr {
		final parseSteps:Array<Expr> = [];
		final structFields:Array<ObjectField> = [];
		for (child in node.children) {
			final fieldName:Null<String> = child.annotations.get('base.fieldName');
			if (fieldName == null) {
				Context.fatalError('Lowering: struct field missing base.fieldName', Context.currentPos());
			}
			// Per-field @:lead
			final leadText:Null<String> = readMetaString(child, ':lead');
			if (leadText != null) {
				parseSteps.push(macro skipWs(ctx));
				parseSteps.push(macro expectLit(ctx, $v{leadText}));
			}
			// Field value
			final localName:String = '_f_$fieldName';
			final valueExpr:Expr = lowerFieldValue(child);
			parseSteps.push(macro skipWs(ctx));
			parseSteps.push({
				expr: EVars([{
					name: localName,
					type: null,
					expr: valueExpr,
					isFinal: true,
				}]),
				pos: Context.currentPos(),
			});
			structFields.push({field: fieldName, expr: macro $i{localName}});
		}
		final structLiteral:Expr = {expr: EObjectDecl(structFields), pos: Context.currentPos()};
		parseSteps.push(macro return $structLiteral);
		return macro $b{parseSteps};
	}

	private function lowerFieldValue(node:ShapeNode):Expr {
		return switch node.kind {
			case Ref:
				final refName:String = node.annotations.get('base.ref');
				{expr: ECall(macro $i{'parse${simpleName(refName)}'}, [macro ctx]), pos: Context.currentPos()};
			case _:
				Context.fatalError('Lowering: field value kind ${node.kind} not supported in Phase 2', Context.currentPos());
				throw 'unreachable';
		};
	}

	// -------- terminal rule --------

	private function lowerTerminal(node:ShapeNode, typePath:String, simple:String):Expr {
		final pattern:Null<String> = node.annotations.get('re.pattern');
		if (pattern == null) {
			Context.fatalError('Lowering: terminal $typePath missing @:re', Context.currentPos());
			throw 'unreachable';
		}
		final underlying:String = node.annotations.get('base.underlying');
		final eregVar:String = '_re_$simple';
		eregByRule.set(typePath, {varName: eregVar, pattern: pattern});

		final decodeExpr:Expr = switch underlying {
			case 'Float': macro Std.parseFloat(_matched);
			case 'String': macro decodeJsonString(_matched);
			case _:
				Context.fatalError('Lowering: no decoder for underlying type "$underlying"', Context.currentPos());
				throw 'unreachable';
		};

		return macro {
			final _rest:String = ctx.input.substring(ctx.pos, ctx.input.length);
			if (!$i{eregVar}.match(_rest)) {
				throw new anyparse.runtime.ParseError(
					new anyparse.runtime.Span(ctx.pos, ctx.pos),
					$v{'expected $simple'}
				);
			}
			final _matched:String = $i{eregVar}.matched(0);
			ctx.pos += _matched.length;
			return $decodeExpr;
		};
	}

	// -------- helpers --------

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

	private static function simpleName(typePath:String):String {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? typePath : typePath.substring(idx + 1);
	}

	private static function packOf(typePath:String):Array<String> {
		final idx:Int = typePath.lastIndexOf('.');
		return idx == -1 ? [] : typePath.substring(0, idx).split('.');
	}
}
#end
