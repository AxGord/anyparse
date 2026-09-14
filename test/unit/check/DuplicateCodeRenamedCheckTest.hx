package unit.check;

import anyparse.check.Check;
import anyparse.check.DuplicateCode;
import anyparse.check.DuplicateCodeRenamed;
import anyparse.check.Linter;
import anyparse.check.Severity;
import anyparse.grammar.haxe.HaxeQueryPlugin;
import utest.Assert;
import utest.Test;

/**
 * The `duplicate-code-renamed` check: three or more consecutive statements repeated with their
 * LOCAL bindings renamed are an `Info`, report-only clone, while a crossed renaming, a different
 * literal and a different member name are safe misses. Every fixture here also asserts what the
 * exact reading answers on the same source, because the two rules are one engine and the exact
 * one must not widen.
 */
class DuplicateCodeRenamedCheckTest extends Test {

	/**
	 * THE discriminating fixture for the renaming: the copies differ only in what their parameters
	 * and locals are called, so the exact reading is silent and this one is not. With the binder
	 * dictionary emptied the render normalizes nothing, the two texts stop matching, and this
	 * fixture goes RED.
	 */
	@:pin('control')
	@:killer('M-DUP-CODE-RENAMED-BINDERS')
	public function testALocalsOnlyRenamingIsAClone(): Void {
		final source: String = src([
			'class C {',
			'\tfunction f(alpha:Int, beta:Int):Void {',
			'\t\tfinal one:Int = alpha + beta;',
			'\t\tfinal two:Int = one * alpha;',
			'\t\ttrace(one, two, beta);',
			'\t}',
			'\tfunction g(gamma:Int, delta:Int):Void {',
			'\t\tfinal first:Int = gamma + delta;',
			'\t\tfinal second:Int = first * gamma;',
			'\t\ttrace(first, second, delta);',
			'\t}',
			'}'
		]);
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals('duplicate-code-renamed', vs[0].rule);
		Assert.equals(Severity.Info, vs[0].severity);
		Assert.equals('3 statements duplicated from line 3 — extract a helper (bindings renamed; hxq extract-method)', vs[0].message);
		Assert.equals(0, exact(source).length, 'the exact reading stays silent on a renamed copy');
	}

	/**
	 * The renaming has to be one-to-one: the second copy swaps the roles of its two parameters, so
	 * no renaming maps one copy onto the other and the run ends where the swap is.
	 */
	public function testACrossedRenamingIsNotAClone(): Void {
		final source: String = src([
			'class C {',
			'\tfunction f(alpha:Int, beta:Int):Void {',
			'\t\tfinal one:Int = alpha + beta;',
			'\t\tfinal two:Int = one * alpha;',
			'\t\ttrace(one, two, beta);',
			'\t}',
			'\tfunction g(gamma:Int, delta:Int):Void {',
			'\t\tfinal first:Int = gamma + delta;',
			'\t\tfinal second:Int = first * delta;',
			'\t\ttrace(first, second, gamma);',
			'\t}',
			'}'
		]);
		Assert.equals(0, violations(source).length);
		Assert.equals(0, exact(source).length);
	}

	/** Literals are compared as written — this is a renaming detector, not a parameterization one. */
	public function testADifferentLiteralIsNotAClone(): Void {
		final source: String = src([
			'class C {',
			'\tfunction f(alpha:Int):Void {',
			'\t\tfinal one:Int = alpha + 1;',
			'\t\tfinal two:Int = one * alpha;',
			'\t\ttrace(one, two, alpha);',
			'\t}',
			'\tfunction g(gamma:Int):Void {',
			'\t\tfinal first:Int = gamma + 2;',
			'\t\tfinal second:Int = first * gamma;',
			'\t\ttrace(first, second, gamma);',
			'\t}',
			'}'
		]);
		Assert.equals(0, violations(source).length);
	}

	/** A MEMBER name is not a local binding, so a copy calling a different method is not a clone. */
	public function testADifferentMemberNameIsNotAClone(): Void {
		final source: String = src([
			'class C {',
			'\tfunction f(alpha:Int):Void {',
			'\t\tfinal one:Int = alpha + alpha;',
			'\t\tfinal two:Int = one * alpha;',
			'\t\tfirstSink(one, two);',
			'\t}',
			'\tfunction g(gamma:Int):Void {',
			'\t\tfinal first:Int = gamma + gamma;',
			'\t\tfinal second:Int = first * gamma;',
			'\t\tsecondSink(first, second);',
			'\t}',
			'}'
		]);
		Assert.equals(0, violations(source).length);
	}

	/**
	 * A loop variable and a `catch` binder carry their name on the node itself rather than as an
	 * identifier of their own, so the render has to find the name token inside the binder's own
	 * text — the half of the normalization a reference-only pass would miss.
	 */
	public function testALoopAndCatchBinderRenamingIsAClone(): Void {
		final source: String = src([
			'class C {',
			'\tfunction f(items:Array<Int>):Void {',
			'\t\tfor (item in items) trace(item);',
			'\t\ttry throw items catch (problem:Dynamic) trace(problem);',
			'\t\ttrace(items.length, items);',
			'\t}',
			'\tfunction g(values:Array<Int>):Void {',
			'\t\tfor (value in values) trace(value);',
			'\t\ttry throw values catch (failure:Dynamic) trace(failure);',
			'\t\ttrace(values.length, values);',
			'\t}',
			'}'
		]);
		final vs: Array<Violation> = violations(source);
		Assert.equals(1, vs.length);
		Assert.equals(0, exact(source).length);
	}

	/**
	 * The content gate measures the text the comparison keys on. Three declarations sharing nothing
	 * but their shape clear the gate on their raw bytes — the long names are most of them — and fall
	 * under it once each name weighs what its placeholder does, so the renamed reading is silent;
	 * with every copy measured on its own bytes again (the arm) the run comes back as a clone.
	 */
	@:pin('control')
	@:killer('M-DUP-CODE-RENAMED-GATE-RAW')
	public function testDeclarationsWhoseBytesAreMostlyTheirNamesAreNotAClone(): Void {
		final source: String = src([
			'class C {',
			'\tfunction f(alphaValue:Int, betaValue:Int):Void {',
			'\t\tfinal firstTotal = alphaValue;',
			'\t\tfinal secondTotal = betaValue;',
			'\t\tfinal thirdTotal = firstTotal;',
			'\t}',
			'\tfunction g(gammaValue:Int, deltaValue:Int):Void {',
			'\t\tfinal leftTotal = gammaValue;',
			'\t\tfinal rightTotal = deltaValue;',
			'\t\tfinal lastTotal = leftTotal;',
			'\t}',
			'}'
		]);
		Assert.equals(0, violations(source).length);
		Assert.equals(0, exact(source).length);
	}

	/**
	 * The same three declarations with an initializer the copies really share clear the gate, so what
	 * the pin above filters is the name-only run and not every declaration run.
	 */
	public function testDeclarationsSharingTheirInitializersAreAClone(): Void {
		final source: String = src([
			'class C {',
			'\tfunction f(alphaValue:Int, betaValue:Int):Void {',
			'\t\tfinal firstTotal:Int = Math.max(alphaValue, betaValue);',
			'\t\tfinal secondTotal:Int = Math.min(alphaValue, betaValue);',
			'\t\tfinal thirdTotal:Int = Math.max(firstTotal, secondTotal);',
			'\t}',
			'\tfunction g(gammaValue:Int, deltaValue:Int):Void {',
			'\t\tfinal leftTotal:Int = Math.max(gammaValue, deltaValue);',
			'\t\tfinal rightTotal:Int = Math.min(gammaValue, deltaValue);',
			'\t\tfinal lastTotal:Int = Math.max(leftTotal, rightTotal);',
			'\t}',
			'}'
		]);
		Assert.equals(1, violations(source).length);
		Assert.equals(0, exact(source).length);
	}

	/**
	 * The exact reading holes nothing, so its gate text is the raw render and an identically-named
	 * copy of the name-heavy run stays its clone: the placeholder measure narrows this rule's
	 * population and leaves the other rule's where it was.
	 */
	public function testTheExactReadingKeepsAnIdenticallyNamedDeclarationRun(): Void {
		final source: String = src([
			'class C {',
			'\tfunction f(alphaValue:Int, betaValue:Int):Void {',
			'\t\tfinal firstTotal = alphaValue;',
			'\t\tfinal secondTotal = betaValue;',
			'\t\tfinal thirdTotal = firstTotal;',
			'\t}',
			'\tfunction g(alphaValue:Int, betaValue:Int):Void {',
			'\t\tfinal firstTotal = alphaValue;',
			'\t\tfinal secondTotal = betaValue;',
			'\t\tfinal thirdTotal = firstTotal;',
			'\t}',
			'}'
		]);
		Assert.equals(1, exact(source).length);
		Assert.equals(0, violations(source).length);
	}

	/** An exact clone with no local binding in play is a clone under renaming too: the two readings compare and gate the same text. */
	public function testAnExactCloneIsReportedByBothReadings(): Void {
		final source: String = src([
			'class C {',
			'\tfunction f():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t}',
			'\tfunction g():Void {',
			'\t\ttrace(alpha, beta);',
			'\t\ttrace(gamma, delta);',
			'\t\ttrace(epsilon, zeta);',
			'\t}',
			'}'
		]);
		Assert.equals(1, violations(source).length);
		Assert.equals(1, exact(source).length);
	}

	/** The cross-file wording names the partner file and says the bindings were renamed. */
	public function testCrossFileRenamedCloneNamesThePartner(): Void {
		final vs: Array<Violation> = new DuplicateCodeRenamed().run([
			{
				file: 'src/Foo.hx',
				source: src([
					'class Foo {',
					'\tfunction f(alpha:Int, beta:Int):Void {',
					'\t\tfinal one:Int = alpha + beta;',
					'\t\tfinal two:Int = one * alpha;',
					'\t\ttrace(one, two, beta);',
					'\t}',
					'}'
				])
			},
			{
				file: 'test/Bar.hx',
				source: src([
					'class Bar {',
					'\tfunction g(gamma:Int, delta:Int):Void {',
					'\t\tfinal first:Int = gamma + delta;',
					'\t\tfinal second:Int = first * gamma;',
					'\t\ttrace(first, second, delta);',
					'\t}',
					'}'
				])
			}
		], new HaxeQueryPlugin());
		Assert.equals(1, vs.length);
		Assert.equals('test/Bar.hx', vs[0].file);
		Assert.equals(
			'3 statements duplicated from src/Foo.hx:3 — extract a shared helper (bindings renamed; report-only, cross-file)',
			vs[0].message
		);
	}

	public function testRegisteredInBuiltinsAsDefaultOff(): Void {
		final check: Null<Check> = Linter.byId('duplicate-code-renamed');
		Assert.notNull(check);
		Assert.isTrue(Std.isOfType(check, DefaultOff), 'the renamed reading is opt-in');
		Assert.equals(183, Linter.builtins().length);
	}

	public function testFixReturnsNothingAndTheReasonSaysWhy(): Void {
		final check: DuplicateCodeRenamed = new DuplicateCodeRenamed();
		Assert.equals(0, check.fix('class C {}', [], new HaxeQueryPlugin()).length);
		Assert.isTrue(check.noAutofixReason().indexOf('judgement') >= 0, check.noAutofixReason());
	}

	/**
	 * The anti-drift pin for `VolatileMessage`: this rule's mask is anchored on its OWN tail, so a
	 * reworded message turns it into a silent no-op. The input is a message `run` produced.
	 */
	public function testMessageIdentityMasksItsOwnOriginalLine(): Void {
		final check: DuplicateCodeRenamed = new DuplicateCodeRenamed();
		final message: String = check.run([
			{
				file: 'C.hx',
				source: src([
					'class C {',
					'\tfunction f(alpha:Int, beta:Int):Void {',
					'\t\tfinal one:Int = alpha + beta;',
					'\t\tfinal two:Int = one * alpha;',
					'\t\ttrace(one, two, beta);',
					'\t}',
					'\tfunction g(gamma:Int, delta:Int):Void {',
					'\t\tfinal first:Int = gamma + delta;',
					'\t\tfinal second:Int = first * gamma;',
					'\t\ttrace(first, second, delta);',
					'\t}',
					'}'
				])
			}
		], new HaxeQueryPlugin())[0].message;
		final identity: String = check.messageIdentity(message);
		Assert.equals('3 statements duplicated from line # — extract a helper (bindings renamed; hxq extract-method)', identity);
		Assert.equals(identity, check.messageIdentity(identity), 'the normalization is idempotent');
	}

	private function violations(source: String): Array<Violation> {
		return new DuplicateCodeRenamed().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function exact(source: String): Array<Violation> {
		return new DuplicateCode().run([{ file: 'C.hx', source: source }], new HaxeQueryPlugin());
	}

	private function src(lines: Array<String>): String {
		return lines.join('\n');
	}

}
