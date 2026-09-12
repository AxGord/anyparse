package unit.grammar.haxe;

import anyparse.grammar.haxe.HaxeQueryPlugin;
import anyparse.query.cli.command.FmtCommand;
import utest.Assert;
import utest.Test;

/**
 * `HxCondSpliceTailBody` — the POST-operand token-splice conditional stops being one raw byte
 * capture and becomes an ordered choice.
 *
 * THE DEFECT THIS CLOSES. `HxExpr.CondSpliceTail` covers every `#if` region that opens AFTER a
 * complete operand, and it swallowed the whole fragment verbatim: the writer re-emitted the
 * bytes, `fmt` printed a note saying so, and every name spelled inside was invisible to `refs`
 * and refused by `rename`. Two sub-shapes are the bulk of it — a leading infix operator
 * (`A + B #if mobile - 120 #end`) and a leading list separator (`g(a, b #if F, c #end)`, and
 * the same inside an array literal) — and both are ordinary expressions once the separator in
 * front of them is read as a token of its own.
 *
 * WHY AN ALT AND NOT A SECOND POSTFIX CTOR. `PrattPostfixLowering.lowerPostfixLoop` emits one
 * `if` / `else if` chain keyed on the operator literal and commits on the first match, so two
 * ctors spelling `#if` compile to two arms of which the second is dead. An `@:peg` enum branch
 * runs inside `Lowering.tryBranch`, which restores `ctx.pos` on a `ParseError` — that rewind is
 * what lets a fragment neither structured branch can represent fall through to the raw capture
 * exactly as the whole shape did before.
 *
 * WHY THE PRATT TRAP DOES NOT BITE. The operand-position mirror (`HxCondSpliceOpExpr`) binds
 * each operand at ATOM level because its fragment ENDS on a dangling operator, which a
 * full-precedence parse would hand to the Pratt loop — and that loop throws on the missing
 * right operand with no rewind of its own. The tail fragment ends on a COMPLETE operand, so the
 * loop is entered on a well-formed expression and stops at the `#end` it cannot read as an
 * operator.
 */
@:nullSafety(Strict)
final class HxCondSpliceTailSliceTest extends Test {

	private static final CONFIG: String = '{"indentation":{"character":"tab","tabWidth":4},"wrapping":{"maxLineLength":140}}';

	public function new(): Void {
		super();
	}

	/**
	 * A leading infix operator reads as `HxCondSpliceOpTail`, and the region's interior is laid
	 * out by the rule rather than replayed from the source: every legal whitespace spelling of
	 * one fragment reaches one output.
	 */
	public function testALeadingOperatorFragmentIsNormalised(): Void {
		final canonical: String = 'class C {\n\tfunction f() {\n\t\tvar a = A + B #if m - 120 #end;\n\t}\n}';
		final spellings: Array<String> = [
			canonical,
			'class C {\n\tfunction f() {\n\t\tvar a = A + B #if   m    -     120   #end;\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\tvar a = A + B #if m\n\t\t\t-\n\t\t\t120\n\t\t#end;\n\t}\n}'
		];
		for (i in 0...spellings.length) Assert.equals(canonical, triviaWrite(spellings[i]), 'spelling $i');
	}

	/**
	 * The same shape in a member initializer, and with a postfix operand after the operator —
	 * TM `popups/help/HelpStyle.hx:15` and `popups/help/HelpMessageForm.hx:155`, the two live
	 * sites of this sub-shape.
	 */
	public function testTheOperatorFragmentInAMemberInitializer(): Void {
		final src: String = 'class C {\n\tpublic static inline final H:UInt = 488 + 1 + F #if mobile - 120 #end;\n\n'
			+ '\tfunction u():Void {\n\t\t_b.disabled = _e.wrong || _m.wrong #if !mobile || _a.wrong #end;\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
		final messy: String = 'class C {\n\tpublic static inline final H:UInt = 488 + 1 + F #if mobile  -  120  #end;\n\n'
			+ '\tfunction u():Void {\n\t\t_b.disabled = _e.wrong || _m.wrong #if !mobile\n\t\t\t|| _a.wrong #end;\n\t}\n}';
		Assert.equals(src, triviaWrite(messy), 'both interiors are normalised, not replayed');
	}

	/**
	 * A leading comma reads as `HxCondSpliceListTail` — one guarded element of an argument list
	 * or of an array literal. The comma stays TIGHT against the condition atom, which is the
	 * whole reason this sub-shape has a production of its own rather than sharing the operator
	 * one's `@:fmt(fillParts)` assembly: a fill seam would spend a space on that gap.
	 *
	 * TM `popups/sessionPlanner/SavedSessions.hx:45` and
	 * `popups/settings/account/Account.hx:73`; Pony `pony/net/rpc/IRPC.hx:160` is the array form.
	 */
	public function testALeadingCommaFragmentKeepsTheCommaTight(): Void {
		final src: String = 'class C {\n\tfunction f() {\n\t\tg(new A(), true #if FEATURE_SHARE_EXTRA, true #end);\n'
			+ '\t\tvar r = [_a, new Spacer(40, 20)#if (ios || MAC_APPSTORE), _labelRestorePurchases #end];\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
		final messy: String = 'class C {\n\tfunction f() {\n\t\tg(new A(), true #if FEATURE_SHARE_EXTRA ,   true   #end);\n'
			+ '\t\tvar r = [_a, new Spacer(40, 20)#if (ios || MAC_APPSTORE)  ,  _labelRestorePurchases   #end];\n\t}\n}';
		Assert.equals(src, triviaWrite(messy), 'the interior is normalised, not replayed');
	}

	/**
	 * The OPERAND-position splice is untouched. Its production is dispatched from the `#if`
	 * ATOM and this slice only adds branches under the POSTFIX one, so the eight census sites
	 * of that shape keep their bytes.
	 */
	public function testTheOperandPositionSpliceIsByteUnchanged(): Void {
		final src: String = 'class C {\n\tfunction f():String {\n\t\treturn \'a\' + endl + #if !flash \'b\' + x + #end \'c\';\n\t}\n}';
		Assert.equals(src, triviaWrite(src));
	}

	/**
	 * A fragment neither structured branch can represent stays raw and keeps its note. Three
	 * shapes, one per reason: a switch arm split across branches (TM
	 * `crashdumper/CrashDumper.hx:376`), a fragment carrying its own `#else`, and a
	 * MULTI-element comma run — the last is `HxCondSpliceListTail`'s declared limit, since
	 * every inter-element separator this writer offers would put a space before the comma.
	 */
	public function testWhatNeitherBranchRepresentsStaysRawAndStillWarns(): Void {
		final switchArm: String = 'class C {\n\tfunction f(s:StackItem):String {\n\t\tvar str:String = \'\';\n\t\tswitch (s) {\n'
			+ '\t\t\tcase Method(c, m):\n\t\t\t\tstr += m;\n\t\t\t#if (haxe_ver >= "3.1.0")\n\t\t\tcase LocalFunction(n):\n'
			+ '\t\t\t#else\n\t\t\tcase Lambda(n):\n\t\t\t#end\n\t\t\t\tstr += n;\n\t\t}\n\t\treturn str;\n\t}\n}';
		Assert.equals(switchArm, triviaWrite(switchArm), 'the switch-arm splice keeps its bytes');
		Assert.isTrue(noteFor(switchArm).indexOf('left unformatted') != -1, 'and still warns: ${noteFor(switchArm)}');
		final elseLed: String = 'class C {\n\tfunction f():Int {\n\t\treturn a #if m + b #else - b #end;\n\t}\n}';
		Assert.equals(elseLed, triviaWrite(elseLed));
		Assert.isTrue(noteFor(elseLed).indexOf('left unformatted') != -1, 'the `#else`-led tail warns: ${noteFor(elseLed)}');
		final twoElements: String = 'class C {\n\tfunction f():Void {\n\t\tg(a, b #if m,   c,  d #end);\n\t}\n}';
		Assert.equals(twoElements, triviaWrite(twoElements), 'a multi-element comma run keeps its bytes');
		Assert.isTrue(noteFor(twoElements).indexOf('left unformatted') != -1, 'and warns: ${noteFor(twoElements)}');
	}

	/**
	 * A nested `#if` inside a fragment still parses and still round-trips. `HxCondSpliceRaw`'s
	 * nesting-aware branch was written for three live sources that were skip-parse without it,
	 * and the structured branches must not take one of them away half-read: lime
	 * `system/ThreadPool.hx:829` is a tail splice whose operator's operand carries a whole
	 * nested region, and the other two are statement-scope shapes the tail branches never see.
	 */
	public function testANestedRegionInsideAFragmentSurvives(): Void {
		final threadPool: String = 'class C {\n\tfunction f():Void {\n\t\tif (activeJobs #if lime_threads + __queuedExitEvents '
			+ '#if lime_threads_deque + __queuedWorkEvents #end #end <= 0)\n\t\t\tg();\n\t}\n}';
		Assert.equals(threadPool, triviaWrite(threadPool));
		final font: String = 'class C {\n\tfunction f():Void {\n\t\t#if js if (ascender == untyped #if haxe4 js.Syntax.code '
			+ '#else __js__ #end ("undefined")) #end ascender = 0;\n\t}\n}';
		Assert.equals(font, triviaWrite(font));
	}

	/** Every new form is a fixed point of the writer, which is what `hxq fmt` promises. */
	public function testFmtIsAFixedPointOnEveryNewForm(): Void {
		final forms: Array<String> = [
			'class C {\n\tfunction f() {\n\t\tvar a = A + B #if   m    -     120   #end;\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\tvar a = A + B #if m\n\t\t\t-\n\t\t\t120\n\t\t#end;\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\tg(new A(), true #if F ,  true #end);\n\t}\n}',
			'class C {\n\tfunction f() {\n\t\tvar r = [_a, new B(40, 20)#if (ios || MAC), _c #end];\n\t}\n}',
			'class C {\n\tfunction f():Int {\n\t\treturn a #if m + b #else - b #end;\n\t}\n}',
			'class C {\n\tfunction f():Void {\n\t\tif (activeJobs #if lime_threads + __queuedExitEvents '
				+ '#if lime_threads_deque + __queuedWorkEvents #end #end <= 0)\n\t\t\tg();\n\t}\n}'
		];
		for (i in 0...forms.length) {
			final once: String = triviaWrite(forms[i]);
			Assert.equals(once, triviaWrite(once), 'form $i is not a fixed point');
		}
	}

	/** The single `fmt` note a source carrying exactly one raw region produces. */
	private inline function noteFor(src: String): String {
		final notes: Array<String> = FmtCommand.opaqueCondRegionNotes(new HaxeQueryPlugin(), 'A.hx', src);
		return notes.length == 1 ? notes[0] : 'expected exactly one note, got ${notes.length}';
	}

	private inline function triviaWrite(src: String): String {
		return HxWriteFixture.triviaWrite(src, CONFIG);
	}

}
