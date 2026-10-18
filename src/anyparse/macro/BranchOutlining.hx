package anyparse.macro;

import haxe.Exception;
import haxe.macro.ComplexTypeTools;
import haxe.macro.Expr;
import haxe.macro.ExprTools;

using Lambda;

/**
 * Pass 4 — every enum-branch trial `Lowering.tryBranch` emitted moves out of its rule into a small static helper of
 * its own, which answers the branch's value or `null`, and the rule keeps one call per branch.
 *
 * Why: V8 runs most of a cold parse in its baseline tier (Sparkplug), and a baseline frame maps its PC to a bytecode
 * offset by a LINEAR scan from the start of the function — once for every frame the unwinder visits and once more
 * for the handler it lands on. A choice rule of thirty branches puts its late handlers tens of kilobytes into the
 * function, so a failed late trial costs about a hundred times what the same throw costs from a
 * small frame, and the `HxStatement.CondSemiAssignStmt` probe in front of every expression
 * statement was most of the parse (`docs/decisions.md`, N37). In a helper the
 * handler sits a few bytes from the start of the function.
 *
 * The helper runs the trial's own statements, in the same order, against the same `ctx`; `null` stands for both ways
 * the inline trial reaches the next statement (its catch rolled back, or its body ended without a `return`), and the
 * rule then goes on exactly as it did. A trial moves only when that equivalence is evident from its text — a
 * positive whitelist, everything else stays inline:
 *  - every local of the rule it reads is a parameter or a declaration with an explicit type, one type for every
 *    declaration of that name, and it writes none of them (the helper receives copies);
 *  - no `break` / `continue` leaves it (they would target a loop of the rule) and it holds no `switch` (whose
 *    pattern bindings this pass does not scope);
 *  - every `return` hands back a value that cannot be `null`: a constructor call, a `new`, an object or array
 *    literal, or the `_alt` of a trial nested inside it that this pass already moved.
 */
final class BranchOutlining {

	/** The catch variable `Lowering.tryBranch` names its rollback with — how this pass recognises a trial. */
	public static inline final CATCH_NAME: String = '_branchFail';

	/** The local a rule binds a helper's answer to before returning it. */
	public static inline final ALT_LOCAL: String = '_alt';

	/** Rewrites `rules` in place and returns them with their helpers, each right after the rule it came from. */
	public static function outline(rules: Array<GeneratedRule>): Array<GeneratedRule> {
		final taken: Array<String> = [for (rule in rules) rule.fnName];
		final out: Array<GeneratedRule> = [];
		for (rule in rules) {
			final helpers: Array<GeneratedRule> = [];
			final outer: Map<String, Null<ComplexType>> = ruleLocals(rule);
			rule.body = rewrite(rule, outer, helpers, taken, rule.body);
			out.push(rule);
			for (helper in helpers) out.push(helper);
		}
		return out;
	}

	private static function rewrite(
		rule: GeneratedRule, outer: Map<String, Null<ComplexType>>, helpers: Array<GeneratedRule>, taken: Array<String>, e: Expr
	): Expr {
		final mapped: Expr = ExprTools.map(e, rewrite.bind(rule, outer, helpers, taken));
		if (!isTrial(mapped)) return mapped;
		final scan: TrialScan = new TrialScan(outer);
		scan.walk(mapped);
		#if anyparse_outline_dump
		if (!scan.ok) Sys.println('BranchOutlining: ${rule.fnName} keeps a trial inline (${scan.refusal})');
		#end
		if (!scan.ok) return mapped;
		final params: Array<String> = [for (name in scan.captured.keys()) if (name != 'ctx') name];
		params.sort(Reflect.compare);
		final args: Array<FunctionArg> = [];
		for (name in params) {
			final type: Null<ComplexType> = outer[name];
			if (type == null) {
				#if anyparse_outline_dump
				Sys.println('BranchOutlining: ${rule.fnName} keeps a trial inline (the rule local $name has no single declared type)');
				#end
				return mapped;
			}
			args.push({ name: name, type: type });
		}
		final name: String = '${rule.fnName}Alt${helpers.length}';
		if (taken.contains(name)) throw new Exception('BranchOutlining: helper name $name collides with a generated rule');
		taken.push(name);
		final returnCT: ComplexType = rule.returnCT;
		final nullableCT: ComplexType = macro :Null<$returnCT>;
		final helperBody: Expr = macro {
			$mapped;
			return null;
		};
		helpers.push(new GeneratedRule(name, nullableCT, helperBody, [], false, args));
		final callArgs: Array<Expr> = [macro ctx].concat([for (p in params) macro $i{p}]);
		final call: Expr = { expr: ECall(macro $i{name}, callArgs), pos: mapped.pos };
		return macro {
			final $ALT_LOCAL: Null<$returnCT> = $call;
			if ($i{ALT_LOCAL} != null) return $i{ALT_LOCAL};
		};
	}

	/** The exact block `Lowering.tryBranch` builds: the position snapshot, then the try with its one named catch. */
	private static function isTrial(e: Expr): Bool {
		return switch e.expr {
			case EBlock([{ expr: EVars([_]) }, { expr: ETry(_, [catchClause]) }]): catchClause.name == CATCH_NAME;
			case _: false;
		};
	}

	/**
	 * Every local the rule body declares, by name, with its declared type — `null` when one declaration of the name
	 * has no type or two declarations disagree, so a capture of it declines. `ctx` and a Pratt loop's `minPrec` are
	 * the rule's parameters.
	 */
	private static function ruleLocals(rule: GeneratedRule): Map<String, Null<ComplexType>> {
		final types: Map<String, Null<ComplexType>> = ['ctx' => macro :anyparse.runtime.Parser];
		if (rule.hasMinPrec) types['minPrec'] = macro :Int;
		for (arg in rule.extraArgs) types[arg.name] = arg.type;
		function declare(name: String, type: Null<ComplexType>): Void {
			if (!types.exists(name)) {
				types[name] = type;
				return;
			}
			final known: Null<ComplexType> = types[name];
			if (known == null || type == null || ComplexTypeTools.toString(known) != ComplexTypeTools.toString(type)) types[name] = null;
		}
		function collect(e: Expr): Void {
			switch e.expr {
				case EVars(vars):
					for (v in vars) declare(v.name, v.type);
				case EFunction(_, f):
					for (arg in f.args) declare(arg.name, arg.type);
				case EFor({ expr: EBinop(OpIn, { expr: EConst(CIdent(v)) }, _) }, _):
					declare(v, null);
				case ETry(_, catches):
					for (c in catches) declare(c.name, c.type);
				case _:
			}
			ExprTools.iter(e, collect);
		}
		collect(rule.body);
		return types;
	}

}

/**
 * One trial's scope walk: which locals of the rule it reads, and whether anything in it falls outside the whitelist
 * `BranchOutlining` moves.
 */
private final class TrialScan {

	public var ok(default, null): Bool = true;

	/** What made `ok` false, for `-D anyparse_outline_dump`. */
	public var refusal(default, null): String = '';

	public final captured: Map<String, Bool> = [];

	private final _scopes: Array<Array<String>> = [];
	private final _outer: Map<String, Null<ComplexType>>;

	private var _loops: Int = 0;
	private var _fns: Int = 0;

	public function new(outer: Map<String, Null<ComplexType>>) {
		_outer = outer;
	}

	public function walk(e: Null<Expr>): Void {
		if (e == null || !ok) return;
		switch e.expr {
			case EConst(CIdent(name)):
				read(name);
			case EBlock(exprs):
				_scopes.push([]);
				for (x in exprs) walk(x);
				_scopes.pop();
			case EVars(vars):
				for (v in vars) {
					walk(v.expr);
					declare(v.name);
				}
			case EFunction(kind, f):
				switch kind {
					case FNamed(name, _):
						declare(name);
					case _:
				}
				nested(f);
			case EFor({ expr: EBinop(OpIn, { expr: EConst(CIdent(v)) }, it) }, body):
				walk(it);
				_scopes.push([v]);
				loop(body);
				_scopes.pop();
			case EFor(_, _):
				refuse('a for over a non-identifier pattern');
			case EWhile(cond, body, _):
				walk(cond);
				loop(body);
			case EBreak, EContinue:
				if (_loops == 0) refuse('a break / continue that leaves the trial');
			case EReturn(value):
				if (_fns == 0 && !cannotBeNull(value)) refuse('a return whose value may be null');
				walk(value);
			case ETry(body, catches):
				walk(body);
				for (c in catches) {
					_scopes.push([c.name]);
					walk(c.expr);
					_scopes.pop();
				}
			case ESwitch(_, _, _):
				refuse('a switch');
			case EBinop(OpAssign | OpAssignOp(_), lhs, rhs):
				written(lhs);
				walk(lhs);
				walk(rhs);
			case EUnop(OpIncrement | OpDecrement, _, operand):
				written(operand);
				walk(operand);
			case _:
				ExprTools.iter(e, walk);
		}
	}

	private function refuse(why: String): Void {
		ok = false;
		refusal = why;
	}

	/** A function inside the trial: its own scope, no loop of the trial around it, and its `return`s are its own. */
	private function nested(f: Function): Void {
		final loops: Int = _loops;
		_loops = 0;
		_fns++;
		_scopes.push([for (arg in f.args) arg.name]);
		for (arg in f.args) walk(arg.value);
		walk(f.expr);
		_scopes.pop();
		_fns--;
		_loops = loops;
	}

	private function loop(body: Expr): Void {
		_loops++;
		walk(body);
		_loops--;
	}

	private function declare(name: String): Void {
		final top: Null<Array<String>> = _scopes[_scopes.length - 1];
		if (top == null)
			_scopes.push([name])
		else
			top.push(name);
	}

	private function inScope(name: String): Bool {
		return _scopes.exists(scope -> scope.contains(name));
	}

	private function read(name: String): Void {
		if (!inScope(name) && _outer.exists(name)) captured[name] = true;
	}

	private function written(target: Expr): Void {
		switch target.expr {
			case EConst(CIdent(name)) if (!inScope(name) && _outer.exists(name)):
				refuse('a write to the rule local $name');
			case _:
		}
	}

	private static function cannotBeNull(value: Null<Expr>): Bool {
		if (value == null) return false;
		return switch value.expr {
			case ECall({ expr: EField(_, name) }, _), ECall({ expr: EConst(CIdent(name)) }, _): isCtorName(name);
			case EField(_, name): isCtorName(name);
			case ENew(_, _), EObjectDecl(_), EArrayDecl(_): true;
			case EConst(CIdent(name)): name == BranchOutlining.ALT_LOCAL;
			case EParenthesis(inner): cannotBeNull(inner);
			case _: false;
		};
	}

	/** A constructor spelling: an upper-case initial and at least one lower-case letter, so `NONE`-style constants miss. */
	private static function isCtorName(name: String): Bool {
		final first: Int = name.charCodeAt(0) ?? 0;
		return first >= 'A'.code && first <= 'Z'.code && name.toUpperCase() != name;
	}

}
