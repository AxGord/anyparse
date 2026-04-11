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

		// Case 4: single-arg ctor wrapping Array<Ref> with @:lead/@:trail and
		// optional @:sep. No-sep variant terminates the loop by peeking at
		// the close character instead of consuming a separator between items.
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
			final closeCharCode:Int = trailText.charCodeAt(0);
			final ctorCall:Expr = {expr: ECall(ctorRef, [macro _items]), pos: Context.currentPos()};
			if (sepText != null) {
				final sepCharCode:Int = sepText.charCodeAt(0);
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
			return macro {
				skipWs(ctx);
				expectLit(ctx, $v{leadText});
				final _items:Array<$elemCT> = [];
				skipWs(ctx);
				while (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
					_items.push($elemCall);
					skipWs(ctx);
				}
				skipWs(ctx);
				expectLit(ctx, $v{trailText});
				return $ctorCall;
			};
		}

		// Case 3 (extended): single-arg ctor wrapping a Ref, with optional
		// kw/lit lead and optional lit trail. No separator loop — that's
		// Case 4's domain. The lead can be either a `@:kw("...")` keyword
		// (word-boundary checked) or a plain `@:lead("...")` literal; only
		// one of the two is emitted per branch.
		if (litList == null && children.length == 1 && children[0].kind == Ref) {
			final refName:String = children[0].annotations.get('base.ref');
			final callSub:Expr = {
				expr: ECall(macro $i{'parse${simpleName(refName)}'}, [macro ctx]),
				pos: Context.currentPos(),
			};
			final ctorCall:Expr = {expr: ECall(ctorRef, [macro _raw]), pos: Context.currentPos()};
			final kwLead:Null<String> = branch.annotations.get('kw.leadText');
			final steps:Array<Expr> = [macro skipWs(ctx)];
			if (kwLead != null) {
				steps.push(macro expectKw(ctx, $v{kwLead}));
				steps.push(macro skipWs(ctx));
			} else if (leadText != null) {
				steps.push(macro expectLit(ctx, $v{leadText}));
				steps.push(macro skipWs(ctx));
			}
			steps.push({
				expr: EVars([{
					name: '_raw',
					type: null,
					expr: callSub,
					isFinal: true,
				}]),
				pos: Context.currentPos(),
			});
			if (trailText != null) {
				steps.push(macro skipWs(ctx));
				steps.push(macro expectLit(ctx, $v{trailText}));
			}
			steps.push(macro return $ctorCall);
			return macro $b{steps};
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
			// Per-field prefix: either @:kw (word-boundary checked) or @:lead.
			// Only one of the two is emitted; @:kw takes priority when both are
			// present on the same field (the compiler already catches duplicate
			// ownership at registration time so this is defensive only).
			//
			// For a Star field, the @:lead/@:trail pair semantically describes
			// the surrounding wrappers of the collection and is read directly
			// from the Star node's own `lit.*` annotations by
			// `emitStarFieldSteps`. Emitting them here too would produce
			// duplicate `expectLit` calls, so we skip struct-level lead/trail
			// emission whenever the field is a Star.
			final kwLead:Null<String> = readMetaString(child, ':kw');
			final leadText:Null<String> = readMetaString(child, ':lead');
			final trailText:Null<String> = readMetaString(child, ':trail');
			final isStar:Bool = child.kind == Star;
			if (!isStar) {
				if (kwLead != null) {
					parseSteps.push(macro skipWs(ctx));
					parseSteps.push(macro expectKw(ctx, $v{kwLead}));
				} else if (leadText != null) {
					parseSteps.push(macro skipWs(ctx));
					parseSteps.push(macro expectLit(ctx, $v{leadText}));
				}
			}
			// Field value — by kind.
			final localName:String = '_f_$fieldName';
			parseSteps.push(macro skipWs(ctx));
			switch child.kind {
				case Ref:
					final refName:String = child.annotations.get('base.ref');
					final callExpr:Expr = {
						expr: ECall(macro $i{'parse${simpleName(refName)}'}, [macro ctx]),
						pos: Context.currentPos(),
					};
					parseSteps.push({
						expr: EVars([{
							name: localName,
							type: null,
							expr: callExpr,
							isFinal: true,
						}]),
						pos: Context.currentPos(),
					});
				case Star:
					emitStarFieldSteps(child, localName, parseSteps);
				case _:
					Context.fatalError('Lowering: struct field kind ${child.kind} not supported', Context.currentPos());
			}
			// Per-field trail. Skipped for Star fields — `emitStarFieldSteps`
			// already emitted the close literal as part of the loop wrappers.
			if (!isStar && trailText != null) {
				parseSteps.push(macro skipWs(ctx));
				parseSteps.push(macro expectLit(ctx, $v{trailText}));
			}
			structFields.push({field: fieldName, expr: macro $i{localName}});
		}
		final structLiteral:Expr = {expr: EObjectDecl(structFields), pos: Context.currentPos()};
		parseSteps.push(macro return $structLiteral);
		return macro $b{parseSteps};
	}

	/**
	 * Emit the parse steps for a struct field of shape `Star<Ref>`. The
	 * Star node's own `lit.*` annotations carry the surrounding wrappers
	 * (`@:lead` open, `@:trail` close, optional `@:sep`). The accumulator
	 * is declared with the given `localName` so the enclosing `lowerStruct`
	 * can reference it in the final struct literal.
	 *
	 * Three termination modes are selected by the metadata on the Star
	 * node (see D22 in session_state.md):
	 *
	 *  - `@:trail("X")` **without** `@:sep` — loop terminates when the
	 *    next non-whitespace char is the close literal's first char.
	 *  - `@:trail("X")` **with** `@:sep(",")` — loop terminates when the
	 *    next char is not a separator. The first element is parsed only
	 *    when the next char is not already the close char (empty-list
	 *    case).
	 *  - No `@:trail` — loop terminates when `ctx.pos` reaches
	 *    `ctx.input.length`. Used by module-root Star fields where the
	 *    top level has no close delimiter. `@:sep` combined with no
	 *    `@:trail` is rejected at compile time because there is no
	 *    unambiguous way to stop the sep-peek loop at EOF.
	 */
	private function emitStarFieldSteps(starNode:ShapeNode, localName:String, parseSteps:Array<Expr>):Void {
		final inner:ShapeNode = starNode.children[0];
		if (inner.kind != Ref) {
			Context.fatalError('Lowering: Star struct field must contain a Ref', Context.currentPos());
		}
		final elemRefName:String = inner.annotations.get('base.ref');
		final elemFn:String = 'parse${simpleName(elemRefName)}';
		final elemCT:ComplexType = TPath({pack: packOf(elemRefName), name: simpleName(elemRefName), params: []});
		final elemCall:Expr = {
			expr: ECall(macro $i{elemFn}, [macro ctx]),
			pos: Context.currentPos(),
		};
		final openText:Null<String> = starNode.annotations.get('lit.leadText');
		final closeText:Null<String> = starNode.annotations.get('lit.trailText');
		final sepText:Null<String> = starNode.annotations.get('lit.sepText');
		if (closeText == null && sepText != null) {
			Context.fatalError('Lowering: Star struct field with @:sep requires an explicit @:trail close literal', Context.currentPos());
		}
		if (openText != null) {
			parseSteps.push(macro expectLit(ctx, $v{openText}));
			parseSteps.push(macro skipWs(ctx));
		}
		final accumCT:ComplexType = TPath({pack: [], name: 'Array', params: [TPType(elemCT)]});
		parseSteps.push({
			expr: EVars([{
				name: localName,
				type: accumCT,
				expr: macro [],
				isFinal: true,
			}]),
			pos: Context.currentPos(),
		});
		final accumRef:Expr = macro $i{localName};
		if (closeText == null) {
			parseSteps.push(macro {
				skipWs(ctx);
				while (ctx.pos < ctx.input.length) {
					$accumRef.push($elemCall);
					skipWs(ctx);
				}
			});
			return;
		}
		final closeCharCode:Int = closeText.charCodeAt(0);
		if (sepText != null) {
			final sepCharCode:Int = sepText.charCodeAt(0);
			parseSteps.push(macro {
				skipWs(ctx);
				if (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
					$accumRef.push($elemCall);
					skipWs(ctx);
					while (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) == $v{sepCharCode}) {
						ctx.pos++;
						skipWs(ctx);
						$accumRef.push($elemCall);
						skipWs(ctx);
					}
				}
			});
		} else {
			parseSteps.push(macro {
				skipWs(ctx);
				while (ctx.pos < ctx.input.length && ctx.input.charCodeAt(ctx.pos) != $v{closeCharCode}) {
					$accumRef.push($elemCall);
					skipWs(ctx);
				}
			});
		}
		parseSteps.push(macro skipWs(ctx));
		parseSteps.push(macro expectLit(ctx, $v{closeText}));
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

		// `@:rawString` on a String-underlying Terminal means "the regex
		// match is already the raw value" — skip the JSON-specific
		// unquote/unescape helper. Used for identifier-like terminals (Haxe
		// `HxIdentLit`) where the matched slice IS the identifier text. A
		// format-contributed decoder table will replace this closed switch
		// once a third Terminal type demands it (see D13 in session_state.md).
		// Named `@:rawString` (not bare `@:raw`) to avoid collision with
		// Haxe's built-in `@:raw` meta for verbatim code injection.
		final raw:Bool = hasMeta(node, ':rawString');
		final decodeExpr:Expr = switch underlying {
			case 'Float': macro Std.parseFloat(_matched);
			case 'String' if (raw): macro _matched;
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

	private static function hasMeta(node:ShapeNode, tag:String):Bool {
		final meta:Null<Metadata> = node.annotations.get('base.meta');
		if (meta == null) return false;
		for (entry in meta) if (entry.name == tag) return true;
		return false;
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
