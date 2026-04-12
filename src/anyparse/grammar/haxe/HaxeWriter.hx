package anyparse.grammar.haxe;

import anyparse.core.D;
import anyparse.core.Doc;
import anyparse.core.Renderer;

/**
 * Formatting options for the Haxe writer.
 */
typedef HaxeWriteOptions = {
	indent:String,
	lineWidth:Int,
};

/**
 * Writer that converts a Haxe AST back to formatted Haxe source text.
 *
 * Internally builds a `Doc` tree and hands it to `Renderer`. Layout
 * decisions (flat vs broken) are handled automatically by the Doc IR
 * for containers like parameter lists and array literals. Declarations
 * and statement blocks always break (one item per line).
 *
 * Operator precedence is tracked via a `contextPrec` parameter so
 * parentheses are inserted only when needed for correctness.
 */
@:nullSafety(Strict)
final class HaxeWriter {

	private static inline final PREC_NONE:Int = -1;
	private static inline final PREC_TERNARY:Int = 1;
	private static inline final PREC_POSTFIX:Int = 10;

	/** Default options: tab indent, 120-column width. */
	public static final defaultOptions:HaxeWriteOptions = {
		indent: '\t',
		lineWidth: 120,
	};

	/** Write a module (zero or more top-level declarations) to a string. */
	public static function write(module:HxModule, ?options:HaxeWriteOptions):String {
		final opt:HaxeWriteOptions = options ?? defaultOptions;
		return Renderer.render(moduleToDoc(module, opt), opt.lineWidth);
	}

	/** Write a single top-level declaration to a string. */
	public static function writeDecl(decl:HxDecl, ?options:HaxeWriteOptions):String {
		final opt:HaxeWriteOptions = options ?? defaultOptions;
		return Renderer.render(declToDoc(decl, opt), opt.lineWidth);
	}

	/** Convert a module to its Doc representation. */
	public static function moduleToDoc(module:HxModule, opt:HaxeWriteOptions):Doc {
		if (module.decls.length == 0) return D.empty();
		final docs:Array<Doc> = [for (d in module.decls) declToDoc(d, opt)];
		final parts:Array<Doc> = [docs[0]];
		for (i in 1...docs.length) {
			parts.push(D.hardline());
			parts.push(D.hardline());
			parts.push(docs[i]);
		}
		return D.concat(parts);
	}

	/** Convert a single declaration to its Doc representation. */
	public static function declToDoc(decl:HxDecl, opt:HaxeWriteOptions):Doc {
		return switch decl {
			case ClassDecl(d): classToDoc(d, opt);
			case TypedefDecl(d): D.concat([typedefToDoc(d), D.text(';')]);
			case EnumDecl(d): enumDeclToDoc(d, opt);
			case InterfaceDecl(d): interfaceToDoc(d, opt);
			case AbstractDecl(d): abstractToDoc(d, opt);
		};
	}

	// --- Declarations ---

	private static function classToDoc(cls:HxClassDecl, opt:HaxeWriteOptions):Doc {
		final header:Doc = D.concat([D.text('class '), D.text(cls.name)]);
		return D.concat([header, membersBody([for (m in cls.members) memberToDoc(m, opt)], opt)]);
	}

	private static function interfaceToDoc(iface:HxInterfaceDecl, opt:HaxeWriteOptions):Doc {
		final header:Doc = D.concat([D.text('interface '), D.text(iface.name)]);
		return D.concat([header, membersBody([for (m in iface.members) memberToDoc(m, opt)], opt)]);
	}

	private static function enumDeclToDoc(ed:HxEnumDecl, opt:HaxeWriteOptions):Doc {
		final header:Doc = D.concat([D.text('enum '), D.text(ed.name)]);
		return D.concat([header, membersBody([for (c in ed.ctors) enumCtorToDoc(c, opt)], opt)]);
	}

	private static function typedefToDoc(td:HxTypedefDecl):Doc {
		return D.concat([D.text('typedef '), D.text(td.name), D.text(' = '), D.text(td.type.name)]);
	}

	private static function abstractToDoc(ab:HxAbstractDecl, opt:HaxeWriteOptions):Doc {
		final parts:Array<Doc> = [
			D.text('abstract '), D.text(ab.name),
			D.text('('), D.text(ab.underlyingType.name), D.text(')'),
		];
		for (c in ab.clauses)
			parts.push(D.concat([D.text(' '), abstractClauseToDoc(c)]));
		parts.push(membersBody([for (m in ab.members) memberToDoc(m, opt)], opt));
		return D.concat(parts);
	}

	private static function abstractClauseToDoc(c:HxAbstractClause):Doc {
		return switch c {
			case FromClause(t): D.concat([D.text('from '), D.text(t.name)]);
			case ToClause(t): D.concat([D.text('to '), D.text(t.name)]);
		};
	}

	private static function enumCtorToDoc(c:HxEnumCtor, opt:HaxeWriteOptions):Doc {
		return switch c {
			case ParamCtor(d):
				final paramDocs:Array<Doc> = [for (p in d.params) paramToDoc(p, opt)];
				D.concat([D.text(d.name), sepList('(', ')', paramDocs, opt), D.text(';')]);
			case SimpleCtor(name): D.concat([D.text(name), D.text(';')]);
		};
	}

	// --- Members ---

	private static function memberToDoc(md:HxMemberDecl, opt:HaxeWriteOptions):Doc {
		final parts:Array<Doc> = [for (m in md.modifiers) D.concat([modifierToDoc(m), D.text(' ')])];
		parts.push(classMemberToDoc(md.member, opt));
		return D.concat(parts);
	}

	private static function classMemberToDoc(cm:HxClassMember, opt:HaxeWriteOptions):Doc {
		return switch cm {
			case VarMember(d): D.concat([D.text('var '), varDeclToDoc(d, opt), D.text(';')]);
			case FnMember(d): D.concat([D.text('function '), fnDeclToDoc(d, opt)]);
		};
	}

	private static function modifierToDoc(m:HxModifier):Doc {
		return D.text(switch m {
			case Public: 'public';
			case Private: 'private';
			case Static: 'static';
			case Inline: 'inline';
			case Override: 'override';
			case Final: 'final';
			case Dynamic: 'dynamic';
			case Extern: 'extern';
		});
	}

	private static function varDeclToDoc(d:HxVarDecl, opt:HaxeWriteOptions):Doc {
		final parts:Array<Doc> = [D.text(d.name), D.text(':'), D.text(d.type.name)];
		final init:Null<HxExpr> = d.init;
		if (init != null)
			parts.push(D.concat([D.text(' = '), exprToDoc(init, PREC_NONE, opt)]));
		return D.concat(parts);
	}

	private static function fnDeclToDoc(fd:HxFnDecl, opt:HaxeWriteOptions):Doc {
		final paramDocs:Array<Doc> = [for (p in fd.params) paramToDoc(p, opt)];
		final sig:Doc = D.concat([
			D.text(fd.name),
			sepList('(', ')', paramDocs, opt),
			D.text(':'), D.text(fd.returnType.name),
		]);
		final bodyDocs:Array<Doc> = [for (s in fd.body) stmtToDoc(s, opt)];
		return D.concat([sig, membersBody(bodyDocs, opt)]);
	}

	private static function paramToDoc(p:HxParam, opt:HaxeWriteOptions):Doc {
		final parts:Array<Doc> = [D.text(p.name), D.text(':'), D.text(p.type.name)];
		final dv:Null<HxExpr> = p.defaultValue;
		if (dv != null)
			parts.push(D.concat([D.text(' = '), exprToDoc(dv, PREC_NONE, opt)]));
		return D.concat(parts);
	}

	private static function lambdaParamToDoc(p:HxLambdaParam):Doc {
		final t:Null<HxTypeRef> = p.type;
		return if (t != null) D.concat([D.text(p.name), D.text(':'), D.text(t.name)])
			else D.text(p.name);
	}

	// --- Statements ---

	private static function stmtToDoc(stmt:HxStatement, opt:HaxeWriteOptions):Doc {
		return switch stmt {
			case VarStmt(d): D.concat([D.text('var '), varDeclToDoc(d, opt), D.text(';')]);
			case ReturnStmt(v): D.concat([D.text('return '), exprToDoc(v, PREC_NONE, opt), D.text(';')]);
			case VoidReturnStmt: D.text('return;');
			case IfStmt(s): ifToDoc(s, opt);
			case WhileStmt(s): whileToDoc(s, opt);
			case ForStmt(s): forToDoc(s, opt);
			case SwitchStmt(s): switchToDoc(s, opt);
			case ThrowStmt(e): D.concat([D.text('throw '), exprToDoc(e, PREC_NONE, opt), D.text(';')]);
			case DoWhileStmt(s): D.concat([doWhileToDoc(s, opt), D.text(';')]);
			case TryCatchStmt(s): tryCatchToDoc(s, opt);
			case BlockStmt(stmts): bracedBlock([for (s in stmts) stmtToDoc(s, opt)], opt.indent.length);
			case ExprStmt(e): D.concat([exprToDoc(e, PREC_NONE, opt), D.text(';')]);
		};
	}

	private static function ifToDoc(s:HxIfStmt, opt:HaxeWriteOptions):Doc {
		final parts:Array<Doc> = [
			D.text('if ('), exprToDoc(s.cond, PREC_NONE, opt), D.text(') '),
			stmtToDoc(s.thenBody, opt),
		];
		final elseBody:Null<HxStatement> = s.elseBody;
		if (elseBody != null)
			parts.push(D.concat([D.text(' else '), stmtToDoc(elseBody, opt)]));
		return D.concat(parts);
	}

	private static function whileToDoc(s:HxWhileStmt, opt:HaxeWriteOptions):Doc {
		return D.concat([
			D.text('while ('), exprToDoc(s.cond, PREC_NONE, opt), D.text(') '),
			stmtToDoc(s.body, opt),
		]);
	}

	private static function forToDoc(s:HxForStmt, opt:HaxeWriteOptions):Doc {
		return D.concat([
			D.text('for ('), D.text(s.varName), D.text(' in '),
			exprToDoc(s.iterable, PREC_NONE, opt), D.text(') '),
			stmtToDoc(s.body, opt),
		]);
	}

	private static function doWhileToDoc(s:HxDoWhileStmt, opt:HaxeWriteOptions):Doc {
		return D.concat([
			D.text('do '), stmtToDoc(s.body, opt),
			D.text(' while ('), exprToDoc(s.cond, PREC_NONE, opt), D.text(')'),
		]);
	}

	private static function switchToDoc(s:HxSwitchStmt, opt:HaxeWriteOptions):Doc {
		final header:Doc = D.concat([D.text('switch ('), exprToDoc(s.expr, PREC_NONE, opt), D.text(')')]);
		final caseDocs:Array<Doc> = [for (c in s.cases) caseToDoc(c, opt)];
		return D.concat([header, membersBody(caseDocs, opt)]);
	}

	private static function caseToDoc(sc:HxSwitchCase, opt:HaxeWriteOptions):Doc {
		return switch sc {
			case CaseBranch(b): caseBranchToDoc(b, opt);
			case DefaultBranch(b): defaultBranchToDoc(b, opt);
		};
	}

	private static function caseBranchToDoc(b:HxCaseBranch, opt:HaxeWriteOptions):Doc {
		final header:Doc = D.concat([D.text('case '), exprToDoc(b.pattern, PREC_NONE, opt), D.text(':')]);
		if (b.body.length == 0) return header;
		final stmtDocs:Array<Doc> = [for (s in b.body) stmtToDoc(s, opt)];
		return D.concat([
			header,
			D.nest(opt.indent.length, D.concat([for (sd in stmtDocs) D.concat([D.hardline(), sd])])),
		]);
	}

	private static function defaultBranchToDoc(b:HxDefaultBranch, opt:HaxeWriteOptions):Doc {
		final header:Doc = D.text('default:');
		if (b.stmts.length == 0) return header;
		final stmtDocs:Array<Doc> = [for (s in b.stmts) stmtToDoc(s, opt)];
		return D.concat([
			header,
			D.nest(opt.indent.length, D.concat([for (sd in stmtDocs) D.concat([D.hardline(), sd])])),
		]);
	}

	private static function tryCatchToDoc(s:HxTryCatchStmt, opt:HaxeWriteOptions):Doc {
		final parts:Array<Doc> = [D.text('try '), stmtToDoc(s.body, opt)];
		for (c in s.catches) {
			parts.push(D.concat([
				D.text(' catch ('), D.text(c.name), D.text(':'), D.text(c.type.name), D.text(') '),
				stmtToDoc(c.body, opt),
			]));
		}
		return D.concat(parts);
	}

	// --- Expressions ---

	private static function exprToDoc(expr:HxExpr, ctxPrec:Int, opt:HaxeWriteOptions):Doc {
		return switch expr {
			// Atoms
			case FloatLit(v): D.text(formatFloat(v));
			case IntLit(v): D.text('$v');
			case BoolLit(v): D.text(if (v) 'true' else 'false');
			case NullLit: D.text('null');
			case DoubleStringExpr(v): D.text(escapeDoubleStr(v));
			case SingleStringExpr(v): interpStringToDoc(v, opt);
			case ArrayExpr(elems):
				sepList('[', ']', [for (e in elems) exprToDoc(e, PREC_NONE, opt)], opt);
			case ParenLambdaExpr(lam): parenLambdaToDoc(lam, opt);
			case ParenExpr(inner):
				D.concat([D.text('('), exprToDoc(inner, PREC_NONE, opt), D.text(')')]);
			case NewExpr(ne): newExprToDoc(ne, opt);
			case IdentExpr(v): D.text(v);
			// Prefix
			case Neg(op): D.concat([D.text('-'), exprToDoc(op, PREC_POSTFIX, opt)]);
			case Not(op): D.concat([D.text('!'), exprToDoc(op, PREC_POSTFIX, opt)]);
			case BitNot(op): D.concat([D.text('~'), exprToDoc(op, PREC_POSTFIX, opt)]);
			// Postfix
			case FieldAccess(op, field):
				D.concat([exprToDoc(op, PREC_POSTFIX, opt), D.text('.'), D.text(field)]);
			case IndexAccess(op, idx):
				D.concat([exprToDoc(op, PREC_POSTFIX, opt), D.text('['), exprToDoc(idx, PREC_NONE, opt), D.text(']')]);
			case Call(op, args):
				D.concat([exprToDoc(op, PREC_POSTFIX, opt), sepList('(', ')', [for (a in args) exprToDoc(a, PREC_NONE, opt)], opt)]);
			// Multiplicative (prec 9, left)
			case Mul(l, r): binop('*', 9, true, l, r, ctxPrec, opt);
			case Div(l, r): binop('/', 9, true, l, r, ctxPrec, opt);
			case Mod(l, r): binop('%', 9, true, l, r, ctxPrec, opt);
			// Additive (prec 8, left)
			case Add(l, r): binop('+', 8, true, l, r, ctxPrec, opt);
			case Sub(l, r): binop('-', 8, true, l, r, ctxPrec, opt);
			// Shift (prec 7, left)
			case Shl(l, r): binop('<<', 7, true, l, r, ctxPrec, opt);
			case UShr(l, r): binop('>>>', 7, true, l, r, ctxPrec, opt);
			case Shr(l, r): binop('>>', 7, true, l, r, ctxPrec, opt);
			// Bitwise (prec 6, left)
			case BitOr(l, r): binop('|', 6, true, l, r, ctxPrec, opt);
			case BitAnd(l, r): binop('&', 6, true, l, r, ctxPrec, opt);
			case BitXor(l, r): binop('^', 6, true, l, r, ctxPrec, opt);
			// Comparison (prec 5, left)
			case Eq(l, r): binop('==', 5, true, l, r, ctxPrec, opt);
			case NotEq(l, r): binop('!=', 5, true, l, r, ctxPrec, opt);
			case LtEq(l, r): binop('<=', 5, true, l, r, ctxPrec, opt);
			case GtEq(l, r): binop('>=', 5, true, l, r, ctxPrec, opt);
			case Lt(l, r): binop('<', 5, true, l, r, ctxPrec, opt);
			case Gt(l, r): binop('>', 5, true, l, r, ctxPrec, opt);
			// Logical (prec 4/3, left)
			case And(l, r): binop('&&', 4, true, l, r, ctxPrec, opt);
			case Or(l, r): binop('||', 3, true, l, r, ctxPrec, opt);
			// Null-coalescing (prec 2, right)
			case NullCoal(l, r): binop('??', 2, false, l, r, ctxPrec, opt);
			// Ternary (prec 1)
			case Ternary(cond, thenE, elseE): ternaryToDoc(cond, thenE, elseE, ctxPrec, opt);
			// Assignment + arrow (prec 0, right)
			case Assign(l, r): binop('=', 0, false, l, r, ctxPrec, opt);
			case AddAssign(l, r): binop('+=', 0, false, l, r, ctxPrec, opt);
			case SubAssign(l, r): binop('-=', 0, false, l, r, ctxPrec, opt);
			case MulAssign(l, r): binop('*=', 0, false, l, r, ctxPrec, opt);
			case DivAssign(l, r): binop('/=', 0, false, l, r, ctxPrec, opt);
			case ModAssign(l, r): binop('%=', 0, false, l, r, ctxPrec, opt);
			case ShlAssign(l, r): binop('<<=', 0, false, l, r, ctxPrec, opt);
			case UShrAssign(l, r): binop('>>>=', 0, false, l, r, ctxPrec, opt);
			case ShrAssign(l, r): binop('>>=', 0, false, l, r, ctxPrec, opt);
			case BitOrAssign(l, r): binop('|=', 0, false, l, r, ctxPrec, opt);
			case BitAndAssign(l, r): binop('&=', 0, false, l, r, ctxPrec, opt);
			case BitXorAssign(l, r): binop('^=', 0, false, l, r, ctxPrec, opt);
			case NullCoalAssign(l, r): binop('??=', 0, false, l, r, ctxPrec, opt);
			case Arrow(l, r): binop('=>', 0, false, l, r, ctxPrec, opt);
		};
	}

	private static function binop(
		op:String, prec:Int, leftAssoc:Bool,
		left:HxExpr, right:HxExpr, ctxPrec:Int, opt:HaxeWriteOptions
	):Doc {
		final leftCtx:Int = if (leftAssoc) prec else prec + 1;
		final rightCtx:Int = if (leftAssoc) prec + 1 else prec;
		final inner:Doc = D.concat([
			exprToDoc(left, leftCtx, opt),
			D.text(' $op '),
			exprToDoc(right, rightCtx, opt),
		]);
		return if (prec < ctxPrec) D.concat([D.text('('), inner, D.text(')')]) else inner;
	}

	private static function ternaryToDoc(
		cond:HxExpr, thenE:HxExpr, elseE:HxExpr, ctxPrec:Int, opt:HaxeWriteOptions
	):Doc {
		final inner:Doc = D.concat([
			exprToDoc(cond, PREC_TERNARY + 1, opt),
			D.text(' ? '),
			exprToDoc(thenE, PREC_NONE, opt),
			D.text(' : '),
			exprToDoc(elseE, PREC_NONE, opt),
		]);
		return if (PREC_TERNARY < ctxPrec) D.concat([D.text('('), inner, D.text(')')]) else inner;
	}

	private static function newExprToDoc(ne:HxNewExpr, opt:HaxeWriteOptions):Doc {
		final argDocs:Array<Doc> = [for (a in ne.args) exprToDoc(a, PREC_NONE, opt)];
		return D.concat([D.text('new '), D.text(ne.type), sepList('(', ')', argDocs, opt)]);
	}

	private static function parenLambdaToDoc(lam:HxParenLambda, opt:HaxeWriteOptions):Doc {
		final paramDocs:Array<Doc> = [for (p in lam.params) lambdaParamToDoc(p)];
		return D.concat([
			sepList('(', ')', paramDocs, opt),
			D.text(' => '),
			exprToDoc(lam.body, PREC_NONE, opt),
		]);
	}

	// --- Strings ---

	private static function interpStringToDoc(s:HxInterpString, opt:HaxeWriteOptions):Doc {
		final parts:Array<Doc> = [D.text("'")];
		for (seg in s.parts)
			parts.push(stringSegmentToDoc(seg, opt));
		parts.push(D.text("'"));
		return D.concat(parts);
	}

	private static function stringSegmentToDoc(seg:HxStringSegment, opt:HaxeWriteOptions):Doc {
		return switch seg {
			case Literal(s): D.text(escapeSingleSegment(s));
			case Dollar: D.text("$$");
			case Block(expr): D.concat([D.text("${"), exprToDoc(expr, PREC_NONE, opt), D.text("}")]);
			case Ident(name): D.concat([D.text("$"), D.text(name)]);
		};
	}

	private static function escapeDoubleStr(s:String):String {
		final buf:StringBuf = new StringBuf();
		buf.add('"');
		for (i in 0...s.length) {
			final c:Null<Int> = s.charCodeAt(i);
			if (c != null) buf.add(HaxeFormat.instance.escapeChar(c));
		}
		buf.add('"');
		return buf.toString();
	}

	private static function escapeSingleSegment(s:String):String {
		final buf:StringBuf = new StringBuf();
		for (i in 0...s.length) {
			final c:Null<Int> = s.charCodeAt(i);
			if (c == null) continue;
			switch c {
				case 39: buf.add("\\'");
				case 92: buf.add("\\\\");
				case 10: buf.add("\\n");
				case 13: buf.add("\\r");
				case 9: buf.add("\\t");
				case _:
					if (c < 0x20) buf.add("\\x" + StringTools.hex(c, 2))
					else buf.addChar(c);
			}
		}
		return buf.toString();
	}

	// --- Shared helpers ---

	/** Braced block without leading space: `{ item\n item\n }`. */
	private static function bracedBlock(docs:Array<Doc>, indentWidth:Int):Doc {
		if (docs.length == 0) return D.text('{}');
		return D.concat([
			D.text('{'),
			D.nest(indentWidth, D.concat([for (d in docs) D.concat([D.hardline(), d])])),
			D.hardline(),
			D.text('}'),
		]);
	}

	/** Braced body with leading space: ` { item\n item\n }`. Used for declarations. */
	private static function membersBody(docs:Array<Doc>, opt:HaxeWriteOptions):Doc {
		if (docs.length == 0) return D.text(' {}');
		return D.concat([
			D.text(' {'),
			D.nest(opt.indent.length, D.concat([for (d in docs) D.concat([D.hardline(), d])])),
			D.hardline(),
			D.text('}'),
		]);
	}

	/** Comma-separated list in delimiters with fit-or-break layout. */
	private static function sepList(open:String, close:String, items:Array<Doc>, opt:HaxeWriteOptions):Doc {
		if (items.length == 0) return D.text('$open$close');
		final inner:Array<Doc> = D.intersperse(items, D.concat([D.text(','), D.line()]));
		return D.group(D.concat([
			D.text(open),
			D.nest(opt.indent.length, D.concat([D.softline(), D.concat(inner)])),
			D.softline(),
			D.text(close),
		]));
	}

	/** Format a float ensuring a decimal point is always present. */
	private static function formatFloat(v:Float):String {
		final s:String = '$v';
		if (s.indexOf('.') >= 0) return s;
		return s + '.0';
	}
}
