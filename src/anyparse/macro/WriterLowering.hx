package anyparse.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.MacroStringTools;
import anyparse.core.ShapeTree;

/**
 * Pass 3W of the macro pipeline — writer lowering.
 *
 * Walks the shape tree and emits one `WriterRule` per type in the grammar.
 * Each rule's body builds a `Doc` value from the typed AST node.
 * This is the structural inverse of `Lowering`, which emits parse bodies
 * that consume input and build AST nodes.
 *
 * Generated code references `_dt`, `_dc`, `_dhl`, `_de` etc. — thin
 * wrappers over `Doc` constructors emitted by `WriterCodegen` on the
 * same class. This avoids direct enum constructor calls in `macro {}`
 * blocks, which trigger macro-time type checking.
 */
class WriterLowering {

	private final shape:ShapeBuilder.ShapeResult;
	private final formatInfo:FormatReader.FormatInfo;

	public function new(shape:ShapeBuilder.ShapeResult, formatInfo:FormatReader.FormatInfo) {
		this.shape = shape;
		this.formatInfo = formatInfo;
	}

	public function generate():Array<WriterRule> {
		final rules:Array<WriterRule> = [];
		for (typePath => node in shape.rules) for (rule in lowerRule(typePath, node)) rules.push(rule);
		return rules;
	}

	private function lowerRule(typePath:String, node:ShapeNode):Array<WriterRule> {
		final simple:String = simpleName(typePath);
		final fnName:String = 'write$simple';
		final valueCT:ComplexType = TPath({pack: packOf(typePath), name: simple, params: []});

		final hasPratt:Bool = node.kind == Alt && (hasPrattBranch(node) || hasPostfixBranch(node));

		final body:Expr = switch node.kind {
			case Alt: lowerEnum(node, typePath, hasPratt);
			case Seq: lowerStruct(node, typePath);
			case Terminal: lowerTerminal(node, typePath, simple);
			case _:
				Context.fatalError('WriterLowering: cannot lower ${node.kind} for $typePath', Context.currentPos());
				throw 'unreachable';
		};
		return [{fnName: fnName, valueCT: valueCT, body: body, hasCtxPrec: hasPratt, isBinary: false}];
	}

	// -------- enum rule --------

	private function lowerEnum(node:ShapeNode, typePath:String, hasPratt:Bool):Expr {
		final simple:String = simpleName(typePath);
		final writeFnName:String = 'write$simple';

		// Compute PREC_POSTFIX for Pratt enums: max(all prec values) + 1
		var precPostfix:Int = 0;
		if (hasPratt) {
			for (b in node.children) {
				final p:Null<Int> = b.annotations.get('pratt.prec');
				if (p != null && p > precPostfix) precPostfix = p;
				final tp:Null<Int> = b.annotations.get('ternary.prec');
				if (tp != null && tp > precPostfix) precPostfix = tp;
			}
			precPostfix++;
		}

		final cases:Array<Case> = [];
		for (branch in node.children) {
			final ctor:String = branch.annotations.get('base.ctor');
			final children:Array<ShapeNode> = branch.children;
			final argNames:Array<String> = [for (i in 0...children.length) '_v$i'];

			// Build pattern
			final ctorPath:Array<String> = packOf(typePath).concat([simple, ctor]);
			final ctorRef:Expr = MacroStringTools.toFieldExpr(ctorPath);
			final pattern:Expr = if (children.length == 0) ctorRef
			else {
				final argExprs:Array<Expr> = [for (name in argNames) macro $i{name}];
				{expr: ECall(ctorRef, argExprs), pos: Context.currentPos()};
			};

			// Build body
			final body:Expr = lowerEnumBranch(branch, typePath, writeFnName, hasPratt, argNames, precPostfix);
			cases.push({values: [pattern], expr: body, guard: null});
		}
		return macro return ${{expr: ESwitch(macro value, cases, null), pos: Context.currentPos()}};
	}

	private function lowerEnumBranch(
		branch:ShapeNode, typePath:String, writeFnName:String,
		hasPratt:Bool, argNames:Array<String>, precPostfix:Int
	):Expr {
		final children:Array<ShapeNode> = branch.children;
		final litList:Null<Array<String>> = branch.annotations.get('lit.litList');
		final leadText:Null<String> = branch.annotations.get('lit.leadText');
		final trailText:Null<String> = branch.annotations.get('lit.trailText');
		final kwLead:Null<String> = branch.annotations.get('kw.leadText');

		final prefixOp:Null<String> = branch.annotations.get('prefix.op');
		final postfixOp:Null<String> = branch.annotations.get('postfix.op');
		final postfixClose:Null<String> = branch.annotations.get('postfix.close');
		final prattPrec:Null<Int> = branch.annotations.get('pratt.prec');
		final prattAssoc:Null<String> = branch.annotations.get('pratt.assoc');
		final ternaryOp:Null<String> = branch.annotations.get('ternary.op');
		final ternaryPrec:Null<Int> = branch.annotations.get('ternary.prec');
		final ternarySep:Null<String> = branch.annotations.get('ternary.sep');

		// ---- Ternary ----
		if (ternaryOp != null) {
			final tPrec:Int = (ternaryPrec : Int);
			final sep:String = (ternarySep : String);
			final condCall:Expr = makeWriteCall(writeFnName, macro $i{argNames[0]}, hasPratt, tPrec + 1);
			final middleCall:Expr = makeWriteCall(writeFnName, macro $i{argNames[1]}, hasPratt, -1);
			final rightCall:Expr = makeWriteCall(writeFnName, macro $i{argNames[2]}, hasPratt, -1);
			final opWithSpaces:String = ' ' + ternaryOp + ' ';
			final sepWithSpaces:String = ' ' + sep + ' ';
			return macro {
				final _inner:anyparse.core.Doc = _dc([
					$condCall, _dt($v{opWithSpaces}),
					$middleCall, _dt($v{sepWithSpaces}),
					$rightCall,
				]);
				if ($v{tPrec} < ctxPrec) _dc([_dt('('), _inner, _dt(')')]) else _inner;
			};
		}

		// ---- Infix ----
		if (prattPrec != null) {
			final prec:Int = (prattPrec : Int);
			final assoc:String = prattAssoc ?? 'Left';
			final opText:String = getOperatorText(branch);
			final leftCtx:Int = assoc == 'Right' ? prec + 1 : prec;
			final rightCtx:Int = assoc == 'Right' ? prec : prec + 1;
			final opWithSpaces:String = ' ' + opText + ' ';
			final leftCall:Expr = makeWriteCall(writeFnName, macro $i{argNames[0]}, hasPratt, leftCtx);
			final rightCall:Expr = makeWriteCall(writeFnName, macro $i{argNames[1]}, hasPratt, rightCtx);
			return macro {
				final _inner:anyparse.core.Doc = _dc([
					$leftCall, _dt($v{opWithSpaces}), $rightCall,
				]);
				if ($v{prec} < ctxPrec) _dc([_dt('('), _inner, _dt(')')]) else _inner;
			};
		}

		// ---- Prefix ----
		if (prefixOp != null) {
			final operandCall:Expr = makeWriteCall(writeFnName, macro $i{argNames[0]}, hasPratt, precPostfix);
			return macro _dc([_dt($v{prefixOp}), $operandCall]);
		}

		// ---- Postfix ----
		if (postfixOp != null) {
			final operandCall:Expr = makeWriteCall(writeFnName, macro $i{argNames[0]}, hasPratt, precPostfix);
			if (children.length == 1) {
				final text:String = postfixOp + (postfixClose ?? '');
				return macro _dc([$operandCall, _dt($v{text})]);
			}
			if (children.length == 2 && children[1].kind == Star)
				return lowerPostfixStar(branch, typePath, writeFnName, hasPratt, argNames, operandCall);
			if (children.length == 2) {
				final suffixRef:String = children[1].annotations.get('base.ref');
				final suffixFn:String = 'write${simpleName(suffixRef)}';
				final suffixCall:Expr = {
					expr: ECall(macro $i{suffixFn}, [macro $i{argNames[1]}, macro opt]),
					pos: Context.currentPos(),
				};
				final close:String = postfixClose ?? '';
				if (close.length > 0)
					return macro _dc([$operandCall, _dt($v{postfixOp}), $suffixCall, _dt($v{close})]);
				return macro _dc([$operandCall, _dt($v{postfixOp}), $suffixCall]);
			}
			Context.fatalError('WriterLowering: unsupported postfix shape', Context.currentPos());
			throw 'unreachable';
		}

		// ---- Case 0: zero-arg kw ----
		if (kwLead != null && children.length == 0 && litList == null) {
			final trail:Null<String> = branch.annotations.get('lit.trailText');
			final text:String = kwLead + (trail ?? '');
			return macro _dt($v{text});
		}

		// ---- Case 1: zero-arg lit ----
		if (litList != null && litList.length == 1 && children.length == 0)
			return macro _dt($v{litList[0]});

		// ---- Case 2: multi-lit Bool ----
		if (litList != null && litList.length > 1 && children.length == 1) {
			final trueLit:String = litList[0];
			final falseLit:String = litList[1];
			return macro if (_v0) _dt($v{trueLit}) else _dt($v{falseLit});
		}

		// ---- Case 4: single-arg Star with lead/trail ----
		if (leadText != null && trailText != null && children.length == 1 && children[0].kind == Star)
			return lowerEnumStar(branch, typePath, writeFnName, hasPratt, argNames);

		// ---- Case 3: single-arg Ref ----
		if (litList == null && children.length == 1 && children[0].kind == Ref) {
			final refName:String = children[0].annotations.get('base.ref');
			final subFn:String = 'write${simpleName(refName)}';
			final isSelfRef:Bool = simpleName(refName) == simpleName(typePath);
			final subCall:Expr = if (isSelfRef && hasPratt)
				{expr: ECall(macro $i{subFn}, [macro $i{argNames[0]}, macro opt, macro -1]), pos: Context.currentPos()}
			else
				{expr: ECall(macro $i{subFn}, [macro $i{argNames[0]}, macro opt]), pos: Context.currentPos()};

			// When the sub-struct opens with a bare-Ref @:bodyPolicy field,
			// the sub-struct's writer emits the header→body separator via
			// bodyPolicyWrap (Same/Next/FitLine). Stripping the trailing
			// space from kwLead here avoids a double space (Same) or
			// trailing-space-before-hardline (Next/FitLine). Non-policy
			// sub-structs keep the pre-ψ₅ `kw ` shape.
			final stripKwTrailingSpace:Bool = subStructStartsWithBodyPolicy(refName);
			final parts:Array<Expr> = [];
			if (kwLead != null) {
				final kwText:String = stripKwTrailingSpace ? kwLead : kwLead + ' ';
				parts.push(macro _dt($v{kwText}));
			}
			if (leadText != null) parts.push(macro _dt($v{leadText}));
			parts.push(subCall);
			if (trailText != null) parts.push(macro _dt($v{trailText}));
			return if (parts.length == 1) parts[0]
			else dcCall(parts);
		}

		Context.fatalError('WriterLowering: unsupported enum branch shape for ${simpleName(typePath)}', Context.currentPos());
		throw 'unreachable';
	}

	/** Postfix Star-suffix form: `Call(operand, args:Array<T>)`. */
	private function lowerPostfixStar(
		branch:ShapeNode, typePath:String, writeFnName:String,
		hasPratt:Bool, argNames:Array<String>, operandCall:Expr
	):Expr {
		final postfixOp:String = branch.annotations.get('postfix.op');
		final postfixClose:String = branch.annotations.get('postfix.close') ?? '';
		final starNode:ShapeNode = branch.children[1];
		final inner:ShapeNode = starNode.children[0];
		final elemRefName:String = inner.annotations.get('base.ref');
		final isSelfRef:Bool = simpleName(elemRefName) == simpleName(typePath);
		final elemFn:String = isSelfRef ? writeFnName : 'write${simpleName(elemRefName)}';
		final elemSep:String = branch.annotations.get('lit.sepText') ?? ',';

		final elemCallArgs:Array<Expr> = [macro _args[_i], macro opt];
		if (isSelfRef && hasPratt) elemCallArgs.push(macro -1);
		final elemCall:Expr = {
			expr: ECall(macro $i{elemFn}, elemCallArgs),
			pos: Context.currentPos(),
		};

		final argsAccess:Expr = macro $i{argNames[1]};
		final tcExpr:Expr = trailingCommaExpr(branch);
		return macro {
			final _args = $argsAccess;
			final _docs:Array<anyparse.core.Doc> = [];
			var _i:Int = 0;
			while (_i < _args.length) {
				_docs.push($elemCall);
				_i++;
			}
			_dc([$operandCall, sepList($v{postfixOp}, $v{postfixClose}, $v{elemSep}, _docs, opt, $tcExpr)]);
		};
	}

	/** Enum Case 4 Star: `@:lead @:trail` with optional `@:sep`. */
	private function lowerEnumStar(
		branch:ShapeNode, typePath:String, writeFnName:String,
		hasPratt:Bool, argNames:Array<String>
	):Expr {
		final leadText:String = branch.annotations.get('lit.leadText');
		final trailText:String = branch.annotations.get('lit.trailText');
		final sepText:Null<String> = branch.annotations.get('lit.sepText');
		final kwLead:Null<String> = branch.annotations.get('kw.leadText');
		final starNode:ShapeNode = branch.children[0];
		final inner:ShapeNode = starNode.children[0];
		final elemRefName:String = inner.annotations.get('base.ref');
		final isSelfRef:Bool = simpleName(elemRefName) == simpleName(typePath);
		final elemFn:String = isSelfRef ? writeFnName : 'write${simpleName(elemRefName)}';

		final elemCallArgs:Array<Expr> = [macro _args[_i], macro opt];
		if (isSelfRef && hasPratt) elemCallArgs.push(macro -1);
		final elemCall:Expr = {
			expr: ECall(macro $i{elemFn}, elemCallArgs),
			pos: Context.currentPos(),
		};

		final argsAccess:Expr = macro $i{argNames[0]};
		final parts:Array<Expr> = [];
		if (kwLead != null) parts.push(macro _dt($v{kwLead + ' '}));

		if (sepText != null) {
			final tcExpr:Expr = trailingCommaExpr(branch);
			parts.push(macro {
				final _args = $argsAccess;
				final _docs:Array<anyparse.core.Doc> = [];
				var _i:Int = 0;
				while (_i < _args.length) {
					_docs.push($elemCall);
					_i++;
				}
				sepList($v{leadText}, $v{trailText}, $v{sepText}, _docs, opt, $tcExpr);
			});
		} else {
			parts.push(macro {
				final _args = $argsAccess;
				final _docs:Array<anyparse.core.Doc> = [];
				var _i:Int = 0;
				while (_i < _args.length) {
					_docs.push($elemCall);
					_i++;
				}
				blockBody($v{leadText}, $v{trailText}, _docs, opt);
			});
		}
		return if (parts.length == 1) parts[0]
		else dcCall(parts);
	}

	// -------- struct rule --------

	private function lowerStruct(node:ShapeNode, typePath:String):Expr {
		final isRaw:Bool = hasMeta(node, ':raw');
		final parts:Array<Expr> = [];
		var isFirstField:Bool = true;
		// Tracks the immediately preceding field when it was a bare
		// try-parse Star (no lead/trail/sep) that may produce no output
		// at runtime. A following bare Ref field must then gate its
		// leading separator on `prevField.length > 0` — otherwise the
		// space is emitted even when the Star contributed nothing,
		// yielding e.g. `\t function` instead of `\tfunction` when
		// `HxMemberDecl.modifiers` is empty.
		var prevEmptyCandidate:Null<Expr> = null;
		// ψ₉: tracks the immediately preceding bare-Ref field that was
		// wrapped via `bodyPolicyWrap` — the next field's `@:sameLine`
		// separator must then be shape-aware on the preceding body's
		// runtime ctor: a block ctor (e.g. `BlockStmt`) respects the
		// flag (space / hardline), any other ctor forces a hardline
		// because a lone keyword on the same line as a semicolon-
		// terminated body has no meaning.
		var prevBodyField:Null<PrevBodyInfo> = null;

		for (child in node.children) {
			final fieldName:Null<String> = child.annotations.get('base.fieldName');
			if (fieldName == null)
				Context.fatalError('WriterLowering: struct field missing base.fieldName', Context.currentPos());
			final kwLead:Null<String> = readMetaString(child, ':kw');
			final leadText:Null<String> = readMetaString(child, ':lead');
			final trailText:Null<String> = readMetaString(child, ':trail');
			final isStar:Bool = child.kind == Star;
			final isOptional:Bool = child.annotations.get('base.optional') == true;
			final hasElseIf:Bool = hasMeta(child, ':elseIf');

			final fieldAccess:Expr = {
				expr: EField(macro value, fieldName),
				pos: Context.currentPos(),
			};

			if (isStar) {
				emitWriterStarField(child, fieldAccess, parts, child == node.children[node.children.length - 1], typePath, isFirstField, isRaw);
				prevEmptyCandidate = isBareTryparseStar(child) ? fieldAccess : null;
				prevBodyField = null;
				isFirstField = false;
				continue;
			}

			// D61: kw prefix — space before kw (unless first), kw text with trailing space.
			// @:sameLine(flagName) on the child switches the leading space to a
			// hardline when `opt.<flagName>` is false (τ₁).
			if (kwLead != null && !isOptional) {
				if (!isFirstField && !isRaw) parts.push(sameLineSeparator(child, prevBodyField));
				parts.push(macro _dt($v{kwLead + ' '}));
			}

			// D61: non-optional lead — no space before lead.
			// ψ₇: `@:objectFieldColon` on the field switches the emission
			// to a runtime-configurable spacing around the lead text; all
			// other mandatory leads stay tight.
			if (leadText != null && !isOptional)
				parts.push(objectFieldColonLead(child, leadText));

			// Field value
			final bodyPolicyFlag:Null<String> = readMetaString(child, ':bodyPolicy');
			var justWrappedBody:Null<PrevBodyInfo> = null;
			switch child.kind {
				case Ref if (isOptional):
					final refName:String = child.annotations.get('base.ref');
					final writeFn:String = 'write${simpleName(refName)}';
					final writeCall:Expr = {
						expr: ECall(macro $i{writeFn}, [macro _optVal, macro opt]),
						pos: Context.currentPos(),
					};
					// Leading separator is runtime-conditional when @:sameLine
					// is present — see sameLineSeparator. Split into (sep, kw+' ')
					// so the sep part can become a hardline (τ₁).
					// @:bodyPolicy replaces the final ' ' before the body with
					// a runtime-switched separator (Same/Next/FitLine, ψ₄).
					final optParts:Array<Expr> = [];
					if (kwLead != null) {
						optParts.push(sameLineSeparator(child, prevBodyField));
						if (bodyPolicyFlag != null) {
							optParts.push(macro _dt($v{kwLead}));
							optParts.push(bodyPolicyWrap(bodyPolicyFlag, writeCall, macro _optVal, refName, hasElseIf));
						} else {
							optParts.push(macro _dt($v{kwLead + ' '}));
							optParts.push(writeCall);
						}
					} else if (leadText != null) {
						if (isTightLead(leadText)) {
							optParts.push(macro _dt($v{leadText}));
						} else {
							optParts.push(sameLineSeparator(child, prevBodyField));
							optParts.push(macro _dt($v{leadText + ' '}));
						}
						optParts.push(writeCall);
					} else {
						optParts.push(writeCall);
					}
					final optBody:Expr = if (optParts.length == 1) optParts[0]
					else dcCall(optParts);
					parts.push(macro {
						final _optVal = $fieldAccess;
						if (_optVal != null) $optBody else _de();
					});

				case Ref:
					final refName:String = child.annotations.get('base.ref');
					final writeFn:String = 'write${simpleName(refName)}';
					final writeCall:Expr = {
						expr: ECall(macro $i{writeFn}, [fieldAccess, macro opt]),
						pos: Context.currentPos(),
					};
					// bodyPolicy on a first field: the parent enum-branch
					// Case 3 strips its kwLead trailing space so the
					// separator here is the sole transition token. Non-
					// first-field case (HxIfStmt.thenBody after cond's
					// `)` trail): the trail emits the token literally and
					// bodyPolicyWrap replaces the default ` ` separator.
					if (bodyPolicyFlag != null && kwLead == null && leadText == null && !isRaw) {
						parts.push(bodyPolicyWrap(bodyPolicyFlag, writeCall, fieldAccess, refName, hasElseIf));
						justWrappedBody = {access: fieldAccess, typePath: refName};
					} else {
						if (kwLead == null && leadText == null && !isFirstField && !isRaw) {
							if (prevEmptyCandidate != null)
								parts.push(macro ($prevEmptyCandidate.length > 0) ? _dt(' ') : _de());
							else
								parts.push(macro _dt(' '));
						}
						parts.push(writeCall);
					}

				case _:
					Context.fatalError('WriterLowering: struct field kind ${child.kind} not supported', Context.currentPos());
			}

			// Trail
			if (!isOptional && trailText != null)
				parts.push(macro _dt($v{trailText}));

			prevEmptyCandidate = null;
			prevBodyField = justWrappedBody;
			isFirstField = false;
		}

		final dcExpr:Expr = dcCall(parts);
		return macro return $dcExpr;
	}

	/** Emit writer steps for a Star struct field. */
	private function emitWriterStarField(
		starNode:ShapeNode, fieldAccess:Expr, parts:Array<Expr>,
		isLastField:Bool, typePath:String, isFirstField:Bool, isRaw:Bool
	):Void {
		final inner:ShapeNode = starNode.children[0];
		if (inner.kind != Ref)
			Context.fatalError('WriterLowering: Star struct field must contain a Ref', Context.currentPos());

		final elemRefName:String = inner.annotations.get('base.ref');
		final elemFn:String = 'write${simpleName(elemRefName)}';
		final openText:Null<String> = starNode.annotations.get('lit.leadText');
		final closeText:Null<String> = starNode.annotations.get('lit.trailText');
		final sepText:Null<String> = starNode.annotations.get('lit.sepText');

		final elemCall:Expr = {
			expr: ECall(macro $i{elemFn}, [macro _arr[_si], macro opt]),
			pos: Context.currentPos(),
		};

		// @:raw types (string content): concatenate items with no whitespace,
		// wrapping in lead/trail if present. No block/sep layout.
		if (isRaw && closeText != null && sepText == null) {
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs:Array<anyparse.core.Doc> = [_dt($v{openText ?? ''})];
				var _si:Int = 0;
				while (_si < _arr.length) {
					_docs.push($elemCall);
					_si++;
				}
				_docs.push(_dt($v{closeText}));
				_dc(_docs);
			});
			return;
		}

		if (closeText != null && sepText != null) {
			if (!isFirstField && !isRaw && isSpacedLead(openText)) parts.push(macro _dt(' '));
			final tcExpr:Expr = trailingCommaExpr(starNode);
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs:Array<anyparse.core.Doc> = [];
				var _si:Int = 0;
				while (_si < _arr.length) {
					_docs.push($elemCall);
					_si++;
				}
				sepList($v{openText ?? ''}, $v{closeText}, $v{sepText}, _docs, opt, $tcExpr);
			});
		} else if (closeText != null) {
			if (!isFirstField && !isRaw && isSpacedLead(openText)) parts.push(leftCurlySeparator(starNode));
			parts.push(macro {
				final _arr = $fieldAccess;
				final _docs:Array<anyparse.core.Doc> = [];
				var _si:Int = 0;
				while (_si < _arr.length) {
					_docs.push($elemCall);
					_si++;
				}
				blockBody($v{openText ?? '{'}, $v{closeText}, _docs, opt);
			});
		} else if (!isLastField || hasMeta(starNode, ':tryparse')) {
			// Try-parse mode. Emit lead if present (e.g. ':' in default:).
			if (openText != null)
				parts.push(macro _dt($v{openText}));
			final sameLineName:Null<String> = readMetaString(starNode, ':sameLine');
			if (sameLineName != null) {
				// @:sameLine on a try-parse Star: each element is preceded by
				// a runtime-conditional separator (space or hardline), so the
				// first element's leading separator acts as the boundary with
				// the preceding struct field (τ₁ — catches against try body).
				final optFlag:Expr = {
					expr: EField(macro opt, sameLineName),
					pos: Context.currentPos(),
				};
				parts.push(macro {
					final _arr = $fieldAccess;
					final _docs:Array<anyparse.core.Doc> = [];
					var _si:Int = 0;
					while (_si < _arr.length) {
						_docs.push(($optFlag) ? _dt(' ') : _dhl());
						_docs.push($elemCall);
						_si++;
					}
					_dc(_docs);
				});
			} else {
				parts.push(macro {
					final _arr = $fieldAccess;
					final _docs:Array<anyparse.core.Doc> = [];
					var _si:Int = 0;
					while (_si < _arr.length) {
						_docs.push($elemCall);
						if (_si < _arr.length - 1) _docs.push(_dt(' '));
						_si++;
					}
					_dc(_docs);
				});
			}
		} else {
			// EOF mode. Emit lead if present.
			if (openText != null)
				parts.push(macro _dt($v{openText}));
			parts.push(macro {
				final _arr = $fieldAccess;
				if (_arr.length == 0) _de()
				else {
					final _docs:Array<anyparse.core.Doc> = [];
					var _si:Int = 0;
					while (_si < _arr.length) {
						if (_si > 0) {
							_docs.push(_dhl());
							_docs.push(_dhl());
						}
						_docs.push($elemCall);
						_si++;
					}
					_dc(_docs);
				}
			});
		}
	}

	// -------- terminal rule --------

	private function lowerTerminal(node:ShapeNode, typePath:String, simple:String):Expr {
		final underlying:String = node.annotations.get('base.underlying');
		final unescape:Bool = hasMeta(node, ':unescape');
		final unescapeMode:Null<String> = readMetaString(node, ':unescape');
		final raw:Bool = hasMeta(node, ':rawString');

		if (unescape) {
			if (unescapeMode == 'raw') {
				// @:unescape("raw"): escape without wrapping in quotes.
				// Cast abstract to String for field access.
				final fmtParts:Array<String> = formatInfo.schemaTypePath.split('.');
				return macro {
					final _s:String = (cast value : String);
					final _buf:StringBuf = new StringBuf();
					var _ci:Int = 0;
					while (_ci < _s.length) {
						final _c:Null<Int> = _s.charCodeAt(_ci);
						if (_c != null) _buf.add($p{fmtParts}.instance.escapeChar(_c));
						_ci++;
					}
					return _dt(_buf.toString());
				};
			}
			// @:unescape (bare): wrap in "..." and escape
			return macro return _dt(escapeString(value));
		}

		if (raw) return macro return _dt(value);

		return switch underlying {
			case 'Float': macro return _dt(formatFloat(value));
			case 'Int': macro return _dt(Std.string(value));
			case 'Bool': macro return _dt(value ? 'true' : 'false');
			case 'String': macro return _dt(value);
			case _:
				Context.fatalError('WriterLowering: no encoder for underlying type "$underlying"', Context.currentPos());
				throw 'unreachable';
		};
	}

	// -------- helpers --------

	/**
	 * Return a Doc-separator expression for the whitespace that precedes
	 * a struct-field's kw/lead token.
	 *
	 * Without `@:sameLine` metadata, emits a plain space (`_dt(' ')`) —
	 * the existing D61 behaviour. With `@:sameLine("flagName")`, emits a
	 * ternary that picks between a plain space and a hardline at the
	 * current indent level based on `opt.<flagName>:Bool`.
	 *
	 * ψ₉ opt-in shape-awareness via `@:shapeAware`: when the field also
	 * carries the `@:shapeAware` meta AND `prevBody` is non-null (the
	 * immediately preceding struct field was a bare-Ref wrapped via
	 * `bodyPolicyWrap`) AND the body's enum type has at least one block
	 * ctor, the emitted separator adds a runtime ctor switch on the
	 * preceding body's value: block ctors keep the flag-based layout
	 * (space / hardline), every other ctor forces a hardline. Used by
	 * `HxIfStmt.elseBody` where a lone `else` on the same line as a
	 * semicolon-terminated thenBody would collide visually with the
	 * body's terminator. NOT used by `HxDoWhileStmt.cond`'s `while`
	 * or `HxTryCatchStmt.catches` — those keywords are part of the
	 * loop/try structure and stay inline regardless of body shape,
	 * matching haxe-formatter's `sameLine.doWhile`/`tryCatch` defaults.
	 *
	 * Consumed by the two struct-field sites (non-optional kw, optional
	 * Ref/lead) that previously hard-coded `' '` as the boundary
	 * between a field and the preceding token. The try-parse Star
	 * `@:sameLine` site in `emitWriterStarField` has its own inline
	 * handler (per-element separator, different semantic) and is
	 * unaffected.
	 */
	private function sameLineSeparator(child:ShapeNode, prevBody:Null<PrevBodyInfo>):Expr {
		final flagName:Null<String> = readMetaString(child, ':sameLine');
		if (flagName == null) return macro _dt(' ');
		final optFlag:Expr = {
			expr: EField(macro opt, flagName),
			pos: Context.currentPos(),
		};
		final flagBased:Expr = macro (($optFlag) ? _dt(' ') : _dhl());
		if (prevBody == null || !hasMeta(child, ':shapeAware')) return flagBased;
		final blockPatterns:Array<Expr> = collectBlockCtorPatterns(prevBody.typePath);
		if (blockPatterns.length == 0) return flagBased;
		final cases:Array<Case> = [
			{values: blockPatterns, expr: flagBased, guard: null},
			{values: [macro _], expr: macro _dhl(), guard: null},
		];
		return {expr: ESwitch(prevBody.access, cases, null), pos: Context.currentPos()};
	}

	/**
	 * Return a Doc-separator expression for the whitespace that precedes
	 * a Star struct field's opening `{`.
	 *
	 * Without `@:leftCurly` metadata, emits a plain space (`_dt(' ')`) —
	 * the existing pre-ψ₆ behaviour. With `@:leftCurly` present (no
	 * argument), emits a switch that picks between `_dhl()` (hardline
	 * at the current indent, placing `{` on its own line) and
	 * `_dt(' ')` based on `opt.leftCurly:BracePlacement`. The knob
	 * field name is hard-coded because haxe-formatter's `lineEnds.
	 * leftCurly` is a single global knob and every tagged grammar site
	 * maps to the same runtime option. Per-category overrides would
	 * add their own metas (`@:typeBrace` / `@:blockBrace` / …) with
	 * their own knob fields, keeping each meta tied to exactly one
	 * option field.
	 *
	 * The `Next` pattern is built as a raw `EField` expression to avoid
	 * macro-time enum resolution against the `BracePlacement` abstract
	 * (same precedent as `bodyPolicyWrap`). Everything other than
	 * `Next` (currently only `Same`) falls through to the default case
	 * and keeps the space — additional placements can be routed here
	 * by adding more cases.
	 */
	private static function leftCurlySeparator(starNode:ShapeNode):Expr {
		if (!hasMeta(starNode, ':leftCurly')) return macro _dt(' ');
		final nextPat:Expr = MacroStringTools.toFieldExpr(['anyparse', 'format', 'BracePlacement', 'Next']);
		final cases:Array<Case> = [
			{values: [nextPat], expr: macro _dhl(), guard: null},
		];
		return {expr: ESwitch(macro opt.leftCurly, cases, macro _dt(' ')), pos: Context.currentPos()};
	}

	/**
	 * Return a Doc expression for a mandatory `@:lead(text)` whose field
	 * carries the `@:objectFieldColon` writer meta (ψ₇).
	 *
	 * Without the meta — plain `_dt(leadText)`, matching the pre-ψ₇
	 * behaviour of the mandatory-lead path: the lead is emitted tight
	 * against the preceding and following fields (`foo:bar`), so
	 * type-annotation colons on `HxVarDecl.type` / `HxParam.type` /
	 * `HxFnDecl.returnType` stay as `x:Int` / `f():Void`.
	 *
	 * With the meta — a runtime switch on `opt.objectFieldColon:
	 * WhitespacePolicy` that picks a pre-concatenated lead string:
	 *  - `Before` → `_dt(' ' + leadText)` (space before only).
	 *  - `After`  → `_dt(leadText + ' ')` (space after only, the default
	 *               for Haxe — matches haxe-formatter's
	 *               `whitespace.objectFieldColonPolicy: @:default(After)`).
	 *  - `Both`   → `_dt(' ' + leadText + ' ')` (space on both sides).
	 *  - `None`   → default case, `_dt(leadText)` (tight).
	 *
	 * Pre-concatenating the text into a single `_dt` (instead of three
	 * separate Doc atoms) keeps the output identical to the pre-ψ₇ byte
	 * layout for the `None` case and avoids introducing any new Doc
	 * boundaries the Renderer might break across.
	 *
	 * The case patterns are built as raw `EField` expressions to avoid
	 * macro-time enum resolution against the `WhitespacePolicy` abstract
	 * (same precedent as `bodyPolicyWrap` and `leftCurlySeparator`).
	 *
	 * The meta tag is consumed field-scope only — sibling mandatory
	 * leads on the same struct are unaffected. Adding a per-knob meta
	 * like this one (instead of a global `@:colon(flag)` with multiple
	 * flag values) follows the ψ₆ principle: one meta = one options
	 * field. If future slices need a different `:` spacing at another
	 * grammar site, that site will get its own tag (e.g. `@:switchCaseColon`)
	 * with its own `HxModuleWriteOptions` field.
	 */
	private static function objectFieldColonLead(child:ShapeNode, leadText:String):Expr {
		if (!hasMeta(child, ':objectFieldColon')) return macro _dt($v{leadText});
		final wpPath:Array<String> = ['anyparse', 'format', 'WhitespacePolicy'];
		final beforePat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Before']));
		final afterPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['After']));
		final bothPat:Expr = MacroStringTools.toFieldExpr(wpPath.concat(['Both']));
		final cases:Array<Case> = [
			{values: [beforePat], expr: macro _dt($v{' ' + leadText}), guard: null},
			{values: [afterPat], expr: macro _dt($v{leadText + ' '}), guard: null},
			{values: [bothPat], expr: macro _dt($v{' ' + leadText + ' '}), guard: null},
		];
		return {expr: ESwitch(macro opt.objectFieldColon, cases, macro _dt($v{leadText})), pos: Context.currentPos()};
	}

	/**
	 * Build a Doc expression that wraps a bare-Ref body field with a
	 * runtime-switched separator driven by `@:bodyPolicy("flagName")`.
	 *
	 * Reads `opt.<flagName>:BodyPolicy` and dispatches:
	 *  - `Same`    → `_dc([_dt(' '), body])` — body on the same line,
	 *                separated by a single space (current behaviour).
	 *  - `Next`    → `_dn(cols, _dc([_dhl(), body]))` — body on the
	 *                next line at one indent level deeper.
	 *  - `FitLine` → `_dg(_dn(cols, _dc([_dl(), body])))` — Group lets
	 *                the renderer pick flat (space + body) or break
	 *                (hardline + indent + body) based on `lineWidth`.
	 *
	 * `cols` is derived from the same `indentChar`/`indentSize`/
	 * `tabWidth` triple as `blockBody`, so one-level body indent matches
	 * a `{}` block's nesting depth.
	 *
	 * Block-bodied values bypass the policy: when `bodyTypePath` is an
	 * enum whose branches carry `@:lead(openText) @:trail(closeText)` on
	 * a single Star child (the characteristic of a `blockBody`-rendered
	 * constructor, e.g. `BlockStmt(@:lead('{') @:trail('}'))`), an outer
	 * runtime `switch` routes those ctors to a single-space layout —
	 * matching haxe-formatter's convention that `{ … }` stays on the
	 * same line as `do` / `if` / `while` / `for` regardless of the
	 * placement knob. This keeps policy targeted at the non-block
	 * expression-body case where the knob actually shifts layout.
	 *
	 * ψ₈: when `hasElseIf` is true, an additional outer-switch case is
	 * added for the `IfStmt` ctor of `bodyTypePath` that routes to
	 * `opt.elseIf:KeywordPlacement` — `Same` keeps `else if (...)`
	 * inline (single space + body) while `Next` moves the nested `if`
	 * to the next line (hardline + indent + body). This override runs
	 * regardless of the field's own `@:bodyPolicy` flag value, so
	 * `elseBody=Next` with `elseIf=Same` still emits `} else if (...)`
	 * on one line for nested ifs and only pushes non-if else branches
	 * to the next line.
	 *
	 * The case patterns are built as raw `EField` expressions to avoid
	 * macro-time enum resolution against the `BodyPolicy` abstract.
	 */
	private function bodyPolicyWrap(
		flagName:String, writeCall:Expr, bodyValueExpr:Expr, bodyTypePath:String, hasElseIf:Bool
	):Expr {
		final optFlag:Expr = {
			expr: EField(macro opt, flagName),
			pos: Context.currentPos(),
		};
		final bpPath:Array<String> = ['anyparse', 'format', 'BodyPolicy'];
		final samePat:Expr = MacroStringTools.toFieldExpr(bpPath.concat(['Same']));
		final nextPat:Expr = MacroStringTools.toFieldExpr(bpPath.concat(['Next']));
		final fitPat:Expr = MacroStringTools.toFieldExpr(bpPath.concat(['FitLine']));
		final policyCases:Array<Case> = [
			{values: [samePat], expr: macro _dc([_dt(' '), $writeCall]), guard: null},
			{values: [nextPat], expr: macro _dn(_cols, _dc([_dhl(), $writeCall])), guard: null},
			{values: [fitPat], expr: macro _dg(_dn(_cols, _dc([_dl(), $writeCall]))), guard: null},
		];
		final policySwitch:Expr = {expr: ESwitch(optFlag, policyCases, null), pos: Context.currentPos()};

		final blockPatterns:Array<Expr> = collectBlockCtorPatterns(bodyTypePath);
		final ifStmtPattern:Null<Expr> = hasElseIf ? findCtorPattern(bodyTypePath, 'IfStmt') : null;
		final outerCases:Array<Case> = [];
		if (ifStmtPattern != null) {
			final kpPath:Array<String> = ['anyparse', 'format', 'KeywordPlacement'];
			final kpNextPat:Expr = MacroStringTools.toFieldExpr(kpPath.concat(['Next']));
			final elseIfCases:Array<Case> = [
				{values: [kpNextPat], expr: macro _dn(_cols, _dc([_dhl(), $writeCall])), guard: null},
			];
			final elseIfSwitch:Expr = {
				expr: ESwitch(macro opt.elseIf, elseIfCases, macro _dc([_dt(' '), $writeCall])),
				pos: Context.currentPos(),
			};
			outerCases.push({values: [ifStmtPattern], expr: elseIfSwitch, guard: null});
		}
		if (blockPatterns.length > 0) {
			final sameLayout:Expr = macro _dc([_dt(' '), $writeCall]);
			outerCases.push({values: blockPatterns, expr: sameLayout, guard: null});
		}
		final bodySwitch:Expr = if (outerCases.length == 0) policySwitch
		else {
			outerCases.push({values: [macro _], expr: policySwitch, guard: null});
			{expr: ESwitch(bodyValueExpr, outerCases, null), pos: Context.currentPos()};
		};

		return macro {
			final _cols:Int = opt.indentChar == anyparse.format.IndentChar.Space ? opt.indentSize : opt.tabWidth;
			$bodySwitch;
		};
	}

	/**
	 * Walk `bodyTypePath`'s rule (expected to be an `Alt`) and collect
	 * `case` patterns for branches that render via `blockBody` — i.e.
	 * enum ctors declared with `@:lead(open) @:trail(close)` on a single
	 * `Star` child. Returns an empty array when `bodyTypePath` is not an
	 * enum, has no such branches, or is absent from the shape map.
	 */
	private function collectBlockCtorPatterns(bodyTypePath:String):Array<Expr> {
		final rule:Null<ShapeNode> = shape.rules.get(bodyTypePath);
		if (rule == null || rule.kind != Alt) return [];
		final simple:String = simpleName(bodyTypePath);
		final pack:Array<String> = packOf(bodyTypePath);
		final patterns:Array<Expr> = [];
		for (branch in rule.children) if (isBlockCtorBranch(branch)) {
			final ctorName:String = branch.annotations.get('base.ctor');
			final arity:Int = branch.children.length;
			final ctorPath:Array<String> = pack.concat([simple, ctorName]);
			final ctorRef:Expr = MacroStringTools.toFieldExpr(ctorPath);
			final pattern:Expr = if (arity == 0) ctorRef
			else {
				final args:Array<Expr> = [for (_ in 0...arity) macro _];
				{expr: ECall(ctorRef, args), pos: Context.currentPos()};
			};
			patterns.push(pattern);
		}
		return patterns;
	}

	private static function isBlockCtorBranch(branch:ShapeNode):Bool {
		final leadText:Null<String> = branch.annotations.get('lit.leadText');
		final trailText:Null<String> = branch.annotations.get('lit.trailText');
		if (leadText == null || trailText == null) return false;
		if (branch.children.length != 1) return false;
		return branch.children[0].kind == Star;
	}

	/**
	 * Build a wildcard `case` pattern for the named ctor of a polymorphic
	 * enum type. Returns `null` when the type is not an enum in the shape
	 * map or has no branch with the requested name — the caller then
	 * skips the ctor-specific override.
	 *
	 * Used by the ψ₈ `@:elseIf` path to target the `IfStmt(_)` ctor of
	 * `HxStatement` when rendering the `else` body of `HxIfStmt`.
	 */
	private function findCtorPattern(bodyTypePath:String, ctorName:String):Null<Expr> {
		final rule:Null<ShapeNode> = shape.rules.get(bodyTypePath);
		if (rule == null || rule.kind != Alt) return null;
		final simple:String = simpleName(bodyTypePath);
		final pack:Array<String> = packOf(bodyTypePath);
		for (branch in rule.children) {
			final branchCtor:String = branch.annotations.get('base.ctor');
			if (branchCtor != ctorName) continue;
			final arity:Int = branch.children.length;
			final ctorPath:Array<String> = pack.concat([simple, branchCtor]);
			final ctorRef:Expr = MacroStringTools.toFieldExpr(ctorPath);
			return if (arity == 0) ctorRef
			else {
				final args:Array<Expr> = [for (_ in 0...arity) macro _];
				{expr: ECall(ctorRef, args), pos: Context.currentPos()};
			};
		}
		return null;
	}

	/**
	 * Return a `Bool`-valued expression for the `trailingComma` argument
	 * of `sepList`. Returns `macro false` when the node carries no
	 * `@:trailingComma("flagName")` meta, else `macro opt.<flagName>` so
	 * the knob is resolved at runtime against the caller's options.
	 *
	 * Read from the node that owns the separated list — an enum branch
	 * (Case 4 Star / postfix Star) or a struct Star field.
	 */
	private static function trailingCommaExpr(node:ShapeNode):Expr {
		final flagName:Null<String> = readMetaString(node, ':trailingComma');
		if (flagName == null) return macro false;
		return {
			expr: EField(macro opt, flagName),
			pos: Context.currentPos(),
		};
	}

	/**
	 * True when the given lead-open string is declared by the format as
	 * taking a preceding space (e.g. Haxe's `{` block-opens). All other
	 * open-delimiters (`(`, `[`, etc.) stay tight against the preceding
	 * token. Evaluated at macro time against `formatInfo.spacedLeads`.
	 */
	private function isSpacedLead(openText:Null<String>):Bool {
		return openText != null && formatInfo.spacedLeads.indexOf(openText) != -1;
	}

	/**
	 * True when the given Star struct field has no `@:lead` / `@:trail`
	 * / `@:sep`, so its emitted Doc is empty whenever the runtime array
	 * is empty. The next bare-Ref field's leading separator must then
	 * be gated on `field.length > 0`, otherwise the writer emits a
	 * dangling space (`\t function` instead of `\tfunction` when
	 * `HxMemberDecl.modifiers` is empty).
	 */
	private static function isBareTryparseStar(child:ShapeNode):Bool {
		if (child.kind != Star) return false;
		final leadText:Null<String> = child.annotations.get('lit.leadText');
		final trailText:Null<String> = child.annotations.get('lit.trailText');
		final sepText:Null<String> = child.annotations.get('lit.sepText');
		return leadText == null && trailText == null && sepText == null;
	}

	/**
	 * True when the given optional `@:lead(...)` text is declared by the
	 * format as tight — no leading separator before it, no trailing
	 * space after it. Used by the optional-Ref code path so Haxe's
	 * `:Type` annotation stays compact instead of being wrapped in
	 * spaces like keyword leads (`else`, `catch`).
	 */
	private function isTightLead(leadText:Null<String>):Bool {
		return leadText != null && formatInfo.tightLeads.indexOf(leadText) != -1;
	}

	/**
	 * True when `refName` names a Seq (struct) rule whose first field is
	 * a bare Ref annotated with `@:bodyPolicy` and no `@:kw` / `@:lead`
	 * of its own. Used by Case 3 enum-branch lowering to decide whether
	 * to strip the trailing space from a `@:kw` lead — the sub-struct's
	 * writer will emit the header→body separator via `bodyPolicyWrap`,
	 * so leaving the space in would yield a double space in the `Same`
	 * case and a dangling space before a hardline in `Next` / `FitLine`.
	 */
	private function subStructStartsWithBodyPolicy(refName:String):Bool {
		final subNode:Null<ShapeNode> = shape.rules.get(refName);
		if (subNode == null || subNode.kind != Seq) return false;
		final children:Array<ShapeNode> = subNode.children;
		if (children.length == 0) return false;
		final first:ShapeNode = children[0];
		if (first.kind != Ref) return false;
		if (first.annotations.get('base.optional') == true) return false;
		if (readMetaString(first, ':kw') != null) return false;
		if (readMetaString(first, ':lead') != null) return false;
		return readMetaString(first, ':bodyPolicy') != null;
	}

	/** Build `_dc([elem1, elem2, ...])` from a macro-time array of Exprs. */
	private static function dcCall(parts:Array<Expr>):Expr {
		final arr:Expr = {expr: EArrayDecl(parts), pos: Context.currentPos()};
		return macro _dc($arr);
	}

	private static function makeWriteCall(writeFnName:String, valueExpr:Expr, hasPratt:Bool, ctxPrec:Int):Expr {
		final args:Array<Expr> = [valueExpr, macro opt];
		if (hasPratt) args.push(macro $v{ctxPrec});
		return {
			expr: ECall(macro $i{writeFnName}, args),
			pos: Context.currentPos(),
		};
	}

	private static function getOperatorText(branch:ShapeNode):String {
		return (branch.annotations.get('pratt.op') : Null<String>) ?? branch.annotations.get('ternary.op');
	}

	private static function hasPrattBranch(node:ShapeNode):Bool {
		for (branch in node.children)
			if (branch.annotations.get('pratt.prec') != null || branch.annotations.get('ternary.op') != null) return true;
		return false;
	}

	private static function hasPostfixBranch(node:ShapeNode):Bool {
		for (branch in node.children) if (branch.annotations.get('postfix.op') != null) return true;
		return false;
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

/** Output of WriterLowering for one rule. */
typedef WriterRule = {
	fnName:String,
	valueCT:ComplexType,
	body:Expr,
	hasCtxPrec:Bool,
	isBinary:Bool,
};

/**
 * Carries the runtime-access expression and enum type path of the
 * immediately preceding bare-Ref struct field whose body was wrapped
 * via `bodyPolicyWrap`. Consumed by `sameLineSeparator` (ψ₉) to emit
 * a shape-aware leading separator on the following `@:sameLine`
 * keyword: block ctors respect the flag, non-block ctors force a
 * hardline.
 */
typedef PrevBodyInfo = {
	access:Expr,
	typePath:String,
};
#end
