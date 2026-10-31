package unit.lowering;

import anyparse.macro.BranchOutlining;
import anyparse.macro.GeneratedRule;
import haxe.macro.ComplexTypeTools;
import haxe.macro.Expr;
import haxe.macro.ExprTools;

/**
 * The contract of `BranchOutlining`, the pass that moves each enum-branch trial out of its rule into a helper.
 *
 * GREEN AT BASE BY CONSTRUCTION: the pass does not exist before this slice. What it guards is a SILENT defect class —
 * a trial moved when its meaning depends on the rule around it (a local it writes, a loop a `break` targets, a
 * `return` whose `null` the call site would read as "the trial failed") still compiles and parses most inputs, down a
 * different path. Each refusal below therefore has an arm, and each is paired with the nearest shape that DOES move,
 * so an arm that weakens the refusal flips exactly its own row.
 */
@:nullSafety(Strict)
final class BranchOutliningTest extends Test {

	/** A trial reading the rule's typed `_start` moves; the rule keeps a call and the helper receives `_start`. */
	@:pin('control')
	@:killer('M-OUTLINE-OFF')
	public function testATrialReadingARuleLocalMovesIntoAHelper(): Void {
		final rules: Array<GeneratedRule> = outlined(macro {
			final _start: Int = ctx.pos;
			{
				final _savedPos: Int = ctx.pos;
				try {
					skipWs(ctx);
					return Foo.Bar(new anyparse.runtime.Span(_start, ctx.pos));
				} catch (_branchFail: anyparse.runtime.ParseError) {
					ctx.pos = _savedPos;
				}
			}
			throw anyparse.runtime.ParseError.backtrack;
		});
		Assert.equals(2, rules.length);
		Assert.equals(
			'{\n\tfinal _start:Int = ctx.pos;\n\t{\n\t\tfinal _alt:Null<Foo> = parseRAlt0(ctx, _start);\n'
			+ '\t\tif (_alt != null) return _alt;\n\t};\n\tthrow anyparse.runtime.ParseError.backtrack;\n}',
			ExprTools.toString(rules[0].body)
		);
		final helper: Null<GeneratedRule> = rules[1];
		if (helper == null) return;
		Assert.equals('parseRAlt0', helper.fnName);
		Assert.equals('Null<Foo>', ComplexTypeTools.toString(helper.returnCT));
		Assert.same(['_start:Int'], [
			for (arg in helper.extraArgs) '${arg.name}:${arg.type == null ? '?' : ComplexTypeTools.toString(arg.type)}'
		]);
	}

	/** A local declared INSIDE the trial is the trial's own, not a capture — even when a sibling trial declares one too. */
	@:pin('guard')
	public function testATrialsOwnLocalIsNotCaptured(): Void {
		final rules: Array<GeneratedRule> = outlined(macro {
			{
				final _savedPos: Int = ctx.pos;
				try {
					final _raw: Int = parseX(ctx);
					return Foo.Bar(_raw);
				} catch (_branchFail: anyparse.runtime.ParseError) {
					ctx.pos = _savedPos;
				}
			}
			throw anyparse.runtime.ParseError.backtrack;
		});
		Assert.equals(2, rules.length);
		Assert.same([], rules[1].extraArgs);
	}

	/** A trial that WRITES a rule local stays inline: the helper would write its own copy. */
	@:pin('control')
	@:killer('M-OUTLINE-WRITE-BLIND')
	public function testAWriteToARuleLocalKeepsTheTrialInline(): Void {
		assertKeptInline(macro {
			var left: Int = 0;
			{
				final _savedPos: Int = ctx.pos;
				try {
					left = parseX(ctx);
					return Foo.Bar(left);
				} catch (_branchFail: anyparse.runtime.ParseError) {
					ctx.pos = _savedPos;
				}
			}
			throw anyparse.runtime.ParseError.backtrack;
		});
	}

	/** A `break` that leaves the trial targets a loop of the rule, which a helper does not have. */
	@:pin('control')
	@:killer('M-OUTLINE-BREAK-BLIND')
	public function testABreakLeavingTheTrialKeepsItInline(): Void {
		assertKeptInline(macro {
			while (true) {
				final _savedPos: Int = ctx.pos;
				try {
					if (parseX(ctx) == 0) break;
					return Foo.Bar(0);
				} catch (_branchFail: anyparse.runtime.ParseError) {
					ctx.pos = _savedPos;
				}
			}
			throw anyparse.runtime.ParseError.backtrack;
		});
	}

	/** The twin: a `break` of a loop INSIDE the trial stays inside the helper too. */
	@:pin('guard')
	public function testABreakOfALoopInsideTheTrialMoves(): Void {
		final rules: Array<GeneratedRule> = outlined(macro {
			{
				final _savedPos: Int = ctx.pos;
				try {
					while (true) if (parseX(ctx) == 0) break;
					return Foo.Bar(0);
				} catch (_branchFail: anyparse.runtime.ParseError) {
					ctx.pos = _savedPos;
				}
			}
			throw anyparse.runtime.ParseError.backtrack;
		});
		Assert.equals(2, rules.length);
	}

	/** A `switch` binds pattern locals this pass does not scope, so a trial holding one stays inline. */
	@:pin('control')
	@:killer('M-OUTLINE-SWITCH-BLIND')
	public function testASwitchKeepsTheTrialInline(): Void {
		assertKeptInline(macro {
			{
				final _savedPos: Int = ctx.pos;
				try {
					switch parseX(ctx) {
						case 0:
							return Foo.Bar(0);
						case _:
					}
				} catch (_branchFail: anyparse.runtime.ParseError) {
					ctx.pos = _savedPos;
				}
			}
			throw anyparse.runtime.ParseError.backtrack;
		});
	}

	/** A `for` over a key-value pattern is a binding shape this pass does not scope. */
	@:pin('control')
	@:killer('M-OUTLINE-FOR-PATTERN-BLIND')
	public function testAForOverAPatternKeepsTheTrialInline(): Void {
		assertKeptInline(macro {
			{
				final _savedPos: Int = ctx.pos;
				try {
					for (k => v in parseMap(ctx)) if (k == v) return Foo.Bar(k);
				} catch (_branchFail: anyparse.runtime.ParseError) {
					ctx.pos = _savedPos;
				}
			}
			throw anyparse.runtime.ParseError.backtrack;
		});
	}

	/** A `return` of a plain call may hand back `null`, which the call site would read as a failed trial. */
	@:pin('control')
	@:killer('M-OUTLINE-NULLABLE-RETURN-BLIND')
	public function testAReturnThatMayBeNullKeepsTheTrialInline(): Void {
		assertKeptInline(macro {
			{
				final _savedPos: Int = ctx.pos;
				try {
					return parseX(ctx);
				} catch (_branchFail: anyparse.runtime.ParseError) {
					ctx.pos = _savedPos;
				}
			}
			throw anyparse.runtime.ParseError.backtrack;
		});
	}

	/** An all-capitals field is a constant, not a constructor — it may be `null`. */
	@:pin('control')
	@:killer('M-OUTLINE-CONSTANT-AS-CTOR')
	public function testAReturnOfAConstantKeepsTheTrialInline(): Void {
		assertKeptInline(macro {
			{
				final _savedPos: Int = ctx.pos;
				try {
					skipWs(ctx);
					return Foo.NONE;
				} catch (_branchFail: anyparse.runtime.ParseError) {
					ctx.pos = _savedPos;
				}
			}
			throw anyparse.runtime.ParseError.backtrack;
		});
	}

	/** A captured local with no declared type has nothing to type the helper's parameter with. */
	@:pin('control')
	@:killer('M-OUTLINE-UNTYPED-CAPTURE')
	public function testAnUntypedRuleLocalKeepsTheTrialInline(): Void {
		assertKeptInline(macro {
			final _start = ctx.pos;
			{
				final _savedPos: Int = ctx.pos;
				try {
					return Foo.Bar(_start);
				} catch (_branchFail: anyparse.runtime.ParseError) {
					ctx.pos = _savedPos;
				}
			}
			throw anyparse.runtime.ParseError.backtrack;
		});
	}

	/** Two declarations of one name with different types: which one the trial reads is not this pass's to decide. */
	@:pin('guard')
	public function testDisagreeingDeclarationsKeepTheTrialInline(): Void {
		assertKeptInline(macro {
			{
				final _start: String = '';
			}
			final _start: Int = ctx.pos;
			{
				final _savedPos: Int = ctx.pos;
				try {
					return Foo.Bar(_start);
				} catch (_branchFail: anyparse.runtime.ParseError) {
					ctx.pos = _savedPos;
				}
			}
			throw anyparse.runtime.ParseError.backtrack;
		});
	}

	/** A nested trial moves first; the outer one returns its `_alt`, which is known non-null, and moves too. */
	@:pin('control')
	@:killer('M-OUTLINE-NESTED-ALT-BLIND')
	public function testANestedTrialMovesFirstAndTheOuterOneFollows(): Void {
		final rules: Array<GeneratedRule> = outlined(macro {
			{
				final _savedPos: Int = ctx.pos;
				try {
					skipWs(ctx);
					{
						final _savedPos: Int = ctx.pos;
						try {
							return Foo.Bar(0);
						} catch (_branchFail: anyparse.runtime.ParseError) {
							ctx.pos = _savedPos;
						}
					}
					return Foo.Baz(1);
				} catch (_branchFail: anyparse.runtime.ParseError) {
					ctx.pos = _savedPos;
				}
			}
			throw anyparse.runtime.ParseError.backtrack;
		});
		Assert.same(['parseR', 'parseRAlt0', 'parseRAlt1'], [for (rule in rules) rule.fnName]);
	}

	/** A try whose catch is not `tryBranch`'s is somebody else's rollback and is left alone. */
	@:pin('guard')
	public function testATryThatIsNotATrialIsLeftAlone(): Void {
		assertKeptInline(macro {
			{
				final _savedPos: Int = ctx.pos;
				try {
					return Foo.Bar(0);
				} catch (_e: anyparse.runtime.ParseError) {
					ctx.pos = _savedPos;
				}
			}
			throw anyparse.runtime.ParseError.backtrack;
		});
	}

	private function outlined(body: Expr): Array<GeneratedRule> {
		return BranchOutlining.outline([new GeneratedRule('parseR', macro :Foo, body, [])]);
	}

	private function assertKeptInline(body: Expr): Void {
		final before: String = ExprTools.toString(body);
		final rules: Array<GeneratedRule> = outlined(body);
		Assert.equals(1, rules.length, 'expected the trial to stay inline, got ${[for (rule in rules) rule.fnName]}');
		Assert.equals(before, ExprTools.toString(rules[0].body));
	}

}
